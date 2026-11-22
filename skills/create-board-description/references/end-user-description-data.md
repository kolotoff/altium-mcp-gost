# End-user board-description JSON

Use this schema with `tools/generate_end_user_board_description_docx.py` when
the requested artifact is a final-user connector reference rather than a PCB
design or manufacturing description.

```json
{
  "board_id": "ExampleBoard_v1",
  "firmware_target": "EXAMPLE-743",
  "firmware_source": "path/to/hwdef/EXAMPLE-743/hwdef.dat",
  "language": "en-US",
  "title": "USER MANUAL",
  "subtitle": "ExampleBoard",
  "footer_label": "ExampleBoard",
  "metadata": {
    "title": "ExampleBoard user manual",
    "subject": "CPU, memory, sensors, controls, and connector pinout"
  },
  "board_renders_title": "Board views",
  "board_renders": [
    {
      "title": "Top side",
      "image": "C:/absolute/path/board_top.png",
      "caption": "Orthographic top-side view",
      "alt": "Orthographic 3D render of the board top side"
    },
    {
      "title": "Bottom side",
      "image": "C:/absolute/path/board_bottom.png",
      "caption": "Orthographic bottom-side view",
      "alt": "Orthographic 3D render of the board bottom side"
    }
  ],
  "interface_maps_title": "Board interface maps",
  "interface_maps_intro": "Vector views are shown at 1:1 scale. STM32 interfaces are blue, RK3588 interfaces are orange, and shared interfaces are purple.",
  "interface_map_scale": 1,
  "component_overrides": {
    "flight_controller": {
      "overview": "STM32H743 flight controller with a Cortex-M7 core.",
      "map_label": "STM32H743"
    }
  },
  "interface_map_legend": {
    "stm32": "STM32 / ArduPilot",
    "rk3588": "RK3588",
    "shared": "STM32 + RK3588",
    "other": "Power / board"
  },
  "interface_map_processors": [
    {
      "designator": "U1",
      "component_override": "flight_controller",
      "processor_domain": "stm32",
      "side": "bottom"
    }
  ],
  "interface_maps": [
    {
      "title": "Top-side interface map — 1:1",
      "image": "C:/absolute/path/pcb-interface-map-top.svg",
      "fallback_image": "C:/absolute/path/pcb-interface-map-top.png",
      "alt": "One-to-one top-side board interface map"
    },
    {
      "title": "Bottom-side processor map — 1:1",
      "image": "C:/absolute/path/pcb-interface-map-bottom.svg",
      "fallback_image": "C:/absolute/path/pcb-interface-map-bottom.png",
      "alt": "One-to-one bottom-side board processor map"
    }
  ],
  "overview": [
    {
      "title": "Flight controller",
      "rows": [
        ["Controller", {"component_override": "flight_controller"}],
        ["Firmware target", "EXAMPLE-743"]
      ]
    }
  ],
  "connector_groups": [
    {
      "title": "Flight-control connectors",
      "items": [
        {
          "designator": "X1",
          "name": "GNSS",
          "description": "Four-pin navigation receiver connector.",
          "body_style": "jst-gh",
          "image": "C:/absolute/path/connector_X1.png",
          "pinout_image": "C:/absolute/path/pinout_X1.svg",
          "pinout_fallback_image": "C:/absolute/path/pinout_X1.png",
          "processor_domain": "stm32",
          "power_domain": "main_5v",
          "interface_label": "GNSS · USART3/SERIAL3",
          "pinout_label_layout": "auto",
          "map_label_layout": "perimeter",
          "map_label_bias": "nearest",
          "pins": [
            {
              "pin": "1",
              "connector_net": "VCC_GNSS",
              "net": "VCC_GNSS",
              "function": "Receiver supply; source VCC_5V, 5 V",
              "power_source_net": "VCC_5V",
              "power_voltage": "5 V",
              "power_path": "L1",
              "power_domain": "main_5v",
              "group": "Power"
            },
            {
              "pin": "2",
              "connector_net": "GNSS_TX_FILTERED",
              "net": "GNSS_TX",
              "function": "STM32 PC10; ArduPilot SERIAL3 TX",
              "ardupilot_port": "SERIAL3",
              "mcu_peripheral": "USART3",
              "mcu_signal": "USART3_TX",
              "mcu_pin": "PC10",
              "mcu_ball": "example package contact",
              "signal_direction": "output",
              "group": "UART / SERIAL3"
            }
          ]
        }
      ]
    }
  ]
}
```

