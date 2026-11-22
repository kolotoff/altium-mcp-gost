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
4. Declare the exact ArduPilot target directory for each board variant in
   `firmware_target` and its application `hwdef.dat` in `firmware_source`.
   Reread this file and every referenced file from disk for each verification.
   Expand includes in place and apply `undef`, reassignment, and alternate
   settings in the firmware parser's effective order. Record the exact target,
   source paths and hashes in the verification report. Treat previous exports
   and manuals as comparison inputs.
5. Match each traced function to its physical MCU pin and effective assignment.
   Keep the numbered peripheral, signal direction, and ArduPilot logical port
   distinct. Derive serial and I²C numbers from `SERIAL_ORDER` and
   `I2C_ORDER`, retaining empty serial slots. Check CAN order, SPI devices and
   chip selects, timer channels and servo indices, GPIO, ADC, USB, safety and
   alarm assignments. Record declared but disabled or unassigned functions
   explicitly. Check target defaults separately from the application and
   bootloader pin maps.
6. When this map feeds an end-user board manual, put both the numbered hardware
   peripheral and ArduPilot port on applicable connector-map labels. Retain
   the audited power path in CSV/JSON, but show only the upstream source rail
   and verified voltage in end-user pin tables.

## Specification and export

Use the board-description JSON's `connector_groups[].items[].pins[]` structure
when available. Every pin needs `pin`, `connector_net`, `net` (the named
source-side net), `function` and `group`. Add `ardupilot_port`,
`mcu_peripheral`, `mcu_pin`, `power_source_net`, `power_voltage`, `power_path`
and `power_domain` when applicable. Keep the component/pin trace in
`trace_note`, including any branch or selection state needed to explain
multiple endpoints. Set top-level `board_id`, `firmware_target` and
`firmware_source` for an ArduPilot board. The CSV and JSON share one flattened
record set.

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

- Compare each export row to a fresh Altium pad readback and match each
  physical number to the native SVG metadata. Require complete coverage of
  documented contacts with zero duplicates, mechanical callouts, or mismatches.
- Compare each firmware record against the effective MCU pin, peripheral,
  direction, and logical port. Verify every power contact against the upstream
  component path. Preserve independent supply banks with equal voltages.
- For independent verification, give a fresh verifier the exact board paths,
  target paths, specification, and exports. Have it reread the sources and
  report record counts and discrepancies by board, designator, and physical
  pin. Recheck every correction before generating the final DOCX.
- Report any `trace_exceptions` explicitly. Do not call unverified nets
  resolved, and do not save the Altium design unless the user asks.
