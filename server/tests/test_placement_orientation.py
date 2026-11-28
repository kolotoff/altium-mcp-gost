"""Regression coverage for exact PCB orientation scoring."""
import json
import unittest
from unittest.mock import AsyncMock, patch

from server import main


class OrientationTests(unittest.IsolatedAsyncioTestCase):
    async def test_plane_threshold_excludes_every_pad_of_the_scored_component(self):
        component = {
            "designator": "C1", "x": 0, "y": 0,
            "rotation": 180, "layer": "Top Layer",
            "pins": [
                {"name": "1", "net": "SIG", "dx": -10, "dy": 0},
                {"name": "2", "net": "GND", "dx": 10, "dy": 0},
            ],
        }
        for other_count, metric in ((40, "net_airline_mils"), (41, "nearest_return_mils")):
            with self.subTest(other_count=other_count):
                pads = [
                    {"designator": "IC1", "net": "SIG", "x": -35, "y": 0},
                    {"designator": "C1", "net": "GND", "x": -10, "y": 0},
                    {"designator": "C1", "net": "GND", "x": 10, "y": 0},
                ]
                pads += [{"designator": "IC1", "net": "GND", "x": 35, "y": 0}
                         for _ in range(other_count)]
                with patch.object(main.altium_bridge, "execute_command", new=AsyncMock(side_effect=[
                    {"success": True, "result": [component]},
                    {"success": True, "result": {"pads": pads}},
                ])):
                    result = json.loads(await main.check_orientation(None, ["C1"]))
                self.assertEqual(result["checked_count"], 1)
                self.assertEqual(result["suggestion_count"], 1)
                suggestion, = result["suggestions"]
                self.assertEqual(suggestion["suggested_rotation"], 0)
                self.assertEqual(suggestion["improvement_mils"], 40)
                self.assertEqual(suggestion["current_pads"][1], {"pin": "2", "net": "GND", metric: 45})
                self.assertEqual(suggestion["suggested_pads"][1], {"pin": "2", "net": "GND", metric: 25})

    def test_plane_nearest_compares_true_distance_across_both_x_directions(self):
        pads = main._PlanePadIndex([
            ("C1", 0, 0), ("R1", 0, 100), ("R2", 1, 4), ("R3", -2, 0),
        ])
        self.assertEqual(pads.nearest_distance((0, 0), "C1"), 2)
