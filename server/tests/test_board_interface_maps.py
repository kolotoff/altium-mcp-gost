import unittest
import xml.etree.ElementTree as ET

from tools.generate_board_interface_maps import (
    POWER_COLORS,
    POWER_FILL_OPACITY,
    add_legend,
    add_power_highlight,
    add_power_legend,
    assembly_path_vertices,
    circle_inside_outline,
    component_body_polygons,
    qname,
    remove_outside_mounting_holes,
    remove_pads,
    visible_power_domains,
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


class ExposedPadTests(unittest.TestCase):
    def test_retains_only_documented_pads_of_selected_instance_in_native_position(self):
        root = ET.fromstring(
            '<svg xmlns="http://www.w3.org/2000/svg"><g transform="scale(1,-1)">'
            '<g id="Pads" data-layer="pads">'
            '<g data-component="X5" data-instance="X5">'
            '<path data-pad-number="A" d="M 0 0 L 1 0 L 1 1 Z"/></g>'
            '<g data-component="X5" data-instance="X5-4" transform="translate(10 20) rotate(180)">'
            '<path data-pad-number="A" d="M 2 0 L 3 0 L 3 1 Z"/>'
            '<path data-pad-number="MP" d="M 4 0 L 5 0 L 5 1 Z"/></g>'
            '</g></g></svg>'
        )

        remove_pads(root, exposed={"instance:X5-4": {"A"}})

        frame = root[0]
        layer = frame[0]
        self.assertEqual("scale(1,-1)", frame.get("transform"))
        self.assertEqual("ExposedConnectorPads", layer.get("id"))
        self.assertEqual(1, len(layer))
        self.assertEqual("translate(10 20) rotate(180)", layer[0].get("transform"))
        self.assertEqual([("A", "M 2 0 L 3 0 L 3 1 Z")],
                         [(path.get("data-pad-number"), path.get("d")) for path in layer[0]])


class PowerHighlightTests(unittest.TestCase):
    def test_interface_legend_is_a_row_and_power_legend_is_a_column(self):
        root = ET.Element(qname("svg"))
        _, y, _, height = add_legend(root, 266, 5, {})
        add_power_legend(root, {"main_5v", "pwm1_5v"}, x=230, y=y + height + 2)
        interface = root.findall(f"{qname('rect')}[@data-interface-legend]")
        power = root.findall(f"{qname('rect')}[@data-power-legend]")
        self.assertEqual(4, len(interface))
        self.assertEqual(2, len(power))
        self.assertEqual(4, len({swatch.get("x") for swatch in interface}))
        self.assertEqual({"5.600"}, {swatch.get("y") for swatch in interface})
        self.assertEqual({"230.000"}, {swatch.get("x") for swatch in power})
        for previous, current in zip(power, power[1:]):
            self.assertLess(float(previous.get("y")) + float(previous.get("height")), float(current.get("y")))

    def test_legend_matches_header_transparency(self):
        root = ET.Element(qname("svg"))
        add_power_legend(root, {"main_5v", "pwm1_5v"})
        add_power_highlight(root, {
            "designator": "X1", "power_domain": "main_5v",
            "body_polygon": [(0, 0), (1, 0), (1, 1), (0, 1)],
        }, {"main_5v"})
        swatch = next(node for node in root if node.get("data-power-legend") == "main_5v")
        header = next(node for node in root if node.get("data-power-highlight") == "main_5v")
        self.assertEqual((POWER_COLORS["main_5v"], POWER_FILL_OPACITY),
                         (swatch.get("fill"), swatch.get("fill-opacity")))
        self.assertEqual((swatch.get("fill"), swatch.get("fill-opacity")),
                         (header.get("fill"), header.get("fill-opacity")))

    def test_arc_metadata_does_not_expand_connector_body(self):
        self.assertEqual(
            [(3.9, -2.4), (5.8, -0.5)],
            assembly_path_vertices("M 3.9 -2.4 A 2.4 2.4 0 0 1 5.8 -0.5"),
        )
        root = ET.fromstring(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<g id="component-X2-assembly" data-component="X2" transform="translate(10 20) rotate(0)">'
            '<path d="M -3 -2 A 2.4 2.4 0 0 1 3 2"/>'
            '<path d="M -3 2 L 3 2"/>'
            '</g></svg>'
        )
        polygons = component_body_polygons(
            root, bottom=False, view_x=0, view_y=-30,
            view_width=30, board_x=0, board_y=0,
        )
        self.assertEqual([(7, 12), (13, 12), (13, 8), (7, 8)], polygons["X2"])

    def test_only_shared_single_rail_domains_are_visible(self):
        spec = {"connector_groups": [{"items": [
            {"power_domain": "main_5v"}, {"power_domain": "main_5v"},
            {"power_domain": "backup"},
            {"power_domain": "mixed"}, {"power_domain": "mixed"},
        ]}]}
        self.assertEqual({"main_5v"}, visible_power_domains(spec))

    def test_highlight_has_exact_body_size_and_no_border(self):
        root = ET.Element(qname("svg"))
        add_power_highlight(root, {
            "designator": "X1", "power_domain": "main_5v",
            "body_polygon": [(6, 18), (14, 18), (14, 23), (6, 23)],
        }, {"main_5v"})
        mark = next(iter(root))
        self.assertEqual("6.000,18.000 14.000,18.000 14.000,23.000 6.000,23.000", mark.get("points"))
        self.assertIsNone(mark.get("stroke"))

    def test_body_polygon_uses_assembly_bounds_without_padding(self):
        root = ET.fromstring(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<g id="component-X1-assembly" data-component="X1" transform="translate(10 20) rotate(0)">'
            '<path d="M -2 -1 L 2 -1 L 2 1 L -2 1 Z"/>'
            '</g></svg>'
        )
        polygons = component_body_polygons(
            root, bottom=False, view_x=0, view_y=-30,
            view_width=30, board_x=2, board_y=3, scale=1.5,
        )
        self.assertEqual([(14, 19.5), (20, 19.5), (20, 16.5), (14, 16.5)], polygons["X1"])


if __name__ == "__main__":
    unittest.main()
