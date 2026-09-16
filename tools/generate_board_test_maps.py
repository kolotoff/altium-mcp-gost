"""Generate top/bottom test-access maps with nonintersecting designator callouts."""

from __future__ import annotations

import argparse
import copy
import json
import math
import random
import re
import xml.etree.ElementTree as ET
from pathlib import Path

if __package__:
    from .generate_board_interface_maps import remove_outside_mounting_holes
else:
    from generate_board_interface_maps import remove_outside_mounting_holes


SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)

COLORS = {
    "testpoint": "#1677FF",
    "solder-bridge": "#E86F00",
    "keystone-5016": "#7C3AED",
    "through-hole-signal": "#475467",
}
LEGEND = {
    "testpoint": "Контрольные точки",
    "solder-bridge": "SB элементы",
    "keystone-5016": "Keystone 5016",
    "through-hole-signal": "Отверстия ≥ 1 мм",
}


def qname(name: str) -> str:
    return f"{{{SVG}}}{name}"


def parse_numbers(text: str) -> list[float]:
    return [float(value) for value in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", text)]


def text(parent: ET.Element, x: float, y: float, value: str, **attrs: str) -> ET.Element:
    settings = {
        "x": f"{x:.3f}",
        "y": f"{y:.3f}",
        "font-family": "Aptos, Arial, sans-serif",
        "fill": "#263746",
    }
    settings.update(attrs)
    node = ET.SubElement(parent, qname("text"), settings)
    node.text = value
    return node


def remove_pads(element: ET.Element) -> None:
    for child in list(element):
        if child.get("id") == "Pads" or child.get("data-layer") == "pads":
            element.remove(child)
        else:
            remove_pads(child)


def component_positions(root: ET.Element, *, bottom: bool, view_x: float, view_y: float, view_width: float) -> dict[str, tuple[float, float]]:
    positions: dict[str, tuple[float, float]] = {}
    for suffix in ("-assembly", "-pads"):
        for element in root.iter():
            identifier = element.get("id", "")
            designator = element.get("data-component")
            if not designator or not identifier.endswith(suffix) or designator in positions:
                continue
            match = re.search(r"translate\(\s*([-+0-9.eE]+)[ ,]+([-+0-9.eE]+)\s*\)", element.get("transform", ""))
            if not match:
                continue
            x, y = float(match.group(1)), float(match.group(2))
            if bottom:
                x = 2.0 * view_x + view_width - x
            positions[designator] = (x - view_x, -y - view_y)
    return positions


def category(item: dict) -> str:
    for key in COLORS:
        if key in item.get("categories", []):
            return key
    raise ValueError(f"item has no supported category: {item.get('designator')}")


def pad_positions(root: ET.Element, *, bottom: bool, view_x: float, view_y: float, view_width: float) -> dict[tuple[str, str], tuple[float, float]]:
    """Locate pad copper centers in the original export before hiding its Pads layer."""
    positions = {}
    for group in root.iter():
        if not group.get("id", "").endswith("-pads") or not group.get("data-component"):
            continue
        match = re.search(r"translate\(\s*([-+0-9.eE]+)[ ,]+([-+0-9.eE]+)\s*\)\s*rotate\(\s*([-+0-9.eE]+)", group.get("transform", ""))
        if not match:
            continue
        gx, gy, angle = map(float, match.groups())
        radians = math.radians(angle)
        for pad in group:
            number = pad.get("data-pad-number")
            if number is None or not pad.get("d"):
                continue
            numbers = parse_numbers(pad.get("d", ""))
            if len(numbers) < 4 or len(numbers) % 2:
                continue
            local_x = (min(numbers[::2]) + max(numbers[::2])) / 2
            local_y = (min(numbers[1::2]) + max(numbers[1::2])) / 2
            x = gx + local_x * math.cos(radians) - local_y * math.sin(radians)
            y = gy + local_x * math.sin(radians) + local_y * math.cos(radians)
            if bottom:
                x = 2 * view_x + view_width - x
            positions[(group.get("data-component"), number)] = (x - view_x, -y - view_y)
    return positions


def distance_to_segment(point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]) -> float:
    dx, dy = end[0] - start[0], end[1] - start[1]
    length_squared = dx * dx + dy * dy
    t = 0.0 if length_squared < 1e-12 else max(0.0, min(1.0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length_squared))
    return math.hypot(point[0] - start[0] - t * dx, point[1] - start[1] - t * dy)


