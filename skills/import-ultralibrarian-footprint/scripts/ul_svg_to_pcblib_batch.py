#!/usr/bin/env python3
"""Convert an Ultra Librarian footprint preview SVG to an altium-mcp PcbLib batch.

The generated file is intended for:
  PCB_LIB_BATCH_CREATE|<batch_file>|TRUE

Only standard-library modules are used so the script can run in a plain Codex
or PowerShell environment.
"""

from __future__ import annotations

import argparse
import math
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

MIL_TO_MM = 0.0254


@dataclass(frozen=True)
class Rect:
    pin: str
    x1: float
    y1: float
    x2: float
    y2: float

    @property
    def cx(self) -> float:
        return (self.x1 + self.x2) / 2.0

    @property
    def cy(self) -> float:
        return (self.y1 + self.y2) / 2.0

    @property
    def w(self) -> float:
        return abs(self.x2 - self.x1)

    @property
    def h(self) -> float:
        return abs(self.y2 - self.y1)

    def contains_rect(self, other: "Rect", eps: float = 1e-6) -> bool:
        return (
            self.x1 - eps <= other.x1 <= self.x2 + eps
            and self.x1 - eps <= other.x2 <= self.x2 + eps
            and self.y1 - eps <= other.y1 <= self.y2 + eps
            and self.y1 - eps <= other.y2 <= self.y2 + eps
        )


@dataclass(frozen=True)
class TextPin:
    pin: str
    x: float
    y: float


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def attr_float(elem: ET.Element, name: str) -> float:
    return float(elem.attrib[name])


def pin_attr(elem: ET.Element) -> str | None:
    for key in ("data-pin_number", "data-pin_bounding_rect", "data-pin_name"):
        if key in elem.attrib:
            return elem.attrib[key].strip().strip('"')
    return None


def iter_group(root: ET.Element, group_id: str) -> Iterable[ET.Element]:
    for elem in root.iter():
        if elem.attrib.get("id") == group_id:
            yield from list(elem)
            return


