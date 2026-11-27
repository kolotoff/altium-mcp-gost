"""Unit tests for router (pure Python, no Altium needed).

Run from server/:  python -m unittest tests.test_router -v
"""
import json
import math
import os
import sys
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import router  # noqa: E402

TOP, BOT = "Top Layer", "Bottom Layer"


def board(area=(0, 0, 200, 100), layers=(TOP,), nets=("A",)):
    return router.Board(list(area), 2.5, list(layers), 6, 6, 24, set(nets))


def segments(legs):
    return [(l, a, b) for l, pts in legs for a, b in zip(pts, pts[1:])]


def angle_ok(a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    return dx == 0 or dy == 0 or abs(abs(dx) - abs(dy)) < 1e-6


class ShapeTest(unittest.TestCase):
    def test_distances(self):
        seg = router.Shape("seg", "A", [TOP], ax=0, ay=0, bx=10, by=0, hw=3)
        self.assertAlmostEqual(seg.dist(5, 10), 7)
        rect = router.Shape("rect", "A", [TOP], cx=0, cy=0, hx=5, hy=2, cos=1, sin=0)
        self.assertAlmostEqual(rect.dist(8, 0), 3)
        self.assertEqual(rect.dist(1, 1), 0)
        rot = router.Shape("rect", "A", [TOP], cx=0, cy=0, hx=5, hy=2, cos=0, sin=1)   # turned 90 degrees
        self.assertAlmostEqual(rot.dist(0, 8), 3)
        poly = router.Shape("poly", "A", [TOP], pts=[(0, 0), (10, 0), (10, 10), (0, 10)])
        self.assertEqual(poly.dist(5, 5), 0)
        self.assertAlmostEqual(poly.dist(15, 5), 5)

    def test_shapes_from_layout(self):
        lay = {"pads": [{"designator": "U1", "pad": "1", "x": 10, "y": 10, "layer": "Multi Layer", "shape": "round",
                         "size": [60, 60], "rotation": 0, "hole": 35, "net": "GND"}],
               "vias": [{"net": "A", "x": 50, "y": 50, "diameter": 24, "hole": 12}],
               "arcs": [{"net": "B", "layer": TOP, "width": 6, "center": [0, 0], "radius": 20,
                         "start_angle": 0, "end_angle": 90}]}
        shapes = router.shapes_from_layout(lay, [TOP, BOT])
        self.assertEqual(shapes[0].layers, [TOP, BOT])   # a through-hole pad blocks every layer
        self.assertTrue(shapes[0].g.get("pad"))
        self.assertEqual([s.kind for s in shapes].count("seg"), len(shapes) - 2)

    def test_via_clearance_includes_rotated_inner_layer_fills(self):
        inner = "Mid Layer 1"
        b = board(layers=(TOP, inner, BOT), nets=("A", "B"))
        layout = {"fills": [{"net": "B", "layer": inner, "corner1": [80, 45],
                             "corner2": [120, 55], "rotation": 90}]}
        for shape in router.shapes_from_layout(layout, b.layers):
            b.add(shape)
        self.assertTrue(b.free(TOP, *b.cell(100, 85), b.id("A")))
        self.assertFalse(b.via_free(*b.cell(100, 85), b.id("A")))

    def test_via_clearance_includes_larger_layers_of_a_pad_stack(self):
        from pcb_layout import parse_layout

        b = board(layers=(TOP, BOT), nets=("A", "B"))
        layout = parse_layout(
            "P|J1|1|1000000|500000|Multi Layer|1|200000|200000|0|150000|B\n"
            "PB|600000|300000|1400000|700000"
        )
        self.assertEqual(layout["pads"][0]["size"], [20, 20])
        for shape in router.shapes_from_layout(layout, b.layers):
            b.add(shape)
        self.assertFalse(b.via_free(*b.cell(145, 50), b.id("A")))
        self.assertTrue(b.via_free(*b.cell(170, 50), b.id("A")))

    def test_via_clearance_includes_both_directions_of_curved_region_edges(self):
        inner = "Mid Layer 1"
        arc = {"center": [100, 50], "radius": 30, "start_angle": 270, "end_angle": 90}
        for y1, y2 in ((20, 80), (80, 20)):
            with self.subTest(start_y=y1):
                b = board(layers=(TOP, inner, BOT), nets=("A", "B"))
                outline = [{"x": 100, "y": y1, "arc": arc}, {"x": 100, "y": y2}]
                layout = {"regions": [{"net": "B", "layer": inner, "outline": outline}]}
                for shape in router.shapes_from_layout(layout, b.layers):
                    b.add(shape)
                self.assertFalse(b.via_free(*b.cell(125, 50), b.id("A")))
                self.assertTrue(b.via_free(*b.cell(75, 50), b.id("A")))


class RouteTest(unittest.TestCase):
    def test_hard_routing_bounds_include_trace_and_via_radii(self):
        board = router.Board([0, 0, 200, 100], 2.5, [TOP, BOT], 6, 6, 24, {"A"},
                             hard_bounds=[0, 0, 200, 100])
        self.assertIsNone(router.route_one(board, "A", (2, 20), (180, 20), [TOP], [TOP]))
        self.assertFalse(board.via_free(*board.cell(10, 20), board.id("A")))
        track = {"start": [10, 20], "end": [199, 20], "width": 6}
        self.assertFalse(board.fits_bounds([track], []))

    def test_occupied_destination_is_never_treated_as_free(self):
        grid = board()
        grid.add(router.Shape("circle", "B", [TOP], cx=120, cy=50, r=3))
        self.assertIsNone(router.route_one(grid, "A", (20, 50), (120, 50), [TOP], [TOP]))

    def test_straight(self):
        b = board()
        legs, vias = router.route_one(b, "A", (10, 50), (190, 50), [TOP], [TOP])
        self.assertEqual(vias, [])
        self.assertEqual(legs, [(TOP, [(10.0, 50.0), (190.0, 50.0)])])

    def test_goes_round_another_net_and_keeps_clearance(self):
        b = board(nets=("A", "B"))
        wall = router.Shape("seg", "B", [TOP], ax=100, ay=20, bx=100, by=100, hw=3)
        b.add(wall)
        legs, _ = router.route_one(b, "A", (20, 60), (180, 60), [TOP], [TOP])
        for _, a, c in segments(legs):
            self.assertTrue(angle_ok(a, c), (a, c))
            # every point of the centre line keeps clearance + half width from the wall
            for t in range(11):
                p = (a[0] + (c[0] - a[0]) * t / 10, a[1] + (c[1] - a[1]) * t / 10)
                self.assertGreaterEqual(wall.dist(*p), 6 + 3 - 1e-6)

    def test_own_net_copper_is_no_obstacle(self):
        b = board(nets=("A",))
        b.add(router.Shape("seg", "A", [TOP], ax=100, ay=0, bx=100, by=100, hw=3))
        legs, _ = router.route_one(b, "A", (10, 50), (190, 50), [TOP], [TOP])
        self.assertEqual(len(segments(legs)), 1)

    def test_changes_layer_through_a_via(self):
        b = board(layers=(TOP, BOT), nets=("A", "B"))
        b.add(router.Shape("seg", "B", [TOP], ax=100, ay=0, bx=100, by=100, hw=3))
        legs, vias = router.route_one(b, "A", (20, 50), (180, 50), [TOP], [TOP])
        self.assertEqual(len(vias), 2)
        self.assertEqual([l for l, _ in legs], [TOP, BOT, TOP])
        self.assertIsNone(router.route_one(
            b, "A", (20, 50), (180, 50), [TOP], [TOP], routing_layers=[TOP],
        ))

    def test_through_via_checks_laid_out_copper_on_an_excluded_layer(self):
        inner = "Mid Layer 1"
        b = board(layers=(TOP, inner, BOT), nets=("A", "B"))
        b.add(router.Shape("poly", "B", [inner], pts=[(0, 0), (200, 0), (200, 100), (0, 100)]))
        self.assertIsNone(router.route_one(
            b, "A", (20, 50), (180, 50), [TOP], [BOT], routing_layers=[TOP, BOT],
        ))

    def test_walled_in_fails(self):
        b = board(nets=("A", "B"))
        b.add(router.Shape("seg", "B", [TOP], ax=100, ay=-10, bx=100, by=110, hw=3))
        self.assertIsNone(router.route_one(b, "A", (20, 50), (180, 50), [TOP], [TOP]))

    def test_grid_size_is_limited(self):
        with self.assertRaises(router.RouteError):
            router.Board([0, 0, 10000, 10000], 2.5, [TOP], 6, 6, 24, {"A"})


class FanoutTest(unittest.TestCase):
    def test_via_goes_outward(self):
        b = board(area=(0, 0, 300, 300), layers=(TOP, BOT), nets=("GND",))
        pad = {"x": 150, "y": 150, "size": [10, 30], "net": "GND"}
        (vx, vy), legs = router.fanout_site(b, pad, "GND", 8, 24, 80, (100, 150), [TOP])
        self.assertGreater(vx, 150)
        self.assertAlmostEqual(vy, 150)
        self.assertEqual(legs, [(TOP, [(150, 150), (vx, vy)])])

    def test_large_pad_gets_its_via_inside(self):
        b = board(area=(0, 0, 300, 300), layers=(TOP, BOT), nets=("GND",))
        pad = {"x": 150, "y": 150, "size": [100, 100], "net": "GND"}
        (vx, vy), legs = router.fanout_site(b, pad, "GND", 8, 24, 80, (150, 150), [TOP])
        self.assertEqual(((vx, vy), legs), ((150, 150), []))

    def test_blocked_on_every_side(self):
        b = board(area=(0, 0, 300, 300), layers=(TOP, BOT), nets=("GND", "X"))
        b.add(router.Shape("circle", "X", [TOP, BOT], cx=150, cy=150, r=200))
        pad = {"x": 150, "y": 150, "size": [10, 10], "net": "GND"}
        self.assertIsNone(router.fanout_site(b, pad, "GND", 8, 24, 80, (100, 150), [TOP]))


class RouteConnectionsToolTest(unittest.IsolatedAsyncioTestCase):
    async def test_pair_members_are_skipped_before_obstacle_scan(self):
        import main

        connection = {"net": "P", "inside": True, "length": 25}
        with (patch.object(main, "get_unrouted_connections", new=AsyncMock(return_value=json.dumps(
                  {"success": True, "connections": [connection]}))),
              patch.object(main, "get_layout", new=AsyncMock()) as get_layout,
              patch.object(main, "_net_rules", new=AsyncMock(return_value={"P": {"paired": True}}))):
            reply = json.loads(await main.route_connections(None, nets=["P"], dry_run=True))
        self.assertEqual(reply["skipped_differential_pair_nets"], ["P"])
        get_layout.assert_not_awaited()

    async def test_tool_does_not_route_on_a_layer_seen_only_in_the_layout(self):
        import main

        start, end = [0, 0], [25, 0]
        connections = [{
            "net": "SIGNAL", "from": start, "to": end, "from_layer": TOP, "to_layer": TOP,
            "from_pad": "U1-1", "to_pad": "U2-1", "length": 25, "inside": True,
        }]
        layout = {"success": True, "pads": [], "arcs": [], "vias": [], "tracks": [
            {"layer": TOP, "net": "WALL", "width": 4, "start": [10, -200], "end": [10, 200]},
            {"layer": BOT, "net": "WALL", "width": 4, "start": [50, 50], "end": [55, 50]},
        ]}
        with (patch.object(main, "get_unrouted_connections", new=AsyncMock(return_value=json.dumps(
                  {"success": True, "connections": connections}))),
              patch.object(main, "get_layout", new=AsyncMock(return_value=json.dumps(layout))) as get_layout,
              patch.object(main, "_net_rules", new=AsyncMock(return_value={"SIGNAL": {"paired": False}}))):
            reply = json.loads(await main.route_connections(
                None, nets=["SIGNAL"], layers=[TOP], grid_mils=10, dry_run=True,
            ))
        self.assertTrue(reply["success"])
        self.assertEqual((reply["routed"], reply["track_list"], reply["via_list"]), (0, [], []))
        self.assertTrue(get_layout.await_args.kwargs["include_component_copper"])


if __name__ == "__main__":
    unittest.main()
