"""Snapshot-based geometry observations, with explicit electrical policies.

Distance primitives adapted from Quilter geometry_review.py (MIT).
Copyright 2026 Allegro Labs, Inc. See LICENSES/Quilter-MIT.txt.
"""

from __future__ import annotations

import math
import re
from collections import defaultdict


def point_segment(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length2 = dx * dx + dy * dy
    t = (
        max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length2))
        if length2
        else 0
    )
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


def segment_segment(a, b, c, d):
    def orient(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])

    if orient(a, b, c) * orient(a, b, d) < 0 and orient(c, d, a) * orient(c, d, b) < 0:
        return 0.0
    return min(
        point_segment(a, c, d),
        point_segment(b, c, d),
        point_segment(c, a, b),
        point_segment(d, a, b),
    )


def inside(p, polygon):
    result = False
    for a, b in zip(polygon, polygon[1:] + polygon[:1]):
        if point_segment(p, a, b) < 1e-12:
            return True
        if (a[1] > p[1]) != (b[1] > p[1]):
            crossing = (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]
            if p[0] < crossing:
                result = not result
    return result


def segment_polygon(a, b, polygon):
    if len(polygon) < 3:
        raise ValueError("A polygon requires at least three vertices")
    if inside(a, polygon) or inside(b, polygon):
        return 0.0
    return min(
        segment_segment(a, b, c, d) for c, d in zip(polygon, polygon[1:] + polygon[:1])
    )


def rectangle(center, x_size, y_size, rotation):
    c, s = math.cos(math.radians(rotation)), math.sin(math.radians(rotation))
    return [
        (center[0] + x * c - y * s, center[1] + x * s + y * c)
        for x, y in [
            (-x_size / 2, -y_size / 2),
            (x_size / 2, -y_size / 2),
            (x_size / 2, y_size / 2),
            (-x_size / 2, y_size / 2),
        ]
    ]


def finite_number(value, field):
    if isinstance(value, bool):
        raise ValueError(f"{field} must be a finite number")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{field} must be finite")
    return result


def units_per_mm(snapshot):
    return int(snapshot["board"]["internal_units_per_mil"]) / 0.0254


def stack_positions(snapshot):
    layers = sorted(
        snapshot["tables"].get("layers", []), key=lambda row: int(row["stack_index"])
    )
    positions = {int(row["layer_id"]): index for index, row in enumerate(layers)}
    if len(positions) != len(layers) or not positions:
        raise ValueError(
            "Snapshot requires a nonempty physical copper stack with unique layer IDs"
        )
    return positions


def via_on_layer(row, layer, positions):
    low, high = int(row["low_layer_id"]), int(row["high_layer_id"])
    if layer not in positions or low not in positions or high not in positions:
        raise ValueError("Via span is not represented in the snapshot copper stack")
    start, end = sorted((positions[low], positions[high]))
    return start <= positions[layer] <= end


def preview_clearance(snapshot, segments, clearance_mm):
    clearance = finite_number(clearance_mm, "clearance_mm")
    if clearance < 0:
        raise ValueError("clearance_mm must be nonnegative")
    scale = units_per_mm(snapshot)
    positions = stack_positions(snapshot)
    known = {r["net"] for r in snapshot["tables"]["nets"]}
    observations = []
    for index, segment in enumerate(segments):
        net = segment["net"]
        if net not in known:
            raise ValueError(f"Unknown candidate net: {net}")
        layer = int(segment["layer_id"])
        if layer not in positions:
            raise ValueError("Candidate layer is absent from the copper stack")
        a = tuple(
            finite_number(segment[f"{axis}1_raw"], axis) / scale for axis in ("x", "y")
        )
        b = tuple(
            finite_number(segment[f"{axis}2_raw"], axis) / scale for axis in ("x", "y")
        )
        radius = finite_number(segment["width_raw"], "width_raw") / scale / 2
        if radius <= 0 or a == b:
            raise ValueError(
                "Candidate width must be positive and segment must have length"
            )
        candidates = []
        for track in snapshot["tables"]["tracks"]:
            if track["net"] == net or int(track["layer_id"]) != layer:
                continue
            c = (int(track["x1_raw"]) / scale, int(track["y1_raw"]) / scale)
            d = (int(track["x2_raw"]) / scale, int(track["y2_raw"]) / scale)
            gap = (
                segment_segment(a, b, c, d)
                - radius
                - int(track["width_raw"]) / scale / 2
            )
            candidates.append((gap, "track", track))
        for via in snapshot["tables"]["vias"]:
            if via["net"] == net or not via_on_layer(via, layer, positions):
                continue
            p = (int(via["x_raw"]) / scale, int(via["y_raw"]) / scale)
            candidates.append(
                (
                    point_segment(p, a, b) - radius - int(via["size_raw"]) / scale / 2,
                    "via",
                    via,
                )
            )
        for pad in snapshot["tables"]["pads"]:
            if pad["net"] == net or int(pad["layer_id"]) not in {layer, 74}:
                continue
            p = (int(pad["x_raw"]) / scale, int(pad["y_raw"]) / scale)
            # Bounding rectangles deliberately overestimate rounded pad copper.
            body = rectangle(
                p,
                int(pad["top_x_size_raw"]) / scale,
                int(pad["top_y_size_raw"]) / scale,
                float(pad["rotation_degrees"]),
            )
            candidates.append((segment_polygon(a, b, body) - radius, "pad", pad))
        minimum = min((row[0] for row in candidates), default=None)
        conflicts = [
            {"gap_mm": gap, "kind": kind, "record": row}
            for gap, kind, row in candidates
            if gap < clearance
        ]
        observations.append(
            {
                "segment_index": index,
                "minimum_modeled_gap_mm": minimum,
                "conflicts": conflicts,
            }
        )
    # Candidate segments must also be checked against each other.
    candidate_conflicts = []
    for i, left in enumerate(segments):
        for j, right in enumerate(segments[:i]):
            if left["net"] == right["net"] or int(left["layer_id"]) != int(
                right["layer_id"]
            ):
                continue
            points = [
                (float(s[f"x{k}_raw"]) / scale, float(s[f"y{k}_raw"]) / scale)
                for s in (left, right)
                for k in (1, 2)
            ]
            gap = (
                segment_segment(*points)
                - (float(left["width_raw"]) + float(right["width_raw"])) / scale / 2
            )
            if gap < clearance:
                candidate_conflicts.append({"segments": [j, i], "gap_mm": gap})
    return {
        "observations": observations,
        "candidate_conflicts": candidate_conflicts,
        "modeled_conflict_count": sum(len(r["conflicts"]) for r in observations)
        + len(candidate_conflicts),
        "native_drc_required": True,
        "electrical_acceptance": False,
        "limits": [
            "Approximate straight-segment preview using pad bounding rectangles and via outer diameters.",
            "Arcs, keepouts, board-edge clearance, poured copper, full pad stacks, holes and reference continuity are not evaluated.",
            "Clearance is caller supplied; native scoped rules remain authoritative.",
        ],
    }


