import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

from tools.generate_board_test_3d_maps import build_page, qname
from tools.pcb_3d_registration import CameraRegistration


class ThreeDTestMapTests(unittest.TestCase):
    def test_reuses_label_and_line_without_circles(self):
        source = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 80">'
            '<text>TOP КАРТА ТЕСТОВОГО ДОСТУПА</text>'
            '<circle cx="3" cy="3" r="1" fill="#123456"/>'
            '<svg x="10" y="10" width="100" height="50" viewBox="0 0 20 10"/>'
            '<line x1="40" y1="25" x2="21" y2="20" data-callout="TP1"/>'
            '<circle cx="20" cy="20" r="1" data-callout="TP1"/>'
            '<rect data-callout="TP1" data-label-for="TP1"/>'
            '<text data-callout="TP1">TP1</text>'
            '</svg>'
        )
        with tempfile.TemporaryDirectory() as directory:
            map_path = Path(directory) / "map.svg"
            render_path = Path(directory) / "render.png"
            output_path = Path(directory) / "3d-map.svg"
            map_path.write_text(source, encoding="utf-8")
            Image.new("RGB", (220, 100), "#0B3D2B").save(render_path)

            build_page(
                map_path,
                render_path,
                output_path,
                registration=CameraRegistration(0, 22, 0, 10, False, 220, 100),
                side="top",
                language_mode="en-zh",
            )

            root = ET.parse(output_path).getroot()
            self.assertFalse(any(element.tag == qname("circle") for element in root.iter()))
            self.assertFalse(any(element.tag == qname("svg") for element in root))
            image = next(element for element in root if element.tag == qname("image"))
            self.assertTrue(image.get("href", "").startswith("data:image/png;base64,"))
            self.assertEqual("xMidYMid meet", image.get("preserveAspectRatio"))
            self.assertEqual("10.000000", image.get("x"))
            self.assertEqual("110.000000", image.get("width"))
            self.assertEqual("altium-camera-mm", image.get("data-registration"))
            self.assertEqual("url(#board-3d-viewport)", image.get("clip-path"))
            line = next(element for element in root if element.get("data-callout") == "TP1" and element.tag == qname("line"))
            self.assertEqual(("20", "20"), (line.get("x2"), line.get("y2")))
            self.assertEqual(1, sum(element.get("data-line-halo") == "TP1" for element in root))
            self.assertEqual(1, sum(element.get("data-label-for") == "TP1" for element in root))
            title = next(element for element in root if element.get("data-map-title") == "3d")
            self.assertEqual("TOP SIDE 3D TEST ACCESS MAP / 顶面三维测试访问图", title.text)

    def test_rejects_registration_for_a_different_image_size(self):
        with tempfile.TemporaryDirectory() as directory:
            map_path = Path(directory) / "map.svg"
            render_path = Path(directory) / "render.png"
            output_path = Path(directory) / "3d-map.svg"
            map_path.write_text(
                '<svg xmlns="http://www.w3.org/2000/svg">'
                '<svg x="0" y="0" width="20" height="10" viewBox="0 0 20 10"/>'
                '</svg>',
                encoding="utf-8",
            )
            Image.new("RGB", (200, 100), "#FFFFFF").save(render_path)
            with self.assertRaisesRegex(ValueError, "image size does not match"):
                build_page(
                    map_path,
                    render_path,
                    output_path,
                    registration=CameraRegistration(0, 20, 0, 10, False, 201, 100),
                )

    def test_bottom_camera_is_positioned_in_mirrored_svg_coordinates(self):
        source = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 80">'
            '<text data-map-title="2d">BOTTOM SIDE TEST ACCESS MAP</text>'
            '<svg x="10" y="10" width="100" height="50" viewBox="0 -10 20 10"/>'
            '<line x1="5" y1="5" x2="10" y2="10" data-callout="TP1"/>'
            '<circle cx="10" cy="10" r="1" data-callout="TP1"/>'
            '<rect data-callout="TP1" data-label-for="TP1"/>'
            '</svg>'
        )
        with tempfile.TemporaryDirectory() as directory:
            map_path = Path(directory) / "map.svg"
            render_path = Path(directory) / "render.png"
            output_path = Path(directory) / "3d-map.svg"
            map_path.write_text(source, encoding="utf-8")
            Image.new("RGB", (220, 100), "#FFFFFF").save(render_path)
            build_page(
                map_path,
                render_path,
                output_path,
                registration=CameraRegistration(-2, 20, 0, 10, True, 220, 100),
            )
            root = ET.parse(output_path).getroot()
            image = next(element for element in root if element.tag == qname("image"))
            self.assertEqual("10.000000", image.get("x"))
            self.assertEqual("110.000000", image.get("width"))


if __name__ == "__main__":
    unittest.main()
