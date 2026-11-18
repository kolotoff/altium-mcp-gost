"""Exercise compact Altium reports and the read-only capture workflow."""

import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

from server import routing_audit as audit
from server.altium_transport import FileCommandTransport, atomic_json
from server.pcb_routing import GENERATED, RoutingService, summarize_drc_artifacts
from server.project_validation import validate_project
from server.tests.test_routing import write_snapshot


BOARD = r"D:\Boards, shared\测试\Example.PcbDoc"
RULE = "Modified Polygon (Allow modified: No), (Allow shelved: No)"
WARNING = "Design contains shelved or unrepoured polygons"
REQUEST_ID = "1" * 32


def compact_report(*, violation=False, warning=False):
    count = int(violation)
    warnings = int(warning)
    lines = ["", f"Warnings|Total|{warnings}", f"Violations|Total|{count}"]
    if warning:
        lines.append(f"Warnings|{WARNING}|1")
    lines.extend(
        [
            "",
            f"Warnings|Total|{warnings}",
            f"Rule Violations|{RULE}|{count}",
            f"Rule Violations|Total|{count}",
        ]
    )
    if warning:
        lines.append(f"{WARNING}|||Polygon named: GND_BOTTOM")
    if violation:
        lines.append(f"{RULE}|1.5|2.3|Modified Polygon on Bottom Layer")
    return "\n".join(lines) + "\n"


class NativeDRCTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        parent = GENERATED / "native-drc-tests"
        parent.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write_report(self, path, **options):
        path.write_text(compact_report(**options), encoding="utf-8")
        return path

    def native_response(self, params, **options):
        path = Path(params["operation_directory"]) / "native-drc.txt"
        self.write_report(path, **options)
        return {
            "success": True,
            "request_id": REQUEST_ID,
            "result": {
                "board_file": BOARD,
                "saved": False,
                "pcb_modified_before": False,
                "pcb_modified_after": False,
            },
        }

    async def test_export_binds_native_report_to_exact_board_and_hash(self):
        bridge = AsyncMock(
            side_effect=lambda command, params: self.native_response(
                params, violation=True, warning=True
            )
        )
        result = await RoutingService(bridge).export_drc(
            BOARD, str(self.root / "export")
        )
        self.assertEqual(bridge.await_args.args[0], "pcb_routing")
        self.assertEqual(bridge.await_args.args[1]["operation"], "native_drc")
        self.assertEqual(bridge.await_args.args[1]["expected_board"], BOARD)
        self.assertEqual((result["violations"], result["warning_count"]), (1, 1))
        self.assertIsNone(result["waived"])
        self.assertFalse(result["saved"])
        path = Path(result["report_path"])
        parsed = audit.read_drc(path)
        self.assertEqual(parsed["metadata"]["PCB File"], BOARD)
        self.assertEqual(parsed["capture"]["request_id"], REQUEST_ID)
        self.assertIn(
            "1.5|2.3|Modified Polygon", audit.drc_ledger(parsed)[0]["finding"]
        )
        with self.assertRaisesRegex(ValueError, "expected board"):
            summarize_drc_artifacts(str(path), r"D:\Other\Example.PcbDoc")
        path.write_text(compact_report(), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "receipt does not match"):
            audit.read_drc(path)

    async def test_standalone_compact_drc_goes_through_validator_with_review(self):
        snapshot = write_snapshot(self.root / "snapshot")
        path = self.write_report(self.root / "standalone.txt", warning=True)
        bridge = AsyncMock()
        result = await validate_project(
            bridge,
            BOARD,
            snapshot_directory=snapshot["directory"],
            drc_report_path=str(path),
            output=str(self.root / "validation"),
        )
        bridge.assert_not_awaited()
        stage = result["stages"][-1]
        self.assertEqual(stage["status"], "review")
        self.assertEqual(
            stage["counts"], {"violations": 0, "waived": None, "native_warnings": 1}
        )
        report = json.loads(Path(result["report_path"]).read_text(encoding="utf-8"))
        self.assertEqual(
            report["stages"][-1]["evidence"]["board_identity_source"], "caller"
        )

    async def test_captured_compact_baseline_keeps_waivers_unknown(self):
        bridge = AsyncMock(
            side_effect=lambda command, params: self.native_response(params)
        )
        service = RoutingService(bridge)
        baseline = await service.export_drc(BOARD, str(self.root / "baseline"))
        current = await service.export_drc(BOARD, str(self.root / "current"))
        result = audit.compare_drc_reports(
            baseline["report_path"], current["report_path"]
        )
        self.assertIsNone(result["waiver_count_changed"])
        self.assertIsNone(result["passed"])
        self.assertEqual(result["changes"]["added_count"], 0)
        bridge.side_effect = lambda command, params: self.native_response(
            params, violation=True
        )
        changed = await service.export_drc(BOARD, str(self.root / "changed"))
        result = audit.compare_drc_reports(
            baseline["report_path"], changed["report_path"]
        )
        self.assertFalse(result["passed"])
        self.assertEqual(result["changes"]["added_count"], 1)

    async def test_native_drc_can_outlast_the_standard_response_timeout(self):
        directory = self.root / "exchange"
        completion = None

        async def launch():
            nonlocal completion
            request = json.loads(
                (directory / "request.json").read_text(encoding="utf-8-sig")
            )
            request_id = request["request_id"]

            async def respond():
                await asyncio.sleep(0.04)
                atomic_json(
                    directory / f"response-{request_id}.json",
                    {
                        "request_id": request_id,
                        "success": True,
                    },
                )

            completion = asyncio.create_task(respond())
            return True

        transport = FileCommandTransport(
            directory,
            launch,
            timeout=0.01,
            poll=0.005,
            native_drc_timeout=0.3,
        )
        result = await transport.execute("pcb_routing", {"operation": "native_drc"})
        await completion
        self.assertTrue(result["success"])

    async def test_cancelled_export_keeps_warning_handler_and_seals_report(self):
        started, release, stopped = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def execute(command, params):
            await release.wait()
            return self.native_response(params)

        async def watch(directory):
            started.set()
            try:
                await asyncio.Future()
            finally:
                stopped.set()

        service = RoutingService(execute, watch)
        export = asyncio.create_task(
            service.export_drc(BOARD, str(self.root / "capture"))
        )
        await asyncio.wait_for(started.wait(), 1)
        (capture_task,) = service._drc_tasks
        export.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await export
        self.assertFalse(stopped.is_set())
        release.set()
        result = await asyncio.wait_for(capture_task, 1)
        self.assertTrue(stopped.is_set())
        self.assertTrue(Path(result["capture_path"]).is_file())

    def test_inconsistent_native_detail_is_rejected(self):
        path = self.root / "truncated.txt"
        path.write_text(
            compact_report(violation=True).rsplit("\n", 2)[0], encoding="utf-8"
        )
        with self.assertRaisesRegex(ValueError, "subtotals do not reconcile"):
            audit.read_drc(path)
