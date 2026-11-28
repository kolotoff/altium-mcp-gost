import json
import unittest
from unittest.mock import AsyncMock, patch

from server import main


class SchematicDataToolTest(unittest.IsolatedAsyncioTestCase):
    async def call(self, designators, payload, expected_filter, script_path=main.DEFAULT_SCRIPT_PATH):
        response = {"success": True, "result": payload}
        bridge = AsyncMock(return_value=response)
        with patch.object(main.altium_bridge, "execute_command", bridge), patch.object(
            main.altium_bridge.config, "script_path", str(script_path)
        ):
            result = await main.get_schematic_data(None, designators)
        bridge.assert_awaited_once_with("get_schematic_data", expected_filter)
        return json.loads(result)

    async def test_preserves_first_match_and_request_order_from_either_bridge(self):
        first = {"designator": "R1", "sheet": "first.SchDoc", "parameters": {"Value": "3.3"}}
        second = {"designator": "R1", "sheet": "second.SchDoc"}
        capacitor = {"designator": "C2", "sheet": "late.SchDoc"}
        rows = [first, second, capacitor]
        request = ["C2", "R1", "r1", "R1", "missing"]
        for payload in ({"has_components": True, "components": rows}, rows, json.dumps(rows)):
            with self.subTest(payload=payload):
                result = await self.call(request, payload, {"filter_designators": request})
                self.assertEqual(result, {"components": [capacitor, first, first],
                                          "missing_designators": ["r1", "missing"]})

    async def test_distinguishes_missing_designator_from_empty_project(self):
        request = ["missing"]
        params = {"filter_designators": request}
        empty = await self.call(request, {"has_components": False, "components": []}, params)
        missing = await self.call(request, {"has_components": True, "components": []}, params)
        self.assertEqual(empty, {"error": "No schematic data found"})
        self.assertEqual(missing, {"components": [], "missing_designators": request})

    async def test_legacy_scan_for_empty_or_unrepresentable_entries(self):
        normal = {"designator": "R1"}
        empty = {"designator": ""}
        unicode = {"designator": "Ö1"}
        rows = [normal, empty, unicode]
        for value, match in (("", empty), ("Ö1", unicode), ("R1\n", None), (0, None), (None, None), ([], None)):
            with self.subTest(value=value):
                result = await self.call(["R1", value], rows, {})
                expected = {"components": [normal, match]} if match else {"components": [normal], "missing_designators": [value]}
                self.assertEqual(result, expected)
        self.assertEqual(await self.call([], rows, {}), {"components": []})
        self.assertEqual(await self.call([], [], {}), {"error": "No schematic data found"})

    async def test_custom_bridge_receives_original_request_shape(self):
        rows = [{"designator": "R1", "sheet": "legacy.SchDoc"}]
        result = await self.call(["R1"], rows, {}, script_path="Custom.Altium_API.PrjScr")
        self.assertEqual(result, {"components": rows})
