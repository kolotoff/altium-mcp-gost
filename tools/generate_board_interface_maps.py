"""Generate millimetre-scale annotated PCB assembly SVG pages.

The board is kept at 1:1 scale inside an A4-landscape content area.  Connector
labels are placed outside the nearest board edge and color-coded by processor
domain.  Perimeter connectors are assigned first; internal items then use the
remaining collision-free perimeter slots.  Copper pads are removed from the
visible assembly artwork.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)

COLORS = {
    "stm32": "#1677FF",
    "rk3588": "#E86F00",
    "shared": "#7C3AED",
    "other": "#475467",
}


def qname(name: str) -> str:
    return f"{{{SVG}}}{name}"


def parse_numbers(text: str) -> list[float]:
    return [float(value) for value in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", text)]


def remove_pads(element: ET.Element) -> None:
    """Hide copper pad bodies while retaining BoardShape mounting-hole circles."""
    for child in list(element):
        if child.get("id") == "Pads" or child.get("data-layer") == "pads":
            element.remove(child)
        else:
            remove_pads(child)


def component_positions(
    root: ET.Element,
    *,
    bottom: bool,
    view_x: float,
    view_y: float,
    view_width: float,
) -> dict[str, tuple[float, float]]:
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
                # Bottom assembly exports are mirrored around the board-view
                # centre. Derive that axis from the SVG rather than assuming a
                # board-specific coordinate system.
                x = 2.0 * view_x + view_width - x
            positions[designator] = (x - view_x, -y - view_y)
    return positions


def text(parent: ET.Element, x: float, y: float, value: str, **attrs: str) -> ET.Element:
    settings = {
        "x": f"{x:.3f}", "y": f"{y:.3f}",
        "font-family": "Aptos, Arial, sans-serif", "fill": "#263746",
    }
    settings.update(attrs)
    node = ET.SubElement(parent, qname("text"), settings)
    node.text = value
    return node


def line(parent: ET.Element, x1: float, y1: float, x2: float, y2: float, color: str, width: float = 0.32) -> None:
    ET.SubElement(parent, qname("line"), {
        "x1": f"{x1:.3f}", "y1": f"{y1:.3f}", "x2": f"{x2:.3f}", "y2": f"{y2:.3f}",
        "stroke": color, "stroke-width": f"{width:.3f}", "stroke-linecap": "round",
    })


def label_width(value: str) -> float:
    return max(12.0, min(28.0, 4.0 + len(value) * 0.88))


def boxes_overlap(a: tuple[float, float, float, float], b: tuple[float, float, float, float], pad: float = 0.75) -> bool:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return not (
        ax + aw + pad <= bx
        or bx + bw + pad <= ax
        or ay + ah + pad <= by
        or by + bh + pad <= ay
    )


def _orientation(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def segments_intersect(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
    d: tuple[float, float],
) -> bool:
    return _orientation(a, b, c) * _orientation(a, b, d) < -1e-7 and _orientation(c, d, a) * _orientation(c, d, b) < -1e-7


def polyline_segments(points: list[tuple[float, float]]) -> list[tuple[tuple[float, float], tuple[float, float]]]:
    return list(zip(points, points[1:]))


def segment_intersects_box(
    segment: tuple[tuple[float, float], tuple[float, float]],
    box: tuple[float, float, float, float],
) -> bool:
    (x1, y1), (x2, y2) = segment
    x, y, width, height = box
    if x < x1 < x + width and y < y1 < y + height:
        return True
    if x < x2 < x + width and y < y2 < y + height:
        return True
    corners = [(x, y), (x + width, y), (x + width, y + height), (x, y + height)]
    return any(segments_intersect((x1, y1), (x2, y2), corners[index], corners[(index + 1) % 4]) for index in range(4))


def spread_centers(
    records: list[dict],
    axis: str,
    minimum: float,
    maximum: float,
    spacing: float = 5.2,
    *,
    tie_axis: str | None = None,
    reverse_tie: bool = False,
) -> None:
    """Keep labels close to their anchors while preserving physical order."""
    if not records:
        return
    ordered = sorted(
        records,
        key=lambda record: (
            round(record[axis], 2),
            (-record[tie_axis] if reverse_tie else record[tie_axis]) if tie_axis else 0.0,
        ),
    )
    values: list[float] = []
    cursor = minimum
    for record in ordered:
        value = max(cursor, min(maximum, record[axis]))
        values.append(value)
        cursor = value + spacing
    overflow = max(0.0, values[-1] - maximum)
    if overflow:
        values = [value - overflow for value in values]
    for index in range(len(values) - 2, -1, -1):
        values[index] = min(values[index], values[index + 1] - spacing)
    underflow = max(0.0, minimum - values[0])
    if underflow:
        values = [value + underflow for value in values]
    if values[-1] > maximum + 1e-6:
        raise ValueError(f"too many labels for {minimum:.1f}..{maximum:.1f} mm perimeter span")
    for record, value in zip(ordered, values):
        record["slot_center"] = value


def place_edge_centers_preserving_priority(
    records: list[dict],
    axis: str,
    minimum: float,
    maximum: float,
    *,
    tie_axis: str | None = None,
    reverse_tie: bool = False,
    spacing: float = 5.2,
) -> None:
    """Pin outline-adjacent labels to their anchors; fit lower-priority labels around them."""
    ordered = sorted(
        records,
        key=lambda record: (
            round(record[axis], 2),
            (-record[tie_axis] if reverse_tie else record[tie_axis]) if tie_axis else 0.0,
        ),
    )
    occupied: list[float] = []
    for record in [item for item in ordered if item["priority"]]:
        center = max(minimum, min(maximum, record[axis]))
        if any(abs(center - value) < spacing - 1e-6 for value in occupied):
            raise ValueError(f"high-priority labels collide at {record['label']}")
        record["slot_center"] = center
        occupied.append(center)

    step = 0.4
    for record in [item for item in ordered if not item["priority"]]:
        preferred = max(minimum, min(maximum, record[axis]))
        count = int((maximum - minimum) / step) + 2
        negative_offsets = [-index * step for index in range(1, count)]
        positive_offsets = [index * step for index in range(1, count)]
        if record.get("bias") == "left":
            offsets = [0.0, *negative_offsets, *positive_offsets]
        elif record.get("bias") == "right":
            offsets = [0.0, *positive_offsets, *negative_offsets]
        else:
            offsets = [0.0]
            for negative, positive in zip(negative_offsets, positive_offsets):
                offsets.extend((negative, positive))
        center = next(
            (
                preferred + offset
                for offset in offsets
                if minimum <= preferred + offset <= maximum
                and all(abs(preferred + offset - value) >= spacing - 1e-6 for value in occupied)
            ),
            None,
        )
        if center is None:
            raise ValueError(f"no perimeter slot remains for {record['label']}")
        record["slot_center"] = center
        occupied.append(center)


def assign_perimeter_edges(records: list[dict], board_box: tuple[float, float, float, float]) -> None:
    """Assign perimeter connectors first, then place internal items outside too."""
    bx, by, bw, bh = board_box
    capacities = {
        "top": int((bw - 5.2) // 5.2) + 1,
        "bottom": int((bw - 5.2) // 5.2) + 1,
        "left": int((bh - 5.2) // 5.2) + 1,
        "right": int((bh - 5.2) // 5.2) + 1,
    }
    used = {edge: 0 for edge in capacities}
    for record in records:
        ax, ay = record["anchor_x"], record["anchor_y"]
        distances = {
            "left": ax - bx,
            "right": bx + bw - ax,
            "top": ay - by,
            "bottom": by + bh - ay,
        }
        record["edge_distances"] = distances
        # Components within 6 mm of the outline own their projected perimeter
        # position. Lower-priority internal items must move around these labels.
        record["priority"] = min(distances.values()) <= 6.0

    ordered = sorted(
        records,
        key=lambda record: (
            0 if record["priority"] else 1,
            min(record["edge_distances"].values()),
        ),
    )
    for record in ordered:
        choices = sorted(record["edge_distances"], key=record["edge_distances"].get)
        record["edge_choices"] = choices
        edge_lock = record.get("edge_lock")
        if edge_lock in capacities:
            edge = edge_lock
        else:
            start = min(int(record.get("edge_attempt", 0)), len(choices) - 1)
            rotated_choices = choices[start:] + choices[:start]
            edge = next((candidate for candidate in rotated_choices if used[candidate] < capacities[candidate]), rotated_choices[0])
        record["edge"] = edge
        used[edge] += 1


def arrange_perimeter_labels(records: list[dict], board_box: tuple[float, float, float, float]) -> None:
    """Place all labels outside the board; top/bottom labels are vertical."""
    bx, by, bw, bh = board_box
    gap = 2.2
    height = 4.2
    for record in records:
        record["edge_attempt"] = 0

    for _attempt in range(80):
        assign_perimeter_edges(records, board_box)
        placement_failed = False
        for edge in ("top", "bottom", "left", "right"):
            edge_records = [record for record in records if record["edge"] == edge]
            try:
                if edge in ("top", "bottom"):
                    place_edge_centers_preserving_priority(
                        edge_records,
                        "anchor_x",
                        bx + height / 2.0,
                        bx + bw - height / 2.0,
                        tie_axis="anchor_y",
                        reverse_tie=edge == "bottom",
                    )
                else:
                    place_edge_centers_preserving_priority(
                        edge_records,
                        "anchor_y",
                        by + height / 2.0,
                        by + bh - height / 2.0,
                        tie_axis="anchor_x",
                        reverse_tie=edge == "right",
                    )
            except ValueError:
                movable = [
                    record for record in edge_records
                    if not record["priority"] and not record.get("edge_lock")
                    and int(record.get("edge_attempt", 0)) < 3
                ]
                if not movable:
                    raise
                victim = max(movable, key=lambda record: record["edge_distances"][edge])
                victim["edge_attempt"] = int(victim.get("edge_attempt", 0)) + 1
                placement_failed = True
                break

            if edge in ("top", "bottom"):
                for record in edge_records:
                    width = label_width(record["label"])
                    cx = record["slot_center"]
                    if edge == "top":
                        cy = by - gap - width / 2.0
                        endpoint = (cx, by - gap)
                        angle = -90
                    else:
                        cy = by + bh + gap + width / 2.0
                        endpoint = (cx, by + bh + gap)
                        angle = 90
                    record.update(label_cx=cx, label_cy=cy, label_w=width, label_angle=angle)
                    record["label_box"] = (cx - height / 2.0, cy - width / 2.0, height, width)
                    record["leader"] = [(record["anchor_x"], record["anchor_y"]), endpoint]
            else:
                for record in edge_records:
                    width = label_width(record["label"])
                    cy = record["slot_center"]
                    if edge == "left":
                        x = bx - gap - width
                        endpoint = (bx - gap, cy)
                    else:
                        x = bx + bw + gap
                        endpoint = (bx + bw + gap, cy)
                    y = cy - height / 2.0
                    record.update(label_x=x, label_y=y, label_w=width)
                    record["label_box"] = (x, y, width, height)
                    record["leader"] = [(record["anchor_x"], record["anchor_y"]), endpoint]

        if placement_failed:
            continue

        conflict: tuple[str, dict, dict] | None = None
        for index, record in enumerate(records):
            leader_segment = polyline_segments(record["leader"])[0]
            for other in records[index + 1:]:
                if boxes_overlap(record["label_box"], other["label_box"], pad=0.45):
                    conflict = ("label overlap", record, other)
                    break
                other_segment = polyline_segments(other["leader"])[0]
                if segments_intersect(leader_segment[0], leader_segment[1], other_segment[0], other_segment[1]):
                    conflict = ("leader crossing", record, other)
                    break
            if conflict:
                break
            for other in records:
                if other is record:
                    continue
                if segment_intersects_box(leader_segment, other["label_box"]):
                    conflict = ("leader through label", record, other)
                    break
            if conflict:
                break
        if conflict is None:
            return

        reason, first, second = conflict
        movable = [
            record for record in (first, second)
            if not record["priority"] and not record.get("edge_lock")
            and int(record.get("edge_attempt", 0)) < 3
        ]
        if not movable:
            raise ValueError(f"{reason}: {first['label']} / {second['label']}")
        victim = max(movable, key=lambda record: record["edge_distances"][record["edge"]])
        victim["edge_attempt"] = int(victim.get("edge_attempt", 0)) + 1

    raise ValueError("could not place top-side labels without intersections")


def render_perimeter_label(root: ET.Element, record: dict) -> None:
    """Render one outside label with a single angled leader."""
    color = COLORS.get(record["domain"], COLORS["other"])
    height = 4.2
    start, end = record["leader"]
    line(root, start[0], start[1], end[0], end[1], color)
    if record["edge"] in ("top", "bottom"):
        width = record["label_w"]
        cx, cy = record["label_cx"], record["label_cy"]
        group = ET.SubElement(root, qname("g"), {
            "transform": f"rotate({record['label_angle']} {cx:.3f} {cy:.3f})",
        })
        x, y = cx - width / 2.0, cy - height / 2.0
        ET.SubElement(group, qname("rect"), {
            "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
            "rx": "1.0", "fill": color,
        })
        text(group, cx, cy + 0.72, record["label"],
             **{"font-size": "1.78", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})
    else:
        x, y, width = record["label_x"], record["label_y"], record["label_w"]
        ET.SubElement(root, qname("rect"), {
            "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
            "rx": "1.0", "fill": color,
        })
        text(root, x + width / 2.0, y + 2.82, record["label"],
             **{"font-size": "1.78", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})
    ET.SubElement(root, qname("circle"), {
        "cx": f"{record['anchor_x']:.3f}", "cy": f"{record['anchor_y']:.3f}", "r": "0.58",
        "fill": "#FFFFFF", "stroke": color, "stroke-width": "0.45",
    })


def arrange_local_labels(
    records: list[dict],
    board_box: tuple[float, float, float, float],
    all_records: list[dict],
    perimeter_records: list[dict],
) -> None:
    """Place local callouts as one collision-free set with short direct leaders."""
    bx, by, bw, bh = board_box
    height = 4.2
    component_gap = 1.5
    fixed_boxes = [record["label_box"] for record in perimeter_records]
    fixed_leaders = [record["leader"] for record in perimeter_records]
    offsets = [0.0]
    for step in range(1, 18):
        offsets.extend((-1.5 * step, 1.5 * step))

    def component_box(item: dict, margin: float = 0.0) -> tuple[float, float, float, float]:
        width = max(float(item.get("component_w", 0.0)), 2.0)
        item_height = max(float(item.get("component_h", 0.0)), 2.0)
        return (
            item["anchor_x"] - width / 2.0 - margin,
            item["anchor_y"] - item_height / 2.0 - margin,
            width + margin * 2.0,
            item_height + margin * 2.0,
        )

    component_boxes = [(item, component_box(item, margin=0.6)) for item in all_records]

    def candidate_conflicts(
        box: tuple[float, float, float, float],
        leader: list[tuple[float, float]],
        boxes: list[tuple[float, float, float, float]],
        leaders: list[list[tuple[float, float]]],
    ) -> bool:
        if any(boxes_overlap(box, other, pad=0.7) for other in boxes):
            return True
        segments = polyline_segments(leader)
        if any(segment_intersects_box(segment, other) for segment in segments for other in boxes):
            return True
        if any(
            segment_intersects_box(old_segment, box)
            for old_leader in leaders
            for old_segment in polyline_segments(old_leader)
        ):
            return True
        return any(
            segments_intersect(segment[0], segment[1], old_segment[0], old_segment[1])
            for segment in segments
            for old_leader in leaders
            for old_segment in polyline_segments(old_leader)
        )

    candidate_sets: list[
        tuple[dict, list[tuple[tuple[float, float, float, float], list[tuple[float, float]]]]]
    ] = []
    for record in records:
        ax, ay = record["anchor_x"], record["anchor_y"]
        width = label_width(record["label"])
        bias = record.get("bias")
        if bias in {"left", "right", "top", "bottom"}:
            # An explicit side is a hard layout requirement. Search along that
            # side only; do not silently move the label to another quadrant.
            direction_order = (bias,)
        else:
            direction_order = ("left", "right", "top", "bottom")
        owner_box = component_box(record)
        owner_x, owner_y, owner_w, owner_h = owner_box
        candidates: list[
            tuple[tuple[float, float, float, float], list[tuple[float, float]]]
        ] = []
        for direction in direction_order:
            for offset in offsets:
                if direction == "left":
                    x, y = owner_x - component_gap - width, ay - height / 2.0 + offset
                    endpoint = (x + width, max(y, min(y + height, ay)))
                elif direction == "right":
                    x, y = owner_x + owner_w + component_gap, ay - height / 2.0 + offset
                    endpoint = (x, max(y, min(y + height, ay)))
                elif direction == "top":
                    x, y = ax - width / 2.0 + offset, owner_y - component_gap - height
                    endpoint = (max(x, min(x + width, ax)), y + height)
                else:
                    x, y = ax - width / 2.0 + offset, owner_y + owner_h + component_gap
                    endpoint = (max(x, min(x + width, ax)), y)
                box = (x, y, width, height)
                if x < bx + 1.0 or x + width > bx + bw - 1.0 or y < by + 1.0 or y + height > by + bh - 1.0:
                    continue
                # Treat every labeled component body, including the owner, as
                # a real obstacle rather than approximating it by its anchor.
                if any(boxes_overlap(box, other_box, pad=0.35) for _item, other_box in component_boxes):
                    continue
                leader = [(ax, ay), endpoint]
                if candidate_conflicts(box, leader, fixed_boxes, fixed_leaders):
                    continue
                candidates.append((box, leader))
        if not candidates:
            raise ValueError(f"no legal local-label position for {record['label']}")
        candidate_sets.append((record, candidates))

    # Search the most constrained labels first. This keeps an early, locally
    # valid choice from consuming the only legal pocket for another connector.
    candidate_sets.sort(key=lambda pair: (len(pair[1]), pair[0]["anchor_y"], pair[0]["anchor_x"]))
    selected_by_id: dict[
        int, tuple[tuple[float, float, float, float], list[tuple[float, float]]]
    ] = {}

    def solve(
        index: int,
        boxes: list[tuple[float, float, float, float]],
        leaders: list[list[tuple[float, float]]],
    ) -> bool:
        if index == len(candidate_sets):
            return True
        record, candidates = candidate_sets[index]
        for box, leader in candidates:
            if candidate_conflicts(box, leader, boxes, leaders):
                continue
            selected_by_id[id(record)] = (box, leader)
            if solve(index + 1, boxes + [box], leaders + [leader]):
                return True
            selected_by_id.pop(id(record), None)
        return False

    if not solve(0, fixed_boxes, fixed_leaders):
        raise ValueError("could not place local labels without overlaps or line intersections")
    for record in records:
        box, leader = selected_by_id[id(record)]
        record.update(label_x=box[0], label_y=box[1], label_w=box[2], label_box=box, leader=leader)


def render_local_label(root: ET.Element, record: dict) -> None:
    color = COLORS.get(record["domain"], COLORS["other"])
    height = 4.2
    start, end = record["leader"]
    line(root, start[0], start[1], end[0], end[1], color)
    x, y, width = record["label_x"], record["label_y"], record["label_w"]
    ET.SubElement(root, qname("rect"), {
        "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
        "rx": "1.0", "fill": color,
    })
    text(root, x + width / 2.0, y + 2.82, record["label"],
         **{"font-size": "1.72", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})
    ET.SubElement(root, qname("circle"), {
        "cx": f"{record['anchor_x']:.3f}", "cy": f"{record['anchor_y']:.3f}", "r": "0.58",
        "fill": "#FFFFFF", "stroke": color, "stroke-width": "0.45",
    })


def arrange_local_left(records: list[dict], page_width: float, page_height: float) -> None:
    """Place compact top-side labels left of their connector without crossings."""
    height = 4.0
    placed_boxes: list[tuple[float, float, float, float]] = []
    placed_leaders: list[list[tuple[float, float]]] = []
    all_anchors = [(record["anchor_x"], record["anchor_y"]) for record in records]
    y_offsets = [0.0]
    for step in range(1, 13):
        y_offsets.extend((-4.7 * step, 4.7 * step))
    x_extras = [0.0, 4.5, 9.0, 14.0, 20.0, 27.0, 35.0, 44.0]
    candidates = sorted(
        ((extra, dy) for extra in x_extras for dy in y_offsets),
        key=lambda value: value[0] * 0.7 + abs(value[1]),
    )
    ordered = sorted(records, key=lambda record: (record["anchor_y"], -record["anchor_x"]))
    for record in ordered:
        ax, ay = record["anchor_x"], record["anchor_y"]
        width = label_width(record["label"])
        selected = None
        for extra, dy in candidates:
            x = ax - width - 2.0 - extra
            y = ay - height / 2.0 + dy
            box = (x, y, width, height)
            if x < 1.5 or x + width > page_width - 1.5 or y < 11.5 or y + height > page_height - 5.0:
                continue
            if any(boxes_overlap(box, other) for other in placed_boxes):
                continue
            if any(x - 0.6 <= px <= x + width + 0.6 and y - 0.6 <= py <= y + height + 0.6 for px, py in all_anchors if (px, py) != (ax, ay)):
                continue
            cy = y + height / 2.0
            corridor_x = x + width + 0.9
            leader = [(ax, ay), (corridor_x, ay), (corridor_x, cy), (x + width, cy)]
            leader_segments = polyline_segments(leader)
            if any(
                segments_intersect(segment[0], segment[1], previous[0], previous[1])
                for segment in leader_segments
                for old_leader in placed_leaders
                for previous in polyline_segments(old_leader)
            ):
                continue
            if any(segment_intersects_box(segment, old_box) for segment in leader_segments for old_box in placed_boxes):
                continue
            if any(segment_intersects_box(segment, box) for old_leader in placed_leaders for segment in polyline_segments(old_leader)):
                continue
            selected = (box, leader)
            break
        if selected is None:
            raise ValueError(f"could not place non-overlapping top-side label {record['label']}")
        box, leader = selected
        record.update(label_x=box[0], label_y=box[1], label_w=box[2], leader=leader)
        placed_boxes.append(box)
        placed_leaders.append(leader)


def arrange_horizontal_edge(records: list[dict], edge: str, board_box: tuple[float, float, float, float], page_width: float) -> None:
    """Place bottom-side connector labels horizontally above or below the PCB."""
    if not records:
        return
    bx, by, bw, bh = board_box
    height = 4.2
    ordered = sorted(records, key=lambda record: record["anchor_x"])
    cursor = 1.5
    for record in ordered:
        width = label_width(record["label"])
        x = max(cursor, min(page_width - width - 1.5, record["anchor_x"] - width / 2.0))
        y = by - height - 2.0 if edge == "top" else by + bh + 2.0
        record.update(label_x=x, label_y=y, label_w=width)
        cursor = x + width + 1.0
    overflow = max(0.0, cursor - 1.0 - (page_width - 1.5))
    if overflow:
        for record in ordered:
            record["label_x"] -= overflow
    for record in ordered:
        x, y, width = record["label_x"], record["label_y"], record["label_w"]
        cx = x + width / 2.0
        if edge == "top":
            rail_y = by - 1.0
            record["leader"] = [(record["anchor_x"], record["anchor_y"]), (record["anchor_x"], rail_y), (cx, rail_y), (cx, y + height)]
        else:
            rail_y = by + bh + 1.0
            record["leader"] = [(record["anchor_x"], record["anchor_y"]), (record["anchor_x"], rail_y), (cx, rail_y), (cx, y)]


def render_horizontal_label(root: ET.Element, record: dict, *, font_size: float = 1.75) -> None:
    height = 4.2
    color = COLORS.get(record["domain"], COLORS["other"])
    for start, end in polyline_segments(record["leader"]):
        line(root, start[0], start[1], end[0], end[1], color)
    x, y, width = record["label_x"], record["label_y"], record["label_w"]
    ET.SubElement(root, qname("rect"), {
        "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
        "rx": "1.0", "fill": color,
    })
    text(root, x + width / 2.0, y + 2.82, record["label"],
         **{"font-size": f"{font_size:.2f}", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})
    ET.SubElement(root, qname("circle"), {
        "cx": f"{record['anchor_x']:.3f}", "cy": f"{record['anchor_y']:.3f}", "r": "0.58",
        "fill": "#FFFFFF", "stroke": color, "stroke-width": "0.45",
    })


def arrange_horizontal(records: list[dict], lanes: list[float], page_width: float) -> None:
    lane_records: list[list[dict]] = [[] for _ in lanes]
    for index, record in enumerate(sorted(records, key=lambda item: item["anchor_x"])):
        lane_records[index % len(lanes)].append(record)
    for lane_y, items in zip(lanes, lane_records):
        cursor = 1.5
        for record in items:
            width = label_width(record["label"])
            left = max(cursor, min(page_width - width - 1.5, record["anchor_x"] - width / 2))
            record.update(label_x=left, label_y=lane_y, label_w=width)
            cursor = left + width + 1.0


def arrange_vertical(records: list[dict], lanes: list[float], page_height: float) -> None:
    lane_records: list[list[dict]] = [[] for _ in lanes]
    for index, record in enumerate(sorted(records, key=lambda item: item["anchor_y"])):
        lane_records[index % len(lanes)].append(record)
    for lane_x, items in zip(lanes, lane_records):
        cursor = 18.0
        for record in items:
            height = 4.2
            top = max(cursor, min(page_height - height - 2.0, record["anchor_y"] - height / 2))
            width = label_width(record["label"])
            if lane_x < 40:
                left = lane_x
            else:
                left = lane_x - width
            record.update(label_x=left, label_y=top, label_w=width)
            cursor = top + height + 1.0


def arrange_rotated_edge(records: list[dict], edge: str, board_box: tuple[float, float, float, float]) -> None:
    """Place top/bottom labels vertically and preserve anchor order."""
    if not records:
        return
    bx, by, bw, bh = board_box
    ordered = sorted(records, key=lambda item: item["anchor_x"])
    minimum_x = bx + 2.6
    maximum_x = bx + bw - 2.6
    gap = 5.0
    positions: list[float] = []
    cursor = minimum_x
    for record in ordered:
        value = max(cursor, min(maximum_x, record["anchor_x"]))
        positions.append(value)
        cursor = value + gap
    overflow = max(0.0, positions[-1] - maximum_x)
    if overflow:
        positions = [value - overflow for value in positions]
    for index in range(len(positions) - 2, -1, -1):
        positions[index] = min(positions[index], positions[index + 1] - gap)
    underflow = max(0.0, minimum_x - positions[0])
    if underflow:
        positions = [value + underflow for value in positions]
    for record, center_x in zip(ordered, positions):
        width = label_width(record["label"])
        if edge == "top":
            center_y = by - 1.6 - width / 2.0
            angle = -90
        else:
            center_y = by + bh + 1.6 + width / 2.0
            angle = 90
        record.update(label_cx=center_x, label_cy=center_y, label_w=width, label_angle=angle)


def render_label(root: ET.Element, record: dict, board_box: tuple[float, float, float, float]) -> None:
    bx, by, bw, bh = board_box
    height = 4.2
    color = COLORS.get(record["domain"], COLORS["other"])
    ax, ay = record["anchor_x"], record["anchor_y"]
    if record["edge"] in ("top", "bottom"):
        width = record["label_w"]
        cx, cy = record["label_cx"], record["label_cy"]
        edge_y = by - 1.1 if record["edge"] == "top" else by + bh + 1.1
        line(root, ax, ay, ax, edge_y, color)
        line(root, ax, edge_y, cx, edge_y, color)
        group = ET.SubElement(root, qname("g"), {
            "transform": f"rotate({record['label_angle']} {cx:.3f} {cy:.3f})",
        })
        x, y = cx - width / 2.0, cy - height / 2.0
        ET.SubElement(group, qname("rect"), {
            "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
            "rx": "1.0", "fill": color,
        })
        text(group, cx, cy + 0.72, record["label"],
             **{"font-size": "1.9", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})
    else:
        x, y, width = record["label_x"], record["label_y"], record["label_w"]
        cx, cy = x + width / 2, y + height / 2
        if record["edge"] == "left":
            line(root, ax, ay, bx - 1.2, ay, color)
            line(root, bx - 1.2, ay, x + width, cy, color)
        else:
            line(root, ax, ay, bx + bw + 1.2, ay, color)
            line(root, bx + bw + 1.2, ay, x, cy, color)
        ET.SubElement(root, qname("rect"), {
            "x": f"{x:.3f}", "y": f"{y:.3f}", "width": f"{width:.3f}", "height": f"{height:.3f}",
            "rx": "1.0", "fill": color,
        })
        text(root, cx, y + 2.85, record["label"],
             **{"font-size": "1.9", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})
    ET.SubElement(root, qname("circle"), {
        "cx": f"{ax:.3f}", "cy": f"{ay:.3f}", "r": "0.62",
        "fill": "#FFFFFF", "stroke": color, "stroke-width": "0.48",
    })


def add_legend(root: ET.Element, page_width: float, spec: dict) -> None:
    default_labels = {
        "stm32": "STM32 / ArduPilot",
        "rk3588": "RK3588",
        "shared": "STM32 + RK3588",
        "other": "Power / board",
    }
    configured = spec.get("interface_map_legend", {})
    entries = [
        (domain, str(configured.get(domain, label)))
        for domain, label in default_labels.items()
    ]
    x = page_width - 103.0
    for domain, label in entries:
        ET.SubElement(root, qname("rect"), {
            "x": f"{x:.3f}", "y": "5.2", "width": "4.0", "height": "3.0", "rx": "0.7",
            "fill": COLORS[domain],
        })
        text(root, x + 5.2, 7.6, label, **{"font-size": "2.15", "font-weight": "600"})
        x += 24.5


def add_processor_marker(root: ET.Element, designator: str, label: str, position: tuple[float, float], domain: str) -> None:
    x, y = position
    color = COLORS[domain]
    ET.SubElement(root, qname("circle"), {
        "cx": f"{x:.3f}", "cy": f"{y:.3f}", "r": "5.5", "fill": color,
        "fill-opacity": "0.12", "stroke": color, "stroke-width": "0.8",
    })
    label_x = x + 8.0
    label_y = y - 4.0
    line(root, x + 4.0, y - 4.0, label_x, label_y + 2.0, color, 0.5)
    ET.SubElement(root, qname("rect"), {
        "x": f"{label_x:.3f}", "y": f"{label_y:.3f}", "width": "31", "height": "5.5", "rx": "1.2", "fill": color,
    })
    text(root, label_x + 15.5, label_y + 3.7, f"{designator}  {label}",
         **{"font-size": "2.35", "font-weight": "700", "text-anchor": "middle", "fill": "#FFFFFF"})


def build_page(spec: dict, source_path: Path, output_path: Path, *, side: str) -> None:
    page_w, page_h = 266.0, 155.0
    source_root = ET.parse(source_path).getroot()
    view = parse_numbers(source_root.get("viewBox", ""))
    if len(view) != 4:
        raise ValueError(f"invalid board SVG viewBox: {source_path}")
    view_x, view_y, board_w, board_h = view
    board_x = (page_w - board_w) / 2.0
    board_y = 46.0
    board_box = (board_x, board_y, board_w, board_h)
    positions = component_positions(
        source_root,
        bottom=side == "bottom",
        view_x=view_x,
        view_y=view_y,
        view_width=board_w,
    )

    root = ET.Element(qname("svg"), {
        "version": "1.2", "baseProfile": "tiny", "data-coordinate-units": "mm",
        "width": f"{page_w}mm", "height": f"{page_h}mm", "viewBox": f"0 0 {page_w} {page_h}",
    })
    ET.SubElement(root, qname("rect"), {"x": "0", "y": "0", "width": str(page_w), "height": str(page_h), "fill": "#FFFFFF"})
    title = "TOP SIDE INTERFACE MAP 1:1" if side == "top" else "BOTTOM SIDE INTERFACE MAP 1:1"
    text(root, 2.0, 8.0, title, **{"font-size": "4.0", "font-weight": "700", "fill": "#000000"})
    add_legend(root, page_w, spec)

    clean = copy.deepcopy(source_root)
    remove_pads(clean)
    nested = ET.SubElement(root, qname("svg"), {
        "x": f"{board_x:.3f}", "y": f"{board_y:.3f}", "width": f"{board_w:.3f}", "height": f"{board_h:.3f}",
        "viewBox": f"{view_x:.6f} {view_y:.6f} {board_w:.6f} {board_h:.6f}",
    })
    for child in list(clean):
        nested.append(copy.deepcopy(child))

    records: list[dict] = []
    for group in spec["connector_groups"]:
        for item in group["items"]:
            designator = str(item["designator"])
            if designator not in positions:
                continue
            local_x, local_y = positions[designator]
            anchor_x, anchor_y = board_x + local_x, board_y + local_y
            label = f"{designator} {item.get('interface_label', item['name'])}"
            records.append({
                "label": label, "domain": str(item.get("processor_domain", "other")).lower(),
                "anchor_x": anchor_x, "anchor_y": anchor_y,
                "layout": str(item.get("map_label_layout", "perimeter")).lower(),
                "bias": str(item.get("map_label_bias", "nearest")).lower(),
                "edge_lock": str(item.get("map_label_edge", "auto")).lower(),
                "component_w": float(item.get("map_component_size_mm", [0.0, 0.0])[0]),
                "component_h": float(item.get("map_component_size_mm", [0.0, 0.0])[1]),
            })
    if side == "top":
        perimeter_records = [record for record in records if record["layout"] != "local"]
        local_records = [record for record in records if record["layout"] == "local"]
        arrange_perimeter_labels(perimeter_records, board_box)
        arrange_local_labels(
            local_records,
            board_box,
            records,
            perimeter_records,
        )
        for record in perimeter_records:
            render_perimeter_label(root, record)
        for record in local_records:
            render_local_label(root, record)
    else:
        top_records = [record for record in records if record["anchor_y"] <= board_y + board_h / 2.0]
        bottom_records = [record for record in records if record["anchor_y"] > board_y + board_h / 2.0]
        arrange_horizontal_edge(top_records, "top", board_box, page_w)
        arrange_horizontal_edge(bottom_records, "bottom", board_box, page_w)
        for record in top_records + bottom_records:
            render_horizontal_label(root, record)

    for processor in spec.get("interface_map_processors", []):
        marker_side = str(processor.get("side", "bottom")).lower()
        if marker_side in ("both", side):
            designator = str(processor["designator"])
            label = str(processor["label"])
            domain = str(processor.get("processor_domain", "other")).lower()
            if designator in positions:
                px, py = positions[designator]
                add_processor_marker(root, designator, label, (board_x + px, board_y + py), domain)

    text(root, 2.0, page_h - 2.0, "Board artwork is shown at physical 1:1 scale. Pads are intentionally hidden.",
         **{"font-size": "2.0", "fill": "#637785"})
    output_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--top-svg", type=Path, required=True)
    parser.add_argument("--bottom-svg", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.data.read_text(encoding="utf-8-sig"))
    build_page(spec, args.top_svg, args.output_dir / "pcb-interface-map-top.svg", side="top")
    build_page(spec, args.bottom_svg, args.output_dir / "pcb-interface-map-bottom.svg", side="bottom")
    print(args.output_dir.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
