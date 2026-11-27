import json
import unittest

from server.signal_routing import measure_paths, plan_length_match, plan_pair
from server.signal_clearance import SignalClearance


UNIT = 10000
MIL = 0.0254


def area(x1, y1, x2, y2):
    return [value * UNIT for value in (x1, y1, x2, y2)]


def track(net, x1, y1, x2, y2, width=4):
    return dict(zip(("x1_raw", "y1_raw", "x2_raw", "y2_raw"), area(x1, y1, x2, y2)),
                net=net, layer_id=1, width_raw=width * UNIT)


def fixture():
    coordinates = {"P": [(20, 45), (180, 45)], "N": [(20, 57), (180, 57)],
                   "REF": [(20, 88), (190, 88)], "OBSTACLE": []}
    return {
        "board": {
            "internal_units_per_mil": str(UNIT),
            "differential_pairs_json": json.dumps([["PAIR", "P", "N"]]),
            "outline_raw": ";".join(f"0,{x * UNIT},{y * UNIT}" for x, y in
                                    ((0, 0), (200, 0), (200, 120), (0, 120))),
        },
        "tables": {
            "nets": [{"net": net} for net in coordinates], "tracks": [],
            "layers": [{"stack_index": "1", "layer_id": "1"}],
            "arcs": [], "vias": [], "polygons": [],
            "pads": [dict(net=net, x_raw=x * UNIT, y_raw=y * UNIT, layer_id=1,
                          rotation_degrees=0, top_x_size_raw=4 * UNIT, top_y_size_raw=4 * UNIT)
                     for net, points in coordinates.items() for x, y in points],
        },
    }


def multilayer_fixture():
    snapshot = fixture()
    snapshot["tables"]["layers"].append({"stack_index": "2", "layer_id": "32"})
    snapshot["board"]["copper_depths_raw"] = f"1,0;32,{5 * UNIT}"
    return snapshot


def install_plan(snapshot, plan):
    for operation in plan["operations"]:
        table = snapshot["tables"][operation["kind"] + "s"]
        if operation["action"] == "edit":
            table.remove(operation["old"])
        table.append(operation["new"])


