# Board test-description data

The task-local files below are generated from the active PCB and are **not** reusable board constants. Keep board-specific net aliases and descriptions outside the skill and common generators.

## Inventory input

Capture complete Altium `get_component_data` and `get_component_pins` results as JSON. Each can be either the result array or the MCP response object with a `result` array. The pin response must include `hole_size` in mils. Run:

```powershell
python skills\create-board-test-description\scripts\prepare_test_inventory.py `
  --components "<components.json>" --pins "<pins.json>" `
  --source-net-overrides "<reviewed-aliases.json>" `
  --output "<inventory.json>"
```

The optional override JSON maps `DESIGNATOR:PAD` (preferred), `DESIGNATOR.*`, or a local PCB net to a verified source name. Example: `{"SB2:2":"FAN_ON"}`. The helper stops if any selected pin's source net remains a generated `Net*` name.

`inventory.json` contains `counts` and a `components` array. Each component has `designator`, `categories`, `footprint`, `side`, placement data, and `pins`. Each pin has `pad`, `pcb_net`, `source_net`, and `hole_mm`. Preserve those fields and their meanings. Never use a through-hole pad's copper width or height as the hole diameter.

## Maps and crops

```powershell
python tools\generate_board_test_maps.py `
  --inventory "<inventory.json>" `
  --top-svg "<pcb-assembly-top.svg>" --bottom-svg "<pcb-assembly-bottom.svg>" `
  --output-dir "<maps>"

python tools\crop_native_pcb_3d_export.py `
  --top "<pcb-3d-top.png>" --bottom "<pcb-3d-bottom.png>" `
  --top-svg "<pcb-assembly-top.svg>" --bottom-svg "<pcb-assembly-bottom.svg>" `
  --components "<inventory.json>" --output-dir "<crops>" `
  --contact-sheet "<crop-review.png>"
```

Rasterize map SVGs to same-named PNG fallbacks with `tools/rasterize_svg_directory.cjs` using the bundled Node runtime and its package path. The DOCX embeds the SVG plus PNG fallback.

## DOCX specification

The generator accepts a JSON object with this shape (paths may be absolute or relative to the JSON file):

```json
{
  "title": "ОПИСАНИЕ ТЕСТОВОГО ДОСТУПА ПЛАТЫ",
  "subtitle": "Board name",
  "footer_label": "Board name",
  "summary_intro": "Verified scope of the open board",
  "summary_rows": [["Test points", "Count and selection rule"]],
  "board_renders": [
    {"title": "Top 3D", "image": "pcb-3d-top.png"},
    {"title": "Bottom 3D", "image": "pcb-3d-bottom.png"}
  ],
  "test_maps": [
    {"title": "Top test map", "image": "pcb-test-map-top.svg", "fallback_image": "pcb-test-map-top.png"},
    {"title": "Bottom test map", "image": "pcb-test-map-bottom.svg", "fallback_image": "pcb-test-map-bottom.png"}
  ],
  "groups": [
    {
      "title": "Test points",
      "items": [
        {
          "designator": "TP1",
          "name": "Test point",
          "side": "top",
          "footprint": "TESTPOINTSMD1MM",
          "image": "crops/TP1.png",
          "pins": [{"pad": "1", "pcb_net": "EXAMPLE", "source_net": "EXAMPLE", "hole_mm": 0}]
        }
      ]
    }
  ]
}
```

Every in-scope designator must appear exactly once in `groups`; each selected pad must be listed. A component in more than one category is listed once and counted in all applicable category totals. Keep local board net and source net separate even when equal. The document generator rejects duplicate designators and unresolved generated source nets.
