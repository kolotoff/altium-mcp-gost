"""Offline tests for script_bundle (no Altium needed).

Run: python -m unittest discover -s server/tests -p "test_script_bundle.py"
"""

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import script_bundle as sb  # noqa: E402


def defined_before_use(text):
    """Routines used before their definition in a bundle (should be none)."""
    clean = sb._NOISE.sub(lambda m: " " * len(m.group(0)), text)
    defs = {}
    for m in re.finditer(r"^(?:function|procedure)\s+(\w+)", text, re.M | re.I):
        defs.setdefault(m.group(1).lower(), m.start())
    return [n for n, pos in defs.items() if re.search(r"\b" + n + r"\b", clean[:pos], re.I)]


class BundleTests(unittest.TestCase):
    def write(self, folder, name, text):
        p = Path(folder) / name
        p.write_text(text.replace("\n", "\r\n"), encoding="latin-1")
        return p

    def test_callees_come_first_and_globals_lead(self):
        with tempfile.TemporaryDirectory() as d:
            a = self.write(d, "a.pas", "var\n    Counter: Integer;\n\n"
                                       "// Entry point\nprocedure Run;\nbegin\n    Helper('x');\nend;\n")
            b = self.write(d, "b.pas", "function Helper(S: String): String;\nbegin\n"
                                       "    Result := S; // Run is not called here\nend;\n")
            text = sb.bundle_text([a, b])
            self.assertLess(text.index("Counter: Integer"), text.index("function Helper"))
            self.assertLess(text.index("function Helper"), text.index("procedure Run"))
            self.assertIn("// Entry point", text)
            self.assertEqual(defined_before_use(text), [])

    def test_cycle_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            a = self.write(d, "a.pas", "procedure A;\nbegin\n    B;\nend;\n\nprocedure B;\nbegin\n    A;\nend;\n")
            with self.assertRaises(ValueError):
                sb.bundle_text([a])

    def test_real_project_bundles_in_order(self):
        units = sb.project_units(HERE.parent / "AltiumScript" / "Altium_API.PrjScr")
        self.assertGreater(len(units), 5)
        text = sb.bundle_text(units)
        self.assertEqual(defined_before_use(text), [])
        count = sum(len(re.findall(r"^(?:function|procedure)\s", p.read_text(encoding="latin-1"), re.M | re.I))
                    for p in units)
        self.assertEqual(len(re.findall(r"^(?:function|procedure)\s", text, re.M | re.I)), count)

    def test_rebuilds_when_a_unit_changes(self):
        with tempfile.TemporaryDirectory() as d:
            unit = self.write(d, "u.pas", "procedure Run;\nbegin\nend;\n")
            prj = self.write(d, "p.PrjScr", "[Document1]\nDocumentPath=u.pas\n")
            out = Path(d) / "bridge"
            first = sb.ensure_bundle(prj, out)
            self.assertEqual(sb.ensure_bundle(prj, out), first)
            self.write(d, "u.pas", "procedure Run;\nbegin\n    ShowMessage('new');\nend;\n")
            later = first.stat().st_mtime + 5
            os.utime(unit, (later, later))
            second = sb.ensure_bundle(prj, out)
            # New content, new name: Altium never runs an editor copy of the old one
            self.assertNotEqual(second, first)
            self.assertIn("ShowMessage('new')", second.read_text(encoding="latin-1"))

    def test_real_routing_bundles_guard_the_request_and_include_selected_dispatch(self):
        project = HERE.parent / "AltiumScript" / "Altium_API.PrjScr"
        units = sb.project_units(project)
        selected = {
            "create_pcb_rule": "ExecuteCreatePCBRule",
            "get_unrouted_connections": "ExecuteGetUnroutedConnections",
            "list_open_documents": "ListOpenDocuments",
            "pcb_routing": "ExecutePCBRouting",
        }
        full = sb.bundle_text(units)
        for command, entry in selected.items():
            with self.subTest(command=command):
                specialized = sb.bundle_text(units, command)
                guard = f"if (RequestText(RequestData, 'command', '') <> '{command}') then Exit;"
                self.assertLess(specialized.index(guard), specialized.index("DeleteFile(REQUEST_FILE)"))
                self.assertRegex(specialized, rf"(?i)\b{entry}\s*\(")
                self.assertNotIn("ExecuteCreateSymbolsBatch", specialized)
                self.assertLess(len(specialized), len(full) // 4)
                self.assertEqual(defined_before_use(specialized), [])
        with tempfile.TemporaryDirectory() as directory:
            narrow = sb.ensure_bundle(project, directory, command="pcb_routing")
            legacy = sb.ensure_bundle(project, directory)
            self.assertNotEqual(narrow, legacy)
            self.assertTrue(narrow.exists())
            self.assertEqual(narrow, sb.ensure_bundle(project, directory, command="pcb_routing"))

    def test_resident_bundle_keeps_only_routing_commands_and_binds_its_ticket(self):
        project = HERE.parent / "AltiumScript" / "Altium_API.PrjScr"
        with tempfile.TemporaryDirectory() as directory:
            resident = sb.ensure_bundle(project, directory, resident=True)
            text = resident.read_text(encoding="latin-1")
            self.assertIn("procedure RunResident;", text)
            self.assertNotIn("ExecuteCreateSymbolsBatch", text)
            self.assertEqual(defined_before_use(text), [])
            self.assertNotIn(sb.RESIDENT_KEY_PLACEHOLDER, text)
            key = resident.stem.rsplit("_", 1)[1]
            self.assertIn(f"BridgeResidentKey = '{key}'", text)
            for command in sb.ROUTING_COMMANDS:
                self.assertIn(f"RequestText(RequestData, 'command', '') <> '{command}'", text)
            self.assertEqual(resident, sb.ensure_bundle(project, directory, resident=True))

    def test_keeps_the_newest_bundles(self):
        with tempfile.TemporaryDirectory() as d:
            unit = self.write(d, "u.pas", "procedure Run;\nbegin\nend;\n")
            prj = self.write(d, "p.PrjScr", "[Document1]\nDocumentPath=u.pas\n")
            out = Path(d) / "bridge"
            for n in range(5):
                self.write(d, "u.pas", f"procedure Run;\nbegin\n    I := {n};\nend;\n")
                t = 1_000_000 + n * 10
                os.utime(unit, (t, t))
                built = sb.ensure_bundle(prj, out, keep=3)
                os.utime(built, (t, t))
            self.assertEqual(len(list(out.glob("p_*.pas"))), 3)


if __name__ == "__main__":
    unittest.main()