## Content requirements

- Keep the overview functional: CPU, flight controller, memory, onboard
  sensors, and behavior visible to an integrator or operator.
- Place full-board orthographic top and bottom renders immediately after the
  cover and before the functional overview. Use one page per side when needed
  to keep connector labels and component placement legible.
- When requested, add `interface_maps` after the board renders. Preserve the
  physical millimetre dimensions of each SVG. Set `interface_map_scale` once
  for both sides, defaulting to `1` for 1:1. Increase the scale when both sides
  fit with their full callouts and legend. Update the scale captions to match.
  Retain the assembly geometry, exposed contact paths, and connector labels.
- Use `component_overrides` for reader-facing model names, population notes,
  or generic module descriptions. An overview row can refer to an override
  key to display its `overview` sentence. A processor-map record can refer to
  the same key to display `map_label`. The native designator, pad geometry,
  and electrical and firmware records retain their original identity.
- Do not include stackup, design-rule, trace-width, clearance, fabrication, or
  other PCB-production details unless the user explicitly requests them.
- Create one `items` entry, one orthographic 3D image, one connector-side
  pinout diagram, and one table for every external connector or user-operated
  control in scope.
- Create one `pins` entry for every physical signal/power contact. Never combine
  repeated contacts into one row.
- Exclude mechanical, mounting, shell, and hold-down contacts from the end-user
  pinout unless the user explicitly asks for chassis or shield bonding details.
  Confirm mating-contact counts against the connector drawing when auxiliary
  solder pads use ordinary numbers. Retain their exclusions in the verification
  report, with the footprint and reason.
- `group` is mandatory. Consecutive equal values are merged visually in the
  last table column while each physical contact retains its own row.
- Keep the exact PCB pad `connector_net` separate from `net`, the traced and
  user-facing source signal. If CSV/JSON exports are requested, follow
  `skills/create-board-port-map/SKILL.md`; populate firmware ports, MCU pins,
  power-source nets, voltages, paths, and `power_domain` from verified sources.
- Set `firmware_target` to the exact target directory name of each ArduPilot
  variant and `firmware_source` to its application `hwdef.dat`. Follow the
  port-map skill to derive the current effective mapping from disk, track
  includes and overrides, and verify both the numbered peripheral and its
  logical port against the physical MCU contact. Record the target and source
  hashes in the verification report.
- Put an ArduPilot mapping in `function` when the signal is defined by the
  selected hardware target. Include the firmware name and MCU pin when known;
  state that a line is unassigned when verified as such.
- Use `NC` for a real physical contact with no assigned board net.
- Use `body_style` to classify the contact geometry, never to select a
  substitute housing. Supported styles are `jst-gh`, `picoblade-ra`, `xt60`,
  `mr60`, `board-to-board`, `usb-c`, `microcoax`, `keystone`, `dip-switch`,
  `solder-bridge`, `pad-contact`, `tactile-switch`, `buzzer`, and `coin-cell`.
- Never expose an automatically generated PCB name such as `NetR42_2`. Replace
  it with the traced source/destination signal or power rail. When the segment
  is intentionally unnamed, use a concise functional alias and explain the
  series or switching element in `function`.
- Trace protected or filtered connector nets through the intervening component
  and display the named net at the source IC. Preserve direction and the
  connector-side effect in `function` when the source and connector aliases
  differ.