def segments_cross(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float], d: tuple[float, float]) -> bool:
    def orientation(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
    return orientation(a, b, c) * orientation(a, b, d) < 0 and orientation(c, d, a) * orientation(c, d, b) < 0


def leaders_intersect(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float], d: tuple[float, float]) -> bool:
    return segments_cross(a, b, c, d) or min(
        distance_to_segment(a, c, d), distance_to_segment(b, c, d),
        distance_to_segment(c, a, b), distance_to_segment(d, a, b),
    ) < 0.35


def line_hits_box(start: tuple[float, float], end: tuple[float, float], box: tuple[float, float, float, float], clearance: float = 0.15) -> bool:
    x, y, width, height = box
    left, top, right, bottom = x - clearance, y - clearance, x + width + clearance, y + height + clearance
    if left <= start[0] <= right and top <= start[1] <= bottom:
        return True
    if left <= end[0] <= right and top <= end[1] <= bottom:
        return True
    corners = [(left, top), (right, top), (right, bottom), (left, bottom)]
    return any(
        segments_cross(start, end, corners[index], corners[(index + 1) % 4])
        or distance_to_segment(corners[index], start, end) < 1e-8
        or distance_to_segment(corners[(index + 1) % 4], start, end) < 1e-8
        for index in range(4)
    )


def boxes_intersect(a: tuple[float, float, float, float], b: tuple[float, float, float, float], clearance: float = 0.25) -> bool:
    return a[0] < b[0] + b[2] + clearance and a[0] + a[2] + clearance > b[0] and a[1] < b[1] + b[3] + clearance and a[1] + a[3] + clearance > b[1]


def candidate_geometry(anchor: tuple[float, float], box: tuple[float, float, float, float]) -> tuple[tuple[float, float], tuple[float, float]]:
    x, y, width, height = box
    nearest = (max(x, min(anchor[0], x + width)), max(y, min(anchor[1], y + height)))
    dx, dy = nearest[0] - anchor[0], nearest[1] - anchor[1]
    distance = math.hypot(dx, dy)
    return (anchor[0] + dx / distance * 0.85, anchor[1] + dy / distance * 0.85), nearest


def candidate_boxes(item: dict, anchors: list[tuple[float, float]], limit_y: float) -> list[tuple[float, float, float, float]]:
    ax, ay = item["anchor"]
    # A conservative Aptos/Arial width keeps long net-named designators inside the chip.
    width = max(5.2, 2.5 + len(item["label"]) * 1.16)
    height = 3.25
    candidates = []
    for radius in (1.6, 3.2, 5.2, 7.8, 11.0, 15.0, 20.0, 26.0, 34.0):
        for step in range(24):
            angle = 2 * math.pi * step / 24
            ux, uy = math.cos(angle), math.sin(angle)
            # The offset is measured from the anchor to the nearest rectangle edge.
            center_x = ax + ux * (radius + width / 2 + 0.95)
            center_y = ay + uy * (radius + height / 2 + 0.95)
            box = (center_x - width / 2, center_y - height / 2, width, height)
            x, y, w, h = box
            if x < 2.0 or x + w > 268.0 or y < 12.5 or y + h > limit_y:
                continue
            if any(x - 1.8 < px < x + w + 1.8 and y - 1.8 < py < y + h + 1.8 for px, py in anchors):
                continue
            start, end = candidate_geometry(item["anchor"], box)
            if any(distance_to_segment(point, start, end) < 1.85 for point in anchors if point != item["anchor"]):
                continue
            candidates.append(box)
    return candidates


def can_place(item: dict, box: tuple[float, float, float, float], placed: list[dict]) -> bool:
    start, end = candidate_geometry(item["anchor"], box)
    for other in placed:
        other_box = other["marker_box"]
        if boxes_intersect(box, other_box):
            return False
        if line_hits_box(start, end, other_box) or line_hits_box(*other["leader"], box):
            return False
        if leaders_intersect(start, end, *other["leader"]):
            return False
        # A line may not graze another circled anchor.
        if distance_to_segment(other["anchor"], start, end) < 1.85 or distance_to_segment(item["anchor"], *other["leader"]) < 1.85:
            return False
    return True


