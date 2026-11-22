"""Generate an end-user board manual as a DOCX and matching PDF.

This generator is intentionally separate from the manufacturing-oriented board
description generator.  It produces a connector manual: one image and one
pin-by-pin table per connector, plus concise functional sections for the CPU,
flight controller, memory, and onboard sensors.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from io import BytesIO
from pathlib import Path
from typing import Any
from zipfile import ZipFile

from PIL import Image as PILImage
from PIL import ImageChops
from docx import Document
from docx.enum.section import WD_ORIENT, WD_SECTION
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml import parse_xml
from docx.oxml.ns import qn
from docx.opc.constants import RELATIONSHIP_TYPE as RT
from docx.opc.packuri import PackURI
from docx.opc.part import Part
from docx.shared import Cm, Pt, RGBColor

if __package__:
    from .board_description_options import component_override, interface_map_scale
    from .export_board_port_maps import GENERATED_NET, verify_firmware_identity
else:
    from board_description_options import component_override, interface_map_scale
    from export_board_port_maps import GENERATED_NET, verify_firmware_identity


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
MANUAL_FONT = "Arial"
FIGURE_CENTERS_CM = (3.50, 12.60)
CONNECTOR_GAP_PT = 24

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


def set_arial_font(r_fonts) -> None:
    r_fonts.attrib.clear()
    for attr in ("ascii", "hAnsi", "cs", "eastAsia"):
        r_fonts.set(qn(f"w:{attr}"), MANUAL_FONT)


def style_run(run, *, size: float, bold=False, color=COLORS["text"]) -> None:
    set_arial_font(run._element.get_or_add_rPr().get_or_add_rFonts())
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = RGBColor.from_string(color)


def add_text(paragraph, text: str, *, size=9.0, bold=False, color=COLORS["text"]):
    run = paragraph.add_run(text)
    style_run(run, size=size, bold=bold, color=color)
    return run


def set_cell_text(cell, text: str, *, bold=False, color=COLORS["text"], size=8.5, compact=False) -> None:
    cell.text = ""
    paragraph = cell.paragraphs[0]
    paragraph.paragraph_format.space_before = Pt(0)
    paragraph.paragraph_format.space_after = Pt(0)
    paragraph.paragraph_format.line_spacing = Pt(size + 1.2) if compact else 1.0
    add_text(paragraph, text, size=size, bold=bold, color=color)
    cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    if compact:
        set_cell_margins(cell, top=11, bottom=11)
    else:
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
    map_scale = interface_map_scale(raw)
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
        map_svg = ET.parse(image_path).getroot()
        if float(map_svg.get("data-board-scale", "1")) != map_scale:
            raise SpecError(f"incorrect scale in interface map {image_path}")
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
            if isinstance(row[1], dict):
                key = require_text(row[1].get("component_override"), "overview component_override")
                row[1] = component_override(raw, key, "overview")
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
                pinout_root = ET.parse(pinout_path).getroot()
                native_source = pinout_root.get("data-native-geometry", "")
            except ET.ParseError as error:
                raise SpecError(f"{designator}: invalid pinout SVG: {pinout_path}") from error
            if native_source not in {
                "altium-component-svg", "altium-component-pad-svg",
                "altium-board-assembly-svg", "altium-board-pad-svg",
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
            if pinout_root.get("data-pinout-view"):
                namespace = {"svg": "http://www.w3.org/2000/svg"}
                callouts = pinout_root.findall("svg:g[@data-pinout-pad]", namespace)
                by_pin = {callout.attrib["data-pinout-pad"]: callout for callout in callouts}
                if len(callouts) != len(pin_ids) or by_pin.keys() != pin_ids:
                    raise SpecError(f"{designator}: pinout callouts do not match the physical pin list")
                for pin in pins:
                    callout = by_pin[pin["pin"]]
                    label = callout.find("svg:image", namespace)
                    if label is None:
                        text_label = callout.findtext("svg:text", namespaces=namespace)
                    else:
                        text_label = label.get("aria-label")
                    if text_label != f"{pin['pin']}: {pin['net']}":
                        raise SpecError(f"{designator}.{pin['pin']}: pinout net does not match the pin table")
                    for field in ("mcu_pin", "mcu_peripheral", "mcu_signal", "ardupilot_port"):
                        if callout.get(f"data-{field.replace('_', '-')}", "") != str(pin.get(field, "")):
                            raise SpecError(f"{designator}.{pin['pin']}: pinout {field} does not match the pin table")
            searchable.extend((designator, str(item["name"]), str(item.get("description", ""))))

    verify_firmware_identity(raw)
    content = "\n".join(searchable).lower()
    if GENERATED_NET.search(content):
        raise SpecError("end-user content contains a compiler-generated net name")
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
    for fonts in styles.element.iter(qn("w:rFonts")):
        set_arial_font(fonts)
    normal.font.name = MANUAL_FONT
    normal.font.size = Pt(9)
    normal.font.color.rgb = RGBColor.from_string(COLORS["text"])
    normal.paragraph_format.space_after = Pt(4)
    normal.paragraph_format.line_spacing = 1.08
    title_style = styles["Title"]
    title_style.font.name = MANUAL_FONT
    title_style.font.bold = True
    title_style.font.color.rgb = RGBColor(0, 0, 0)
    clear_paragraph_borders(title_style)
    language = str(spec.get("language", "en-US"))
    lang = OxmlElement("w:lang")
    lang.set(qn("w:val"), language)
    normal.element.get_or_add_rPr().append(lang)
    for level in (1, 2):
        style = styles[f"Heading {level}"]
        style.font.name = MANUAL_FONT
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
    core.language = language


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


def add_overview_table(document: Document, rows: list[list[str]], headers: list[str]) -> None:
    table = document.add_table(rows=1, cols=2)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_table_borders(table)
    widths = (2640, 7690)
    for column, width in zip(table.columns, widths):
        column.width = Pt(width / 20)
    if len(headers) != 2:
        raise SpecError("overview_headers must contain two strings")
    for cell, width, label in zip(table.rows[0].cells, widths, headers):
        set_cell_width(cell, width)
        set_cell_text(cell, str(label), bold=True, color=COLORS["white"], size=8.5, compact=True)
        set_cell_fill(cell, COLORS["navy"])
    set_repeat_header(table.rows[0])
    for index, row_data in enumerate(rows):
        row = table.add_row()
        set_cant_split(row)
        for cell, width in zip(row.cells, widths):
            set_cell_width(cell, width)
        set_cell_text(row.cells[0], str(row_data[0]), bold=True, color=COLORS["navy"], size=9, compact=True)
        set_cell_text(row.cells[1], str(row_data[1]), size=9, compact=True)
        if index % 2:
            set_cell_fill(row.cells[0], COLORS["pale"])
            set_cell_fill(row.cells[1], COLORS["pale"])


def add_connector_table(document: Document, item: dict[str, Any], *, keep_together: bool) -> None:
    table = document.add_table(rows=1, cols=4)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_table_borders(table)
    widths = (900, 2490, 5050, 1890)
    for column, width in zip(table.columns, widths):
        column.width = Pt(width / 20)
    headers = tuple(spec_header for spec_header in item.get("table_headers", ()))
    if not headers:
        headers = ("Pin", "Board net", "Function / ArduPilot mapping", "Interface / group")
    if len(headers) != 4:
        raise SpecError(f"{item['designator']}.table_headers must contain four strings")
    for cell, width, label in zip(table.rows[0].cells, widths, headers):
        set_cell_width(cell, width)
        set_cell_text(cell, label, bold=True, color=COLORS["white"], size=8.3, compact=True)
        set_cell_fill(cell, COLORS["blue"])
    set_repeat_header(table.rows[0])

    for index, pin in enumerate(item["pins"]):
        row = table.add_row()
        set_cant_split(row)
        values = (pin["pin"], pin["net"], pin["function"], pin["group"])
        for cell, width, value in zip(row.cells, widths, values):
            set_cell_width(cell, width)
            set_cell_text(cell, str(value), size=8.3, compact=True)
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
            set_cell_text(merged, group, bold=True, color=COLORS["navy"], size=8.3, compact=True)
            set_cell_fill(merged, COLORS["cyan"])
        else:
            set_cell_fill(table.cell(start, 3), COLORS["cyan"])
            for run in table.cell(start, 3).paragraphs[0].runs:
                run.font.bold = True
                run.font.color.rgb = RGBColor.from_string(COLORS["navy"])
        start = end + 1
    if keep_together:
        # Merge operations share paragraph objects across rows. Visit each
        # physical cell once and stop the chain in the last physical row.
        for row in table.rows[:-1]:
            for tc in row._tr.tc_lst:
                for paragraph in tc.p_lst:
                    paragraph.get_or_add_pPr().get_or_add_keepNext().val = True


def fit_image(path: Path, *, max_width_cm: float, max_height_cm: float) -> tuple[float, float]:
    with PILImage.open(path) as image:
        width, height = image.size
    scale = min(max_width_cm / width, max_height_cm / height)
    return width * scale, height * scale


def fit_pinout(item: dict[str, Any]) -> tuple[float, float]:
    svg = ET.parse(item["_pinout_path"]).getroot()
    max_width = 11.2
    pin_count = len(item["pins"])
    max_height = 6.1
    if pin_count >= 40:
        # Keep dense connector tables below their diagrams on one page.
        max_height = 5.15
    elif pin_count <= 3:
        # Keep short connector sections compact enough for visible separation.
        max_height = 4.8
    if svg.get("data-coordinate-units") == "mm":
        match = re.fullmatch(r"(\d+(?:\.\d+)?)mm", svg.get("width", ""))
        if match:
            # Limit enlargement for small diagrams while retaining the larger
            # native body and readable labels on dense diagrams.
            max_width = min(max_width, float(match.group(1)) * 0.165)
    return fit_image(item["_pinout_fallback_path"], max_width_cm=max_width, max_height_cm=max_height)


def png_stream(image: PILImage.Image) -> BytesIO:
    stream = BytesIO()
    image.save(stream, format="PNG")
    stream.seek(0)
    return stream


def centered_figure_png(path: Path, image_height: float, row_height: float) -> tuple[BytesIO, float]:
    """Center the visible artwork and return its original vertical position for the SVG."""
    with PILImage.open(path) as source:
        image = image_on_white(source)
        target_height = max(source.height, round(source.height * row_height / image_height))
    bounds = artwork_bounds(image)
    center_y = (bounds[1] + bounds[3]) / 2 if bounds else image.height / 2
    canvas = PILImage.new("RGB", (image.width, target_height), "white")
    canvas.paste(image, (0, round(target_height / 2 - center_y)))
    return png_stream(canvas), center_y / image.height


def centered_figure_svg(path: Path, image_height: float, row_height: float, center: float) -> bytes:
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
    svg = ET.parse(path).getroot()
    x, y, width, height = map(float, svg.attrib["viewBox"].split())
    padded_height = height * row_height / image_height
    svg.set("viewBox", f"{x:g} {y + center * height - padded_height / 2:g} {width:g} {padded_height:g}")
    svg.set("height", f"{padded_height:g}mm")
    return ET.tostring(svg, encoding="utf-8")


def add_svg_picture(run, svg_path: Path | bytes, fallback_path: Path | BytesIO, *, width, height, alt_text: str):
    """Insert a PNG fallback and attach the source SVG through Office SVG markup."""
    fallback = str(fallback_path) if isinstance(fallback_path, Path) else fallback_path
    inline_shape = run.add_picture(fallback, width=width, height=height)
    package = run.part.package
    partname = package.next_partname(PackURI("/word/media/image%d.svg"))
    svg_data = svg_path.read_bytes() if isinstance(svg_path, Path) else svg_path
    svg_part = Part(partname, "image/svg+xml", svg_data, package)
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


def center_picture_on_page(shape) -> None:
    inline = shape._inline
    anchor = OxmlElement("wp:anchor")
    for name in ("distT", "distB", "distL", "distR", "simplePos", "behindDoc", "locked"):
        anchor.set(name, "0")
    anchor.set("relativeHeight", "0")
    anchor.set("layoutInCell", "1")
    anchor.set("allowOverlap", "1")
    position = OxmlElement("wp:simplePos")
    position.set("x", "0")
    position.set("y", "0")
    anchor.append(position)
    for axis in ("H", "V"):
        position = OxmlElement(f"wp:position{axis}")
        position.set("relativeFrom", "page")
        alignment = OxmlElement("wp:align")
        alignment.text = "center"
        position.append(alignment)
        anchor.append(position)
    for child in list(inline):
        if child.tag == qn("wp:docPr"):
            anchor.append(OxmlElement("wp:wrapNone"))
        anchor.append(child)
    inline.getparent().replace(inline, anchor)


def image_on_white(source: PILImage.Image) -> PILImage.Image:
    image = PILImage.new("RGB", source.size, "white")
    rgba = source.convert("RGBA")
    image.paste(rgba, mask=rgba.getchannel("A"))
    return image


def artwork_bounds(image: PILImage.Image) -> tuple[int, int, int, int] | None:
    white = PILImage.new("RGB", image.size, "white")
    ink = ImageChops.difference(image, white).convert("L").point(lambda level: 255 if level > 28 else 0)
    return ink.getbbox()


def board_artwork(path: Path) -> PILImage.Image:
    with PILImage.open(path) as source:
        image = image_on_white(source)
    bounds = artwork_bounds(image)
    if bounds is None:
        raise SpecError(f"board render contains no visible artwork: {path}")
    x1, y1, x2, y2 = bounds
    return image.crop((max(x1 - 2, 0), max(y1 - 2, 0), min(x2 + 2, image.width), min(y2 + 2, image.height)))


def add_board_renders(document: Document, spec: dict[str, Any]) -> None:
    renders = spec.get("board_renders", [])
    if not renders:
        return
    heading = add_heading(document, str(spec.get("board_renders_title", "Board views")), 1)
    heading.paragraph_format.page_break_before = True
    intro = document.add_paragraph()
    intro.paragraph_format.space_after = Pt(6)
    add_text(
        intro,
        str(spec.get("board_renders_intro", "Orthographic views show the complete board and connector placement.")),
        size=9.2,
        color=COLORS["muted"],
    )
    artwork = [board_artwork(render["_image_path"]) for render in renders]
    scale = min(min(25.8 / image.width, 13.5 / image.height) for image in artwork)
    for index, (render, image) in enumerate(zip(renders, artwork)):
        heading = add_heading(document, str(render["title"]), 2)
        heading.paragraph_format.page_break_before = bool(index)
        shape = heading.add_run().add_picture(
            png_stream(image), width=Cm(image.width * scale), height=Cm(image.height * scale)
        )
        set_picture_alt(shape, str(render.get("alt", render["title"])))
        center_picture_on_page(shape)
        caption = document.add_paragraph()
        caption.alignment = WD_ALIGN_PARAGRAPH.CENTER
        caption.paragraph_format.space_after = Pt(0)
        section = document.sections[0]
        frame = OxmlElement("w:framePr")
        for key, value in {
            "hAnchor": "page", "vAnchor": "page", "xAlign": "center", "wrap": "none",
            "w": str(section.page_width.twips - section.left_margin.twips - section.right_margin.twips),
            "y": str(round((section.page_height.twips + Cm(image.height * scale).twips) / 2 + Pt(5).twips)),
        }.items():
            frame.set(qn(f"w:{key}"), value)
        caption._p.get_or_add_pPr().insert(0, frame)
        add_text(caption, str(render.get("caption", render["title"])), size=8.2, color=COLORS["muted"])


def add_interface_maps(document: Document, spec: dict[str, Any]) -> None:
    maps = spec.get("interface_maps", [])
    if not maps:
        return
    heading = add_heading(document, str(spec.get("interface_maps_title", "Board interface maps")), 1)
    heading.paragraph_format.page_break_before = True
    intro = document.add_paragraph()
    intro.paragraph_format.space_after = Pt(0)
    add_text(
        intro,
        str(spec.get("interface_maps_intro", "Processor-related interfaces are color-coded on 1:1 vector views.")),
        size=8.8,
        color=COLORS["muted"],
    )
    for index, interface_map in enumerate(maps):
        heading = add_heading(document, str(interface_map["title"]), 2)
        heading.paragraph_format.page_break_before = bool(index)
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


def add_item(document: Document, item: dict[str, Any], *, follows_connector: bool) -> None:
    heading = add_heading(document, f"{item['designator']} — {item['name']}", 2)
    if follows_connector:
        heading.paragraph_format.space_before = Pt(CONNECTOR_GAP_PT)
    description = str(item.get("description", "")).strip()
    if description:
        paragraph = document.add_paragraph()
        paragraph.paragraph_format.space_after = Pt(3)
        set_keep_with_next(paragraph)
        add_text(paragraph, description, size=8.8, color=COLORS["muted"])

    paragraph = document.add_paragraph()
    paragraph.paragraph_format.space_before = Pt(2)
    paragraph.paragraph_format.space_after = Pt(4)
    set_keep_with_next(paragraph)
    image_width, image_height = fit_image(item["_image_path"], max_width_cm=6.6, max_height_cm=4.8)
    pinout_width, pinout_height = fit_pinout(item)
    for center in FIGURE_CENTERS_CM:
        paragraph.paragraph_format.tab_stops.add_tab_stop(Cm(center), WD_TAB_ALIGNMENT.CENTER)
    row_height = max(image_height, pinout_height)
    crop, _ = centered_figure_png(item["_image_path"], image_height, row_height)
    paragraph.add_run("\t")
    shape = paragraph.add_run().add_picture(
        crop, width=Cm(image_width), height=Cm(row_height)
    )
    alt_template = str(item.get("image_alt_template", "Orthographic 3D PCB view of {designator}"))
    set_picture_alt(shape, alt_template.format(designator=item["designator"], name=item["name"]))
    paragraph.add_run("\t")
    pinout_alt_template = str(item.get("pinout_alt_template", "Pinout diagram for {designator} — {name}"))
    pinout_alt = pinout_alt_template.format(designator=item["designator"], name=item["name"])
    fallback, center = centered_figure_png(item["_pinout_fallback_path"], pinout_height, row_height)
    svg = centered_figure_svg(item["_pinout_path"], pinout_height, row_height, center)
    add_svg_picture(
        paragraph.add_run(),
        svg,
        fallback,
        width=Cm(pinout_width),
        height=Cm(row_height),
        alt_text=pinout_alt,
    )
    caption = document.add_paragraph(style="Caption")
    for center in FIGURE_CENTERS_CM:
        caption.paragraph_format.tab_stops.add_tab_stop(Cm(center), WD_TAB_ALIGNMENT.CENTER)
    caption.paragraph_format.space_before = Pt(0)
    caption.paragraph_format.space_after = Pt(4)
    set_keep_with_next(caption)
    caption_template = str(item.get("image_caption_template", "Orthographic 3D view — {designator}"))
    pinout_caption_template = str(item.get("pinout_caption_template", "Connector-side pinout — {designator}"))
    for template in (caption_template, pinout_caption_template):
        label = template.format(designator=item["designator"], name=item["name"])
        add_text(caption, "\t" + label, size=8.0, color=COLORS["muted"])
    minimum_table_height = Pt((len(item["pins"]) + 1) * 10.6)
    available_height = Cm(27.0 - row_height) - Pt(80)
    add_connector_table(document, item, keep_together=minimum_table_height < available_height)


def build_document(spec: dict[str, Any], output: Path) -> None:
    document = Document()
    configure_document(document, spec)
    add_cover(document, spec)
    add_board_renders(document, spec)
    add_interface_maps(document, spec)

    section = document.add_section(WD_SECTION.NEW_PAGE)
    section.orientation = WD_ORIENT.PORTRAIT
    section.page_width = Cm(21.0)
    section.page_height = Cm(29.7)
    section.left_margin = Cm(1.35)
    section.right_margin = Cm(1.35)
    for overview_section in spec["overview"]:
        add_heading(document, overview_section["title"], 1)
        add_overview_table(
            document,
            overview_section["rows"],
            list(spec.get("overview_headers", ("Parameter", "Description"))),
        )

    for index, group in enumerate(spec["connector_groups"]):
        heading = add_heading(document, group["title"], 1)
        heading.paragraph_format.page_break_before = index == 0
        if index:
            heading.paragraph_format.space_before = Pt(CONNECTOR_GAP_PT)
        for item_index, item in enumerate(group["items"]):
            item.setdefault("table_headers", spec.get("table_headers", ()))
            item.setdefault("image_alt_template", spec.get("image_alt_template", "Orthographic 3D PCB view of {designator}"))
            item.setdefault("image_caption_template", spec.get("image_caption_template", "Orthographic 3D view — {designator}"))
            item.setdefault("pinout_alt_template", spec.get("pinout_alt_template", "Pinout diagram for {designator} — {name}"))
            item.setdefault("pinout_caption_template", spec.get("pinout_caption_template", "Connector-side pinout — {designator}"))
            add_item(document, item, follows_connector=bool(item_index))

    # Reserve a compact final paragraph so Word's end marker does not spill
    # onto its own page when the last connector table fills the text area.
    end = document.add_paragraph()
    end.paragraph_format.space_after = Pt(0)
    end.paragraph_format.line_spacing = Pt(1)
    end.paragraph_format.keep_with_next = False

    output.parent.mkdir(parents=True, exist_ok=True)
    document.save(output)


def write_pdf_source(docx: Path, render_copy: Path) -> None:
    """Keep SVG pictures selected and bake their stroke widths into vector outlines."""
    try:
        if __package__:
            from .board_pdf_vectors import vectorize_pdf_svg
        else:
            from board_pdf_vectors import vectorize_pdf_svg
    except ImportError as error:
        raise SpecError(str(error)) from error
    with ZipFile(docx) as source, ZipFile(render_copy, "w") as output:
        for member in source.infolist():
            data = source.read(member)
            if member.filename.startswith("word/media/") and member.filename.endswith(".svg"):
                data = vectorize_pdf_svg(data)
            output.writestr(member, data)


def export_pdf(docx: Path, pdf: Path) -> None:
    """Render the finished DOCX using Word or LibreOffice."""
    errors: list[str] = []
    if sys.platform == "win32" and (powershell := shutil.which("powershell.exe")):
        word_export = """
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
$source = $env:BOARD_MANUAL_DOCX
$readOnly = $true
$disabled = $false
$discard = 0
try {
    $document = $word.Documents.Open([ref]$source, [ref]$disabled, [ref]$readOnly, [ref]$disabled)
    try { $document.ExportAsFixedFormat($env:BOARD_MANUAL_PDF, 17) }
    finally { $document.Close([ref]$discard) }
} finally { $word.Quit([ref]$discard) }
"""
        try:
            result = subprocess.run(
                [powershell, "-NoProfile", "-NonInteractive", "-Command", word_export],
                env={**os.environ, "BOARD_MANUAL_DOCX": str(docx), "BOARD_MANUAL_PDF": str(pdf)},
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            if result.returncode == 0 and pdf.is_file():
                return
            errors.append(result.stderr.strip() or "Word did not create the PDF")
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))

    if soffice := shutil.which("soffice") or shutil.which("libreoffice"):
        profile = (pdf.parent / "office-profile").as_uri()
        try:
            result = subprocess.run(
                [soffice, f"-env:UserInstallation={profile}", "--headless", "--convert-to",
                 "pdf:writer_pdf_Export", "--outdir", str(pdf.parent), str(docx)],
                capture_output=True, text=True, errors="replace", timeout=180,
            )
            if result.returncode == 0 and pdf.is_file():
                return
            errors.append(result.stderr.strip() or result.stdout.strip() or "LibreOffice did not create the PDF")
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))

    detail = "\n".join(errors) or "Install Microsoft Word or put LibreOffice on PATH."
    raise SpecError(f"PDF export failed. {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="Destination DOCX. The PDF uses the same base name.")
    parser.add_argument("--docx-only", action="store_true", help="Create only the editable DOCX.")
    args = parser.parse_args()
    output = args.output.resolve()
    input_path = args.data.resolve()
    pdf = output.with_suffix(".pdf")
    if input_path == output or (not args.docx_only and input_path == pdf):
        raise SystemExit("input and output paths must be different")
    if output.suffix.lower() != ".docx":
        raise SystemExit("--output must name a .docx file")
    try:
        spec = parse_spec(input_path)
        if args.docx_only:
            build_document(spec, output)
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=output.parent, prefix=".manual-") as directory:
                draft_docx = Path(directory) / output.name
                draft_pdf = Path(directory) / pdf.name
                build_document(spec, draft_docx)
                # Filled outlines preserve the authored widths through Word's PDF conversion.
                render_copy = Path(directory) / "render" / output.name
                render_copy.parent.mkdir()
                write_pdf_source(draft_docx, render_copy)
                export_pdf(render_copy, draft_pdf)
                with draft_pdf.open("rb") as stream:
                    if stream.read(5) != b"%PDF-":
                        raise SpecError("The renderer did not produce a valid PDF header.")
                draft_docx.replace(output)
                draft_pdf.replace(pdf)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(output)
    if not args.docx_only:
        print(pdf)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
