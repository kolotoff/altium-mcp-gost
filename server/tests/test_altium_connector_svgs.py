import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from tools.generate_altium_connector_svgs import distribute, generate_one


class NativeConnectorSvgTests(unittest.TestCase):
    def test_crowded_contact_row_fans_out_symmetrically(self):
        pins = [{"anchor_y": 11.5 + index * 2.4} for index in range(6)]
        rows = distribute(pins, top=8.0, bottom=27.0, pitch=2.95)
        offsets = [y - pin["anchor_y"] for pin, y in rows]
        self.assertLess(offsets[0], 0)
        self.assertGreater(offsets[-1], 0)
        for first, last in zip(offsets, reversed(offsets)):
            self.assertAlmostEqual(first, -last)
        for (_, first), (_, second) in zip(rows, rows[1:]):
            self.assertAlmostEqual(second - first, 2.95)

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
            output = folder / "out.svg"
            for body_style in ("keystone", "jst-gh"):
                with self.subTest(body_style=body_style):
                    item = {"designator": "X7", "pins": [{"pin": "1", "net": "GND"}], "body_style": body_style}
                    generate_one(item, folder / "X7.svg", output, [board])
                    root = ET.parse(output).getroot()
                    self.assertEqual("altium-board-pad-svg", root.get("data-native-geometry"))
                    self.assertTrue(any(e.get("d") == "M 0 0 L 2 0 L 2 2 L 0 2 Z" for e in root.iter()))

    def test_installed_pad_anchors_and_body_share_uniform_scaling(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            board = folder / "board.svg"
            board.write_text(
                '<svg xmlns="http://www.w3.org/2000/svg"><g transform="scale(1,-1)">'
                '<g id="X1-assembly" data-component="X1" transform="translate(10 10) rotate(180)">'
                '<path d="M -2 -3 L 2 -3 L 2 3 L -2 3 Z"/></g>'
                '<g id="X1-pads" data-component="X1" transform="translate(10 10) rotate(180)">'
                '<path data-pad-number="1" d="M -1.5 -2 L -0.5 -2 L -0.5 -1 L -1.5 -1 Z"/>'
                '<path data-pad-number="2" d="M 0.5 -2 L 1.5 -2 L 1.5 -1 L 0.5 -1 Z"/>'
                '</g></g></svg>', encoding="utf-8"
            )
            output = folder / "out.svg"
            generate_one({"designator": "X1", "body_style": "dip-switch", "pins": [
                {"pin": "2", "net": "SIGNAL_TX"}, {"pin": "1", "net": "GND"},
            ]}, folder / "X1.svg", output, [board])
            root = ET.parse(output).getroot()
            nested = next(node for node in root if node.tag.endswith("}svg"))
            _, _, view_width, view_height = map(float, nested.attrib["viewBox"].split())
            self.assertAlmostEqual(float(nested.attrib["width"]) / view_width,
                                   float(nested.attrib["height"]) / view_height, places=3)
            calls = {node.get("data-pinout-pad"): node for node in root if node.get("data-pinout-pad")}
            left = calls["2"].find("{*}circle")
            right = calls["1"].find("{*}circle")
            self.assertEqual("left", calls["2"].get("data-label-side"))
            self.assertEqual("right", calls["1"].get("data-label-side"))
            self.assertEqual(left.get("cy"), right.get("cy"))
            self.assertLess(float(left.get("cx")), float(right.get("cx")))
            self.assertFalse(any(node.get("id") == "Pads" for node in root.iter()))
            for number, net in (("2", "SIGNAL_TX"), ("1", "GND")):
                callout = calls[number]
                label = callout.find("{*}image")
                points = [tuple(map(float, point.split(","))) for point in callout.find("{*}polyline").get("points").split()]
                (start_x, start_y), (end_x, end_y) = points[-2:]
                self.assertEqual(f"{number}: {net}", label.get("aria-label"))
                self.assertAlmostEqual(float(label.get("y")) + float(label.get("data-cap-center-offset")), end_y, places=3)
                self.assertEqual(start_y, end_y)
                self.assertGreater(abs(end_x - start_x), 1.5)
            label = calls["2"].find("{*}image")
            self.assertLess(float(label.get("data-cap-center-offset")), float(label.get("height")) / 2)
