"""Create pinout SVGs using native Altium component or PCB assembly geometry.

The component ``Shape`` group (or PCB assembly group) supplies the visible
body. Pads supply numbered anchors but remain hidden except for pad-only
contacts and solder bridges, where the real pad paths are the visible part.
Missing native geometry is an error; no connector silhouette is synthesized.
"""

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

DOMAIN_COLORS = {
    "stm32": "#1677FF",
    "rk3588": "#E86F00",
    "shared": "#7C3AED",
    "other": "#475467",
}


def qname(name: str) -> str:
    return f"{{{SVG}}}{name}"


def numbers(text: str) -> list[float]:
    return [float(value) for value in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", text)]


def path_center(path: ET.Element) -> tuple[float, float]:
    values = numbers(path.get("d", ""))
    if len(values) < 2:
        return 0.0, 0.0
    points = list(zip(values[0::2], values[1::2]))
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0


def paths_bounds(paths: list[ET.Element]) -> tuple[float, float, float, float]:
    points: list[tuple[float, float]] = []
    for path in paths:
        values = numbers(path.get("d", ""))
        points.extend(zip(values[0::2], values[1::2]))
    if not points:
        raise ValueError("pad geometry contains no SVG coordinates")
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return min(xs), min(ys), max(xs), max(ys)


def board_component_geometry(
    board_paths: list[Path], designator: str, *, allow_pad_body: bool
) -> tuple[ET.Element, dict[str, tuple[float, float]], float, float, float, float, bool] | None:
    """Extract local assembly and numbered-pad geometry from a PCB SVG."""
    for board_path in board_paths:
        if not board_path or not board_path.exists():
            continue
        root = ET.parse(board_path).getroot()
        pad_group = None
        assembly_group = None
        for element in root.iter(qname("g")):
            if element.get("data-component") != designator:
                continue
            if element.get("id", "").endswith("-pads"):
                pad_group = element
            elif element.get("id", "").endswith("-assembly"):
                assembly_group = element
        if pad_group is None:
            continue
        paths = [path for path in pad_group.iter(qname("path")) if path.get("data-pad-number")]
        if not paths:
            continue
        body_paths = list(assembly_group.iter(qname("path"))) if assembly_group is not None else []
        pads_are_visible_body = not body_paths
        if pads_are_visible_body and not allow_pad_body:
            continue
        min_x, min_y, max_x, max_y = paths_bounds(body_paths + paths)
        margin = 0.35
        view_x, view_y = min_x - margin, min_y - margin
        source_w = max_x - min_x + margin * 2.0
        source_h = max_y - min_y + margin * 2.0
        visible = ET.Element(qname("g"), {"id": "NativeBoardGeometry"})
        pad_centers: dict[str, tuple[float, float]] = {}
        if not pads_are_visible_body:
            for child in assembly_group:
                visible.append(copy.deepcopy(child))
        for path in paths:
            if pads_are_visible_body:
                cloned = copy.deepcopy(path)
                for key in ("id", "data-component", "data-instance", "data-footprint"):
                    cloned.attrib.pop(key, None)
                visible.append(cloned)
            number = str(path.get("data-pad-number"))
            cx, cy = path_center(path)
            pad_centers[number] = (cx - view_x, cy - view_y)
        return visible, pad_centers, view_x, view_y, source_w, source_h, pads_are_visible_body
    return None


def add_text(parent: ET.Element, x: float, y: float, text: str, **attrs: str) -> ET.Element:
    attributes = {
        "x": f"{x:.3f}",
        "y": f"{y:.3f}",
        "font-family": "Aptos, Arial, sans-serif",
        "fill": "#263746",
    }
    attributes.update(attrs)
    node = ET.SubElement(parent, qname("text"), attributes)
    node.text = text
    return node


def add_line(parent: ET.Element, x1: float, y1: float, x2: float, y2: float, color: str) -> None:
    ET.SubElement(
        parent,
        qname("line"),
        {
            "x1": f"{x1:.3f}",
            "y1": f"{y1:.3f}",
            "x2": f"{x2:.3f}",
            "y2": f"{y2:.3f}",
            "stroke": color,
            "stroke-width": "0.35",
            "stroke-linecap": "round",
        },
    )


def rotated_point(x: float, y: float, width: float, height: float, angle: int) -> tuple[float, float]:
    if angle == 90:
        return height - y, x
    if angle == 180:
        return width - x, height - y
    if angle == 270:
        return y, width - x
    return x, y


def rotated_size(width: float, height: float, angle: int) -> tuple[float, float]:
    return (height, width) if angle in (90, 270) else (width, height)


def shape_transform(view_x: float, view_y: float, width: float, height: float, angle: int) -> str:
    normalize = f"translate({-view_x:.6f} {-view_y:.6f})"
    if angle == 90:
        return f"translate({height:.6f} 0) rotate(90) {normalize}"
    if angle == 180:
        return f"translate({width:.6f} {height:.6f}) rotate(180) {normalize}"
    if angle == 270:
        return f"translate(0 {width:.6f}) rotate(270) {normalize}"
    return normalize


def choose_rotation(pad_centers: dict[str, tuple[float, float]], pins: list[dict]) -> int:
    """Put the dominant contact row vertically so leader lines spread cleanly."""
    points = [pad_centers[str(pin["pin"])] for pin in pins if str(pin["pin"]) in pad_centers]
    if len(points) < 2:
        return 0
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    x_span = max(xs) - min(xs)
    y_span = max(ys) - min(ys)
    return 90 if x_span > y_span * 1.08 else 0


def distribute(pins: list[dict], height: float, top: float) -> list[tuple[dict, float]]:
    if not pins:
        return []
    if len(pins) == 1:
        return [(pins[0], top + height / 2)]
    gap = height / (len(pins) - 1)
    return [(pin, top + index * gap) for index, pin in enumerate(pins)]


def generate_one(item: dict, source: Path, output: Path, board_paths: list[Path]) -> None:
    pins = item["pins"]
    domain = str(item.get("processor_domain", "other")).lower()
    color = DOMAIN_COLORS.get(domain, DOMAIN_COLORS["other"])
    domain_label = {"stm32": "STM32", "rk3588": "RK3588", "shared": "STM32 + RK3588"}.get(domain, "BOARD")

    shape: ET.Element | None = None
    pad_centers: dict[str, tuple[float, float]] = {}
    view_x = view_y = 0.0
    source_w = source_h = 0.0
    pads_are_visible_body = False
    native_source = ""

    if source.exists():
        source_root = ET.parse(source).getroot()
        view = numbers(source_root.get("viewBox", ""))
        if len(view) != 4 or view[2] <= 0 or view[3] <= 0:
            raise ValueError(f"{item['designator']}: invalid native component SVG viewBox: {source}")
        view_x, view_y, source_w, source_h = view
        shape = source_root.find(f".//{qname('g')}[@id='Shape']")
        pads = source_root.find(f".//{qname('g')}[@id='Pads']")
        if shape is not None and list(shape):
            native_source = "altium-component-svg"
        if pads is not None:
            for path in pads.findall(f".//{qname('path')}"):
                pad_number = path.get("data-pad-number")
                if not pad_number or pad_number in pad_centers:
                    continue
                cx, cy = path_center(path)
                # Altium component exports wrap pads in scale(1,-1).
                pad_centers[pad_number] = (cx - view_x, -cy - view_y)

    if not native_source:
        allow_pad_body = str(item.get("body_style", "")).lower() in {"solder-bridge", "keystone"}
        board_geometry = board_component_geometry(
            board_paths, str(item["designator"]), allow_pad_body=allow_pad_body
        )
        if board_geometry is None:
            raise ValueError(
                f"{item['designator']}: native connector SVG missing or lacks Shape; "
                "no usable assembly geometry in supplied PCB SVGs"
            )
        shape, pad_centers, view_x, view_y, source_w, source_h, pads_are_visible_body = board_geometry
        native_source = "altium-board-pad-svg" if pads_are_visible_body else "altium-board-assembly-svg"

    missing = [str(pin["pin"]) for pin in pins if str(pin["pin"]) not in pad_centers]
    if missing:
        raise ValueError(f"{item['designator']}: SVG lacks pad metadata for {', '.join(missing)}")

    rotation = choose_rotation(pad_centers, pins)
    rotated_w, rotated_h = rotated_size(source_w, source_h, rotation)
    if rotation:
        pad_centers = {
            number: rotated_point(x, y, source_w, source_h, rotation)
            for number, (x, y) in pad_centers.items()
        }
    body_scale = 2.0
    body_w = max(rotated_w * body_scale, 10.0)
    body_h = max(rotated_h * body_scale, 8.0)
    header_h = 6.0
    label_w = 43.0
    requested_layout = str(item.get("pinout_label_layout", "auto")).lower()
    if requested_layout not in {"auto", "left", "right", "split"}:
        raise ValueError(f"{item['designator']}: invalid pinout_label_layout {requested_layout!r}")
    label_layout = requested_layout
    if label_layout == "auto":
        # Dense dual-row connectors already benefit from two-sided callouts.
        # Single-row connectors are drawn with callouts on the left so their
        # leaders leave the contact face without crossing the connector body.
        label_layout = "split" if len(pins) > 8 else "left"
    use_two_sides = label_layout == "split"
    left_w = label_w if label_layout in {"left", "split"} else 3.0
    right_w = label_w if label_layout in {"right", "split"} else 3.0
    rows_per_side = math.ceil(len(pins) / 2) if use_two_sides else len(pins)
    content_h = max(body_h + 4.0, max(1, rows_per_side) * 3.4 + 1.0)
    route_gap = 6.0
    total_w = left_w + body_w + right_w + route_gap * 2
    total_h = header_h + content_h + 3.0
    body_x = left_w + route_gap
    body_y = header_h + (content_h - body_h) / 2.0

    root = ET.Element(qname("svg"), {
        "version": "1.2", "baseProfile": "tiny", "data-coordinate-units": "mm",
        "data-native-geometry": native_source,
        "width": f"{total_w:.3f}mm", "height": f"{total_h:.3f}mm",
        "viewBox": f"0 0 {total_w:.3f} {total_h:.3f}",
    })
    ET.SubElement(root, qname("rect"), {
        "x": "0", "y": "0", "width": f"{total_w:.3f}", "height": f"{total_h:.3f}",
        "fill": "#FFFFFF",
    })
    add_text(root, 2.0, 4.0, f"{item['designator']} / {domain_label}",
             **{"font-size": "3.0", "font-weight": "700", "fill": color})

    nested = ET.SubElement(root, qname("svg"), {
        "x": f"{body_x:.3f}", "y": f"{body_y:.3f}",
        "width": f"{body_w:.3f}", "height": f"{body_h:.3f}",
        "viewBox": f"0 0 {rotated_w:.6f} {rotated_h:.6f}",
        "overflow": "visible",
    })
    wrapper_attrs = {
        "transform": shape_transform(view_x, view_y, source_w, source_h, rotation),
    }
    if pads_are_visible_body:
        wrapper_attrs.update({
            "fill": "#D7A84D", "stroke": "#1F2937", "stroke-width": "0.10",
            "stroke-linejoin": "round",
        })
    wrapper = ET.SubElement(nested, qname("g"), wrapper_attrs)
    wrapper.append(copy.deepcopy(shape))

    pin_records = []
    for pin in pins:
        local_x, local_y = pad_centers[str(pin["pin"])]
        pin_records.append({
            **pin,
            "anchor_x": body_x + local_x * body_w / rotated_w,
            "anchor_y": body_y + local_y * body_h / rotated_h,
        })

    if use_two_sides:
        center_x = body_x + body_w / 2.0
        left = [pin for pin in pin_records if pin["anchor_x"] <= center_x]
        right = [pin for pin in pin_records if pin["anchor_x"] > center_x]
        if not left or not right or abs(len(left) - len(right)) > max(4, len(pin_records) // 2):
            split = math.ceil(len(pin_records) / 2)
            left, right = pin_records[:split], pin_records[split:]
        left.sort(key=lambda pin: (pin["anchor_y"], pin["anchor_x"], str(pin["pin"])))
        right.sort(key=lambda pin: (pin["anchor_y"], pin["anchor_x"], str(pin["pin"])))
    elif label_layout == "left":
        left = sorted(pin_records, key=lambda pin: (pin["anchor_y"], pin["anchor_x"], str(pin["pin"])))
        right = []
    else:
        left = []
        right = sorted(pin_records, key=lambda pin: (pin["anchor_y"], pin["anchor_x"], str(pin["pin"])))

    label_top = header_h + 2.0
    label_height = content_h - 3.0
    for side, records in (("left", left), ("right", right)):
        for pin, label_y in distribute(records, label_height, label_top):
            ax, ay = pin["anchor_x"], pin["anchor_y"]
            ET.SubElement(root, qname("circle"), {
                "cx": f"{ax:.3f}", "cy": f"{ay:.3f}", "r": "0.42",
                "fill": "#FFFFFF", "stroke": color, "stroke-width": "0.35",
            })
            if side == "right":
                elbow_x = body_x + body_w + 2.0
                text_x = body_x + body_w + 4.0
                add_line(root, ax, ay, elbow_x, label_y, color)
                add_line(root, elbow_x, label_y, text_x - 0.8, label_y, color)
                add_text(root, text_x, label_y + 0.85, f"{pin['pin']}: {pin['net']}",
                         **{"font-size": "2.45", "font-weight": "600"})
            else:
                elbow_x = body_x - 2.0
                text_x = body_x - 4.0
                add_line(root, ax, ay, elbow_x, label_y, color)
                add_line(root, elbow_x, label_y, text_x + 0.8, label_y, color)
                add_text(root, text_x, label_y + 0.85, f"{pin['pin']}: {pin['net']}",
                         **{"font-size": "2.45", "font-weight": "600", "text-anchor": "end"})

    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--board-top-svg", type=Path)
    parser.add_argument("--board-bottom-svg", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.data.read_text(encoding="utf-8-sig"))
    board_paths = [path for path in (args.board_top_svg, args.board_bottom_svg) if path]
    count = 0
    for group in spec["connector_groups"]:
        for item in group["items"]:
            designator = str(item["designator"])
            generate_one(
                item,
                args.source_dir / f"{designator}.svg",
                args.output_dir / f"{designator}.svg",
                board_paths,
            )
            count += 1
    print(f"generated {count} connector SVGs in {args.output_dir.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
