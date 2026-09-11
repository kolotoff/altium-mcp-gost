# Board-description JSON

Read this reference when preparing input for
`tools/generate_board_description_docx.py`.

## Required structure

```json
{
  "title": "ТЕХНИЧЕСКИЕ ХАРАКТЕРИСТИКИ",
  "subtitle": "печатной платы ExampleBoard",
  "footer_label": "ExampleBoard",
  "metadata": {
    "title": "Технические характеристики печатной платы ExampleBoard",
    "subject": "Назначение и основные параметры"
  },
  "layout": {
    "left_column_dxa": 3685,
    "right_column_dxa": 5783
  },
  "sections": [
    {
      "number": "01",
      "title": "Общие сведения",
      "rows": [
        ["Назначение", "Описание назначения платы"],
        ["Габаритные размеры", "100 × 50 мм"]
      ]
    }
  ]
}
```

Required top-level keys are `title`, `subtitle`, `footer_label`, and a non-empty
`sections` array. Each section requires `number`, `title`, and a non-empty `rows`
array. Every row is exactly two strings: the parameter and its value.

`metadata`, `layout`, and `colors` are optional. Default column widths are 3685
and 5783 dxa.

## Optional colors

Each value is a six-digit RGB string without a required leading `#`:

```json
{
  "colors": {
    "heading_number": "167FB5",
    "heading_text": "1D4059",
    "body_text": "334856",
    "alternate_row": "F2F6F8",
    "white": "FFFFFF",
    "footer": "607487"
  }
}
```

## Content rules

- Use Russian engineering notation consistently: decimal comma, en dash for
  ranges, `×` for dimensions, non-ambiguous units, and `°C` for temperature.
- Distinguish nominal, maximum, and calculated values.
- State whether aggregate power is a sum across independent outputs.
- Describe externally visible behavior rather than implementation designators.
- Keep unsupported capabilities out of the document even if a component
  datasheet lists them.

## Pre-generation checks

- The number of JSON sections equals the number of template tables.
- All requested corrections are represented exactly once.
- Required user values are present.
- Suppressed model names and positional designators are absent.
- Template and output paths are different unless overwriting was explicitly
  requested.
