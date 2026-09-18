import unittest
import xml.etree.ElementTree as ET

from tools.export_board_port_maps import flatten, interface_mappings
from tools.generate_board_interface_maps import (
    add_power_highlight,
    add_power_legend,
    qname,
)


class BoardPortMapTests(unittest.TestCase):
    def test_distinguishes_pad_source_and_power_nets(self):
        spec = {
            "board_id": "Example",
            "connector_groups": [{"items": [{
                "designator": "X1",
                "pins": [
                    {"pin": "1", "connector_net": "VCC_FILTERED", "net": "VCC_FILTERED",
                     "function": "Power", "group": "Power", "power_source_net": "VCC_5V",
                     "power_voltage": "5 V", "power_path": "L1", "power_domain": "main_5v"},
                    {"pin": "2", "connector_net": "TX_C", "net": "MCU_TX",
                     "function": "TX", "group": "UART", "ardupilot_port": "SERIAL3",
                     "mcu_peripheral": "USART3_TX", "mcu_pin": "PC10"},
                ],
            }]}],
        }
        rows = flatten(spec)
        self.assertEqual("VCC_FILTERED", rows[0]["connector_net"])
        self.assertEqual("VCC_5V", rows[0]["power_source_net"])
        self.assertEqual("traced_source", rows[1]["trace_status"])
        mapping = interface_mappings(rows, "SERIAL")
        self.assertEqual("USART3", mapping[0]["mcu_peripheral"])
        self.assertEqual("PC10", mapping[0]["connector_pins"][0]["mcu_pin"])

    def test_rejects_generated_source_name(self):
        spec = {"board_id": "Example", "connector_groups": [{"items": [{
            "designator": "X1", "pins": [{"pin": "1", "connector_net": "NetR1_2",
                                       "net": "NetR1_2", "function": "", "group": ""}],
        }]}]}
        with self.assertRaisesRegex(ValueError, "unresolved source net"):
            flatten(spec)

    def test_power_legend_and_body_highlight_are_separate(self):
        root = ET.Element(qname("svg"))
        add_power_legend(root, {"pwm1_5v"})
        add_power_highlight(root, {
            "designator": "X1", "power_domain": "pwm1_5v",
            "body_polygon": [(30.0, 40.0), (35.0, 40.0),
                             (35.0, 43.0), (30.0, 43.0)],
        }, {"pwm1_5v"})
        legend = [node for node in root.iter() if node.get("data-power-legend")]
        highlights = [node for node in root.iter() if node.get("data-power-highlight")]
        self.assertEqual(1, len(legend))
        self.assertEqual("X1", highlights[0].get("data-designator"))
        self.assertEqual(legend[0].get("fill-opacity"), highlights[0].get("fill-opacity"))


if __name__ == "__main__":
    unittest.main()
