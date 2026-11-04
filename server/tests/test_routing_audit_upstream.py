# Portions adapted from Quilter PCB routing test tools.
# Copyright 2026 Allegro Labs, Inc. (Quilter). MIT; see LICENSES/Quilter-MIT.txt.
"""Check exact geometry, duplicate DRC, and inventory invariants."""

import tempfile
import unittest
from collections import Counter
from copy import deepcopy
from pathlib import Path

from server import routing_audit as compare


class ComparisonTests(unittest.TestCase):
    """Exercise comparisons where aggregate counts alone are insufficient."""

    def test_reversed_tracks_keep_multiplicity_and_ignore_selection(self):
        first = {
            "net": "N",
            "x1_raw": "10",
            "y1_raw": "30",
            "x2_raw": "2",
            "y2_raw": "4",
            "width_raw": "5",
            "layer_id": "1",
            "selected": "false",
        }
        reversed_track = dict(
            first, x1_raw="2", y1_raw="4", x2_raw="10", y2_raw="30", selected="true"
        )
        before = compare.records([first, first], track=True)
        after = compare.records([reversed_track], track=True)
        self.assertEqual(compare.delta(before, after)["removed_count"], 1)
        self.assertEqual(compare.delta(before, after)["added_count"], 0)

    def test_remaining_count_excludes_redundant_and_broken_markers(self):
        rows = [
            {"net": "N", "mode": "ratsnest", "redundant": "false"},
            {"net": "N", "mode": "ratsnest", "redundant": "true"},
            {"net": "N", "mode": "broken_net_marker", "redundant": "false"},
            {"net": "n", "mode": "ratsnest", "redundant": "false"},
        ]
        self.assertEqual(
            compare.remaining_edges({"connections": rows}), Counter({"N": 1, "n": 1})
        )

    def test_pad_move_and_rule_scope_change_fail_with_unchanged_counts(self):
        baseline = {
            "board": {
                "coordinate_units": "raw",
                "internal_units_per_mil": "10000",
                "x_origin_raw": "1",
                "y_origin_raw": "2",
            },
            "tables": {
                "pads": [
                    {
                        "refdes": "U1",
                        "pad": "1",
                        "net": "N",
                        "x_raw": "100",
                        "selected": "false",
                    }
                ],
                "rules": [{"name": "Width", "scope1": "All", "drc_enabled": "true"}],
                "nets": [{"net": "N", "pin_count": "1"}],
                "tracks": [],
                "vias": [],
                "connections": [],
            },
            "counts": {},
        }
        current = deepcopy(baseline)
        current["tables"]["pads"][0]["x_raw"] = "101"
        current["tables"]["rules"][0]["scope1"] = "InNet('N')"
        regressions = compare.compare_inventories(baseline, current)["regressions"]
        self.assertIn("Immutable pads records changed", regressions)
        self.assertIn("Immutable rules records changed", regressions)

    def test_drc_duplicates_and_rule_context_are_not_collapsed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.drc"
            path.write_text(
                "PCB File : C:\\board.PcbDoc\n"
                "Processing Rule : Clearance A\n"
                "   Violation between Same objects\n"
                "   Violation between Same objects\n"
                "Rule Violations :2\n"
                "Processing Rule : Clearance B\n"
                "   Violation between Same objects\n"
                "Rule Violations :1\n"
                "Violations Detected : 3\nWaived Violations : 0\n",
                encoding="utf-8",
            )
            report = compare.read_drc(path)
            self.assertEqual(report["total"], 3)
            self.assertEqual(len(report["findings"]), 2)
            reduced = report["findings"].copy()
            reduced[next(iter(reduced))] -= 1
            self.assertEqual(
                compare.delta(report["findings"], reduced)["removed_count"], 1
            )

    def test_drc_rejects_truncated_or_inconsistent_subtotal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.drc"
            for text in (
                "Processing Rule : A\n   Violation between X\n",
                "Processing Rule : A\n   Violation between X\nRule Violations :0\n",
            ):
                path.write_text(text, encoding="utf-8")
                with self.assertRaises(ValueError):
                    compare.read_drc(path)

    def test_inventory_counts_are_validated_without_source_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "inventory-status.txt").write_text("complete\n", encoding="utf-8")
            for name, header in compare.HEADERS.items():
                (root / f"{name}.tsv").write_text(
                    header.replace(" ", "\t") + "\n", encoding="utf-8"
                )
            fields = {
                "net_count": 0,
                "pad_count": 0,
                "track_segment_count": 0,
                "via_count": 0,
                "rule_count": 0,
                "connection_object_count": 0,
                "nonredundant_ratsnest_connections": 0,
                "redundant_connection_objects": 0,
                "connectivity_invalid_nets": 0,
                "internal_units_per_mil": 10000,
                "coordinate_units": "Altium internal units",
                "board_file": "C:\\board.PcbDoc",
                "x_origin_raw": 0,
                "y_origin_raw": 0,
            }
            text = "field\tvalue\n" + "".join(
                f"{name}\t{value}\n" for name, value in fields.items()
            )
            (root / "board.tsv").write_text(text, encoding="utf-8")
            before = {path.name: path.read_bytes() for path in root.iterdir()}
            self.assertEqual(
                compare.read_inventory(root)["counts"]["connection_object_count"], 0
            )
            self.assertEqual(
                before, {path.name: path.read_bytes() for path in root.iterdir()}
            )
            (root / "board.tsv").write_text(
                text.replace("pad_count\t0", "pad_count\t1"), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "pad_count declares 1, found 0"):
                compare.read_inventory(root)


if __name__ == "__main__":
    unittest.main()
