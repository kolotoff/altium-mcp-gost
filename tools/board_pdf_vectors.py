"""Prepare the board artwork for Word's vector PDF exporter."""

from __future__ import annotations

import base64
import re
from functools import lru_cache
from io import BytesIO

from lxml import etree
from PIL import Image

try:
    import skia
except ImportError as exc:
    raise ImportError("Install skia-python to export the board manuals as vector PDFs.") from exc

if __package__:
    from .pcb_svg_geometry import parse_numbers
    from .svg_label_text import PIXELS_PER_MM, SVG, XLINK, label_font
else:
    from pcb_svg_geometry import parse_numbers
    from svg_label_text import PIXELS_PER_MM, SVG, XLINK, label_font


SVG_NS = f"{{{SVG}}}"
STROKED_SHAPES = {"path", "line", "polyline", "polygon", "circle", "ellipse", "rect"}


def shape_path(element: etree._Element, kind: str) -> skia.Path:
    path = skia.Path()
    if kind == "path":
        # Altium assembly exports use absolute move, line, arc, and close commands.
        for command, args in re.findall(r"([A-DF-Za-df-z])([^A-DF-Za-df-z]*)", element.get("d", "")):
            values = parse_numbers(args)
            if command in {"M", "L"}:
                if command == "M":
                    path.moveTo(*values[:2])
                    values = values[2:]
                for x, y in zip(values[::2], values[1::2], strict=True):
                    path.lineTo(x, y)
            elif command == "A":
                for i in range(0, len(values), 7):
                    rx, ry, angle, large, sweep, x, y = values[i:i + 7]
                    path.arcTo(rx, ry, angle, skia.Path.kLarge_ArcSize if large else skia.Path.kSmall_ArcSize,
                               skia.PathDirection.kCW if sweep else skia.PathDirection.kCCW, x, y)
            elif command == "Z":
                path.close()
            else:
                raise ValueError(f"Unsupported assembly SVG path command in PDF artwork: {command}")
        return path

    if kind in {"line", "polyline", "polygon"}:
        points = ([float(element.get(key, "0")) for key in ("x1", "y1", "x2", "y2")]
                  if kind == "line" else parse_numbers(element.get("points", "")))
        if points:
            path.moveTo(*points[:2])
            for x, y in zip(points[2::2], points[3::2], strict=True):
                path.lineTo(x, y)
            if kind == "polygon":
                path.close()
    elif kind in {"circle", "ellipse"}:
        x, y = (float(element.get(key, "0")) for key in ("cx", "cy"))
        rx = float(element.get("r", element.get("rx", "0")))
        ry = float(element.get("r", element.get("ry", "0")))
        path.addOval(skia.Rect.MakeLTRB(x - rx, y - ry, x + rx, y + ry))
    else:
        x, y, width, height = (float(element.get(key, "0")) for key in ("x", "y", "width", "height"))
        rx = float(element.get("rx", element.get("ry", "0")))
        ry = float(element.get("ry", element.get("rx", "0")))
        path.addRoundRect(skia.Rect.MakeXYWH(x, y, width, height), rx, ry)
    return path


def svg_path_data(path: skia.Path) -> str:
    verbs = skia.Path.Verb
    commands = {verbs.kMove_Verb: "M", verbs.kLine_Verb: "L", verbs.kQuad_Verb: "Q", verbs.kCubic_Verb: "C"}
    output = []
    iterator = skia.Path.RawIter(path)
    for verb, points in iterator:
        if verb == verbs.kClose_Verb:
            output.append("Z")
        elif verb == verbs.kConic_Verb:
            points = skia.Path.ConvertConicToQuads(*points, iterator.conicWeight(), 2)
            for index in range(1, len(points), 2):
                output.append("Q" + " ".join(f"{v:.6f}" for pt in points[index:index + 2] for v in (pt.x(), pt.y())))
        else:
            coords = points if verb == verbs.kMove_Verb else points[1:]
            output.append(commands[verb] + " ".join(f"{v:.6f}" for pt in coords for v in (pt.x(), pt.y())))
    return " ".join(output)


