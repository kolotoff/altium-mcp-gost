"""Verify validation verdicts, source binding, and the read-only command path."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock

from server.pcb_routing import GENERATED
from server.project_validation import validate_project
from server.tests.test_routing import write_snapshot


BOARD = r"D:\Boards, shared\测试\Example.PcbDoc"
PROJECT = r"D:\Boards, shared\测试\Example.PrjPcb"


class ProjectValidationTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        parent = GENERATED / "project-validation-tests"
        parent.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write_drc(
        self, name="current.drc", *, board=BOARD, rule="Clearance Constraint", count=0
    ):
        path = self.root / name
        lines = [f"PCB File : {board}", f"Processing Rule : {rule}"]
        lines.extend(["   Violation between Pad U1-1 and Track"] * count)
        lines.extend(
            [
                f"Rule Violations : {count}",
                f"Violations Detected : {count}",
                "Waived Violations : 0",
            ]
        )
        path.write_text("\n".join(lines), encoding="utf-8")
        return str(path)

    @staticmethod
    def project_result(*designators):
        return {
            "success": True,
            "result": {
                "success": True,
                "path": PROJECT,
                "board_file": BOARD,
                "components": [
                    {"designator": ref, "footprint": "QFN"} for ref in designators
                ],
            },
        }

    async def test_live_pass_calls_only_project_inspection_and_snapshot(self):
        async def execute(command, params):
            if command == "project_variant_maintenance":
                return self.project_result("U1")
            self.assertEqual(
                (command, params["operation"]), ("pcb_routing", "snapshot")
            )
            write_snapshot(
                params["operation_directory"],
                snapshot_id=params["snapshot_id"],
                seal=False,
            )
            return {"success": True, "result": {}}

        bridge = AsyncMock(side_effect=execute)
        result = await validate_project(
            bridge,
            BOARD,
            PROJECT,
            drc_report_path=self.write_drc(),
            output=str(self.root / "review"),
        )
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual([stage["status"] for stage in result["stages"]], ["pass"] * 4)
        self.assertEqual(bridge.await_count, 2)
        self.assertEqual(
            bridge.await_args_list[0].args,
            (
                "project_variant_maintenance",
                {
                    "exclude_footprint_names": [],
                    "layer_moves": [f"PROJECT_VARIANT_COMPONENTS|{PROJECT}|{BOARD}"],
                },
            ),
        )
        report = json.loads(Path(result["report_path"]).read_text(encoding="utf-8"))
        self.assertEqual(report["stages"][1]["evidence"]["source"], "live_snapshot")
        self.assertFalse(report["stages"][3]["evidence"]["freshness_verified"])
        self.assertTrue(Path(result["markdown_path"]).is_file())

    async def test_drc_is_still_checked_when_snapshot_is_bound_to_another_board(self):
        board = r"D:\Another\Example.PcbDoc"
        snapshot = write_snapshot(self.root / "snapshot")
        bridge = AsyncMock()
        result = await validate_project(
            bridge,
            board,
            snapshot_directory=snapshot["directory"],
            drc_report_path=self.write_drc(board=board, count=2),
            output=str(self.root / "review"),
        )
        bridge.assert_not_awaited()
        self.assertEqual(result["verdict"], "fail")
        self.assertEqual(
            [stage["status"] for stage in result["stages"]],
            ["skipped", "error", "skipped", "fail"],
        )
        self.assertEqual(result["stages"][3]["counts"]["violations"], 2)
        self.assertNotIn("Violation between Pad", json.dumps(result))

    async def test_designator_differences_and_missing_drc_are_incomplete(self):
        snapshot = write_snapshot(self.root / "snapshot")
        bridge = AsyncMock(return_value=self.project_result("U2", "U2"))
        result = await validate_project(
            bridge,
            BOARD,
            PROJECT,
            snapshot_directory=snapshot["directory"],
            output=str(self.root / "review"),
        )
        self.assertEqual(result["verdict"], "incomplete")
        self.assertEqual(
            [stage["status"] for stage in result["stages"]],
            ["pass", "pass", "review", "skipped"],
        )
        report = json.loads(Path(result["report_path"]).read_text(encoding="utf-8"))
        self.assertEqual(report["stages"][2]["evidence"]["pcb_only"], ["U1"])
        self.assertEqual(
            report["stages"][2]["evidence"]["duplicate_schematic_designators"], ["U2"]
        )
        self.assertNotIn("U2", json.dumps(result))
        bridge.assert_awaited_once()

    async def test_legacy_project_response_cannot_authorize_designator_comparison(self):
        snapshot = write_snapshot(self.root / "snapshot")
        legacy = self.project_result("U1")
        del legacy["result"]["board_file"]
        bridge = AsyncMock(return_value=legacy)
        result = await validate_project(
            bridge,
            BOARD,
            PROJECT,
            snapshot_directory=snapshot["directory"],
            drc_report_path=self.write_drc(),
            output=str(self.root / "review"),
        )
        self.assertEqual(
            [stage["status"] for stage in result["stages"]],
            ["error", "pass", "skipped", "pass"],
        )

    async def test_unresolved_live_query_blocks_new_native_requests(self):
        bridge = AsyncMock(
            return_value={
                "success": False,
                "error": "timeout",
                "execution_state": "unknown",
                "request_id": "timed-out",
            }
        )
        result = await validate_project(
            bridge,
            BOARD,
            PROJECT,
            drc_report_path=self.write_drc(),
            output=str(self.root / "review"),
        )
        bridge.assert_awaited_once()
        self.assertEqual(
            [stage["status"] for stage in result["stages"]],
            ["error", "skipped", "skipped", "pass"],
        )
        report = json.loads(Path(result["report_path"]).read_text(encoding="utf-8"))
        self.assertEqual(report["stages"][0]["evidence"]["request_id"], "timed-out")

    async def test_stale_schematic_and_drc_coverage_change_are_reported(self):
        snapshot = write_snapshot(self.root / "snapshot")
        bridge = AsyncMock(
            return_value={
                "success": True,
                "result": {
                    "success": False,
                    "code": "schematic_not_validated",
                    "error": "Validate in Altium.",
                },
            }
        )
        result = await validate_project(
            bridge,
            BOARD,
            PROJECT,
            snapshot_directory=snapshot["directory"],
            drc_report_path=self.write_drc(),
            baseline_drc_report_path=self.write_drc(
                "baseline.drc", rule="Width Constraint"
            ),
            output=str(self.root / "review"),
        )
        self.assertEqual(result["verdict"], "fail")
        self.assertEqual(
            [stage["status"] for stage in result["stages"]],
            ["skipped", "pass", "skipped", "fail"],
        )
        self.assertEqual(result["stages"][3]["counts"]["violations"], 0)

    async def test_drc_cannot_match_by_basename(self):
        snapshot = write_snapshot(self.root / "snapshot")
        bridge = AsyncMock()
        result = await validate_project(
            bridge,
            BOARD,
            snapshot_directory=snapshot["directory"],
            drc_report_path=self.write_drc(board=r"D:\Another\Example.PcbDoc"),
            output=str(self.root / "review"),
        )
        bridge.assert_not_awaited()
        self.assertEqual(result["stages"][3]["status"], "error")
        self.assertIn("expected board", result["stages"][3]["summary"])

    async def test_invalid_request_cannot_reach_native_commands_or_create_a_report(
        self,
    ):
        bridge = AsyncMock()
        output = self.root / "review"
        with self.assertRaisesRegex(ValueError, "no pipe"):
            await validate_project(
                bridge, BOARD, r"D:\Boards\Project|APPLY.PrjPcb", output=str(output)
            )
        with self.assertRaisesRegex(ValueError, "requires a current"):
            await validate_project(
                bridge,
                BOARD,
                baseline_drc_report_path="baseline.drc",
                output=str(output),
            )
        bridge.assert_not_awaited()
        self.assertFalse(output.exists())
