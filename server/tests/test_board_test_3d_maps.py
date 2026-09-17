import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

from tools.generate_board_test_3d_maps import build_page, qname


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
            Image.new("RGB", (200, 100), "#0B3D2B").save(render_path)

            build_page(map_path, render_path, output_path)

            root = ET.parse(output_path).getroot()
            self.assertFalse(any(element.tag == qname("circle") for element in root.iter()))
            self.assertFalse(any(element.tag == qname("svg") for element in root))
            image = next(element for element in root if element.tag == qname("image"))
            self.assertTrue(image.get("href", "").startswith("data:image/png;base64,"))
            line = next(element for element in root if element.get("data-callout") == "TP1" and element.tag == qname("line"))
            self.assertEqual(("20", "20"), (line.get("x2"), line.get("y2")))
            self.assertEqual(1, sum(element.get("data-line-halo") == "TP1" for element in root))
            self.assertEqual(1, sum(element.get("data-label-for") == "TP1" for element in root))


if __name__ == "__main__":
    unittest.main()
