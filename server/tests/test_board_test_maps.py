import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from tools.crop_native_pcb_3d_export import svg_component_pixels
from tools.generate_board_test_maps import build_page, component_positions, pad_positions, qname
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


if __name__ == "__main__":
    unittest.main()
