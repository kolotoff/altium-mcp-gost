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

if __package__:
    from .pcb_svg_geometry import assembly_path_vertices, component_transform, parse_numbers
    from .svg_label_text import add_label_ink
else:
    from pcb_svg_geometry import assembly_path_vertices, component_transform, parse_numbers
    from svg_label_text import add_label_ink


SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)

DOMAIN_COLORS = {
    "stm32": "#1677FF",
    "rk3588": "#E86F00",
    "shared": "#7C3AED",
    "other": "#475467",
}

AUTO_SPLIT_BODY_STYLES = {"usb-c", "dip-switch", "tactile-switch", "buzzer"}
PRESERVE_NATIVE_ROTATION_STYLES = {"dip-switch"}


def qname(name: str) -> str:
    return f"{{{SVG}}}{name}"


def path_center(path: ET.Element) -> tuple[float, float]:
    points = assembly_path_vertices(path.get("d", ""))
    if not points:
        raise ValueError("numbered SVG pad has no geometry")
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0


def points_bounds(points) -> tuple[float, float, float, float]:
    points = list(points)
    if not points:
        raise ValueError("pad geometry contains no SVG coordinates")
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return min(xs), min(ys), max(xs), max(ys)


def board_component_geometry(
    board_paths: list[Path], designator: str, *, allow_pad_body: bool,
    instance: str = "", pin_numbers: set[str] | None = None, orthogonal_view: bool = False,
) -> tuple[ET.Element, dict[str, tuple[float, float]], float, float, float, float, bool] | None:
    """Extract local assembly and numbered-pad geometry from a PCB SVG."""
    for board_path in board_paths:
        if not board_path or not board_path.exists():
            continue
        root = ET.parse(board_path).getroot()
        parents = {child: parent for parent in root.iter() for child in parent}
        pad_group = None
        assembly_group = None
        for element in root.iter(qname("g")):
            matches = element.get("data-instance") == instance if instance else element.get("data-component") == designator
            if not matches:
                continue
            if element.get("id", "").endswith("-pads"):
                if pad_group is not None:
                    raise ValueError(f"{designator}: multiple native pad groups; supply the verified native_svg_instance")
                pad_group = element
            elif element.get("id", "").endswith("-assembly"):
                assembly_group = element
        if pad_group is None:
            continue
        paths = [path for path in pad_group.iter(qname("path")) if path.get("data-pad-number")]
        if pin_numbers is not None:
            paths = [path for path in paths if path.get("data-pad-number") in pin_numbers]
        if not paths:
            continue
        body_paths = list(assembly_group.iter(qname("path"))) if assembly_group is not None else []
        pads_are_visible_body = not body_paths
        if pads_are_visible_body and not allow_pad_body:
            continue
        placement = []
        element = pad_group
        while element is not root:
            transform = element.get("transform")
            if transform:
                placement.append(transform)
            element = parents[element]
        view = "installed"
        component = component_transform(pad_group)
        if orthogonal_view and component is not None:
            angle = math.degrees(math.atan2(component.sine, component.cosine))
            if abs(angle - round(angle / 90) * 90) > 1.0:
                # Use the native footprint frame on the installed side when
                # the board placement is oblique and obscures the contact rows.
                placement[0] = f"translate(0 0) scale({component.scale_x} {component.scale_y})"
                view = "footprint"
        transforms = [
            component_transform(ET.Element("g", {"transform":
                f"translate(0 0) {transform}" if transform.startswith("scale(") else transform}))
            for transform in placement
        ]
        if any(transform is None for transform in transforms):
            raise ValueError(f"{designator}: unsupported native placement: {placement}")

        def installed_point(x: float, y: float) -> tuple[float, float]:
            for transform in transforms:
                x, y = transform.to_board(x, y)
            return x, y

        min_x, min_y, max_x, max_y = points_bounds(
            installed_point(x, y) for path in body_paths + paths
            for x, y in assembly_path_vertices(path.get("d", ""))
        )
        margin = 0.35
        view_x, view_y = min_x - margin, min_y - margin
        source_w = max_x - min_x + margin * 2.0
        source_h = max_y - min_y + margin * 2.0
        visible = ET.Element(qname("g"), {
            "id": "NativeBoardGeometry",
            "transform": " ".join(reversed(placement)),
            "data-native-view": view,
        })
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
            cx, cy = installed_point(*path_center(path))
            pad_centers.setdefault(number, (cx - view_x, cy - view_y))
        return visible, pad_centers, view_x, view_y, source_w, source_h, pads_are_visible_body
    return None


