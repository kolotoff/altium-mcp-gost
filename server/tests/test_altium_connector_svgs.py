import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from tools.generate_altium_connector_svgs import generate_one


class NativeConnectorSvgTests(unittest.TestCase):
    def test_missing_native_geometry_fails_instead_of_drawing_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            item = {
                "designator": "X1", "pins": [{"pin": "1", "net": "GND"}],
                "body_style": "jst-gh",
            }
            with self.assertRaisesRegex(ValueError, "native connector SVG missing"):
                generate_one(item, folder / "X1.svg", folder / "out.svg", [])
            self.assertFalse((folder / "out.svg").exists())

    def test_pad_only_contact_uses_board_pad_path(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            board = folder / "board.svg"
            board.write_text(
                '<svg xmlns="http://www.w3.org/2000/svg">'
                '<g id="component-X7-pads" data-component="X7">'
                '<path data-pad-number="1" d="M 0 0 L 2 0 L 2 2 L 0 2 Z"/>'
                '</g></svg>', encoding="utf-8"
            )
            item = {
                "designator": "X7", "pins": [{"pin": "1", "net": "GND"}],
                "body_style": "keystone",
            }
            output = folder / "out.svg"
            generate_one(item, folder / "X7.svg", output, [board])
            root = ET.parse(output).getroot()
            self.assertEqual("altium-board-pad-svg", root.get("data-native-geometry"))
            self.assertTrue(any(e.get("d") == "M 0 0 L 2 0 L 2 2 L 0 2 Z" for e in root.iter()))
