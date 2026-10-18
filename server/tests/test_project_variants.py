"""Protocol checks use a mocked bridge; they never open or edit Altium."""

import json
import unittest
from unittest.mock import AsyncMock, patch

from server import main


class ProjectVariantToolsTest(unittest.IsolatedAsyncioTestCase):
    async def test_copy_defaults_to_strict_dry_run(self):
        bridge = AsyncMock(return_value={"success": True, "result": {"applied": False}})
        with patch.object(main.altium_bridge, "execute_command", bridge):
            result = await main.copy_project_variant_materials(
                None, "SwarmRK_v1.6S", "MainRK_v1.6", "E1_MOUNT"
            )
        self.assertFalse(json.loads(result)["applied"])
        bridge.assert_awaited_once_with(
            "project_variant_maintenance",
            {"exclude_footprint_names": [], "layer_moves": [
                "PROJECT_VARIANT_MATERIALS|SwarmRK_v1.6S|MainRK_v1.6|E1_MOUNT|FALSE|DRY_RUN"
            ]},
        )

    async def test_explicit_apply_preserves_full_paths_and_missing_policy(self):
        source = r"D:\Boards, shared\Source board\Source.PrjPcb"
        target = r"D:\Boards\Целевая\Target.PrjPcb"
        bridge = AsyncMock(return_value={"success": True, "result": {"verified": True}})
        with patch.object(main.altium_bridge, "execute_command", bridge):
            result = await main.copy_project_variant_materials(
                None, source, target, "E1 MOUNT", allow_missing=True, apply=True
            )
        self.assertTrue(json.loads(result)["verified"])
        command = bridge.call_args.args[1]["layer_moves"][0]
        self.assertEqual(
            command, f"PROJECT_VARIANT_MATERIALS|{source}|{target}|E1 MOUNT|TRUE|APPLY"
        )

    async def test_invalid_fields_never_reach_altium(self):
        bridge = AsyncMock()
        with patch.object(main.altium_bridge, "execute_command", bridge):
            for value in ("", "   ", "Board|Other", "Board\nOther", 'Board"Other', "Board\rOther"):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    await main.get_project_variants(None, value)
                with self.subTest(value=value), self.assertRaises(ValueError):
                    await main.copy_project_variant_materials(None, "Source", "Target", value)
        bridge.assert_not_awaited()

    async def test_inspection_scopes_to_selected_project(self):
        bridge = AsyncMock(return_value={"success": True, "result": {"projects": []}})
        with patch.object(main.altium_bridge, "execute_command", bridge):
            await main.get_project_variants(None, "MainRK_v1.6")
        self.assertEqual(
            bridge.call_args.args[1]["layer_moves"], ["PROJECT_VARIANTS_INSPECT|MainRK_v1.6"]
        )

    async def test_transport_error_is_not_reported_as_success(self):
        bridge = AsyncMock(return_value={"success": False, "error": "timeout"})
        with patch.object(main.altium_bridge, "execute_command", bridge):
            result = json.loads(await main.get_project_variants(None, "MainRK_v1.6"))
        self.assertEqual(result, {"success": False, "error": "timeout"})

    async def test_preflight_rejection_and_save_warning_are_preserved(self):
        for payload in (
            {"success": False, "error": "Base component mismatch: F1"},
            {"success": True, "verified": True, "target_modified": False,
             "save_state_warning": "Persistence is unconfirmed."},
        ):
            with self.subTest(payload=payload):
                bridge = AsyncMock(return_value={"success": True, "result": payload})
                with patch.object(main.altium_bridge, "execute_command", bridge):
                    result = await main.copy_project_variant_materials(None, "Source", "Target", "E1")
                self.assertEqual(json.loads(result), payload)


if __name__ == "__main__":
    unittest.main()
