"""Generate dense top/bottom SVG test-access maps with indexed markers and legends."""

from __future__ import annotations

import argparse
import copy
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path


SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)

COLORS = {
    "testpoint": "#1677FF",
    "solder-bridge": "#E86F00",
    "keystone-5016": "#7C3AED",
    "through-hole-signal": "#475467",
}
PREFIXES = {
    "testpoint": "T",
    "solder-bridge": "S",
    "keystone-5016": "K",
    "through-hole-signal": "H",
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
    for key in PREFIXES:
        if key in item.get("categories", []):
            return key
    raise ValueError(f"item has no supported category: {item.get('designator')}")


def overlaps(a: tuple[float, float, float, float], b: tuple[float, float, float, float], pad: float = 0.35) -> bool:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return not (ax + aw + pad <= bx or bx + bw + pad <= ax or ay + ah + pad <= by or by + bh + pad <= ay)


def place_markers(items: list[dict], positions: dict[str, tuple[float, float]], board_x: float, board_y: float, board_w: float, board_h: float) -> None:
    occupied: list[tuple[float, float, float, float]] = []
    marker_w, marker_h = 5.4, 3.4
    offsets = [(0.0, 0.0)]
    for radius in (3.8, 6.2, 8.6, 11.0):
        offsets.extend(
            (math.cos(angle) * radius, math.sin(angle) * radius)
            for angle in (0, math.pi / 4, math.pi / 2, 3 * math.pi / 4, math.pi, 5 * math.pi / 4, 3 * math.pi / 2, 7 * math.pi / 4)
        )
    for item in sorted(items, key=lambda record: record["designator"].upper()):
        local_x, local_y = positions[item["designator"]]
        anchor_x, anchor_y = board_x + local_x, board_y + local_y
        selected = None
        for dx, dy in offsets:
            x = min(max(anchor_x + dx - marker_w / 2, board_x), board_x + board_w - marker_w)
            y = min(max(anchor_y + dy - marker_h / 2, board_y), board_y + board_h - marker_h)
            box = (x, y, marker_w, marker_h)
            if not any(overlaps(box, old) for old in occupied):
                selected = box
                break
        if selected is None:
            raise ValueError(f"could not place a non-overlapping marker for {item['designator']}")
        occupied.append(selected)
        item["anchor"] = (anchor_x, anchor_y)
        item["marker_box"] = selected


def render_marker(root: ET.Element, item: dict) -> None:
    x, y, width, height = item["marker_box"]
    ax, ay = item["anchor"]
    cx, cy = x + width / 2, y + height / 2
    color = COLORS[category(item)]
    if abs(cx - ax) > 0.25 or abs(cy - ay) > 0.25:
        ET.SubElement(root, qname("line"), {
            "x1": f"{ax:.3f}", "y1": f"{ay:.3f}", "x2": f"{cx:.3f}", "y2": f"{cy:.3f}",
            "stroke": color, "stroke-width": "0.45", "stroke-linecap": "round",
        })
    ET.SubElement(root, qname("circle"), {
        "cx": f"{ax:.3f}", "cy": f"{ay:.3f}", "r": "0.7", "fill": "#FFFFFF",
        "stroke": color, "stroke-width": "0.55",
    })
    ET.SubElement(root, qname("rect"), {
        "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
        "rx": "0.75", "fill": color, "stroke": "#FFFFFF", "stroke-width": "0.35",
    })
    text(root, cx, y + 2.35, item["map_id"], **{
        "font-size": "1.65", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF",
    })


def legend_entry(root: ET.Element, item: dict, x: float, y: float, width: float) -> None:
    color = COLORS[category(item)]
    ET.SubElement(root, qname("rect"), {
        "x": f"{x:.3f}", "y": f"{y - 2.8:.3f}", "width": "7.0", "height": "3.6", "rx": "0.65", "fill": color,
    })
    text(root, x + 3.5, y - 0.25, item["map_id"], **{
        "font-size": "1.65", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF",
    })
    source = ", ".join(dict.fromkeys(str(pin["source_net"]) for pin in item.get("pins", [])))
    designator = str(item["designator"])
    text(root, x + 8.2, y - 0.15, designator, **{"font-size": "2.05", "font-weight": "700"})
    max_chars = max(8, int((width - 31.0) / 1.05))
    if len(source) > max_chars:
        source = source[: max_chars - 1] + "…"
    text(root, x + 29.0, y - 0.15, source, **{"font-size": "1.9", "fill": "#637785"})


def build_page(inventory: dict, source_path: Path, output_path: Path, *, side: str) -> None:
    page_w, page_h = 330.0, 210.0
    source_root = ET.parse(source_path).getroot()
    view = parse_numbers(source_root.get("viewBox", ""))
    if len(view) != 4:
        raise ValueError(f"invalid board SVG viewBox: {source_path}")
    view_x, view_y, board_w, board_h = view
    board_x = (page_w - board_w) / 2.0
    board_y = 27.0
    positions = component_positions(source_root, bottom=side == "bottom", view_x=view_x, view_y=view_y, view_width=board_w)
    items = [copy.deepcopy(item) for item in inventory["components"] if item.get("side") == side]
    missing = [item["designator"] for item in items if item["designator"] not in positions]
    if missing:
        raise ValueError(f"components missing from {side} assembly SVG: {', '.join(missing)}")

    counters = {key: 0 for key in PREFIXES}
    for item in items:
        key = category(item)
        counters[key] += 1
        item["map_id"] = f"{PREFIXES[key]}{counters[key]:02d}"
    place_markers(items, positions, board_x, board_y, board_w, board_h)

    root = ET.Element(qname("svg"), {
        "version": "1.2", "baseProfile": "tiny", "data-coordinate-units": "mm",
        "width": f"{page_w}mm", "height": f"{page_h}mm", "viewBox": f"0 0 {page_w} {page_h}",
    })
    ET.SubElement(root, qname("rect"), {"x": "0", "y": "0", "width": str(page_w), "height": str(page_h), "fill": "#FFFFFF"})
    side_title = "ВЕРХНЯЯ" if side == "top" else "НИЖНЯЯ"
    text(root, 8.0, 10.0, f"{side_title} СТОРОНА  КАРТА ТЕСТОВОГО ДОСТУПА", **{"font-size": "4.4", "font-weight": "700", "fill": "#000000"})
    legend_x = 8.0
    for key in PREFIXES:
        ET.SubElement(root, qname("rect"), {"x": f"{legend_x:.2f}", "y": "14.0", "width": "4.0", "height": "3.0", "rx": "0.6", "fill": COLORS[key]})
        text(root, legend_x + 5.2, 16.45, LEGEND[key], **{"font-size": "2.05", "font-weight": "600"})
        legend_x += 53.0

    clean = copy.deepcopy(source_root)
    remove_pads(clean)
    nested = ET.SubElement(root, qname("svg"), {
        "x": f"{board_x:.3f}", "y": f"{board_y:.3f}", "width": f"{board_w:.3f}", "height": f"{board_h:.3f}",
        "viewBox": f"{view_x:.6f} {view_y:.6f} {board_w:.6f} {board_h:.6f}",
    })
    for child in list(clean):
        nested.append(copy.deepcopy(child))
    for item in items:
        render_marker(root, item)

    legend_top = board_y + board_h + 10.0
    columns = 3
    rows = max(1, math.ceil(len(items) / columns))
    column_width = (page_w - 16.0) / columns
    row_height = min(5.3, (page_h - legend_top - 8.0) / rows)
    for index, item in enumerate(items):
        column = index // rows
        row = index % rows
        legend_entry(root, item, 8.0 + column * column_width, legend_top + (row + 1) * row_height, column_width - 3.0)

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
