---
name: create-board-test-description
description: Inspect the currently open Altium PCB and create a board test-access DOCX with orthographic top/bottom 3D views, labeled vector maps, per-item crops, and verified source nets. Use for test-point and manufacturing-test access descriptions, not general connector user manuals.
---

# Create Board Test Description

Create a test-access document from the **currently open PCB**, without editing or saving the Altium design. Follow the repository `AGENTS.md` rules. This is a focused companion to `skills/create-board-description/SKILL.md`; its end-user mode is a useful reference for 3D/SVG export and net tracing, but a test description has different selection and layout rules.

## Inventory

Use `mcp__altium` readback from the active PCB. Select the union of:

1. Every component whose footprint name contains `TESTPOINT` (including net-named designators).
2. Every `SB*` designator. Identify actual solder bridges from the footprint; describe a switch or other control honestly rather than treating every `SB*` item as a solder bridge.
3. Every component with footprint `Keystone 5016`.
4. Every component pad with a real drilled hole of at least **1.00 mm**, a nonempty assigned PCB net, and a pad name that does not start with `MP` (case-insensitive). Select the component once, but list every qualifying pad. Do not infer hole diameter from the copper-pad dimensions or the assembly SVG's standalone mounting-hole circles.

The `get_component_pins` readback includes `hole_size` in **mils**; multiply by `0.0254` for millimetres. If a deployed server does not expose `hole_size`, add or restore that read-only field and re-query before asserting the hole set. `scripts/prepare_test_inventory.py` validates and deduplicates the readback; see [references/test-description-data.md](references/test-description-data.md) before preparing its input.

For each listed pad, retain the local PCB net and trace to a meaningful source net or source IC signal where the local name is generated or separated by a resistor, filter, selector, or bridge. Verify the connectivity before substituting names. The inventory helper refuses unresolved `Net*` source names; provide reviewed source-net overrides. An IC pin-function inference from a manufacturer pinout must be identified as such when the schematic net name is unavailable. Do not silently relabel an uncertain net.

## Images and document

- Export top and bottom orthographic PCB 3D PNGs with `export_pcb_3d_images`. Export top and mirrored bottom assembly SVGs with `export_pcb_assembly_images(keep_svg=True)`. These Altium exports are read-only and must not save the PCB.
- Build a labeled top and bottom test map from those assembly SVGs using `tools/generate_board_test_maps.py`. Keep the original board outline, component geometry, and mounting-hole circles. Hide the general copper `Pads` group, then place indexed markers at the actual component coordinates and a designator/source-net legend on each side. Do not accept missing or duplicated labels, untraceable marker IDs, overlapping legend text, or misleading leader lines.
- Generate the **same-sized local 3D crop style** for every selected test point and component with `tools/crop_native_pcb_3d_export.py --top-svg ... --bottom-svg ...`. The crop must come from the correct side of the same 3D export, center the selected item, and show its designator and locator. Visually inspect a contact sheet and fix orientation/crop exceptions.
- Create a task-local JSON specification following [references/test-description-data.md](references/test-description-data.md), then run `tools/generate_board_test_description_docx.py`. Start with the two full-board 3D views and the two labeled SVG maps. Give each selected item a local crop and a pad table with pad number, PCB net, source net, and hole diameter when applicable. For solder bridges, state default open/closed state and the exact effect of changing it. Include a concise selection-rule/count summary.
- Use the `documents` skill's render-and-inspect workflow. On Windows, if its bundled renderer cannot find LibreOffice, export a temporary PDF through installed Word and rasterize every page with the bundled Poppler tools. Inspect every page for clipping, orphaned tables, unreadable maps, and blank pages. Check unique-item and per-category counts against the Altium inventory, and search extracted text for unresolved generated net names. Deliver the DOCX only after visual and content QA.

Do not save the open PCB. Report if Altium's saved/dirty state is ambiguous or changes unexpectedly.