def place_markers(items: list[dict], limit_y: float) -> None:
    """Search local and perimeter positions; reject every annotation intersection."""
    anchors = [item["anchor"] for item in items]
    if len(set(anchors)) != len(anchors):
        raise ValueError("duplicate callout anchors")
    for item in items:
        item["candidates"] = candidate_boxes(item, anchors, limit_y)
        if not item["candidates"]:
            raise ValueError(f"no free map-label position for {item['label']}")
    randomizer = random.Random(10817)
    best_count = 0
    for attempt in range(180):
        order = list(items)
        randomizer.shuffle(order)
        order.sort(key=lambda item: (len(item["candidates"]), -len(item["label"]), randomizer.random() * (6 if attempt else 0)))
        placed = []
        for item in order:
            options = item["candidates"][:]
            if attempt:
                # Short callouts remain preferred, but vary ties and nearby slots.
                options.sort(key=lambda box: math.hypot(box[0] + box[2] / 2 - item["anchor"][0], box[1] + box[3] / 2 - item["anchor"][1]) + randomizer.random() * (1.4 + attempt / 35))
            found = next((box for box in options if can_place(item, box, placed)), None)
            if found is None:
                break
            item["marker_box"] = found
            item["leader"] = candidate_geometry(item["anchor"], found)
            placed.append(item)
        best_count = max(best_count, len(placed))
        if len(placed) == len(items):
            for item in items:
                del item["candidates"]
            return
    raise ValueError(f"nonintersecting layout found for only {best_count}/{len(items)} labels")


def render_marker(root: ET.Element, item: dict) -> None:
    x, y, width, height = item["marker_box"]
    ax, ay = item["anchor"]
    cx, cy = x + width / 2, y + height / 2
    color = COLORS[category(item)]
    (start_x, start_y), (end_x, end_y) = item["leader"]
    ET.SubElement(root, qname("line"), {
        "x1": f"{end_x:.3f}", "y1": f"{end_y:.3f}", "x2": f"{start_x:.3f}", "y2": f"{start_y:.3f}",
        "stroke": color, "stroke-width": "0.28", "stroke-linecap": "round",
        "data-callout": item["key"],
    })
    ET.SubElement(root, qname("circle"), {
        "cx": f"{ax:.3f}", "cy": f"{ay:.3f}", "r": "0.7", "fill": "#FFFFFF",
        "stroke": color, "stroke-width": "0.45", "data-callout": item["key"],
    })
    ET.SubElement(root, qname("rect"), {
        "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
        "rx": "0.75", "fill": color, "stroke": "#FFFFFF", "stroke-width": "0.35",
        "data-callout": item["key"], "data-label-for": item["designator"],
    })
    text(root, cx, y + 2.35, item["label"], **{
        "font-size": "1.67", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF",
        "data-callout": item["key"],
    })


def legend_entry(root: ET.Element, item: dict, x: float, y: float, width: float) -> None:
    color = COLORS[category(item)]
    ET.SubElement(root, qname("circle"), {
        "cx": f"{x + 1.5:.3f}", "cy": f"{y - 1.10:.3f}", "r": "0.85", "fill": color,
    })
    source = ", ".join(dict.fromkeys(str(pin["source_net"]) for pin in item.get("pins", [])))
    designator = str(item["designator"])
    text(root, x + 4.0, y - 0.25, designator, **{"font-size": "1.9", "font-weight": "700"})
    source_x = x + 39.0
    max_chars = max(8, int((width - (source_x - x) - 1.0) / 0.85))
    if len(source) > max_chars:
        source = source[: max_chars - 1] + "…"
    text(root, source_x, y - 0.25, source, **{"font-size": "1.75", "fill": "#637785"})