def _length(row, kind, scale):
    if kind == "tracks":
        return (
            math.hypot(
                int(row["x2_raw"]) - int(row["x1_raw"]),
                int(row["y2_raw"]) - int(row["y1_raw"]),
            )
            / scale
        )
    if kind == "arcs":
        angle = (float(row["end_angle"]) - float(row["start_angle"])) % 360
        if angle == 0:
            angle = 360
        return int(row["radius_raw"]) / scale * math.radians(angle)
    return 0


def audit_layer_usage(snapshot, policies, controlled_impedance_nets=()):
    positions = stack_positions(snapshot)
    known = {r["net"] for r in snapshot["tables"]["nets"]}
    controlled = set(controlled_impedance_nets)
    if not controlled <= known:
        raise ValueError("Controlled-impedance list includes unknown nets")
    policy_by_layer = {}
    for policy in policies:
        layer = int(policy["layer_id"])
        if layer not in positions or layer in policy_by_layer:
            raise ValueError("Layer policies must identify unique actual copper layers")
        if policy.get("role") not in {"signal", "ground", "power", "mixed"}:
            raise ValueError("Layer role must be signal, ground, power or mixed")
        allowed = policy.get("allowed_nets")
        if allowed is not None and not set(allowed) <= known:
            raise ValueError("Layer policy includes unknown allowed nets")
        if policy["role"] in {"ground", "power"} and allowed is None:
            raise ValueError(
                "Dedicated power/ground roles require an explicit allowed_nets list"
            )
        policy_by_layer[layer] = policy
    scale = units_per_mm(snapshot)
    summaries = defaultdict(
        lambda: {"primitives": 0, "length_mm": 0.0, "nets": set(), "violations": 0}
    )
    violations = []
    for kind in ("tracks", "arcs", "polygons"):
        for row in snapshot["tables"].get(kind, []):
            layer = int(row["layer_id"])
            if layer not in policy_by_layer:
                continue
            policy = policy_by_layer[layer]
            summary = summaries[layer]
            summary["primitives"] += 1
            summary["length_mm"] += _length(row, kind, scale)
            summary["nets"].add(row["net"])
            reasons = []
            if (
                policy.get("allowed_nets") is not None
                and row["net"] not in policy["allowed_nets"]
            ):
                reasons.append("net_not_allowed_on_layer")
            if (
                policy.get("prohibit_controlled_impedance", False)
                and row["net"] in controlled
            ):
                reasons.append("controlled_impedance_net_prohibited")
            if reasons:
                summary["violations"] += 1
                violations.append(
                    {
                        "kind": kind,
                        "role": policy["role"],
                        "reasons": reasons,
                        "record": row,
                    }
                )
    return {
        "layers": {
            str(k): dict(v, nets=sorted(v["nets"])) for k, v in summaries.items()
        },
        "violations": violations,
        "passed_policy": not violations,
        "unreviewed_layer_ids": sorted(set(positions) - set(policy_by_layer)),
        "limits": [
            "Roles, allowed nets and controlled-impedance nets are explicit caller policy, not name-prefix inference.",
            "Summed copper centerline length includes branches/overlaps; it is not endpoint path length or propagation delay.",
        ],
    }


def electrical_findings(ledger):
    """Extract native reported values without guessing which paired value belongs to a net."""
    selected = []
    for finding in ledger:
        if finding["category"] not in {
            "Delay",
            "Matched Lengths",
            "Differential pair coupling",
        }:
            continue
        text = finding["finding"]
        values = []
        for match in re.finditer(
            r"(?P<label>Actual Propagation Delay|Delay|Uncoupled Length|Maximum Uncoupled Length|Delay Tolerance)\s*(?:=|:)\s*(?P<value>[\d.]+)\s*(?P<unit>ps|ns|mil|mm)",
            text,
        ):
            values.append(
                {
                    "label": match["label"],
                    "value": float(match["value"]),
                    "unit": match["unit"],
                }
            )
        selected.append({**finding, "reported_values": values})
    return {
        "findings": selected,
        "count": len(selected),
        "limits": [
            "Values are samples from native violations, not a complete timing export.",
            "Paired delay values are retained in reported order without inferred net association.",
        ],
    }