class SignalRoutingTest(unittest.TestCase):
    def pair(self, snapshot, corridor=None):
        return plan_pair(snapshot, "PAIR", 1, 4 * MIL, 8 * MIL,
                         corridor or area(15, 12, 185, 100), 8 * MIL, 2 * MIL)

    def test_pair_straight_on_exact_clearance_and_equal_length(self):
        snapshot = fixture()
        result = self.pair(snapshot)
        self.assertEqual(len(result["operations"]), 2)
        self.assertAlmostEqual(result["minimum_track_gap_mm"], 8 * MIL)
        snapshot["tables"]["tracks"] = [op["new"] for op in result["operations"]]
        report = measure_paths(snapshot, ["P", "N"])
        self.assertEqual(report["differential_pairs"][0]["skew_mm"], 0)
        self.assertAlmostEqual(report["paths"]["P"]["length_mm"], 160 * MIL)

    def test_pair_detours_as_one_and_routing_fails_in_tight_corridor(self):
        snapshot = fixture()
        snapshot["tables"]["tracks"].append(track("OBSTACLE", 94, 35, 94, 62))
        result = self.pair(snapshot)
        self.assertNotEqual(result["detour_mm"], 0)
        self.assertAlmostEqual(result["minimum_track_gap_mm"], 8 * MIL, places=6)
        with self.assertRaisesRegex(ValueError, "No straight or paired"):
            self.pair(snapshot, area(15, 38, 185, 64))
        snapshot["tables"]["tracks"] += [op["new"] for op in result["operations"]]
        self.assertAlmostEqual(measure_paths(snapshot, ["P", "N"])["differential_pairs"][0]["skew_mm"], 0)

    def test_tuning_preserves_endpoints_and_matches_longest_path(self):
        snapshot = fixture()
        tracks = snapshot["tables"]["tracks"]
        tracks.extend([track("P", 20, 45, 180, 45), track("N", 20, 57, 180, 57),
                       track("REF", 20, 88, 190, 88)])
        plan = plan_length_match(snapshot, ["P", "REF"], {"P": area(15, 15, 185, 50)},
                                 0.001, 7 * MIL, None, 2 * MIL)
        self.assertEqual([op["action"] for op in plan["operations"]], ["edit"] + ["add"] * 4)
        tracks.remove(plan["operations"][0]["old"])
        tracks.extend(op["new"] for op in plan["operations"])
        self.assertAlmostEqual(measure_paths(snapshot, ["P", "REF"])["paths"]["P"]["length_mm"],
                               170 * MIL, places=5)

    def test_rejects_partial_routing_branch_and_collinear_retrace(self):
        snapshot = fixture()
        tracks = snapshot["tables"]["tracks"]
        tracks.append(track("P", 20, 45, 100, 45))
        self.assertEqual(measure_paths(snapshot, ["P"])["paths"]["P"]["status"], "unsupported")
        tracks.extend([track("P", 100, 45, 180, 45), track("P", 100, 45, 100, 80)])
        self.assertIn("branched", measure_paths(snapshot, ["P"])["paths"]["P"]["reason"])
        tracks[:] = [track("P", 20, 45, 185, 45), track("P", 185, 45, 180, 45)]
        self.assertIn("retrace", measure_paths(snapshot, ["P"])["paths"]["P"]["reason"])

    def test_refuses_outside_board_and_different_pair_pitch(self):
        snapshot = fixture()
        snapshot["board"]["outline_raw"] = "0,0,0;0,1000000,0;0,1000000,1200000;0,0,1200000"
        with self.assertRaisesRegex(ValueError, "No straight or paired"):
            self.pair(snapshot)
        snapshot["tables"]["pads"][3]["y_raw"] += UNIT
        with self.assertRaisesRegex(ValueError, "equal pad pitch"):
            self.pair(snapshot)

    def test_paired_transitions_detour_around_obstacles_on_both_layers(self):
        snapshot = multilayer_fixture()
        tracks = snapshot["tables"]["tracks"]
        tracks.extend([track("OBSTACLE", 100, 11, 100, 101),
                       {**track("OBSTACLE", 100, 11, 100, 55), "layer_id": 32}])
        # Keep the unrelated reference pads off this test's routing corridor.
        snapshot["tables"]["pads"] = [row for row in snapshot["tables"]["pads"] if row["net"] != "REF"]
        with self.assertRaisesRegex(ValueError, "No straight or paired"):
            self.pair(snapshot)
        result = plan_pair(snapshot, "PAIR", 1, 4 * MIL, 8 * MIL, area(15, 12, 185, 100),
                           8 * MIL, 2 * MIL, [1, 32], 10 * MIL, 4 * MIL)
        self.assertEqual(result["layer_ids"], [1, 32, 1])
        self.assertEqual(result["via_count"], 4)
        self.assertNotEqual(result["detour_mm"], 0)
        vias = [op["new"] for op in result["operations"] if op["kind"] == "via"]
        for left, right in zip(vias[::2], vias[1::2]):
            self.assertEqual(left["x_raw"], right["x_raw"])
            self.assertGreaterEqual(abs(left["y_raw"] - right["y_raw"]), 18 * UNIT)
        install_plan(snapshot, result)
        measured = measure_paths(snapshot, ["P", "N"])
        self.assertAlmostEqual(measured["differential_pairs"][0]["skew_mm"], 0)
        for path in measured["paths"].values():
            self.assertAlmostEqual(path["via_length_mm"], 10 * MIL)
            self.assertAlmostEqual(path["length_mm"], result["planned_length_mm_each"])

    def test_changes_layer_for_bottom_launch_and_refuses_unknown_depths(self):
        snapshot = multilayer_fixture()
        for row in snapshot["tables"]["pads"]:
            if row["net"] in {"P", "N"} and row["x_raw"] == 180 * UNIT:
                row["layer_id"] = 32
        args = (snapshot, "PAIR", 1, 4 * MIL, 8 * MIL, area(15, 30, 185, 75),
                8 * MIL, 2 * MIL, [1, 32], 10 * MIL, 4 * MIL)
        self.assertEqual(plan_pair(*args)["layer_ids"], [1, 32])
        del snapshot["board"]["copper_depths_raw"]
        with self.assertRaisesRegex(ValueError, "fresh snapshot"):
            plan_pair(*args)

    def test_through_via_uses_clearance_on_nonrouting_layer_and_at_same_net_drills(self):
        snapshot = multilayer_fixture()
        snapshot["tables"]["layers"].append({"stack_index": "2", "layer_id": "2"})
        snapshot["tables"]["layers"][-2]["stack_index"] = "3"
        outline = [(x * UNIT, y * UNIT) for x, y in ((0, 0), (200, 0), (200, 120), (0, 120))]
        via = {"net": "P", "x_raw": 80 * UNIT, "y_raw": 65 * UNIT, "size_raw": 8 * UNIT,
               "hole_size_raw": 4 * UNIT, "low_layer_id": 1, "high_layer_id": 32}

        def clears():
            return SignalClearance(snapshot, area(15, 10, 185, 110), outline,
                                   5 * UNIT, 2 * UNIT, 12 * UNIT).clears([], [via])

        self.assertTrue(clears())
        snapshot["tables"]["tracks"].append({**track("OBSTACLE", 75, 65, 85, 65), "layer_id": 2})
        self.assertFalse(clears())
        snapshot["tables"]["tracks"].clear()
        snapshot["tables"]["vias"].append({**via, "x_raw": 95 * UNIT})
        self.assertFalse(clears())

    def test_corridor_corners_do_not_hide_a_notch_or_an_edge_clearance_failure(self):
        snapshot = fixture()
        notch = [(x * UNIT, y * UNIT) for x, y in (
            (0, 0), (200, 0), (200, 120), (100, 120), (100, 50), (90, 50), (90, 120), (0, 120)
        )]
        checker = SignalClearance(snapshot, area(10, 10, 190, 85), notch, 2 * UNIT, 4 * UNIT)
        self.assertFalse(checker.clears([track("P", 20, 70, 180, 70)]))
        self.assertFalse(checker.clears([track("P", 20, 45, 180, 45)]))
        self.assertTrue(checker.clears([track("P", 20, 35, 180, 35)]))

    def test_mask_screening_widens_pair_and_moves_vias_away_from_launch_pads(self):
        snapshot = multilayer_fixture()
        for row in snapshot["tables"]["pads"]:
            if row["net"] in {"P", "N"} and row["x_raw"] == 180 * UNIT:
                row["layer_id"] = 32
        args = (snapshot, "PAIR", 1, 4 * MIL, 8 * MIL, area(15, 25, 185, 80),
                2 * MIL, 2 * MIL, [1, 32], 10 * MIL, 4 * MIL)
        original = [row["new"] for row in plan_pair(*args)["operations"] if row["kind"] == "via"]
        screened = [row["new"] for row in plan_pair(
            *args, mask_expansion_mm=4 * MIL, min_mask_sliver_mm=10 * MIL
        )["operations"] if row["kind"] == "via"]
        self.assertGreaterEqual(abs(screened[0]["y_raw"] - screened[1]["y_raw"]), 28 * UNIT)
        self.assertLess(screened[0]["x_raw"], original[0]["x_raw"])

    def test_coupled_length_matching_accounts_for_vias_and_keeps_both_rails(self):
        snapshot = multilayer_fixture()
        tables = snapshot["tables"]
        for row in tables["pads"]:
            if row["net"] in {"P", "N"} and row["x_raw"] == 180 * UNIT:
                row["layer_id"] = 32
        # Use a remote same-layer reference pair longer than the layered pair.
        tables["pads"][:] = [row for row in tables["pads"] if row["net"] != "REF"]
        pad = tables["pads"][0]
        for net, y in (("RP", 100), ("RN", 112)):
            tables["nets"].append({"net": net})
            tables["pads"].extend({**pad, "net": net, "x_raw": x * UNIT, "y_raw": y * UNIT}
                                  for x in (10, 185))
            tables["tracks"].append(track(net, 10, y, 185, y))
        snapshot["board"]["differential_pairs_json"] = json.dumps([["PAIR", "P", "N"], ["R", "RP", "RN"]])
        routed = plan_pair(snapshot, "PAIR", 1, 4 * MIL, 8 * MIL, area(15, 20, 185, 90),
                           8 * MIL, 2 * MIL, [1, 32], 10 * MIL, 4 * MIL)
        install_plan(snapshot, routed)
        vias = list(tables["vias"])
        before = measure_paths(snapshot, ["P", "N", "RP", "RN"])
        plan = plan_length_match(snapshot, None, {"PAIR": area(15, 15, 185, 90)}, 0.001,
                                 8 * MIL, None, 2 * MIL, pairs=["PAIR", "R"])
        self.assertEqual({op["new"]["net"] for op in plan["operations"]}, {"P", "N"})
        self.assertEqual({op["kind"] for op in plan["operations"]}, {"track"})
        install_plan(snapshot, plan)
        after = measure_paths(snapshot, ["P", "N", "RP", "RN"])
        self.assertEqual(tables["vias"], vias)
        self.assertAlmostEqual(after["paths"]["P"]["via_length_mm"], before["paths"]["P"]["via_length_mm"])
        self.assertLess(abs(after["paths"]["P"]["length_mm"] - after["paths"]["RP"]["length_mm"]), 0.001)
        self.assertAlmostEqual(after["differential_pairs"][0]["skew_mm"], 0)
