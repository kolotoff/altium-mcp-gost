import importlib.util
import json
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

from tools.crop_native_pcb_3d_export import svg_component_pixels
from tools.generate_board_test_maps import build_page, component_positions, pad_positions, qname, qualifying_pins
from tools.pcb_3d_registration import CameraRegistration


class TestMapMountingHoleTests(unittest.TestCase):
    def test_both_maps_exclude_holes_not_wholly_inside_outline(self):
        assembly = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 4">'
            '<g id="BoardShape">'
            '<path id="BoardOutline" d="M 0 0 L 20 0 L 20 4 L 0 4 Z"/>'
            '<g id="StandaloneMountingPads">'
            '<circle id="inside" cx="2" cy="2" r="0.5"/>'
            '<circle id="crossing" cx="0.2" cy="2" r="0.5"/>'
            '<circle id="panel" cx="21" cy="2" r="0.5"/>'
            '</g></g><g id="Pads" data-layer="pads"/>'
            '</svg>'
        )
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "assembly.svg"
            source.write_text(assembly, encoding="utf-8")
            for side in ("top", "bottom"):
                output = Path(directory) / f"{side}.svg"
                build_page({"components": []}, source, output, side=side)
                root = ET.parse(output).getroot()
                group = next(element for element in root.iter() if element.get("id") == "StandaloneMountingPads")
                holes = [element.get("id") for element in group if element.tag == qname("circle")]
                self.assertEqual(["inside"], holes)
                self.assertFalse(any(element.get("id") == "Pads" for element in root.iter()))


class PanelizedDesignatorTests(unittest.TestCase):
    def test_bottom_pad_applies_component_mirror_before_board_mirror(self):
        root = ET.fromstring(
            '<svg><g id="component-TP-pads" data-component="TP" '
            'transform="translate(10 10) rotate(0) scale(1 -1)">'
            '<path data-pad-number="1" d="M 1 2 L 3 2 L 3 4 L 1 4 Z"/>'
            '</g></svg>'
        )
        pads = pad_positions(root, bottom=True, view_x=0, view_y=-20, view_width=30)
        self.assertEqual((18.0, 13.0), pads[("TP", "1")])

    def test_panel_instances_are_available_by_logical_designator(self):
        source = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -20 40 20">'
            '<g id="component-TP-assembly" data-component="TP" data-instance="TP" transform="translate(5 5)"/>'
            '<g id="component-TP-2-pads" data-component="TP" data-instance="TP-2" transform="translate(15 5) rotate(0)">'
            '<path data-pad-number="1" d="M -1 -1 L 1 -1 L 1 1 L -1 1 Z"/>'
            '</g></svg>'
        )
        root = ET.fromstring(source)
        positions = component_positions(root, bottom=False, view_x=0, view_y=-20, view_width=40)
        pads = pad_positions(root, bottom=False, view_x=0, view_y=-20, view_width=40)
        self.assertEqual((5.0, 15.0), positions["TP_1"])
        self.assertEqual((15.0, 15.0), positions["TP_2"])
        self.assertEqual((15.0, 15.0), pads[("TP_2", "1")])

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "assembly.svg"
            path.write_text(source, encoding="utf-8")
            pixels = svg_component_pixels(path, (400, 200), bottom=False)
            self.assertEqual((50.0, 150.0), pixels["TP_1"])
            self.assertEqual((150.0, 150.0), pixels["TP_2"])

            registered = svg_component_pixels(
                path,
                (440, 200),
                bottom=False,
                registration=CameraRegistration(-2, 42, 0, 20, False, 440, 200),
            )
            self.assertEqual((70.0, 150.0), registered["TP_1"])
            self.assertEqual((170.0, 150.0), registered["TP_2"])

            mirrored = svg_component_pixels(
                path,
                (440, 200),
                bottom=True,
                registration=CameraRegistration(-2, 42, 0, 20, True, 440, 200),
            )
            self.assertEqual((370.0, 150.0), mirrored["TP_1"])
            self.assertEqual((270.0, 150.0), mirrored["TP_2"])


class TestInventoryQualification(unittest.TestCase):
    def test_map_uses_exact_physical_pad_qualification_from_inventory(self):
        script = (Path(__file__).resolve().parents[2] / "skills" / "create-board-test-description"
                  / "scripts" / "prepare_test_inventory.py")
        spec = importlib.util.spec_from_file_location("prepare_test_inventory", script)
        inventory_builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(inventory_builder)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            components, pins, inventory = (root / name for name in ("components.json", "pins.json", "inventory.json"))
            components.write_text(json.dumps([{"designator": "SB1", "footprint": "Bridge"}]))
            pins.write_text(json.dumps([{"designator": "SB1", "pins": [
                {"name": "1", "net": "GND", "hole_size": 1.2 / 0.0254},
                {"name": "2", "net": "GND", "hole_size": 0.9996 / 0.0254},
                {"name": "3", "net": "", "hole_size": 1.5 / 0.0254},
                {"name": "1", "net": "GND", "hole_size": 0.0},
            ]}]))
            with patch.object(sys, "argv", [
                str(script), "--components", str(components), "--pins", str(pins),
                "--minimum-hole-mm", "1.1", "--output", str(inventory),
            ]):
                self.assertEqual(inventory_builder.main(), 0)
            item = json.loads(inventory.read_text(encoding="utf-8"))["components"][0]
            self.assertEqual(["1"], item["qualifying_pad_ids"])
            self.assertEqual(1.0, item["pins"][1]["hole_mm"])
            self.assertEqual("NC", item["pins"][2]["pcb_net"])
            self.assertEqual([item["pins"][0]], qualifying_pins(item, 1.0))

    def test_map_supports_inventories_with_only_qualifying_ids(self):
        item = {"qualifying_pad_ids": ["2"], "pins": [
            {"pad": "1", "pcb_net": "GND", "hole_mm": 1.0},
            {"pad": "2", "pcb_net": "GND", "hole_mm": 1.0},
        ]}
        self.assertEqual([item["pins"][1]], qualifying_pins(item, 1.0))

    def test_legacy_map_skips_nc_and_honors_inventory_threshold(self):
        item = {"pins": [
            {"pad": "1", "pcb_net": "GND", "hole_mm": 1.0},
            {"pad": "2", "pcb_net": "GND", "hole_mm": 1.5},
            {"pad": "3", "pcb_net": "NC", "hole_mm": 1.5},
        ]}
        self.assertEqual(["2"], [pin["pad"] for pin in qualifying_pins(item, 1.25)])


if __name__ == "__main__":
    unittest.main()
