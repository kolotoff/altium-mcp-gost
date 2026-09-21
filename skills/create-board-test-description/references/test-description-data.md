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

The paired 3D export writes `pcb-3d-registration.json` beside its PNGs. It
contains the physical camera bounds for each side. This file is mandatory for
3D maps and SVG-derived crops because Altium frames protruding component bodies,
not only the PCB outline. Do not replace it with left/right alignment guesses.
Registration is export-specific: its camera bounds, mirror state, and image
dimensions must match the exact PNG pair. Never copy it between boards, DPI
settings, or exports.

For an export made by the legacy opaque renderer, flatten the workspace before
building dependent assets:

```powershell
python tools\normalize_pcb_3d_background.py `
  --top "<raw>/pcb-3d-top.png" --bottom "<raw>/pcb-3d-bottom.png" `
  --output-dir "<renders>" --background "#FFFFFF"
```

```powershell
python tools\generate_board_test_maps.py `
  --inventory "<inventory.json>" `
  --top-svg "<pcb-assembly-top.svg>" --bottom-svg "<pcb-assembly-bottom.svg>" `
  --language-mode "<source|ru|en|zh|en-zh>" `
  --output-dir "<maps>"

python tools\generate_board_test_3d_maps.py `
  --top-map "<maps>/pcb-test-map-top.svg" --bottom-map "<maps>/pcb-test-map-bottom.svg" `
  --top-render "<pcb-3d-top.png>" --bottom-render "<pcb-3d-bottom.png>" `
  --registration "<pcb-3d-registration.json>" `
  --language-mode "<source|ru|en|zh|en-zh>" `
  --output-dir "<maps>"

python tools\crop_native_pcb_3d_export.py `
  --top "<pcb-3d-top.png>" --bottom "<pcb-3d-bottom.png>" `
  --top-svg "<pcb-assembly-top.svg>" --bottom-svg "<pcb-assembly-bottom.svg>" `
  --registration "<pcb-3d-registration.json>" `
  --components "<inventory.json>" --output-dir "<crops>" `
  --language-mode "<source|ru|en|zh|en-zh>" `
  --contact-sheet "<crop-review.png>"
```

Rasterize map SVGs to same-named PNG fallbacks with `tools/rasterize_svg_directory.cjs` using the bundled Node runtime and its package path. The DOCX embeds the SVG plus PNG fallback.

## DOCX specification

The generator accepts a JSON object with this shape (paths may be absolute or relative to the JSON file):

```json
{
  "board_name": "Main_v1.5X",
  "title": "ОПИСАНИЕ ТЕСТОВОГО ДОСТУПА ПЛАТЫ Main_v1.5X",
  "subtitle": "Main_v1.5X",
  "footer_label": "Main_v1.5X",
  "summary_intro": "Verified scope of the open board",
  "summary_rows": [["Test points", "Count and selection rule"]],
  "board_renders": [
    {"title": "Top 3D", "image": "pcb-3d-top.png"},
    {"title": "Bottom 3D", "image": "pcb-3d-bottom.png"}
  ],
  "test_maps": [
    {
      "title": "Top test map", "image": "pcb-test-map-top.svg", "fallback_image": "pcb-test-map-top.png",
      "render_3d": {"title": "Top annotated 3D map", "image": "pcb-test-3d-map-top.svg", "fallback_image": "pcb-test-3d-map-top.png"}
    },
    {
      "title": "Bottom test map", "image": "pcb-test-map-bottom.svg", "fallback_image": "pcb-test-map-bottom.png",
      "render_3d": {"title": "Bottom annotated 3D map", "image": "pcb-test-3d-map-bottom.svg", "fallback_image": "pcb-test-3d-map-bottom.png"}
    }
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

`board_name` is a technical identifier, not display prose. Copy it verbatim
from the Altium document name or approved project identifier. Preserve all
dots, underscores, hyphens, spaces, revision markers, and other symbols. The
localized `title` and `subtitle` must contain this exact value; generation fails
when either field contains a normalized or prettified variant.

## English and Chinese option

For one combined English and Simplified Chinese document, pass:

```powershell
python tools\generate_board_test_description_docx.py `
  --data "<board-test-description.json>" `
  --language-mode en-zh --translations "<en-zh-translations.json>" `
  --output "<board-test-description-en-zh.docx>"
```

The translation catalog is an object keyed by exact source strings. Each value
contains complete `en` and `zh` translations:

```json
{
  "Source heading": {
    "en": "English heading",
    "zh": "中文标题"
  }
}
```

Catalog entries apply to titles, summary rows, group titles and introductions,
item names and descriptions, and document metadata. Technical identifiers that
are absent from the catalog remain unchanged. Map headings and legends, table
headers, side names, footer text, and crop-side labels use the generator's
built-in localization. Use the same language mode for every dependent asset so
the DOCX does not mix source-language maps with bilingual prose.

Use `--language-mode ru` for a reusable explicitly Russian output. Russian UI
labels are built in; source prose is retained when it is already Russian, so a
translation catalog is optional for this mode.

Each `render_3d` entry is paired with the assembly-SVG map immediately before it. Use the same callout labels and leader routes, but omit drawn endpoint circles on the 3D overlay. Every in-scope designator must appear exactly once in `groups`; each selected pad must be listed. A component in more than one category is listed once and counted in all applicable category totals. Keep local board net and source net separate even when equal. The document generator rejects duplicate designators and unresolved generated source nets.
