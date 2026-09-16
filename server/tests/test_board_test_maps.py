import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from tools.generate_board_test_maps import build_page, qname


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


if __name__ == "__main__":
    unittest.main()
