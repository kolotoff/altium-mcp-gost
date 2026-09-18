"""Generate an end-user board reference DOCX from structured JSON.

This generator is intentionally separate from the manufacturing-oriented board
description generator.  It produces a connector manual: one image and one
pin-by-pin table per connector, plus concise functional sections for the CPU,
flight controller, memory, and onboard sensors.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from PIL import Image as PILImage
from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml import parse_xml
from docx.oxml.ns import qn
from docx.opc.constants import RELATIONSHIP_TYPE as RT
from docx.opc.packuri import PackURI
from docx.opc.part import Part
from docx.shared import Cm, Pt, RGBColor


class SpecError(ValueError):
    """Raised when input data cannot produce a safe end-user manual."""


COLORS = {
    "navy": "18324A",
    "blue": "1E6F9F",
    "cyan": "DDEFF7",
    "pale": "F3F7F9",
    "line": "BCD0DA",
    "text": "263746",
    "muted": "637785",
    "white": "FFFFFF",
}

FORBIDDEN_USER_CONTENT = (
    "минимальная ширина проводника",
    "минимальный электрический зазор",
    "minimum track width",
    "minimum electrical clearance",
)


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SpecError(f"{field} must be a non-empty string")
    return value.strip()


def set_cell_fill(cell, color: str) -> None:
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), color)


def set_cell_width(cell, width_dxa: int) -> None:
    tc_pr = cell._tc.get_or_add_tcPr()
    tc_w = tc_pr.find(qn("w:tcW"))
    if tc_w is None:
        tc_w = OxmlElement("w:tcW")
        tc_pr.append(tc_w)
    tc_w.set(qn("w:w"), str(width_dxa))
    tc_w.set(qn("w:type"), "dxa")


def set_cell_margins(cell, *, top=65, start=90, bottom=65, end=90) -> None:
    tc = cell._tc
    tc_pr = tc.get_or_add_tcPr()
    tc_mar = tc_pr.first_child_found_in("w:tcMar")
    if tc_mar is None:
        tc_mar = OxmlElement("w:tcMar")
        tc_pr.append(tc_mar)
    for edge, value in (("top", top), ("start", start), ("bottom", bottom), ("end", end)):
        node = tc_mar.find(qn(f"w:{edge}"))
        if node is None:
            node = OxmlElement(f"w:{edge}")
            tc_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def set_repeat_header(row) -> None:
    tr_pr = row._tr.get_or_add_trPr()
    if tr_pr.find(qn("w:tblHeader")) is None:
        tr_pr.append(OxmlElement("w:tblHeader"))


def set_cant_split(row) -> None:
    tr_pr = row._tr.get_or_add_trPr()
    if tr_pr.find(qn("w:cantSplit")) is None:
        tr_pr.append(OxmlElement("w:cantSplit"))


def set_keep_with_next(paragraph) -> None:
    p_pr = paragraph._p.get_or_add_pPr()
    if p_pr.find(qn("w:keepNext")) is None:
        p_pr.append(OxmlElement("w:keepNext"))


def clear_paragraph_borders(paragraph_or_style) -> None:
    element = paragraph_or_style._p if hasattr(paragraph_or_style, "_p") else paragraph_or_style._element
    p_pr = element.get_or_add_pPr()
    borders = p_pr.find(qn("w:pBdr"))
    if borders is not None:
        p_pr.remove(borders)


def set_table_borders(table, color: str = COLORS["line"], size: str = "5") -> None:
    tbl_pr = table._tbl.tblPr
    borders = tbl_pr.find(qn("w:tblBorders"))
    if borders is None:
        borders = OxmlElement("w:tblBorders")
        tbl_pr.append(borders)
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        element = borders.find(qn(f"w:{edge}"))
        if element is None:
            element = OxmlElement(f"w:{edge}")
            borders.append(element)
        element.set(qn("w:val"), "single")
        element.set(qn("w:sz"), size)
        element.set(qn("w:color"), color)


def style_run(run, *, size: float, bold=False, color=COLORS["text"], name="Aptos") -> None:
    run.font.name = name
    r_fonts = run._element.get_or_add_rPr().rFonts
    for attr in ("ascii", "hAnsi", "cs", "eastAsia"):
        r_fonts.set(qn(f"w:{attr}"), name)
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = RGBColor.from_string(color)


def add_text(paragraph, text: str, *, size=9.0, bold=False, color=COLORS["text"]):
    run = paragraph.add_run(text)
    style_run(run, size=size, bold=bold, color=color)
    return run


def set_cell_text(cell, text: str, *, bold=False, color=COLORS["text"], size=8.5) -> None:
    cell.text = ""
    paragraph = cell.paragraphs[0]
    paragraph.paragraph_format.space_before = Pt(0)
    paragraph.paragraph_format.space_after = Pt(0)
    paragraph.paragraph_format.line_spacing = 1.0
    add_text(paragraph, text, size=size, bold=bold, color=color)
    cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    set_cell_margins(cell)


def add_page_number(paragraph) -> None:
    paragraph.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    run = paragraph.add_run()
    fld_char = OxmlElement("w:fldChar")
    fld_char.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = " PAGE "
    separate = OxmlElement("w:fldChar")
    separate.set(qn("w:fldCharType"), "separate")
    text = OxmlElement("w:t")
    text.text = "1"
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    for element in (fld_char, instr, separate, text, end):
        run._r.append(element)
    style_run(run, size=8, color=COLORS["muted"])


def set_picture_alt(inline_shape, alt_text: str) -> None:
    doc_pr = inline_shape._inline.docPr
    doc_pr.set("descr", alt_text)
    doc_pr.set("title", alt_text)


def add_heading(document, text: str, level: int):
    paragraph = document.add_paragraph(style=f"Heading {level}")
    paragraph.paragraph_format.space_before = Pt(10 if level == 1 else 7)
    paragraph.paragraph_format.space_after = Pt(4)
    set_keep_with_next(paragraph)
    add_text(
        paragraph,
        text,
        size=17 if level == 1 else 12,
        bold=True,
        color="000000",
    )
    return paragraph


def parse_spec(path: Path) -> dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(raw, dict):
        raise SpecError("the JSON root must be an object")
    for field in ("title", "subtitle", "footer_label"):
        require_text(raw.get(field), field)
    overview = raw.get("overview")
    groups = raw.get("connector_groups")
    if not isinstance(overview, list) or not overview:
        raise SpecError("overview must be a non-empty array")
    if not isinstance(groups, list) or not groups:
        raise SpecError("connector_groups must be a non-empty array")

    board_renders = raw.get("board_renders", [])
    if not isinstance(board_renders, list):
        raise SpecError("board_renders must be an array")
    for render_index, render in enumerate(board_renders, start=1):
        if not isinstance(render, dict):
            raise SpecError(f"board_renders[{render_index}] must be an object")
        require_text(render.get("title"), f"board_renders[{render_index}].title")
        image_path = Path(require_text(render.get("image"), f"board_renders[{render_index}].image"))
        if not image_path.is_absolute():
            image_path = (path.parent / image_path).resolve()
        if not image_path.exists():
            raise SpecError(f"missing board render: {image_path}")
        render["_image_path"] = image_path

    interface_maps = raw.get("interface_maps", [])
    if not isinstance(interface_maps, list):
        raise SpecError("interface_maps must be an array")
    for map_index, interface_map in enumerate(interface_maps, start=1):
        if not isinstance(interface_map, dict):
            raise SpecError(f"interface_maps[{map_index}] must be an object")
        require_text(interface_map.get("title"), f"interface_maps[{map_index}].title")
        image_path = Path(require_text(interface_map.get("image"), f"interface_maps[{map_index}].image"))
        fallback_path = Path(require_text(interface_map.get("fallback_image"), f"interface_maps[{map_index}].fallback_image"))
        if not image_path.is_absolute():
            image_path = (path.parent / image_path).resolve()
        if not fallback_path.is_absolute():
            fallback_path = (path.parent / fallback_path).resolve()
        if not image_path.exists() or image_path.suffix.lower() != ".svg":
            raise SpecError(f"missing SVG interface map: {image_path}")
        if not fallback_path.exists():
            raise SpecError(f"missing interface-map fallback image: {fallback_path}")
        interface_map["_image_path"] = image_path
        interface_map["_fallback_path"] = fallback_path

    searchable: list[str] = []
    seen: set[str] = set()
    for section_index, section in enumerate(overview, start=1):
        if not isinstance(section, dict):
            raise SpecError(f"overview[{section_index}] must be an object")
        require_text(section.get("title"), f"overview[{section_index}].title")
        rows = section.get("rows")
        if not isinstance(rows, list) or not rows:
            raise SpecError(f"overview[{section_index}].rows must be non-empty")
        for row_index, row in enumerate(rows, start=1):
            if not isinstance(row, list) or len(row) != 2:
                raise SpecError(f"overview[{section_index}].rows[{row_index}] must have two cells")
            searchable.extend(str(value) for value in row)

    for group_index, group in enumerate(groups, start=1):
        require_text(group.get("title"), f"connector_groups[{group_index}].title")
        items = group.get("items")
        if not isinstance(items, list) or not items:
            raise SpecError(f"connector_groups[{group_index}].items must be non-empty")
        for item_index, item in enumerate(items, start=1):
            prefix = f"connector_groups[{group_index}].items[{item_index}]"
            designator = require_text(item.get("designator"), f"{prefix}.designator")
            if designator in seen:
                raise SpecError(f"duplicate item designator: {designator}")
            seen.add(designator)
            require_text(item.get("name"), f"{prefix}.name")
            image_path = Path(require_text(item.get("image"), f"{prefix}.image"))
            if not image_path.is_absolute():
                image_path = (path.parent / image_path).resolve()
            if not image_path.exists():
                raise SpecError(f"missing image for {designator}: {image_path}")
            item["_image_path"] = image_path
            pinout_path = Path(require_text(item.get("pinout_image"), f"{prefix}.pinout_image"))
            if not pinout_path.is_absolute():
                pinout_path = (path.parent / pinout_path).resolve()
            if not pinout_path.exists():
                raise SpecError(f"missing pinout image for {designator}: {pinout_path}")
            if pinout_path.suffix.lower() != ".svg":
                raise SpecError(f"{designator}: a native-geometry SVG pinout is required")
            try:
                native_source = ET.parse(pinout_path).getroot().get("data-native-geometry", "")
            except ET.ParseError as error:
                raise SpecError(f"{designator}: invalid pinout SVG: {pinout_path}") from error
            if native_source not in {
                "altium-component-svg", "altium-board-assembly-svg", "altium-board-pad-svg"
            }:
                raise SpecError(f"{designator}: pinout SVG has no verified Altium geometry source")
            item["_pinout_path"] = pinout_path
            fallback_path = Path(require_text(item.get("pinout_fallback_image"), f"{prefix}.pinout_fallback_image"))
            if not fallback_path.is_absolute():
                fallback_path = (path.parent / fallback_path).resolve()
            if not fallback_path.exists():
                raise SpecError(f"missing SVG fallback image for {designator}: {fallback_path}")
            item["_pinout_fallback_path"] = fallback_path
            pins = item.get("pins")
            if not isinstance(pins, list) or not pins:
                raise SpecError(f"{prefix}.pins must be non-empty")
            pin_ids: set[str] = set()
            for pin_index, pin in enumerate(pins, start=1):
                if not isinstance(pin, dict):
                    raise SpecError(f"{prefix}.pins[{pin_index}] must be an object")
                pin_id = require_text(pin.get("pin"), f"{prefix}.pins[{pin_index}].pin")
                if pin_id in pin_ids:
                    raise SpecError(f"duplicate physical pin {designator}.{pin_id}")
                pin_ids.add(pin_id)
                for field in ("net", "function", "group"):
                    require_text(pin.get(field), f"{prefix}.pins[{pin_index}].{field}")
                searchable.extend(str(pin[field]) for field in ("pin", "net", "function", "group"))
            searchable.extend((designator, str(item["name"]), str(item.get("description", ""))))

    content = "\n".join(searchable).lower()
    for phrase in FORBIDDEN_USER_CONTENT:
        if phrase in content:
            raise SpecError(f"end-user content contains a forbidden fabrication phrase: {phrase}")
    if re.search(r"(?<![a-zа-я0-9])(?:mp|mh)\d*(?![a-zа-я0-9])", content, flags=re.IGNORECASE):
        raise SpecError("end-user content contains excluded non-signal contact identifiers")
    return raw


def configure_document(document: Document, spec: dict[str, Any]) -> None:
    section = document.sections[0]
    section.orientation = WD_ORIENT.LANDSCAPE
    section.page_width = Cm(29.7)
    section.page_height = Cm(21.0)
    section.top_margin = Cm(1.35)
    section.bottom_margin = Cm(1.2)
    section.left_margin = Cm(1.45)
    section.right_margin = Cm(1.45)

    styles = document.styles
    normal = styles["Normal"]
    normal.font.name = "Aptos"
    normal.font.size = Pt(9)
    normal.font.color.rgb = RGBColor.from_string(COLORS["text"])
    normal.paragraph_format.space_after = Pt(4)
    normal.paragraph_format.line_spacing = 1.08
    title_style = styles["Title"]
    title_style.font.name = "Aptos Display"
    title_style.font.bold = True
    title_style.font.color.rgb = RGBColor(0, 0, 0)
    clear_paragraph_borders(title_style)
    for level in (1, 2):
        style = styles[f"Heading {level}"]
        style.font.name = "Aptos Display"
        style.font.bold = True
        style.font.color.rgb = RGBColor(0, 0, 0)

    footer = section.footer.paragraphs[0]
    footer.text = ""
    add_text(footer, require_text(spec["footer_label"], "footer_label"), size=8, bold=True, color=COLORS["muted"])
    add_text(footer, "    |    ", size=8, color=COLORS["line"])
    add_text(footer, str(spec.get("document_kind", "Connector reference")) + "    |    ", size=8, color=COLORS["muted"])
    add_page_number(footer)

    core = document.core_properties
    metadata = spec.get("metadata", {})
    core.title = str(metadata.get("title", spec["subtitle"]))
    core.subject = str(metadata.get("subject", "End-user board and connector reference"))


def add_cover(document: Document, spec: dict[str, Any]) -> None:
    paragraph = document.add_paragraph(style="Title")
    clear_paragraph_borders(paragraph)
    paragraph.paragraph_format.space_before = Pt(42)
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_text(paragraph, spec["title"], size=28, bold=True, color="000000")

    paragraph = document.add_paragraph()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_text(paragraph, spec["subtitle"], size=17, color=COLORS["blue"])

    paragraph = document.add_paragraph()
    paragraph.paragraph_format.space_before = Pt(18)
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_text(
        paragraph,
        str(spec.get("tagline", "CPU • flight controller • memory • onboard sensors • connector pinout")),
        size=10.5,
        color=COLORS["muted"],
    )
    document.add_page_break()


def add_overview_table(document: Document, rows: list[list[str]], headers: list[str]) -> None:
    table = document.add_table(rows=1, cols=2)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_table_borders(table)
    if len(headers) != 2:
        raise SpecError("overview_headers must contain two strings")
    for cell, width, label in zip(table.rows[0].cells, (3000, 10000), headers):
        set_cell_width(cell, width)
        set_cell_text(cell, str(label), bold=True, color=COLORS["white"], size=8.5)
        set_cell_fill(cell, COLORS["navy"])
    set_repeat_header(table.rows[0])
    for index, row_data in enumerate(rows):
        row = table.add_row()
        set_cant_split(row)
        set_cell_width(row.cells[0], 3000)
        set_cell_width(row.cells[1], 10000)
        set_cell_text(row.cells[0], str(row_data[0]), bold=True, color=COLORS["navy"], size=9)
        set_cell_text(row.cells[1], str(row_data[1]), size=9)
        if index % 2:
            set_cell_fill(row.cells[0], COLORS["pale"])
            set_cell_fill(row.cells[1], COLORS["pale"])


def add_connector_table(document: Document, item: dict[str, Any]) -> None:
    table = document.add_table(rows=1, cols=4)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_table_borders(table)
    widths = (1050, 3400, 6100, 2750)
    headers = tuple(spec_header for spec_header in item.get("table_headers", ()))
    if not headers:
        headers = ("Pin", "Board net", "Function / ArduPilot mapping", "Interface / group")
    if len(headers) != 4:
        raise SpecError(f"{item['designator']}.table_headers must contain four strings")
    for cell, width, label in zip(table.rows[0].cells, widths, headers):
        set_cell_width(cell, width)
        set_cell_text(cell, label, bold=True, color=COLORS["white"], size=8.2)
        set_cell_fill(cell, COLORS["blue"])
    set_repeat_header(table.rows[0])

    for index, pin in enumerate(item["pins"]):
        row = table.add_row()
        set_cant_split(row)
        values = (pin["pin"], pin["net"], pin["function"], pin["group"])
        for cell, width, value in zip(row.cells, widths, values):
            set_cell_width(cell, width)
            set_cell_text(cell, str(value), size=8.1)
        if index % 2:
            for cell in row.cells:
                set_cell_fill(cell, COLORS["pale"])

    # Visually group consecutive rows while preserving one physical pin per row.
    start = 1
    while start < len(table.rows):
        group = item["pins"][start - 1]["group"]
        end = start
        while end + 1 < len(table.rows) and item["pins"][end]["group"] == group:
            end += 1
        if end > start:
            merged = table.cell(start, 3).merge(table.cell(end, 3))
            set_cell_text(merged, group, bold=True, color=COLORS["navy"], size=8.1)
            set_cell_fill(merged, COLORS["cyan"])
        else:
            set_cell_fill(table.cell(start, 3), COLORS["cyan"])
            for run in table.cell(start, 3).paragraphs[0].runs:
                run.font.bold = True
                run.font.color.rgb = RGBColor.from_string(COLORS["navy"])
        start = end + 1


def fit_image(path: Path, *, max_width_cm: float, max_height_cm: float) -> tuple[float, float]:
    with PILImage.open(path) as image:
        width, height = image.size
    scale = min(max_width_cm / width, max_height_cm / height)
    return width * scale, height * scale


def add_svg_picture(run, svg_path: Path, fallback_path: Path, *, width, height, alt_text: str):
    """Insert a PNG fallback and attach the source SVG through Office SVG markup."""
    inline_shape = run.add_picture(str(fallback_path), width=width, height=height)
    package = run.part.package
    partname = package.next_partname(PackURI("/word/media/image%d.svg"))
    svg_part = Part(partname, "image/svg+xml", svg_path.read_bytes(), package)
    svg_rid = run.part.relate_to(svg_part, RT.IMAGE)
    blips = inline_shape._inline.xpath(".//a:blip")
    if not blips:
        raise SpecError(f"could not locate fallback blip for SVG {svg_path}")
    blip = blips[0]
    ext_list = OxmlElement("a:extLst")
    extension = OxmlElement("a:ext")
    extension.set("uri", "{96DAC541-7B7A-43D3-8B79-37D633B846F1}")
    svg_blip = parse_xml(
        '<asvg:svgBlip xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        f'r:embed="{svg_rid}"/>'
    )
    extension.append(svg_blip)
    ext_list.append(extension)
    blip.append(ext_list)
    set_picture_alt(inline_shape, alt_text)
    return inline_shape


def add_board_renders(document: Document, spec: dict[str, Any]) -> None:
    renders = spec.get("board_renders", [])
    if not renders:
        return
    add_heading(document, str(spec.get("board_renders_title", "Board views")), 1)
    intro = document.add_paragraph()
    intro.paragraph_format.space_after = Pt(6)
    add_text(
        intro,
        str(spec.get("board_renders_intro", "Orthographic views show the complete board and connector placement.")),
        size=9.2,
        color=COLORS["muted"],
    )
    for index, render in enumerate(renders):
        if index:
            document.add_page_break()
        add_heading(document, str(render["title"]), 2)
        paragraph = document.add_paragraph()
        paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
        paragraph.paragraph_format.space_before = Pt(4)
        paragraph.paragraph_format.space_after = Pt(5)
        image_width, image_height = fit_image(render["_image_path"], max_width_cm=25.8, max_height_cm=13.5)
        shape = paragraph.add_run().add_picture(
            str(render["_image_path"]), width=Cm(image_width), height=Cm(image_height)
        )
        set_picture_alt(shape, str(render.get("alt", render["title"])))
        caption = document.add_paragraph()
        caption.alignment = WD_ALIGN_PARAGRAPH.CENTER
        caption.paragraph_format.space_after = Pt(4)
        add_text(caption, str(render.get("caption", render["title"])), size=8.2, color=COLORS["muted"])
    document.add_page_break()


def add_interface_maps(document: Document, spec: dict[str, Any]) -> None:
    maps = spec.get("interface_maps", [])
    if not maps:
        return
    add_heading(document, str(spec.get("interface_maps_title", "Board interface maps")), 1)
    intro = document.add_paragraph()
    intro.paragraph_format.space_after = Pt(0)
    add_text(
        intro,
        str(spec.get("interface_maps_intro", "Processor-related interfaces are color-coded on 1:1 vector views.")),
        size=8.8,
        color=COLORS["muted"],
    )
    for index, interface_map in enumerate(maps):
        if index:
            document.add_page_break()
        paragraph = document.add_paragraph()
        paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
        paragraph.paragraph_format.space_before = Pt(0)
        paragraph.paragraph_format.space_after = Pt(0)
        add_svg_picture(
            paragraph.add_run(),
            interface_map["_image_path"],
            interface_map["_fallback_path"],
            width=Cm(26.6),
            height=Cm(15.5),
            alt_text=str(interface_map.get("alt", interface_map["title"])),
        )
def add_item(document: Document, item: dict[str, Any]) -> None:
    add_heading(document, f"{item['designator']} — {item['name']}", 2)
    description = str(item.get("description", "")).strip()
    if description:
        paragraph = document.add_paragraph()
        paragraph.paragraph_format.space_after = Pt(3)
        set_keep_with_next(paragraph)
        add_text(paragraph, description, size=8.8, color=COLORS["muted"])

    paragraph = document.add_paragraph()
    paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
    paragraph.paragraph_format.space_before = Pt(1)
    paragraph.paragraph_format.space_after = Pt(4)
    set_keep_with_next(paragraph)
    image_width, image_height = fit_image(item["_image_path"], max_width_cm=11.0, max_height_cm=6.2)
    shape = paragraph.add_run().add_picture(
        str(item["_image_path"]), width=Cm(image_width), height=Cm(image_height)
    )
    alt_template = str(item.get("image_alt_template", "Orthographic 3D PCB view of {designator}"))
    set_picture_alt(shape, alt_template.format(designator=item["designator"], name=item["name"]))
    add_text(paragraph, "   ", size=8)
    pinout_alt_template = str(item.get("pinout_alt_template", "Pinout diagram for {designator} — {name}"))
    pinout_alt = pinout_alt_template.format(designator=item["designator"], name=item["name"])
    if item["_pinout_path"].suffix.lower() == ".svg":
        pinout_width, pinout_height = fit_image(item["_pinout_fallback_path"], max_width_cm=14.0, max_height_cm=9.0)
        add_svg_picture(
            paragraph.add_run(),
            item["_pinout_path"],
            item["_pinout_fallback_path"],
            width=Cm(pinout_width),
            height=Cm(pinout_height),
            alt_text=pinout_alt,
        )
    else:
        pinout_width, pinout_height = fit_image(item["_pinout_path"], max_width_cm=14.0, max_height_cm=9.0)
        pinout_shape = paragraph.add_run().add_picture(
            str(item["_pinout_path"]), width=Cm(pinout_width), height=Cm(pinout_height)
        )
        set_picture_alt(pinout_shape, pinout_alt)
    caption = document.add_paragraph()
    caption.alignment = WD_ALIGN_PARAGRAPH.CENTER
    caption.paragraph_format.space_after = Pt(4)
    set_keep_with_next(caption)
    caption_template = str(item.get("image_caption_template", "Orthographic 3D view — {designator}"))
    pinout_caption_template = str(item.get("pinout_caption_template", "Connector-side pinout — {designator}"))
    caption_text = (
        caption_template.format(designator=item["designator"], name=item["name"])
        + "    |    "
        + pinout_caption_template.format(designator=item["designator"], name=item["name"])
    )
    add_text(caption, caption_text, size=7.8, color=COLORS["muted"])
    add_connector_table(document, item)


def build_document(spec: dict[str, Any], output: Path) -> None:
    document = Document()
    configure_document(document, spec)
    add_cover(document, spec)
    add_board_renders(document, spec)
    add_interface_maps(document, spec)

    for index, overview_section in enumerate(spec["overview"]):
        heading = add_heading(document, overview_section["title"], 1)
        if index == 0 and spec.get("interface_maps"):
            heading.paragraph_format.page_break_before = True
        add_overview_table(
            document,
            overview_section["rows"],
            list(spec.get("overview_headers", ("Parameter", "Description"))),
        )

    for group in spec["connector_groups"]:
        document.add_page_break()
        add_heading(document, group["title"], 1)
        for item in group["items"]:
            item.setdefault("table_headers", spec.get("table_headers", ()))
            item.setdefault("image_alt_template", spec.get("image_alt_template", "Orthographic 3D PCB view of {designator}"))
            item.setdefault("image_caption_template", spec.get("image_caption_template", "Orthographic 3D view — {designator}"))
            item.setdefault("pinout_alt_template", spec.get("pinout_alt_template", "Pinout diagram for {designator} — {name}"))
            item.setdefault("pinout_caption_template", spec.get("pinout_caption_template", "Connector-side pinout — {designator}"))
            add_item(document, item)

    output.parent.mkdir(parents=True, exist_ok=True)
    document.save(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.data.resolve() == args.output.resolve():
        raise SystemExit("input and output paths must be different")
    try:
        spec = parse_spec(args.data.resolve())
        build_document(spec, args.output.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
