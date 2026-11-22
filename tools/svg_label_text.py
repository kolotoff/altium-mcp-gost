"""Place the visible bounds of Arial text without SVG renderer font-metric differences."""

import base64
import xml.etree.ElementTree as ET
from functools import lru_cache
from io import BytesIO

from PIL import Image, ImageFont


SVG = "http://www.w3.org/2000/svg"
XLINK = "http://www.w3.org/1999/xlink"
PIXELS_PER_MM = 64
ET.register_namespace("xlink", XLINK)


@lru_cache(maxsize=8)
def label_font(pixel_size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype("arialbd.ttf", pixel_size)


def add_label_ink(
    parent: ET.Element, value: str, x: float, y: float, *, size: float,
    fill: str, anchor: str = "middle", pitch: float = 2.0,
    max_size: tuple[float, float] | None = None, center_capitals: bool = False,
) -> ET.Element:
    """Anchor visible width on x and center the ink or capital height on y."""
    font = label_font(round(size * PIXELS_PER_MM))
    rows = []
    tops = []
    for part in value.split("|"):
        mask, (_, baseline_offset) = font.getmask2(part, mode="L", anchor="ls")
        ink = Image.frombytes("L", mask.size, bytes(mask))
        bounds = ink.getbbox()
        rows.append(ink.crop(bounds))
        tops.append(baseline_offset + (bounds[1] if bounds else 0))
    line_pitch = round(pitch * PIXELS_PER_MM)
    if center_capitals:
        # Underscores and descenders should not pull the main characters above the leader.
        _, cap_top, _, cap_bottom = font.getbbox("H", anchor="ls")
        cap_center = (cap_top + cap_bottom) / 2
        row_positions = [index * line_pitch + top - cap_center for index, top in enumerate(tops)]
    else:
        row_positions = [index * line_pitch - row.height // 2 for index, row in enumerate(rows)]
    top = min(row_positions)
    bottom = max(y + row.height for y, row in zip(row_positions, rows))
    width = max(row.width for row in rows)
    mask = Image.new("L", (width, round(bottom - top)))
    for row_top, row in zip(row_positions, rows):
        mask.paste(row, ((width - row.width) // 2, round(row_top - top)))
    image = Image.new("RGBA", mask.size, fill)
    image.putalpha(mask)
    buffer = BytesIO()
    image.save(buffer, format="PNG")

    scale = 1 / PIXELS_PER_MM
    if max_size is not None:
        scale = min(scale, max_size[0] / image.width, max_size[1] / image.height)
    width, height = image.width * scale, image.height * scale
    top_offset = top * scale if center_capitals else -height / 2
    left = x - width * {"start": 0.0, "middle": 0.5, "end": 1.0}[anchor]
    accessible = value.replace("|", " · ")
    label = ET.SubElement(parent, f"{{{SVG}}}image", {
        "x": f"{left:.4f}", "y": f"{y + top_offset:.4f}",
        "width": f"{width:.4f}", "height": f"{height:.4f}",
        "aria-label": accessible, "data-font-family": "Arial",
        f"{{{XLINK}}}href": "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii"),
    })
    if center_capitals:
        label.set("data-cap-center-offset", f"{-top_offset:.4f}")
    ET.SubElement(label, f"{{{SVG}}}title").text = accessible
    return label
