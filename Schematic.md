# Schematic Symbol Creation Rules

This document records the default schematic-symbol creation workflow and rules to use with the Altium MCP tools for the GOST schematic libraries under:

```text
D:\Develop\Hardware\altium-gost-libraries\Schematic
```

Target libraries for this pass:

- `Connector Board-To-Board HRS DF40.SchLib`
- `Connector 1.25mm Pitch JST GH.SchLib`
- `Connector Board-To-Board.SchLib`
- `Connector FFC-FPC.SchLib`
- `Connector USB.SchLib`
- `MCU.SchLib`
- `MPU.SchLib`
- `RF Active.SchLib`
- `Opamp.SchLib`
- `Interface.SchLib`
- `Isolation.SchLib`

## MCP Research Notes

Use Altium MCP as the source of library style data. Do not inspect `.SchLib` files directly when deriving style rules.

This is the default workflow for all GOST schematic-library symbol creation, update, and review tasks unless the user explicitly requests a different library convention.

Recommended workflow:

1. Check that the bridge is available with `get_server_status`.
2. Load the project placement baseline with `get_symbol_placement_rules`.
3. For each source library, open or navigate to representative symbols with `search_library_symbol`.
4. Capture the active symbol style with `get_library_symbol_reference`.
5. When exact primitive/font auditing is needed, capture the active symbol with `get_library_symbol_primitive_font_dump`.
6. Create new symbols only after the rules and a reference style are known, using `create_schematic_symbol`.
7. Save the focused document with `save_current_document` only when the user explicitly asks to save.

Common command pattern:

```text
get_symbol_placement_rules()
search_library_symbol(
  library_path="D:\Develop\Hardware\altium-gost-libraries\Schematic\<Library>.SchLib",
  symbol_name="<representative symbol or family>"
)
get_library_symbol_reference()
get_library_symbol_primitive_font_dump()  // optional exact primitive/font audit
create_schematic_symbol(...)
```

Sampling was rerun through Altium MCP after Altium recovered. The sampled references below were opened with `search_library_symbol`, inspected with `get_library_symbol_reference`, and checked visually with `get_screenshot` for the CH334P grouped-interface splitter style.

## Sampling Results

Connector libraries:

- `Connector Board-To-Board HRS DF40.SchLib`: 60 symbols. Sampled `DF40HC(3.0)-100DS-0.4V` and `DF40C-10DP-0.4V`. Receptacles use `XS?`; headers use `XP?`. Descriptions use comma-separated selection facts: position count, `Mezzanine Header` or `Mezzanine Receptacle`, contact pitch, and stacking height. Pins are passive and arranged as odd pins on the left and even pins on the right. Mounting pins use `MP1...MP4`, passive type, and occupy top/bottom rows on both sides.
- `Connector 1.25mm Pitch JST GH.SchLib`: 14 symbols. Sampled `BM08B-GHS-TBT`. Existing symbols use `X?`, `Manufacturer=JST`, `ValueType=Разъём`, and `PartNumber` set to `=Comment`. Contact pins are single-column on the left in ascending order, named `Pin1...PinN`, with descriptions such as `Circuit 1`. `MP1` and `MP2` mounting pads are passive pins on the right with description `Mounting pad`.
- `Connector Board-To-Board.SchLib`: 18 symbols. Sampled `BM10NB(0.8)-40DS-0.4V`. Receptacles use `XS?`; BM10 header variants exist as `DP` symbols and should use the header convention. Contacts are passive, odd pins left and even pins right. `MP1...MP4` are included as passive mounting pins at symbol ends.
- `Connector FFC-FPC.SchLib`: 12 symbols. Sampled the active reference `5-520314-4`. Existing symbols use `X?`, `Manufacturer=TE Connectivity`, `ValueType=Разъём`, and simple passive contacts on the left in ascending order.
- `Connector USB.SchLib`: 11 symbols. Sampled `USB4110`. USB receptacles use `XS?`, `ValueType=Разъём USB`, and `PartNumber` set to `=Comment`. Type-C merged pins use combined designators such as `A1/B12`. USB data, CC, and SBU pins use `eElectricIO` on the left; VBUS/GND and shield mounting pins are on the right. Shield pins are passive and use `MP` pin numbers with visible name `Shield`.

IC libraries:

- `MCU.SchLib`: 35 symbols. Sampled `STM32H743VIH6`. Existing MCU symbols use `DD?`, `ValueType=Микросхема`, and multi-part partitioning for dense devices. The sampled STM32H743 uses 5 parts: GPIO ports, miscellaneous/reset/clock, and a separate power part. GPIO pins use `eElectricIO`; reset/boot pins use input where appropriate; power pins use `eElectricPower`. Ball-grid pin numbers such as `G2` and `A10` are preserved.
- `MPU.SchLib`: 2 symbols. Sampled active `Hi3516ARBCV300`. Existing MPU symbols use `DD?`, `ValueType=Микросхема`, and 5 parts. Dense SoC symbols group major domains such as power, flash/eMMC/SFC, UART/GPIO, clocks, and DDR. DDR address/control pins are outputs, DDR data pins are IO, crystal pins use input/output, and no-connect pins are passive.
- `RF Active.SchLib`: 13 symbols. Sampled active `GSL809AD`. Existing RF active symbols use `DA?`. RF input is on the left as `eElectricInput`; RF output is on the right as `eElectricOutput`; enable/control and bias supply are grouped separately. PAD is pin number package count plus one and uses `eElectricPower` on the right.
- `Opamp.SchLib`: 12 symbols. Sampled active `544УД7Р3`. Existing quad op-amps use `DA?` and 5 parts: four amplifier units plus a separate power part. Amplifier parts place `IN+` and `IN-` on the left and `OUT` on the right. Existing op-amp signal pins are passive in this library; power pins use `eElectricPower`.
- `Interface.SchLib`: 25 symbols. Sampled `CH9114F` and `CH334P`. Existing interface ICs use `DD?`, `ValueType=Микросхема`, and `PartNumber` set to `=Comment`. CH9114F groups USB, UART channel pins, reset, crystal, power, and PAD on a single part. CH334P uses a wide center label `USB Hub`, vertical side-section dividers, and horizontal delimiter lines between functional groups.
- `Isolation.SchLib`: 3 symbols. Sampled `ADUM1401BRWZ`. Existing isolation symbols use `DD?`. Side 1 pins are on the left and side 2 pins are on the right. Power domains stay with their side: `VDD1/GND1` left and `VDD2/GND2` right. Signal direction is preserved with input/output electrical types across the barrier.

## Naming Convention

Symbol names should match the library's design item ID style and should be suitable as the component `Comment`. Prefer the manufacturer ordering and exact family/package suffix used by the part number:

- Connectors: use the complete orderable connector or family-derived identifier, for example `DF40C-40DP-0.4V` or a JST GH orderable number.
- ICs: use the exact ordering code when one footprint/package variant matters; otherwise use the common device name that matches the library entry.
- Multi-part op-amps and isolators: keep one design item per device/package variant, not one per channel.

Set component metadata consistently:

- `Comment`: equal to the Design Item ID / LibReference.
- `PartNumber`: exactly `=Comment`.
- `Description`: concise, product-selection facts only. Do not include generation provenance.
- Pin descriptions: copied from the datasheet, never inherited blindly from a reference symbol.

For DF40 and BM10 board-to-board connectors, descriptions should use comma-separated clauses and omit manufacturer and part number, for example:

```text
16 Position Header, 0.4mm Contact Pitch, Stacking Height 0.8mm
```

Use `Mezzanine`, not `Mezzanine Connector`, in connector descriptions.

For existing JST GH, FFC-FPC, and USB connector families, preserve the family wording already used by the target library when updating sibling symbols, for example `GH series 1.25 mm pitch SMT top entry header 8 circuits` or `USB 2.0 Connector Type C 16P SMT Horizontal Receptacle`. For new connector families, prefer the structured comma-separated style unless the destination library already has a clearer local pattern.

## Designators

Default designators:

- `XP?`: connector headers, plugs, board-to-board headers, pin headers.
- `XS?`: connector sockets, receptacles, FFC/FPC sockets, USB receptacles.
- `X?`: preserve for existing simple wire/FFC/JST connector families that already use it.
- `DD?`: MCU, MPU, interface ICs, digital isolators, and other digital/mixed-signal ICs in the sampled GOST libraries.
- `DA?`: RF active ICs and op-amps in the sampled GOST libraries.

No sampled target library used `U?`. Do not introduce `U?` for these GOST libraries unless a separate target library or explicit user request shows that convention.

Do not add part numbers, comments, LibReferences, or manufacturer names as graphical text inside the symbol body. Only draw explicit functional labels such as `USB Hub` when they clarify the symbol.

## Grid, Units, and Coordinates

Use the 2.5 mm schematic grid for every generated symbol primitive:

- One grid step is `98.425 mil`.
- Use exact 2.5 mm-grid mil values in `create_schematic_symbol`.
- Do not round the row pitch to `200 mil`; it creates uneven snapped spacing.
- The top-left pin row starts at `Y = -2.5 mm`.
- Build pin groups downward from that anchor.
- Body borders, delimiter lines, labels, parameters, and designator positions must also snap to the 2.5 mm grid unless text centering requires a small off-grid X origin.

For generated symbols, pins belong only on the left and right sides. Do not place pins on the top or bottom.

## Fonts and Primitive Style

Never use Altium default styling for GOST schematic-library symbols. Always apply the fixed GOST defaults below to generated pins, labels, delimiters, body primitives, component designator, visible parameters, and pin text. Use an open/reference component to confirm family geometry, proportions, grouping, and placement conventions, not as permission to keep Altium defaults.

- font family: `GOST type B` as shown in the Altium font selector; do not substitute Arial, Times New Roman, or Altium defaults for schematic symbols.
- font size: `12` for pin names, pin designators, body labels, component designator, and visible parameters unless the sampled family reference explicitly uses another fixed size.
- text style: regular upright text, not bold, not italic, not underlined.
- line width: Altium `eSmall` schematic line width for body rectangles, vertical splitters, horizontal delimiters, and pin strokes.
- color: black
- pin length
- body and delimiter style

The MCP reference dump exposes pin placement and metadata. For exact primitive/font auditing, use the MCP read-only `get_library_symbol_primitive_font_dump` on the active SchLib symbol rather than reading `.SchLib` files directly. Generated symbols still must use the fixed GOST defaults: `GOST type B`, font size 12, regular style, Altium `eSmall` line width, black drawing primitives, and a 5.0 mm fixed pin length.

## Pin Names and Pin Style

Use datasheet pin names exactly enough to preserve electrical meaning, while keeping library style readable.