def parse_points(points: str) -> list[tuple[float, float]]:
    values = [float(v) for v in re.findall(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", points)]
    if len(values) % 2:
        raise ValueError(f"Odd number of polygon coordinates: {points}")
    return [(values[i], values[i + 1]) for i in range(0, len(values), 2)]


def parse_transform_center(elem: ET.Element) -> tuple[float, float] | None:
    transform = elem.attrib.get("transform", "")
    match = re.search(r"rotate\([^,]+,\s*([^) ,]+)\s*,\s*([^) ,]+)\)", transform)
    if not match:
        return None
    return float(match.group(1)), float(match.group(2))


def rect_from_svg(elem: ET.Element, pin: str) -> Rect:
    x = attr_float(elem, "x")
    y = attr_float(elem, "y")
    w = attr_float(elem, "width")
    h = attr_float(elem, "height")
    center = parse_transform_center(elem)
    if center:
        cx, cy = center
        return Rect(pin, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
    return Rect(pin, x, y, x + w, y + h)


def point_in_polygon(x: float, y: float, points: list[tuple[float, float]]) -> bool:
    inside = False
    j = len(points) - 1
    for i, (xi, yi) in enumerate(points):
        xj, yj = points[j]
        intersects = (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-30) + xi
        if intersects:
            inside = not inside
        j = i
    return inside


def infer_polygon_pin(points: list[tuple[float, float]], text_pins: list[TextPin]) -> str:
    for text_pin in text_pins:
        if point_in_polygon(text_pin.x, text_pin.y, points):
            return text_pin.pin
    min_x, max_x = min(x for x, _ in points), max(x for x, _ in points)
    min_y, max_y = min(y for _, y in points), max(y for _, y in points)
    cx, cy = (min_x + max_x) / 2, (min_y + max_y) / 2
    if not text_pins:
        raise ValueError("Cannot infer polygon pin because no PIN_NUMBER text was found")
    return min(text_pins, key=lambda p: math.hypot(p.x - cx, p.y - cy)).pin


def decompose_orthogonal_polygon(points: list[tuple[float, float]], pin: str) -> list[Rect]:
    xs = sorted(set(round(x, 9) for x, _ in points))
    ys = sorted(set(round(y, 9) for _, y in points))
    cells: list[Rect] = []
    for x1, x2 in zip(xs, xs[1:]):
        if abs(x2 - x1) < 1e-9:
            continue
        for y1, y2 in zip(ys, ys[1:]):
            if abs(y2 - y1) < 1e-9:
                continue
            if point_in_polygon((x1 + x2) / 2, (y1 + y2) / 2, points):
                cells.append(Rect(pin, x1, y1, x2, y2))

    merged = cells
    changed = True
    while changed:
        changed = False
        next_rects: list[Rect] = []
        used = [False] * len(merged)
        for i, a in enumerate(merged):
            if used[i]:
                continue
            current = a
            for j in range(i + 1, len(merged)):
                if used[j]:
                    continue
                b = merged[j]
                same_y = abs(current.y1 - b.y1) < 1e-9 and abs(current.y2 - b.y2) < 1e-9
                touching_x = abs(current.x2 - b.x1) < 1e-9 or abs(b.x2 - current.x1) < 1e-9
                same_x = abs(current.x1 - b.x1) < 1e-9 and abs(current.x2 - b.x2) < 1e-9
                touching_y = abs(current.y2 - b.y1) < 1e-9 or abs(b.y2 - current.y1) < 1e-9
                if same_y and touching_x:
                    current = Rect(pin, min(current.x1, b.x1), current.y1, max(current.x2, b.x2), current.y2)
                    used[j] = True
                    changed = True
                elif same_x and touching_y:
                    current = Rect(pin, current.x1, min(current.y1, b.y1), current.x2, max(current.y2, b.y2))
                    used[j] = True
                    changed = True
            used[i] = True
            next_rects.append(current)
        merged = next_rects
    return merged


def parse_text_pins(root: ET.Element) -> list[TextPin]:
    pins: list[TextPin] = []
    for elem in iter_group(root, "PIN_NUMBER"):
        if local_name(elem.tag) != "text":
            continue
        pin = pin_attr(elem) or (elem.text or "").strip()
        if not pin:
            continue
        pins.append(TextPin(pin, attr_float(elem, "x"), attr_float(elem, "y")))
    return pins


def svg_to_altium_rect(rect: Rect) -> tuple[str, float, float, float, float]:
    return (
        rect.pin,
        rect.cx * MIL_TO_MM,
        -rect.cy * MIL_TO_MM,
        rect.w * MIL_TO_MM,
        rect.h * MIL_TO_MM,
    )


def parse_top_pads(root: ET.Element) -> tuple[list[Rect], int]:
    text_pins = parse_text_pins(root)
    rects: list[Rect] = []
    polygon_rects: list[Rect] = []
    polygon_count = 0
    for elem in iter_group(root, "TOP"):
        name = local_name(elem.tag)
        if name == "rect":
            pin = pin_attr(elem)
            if pin:
                rects.append(rect_from_svg(elem, pin))
        elif name == "polygon" and "points" in elem.attrib:
            points = parse_points(elem.attrib["points"])
            pin = infer_polygon_pin(points, text_pins)
            polygon_rects.extend(decompose_orthogonal_polygon(points, pin))
            polygon_count += 1

    filtered_rects: list[Rect] = []
    for rect in rects:
        if any(poly.pin == rect.pin and poly.contains_rect(rect) for poly in polygon_rects):
            continue
        filtered_rects.append(rect)
    return filtered_rects + polygon_rects, polygon_count


def parse_assembly_lines(root: ET.Element) -> list[tuple[float, float, float, float]]:
    lines = []
    for elem in iter_group(root, "TOP_ASSEMBLY"):
        if local_name(elem.tag) != "line":
            continue
        lines.append((attr_float(elem, "x1"), attr_float(elem, "y1"), attr_float(elem, "x2"), attr_float(elem, "y2")))
    return lines


def parse_silkscreen_circles(root: ET.Element) -> list[tuple[float, float, float, float]]:
    circles = []
    for elem in iter_group(root, "TOP_SILKSCREEN"):
        if local_name(elem.tag) != "path":
            continue
        nums = [float(v) for v in re.findall(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", elem.attrib.get("d", ""))]
        if len(nums) < 9:
            continue
        x_start, y_start = nums[0], nums[1]
        radius = abs(nums[2])
        x_end, y_end = nums[7], nums[8]
        cx, cy = (x_start + x_end) / 2.0, (y_start + y_end) / 2.0
        width = float(elem.attrib.get("stroke-width", "6"))
        circles.append((cx, cy, radius, width))
    return circles


def mm(value_mil: float) -> float:
    return value_mil * MIL_TO_MM


def write_batch(args: argparse.Namespace, root: ET.Element) -> int:
    pads, polygon_count = parse_top_pads(root)
    if not pads:
        raise ValueError("No TOP pads found in SVG")

    lines = [f"FOOTPRINT|{args.name}|{args.description}"]
    for pin, cx, cy, w, h in sorted((svg_to_altium_rect(p) for p in pads), key=lambda p: (p[0], p[1], p[2])):
        lines.append(f"PAD|{pin}|{cx:.4f}|{cy:.4f}|{w:.4f}|{h:.4f}|RECT")

    for x1, y1, x2, y2 in parse_assembly_lines(root):
        lines.append(
            "TRACK|Mechanical Layer 2|"
            f"{mm(x1):.4f}|{-mm(y1):.4f}|{mm(x2):.4f}|{-mm(y2):.4f}|{args.assembly_width_mm:.4f}"
        )

    for cx, cy, radius, width in parse_silkscreen_circles(root):
        line_width = max(args.silk_width_mm, mm(width))
        lines.append(f"ARC|Top Overlay|{mm(cx):.4f}|{-mm(cy):.4f}|{mm(radius):.4f}|0|360|{line_width:.4f}")

    xs: list[float] = []
    ys: list[float] = []
    for pin, cx, cy, w, h in (svg_to_altium_rect(p) for p in pads):
        xs.extend([cx - w / 2, cx + w / 2])
        ys.extend([cy - h / 2, cy + h / 2])
    x1, x2 = min(xs) - args.courtyard_margin_mm, max(xs) + args.courtyard_margin_mm
    y1, y2 = min(ys) - args.courtyard_margin_mm, max(ys) + args.courtyard_margin_mm
    lines.extend(
        [
            f"TRACK|Mechanical Layer 3|{x1:.4f}|{y1:.4f}|{x2:.4f}|{y1:.4f}|{args.courtyard_width_mm:.4f}",
            f"TRACK|Mechanical Layer 3|{x2:.4f}|{y1:.4f}|{x2:.4f}|{y2:.4f}|{args.courtyard_width_mm:.4f}",
            f"TRACK|Mechanical Layer 3|{x2:.4f}|{y2:.4f}|{x1:.4f}|{y2:.4f}|{args.courtyard_width_mm:.4f}",
            f"TRACK|Mechanical Layer 3|{x1:.4f}|{y2:.4f}|{x1:.4f}|{y1:.4f}|{args.courtyard_width_mm:.4f}",
            f"TRACK|Mechanical Layer 3|{x1:.4f}|0.0000|{x2:.4f}|0.0000|{args.courtyard_width_mm:.4f}",
            f"TRACK|Mechanical Layer 3|0.0000|{y1:.4f}|0.0000|{y2:.4f}|{args.courtyard_width_mm:.4f}",
            "TEXT|Mechanical Layer 2|.Designator|-0.5000|0.9000|1.0000|0.2540|0",
            "TEXT|Mechanical Layer 2|.Comment|-0.6000|-1.5000|1.0000|0.2540|0",
            "END",
        ]
    )

    Path(args.out).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return polygon_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--svg", required=True, help="Ultra Librarian detailed footprint preview SVG")
    parser.add_argument("--name", required=True, help="PcbLib footprint name, usually with _UL suffix")
    parser.add_argument("--description", default="Ultra Librarian preview-derived footprint")
    parser.add_argument("--out", required=True, help="Output batch file path")
    parser.add_argument("--courtyard-margin-mm", type=float, default=0.25)
    parser.add_argument("--courtyard-width-mm", type=float, default=0.05)
    parser.add_argument("--assembly-width-mm", type=float, default=0.10)
    parser.add_argument("--silk-width-mm", type=float, default=0.20)
    args = parser.parse_args()

    root = ET.parse(args.svg).getroot()
    polygon_count = write_batch(args, root)
    print(f"Wrote {args.out}")
    if polygon_count:
        print(f"Decomposed {polygon_count} TOP polygon pad(s) into rectangular pads")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