def build_page(inventory: dict, source_path: Path, output_path: Path, *, side: str) -> None:
    page_w, page_h = 270.0, 180.0
    source_root = ET.parse(source_path).getroot()
    view = parse_numbers(source_root.get("viewBox", ""))
    if len(view) != 4:
        raise ValueError(f"invalid board SVG viewBox: {source_path}")
    view_x, view_y, board_w, board_h = view
    board_display_w = 246.0
    scale = board_display_w / board_w
    board_display_h = board_h * scale
    board_x = (page_w - board_display_w) / 2.0
    board_y = 15.8
    if board_y + board_display_h > 122.0:
        raise ValueError("board aspect ratio leaves insufficient room for the map legend")
    positions = component_positions(source_root, bottom=side == "bottom", view_x=view_x, view_y=view_y, view_width=board_w)
    pads = pad_positions(source_root, bottom=side == "bottom", view_x=view_x, view_y=view_y, view_width=board_w)
    items = [copy.deepcopy(item) for item in inventory["components"] if item.get("side") == side]
    missing = [item["designator"] for item in items if item["designator"] not in positions]
    if missing:
        raise ValueError(f"components missing from {side} assembly SVG: {', '.join(missing)}")

    callouts = []
    for item in items:
        qualifying = [pin for pin in item.get("pins", []) if float(pin.get("hole_mm") or 0) >= 1.0 and pin.get("pcb_net") and not str(pin.get("pad", "")).upper().startswith("MP")]
        if "through-hole-signal" in item.get("categories", []) and qualifying:
            for pin in qualifying:
                key = (item["designator"], str(pin["pad"]))
                if key not in pads:
                    raise ValueError(f"pad {key} missing from {side} SVG")
                local_x, local_y = pads[key]
                callouts.append({**item, "key": f"{key[0]}:{key[1]}", "label": f"{key[0]}/{key[1]} {pin['source_net']}", "anchor": (board_x + local_x * scale, board_y + local_y * scale)})
        else:
            local_x, local_y = positions[item["designator"]]
            callouts.append({**item, "key": item["designator"], "label": item["designator"], "anchor": (board_x + local_x * scale, board_y + local_y * scale)})
    place_markers(callouts, board_y + board_display_h + 0.8)

    root = ET.Element(qname("svg"), {
        "version": "1.2", "baseProfile": "tiny", "data-coordinate-units": "mm",
        "width": f"{page_w}mm", "height": f"{page_h}mm", "viewBox": f"0 0 {page_w} {page_h}",
    })
    ET.SubElement(root, qname("rect"), {"x": "0", "y": "0", "width": str(page_w), "height": str(page_h), "fill": "#FFFFFF"})
    side_title = "ВЕРХНЯЯ" if side == "top" else "НИЖНЯЯ"
    text(root, 4.0, 5.6, f"{side_title} СТОРОНА  КАРТА ТЕСТОВОГО ДОСТУПА", **{"font-size": "3.6", "font-weight": "700", "fill": "#000000"})
    legend_x = 4.0
    for key in COLORS:
        ET.SubElement(root, qname("rect"), {"x": f"{legend_x:.2f}", "y": "8.2", "width": "3.2", "height": "2.5", "rx": "0.5", "fill": COLORS[key]})
        text(root, legend_x + 4.4, 10.3, LEGEND[key], **{"font-size": "1.85", "font-weight": "600"})
        legend_x += 59.0

    clean = copy.deepcopy(source_root)
    remove_pads(clean)
    remove_outside_mounting_holes(clean)
    nested = ET.SubElement(root, qname("svg"), {
        "x": f"{board_x:.3f}", "y": f"{board_y:.3f}", "width": f"{board_display_w:.3f}", "height": f"{board_display_h:.3f}",
        "viewBox": f"{view_x:.6f} {view_y:.6f} {board_w:.6f} {board_h:.6f}",
    })
    for child in list(clean):
        nested.append(copy.deepcopy(child))
    for item in callouts:
        render_marker(root, item)

    legend_top = board_y + board_display_h + 4.0
    columns = 3
    rows = max(1, (len(items) + columns - 1) // columns)
    column_width = (page_w - 8.0) / columns
    row_height = (page_h - legend_top - 4.0) / rows
    if row_height < 3.35:
        raise ValueError("too many legend entries for the selected map page")
    for index, item in enumerate(items):
        column = index // rows
        row = index % rows
        legend_entry(root, item, 4.0 + column * column_width, legend_top + (row + 1) * row_height, column_width - 2.0)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--top-svg", type=Path, required=True)
    parser.add_argument("--bottom-svg", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text(encoding="utf-8-sig"))
    build_page(inventory, args.top_svg, args.output_dir / "pcb-test-map-top.svg", side="top")
    build_page(inventory, args.bottom_svg, args.output_dir / "pcb-test-map-bottom.svg", side="bottom")
    print(args.output_dir.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
