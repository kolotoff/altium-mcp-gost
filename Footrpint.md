# Footprint Creation Rules and Research

This document captures common footprint creation rules for the Altium GOST footprint libraries. It is based on `D:\Develop\Hardware\altium-gost-libraries\Footprint\#Rules.txt`, the Altium MCP README, and read-only MCP inspection of these libraries:

- `Connector Board-To-Board HRS DF40.PcbLib`
- `Connector 1.25mm Pitch JST GH.PcbLib`
- `Connector Board-To-Board.PcbLib`
- `QFN.PcbLib`
- `BGA.PcbLib`
- `Connector FFC-FPC.PcbLib`
- `Connector USB.PcbLib`

## MCP Research Workflow

Use Altium MCP for `.PcbLib` research and edits. Do not parse `.PcbLib` files directly.

Open or focus a library by absolute path through the generic PcbLib command channel:

```text
move_pcb_library_mechanical_layers(
  exclude_footprint_names=[],
  layer_moves=["PCB_LIB_OPEN|D:\Develop\Hardware\altium-gost-libraries\Footprint\QFN.PcbLib"]
)
```

Then use:

- `get_pcblib_footprints` to list the active library footprint names.
- `PCB_LIB_STATS_DUMP|*` through `move_pcb_library_mechanical_layers` for compact read-only research across the active library.
- `PCB_LIB_STATS_DUMP|<footprint>` for one footprint.
- `FOOTPRINT_PRIMITIVE_DUMP|<footprint>` only when exact pad, track, arc, text, or 3D body coordinates are required.
- `PCB_LIB_DESCRIPTION_DUMP|*` to audit descriptions.
- `PCB_LIB_BATCH_CREATE|<data_file>|<skip_existing>` for repeatable batch creation or refresh.
- `PCB_LIB_SET_DESCRIPTION|<footprint>|<description>` for description fixes.
- `3D_BODY_IMPORT`, `3D_BODY_SET_PLACEMENT`, `3D_BODY_SET_IDENTIFIER`, and `3D_BODY_DUMP` for STEP body placement work.
- `PCB_POSTPROCESS` after any mutating PcbLib command, before user inspection or manual save.

Do not save PcbLib documents automatically unless the user explicitly asks for saving.

## Layer Usage

Use these layers consistently:

- `Top Layer` and `Bottom Layer`: copper pads. Prefer `Top Layer`; use `Bottom Layer` only when the real connector or package has contacts on both sides.
- `Multi Layer`: through-hole pads, locating pegs, mounting holes, and plated or non-plated mechanical holes.
- `Top Overlay` and `Bottom Overlay`: silkscreen. Preferred and minimum line width is `0.2 mm`. Keep silkscreen outside pads and mask openings. For very small packages such as 0402 and small QFN, omit silkscreen on top of or inside the package body.
- `Top Solder` and `Bottom Solder`: solder mask generated from rules by default. Minimum expansion/clearance target is `0.1 mm`, or `0.075 mm` for class 5 complexity when required.
- `Top Paste` and `Bottom Paste`: solder paste openings only when required. Adjust exposed-pad paste patterns according to package recommendations.
- `Mechanical Layer 1`: exact 3D body/model layer.
- `Mechanical Layer 2`: 2D body projection and assembly drawing. Include the pin-1 mark for parts with more than two pins, and include `.Designator` and `.Comment`, normally centered around the component/projection when practical.
- `Mechanical Layer 3`: package courtyard/body extents and component center for automated assembly. Use a rectangle or circle as appropriate, and include pin-1 indication inside the outline.
- `Mechanical Layer 4`: debug/test/programming connectors, labels, and test-point information. For footprints that do not represent an assembled component, use Mechanical 4 instead of Mechanical 2/3 when the object is only for test/debug access.
- `Mechanical Layers 5, 6, 7, 8`: paired bottom-side equivalents of Mechanical 1, 2, 3, and 4.

Observed convention: mature connector libraries use Mechanical 2 projection tracks at `0.1 mm`, Mechanical 3 outline/center tracks at `0.1 to 0.2 mm`, and overlay at `0.2 mm` with larger pin-1 dots or arcs where needed. Normalize imported or legacy imperial overlay widths to metric multiples: replace `0.254 mm * n` with `0.2 mm * n`, for example `0.254 mm` becomes `0.2 mm` and `0.508 mm` becomes `0.4 mm`.

## Naming Rules

Package-style footprints should use uppercase English names for imported parts:

```text
<PACKAGE><PIN_COUNT>-P<PITCH_MM>-V<VIA_DIAMETER_MM>-S<BODY_SIZE_MM>(<OPTIONAL_CODE>)
```

Examples:

- `BGA100-P0.5`
- `QFN42-P0.4-V0.3`
- `UFBGA100-P0.5-S7X7MM`
- `WLCSP64-P0.5-H0.3`
- `QFN20-P0.5-V0.3-3X3MM(EFM8BB2-QFN20R)`

Rules:

- Start with the package type or exact manufacturer footprint family.
- Add pin/ball count immediately after the package type when the footprint is package-generic.
- Use `-P` for pitch in millimeters.
- Use `-V` for thermal or fanout via diameter when applicable. Preferred via diameter is `0.3 mm` unless the package requires otherwise.
- Use `-S` when the same pin count and pitch can map to multiple body sizes. Use `-S<width>X<height>MM`, or include height as needed, for example `-S7.5X13.5X1.2MM`.
- Use a manufacturer/package code in parentheses when it disambiguates a package, such as `(RSG)`, `(RHA)`, or `(RK806)`.
- If a footprint is suitable only for one component, use the component or manufacturer part number, for example `SIM800C`, `USB4105`, or `DF40C-20DS-0.4V`.
- Imported component names are English uppercase. Domestic footprints may use Russian names.
- If a domestic footprint has a foreign analog, put the foreign analog in parentheses after the domestic name, and keep a separate imported-component copy without the Russian name.
- Avoid ambiguous pitch tokens such as `P.08` or `P.065`; use `P0.8` and `P0.65`.

Connector libraries commonly use manufacturer part numbers or connector series names because connector selection depends on orientation, latch, stack height, entry side, shield style, and exact mating family.

## Descriptions and Comment Field

Descriptions must describe the part or package, not the generation method.

Include useful selection facts:

- Manufacturer or series.
- Connector/package role.
- Pin, position, or circuit count.
- Pitch.
- Orientation or entry style.
- Mating/stacking height for board-to-board connectors.
- Body size and height for IC packages.
- Exposed pad and via diameter where relevant.
- Important ratings or contact style when they affect footprint choice.

Do not include provenance text such as `generated from`, `copied from`, or a reference footprint name.

If the footprint corresponds to a manufacturer package code, place that package code in the component `Comment` field. Example: a footprint named `WLCSP28-P0.4-S3X2MM` may carry a TI package code such as `YFP (R-XBGA-N28)`.

## Pad Style and Numbering

General pad rules:

- Every pad, mounting hole, and mounting pad name must be unique.
- Use numeric pad names for normal pin packages and connectors.
- Use BGA row/column names for BGA/WLCSP balls, such as `A1`.
- Use `MH1`, `MH2`, etc. for mounting holes.
- Use `MP1`, `MP2`, etc. for mounting pads.
- SMD pads should be rounded rectangle when possible.
- Through-hole pin 1 should be rounded rectangle.
- BGA/WLCSP balls should be round.
- Connector shield pads and mechanical retention pads should be named and documented, not left anonymous.
- Use default solder-mask opening from rules unless a package-specific requirement overrides it.
- Use paste openings only where solder is intended. Do not paste non-soldered locating holes or pegs.

Observed pad shape IDs from MCP:

- Shape `9`: rounded rectangle, used broadly for SMD connector pads and many modern QFN pads.
- Shape `1`: round/rectangular legacy style depending on pad context; observed for BGA balls, through-hole pads, mounting holes, and some older QFN signal pads.

For new work, prefer rounded-rectangle SMD pads and reserve round pads for BGA balls and holes.

## Footprint Geometry and Parameters

Use millimeters for all footprint geometry.

- Place the component origin at the physical body center.
- Keep the body center and origin aligned.
- Symmetric packages should be symmetric around `(0, 0)`.
- For connectors, align the origin to the package/body center unless the manufacturer drawing gives a more useful placement datum.
- Use the datasheet land pattern when available. If IPC generation is needed, record the density assumption in the description only when it matters.
- Keep silkscreen clear of copper pads and mask openings.
- Do not let connector silkscreen extend outside the intended board edge or mechanical keep-in area.
- Add pin-1 indication on Mechanical 2 and Mechanical 3. Add a silkscreen pin-1 mark only when it remains clear and useful.
- For QFN exposed pads, model the exposed pad as its own pad and add thermal vias/paste pattern when required by the package or reference layout.
- Use `NOEP` in the footprint name only when the package has no exposed pad.

## 3D Body Rules

An accurate 3D model is mandatory.

- Use the vendor STEP file unchanged.
- Do not rotate, mirror, translate, or edit STEP geometry directly.
- Place the 3D body on Mechanical Layer 1.
- Set the 3D body identifier to the STEP file name without extension.
- Store placement in the Altium 3D body/model state: local X/Y, Rotation X/Y/Z, model Z, standoff, and overall height.
- Keep component-body standoff at `0 mm` unless the footprint has a documented reason to use another value.
- For existing embedded bodies, treat the embedded placement state as authoritative. Do not infer Z placement from similar footprint names.
- For non-zero PcbLib origins, apply origin correction to Altium body placement state only. Do not edit STEP coordinates.

Use `3D_BODY_DUMP` to verify body bounds and `PCB_POSTPROCESS` after scripted modifications.

## Library Research Notes

### Connector Board-To-Board HRS DF40

