"""Offline integration checks; no test invokes or modifies Altium."""

import json
import tempfile
import unittest
import uuid
from copy import deepcopy
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server import pcb_routing as workflow
from server import routing_audit as audit
from server.routing_geometry import (
    audit_layer_usage,
    preview_clearance,
    segment_segment,
    via_on_layer,
)
from server.routing_operations import geometry, plan_batch, reconcile_batch
from tools.optional import checkpoints


def example_tables():
    return {
        "nets": [
            dict(
                net="Signal",
                pin_count="2",
                via_count="0",
                routed_length_raw="2000",
                connectivity_invalid="true",
                connections_visible="true",
            ),
            dict(
                net="GND",
                pin_count="1",
                via_count="1",
                routed_length_raw="0",
                connectivity_invalid="false",
                connections_visible="true",
            ),
        ],
        "pads": [
            dict(
                refdes="U1",
                pad="1",
                net="Signal",
                x_raw="1000",
                y_raw="2000",
                layer_id="1",
                layer="Top Layer",
                rotation_degrees="0",
                top_x_size_raw="300",
                top_y_size_raw="300",
                hole_size_raw="0",
                selected="false",
            )
        ],
        "tracks": [
            dict(
                net="Signal",
                x1_raw="1000",
                y1_raw="2000",
                x2_raw="3000",
                y2_raw="2000",
                width_raw="100",
                layer_id="1",
                layer="Top Layer",
                selected="false",
            )
        ],
        "vias": [
            dict(
                net="GND",
                x_raw="6000",
                y_raw="7000",
                size_raw="500",
                hole_size_raw="200",
                low_layer_id="1",
                high_layer_id="32",
                selected="false",
            )
        ],
        "connections": [],
        "rules": [],
        "arcs": [],
        "polygons": [],
        "components": [
            dict(
                refdes="U1",
                comment="CJK 测试, Кириллица",
                footprint="QFN",
                x_raw="1000",
                y_raw="2000",
                rotation_degrees="90",
                layer_id="1",
                layer="Top Layer",
            )
        ],
        "layers": [
            dict(
                stack_index=str(i + 1),
                layer_id=str(layer),
                layer_name=name,
                copper_thickness_raw="1000",
            )
            for i, (layer, name) in enumerate(
                [(1, "Top Layer"), (5, "Internal plane"), (32, "Bottom Layer")]
            )
        ],
    }