- Images must be exported from the open PCB through the Altium MCP, with the
  projection verified as orthographic. Prefer direct 3D and assembly exports to
  screen capture.
- Pinout diagrams use the same `pins` records as the table. Prefer the
  installed-side assembly and pad groups from the current PCB SVG. The
  component assembly export is also valid when its contact view matches the
  installed part. Use the native body, keying and pin-1 orientation.
  For repeated designators, match the Altium pad coordinates before assigning
  `native_svg_instance`. Pinouts, interface maps and 3D crops use the same
  verified instance.
  Read `data-pad-number` to place each net label. When the assembly body is
  absent, render the exact native paths for the documented numbered pads in
  both the pinout and interface map. Keep their installed transforms and omit
  unrelated pads. Stop if usable native geometry or pin metadata is absent.
- Apply the same native transform and uniform scale to artwork and pad anchors.
  Use the available label-row height for the housing and reserve side space
  for the longest complete label. If physical order benefits from reorientation,
  rotate the artwork and anchors together by 90 degrees. For an obliquely
  installed board-to-board part, use the native footprint frame on the same
  installed side if this makes the two contact rows legible. Keep text horizontal.
- `pinout_label_layout` may be `auto`, `left`, `right`, or `split`. In `auto`,
  keep dual-row connectors split across both sides, automatically split
  `usb-c`, `dip-switch`, `tactile-switch`, and `buzzer` bodies, and route a
  single-row connector toward the closer housing edge. Sort callouts by their
  physical pad positions. Fan leaders outside the housing where practical.
  When a uniformly spaced pad row needs more label room, spread its leaders
  symmetrically above and below the row midpoint.
- Split layouts use physical pad columns before pin-list order. The lower-x
  column is labeled on the left and the higher-x column on the right. USB-C A/B
  rows remain intact and are assigned to the nearest side, including when both
  rows lie on the same half of the housing. This is the default X-crossing
  prevention; do not add a board-specific swap when geometry resolves it.
- `pinout_rotation` may explicitly select `0`, `90`, `180`, or `270` degrees
  when the native footprint orientation must match the installed board
  orientation. `dip-switch` bodies preserve their native orientation by
  default; omit the field when that matches the board.
- Set `pinout_split_swap` to `true` when a split connector has both contact
  rows on the same half of the housing and damaged or incomplete pad metadata
  prevents automatic physical-column assignment. This is an exceptional
  override; it swaps complete groups while preserving pad order.
- Classify low-pin-count multi-column controls with `body_style`; automatic
  layout then splits their labels left/right. Verify the resulting leader
  geometry rather than assuming every low-pin-count component is single-row.
- `map_label_layout` may be `perimeter` or `local`. Reserve `local` for an
  internal component whose outside placement would create a long leader.
- `map_label_bias` may be `nearest`, `left`, `right`, `top`, or `bottom` and
  controls the side of an explicitly local callout or the search direction for
  a lower-priority perimeter slot. Treat an explicit local side as a hard
  constraint; it may slide along that side but must not migrate to another side.
- For `jst-gh`, preserve the Altium-exported housing and locking/key opening.
  Never replace a missing housing SVG with a generic rounded rectangle.
- Board-specific data and image paths belong in task-local JSON, not in the
  reusable generator or skill.
- `processor_domain` may be `stm32`, `rk3588`, `shared`, or `other` and drives
  consistent color marking in pinouts and board maps. `interface_label` is the
  concise nearby map label. For ArduPilot-related connectors use target port
  numbers such as `SERIAL3`, `BUS1` (ArduPilot I²C bus 1), `SERVO7`, or
  `AP CAN2`, not generic `UART` or `I²C` labels. Include the numbered STM32
  hardware peripheral alongside each applicable ArduPilot port, verified from
  `hwdef.dat` (for example `USART3/SERIAL3` or `I2C2/BUS1`).
