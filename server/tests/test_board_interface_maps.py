import unittest
import xml.etree.ElementTree as ET

from tools.generate_board_interface_maps import (
    circle_inside_outline,
    qname,
    remove_outside_mounting_holes,
)


class MountingHoleFilterTests(unittest.TestCase):
    def test_hole_must_fit_inside_outline(self):
        rectangle = [(0, 0), (10, 0), (10, 10), (0, 10)]
        self.assertTrue(circle_inside_outline(rectangle, 5, 5, 1))
        self.assertTrue(circle_inside_outline(rectangle, 1, 5, 1))
        self.assertFalse(circle_inside_outline(rectangle, 0.5, 5, 1))
        self.assertFalse(circle_inside_outline(rectangle, 11, 5, 1))

        concave = [(0, 0), (10, 0), (10, 10), (6, 10), (6, 4), (4, 4), (4, 10), (0, 10)]
        self.assertFalse(circle_inside_outline(concave, 5, 7, 0.5))
        self.assertFalse(circle_inside_outline(concave, 3.5, 7, 1))
        self.assertTrue(circle_inside_outline(concave, 2, 7, 1))

    def test_removes_panel_holes_but_preserves_board_holes(self):
        root = ET.fromstring(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<g id="BoardShape">'
            '<path id="BoardOutline" d="M 0 0 L 10 0 L 10 10 L 0 10 Z"/>'
            '<g id="StandaloneMountingPads">'
            '<circle id="inside" cx="5" cy="5" r="1"/>'
            '<circle id="crossing" cx="0.5" cy="5" r="1"/>'
            '<circle id="panel" cx="11" cy="5" r="1"/>'
            '</g></g></svg>'
        )

        remove_outside_mounting_holes(root)

        group = next(element for element in root.iter() if element.get("id") == "StandaloneMountingPads")
        circles = [element for element in group if element.tag == qname("circle")]
        self.assertEqual(["inside"], [element.get("id") for element in circles])


if __name__ == "__main__":
    unittest.main()