- Active-low names: use Altium overbar syntax by placing a backslash after each overbarred character, for example `R\E\S\E\T\`.
- Exposed pad, thermal pad, or center pad: name it `PAD`, set pin number to package pin count plus one, and use `eElectricPower`.
- Do not name an exposed pad `GND` unless the datasheet truly names the package pin that way.
- No-connect pins: keep the datasheet pin name or use `NC`; place them as a separate low-priority group.
- Mechanical connector pins with pin numbers or names beginning with `MP`: hide the pin designator/pin number and leave the pin name visible.
- Pin length: fixed 5.0 mm for all generated pins.
- Pin-name font: enable `Custom Settings`; use `GOST type B`, size 12, black, regular.
- Pin-designator font: enable `Custom Settings`; use `GOST type B`, size 12, black, regular.
- Pin-name margin: enable `Custom Margin`; set `X = 0 mm`, `Y = 0 mm`.
- Pin-designator margin: enable `Custom Margin`; set `X = 1 mm`, `Y = 0 mm`.

Recommended electrical types:

- Power rails, grounds, exposed pads: `eElectricPower`.
- Digital and analog inputs: `eElectricInput`.
- Digital and analog outputs: `eElectricOutput`.
- Bidirectional buses and configurable GPIO: `eElectricIO`.
- Passive connector contacts, jumpers, shields, and simple analog pass-through pins: `eElectricPassive`.
- Open-drain/open-collector outputs: `eElectricOpenCollector` when the datasheet calls this out.
- High-impedance or tri-state pins: `eElectricHiZ` only when that behavior is the defining pin function.

## Pin Grouping and Side Selection

Group pins by function first, then by signal flow. Keep related buses together and preserve natural numeric order inside a group unless the interface convention has a clearer order.

General side rules:

- Inputs on the left.
- Outputs on the right.
- Bidirectional and passive connector contacts may be placed by physical/contact order, usually left side for simple single-column connectors.
- Power pins start at the bottom-left and fill upward.
- `PAD`, `GND`, shields, and chassis pins go in the bottom-right corner, with `PAD` as the lowest pin when present.
- No-connect pins go above `PAD`/`GND` in the bottom-right when present.
- Crystal oscillator pins go on the right, with oscillator output above oscillator input and 10 mm spacing inside the oscillator group.

Family guidance:

- Board-to-board mezzanine connectors: use two-sided contact order. Place odd-numbered contacts on the left and even-numbered contacts on the right. Keep `MP` mounting pins at the top and/or bottom rows matching the sampled reference, not mixed into signal contact order.
- JST GH and FFC/FPC connectors: use simple single-column contact order on the left for low pin-count families. Place mounting pads on the right when present.
- USB connectors: group `VBUS`, `CC`, `D+`, `D-`, SuperSpeed pairs, SBU, shield, and ground separately. Keep differential pairs adjacent. For Type-C, preserve combined pin-number notation such as `A1/B12` when contacts are shorted in the connector.
- MCU and MPU symbols: group power, reset/boot/debug, clocks, GPIO ports, serial buses, memory interfaces, analog, and special functions. Use multi-part symbols for dense packages; the sampled MCU/MPU references both use 5 parts.
- RF active symbols: group RF input, RF output, enable/control, supplies, no-connect pins, and exposed pad. Keep RF input on the left and RF output on the right.
- Op-amps: use multi-part symbols for multi-channel devices. Put non-inverting and inverting inputs on the left and output on the right; place shared supplies in a separate power part when that matches the library family.
- Interface ICs: group by functional channels and external bus domains. For USB-to-UART parts, keep USB upstream pins together, UART channel groups together, crystal pins on the right, and PAD/power pins in their own group.
- Isolation parts: place side 1 pins on the left and side 2 pins on the right. Keep isolated power domains on their respective sides and align channels by function across the barrier.

## Pin Spacing

Default pin row pitch is one 2.5 mm grid step.

- Separate functional groups by one additional empty 2.5 mm row.
- When there is extra room, distribute group gaps evenly.
- Do not place a delimiter through a pin row or through pin-name text.
- Keep long pin names clear of body borders and divider lines.

For dense MCU/MPU devices, prefer taller symbols over compressed or overlapping pin labels. For very dense packages, split into logical multi-part symbols if the existing library family style supports it.

## Splitters and Delimiters

Use splitters only when they improve readability or match a reference style.

Vertical splitters:

- Default connector symbols to no generated vertical separator lines.
- Preserve vertical lines when they exist in the reference symbol.
- Do not add gaps in vertical divider lines unless the requested symbol geometry explicitly requires it.
- For symbols with left/center/right sections, keep left and right side-section widths equal and compact.
- Size side sections from the widest pin-name label plus one 2.5 mm clearance step, rounded to the 2.5 mm grid.
- For CH334P-style grouped interface symbols, use vertical dividers to create left pin-name section, center functional-label section, and right pin-name section. Keep the center section wide enough for the functional label only.

Horizontal splitters:

- Draw only between functional pin groups.
- Place on the 2.5 mm grid, normally halfway through the empty row between groups.
- Use short left/right section delimiters so the center label area stays clean unless the reference uses full-width lines.
- Never put a horizontal line inside a group.
- In the sampled CH334P reference, horizontal delimiter lines separate upstream USB, control, power, downstream USB groups, and oscillator area. Follow that pattern for grouped hubs and similar interface symbols.

For CH334P-style grouped symbols, keep the body top and bottom one 2.5 mm grid step outside the top and bottom pin extents. Functional center labels should sit near the top center of the full body, one 2.5 mm step below the top pin row/body top reference.

## Footprint Parameters

Schematic symbols should carry footprint links as parameters rather than graphical text.

Recommended parameter fields:

- `Footprint`: primary footprint model name used by the integrated library flow.
- `Package`: package or connector form factor when useful for selection.
- `Pitch`: connector contact pitch or package pitch when relevant.
- `Positions`: connector contact count when relevant.
- `Rows`: row count for connectors when relevant.
- `Orientation`: top-entry, side-entry, right-angle, vertical, horizontal, or equivalent vendor wording.
- `Mounting`: SMT, through-hole, hybrid, locating pegs, mounting pads, or shield tabs when relevant.
- `StackingHeight`: board-to-board connector stacking height when relevant.
- `MatingPart`: mating connector family or part when this is critical for board-to-board and wire-to-board selection.
- `Value`: only when the library family uses it for schematic presentation.

Keep footprint names and parameters aligned with the PcbLib naming rules in `Footrpint.md` and the README's footprint-description guidance.

## Creation Checklist

Before calling `create_schematic_symbol`:

1. Run `get_symbol_placement_rules`.
2. Open a close reference with `search_library_symbol`.
3. Capture style with `get_library_symbol_reference`.
4. Run `get_library_symbol_primitive_font_dump` when an exact primitive/font audit is needed.
5. Decide the symbol name, designator prefix, description, and core parameters.
6. Build pin groups, side assignment, and delimiter plan.
7. Explain pin-placement choices before creation.
8. Pass exact 2.5 mm-grid coordinates and owner part IDs.

After creation:

1. Use a schematic screenshot only for visual QA when needed.
2. Check long pin names against borders and splitters.
3. Check hidden connector mounting-pin designators.
4. Check active-low overbars.
5. Check `Comment`, `PartNumber`, `Description`, footprint parameters, and pin descriptions.
6. Save only when requested.