def write_snapshot(directory, tables=None, snapshot_id=None, seal=True):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    tables = deepcopy(tables or example_tables())
    snapshot_id = snapshot_id or uuid.uuid4().hex
    counts = {
        "net_count": len(tables["nets"]),
        "pad_count": len(tables["pads"]),
        "track_segment_count": len(tables["tracks"]),
        "via_count": len(tables["vias"]),
        "rule_count": len(tables["rules"]),
        "connection_object_count": len(tables["connections"]),
        "nonredundant_ratsnest_connections": sum(
            audit.remaining_edges(tables).values()
        ),
        "redundant_connection_objects": sum(
            r["redundant"] == "true" for r in tables["connections"]
        ),
        "connectivity_invalid_nets": sum(
            r["connectivity_invalid"] == "true" for r in tables["nets"]
        ),
    }
    counts.update({name + "_count": len(tables[name]) for name in audit.EXTRA_HEADERS})
    board = {
        "board_file": r"D:\Boards, shared\测试\Example.PcbDoc",
        "coordinate_units": "Altium internal units",
        "internal_units_per_mil": "10000",
        "x_origin_raw": "0",
        "y_origin_raw": "0",
        "field_encoding": "json-string",
        "snapshot_id": snapshot_id,
        **{k: str(v) for k, v in counts.items()},
    }
    tables["board"] = [dict(field=k, value=v) for k, v in board.items()]
    for name, header in {**audit.HEADERS, **audit.EXTRA_HEADERS}.items():
        fields = header.split()
        text = "\t".join(fields) + "\n"
        for row in tables[name]:
            text += (
                "\t".join(json.dumps(row[k], ensure_ascii=True)[1:-1] for k in fields)
                + "\n"
            )
        (directory / f"{name}.tsv").write_text(text, encoding="ascii")
    (directory / "inventory-status.txt").write_text("complete\n", encoding="ascii")
    (directory / "board-signature.txt").write_text(
        json.dumps(tables, sort_keys=True, ensure_ascii=True), encoding="ascii"
    )
    if seal:
        audit.seal_inventory(directory, snapshot_id)
        return audit.read_snapshot(directory)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_sealed_snapshot_roundtrips_unicode_and_detects_tampering(self):
        snapshot = write_snapshot(self.root / "before")
        self.assertEqual(
            "CJK 测试, Кириллица", snapshot["tables"]["components"][0]["comment"]
        )
        (self.root / "before/tracks.tsv").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "was changed"):
            audit.read_snapshot(self.root / "before")

    def test_inventory_rejects_duplicate_and_unknown_net_names(self):
        tables = example_tables()
        tables["nets"].append(dict(tables["nets"][0]))
        path = self.root / "duplicate"
        write_snapshot(path, tables, seal=False)
        with self.assertRaisesRegex(ValueError, "duplicate net name"):
            audit.read_inventory(path)

        tables["nets"].pop()
        tables["tracks"][0]["net"] = "signal"
        path = self.root / "unknown"
        write_snapshot(path, tables, seal=False)
        with self.assertRaisesRegex(ValueError, "Unknown net in tracks.tsv"):
            audit.read_inventory(path)

    def test_manifest_requires_all_tables_and_correct_generation(self):
        path = self.root / "before"
        write_snapshot(path, seal=False, snapshot_id="generation-one")
        with self.assertRaisesRegex(ValueError, "different snapshot generation"):
            audit.seal_inventory(path, "generation-two")
        (path / "polygons.tsv").unlink()
        with self.assertRaisesRegex(ValueError, "require component"):
            audit.seal_inventory(path, "generation-one")

    def test_json_string_fields_preserve_escapes_and_reject_raw_controls(self):
        path = self.root / "escaped"
        tables = example_tables()
        comment = 'Quoted "part" \\ TVS\tline\r\n\x01'
        tables["components"][0]["comment"] = comment
        snapshot = write_snapshot(path, tables)
        self.assertEqual(comment, snapshot["tables"]["components"][0]["comment"])
        components = path / "components.tsv"
        components.write_bytes(components.read_bytes().replace(b"\\u0001", b"\x01"))
        with self.assertRaisesRegex(ValueError, "Invalid control character"):
            audit.read_inventory(path)

    def test_components_layers_and_polygon_changes_are_visible(self):
        before = write_snapshot(self.root / "before")
        tables = example_tables()
        tables["components"][0]["rotation_degrees"] = "180"
        after = write_snapshot(self.root / "after", tables)
        self.assertIn(
            "Immutable components records changed",
            audit.compare_snapshots(before, after)["regressions"],
        )
        self.assertFalse(
            audit.compare_snapshots(before, after, allow_placement_changes=True)[
                "regressions"
            ]
        )

    def test_intentional_width_change_requires_policy_and_exact_request(self):
        before = write_snapshot(self.root / "before")
        old = before["tables"]["tracks"][0]
        new = dict(old, width_raw="150")
        plan = plan_batch(before, [dict(kind="track", action="edit", old=old, new=new)])
        tables = example_tables()
        tables["tracks"][0]["width_raw"] = "150"
        after = write_snapshot(self.root / "after", tables)
        self.assertTrue(reconcile_batch(before, after, plan)["verified"])
        tables["vias"][0]["hole_size_raw"] = "210"
        unrelated = write_snapshot(self.root / "unrelated", tables)
        self.assertFalse(reconcile_batch(before, unrelated, plan)["verified"])

    def test_batch_expected_inventory_copies_rows_and_preserves_shared_references(self):
        before = write_snapshot(self.root / "before")
        track = before["tables"]["tracks"][0]
        pad = before["tables"]["pads"][0]
        via = before["tables"]["vias"][0]
        via["metadata"] = {"labels": ["original"]}
        before["metadata"] = {"pad": pad, "via": via}

        plan = plan_batch(before, [dict(kind="track", action="remove", old=track)])
        expected = plan["expected"]
        self.assertEqual(expected["tables"]["tracks"], [])
        self.assertEqual(before["tables"]["tracks"], [track])
        self.assertIs(expected["tables"]["pads"][0], expected["metadata"]["pad"])
        self.assertIs(expected["tables"]["vias"][0], expected["metadata"]["via"])

        expected["metadata"]["pad"]["net"] = "changed"
        expected["metadata"]["via"]["metadata"]["labels"].append("changed")
        self.assertNotEqual(pad["net"], "changed")
        self.assertEqual(via["metadata"]["labels"], ["original"])

    def test_duplicate_targets_unknown_nets_and_unqualified_via_spans_are_rejected(
        self,
    ):
        before = write_snapshot(self.root / "before")
        old = before["tables"]["tracks"][0]
        with self.assertRaisesRegex(ValueError, "targeted only once"):
            plan_batch(before, [dict(kind="track", action="remove", old=old)] * 2)
        with self.assertRaisesRegex(ValueError, "known assigned"):
            plan_batch(
                before, [dict(kind="track", action="add", new=dict(old, net="UNKNOWN"))]
            )
        via = dict(before["tables"]["vias"][0], x_raw="9000", high_layer_id="5")
        with self.assertRaisesRegex(ValueError, "through span"):
            plan_batch(before, [dict(kind="via", action="add", new=via)])

    def test_batch_matches_reversed_track_geometry_with_exact_net_identity(self):
        tables = example_tables()
        old = tables["tracks"][0]
        reversed_track = dict(
            old, x1_raw=old["x2_raw"], x2_raw=old["x1_raw"], net="GND"
        )
        tables["tracks"].append(reversed_track)
        # A track-only batch does not validate the geometry of unrelated vias.
        tables["vias"][0]["hole_size_raw"] = "0"
        before = write_snapshot(self.root / "cross-net", tables)
        remove = [dict(kind="track", action="remove", old=old)]
        result = plan_batch(before, remove)
        self.assertEqual(result["expected"]["tables"]["tracks"], [reversed_track])
        with self.assertRaisesRegex(ValueError, "Destination geometry is already occupied"):
            plan_batch(before, [dict(kind="track", action="edit", old=old, new=old)])

        reversed_track["net"] = old["net"]
        before = write_snapshot(self.root / "same-net", tables)
        with self.assertRaisesRegex(ValueError, "match exactly one snapshot record"):
            plan_batch(before, remove)

    def test_batch_rejects_unrequested_same_net_arc_removal(self):
        tables = example_tables()
        tables["arcs"] = [
            dict(
                net="Signal",
                x_raw="1000",
                y_raw="2000",
                radius_raw="500",
                start_angle="0",
                end_angle="90",
                width_raw="100",
                layer_id="1",
                selected="false",
            )
        ]
        before = write_snapshot(self.root / "before", tables)
        old = before["tables"]["tracks"][0]
        plan = plan_batch(
            before,
            [
                dict(
                    kind="track", action="edit", old=old, new=dict(old, width_raw="150")
                )
            ],
        )
        tables["tracks"][0]["width_raw"] = "150"
        tables["arcs"] = []
        after = write_snapshot(self.root / "after", tables)
        self.assertFalse(reconcile_batch(before, after, plan)["verified"])

    def test_offcenter_via_overlapping_pad_requires_same_net_allowance(self):
        before = write_snapshot(self.root / "before")
        via = dict(
            before["tables"]["vias"][0],
            net="Signal",
            x_raw="1050",
            y_raw="2000",
            size_raw="100",
            hole_size_raw="20",
        )
        operations = [dict(kind="via", action="add", new=via)]
        with self.assertRaisesRegex(ValueError, "Via in pad"):
            plan_batch(before, operations)
        self.assertEqual(
            1, len(plan_batch(before, operations, allow_via_in_pad=True)["operations"])
        )
        with self.assertRaisesRegex(ValueError, "Via in pad"):
            plan_batch(
                before,
                [dict(kind="via", action="add", new=dict(via, net="GND"))],
                allow_via_in_pad=True,
            )

    def test_reversed_endpoint_targets_are_identical(self):
        row = example_tables()["tracks"][0]
        reverse = dict(row, x1_raw=row["x2_raw"], x2_raw=row["x1_raw"])
        self.assertEqual(geometry("track", row), geometry("track", reverse))
        self.assertEqual(0, segment_segment((0, 0), (4, 0), (1, 0), (5, 0)))

    def test_preview_uses_physical_stack_order_and_explicit_layer_policy(self):
        snapshot = write_snapshot(self.root / "before")
        self.assertTrue(
            via_on_layer(snapshot["tables"]["vias"][0], 5, {1: 0, 5: 1, 32: 2})
        )
        candidate = dict(
            net="Signal",
            layer_id=1,
            x1_raw=6000,
            y1_raw=6000,
            x2_raw=6000,
            y2_raw=8000,
            width_raw=100,
        )
        result = preview_clearance(snapshot, [candidate], 0)
        self.assertGreater(result["modeled_conflict_count"], 0)
        self.assertTrue(result["native_drc_required"])
        with self.assertRaisesRegex(ValueError, "explicit allowed_nets"):
            audit_layer_usage(snapshot, [dict(layer_id=1, role="ground")])
        result = audit_layer_usage(
            snapshot, [dict(layer_id=1, role="ground", allowed_nets=["GND"])]
        )
        self.assertFalse(result["passed_policy"])
        self.assertEqual("Signal", result["violations"][0]["record"]["net"])

    def test_outputs_cannot_escape_generated(self):
        with patch.object(workflow, "GENERATED", self.root / "generated"):
            with self.assertRaises(ValueError):
                workflow.output_directory(str(self.root / "elsewhere"))

    def test_placement_policy_never_silently_allows_pad_net_reassignment(self):
        before = write_snapshot(self.root / "before")
        tables = example_tables()
        tables["pads"][0]["net"] = "GND"
        after = write_snapshot(self.root / "after", tables)
        result = audit.compare_snapshots(before, after, allow_placement_changes=True)
        self.assertIn(
            "Pad identities, net assignments or dimensions changed",
            result["regressions"],
        )

    def test_new_via_at_pad_requires_explicit_same_net_allowance(self):
        before = write_snapshot(self.root / "before")
        via = dict(
            before["tables"]["vias"][0], net="Signal", x_raw="1000", y_raw="2000"
        )
        operations = [dict(kind="via", action="add", new=via)]
        with self.assertRaisesRegex(ValueError, "Via in pad"):
            plan_batch(before, operations)
        plan = plan_batch(before, operations, allow_via_in_pad=True)
        self.assertEqual(1, len(plan["operations"]))

    def test_drc_comparison_rejects_new_timing_occurrences_and_checks_identity(self):
        def report(finding):
            return "\n".join(
                [
                    r"PCB File : D:\Boards\Example.PcbDoc",
                    "Date : 2026-11-04",
                    "Time : 10:00",
                    "Processing Rule : Delay Constraint (Max=100ps)",
                    *(
                        []
                        if not finding
                        else [
                            "   Violation between Net X Actual Propagation Delay = 120ps"
                        ]
                    ),
                    f"Rule Violations : {int(finding)}",
                    f"Violations Detected : {int(finding)}",
                    "Waived Violations : 0",
                ]
            )

        baseline, current = self.root / "before.drc", self.root / "after.drc"
        baseline.write_text(report(False))
        current.write_text(report(True))
        result = audit.compare_drc_reports(baseline, current)
        self.assertFalse(result["passed"])
        self.assertEqual("Delay", result["rejected_added_findings"][0]["category"])
        with self.assertRaisesRegex(ValueError, "expected PCB"):
            audit.compare_drc_reports(baseline, current, r"D:\Other\Example.PcbDoc")


class WorkflowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.patch = patch.object(workflow, "GENERATED", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.before = write_snapshot(self.root / "before")

    async def test_undo_dry_run_does_not_touch_native_stack(self):
        native = AsyncMock()
        service = workflow.RoutingService(native)
        for steps in (0, 257, True):
            with self.assertRaises(ValueError):
                await service.undo(self.root / "before", steps)
        result = await service.undo(self.root / "before", 6)
        self.assertFalse(result["applied"])
        native.assert_not_awaited()

    async def test_undo_exports_actual_readback_on_the_bound_board(self):
        async def native(command, params):
            self.assertEqual("undo", params["operation"])
            self.assertEqual(
                self.before["board"]["board_file"], params["expected_board"]
            )
            self.assertEqual("6", params["steps"])
            write_snapshot(
                params["operation_directory"],
                example_tables(),
                params["snapshot_id"],
                seal=False,
            )
            return dict(success=True, result=dict(undo_requested=6))

        result = await workflow.RoutingService(native).undo(
            self.root / "before", 6, True
        )
        self.assertEqual(6, result["undo_requested"])
        self.assertFalse(result["saved"])
        self.assertTrue(
            audit.read_snapshot(Path(result["snapshot_directory"]))["manifest"]
        )

    async def test_polygon_readback_rejects_wrong_target_and_collateral_copper(self):
        vertices = [[0, 0], [100, 0], [100, 100], [0, 100]]
        for defect in (
            "none",
            "net",
            "layer",
            "arc_segment",
            "track",
            "arc",
            "settings",
        ):
            with self.subTest(defect=defect):

                async def native(command, params):
                    tables = example_tables()
                    segments = [
                        f"{1 if defect == 'arc_segment' else 0},{x},{y},0,0,0,0,0"
                        for x, y in vertices
                    ]
                    tables["polygons"] = [
                        dict(
                            name="P1",
                            net="Signal" if defect == "net" else "GND",
                            layer_id="32" if defect == "layer" else "1",
                            definition=(
                                "0,0,1,true,0,200000,10000,30000,false,true,250000000000,true,50000,5000"
                                if defect == "settings"
                                else "0,5,1,true,0,200000,10000,30000,false,true,250000000000,true,50000,5000"
                            )
                            + ";"
                            + ";".join(segments),
                        )
                    ]
                    if defect == "track":
                        tables["tracks"].append(dict(tables["tracks"][0], net="GND"))
                    if defect == "arc":
                        tables["arcs"] = [
                            dict(
                                net="GND",
                                x_raw="1000",
                                y_raw="2000",
                                radius_raw="500",
                                start_angle="0",
                                end_angle="90",
                                width_raw="100",
                                layer_id="1",
                                selected="false",
                            )
                        ]
                    write_snapshot(
                        params["operation_directory"],
                        tables,
                        params["snapshot_id"],
                        seal=False,
                    )
                    return dict(success=True, result=dict(applied=True))

                result = await workflow.RoutingService(native).polygon(
                    self.root / "before", "P1", "GND", 1, vertices, True
                )
                self.assertEqual(defect == "none", result["verified"])

    async def test_dry_run_never_sends_a_native_command(self):
        native = AsyncMock()
        service = workflow.RoutingService(native)
        old = self.before["tables"]["tracks"][0]
        result = await service.batch(
            self.root / "before", [dict(kind="track", action="remove", old=old)]
        )
        self.assertFalse(result["applied"])
        native.assert_not_awaited()

    async def test_live_batch_stages_only_sealed_native_float_values(self):
        baseline = self.root / "native-baseline"
        write_snapshot(baseline, snapshot_id="native", seal=False)
        source = baseline / audit.ROUTING_FLOAT_VALUES
        values = b"value\ttext\r\n268435456,0,0\t1\r\n"
        source.write_bytes(values)
        manifest = audit.seal_inventory(baseline, "native")
        self.assertIn(audit.ROUTING_FLOAT_VALUES, manifest["files"])

        async def native(command, params):
            self.assertEqual((command, params["operation"]), ("pcb_routing", "batch"))
            staged = Path(params["operation_directory"]) / f"baseline-{audit.ROUTING_FLOAT_VALUES}"
            self.assertEqual(staged.read_bytes(), values)
            return {"success": False, "error": "native test stub"}

        service = workflow.RoutingService(AsyncMock(side_effect=native))
        operations = [dict(kind="track", action="remove", old=self.before["tables"]["tracks"][0])]
        dry_run = await service.batch(baseline, operations)
        service.execute.assert_not_awaited()
        self.assertFalse((Path(dry_run["operation_directory"]) / f"baseline-{audit.ROUTING_FLOAT_VALUES}").exists())
        await service.batch(baseline, operations, apply=True)
        source.write_bytes(values.replace(b"\t1\r\n", b"\t2\r\n"))
        with self.assertRaisesRegex(ValueError, "Snapshot file was changed: routing-float-values.tsv"):
            await service.batch(baseline, operations, apply=True)
        service.execute.assert_awaited_once()

    async def test_apply_reconciles_readback_instead_of_trusting_native_success(self):
        old = self.before["tables"]["tracks"][0]
        new = dict(old, width_raw="150")

        async def native(command, params):
            tables = example_tables()  # Simulate a silently ignored write.
            write_snapshot(
                params["operation_directory"], tables, params["snapshot_id"], seal=False
            )
            return dict(success=True, result=dict(applied=True, completed_rows=1))

        result = await workflow.RoutingService(native).batch(
            self.root / "before",
            [dict(kind="track", action="edit", old=old, new=new)],
            True,
        )
        self.assertTrue(result["applied"])
        self.assertFalse(result["verified"])
        self.assertIn("tracks", result["geometry_mismatches"])

    async def test_timeout_keeps_progress_artifacts_and_never_replays(self):
        native = AsyncMock(
            return_value=dict(success=False, error="timeout", execution_state="unknown")
        )
        old = self.before["tables"]["tracks"][0]
        result = await workflow.RoutingService(native).batch(
            self.root / "before", [dict(kind="track", action="remove", old=old)], True
        )
        self.assertFalse(result["success"])
        self.assertEqual(1, native.await_count)
        self.assertTrue((Path(result["operation_directory"]) / "plan.json").exists())

    async def test_successful_apply_exports_a_new_verified_baseline(self):
        old = self.before["tables"]["tracks"][0]
        new = dict(old, width_raw="150")

        async def native(command, params):
            tables = example_tables()
            tables["tracks"][0]["width_raw"] = "150"
            write_snapshot(
                params["operation_directory"], tables, params["snapshot_id"], seal=False
            )
            return dict(success=True, result=dict(applied=True, completed_rows=1))

        result = await workflow.RoutingService(native).batch(
            self.root / "before",
            [dict(kind="track", action="edit", old=old, new=new)],
            True,
        )
        self.assertTrue(result["verified"])
        self.assertFalse(result["saved"])
        self.assertTrue(
            audit.read_snapshot(Path(result["snapshot_directory"]))["manifest"]
        )

    async def test_polygon_dry_run_rejects_self_intersection_and_preserves_source(self):
        service = workflow.RoutingService(AsyncMock())
        with self.assertRaisesRegex(ValueError, "self-intersects|nonzero area"):
            await service.polygon(
                self.root / "before",
                "P1",
                "GND",
                1,
                [[0, 0], [100, 100], [0, 100], [100, 0]],
            )
        result = await service.polygon(
            self.root / "before", "P1", "GND", 1, [[0, 0], [100, 0], [100, 100]]
        )
        self.assertFalse(result["applied"])


class CheckpointTests(unittest.TestCase):
    def test_default_copy_is_independent_and_manifest_detects_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "Board.PcbDoc").write_bytes(b"saved bytes")
            with patch.object(checkpoints, "GENERATED", root / "generated"):
                result = checkpoints.copy_checkpoint(
                    source, root / "generated/checkpoint"
                )
            self.assertEqual(0, result["shared_files"])
            (source / "Board.PcbDoc").write_bytes(b"changed source")
            self.assertEqual(
                b"saved bytes",
                (root / "generated/checkpoint/Board.PcbDoc").read_bytes(),
            )
            checkpoints.verify(root / "generated/checkpoint")
            (root / "generated/checkpoint/Board.PcbDoc").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "bytes changed"):
                checkpoints.verify(root / "generated/checkpoint")


if __name__ == "__main__":
    unittest.main()