def stroke_outline(element: etree._Element, kind: str, style: dict[str, str]) -> etree._Element | None:
    width = float(style.get("stroke-width", "1"))
    element.set("stroke", "none")
    if width <= 0:
        return None
    cap = {"butt": skia.Paint.kButt_Cap, "round": skia.Paint.kRound_Cap, "square": skia.Paint.kSquare_Cap}
    join = {"miter": skia.Paint.kMiter_Join, "round": skia.Paint.kRound_Join, "bevel": skia.Paint.kBevel_Join}
    paint = skia.Paint()
    paint.setStyle(skia.Paint.kStroke_Style)
    paint.setStrokeWidth(width)
    paint.setStrokeCap(cap[style.get("stroke-linecap", "butt")])
    paint.setStrokeJoin(join[style.get("stroke-linejoin", "miter")])
    paint.setStrokeMiter(float(style.get("stroke-miterlimit", "4")))
    path = skia.Path()
    paint.getFillPath(shape_path(element, kind), path, None, 4)
    if path.isEmpty():
        return None
    outline = etree.Element(SVG_NS + "path", d=svg_path_data(path), fill=style["stroke"], stroke="none")
    outline.set("fill-opacity", style.get("stroke-opacity", "1"))
    for attribute in ("transform", "opacity", "clip-path"):
        if attribute in element.attrib:
            outline.set(attribute, element.attrib[attribute])
    return outline


@lru_cache(maxsize=1)
def outline_font() -> skia.Font:
    font = skia.Typeface.MakeFromFile(label_font(1024).path)
    return skia.Font(font, 1024)


@lru_cache(maxsize=2048)
def label_path(value: str) -> tuple[str, skia.Rect]:
    font = outline_font()
    metrics = label_font(1024)
    path = skia.Path()
    for index, (character, glyph) in enumerate(zip(value, font.getPaths(font.textToGlyphs(value)), strict=True)):
        if glyph is not None and not glyph.isEmpty():
            position = metrics.getlength(value[:index + 1]) - metrics.getlength(character)
            path.addPath(glyph, position, 0)
    return svg_path_data(path), path.computeTightBounds()


def vector_label(element: etree._Element) -> etree._Element:
    value = element.attrib["aria-label"]
    href = element.attrib[f"{{{XLINK}}}href"]
    with Image.open(BytesIO(base64.b64decode(href.split(",", 1)[1]))) as source:
        image = source.convert("RGBA")
    alpha = image.getchannel("A")
    projection = alpha.resize((1, alpha.height), Image.Resampling.BOX).tobytes()
    occupied = [y for y, intensity in enumerate(projection) if intensity]
    first, last = occupied[0], occupied[-1] + 1
    gaps = [(a + 1, b) for a, b in zip(occupied, occupied[1:]) if b - a > PIXELS_PER_MM / 3]
    # Older diagrams expose their multiline label as text joined with middle dots.
    lines = value.split(" · ") if gaps else [value]
    rows = list(zip([first] + [b for _, b in gaps], [a for a, _ in gaps] + [last], strict=True))
    x, y, width, height = (float(element.get(key, "0")) for key in ("x", "y", "width", "height"))
    sx, sy = width / image.width, height / image.height
    rgb = image.getpixel((0, 0))[:3]
    group = etree.Element(SVG_NS + "g", {"aria-label": value, "stroke": "none"})
    for line, (top, bottom) in zip(lines, rows, strict=True):
        left, y0, right, y1 = alpha.crop((0, top, alpha.width, bottom)).getbbox()
        outline, bounds = label_path(line)
        scale_x, scale_y = (right - left) * sx / bounds.width(), (y1 - y0) * sy / bounds.height()
        px = x + sx * left - bounds.left() * scale_x
        py = y + sy * (top + y0) - bounds.top() * scale_y
        etree.SubElement(group, SVG_NS + "path", d=outline, fill="#{:02x}{:02x}{:02x}".format(*rgb),
                         transform=f"matrix({scale_x:.8f} 0 0 {scale_y:.8f} {px:.6f} {py:.6f})")
    return group


def vectorize_pdf_svg(data: bytes) -> bytes:
    root = etree.fromstring(data)

    def convert(parent: etree._Element, inherited: dict[str, str]) -> None:
        style = {**inherited, **{key: value for key, value in parent.attrib.items() if key.startswith("stroke")}}
        for child in list(parent):
            kind = etree.QName(child).localname
            if kind == "image" and child.get("data-font-family") == "Arial":
                parent.replace(child, vector_label(child))
            elif kind in STROKED_SHAPES:
                stroke = {**style, **{key: value for key, value in child.attrib.items() if key.startswith("stroke")}}
                if stroke.get("stroke", "none") != "none":
                    outline = stroke_outline(child, kind, stroke)
                    if outline is not None:
                        if child.get("fill") == "none":
                            parent.replace(child, outline)
                        else:
                            child.addnext(outline)
            else:
                convert(child, style)

    convert(root, {})
    return etree.tostring(root, encoding="utf-8", xml_declaration=True)