- `power_domain` marks the connector body on the map independently of the
  processor-colored label. Highlight only domains shared by at least two
  connectors; omit single-connector and `mixed` domains from highlights and
  power legend. Fill the exact component-body extent with no margin or border.
  Use `mixed` for multiple supply classes and `none` for no supply.
- Use the same fill and opacity for each power-legend swatch and its connector
  highlight. Choose clearly different hues for power domains that appear near
  one another on the board. When measuring native assembly SVG bodies, parse
  path commands: arc radii and flags are not x/y coordinates. Compare the
  resulting overlays with the actual housing outlines before embedding maps.
- Processor-package highlights use their native Altium assembly-body extents
  as well, without padding or a border; labels may remain separate.
- Per-pin table power descriptions show the upstream source rail and voltage,
  not intervening component designators. Keep the verified component path in
  `power_path` for machine-readable CSV/JSON exports.
- `interface_map_legend` may override the four domain captions without changing
  their colors. Declare processor callouts in `interface_map_processors`; each
  record supplies the real designator, domain, `top`, `bottom`, or `both` side,
  and either `label` or `component_override` for the displayed text. Arrange
  processor colors in one horizontal row and power colors in one vertical
  column in the lower-right corner, clear of the drawing and its leaders.
- For top-side interface maps, place perimeter-connector labels outside the PCB
  first. Keep left/right labels horizontal and rotate top/bottom labels by 90°.
  Center the visible Arial text within each colored badge on both axes,
  including multiline and rotated badges. Verify this in Word's page render.
  Preserve `BoardShape/StandaloneMountingPads` from the current Altium assembly
  export when hiding the copper `Pads` group so drilled mounting holes inside
  the PCB outline remain visible on both top- and bottom-side maps. Exclude
  panel-rail pads and any drilled circle that crosses the actual board contour.
  Then place internal-component labels outside the outline when this does not
  overlap or cross the first-priority labels. Use direct angled leaders rather
  than rectangular routes, preserve physical anchor order, and keep labels clear
  of their target components by a visible margin. Treat all labeled component
  bodies as obstacles, including the label owner's body. Test collisions in
  both directions: a new leader must not enter an existing label, and an
  existing leader must not pass through a new label. For bottom-side maps, place
  connector labels horizontally above or below the board, preserving physical
  anchor order.
- Keep the projected edge position fixed for components closest to the outline;
  lower-priority labels must move around them. When a local override is used,
  place the label beside the component with a short direct leader.
- Center the full-board artwork on each landscape page and place the caption
  below it. Align the connector crop and pinout on one horizontal centerline.
  Align the midpoint of each net label's capital letters with the horizontal
  end of its leader. Leave a clear gap between a connector's pin table and the
  next heading on the same page.
- If connector crops use a locator arrow, draw a short vertical translucent red
  shaft with a clear triangular head. Provide a per-designator vertical-flip
  override for bottom-side crops whose exported local orientation is reversed.
- Every `SB*` item needs a state description. State the default condition and
  the effect of bridging or actuation; explicitly identify non-solder-bridge
  controls that use an `SB*` designator.

## Pre-generation checks

- Every in-scope designator appears exactly once.
- Every table has exactly four columns: pin, board net, function/mapping, and
  interface group.
- Every item image exists and shows the stated designator from the correct side.
- No blocked production-detail phrase or excluded non-signal contact identifier
  occurs in the finished document text.
- The document contains no legacy block diagram.
- The native SVG instance, installed side, pad number and conductor trace agree
  with the fresh Altium readback. The specification, port-map CSV and JSON
  agree for every pin and an independent review has cleared the technical data.
- Check the full-width connector tables and aligned figure captions in the
  portrait connector pages. Use rendered page images to check dense tables,
  body size and legibility. Confirm that both landscape maps print at the same
  labeled scale and both legend groups are clear of the callouts.