- 60 footprints inspected by MCP.
- Names are exact Hirose DF40/DF40HC series variants, for example `DF40C-20DS-0.4V` and `DF40HC(4.0)-90DS-0.4V`.
- Descriptions consistently include Hirose series, position count, plug/receptacle role, `0.4 mm` pitch, and mating height.
- SMD pads are on `Top Layer` and use rounded rectangle shape `9`.
- Typical DF40 signal pad sizes observed: `0.24 x 0.7 mm`, with auxiliary/mounting pads on small plug variants.
- Mechanical Layer 1 contains one 3D body per footprint.
- Mechanical Layer 2 contains dense 2D projections plus `.Designator` and `.Comment`.
- Mechanical Layer 3 contains outline and center primitives.
- Top Overlay uses `0.2 mm` outline segments and a larger pin-1 marker where useful.

### Connector 1.25mm Pitch JST GH

- 14 footprints inspected: `SM02B-GHS-TB` through `SM08B-GHS-TB`, and `BM02B-GHS-TBT` through `BM08B-GHS-TBT`.
- Names follow JST manufacturer part numbers because side/top entry and exact series are selection-critical.
- Pads are on `Top Layer`, rounded rectangle shape `9`.
- Signal pads are commonly `0.6 x 1.7 mm`; retention pads are about `1.0 x 2.7/2.8 mm`.
- Mechanical Layer 2/3 and `.Designator`/`.Comment` usage is consistent.
- One 3D body is present on Mechanical Layer 1 for each footprint.

### Connector Board-To-Board

- 18 footprints inspected, including Molex SlimStack, YXT mezzanine, and Hirose BM10 variants.
- Names mix manufacturer part numbers and series names, which is appropriate for connector-specific footprints.
- SMD signal pads are rounded rectangle shape `9`.
- Locating pegs and through features appear as `Multi Layer` pads, usually shape `1`.
- Mechanical Layer 2/3 and Mechanical Layer 1 3D bodies are consistently present.
- Descriptions should be normalized where imported source text is noisy or contains encoding artifacts.

### QFN

- 31 footprints inspected.
- Names mostly follow `QFN<count>-P<pitch>-V<via>-S<size>(code)`, with useful variants such as `NOEP`.
- Exposed-pad packages include the exposed pad as an additional pad.
- Newer QFN footprints use rounded rectangle shape `9`; some legacy QFN footprints use shape `1` for signal pads.
- Small packages sometimes intentionally have no overlay inside the body; this matches the no-silkscreen-under-small-SMD rule.
- Some footprints have missing `.Designator`/`.Comment` text on Mechanical 2; new work should include these unless a documented exception applies.

### BGA

- 9 footprints inspected.
- Ball pads are on `Top Layer`, shape `1`, and sized according to pitch and package.
- Names include pin count, pitch, and body size, but some legacy names use `P.08` or `P.065`; normalize new names to `P0.8` and `P0.65`.
- Mechanical Layer 1 3D bodies, Mechanical Layer 2 assembly text, and Mechanical Layer 3 outline/center primitives are present.
- BGA descriptions vary in quality; new descriptions should include body size, pitch, ball count, array information when known, and package height.

### Connector FFC-FPC

- 12 footprints inspected.
- Names are manufacturer part numbers, appropriate for exact FFC/FPC connectors.
- SMD FFC/FPC footprints use rounded rectangle pads on `Top Layer`.
- Through-hole/right-angle legacy FFC connectors use `Multi Layer` pads, with pin 1 expected as rounded rectangle.
- Most footprints have 3D bodies and Mechanical 2 `.Designator`/`.Comment`; a few lack these texts and should be fixed during refresh.
- FFC/FPC footprints may have dense overlay/projection detail. Keep overlay useful but clear of pads and board edges.

### Connector USB

- 10 footprints inspected.
- Names are exact USB connector part numbers or concise connector identifiers.
- USB-C footprints may use `Top Layer`, `Bottom Layer`, and `Multi Layer` pads because contacts, shells, and mounting features can be on different sides.
- Signal SMD pads are rounded rectangle shape `9`; shell holes and mounting pads commonly use shape `1`.
- Mechanical Layer 1 bodies and Mechanical Layer 2 `.Designator`/`.Comment` are present.
- Some USB footprints include special Mechanical Layer 1 drawing primitives in addition to the 3D body; keep these only when they serve body/model documentation.

## Creation Checklist

Before saving a new or refreshed footprint:

- Name follows the package or manufacturer-part naming rule.
- Description contains selection facts and no provenance text.
- Origin is at body center.
- Pad names are unique and follow pin/BGA/MH/MP conventions.
- SMD pads are rounded rectangle unless the package type requires round pads.
- BGA/WLCSP balls are round and use row/column naming.
- Pin 1 is marked on Mechanical 2/3 and on overlay when useful.
- Mechanical Layer 1 has an accurate 3D model.
- Mechanical Layer 2 has 2D projection, `.Designator`, and `.Comment`.
- Mechanical Layer 3 has body/courtyard outline and center mark.
- Overlay is `0.2 mm` preferred/minimum and clear of pads; legacy `0.254 mm` imperial-width multiples are converted to `0.2 mm` metric multiples.
- Solder mask uses rule defaults unless explicitly required otherwise.
- Paste is present only where solder paste is intended.
- Bottom-side copper is used only for true two-sided contact geometry.
- Run `PCB_POSTPROCESS` after scripted edits.
- Leave the library dirty for user inspection unless the user explicitly asks to save.
