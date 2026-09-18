---
name: create-board-port-map
description: Create auditable CSV and JSON connector-pin maps from an open Altium PCB, including exact pad nets, traced IC-side nets, firmware UART and I2C port numbering, and verified power-source paths and voltages. Use when a board manual, test document, or integration task needs machine-readable port mappings.
---

# Create Board Port Map

Produce one record per physical connector contact. Keep the mapping reusable by
other board-description and test-access workflows; never infer a voltage or
firmware port from a connector's label alone.

## Sources and evidence

1. Use `mcp__altium__get_component_pins` on the active PCB for designators and
   exact `pin` → `connector_net` pairs. Exclude mechanical pads (for example
   `MP*` and `MH*`) unless the user specifically requests them. An empty net is
   unconnected; do not replace it with a guessed name.
2. Trace filters, ESD parts, series resistors, selectors, switches and
   transceivers to the named IC-side `source_net`. Preserve both names in the
   output. For a generated PCB net (`Net*`), never use that as the resolved
   source. If a route stops at an unconnected filter pin, mark the trace as
   unassigned rather than inventing a destination.
3. For each supply contact, follow the board path to its upstream rail and
   record `power_source_net`, `power_path` and `power_voltage`. Distinguish a
   regulated output from a filtered branch, a gated branch, USB VBUS, a backup
   cell, and a source-dependent input. A nominal voltage is allowed only when
   verified by the schematic or regulator connection. Use a descriptive value
   such as `input-dependent` or `1.8/3.3 V selectable` when appropriate.
4. If firmware is in scope, read its actual board definition. Record the
   software port number separately from the hardware peripheral and MCU pin.
   For ArduPilot, `SERIAL_ORDER` maps `SERIAL0`, `SERIAL1`, … in order and
   `I2C_ORDER` maps bus 0, bus 1, … in order. Do not confuse hardware `UART5`
   with `SERIAL5`. Record TX/RX or SCL/SDA per contact. Keep bootloader and
   main-firmware mappings distinct if they differ.
5. When this map feeds an end-user board manual, put both the numbered hardware
   peripheral and ArduPilot port on applicable connector-map labels. Retain
   the audited power path in CSV/JSON, but show only the upstream source rail
   and verified voltage in end-user pin tables.

## Specification and export

Use the board-description JSON's `connector_groups[].items[].pins[]` structure
when available. Every pin needs `pin`, `connector_net`, `net` (the named
source-side net), `function` and `group`. Add `ardupilot_port`,
`mcu_peripheral`, `mcu_pin`, `power_source_net`, `power_voltage`, `power_path`
and `power_domain` when applicable. Set top-level `board_id` and
`firmware_source`. The CSV and JSON share one flattened record set.

```powershell
python tools/export_board_port_maps.py `
  --data <reviewed-board-description.json> `
  --csv <board>_port_pin_net_map.csv `
  --json <board>_port_pin_net_map.json
```

The JSON also contains grouped `uart_mappings`, `i2c_mappings` and
`trace_exceptions`; the CSV keeps every contact on a separate row. Keep source
paths relative to the project when possible, but preserve the exact board
definition filename for auditability.

## Verification

- Compare every exported `connector_net` with a fresh Altium pin readback;
  zero mismatches is the release criterion. Check duplicate and missing pins.
- Cross-check every UART and I2C group against the firmware order and MCU pin
  declarations, including signal direction.
- Independently check one contact in each power-domain class against the
  upstream component pins. Never collapse independent regulated banks merely
  because they share the same nominal voltage.
- Report any `trace_exceptions` explicitly. Do not call unverified nets
  resolved, and do not save the Altium design unless the user asks.