def add_text(parent: ET.Element, x: float, y: float, text: str, **attrs: str) -> ET.Element:
    attributes = {
        "x": f"{x:.3f}",
        "y": f"{y:.3f}",
        "font-family": "Arial",
        "fill": "#263746",
    }
    attributes.update(attrs)
    node = ET.SubElement(parent, qname("text"), attributes)
    node.text = text
    return node


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


def choose_rotation(
    pad_centers: dict[str, tuple[float, float]], pins: list[dict], *, body_style: str = ""
) -> int:
    """Put the dominant contact row vertically so leader lines spread cleanly."""
    if body_style in PRESERVE_NATIVE_ROTATION_STYLES:
        return 0
    points = [pad_centers[str(pin["pin"])] for pin in pins if str(pin["pin"]) in pad_centers]
    if len(points) < 2:
        return 0
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    x_span = max(xs) - min(xs)
    y_span = max(ys) - min(ys)
    return 90 if x_span > y_span * 1.08 else 0


def split_physical_columns(
    pin_records: list[dict], body_w: float
) -> tuple[list[dict], list[dict]] | None:
    """Split callouts by the nearest physical contact column.

    USB-C A/B rows are kept intact, then assigned to the left or right by the
    rendered row position. Other dual-column parts use the largest physical
    x-gap. This prevents the sequence fallback from routing each label column
    to the farther contact row and producing X-crossings.
    """
    if len(pin_records) < 2:
        return None

    a_rows = [pin for pin in pin_records if re.fullmatch(r"A\d+", str(pin["pin"]), re.I)]
    b_rows = [pin for pin in pin_records if re.fullmatch(r"B\d+", str(pin["pin"]), re.I)]
    if a_rows and b_rows and len(a_rows) + len(b_rows) == len(pin_records):
        a_x = sum(pin["anchor_x"] for pin in a_rows) / len(a_rows)
        b_x = sum(pin["anchor_x"] for pin in b_rows) / len(b_rows)
        return (a_rows, b_rows) if a_x <= b_x else (b_rows, a_rows)

    ordered = sorted(pin_records, key=lambda pin: pin["anchor_x"])
    gaps = [
        (ordered[index + 1]["anchor_x"] - ordered[index]["anchor_x"], index)
        for index in range(len(ordered) - 1)
    ]
    gap, index = max(gaps, default=(0.0, -1))
    if index < 0 or gap < max(0.12, body_w * 0.04):
        return None
    left = ordered[: index + 1]
    right = ordered[index + 1 :]
    left_y = [pin["anchor_y"] for pin in left]
    right_y = [pin["anchor_y"] for pin in right]
    if len(pin_records) > 2 and (max(left_y) + gap < min(right_y) or max(right_y) + gap < min(left_y)):
        return None
    return left, right


def distribute(pins: list[dict], top: float, bottom: float, pitch: float) -> list[tuple[dict, float]]:
    """Keep labels near their pads and spread crowded rows in both directions."""
    # Subtract the required pitch so that spacing becomes a nondecreasing
    # sequence. Average neighboring blocks that would violate that order.
    blocks: list[tuple[float, int]] = []
    for index, pin in enumerate(pins):
        total, count = pin["anchor_y"] - index * pitch, 1
        while blocks and blocks[-1][0] / blocks[-1][1] > total / count:
            previous, size = blocks.pop()
            total += previous
            count += size
        blocks.append((total, count))

    latest_start = bottom - (len(pins) - 1) * pitch
    positions: list[float] = []
    for total, count in blocks:
        start = min(latest_start, max(top, total / count))
        for _ in range(count):
            positions.append(start + len(positions) * pitch)
    return list(zip(pins, positions))


def pin_label(pin: dict) -> str:
    return f"{pin['pin']}: {pin['net']}"


