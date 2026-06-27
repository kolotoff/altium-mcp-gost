---
name: import-ultralibrarian-footprint
description: Import Ultra Librarian footprint preview geometry into an active Altium PcbLib through altium-mcp. Use when a user asks to create or import an Altium PCB footprint from Ultra Librarian, vendor.ultralibrarian.com, a saved Ultra Librarian SVG preview, or a part page whose native CAD download is gated, and especially when the footprint should get a suffix such as _UL for comparison against an existing library footprint.
---

# Import Ultra Librarian Footprint

## Workflow

1. Use official/vendor-linked Ultra Librarian sources first. Prefer the native Altium export if it is available without interactive gates. If export is blocked by login, terms, captcha, queue failure, or HTTP errors, use the public footprint preview SVG and state that the result is preview-derived.
2. Save the detailed footprint preview SVG under the task workspace, not inside the common script or MCP server code. Keep the raw SVG for auditability.
3. Generate a PcbLib batch file with `scripts/ul_svg_to_pcblib_batch.py`.
4. Create a new footprint with a suffix such as `_UL`; do not overwrite the existing footprint unless the user explicitly requests replacement.
5. Apply the batch through `mcp__altium.move_pcb_library_mechanical_layers`:

```text
PCB_LIB_BATCH_CREATE|<batch_file>|TRUE
```

6. Verify with `mcp__altium.get_pcblib_footprints` and `mcp__altium.get_pcblib_footprint_primitives`.
7. Run `PCB_POSTPROCESS` after the last PcbLib mutation. Do not save the library unless the user explicitly asks.

## Generate The Batch

Use the helper on a saved Ultra Librarian SVG preview:

```bash
python skills/import-ultralibrarian-footprint/scripts/ul_svg_to_pcblib_batch.py \
  --svg downloads/part/detailed-footprint.svg \
  --name DFN1110-3A_VIS_UL \
  --description "Ultra Librarian preview-derived footprint for <part>" \
  --out downloads/part/footprint_ul_batch.txt
```

The script assumes Ultra Librarian SVG coordinates are mils and converts to mm. It flips SVG Y into Altium Y. It maps:

- `TOP` rectangles and orthogonal polygons to top-layer pads.
- `TOP_ASSEMBLY` lines to `Mechanical Layer 2`.
- `TOP_SILKSCREEN` circular pin marks to `Top Overlay`.
- Pad extents plus margin to a `Mechanical Layer 3` courtyard and center marks.

Ultra Librarian often represents unusual copper, such as stepped pads, as polygons. The MCP batch format supports rectangular pads, not copper polygons, so the helper decomposes orthogonal polygons into one or more rectangular same-pin pads. Mention this approximation in the final report when it occurs.

## Altium Rules

- Use `mcp__altium` tools for all active Altium document/library operations.
- Keep `.Designator` and `.Comment` on `Mechanical Layer 2`.
- Keep courtyard and component center marks on `Mechanical Layer 3`.
- Keep 3D bodies on `Mechanical Layer 1`; this preview-import workflow does not add a 3D model unless a real STEP source is separately available.
- Avoid dense silkscreen on tiny packages. Import only clear pin-1 marks from the Ultra Librarian silkscreen preview.
- Treat MCP timeouts as inconclusive. Read back the footprint list and primitives before retrying or recreating.

## Report

Include:

- Footprint name and active library state.
- Source URL or SVG file used.
- Whether the result came from native CAD export or preview-derived geometry.
- Pads, important mechanical layers, and any polygon-to-rectangle approximations.
- Confirmation that `PCB_POSTPROCESS` was run.
- Save state: explicitly say whether the library was left dirty or saved.
