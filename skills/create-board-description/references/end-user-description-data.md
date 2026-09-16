# End-user board-description JSON

Use this schema with `tools/generate_end_user_board_description_docx.py` when
the requested artifact is a final-user connector reference rather than a PCB
design or manufacturing description.

```json
{
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
  "interface_map_legend": {
    "stm32": "STM32 / ArduPilot",
    "rk3588": "RK3588",
    "shared": "STM32 + RK3588",
    "other": "Power / board"
  },
  "interface_map_processors": [
    {
      "designator": "U1",
      "label": "STM32H743",
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
        ["Controller", "STM32H743"],
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
          "interface_label": "UART3 / SERIAL3",
          "pinout_label_layout": "auto",
          "map_label_layout": "perimeter",
          "map_label_bias": "nearest",
          "pins": [
            {
              "pin": "1",
              "net": "VCC_GNSS",
              "function": "Receiver supply",
              "group": "Power"
            },
            {
              "pin": "2",
              "net": "GNSS_TX",
              "function": "STM32 PC10; ArduPilot SERIAL3 TX",
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
  physical millimetre dimensions of each SVG so the internal PCB outline prints
  at 1:1 scale. Remove the visible Pads group from these maps while retaining
  component-body assembly geometry and connector labels.
- Do not include stackup, design-rule, trace-width, clearance, fabrication, or
  other PCB-production details unless the user explicitly requests them.
- Create one `items` entry, one orthographic 3D image, one connector-side
  pinout diagram, and one table for every external connector or user-operated
  control in scope.
- Create one `pins` entry for every physical signal/power contact. Never combine
  repeated contacts into one row.
- Exclude mechanical, mounting, shell, and hold-down contacts from the end-user
  pinout unless the user explicitly asks for chassis or shield bonding details.
- `group` is mandatory. Consecutive equal values are merged visually in the
  last table column while each physical contact retains its own row.
- Put an ArduPilot mapping in `function` when the signal is defined by the
  selected hardware target. Include the firmware name and MCU pin when known;
  state that a line is unassigned when verified as such.
- Use `NC` for a real physical contact with no assigned board net.
- Use `body_style` to select a connector-family silhouette in the physical
  pinout generator. Supported styles are `jst-gh`, `picoblade-ra`, `xt60`,
  `mr60`, `board-to-board`, `usb-c`, `microcoax`, `keystone`, `dip-switch`,
  `solder-bridge`, `tactile-switch`, `buzzer`, and `coin-cell`.
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
- Pinout diagrams must be generated from the same ordered `pins` records used
  by the table. Prefer the real component assembly SVG body, keying, and pin-1
  orientation. Read `data-pad-number` from the source Pads group to place each
  net label, then omit the Pads group from the visible drawing. These are
  connector illustrations, not board block diagrams.
- Rotate the real connector SVG body by 90 degrees when it reduces label-line
  overlap or intersections; rotate pad anchor coordinates with the body so the
  `data-pad-number` correspondence remains exact.
- `pinout_label_layout` may be `auto`, `left`, `right`, or `split`. In `auto`,
  keep dual-row connectors split across both sides and route a single-row
  connector to the left after rotation. Sort one-sided callouts by physical pad
  position, not schematic pin order, so reversed numbering cannot cross.
- Use `split` for low-pin-count components whose contacts occupy multiple
  columns, such as a DIP switch or buzzer. Verify the resulting leader geometry
  rather than assuming every low-pin-count component is single-row.
- `map_label_layout` may be `perimeter` or `local`. Reserve `local` for an
  internal component whose outside placement would create a long leader.
- `map_label_bias` may be `nearest`, `left`, `right`, `top`, or `bottom` and
  controls the side of an explicitly local callout or the search direction for
  a lower-priority perimeter slot. Treat an explicit local side as a hard
  constraint; it may slide along that side but must not migrate to another side.
- For `jst-gh`, use the mating-face outline: show the contact channel and the
  long locking/key opening beside it, matching the family-specific housing
  rather than a generic rounded rectangle.
- Board-specific data and image paths belong in task-local JSON, not in the
  reusable generator or skill.
- `processor_domain` may be `stm32`, `rk3588`, `shared`, or `other` and drives
  consistent color marking in pinouts and board maps. `interface_label` is the
  concise nearby map label, for example `PWM7`, `UART1`, `CAN1`, or `CSI0`.
- `interface_map_legend` may override the four domain captions without changing
  their colors. Declare processor callouts in `interface_map_processors`; each
  record supplies the real designator, displayed label, domain, and `top`,
  `bottom`, or `both` side. Do not hard-code board-specific processor locations
  in the generator.
- For top-side interface maps, place perimeter-connector labels outside the PCB
  first. Keep left/right labels horizontal and rotate top/bottom labels by 90°.
  Preserve `BoardShape/StandaloneMountingPads` from the current Altium assembly
  export when hiding the copper `Pads` group so drilled mounting holes remain
  visible on both top- and bottom-side maps.
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
- If an `SB*` solder bridge has no Mechanical-2 body, copy its real pad paths
  from the board assembly SVG and use `data-pad-number` for pin mapping. Never
  replace the bridge with a generated rounded rectangle.
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