def generate_one(item: dict, source: Path, output: Path, board_paths: list[Path]) -> None:
    pins = item["pins"]
    body_style = str(item.get("body_style", "")).lower()
    domain = str(item.get("processor_domain", "other")).lower()
    color = DOMAIN_COLORS.get(domain, DOMAIN_COLORS["other"])
    domain_label = {"stm32": "STM32", "rk3588": "RK3588", "shared": "STM32 + RK3588"}.get(domain, "BOARD")

    shape: ET.Element | None = None
    pad_centers: dict[str, tuple[float, float]] = {}
    view_x = view_y = 0.0
    source_w = source_h = 0.0
    pads_are_visible_body = False
    native_source = ""

    pin_numbers = {str(pin["pin"]) for pin in pins}
    geometry_options = {
        "instance": str(item.get("native_svg_instance", "")), "pin_numbers": pin_numbers,
        "orthogonal_view": body_style == "board-to-board",
    }
    board_geometry = board_component_geometry(
        board_paths, str(item["designator"]), allow_pad_body=False, **geometry_options,
    )
    source_root = ET.parse(source).getroot() if board_geometry is None and source.exists() else None
    component_shape = None if source_root is None else source_root.find(f".//{qname('g')}[@id='Shape']")
    if board_geometry is None and (component_shape is None or not len(component_shape)):
        board_geometry = board_component_geometry(
            board_paths, str(item["designator"]), allow_pad_body=True, **geometry_options,
        )
    if board_geometry is not None:
        shape, pad_centers, view_x, view_y, source_w, source_h, pads_are_visible_body = board_geometry
        native_source = "altium-board-pad-svg" if pads_are_visible_body else "altium-board-assembly-svg"
    elif source_root is not None:
        view = parse_numbers(source_root.get("viewBox", ""))
        if len(view) != 4 or view[2] <= 0 or view[3] <= 0:
            raise ValueError(f"{item['designator']}: invalid native component SVG viewBox: {source}")
        view_x, view_y, source_w, source_h = view
        shape = component_shape
        pads = source_root.find(f".//{qname('g')}[@id='Pads']")
        if shape is not None and list(shape):
            native_source = "altium-component-svg"
        if pads is not None:
            pad_paths = [path for path in pads.iter(qname("path")) if path.get("data-pad-number") in pin_numbers]
            if not native_source and pad_paths:
                shape = ET.Element(qname("g"), {"transform": pads.get("transform", "scale(1,-1)")})
                shape.extend(copy.deepcopy(path) for path in pad_paths)
                native_source = "altium-component-pad-svg"
                pads_are_visible_body = True
            for path in pad_paths:
                pad_number = path.get("data-pad-number")
                if not pad_number or pad_number in pad_centers:
                    continue
                cx, cy = path_center(path)
                # Altium component exports wrap pads in scale(1,-1).
                pad_centers[pad_number] = (cx - view_x, -cy - view_y)

    if not native_source:
        raise ValueError(
            f"{item['designator']}: native connector SVG missing or lacks Shape; "
            "no usable assembly or numbered-pad geometry in supplied SVGs"
        )

    missing = [str(pin["pin"]) for pin in pins if str(pin["pin"]) not in pad_centers]
    if missing:
        raise ValueError(f"{item['designator']}: SVG lacks pad metadata for {', '.join(missing)}")

    rotation_value = item.get("pinout_rotation")
    if rotation_value is None:
        rotation = choose_rotation(pad_centers, pins, body_style=body_style)
    else:
        try:
            rotation = int(rotation_value) % 360
        except (TypeError, ValueError) as exc:
            raise ValueError(
                f"{item['designator']}: invalid pinout_rotation {rotation_value!r}"
            ) from exc
        if rotation not in {0, 90, 180, 270}:
            raise ValueError(
                f"{item['designator']}: pinout_rotation must be 0, 90, 180, or 270"
            )
    rotated_w, rotated_h = rotated_size(source_w, source_h, rotation)
    if rotation:
        pad_centers = {
            number: rotated_point(x, y, source_w, source_h, rotation)
            for number, (x, y) in pad_centers.items()
        }
    pin_records = [
        {**pin, "anchor_x": pad_centers[str(pin["pin"])][0], "anchor_y": pad_centers[str(pin["pin"])][1]}
        for pin in pins
    ]
    physical_columns = split_physical_columns(pin_records, rotated_w)
    requested_layout = str(item.get("pinout_label_layout", "auto")).lower()
    if requested_layout not in {"auto", "left", "right", "split"}:
        raise ValueError(f"{item['designator']}: invalid pinout_label_layout {requested_layout!r}")
    label_layout = requested_layout
    if label_layout == "auto":
        if physical_columns or body_style in AUTO_SPLIT_BODY_STYLES:
            label_layout = "split"
        else:
            mean_x = sum(pin["anchor_x"] for pin in pin_records) / len(pin_records)
            label_layout = "left" if mean_x <= rotated_w / 2 else "right"
    if label_layout == "split":
        if physical_columns is None:
            ordered = sorted(pin_records, key=lambda pin: (pin["anchor_x"], pin["anchor_y"]))
            split = (len(ordered) + 1) // 2
            physical_columns = ordered[:split], ordered[split:]
        left, right = physical_columns
        if item.get("pinout_split_swap"):
            left, right = right, left
    else:
        left, right = (pin_records, []) if label_layout == "left" else ([], pin_records)
    for records in (left, right):
        records.sort(key=lambda pin: (pin["anchor_y"], pin["anchor_x"], str(pin["pin"])))

    header_h = 5.5
    font_size = 2.55
    label_pitch = 2.95
    content_h = max(24.0, (max(len(left), len(right)) - 1) * label_pitch + 6.0)
    body_scale = min((content_h - 2.0) / rotated_h, 48.0 / rotated_w)
    body_w = rotated_w * body_scale
    body_h = rotated_h * body_scale

    def label_width(records: list[dict]) -> float:
        # Reserve enough room even when the net uses wide capital letters.
        characters = max((len(pin_label(pin)) for pin in records), default=0)
        return characters * font_size * 0.76 + 3.8 if records else 2.0

    route_gap = 4.7
    left_w = label_width(left) + (route_gap if left else 0.0)
    right_w = label_width(right) + (route_gap if right else 0.0)
    artwork_w = left_w + body_w + right_w
    total_w = max(artwork_w, 35.0)
    total_h = header_h + content_h + 3.0
    body_x = left_w + (total_w - artwork_w) / 2
    body_y = header_h + (content_h - body_h) / 2.0

    view_kind = shape.get("data-native-view", "installed") + "-side" if board_geometry else "component-export"
    root = ET.Element(qname("svg"), {
        "version": "1.2", "baseProfile": "tiny", "data-coordinate-units": "mm",
        "data-native-geometry": native_source, "data-pinout-rotation": str(rotation),
        "data-pinout-view": view_kind,
        "width": f"{total_w:.3f}mm", "height": f"{total_h:.3f}mm",
        "viewBox": f"0 0 {total_w:.3f} {total_h:.3f}",
    })
    ET.SubElement(root, qname("rect"), {
        "x": "0", "y": "0", "width": f"{total_w:.3f}", "height": f"{total_h:.3f}",
        "fill": "#FFFFFF",
    })
    add_text(root, total_w / 2, 3.6, f"{item['designator']} / {domain_label}",
             **{"font-size": "2.9", "font-weight": "700", "text-anchor": "middle", "fill": color})

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

    for pin in pin_records:
        pin["anchor_x"] = body_x + pin["anchor_x"] * body_scale
        pin["anchor_y"] = body_y + pin["anchor_y"] * body_scale

    for side, records in (("left", left), ("right", right)):
        direction = 1 if side == "right" else -1
        edge_x = body_x + body_w if side == "right" else body_x
        text_x = edge_x + direction * route_gap
        for pin, label_y in distribute(records, header_h + 2.5, header_h + content_h - 2.5, label_pitch):
            ax, ay = pin["anchor_x"], pin["anchor_y"]
            callout = ET.SubElement(root, qname("g"), {
                "data-pinout-pad": str(pin["pin"]), "data-label-side": side,
            })
            for field in ("mcu_pin", "mcu_peripheral", "mcu_signal", "ardupilot_port"):
                if pin.get(field):
                    callout.set(f"data-{field.replace('_', '-')}", str(pin[field]))
            ET.SubElement(callout, qname("polyline"), {
                "points": f"{ax:.3f},{ay:.3f} {edge_x:.3f},{ay:.3f} "
                          f"{text_x - direction * 2.25:.3f},{label_y:.3f} "
                          f"{text_x - direction * 0.55:.3f},{label_y:.3f}",
                "fill": "none", "stroke": color, "stroke-width": "0.24",
                "stroke-linejoin": "round",
            })
            ET.SubElement(callout, qname("circle"), {
                "cx": f"{ax:.3f}", "cy": f"{ay:.3f}", "r": "0.31",
                "fill": "#FFFFFF", "stroke": color, "stroke-width": "0.24",
            })
            add_label_ink(callout, pin_label(pin), text_x, label_y, size=font_size,
                          fill="#263746", anchor="start" if side == "right" else "end",
                          center_capitals=True)

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
