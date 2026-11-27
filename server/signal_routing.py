"""Constrained PCB signal routing and length tuning from a sealed inventory."""

from collections import defaultdict
from dataclasses import dataclass
from itertools import product
import json
import math

from .routing_geometry import (
    finite_number, point_segment, segment_segment, stack_positions, units_per_mm, via_on_layer,
)
from .routing_operations import integer
from .signal_clearance import SignalClearance, point as _point


MULTI_LAYER = 74
TUNING_GAIN = 2 * (math.sqrt(2) - 1)


def _net_members(snapshot, net):
    tables = snapshot["tables"]
    if net not in {row["net"] for row in tables["nets"]}:
        raise ValueError(f"Unknown PCB net: {net}")
    pads = [row for row in tables["pads"] if row["net"] == net]
    tracks = [row for row in tables["tracks"] if row["net"] == net]
    if len(pads) != 2 or _point(pads[0]) == _point(pads[1]):
        raise ValueError(f"{net}: expected exactly two distinct pad centers")
    if any(row["net"] == net for table in ("arcs", "polygons") for row in tables[table]):
        raise ValueError(f"{net}: topology includes arcs or polygon definitions")
    return pads, tracks, [row for row in tables["vias"] if row["net"] == net]


def _copper_depths(snapshot):
    field = snapshot["board"].get("copper_depths_raw")
    if field is None:
        raise ValueError("Export a fresh snapshot with copper center depths for layer transitions")
    if not field:
        raise ValueError("Layer transitions require dielectric thickness between each pair of adjacent copper layers")
    depths = {int(layer): finite_number(depth, "copper depth")
              for layer, depth in (row.split(",") for row in field.split(";"))}
    positions = stack_positions(snapshot)
    ordered = [depths[layer] for layer in positions if layer in depths]
    if depths.keys() != positions.keys() or any(a >= b for a, b in zip(ordered, ordered[1:])):
        raise ValueError("Copper center depths must increase in physical stack order")
    return depths


@dataclass
class _Path:
    tracks: list
    vias: list
    layers: tuple
    planar: float
    vertical: float

    @property
    def length(self):
        return self.planar + self.vertical


def _path(snapshot, net):
    pads, tracks, vias = _net_members(snapshot, net)
    positions = stack_positions(snapshot)
    neighbors = defaultdict(list)
    point_layers = defaultdict(set)
    for track in tracks:
        a, b = _point(track, "1"), _point(track, "2")
        layer = int(track["layer_id"])
        if layer not in positions or a == b:
            raise ValueError(f"{net}: route includes a degenerate track or invalid layer")
        point_layers[a].add(layer)
        point_layers[b].add(layer)
        neighbors[a, layer].append(((b, layer), track, 0.0))
        neighbors[b, layer].append(((a, layer), track, 0.0))
    terminals = []
    for pad in pads:
        p, layer = _point(pad), int(pad["layer_id"])
        choices = point_layers[p] if layer == MULTI_LAYER else point_layers[p] & {layer}
        if len(choices) != 1:
            raise ValueError(f"{net}: each pad center must connect on exactly one layer")
        terminals.append((p, next(iter(choices))))
    start, finish = terminals
    depths = _copper_depths(snapshot) if vias else {}
    seen_vias = set()
    for via in vias:
        p = _point(via)
        layers = [layer for layer in point_layers[p] if via_on_layer(via, layer, positions)]
        if len(layers) != 2 or p in seen_vias or any(p == terminal[0] for terminal in terminals):
            raise ValueError(f"{net}: each distinct via center must join exactly two track layers outside the pads")
        for track in tracks:
            a, b = _point(track, "1"), _point(track, "2")
            if (p not in (a, b) and via_on_layer(via, int(track["layer_id"]), positions)
                    and point_segment(p, a, b) <= 1e-7):
                raise ValueError(f"{net}: a via joins a track away from its endpoint")
        seen_vias.add(p)
        a, b = [(p, layer) for layer in layers]
        height = abs(depths[a[1]] - depths[b[1]])
        neighbors[a].append((b, via, height))
        neighbors[b].append((a, via, height))
    if any(len(edges) != (1 if p in (start, finish) else 2) for p, edges in neighbors.items()):
        raise ValueError(f"{net}: route is branched or discontinuous")
    path, junctions, segments = [], [], defaultdict(list)
    planar, vertical, previous, point = 0.0, 0.0, None, start
    while point != finish and len(path) + len(junctions) < len(tracks) + len(vias):
        candidates = [(p, row, height) for p, row, height in neighbors[point] if p != previous]
        if len(candidates) != 1:
            break
        next_point, row, height = candidates[0]
        if height:
            junctions.append(row)
            vertical += height
        else:
            path.append(row)
            segments[point[1]].append((point[0], next_point[0]))
            planar += math.dist(point[0], next_point[0])
        previous, point = point, next_point
    if point != finish or len(path) != len(tracks) or len(junctions) != len(vias):
        raise ValueError(f"{net}: no single pad-center path consuming every track and via")
    # Endpoint degree alone misses a crossing, a retraced segment or a
    # junction midway along a segment.
    for layer_segments in segments.values():
        for i, (a, b) in enumerate(layer_segments):
            for c, d in layer_segments[:i]:
                if d == a:
                    dx, dy = a[0] - c[0], a[1] - c[1]
                    ex, ey = b[0] - a[0], b[1] - a[1]
                    if dx * ey == dy * ex and dx * ex + dy * ey < 0:
                        raise ValueError(f"{net}: adjacent tracks retrace the route")
                elif segment_segment(a, b, c, d) <= 1e-7:
                    raise ValueError(f"{net}: route touches or crosses itself")
    return _Path(path, junctions, tuple(segments), planar, vertical)


def _pairs(snapshot):
    data = snapshot["board"].get("differential_pairs_json")
    if data is None:
        raise ValueError("Export a fresh snapshot with differential-pair and board-outline context")
    return json.loads(data)


def _net_list(nets):
    if (not isinstance(nets, list) or not 1 <= len(nets) <= 32
            or not all(isinstance(net, str) and net for net in nets) or len(set(nets)) != len(nets)):
        raise ValueError("Supply 1–32 distinct PCB net names")
    return nets


def measure_paths(snapshot, nets):
    scale = units_per_mm(snapshot)
    measurements = {}
    for net in _net_list(nets):
        try:
            path = _path(snapshot, net)
        except ValueError as error:
            measurements[net] = {"status": "unsupported", "reason": str(error)}
        else:
            measurements[net] = {
                "status": "measured", "length_mm": path.length / scale,
                "planar_length_mm": path.planar / scale, "via_length_mm": path.vertical / scale,
                "track_count": len(path.tracks), "via_count": len(path.vias), "layer_ids": path.layers,
                "layer_id": path.layers[0] if len(path.layers) == 1 else None,
            }
    pairs = []
    for name, positive, negative in json.loads(snapshot["board"].get("differential_pairs_json", "[]")):
        if positive in measurements and negative in measurements:
            a, b = measurements[positive], measurements[negative]
            lengths = [a["length_mm"], b["length_mm"]] if a["status"] == b["status"] == "measured" else []
            pairs.append({"pair": name, "positive": positive, "negative": negative,
                          "skew_mm": abs(lengths[0] - lengths[1]) if lengths else None,
                          "longest_member_mm": max(lengths, default=None)})
    return {"paths": measurements, "differential_pairs": pairs,
            "length_model": "Pad-center track lengths plus via travel between connected copper centers"}


def _raw_mm(snapshot, value, field, *, zero=False):
    length = finite_number(value, field)
    raw = length * units_per_mm(snapshot)
    if not (0 <= raw <= 1000000000) or (not zero and raw < 1):
        raise ValueError(f"{field} is outside the supported range")
    return raw


def _outline(snapshot):
    outline = snapshot["board"].get("outline_raw", "")
    fields = [row.split(",") for row in outline.split(";") if row]
    if len(fields) < 3 or any(row[0] != "0" for row in fields):
        raise ValueError("Planning requires a fresh snapshot with a straight-edged board outline")
    return [(int(row[1]), int(row[2])) for row in fields]


def _rectangle(area):
    if not isinstance(area, list) or len(area) != 4:
        raise ValueError("Each corridor must be an [x1,y1,x2,y2] rectangle in native units")
    x1, y1, x2, y2 = [integer(v, "corridor coordinate") for v in area]
    if not (x1 < x2 and y1 < y2):
        raise ValueError("Corridor bounds must be strictly increasing")
    return x1, y1, x2, y2


def _tracks(points, net, layer, width):
    return [
        {"net": net, "layer_id": layer, "width_raw": width,
         "x1_raw": a[0], "y1_raw": a[1], "x2_raw": b[0], "y2_raw": b[1]}
        for a, b in zip(points, points[1:]) if a != b
    ]


def _rail_points(span, shift, pitch=0):
    if shift == 0:
        return [(0, pitch), (span, pitch)]
    ramp = abs(shift)
    # Offset each 45-degree leg by the same normal distance as the horizontal
    # rail. Intersect the offset lines on the native grid to keep exact angles.
    diagonal_offset = math.copysign(math.ceil(abs(pitch) * math.sqrt(2)), pitch)
    miter = int(pitch - diagonal_offset) * (1 if shift > 0 else -1)
    lead = max(1, span // 8)
    return [(0, pitch), (lead + miter, pitch), (lead + ramp + miter, shift + pitch),
            (span - lead - ramp - miter, shift + pitch), (span - lead - miter, pitch),
            (span, pitch)]


def _world(anchor, axis, point):
    return anchor[0] + point[axis], anchor[1] + point[1 - axis]


def _rail_slice(rail, start, stop):
    points = []
    for (ax, ay), (bx, by) in zip(rail, rail[1:]):
        left, right = max(ax, start), min(bx, stop)
        if left < right:
            slope = (by - ay) // (bx - ax)
            if not points:
                points.append((left, ay + (left - ax) * slope))
            points.append((right, ay + (right - ax) * slope))
    return points


def _paired_track_gap(tracks, positive, negative):
    return min((
        segment_segment(_point(a, "1"), _point(a, "2"), _point(b, "1"), _point(b, "2"))
        - (a["width_raw"] + b["width_raw"]) / 2
        for a in tracks if a["net"] == positive
        for b in tracks if b["net"] == negative and b["layer_id"] == a["layer_id"]
    ), default=None)


def _via_sites(rails, step, half_run):
    flats = [[(ax, bx, ay) for (ax, ay), (bx, by) in zip(rail, rail[1:]) if ay == by]
             for rail in rails]
    sites = {}
    for (ax, bx, ay), (cx, dx, cy) in product(*flats):
        low, high = max(ax, cx) + half_run, min(bx, dx) - half_run
        if low <= high:
            for center in {*range(low, high + 1, step), (low + high) // 2, high}:
                sites[center] = (ay, cy)
    return sites


def _join_tracks(tracks):
    by_net = defaultdict(list)
    for row in tracks:
        rows = by_net[row["net"]]
        if rows and rows[-1]["layer_id"] == row["layer_id"]:
            previous = rows[-1]
            a, b, c = _point(previous, "1"), _point(previous, "2"), _point(row, "2")
            if b == _point(row, "1") and (b[0] - a[0]) * (c[1] - b[1]) == (b[1] - a[1]) * (c[0] - b[0]):
                previous.update(x2_raw=c[0], y2_raw=c[1])
                continue
        rows.append(dict(row))
    return [row for group in by_net.values() for row in group]


def _route_layer_profile(rails, nets, anchor, axis, width, preferred, layers, starts, finishes,
                         via_size, via_hole, clearance, pitch, step, max_changes):
    span = rails[0][-1][0]
    spread = max(0, math.ceil((max(via_size + max(clearance.clearance, clearance.mask_gap),
                                   via_hole + clearance.hole_clearance) - abs(pitch)) / 2))
    half_run = max(spread + width, math.ceil((via_size + width) / 2 + clearance.clearance),
                   math.ceil((via_hole + clearance.hole_clearance) / 2),
                   math.ceil((via_size + clearance.mask_gap) / 2))
    # A finite set of via stations keeps long corridors bounded. Candidate
    # copper is checked continuously between stations.
    sites = _via_sites(rails, max(step, math.ceil(span / 96)), half_run)
    transitions = {center - half_run: center for center in sites}
    nodes = sorted({0, span, *transitions, *(center + half_run for center in sites)})
    state = {(0, layer, 0): (0, None, [], []) for layer in starts}

    def place(net, points, layer):
        return _tracks([_world(anchor, axis, p) for p in points], net, layer, width)

    def extend(source, dest_x, dest_layer, tracks, vias, cost):
        dest = (dest_x, dest_layer, source[2] + bool(vias))
        total = state[source][0] + cost
        if dest in state and state[dest][0] <= total:
            return
        if clearance.clears(tracks, vias):
            state[dest] = (total, source, tracks, vias)

    for left, right in zip(nodes, nodes[1:]):
        for layer, changes in product(layers, range(max_changes + 1)):
            source = left, layer, changes
            if source not in state:
                continue
            straight = [row for net, rail in zip(nets, rails)
                        for row in place(net, _rail_slice(rail, left, right), layer)]
            extend(source, right, layer, straight, [], 0 if layer == preferred else right - left)
            if changes == max_changes or left not in transitions:
                continue
            center = transitions[left]
            stop = center + half_run
            for next_layer in layers:
                if next_layer == layer:
                    continue
                tracks, vias = [], []
                for index, (net, y) in enumerate(zip(nets, sites[center])):
                    direction = (1 if pitch > 0 else -1) * (1 if index else -1)
                    via_point = (center, y + direction * spread)
                    tracks.extend(place(net, [(left, y), (center - spread, y), via_point], layer))
                    tracks.extend(place(net, [via_point, (center + spread, y), (stop, y)], next_layer))
                    x, world_y = _world(anchor, axis, via_point)
                    vias.append({"net": net, "x_raw": x, "y_raw": world_y, "size_raw": via_size,
                                 "hole_size_raw": via_hole, "low_layer_id": 1, "high_layer_id": 32})
                cost = half_run * ((layer != preferred) + (next_layer != preferred))
                extend(source, stop, next_layer, tracks, vias, cost)

    goals = sorted((key for key in state if key[0] == span and key[1] in finishes),
                   key=lambda key: (key[2], state[key][0], key[1]))
    for goal in goals:
        route, key = [], goal
        while key[0]:
            _, key, tracks, vias = state[key]
            route.append((tracks, vias))
        route.reverse()
        tracks = _join_tracks([track for legs, _ in route for track in legs])
        vias = [via for _, transitions in route for via in transitions]
        if clearance.clears(tracks, vias):
            return tracks, vias, [key[1], *(legs[-1]["layer_id"] for legs, vias in route if vias)]
    return None


def plan_pair(snapshot, pair, layer_id, width_mm, clearance_mm, corridor_raw,
              detour_step_mm, edge_clearance_mm, routing_layer_ids=None, via_diameter_mm=None,
              via_hole_mm=None, hole_clearance_mm=None, max_layer_changes=2,
              mask_expansion_mm=None, min_mask_sliver_mm=None):
    members = [(p, n) for name, p, n in _pairs(snapshot) if name == pair]
    if len(members) != 1 or not all(members[0]) or members[0][0] == members[0][1]:
        raise ValueError("Pair must resolve to one native differential pair with two assigned nets")
    positive, negative = members[0]
    layer = integer(layer_id, "layer_id")
    width = round(_raw_mm(snapshot, width_mm, "width_mm"))
    clearance = _raw_mm(snapshot, clearance_mm, "clearance_mm", zero=True)
    step = round(_raw_mm(snapshot, detour_step_mm, "detour_step_mm"))
    edge = _raw_mm(snapshot, edge_clearance_mm, "edge_clearance_mm", zero=True)
    area, outline = _rectangle(corridor_raw), _outline(snapshot)
    routing_layers = [layer] if routing_layer_ids is None else routing_layer_ids
    if not isinstance(routing_layers, list) or not 1 <= len(routing_layers) <= 4:
        raise ValueError("Supply 1–4 signal layer IDs in routing_layer_ids")
    routing_layers = [integer(value, "routing layer ID") for value in routing_layers]
    positions = stack_positions(snapshot)
    if (layer not in routing_layers or len(set(routing_layers)) != len(routing_layers)
            or any(value not in positions or not 1 <= value <= 32 for value in routing_layers)):
        raise ValueError("Routing layers must be unique signal layers in the stack and include layer_id")
    max_changes = integer(max_layer_changes, "max_layer_changes")
    if not 0 <= max_changes <= 4:
        raise ValueError("max_layer_changes must be 0–4")
    via_size = via_hole = hole_clearance = mask_gap = 0
    depths = {}
    if len(routing_layers) > 1:
        if not {1, 32} <= positions.keys() or via_diameter_mm is None or via_hole_mm is None:
            raise ValueError("Layer changes require a Top–Bottom drill span and explicit via diameter and hole")
        via_size = round(_raw_mm(snapshot, via_diameter_mm, "via_diameter_mm"))
        via_hole = round(_raw_mm(snapshot, via_hole_mm, "via_hole_mm"))
        if via_hole >= via_size:
            raise ValueError("Via hole must be smaller than the diameter")
        hole_clearance = clearance if hole_clearance_mm is None else _raw_mm(
            snapshot, hole_clearance_mm, "hole_clearance_mm", zero=True)
        depths = _copper_depths(snapshot)
    if mask_expansion_mm is not None or min_mask_sliver_mm is not None:
        if mask_expansion_mm is None or min_mask_sliver_mm is None:
            raise ValueError("Supply both mask_expansion_mm and min_mask_sliver_mm for mask screening")
        expansion = _raw_mm(snapshot, mask_expansion_mm, "mask_expansion_mm", zero=True)
        sliver = _raw_mm(snapshot, min_mask_sliver_mm, "min_mask_sliver_mm", zero=True)
        mask_gap = 2 * expansion + sliver
    checker = SignalClearance(snapshot, area, outline, clearance, edge, hole_clearance, mask_gap)
    p_pads, p_tracks, p_vias = _net_members(snapshot, positive)
    n_pads, n_tracks, n_vias = _net_members(snapshot, negative)
    if p_tracks or n_tracks or p_vias or n_vias:
        raise ValueError("Both pair members must be unrouted")
    p, n = [[_point(row) for row in pads] for pads in (p_pads, n_pads)]
    if p[0][0] == p[1][0]:
        axis = 1
    elif p[0][1] == p[1][1]:
        axis = 0
    else:
        raise ValueError("Pair launch geometry must be horizontal or vertical")
    cross_axis = 1 - axis
    p, n = sorted(p, key=lambda v: v[axis]), sorted(n, key=lambda v: v[axis])
    pitch = n[0][cross_axis] - p[0][cross_axis]
    if not all(a[axis] == b[axis] and b[cross_axis] - a[cross_axis] == pitch for a, b in zip(p, n)):
        raise ValueError("The two ends must have equal pad pitch and consistent polarity")
    if abs(pitch) <= width or abs(pitch) - width + 1e-6 < clearance:
        raise ValueError("Pair pad pitch minus track width cannot meet the requested clearance")
    span = p[1][axis] - p[0][axis]
    terminals = []
    for a, b in zip(sorted(p_pads, key=lambda row: _point(row)[axis]),
                    sorted(n_pads, key=lambda row: _point(row)[axis])):
        allowed = [value for value in routing_layers
                   if all(int(row["layer_id"]) in (MULTI_LAYER, value) for row in (a, b))]
        if not allowed:
            raise ValueError("Each pair launch requires a common pad layer among the routing layers")
        terminals.append(allowed)
    starts, finishes = terminals
    scale = units_per_mm(snapshot)
    shifts = [0] + [sign * step * i for i in range(1, 17) for sign in (1, -1)]
    best = None
    for shift in shifts:
        rails = [_rail_points(span, shift), _rail_points(span, shift, pitch)]
        if any(any(a[0] >= b[0] for a, b in zip(rail, rail[1:])) for rail in rails):
            continue
        direct = None
        for direct_layer in sorted(set(starts) & set(finishes), key=lambda value: (value != layer, value)):
            tracks = [row for net, rail in zip(members[0], rails)
                      for row in _tracks([_world(p[0], axis, point) for point in rail], net, direct_layer, width)]
            if checker.clears(tracks):
                direct = tracks, [], [direct_layer]
                break
        route = direct
        if route is None and len(routing_layers) > 1 and max_changes:
            cap = len(best[1]) // 2 - 1 if best else max_changes
            if cap >= 1:
                route = _route_layer_profile(rails, members[0], p[0], axis, width, layer, routing_layers,
                                             starts, finishes, via_size, via_hole, checker, pitch, step, cap)
        if route is None:
            continue
        tracks, vias, layers = route
        pair_gap = _paired_track_gap(tracks, positive, negative)
        if pair_gap is None or pair_gap < abs(pitch) - width - 1:
            continue
        if best is None or len(vias) < len(best[1]):
            best = tracks, vias, layers, shift, pair_gap
        # Zero transitions for a common launch layer, otherwise one, is the lower bound.
        if len(vias) == (0 if set(starts) & set(finishes) else 2):
            break
    if best is None:
        raise ValueError("No straight or paired 45-degree detour fits the corridor and modeled clearance")
    tracks, vias, layers, shift, pair_gap = best
    planar = sum(math.dist(_point(r, "1"), _point(r, "2")) for r in tracks if r["net"] == positive)
    vertical = sum(abs(depths[a] - depths[b]) for a, b in zip(layers, layers[1:]))
    return {
        "pair": pair, "positive": positive, "negative": negative,
        "detour_mm": shift / scale, "nominal_edge_gap_mm": (abs(pitch) - width) / scale,
        "minimum_track_gap_mm": pair_gap / scale,
        "planned_centerline_length_mm_each": planar / scale,
        "planned_length_mm_each": (planar + vertical) / scale,
        "layer_ids": layers, "layer_changes": len(vias) // 2, "via_count": len(vias),
        "operations": [{"kind": "via", "action": "add", "new": row} for row in vias]
        + [{"kind": "track", "action": "add", "new": row} for row in tracks],
    }


def _tuning_candidates(row, depth):
    a, b = sorted((_point(row, "1"), _point(row, "2")))
    axis = 0 if a[1] == b[1] else 1
    if a[1 - axis] != b[1 - axis]:
        return
    run = b[axis] - a[axis]
    # Retain straight lead-ins and a flat at least one track width long.
    width = int(row["width_raw"])
    if run < 2 * depth + 3 * width:
        return
    remaining = run - 2 * depth
    for margin in sorted({width, max(width, remaining // 4), remaining // 3}):
        for shift in (depth, -depth):
            points = [(0, 0), (margin, 0), (margin + depth, shift),
                      (run - margin - depth, shift), (run - margin, 0), (run, 0)]
            yield _tracks([(a[0] + v[axis], a[1] + v[1 - axis]) for v in points],
                          row["net"], int(row["layer_id"]), width)


def _preserves_path(path, old, candidates, positions):
    layer = int(old["layer_id"])
    for new in candidates[1:-1]:
        a, b = _point(new, "1"), _point(new, "2")
        if any(int(other["layer_id"]) == layer and other is not old
               and segment_segment(a, b, _point(other, "1"), _point(other, "2")) <=
               (new["width_raw"] + int(other["width_raw"])) / 2 for other in path.tracks):
            return False
        if any(via_on_layer(via, layer, positions) and point_segment(_point(via), a, b) <=
               (new["width_raw"] + int(via["size_raw"])) / 2 for via in path.vias):
            return False
    return True


def _coupled_tuning(left, right, depth, clearance):
    layer = int(left["layer_id"])
    width = int(left["width_raw"])
    if layer != int(right["layer_id"]) or width != int(right["width_raw"]):
        return
    a, b = sorted((_point(left, "1"), _point(left, "2")))
    c, d = sorted((_point(right, "1"), _point(right, "2")))
    axis = 0 if a[1] == b[1] else 1
    lateral = 1 - axis
    if a[lateral] != b[lateral] or c[lateral] != d[lateral]:
        return
    pitch = c[lateral] - a[lateral]
    if abs(pitch) - width < max(1, clearance) - 1e-6:
        return
    start, finish = max(a[axis], c[axis]), min(b[axis], d[axis])
    if finish - start < 2 * depth + 3 * width:
        return
    anchor = (start, a[1]) if axis == 0 else (a[0], start)
    for shift in (depth, -depth):
        rails = [_rail_points(finish - start, shift), _rail_points(finish - start, shift, pitch)]
        if any(any(q[0] <= p[0] or (p[1] == q[1] and q[0] - p[0] < width)
                   for p, q in zip(rail, rail[1:])) for rail in rails):
            continue
        paths = [_join_tracks(_tracks([first, *(_world(anchor, axis, p) for p in rail), last],
                                      row["net"], layer, width))
                 for row, rail, first, last in ((left, rails[0], a, b), (right, rails[1], c, d))]
        gap = _paired_track_gap(paths[0] + paths[1], left["net"], right["net"])
        if gap is not None and gap >= abs(pitch) - width - 1:
            yield paths


def _replace_track(existing, operations, old, candidates):
    existing.remove(old)
    existing.extend(candidates)
    operations.append({"kind": "track", "action": "edit", "old": old, "new": candidates[0]})
    operations.extend({"kind": "track", "action": "add", "new": row} for row in candidates[1:])


def _group_members(snapshot, pairs):
    if not isinstance(pairs, list) or not 1 <= len(pairs) <= 16:
        raise ValueError("Supply 1–16 native differential-pair names")
    members = []
    definitions = _pairs(snapshot)
    for name in _net_list(pairs):
        matches = [(p, n) for label, p, n in definitions if label == name]
        if len(matches) != 1 or not all(matches[0]) or matches[0][0] == matches[0][1]:
            raise ValueError(f"{name}: expected a native pair with two assigned nets")
        members.append((name, matches[0]))
    return members


def plan_length_match(snapshot, nets, corridors_raw, tolerance_mm, clearance_mm,
                      target_mm, edge_clearance_mm, pairs=None):
    if (nets is None) == (pairs is None):
        raise ValueError("Supply either nets or pairs")
    groups = _group_members(snapshot, pairs) if pairs is not None else [(net, (net,)) for net in _net_list(nets)]
    nets = _net_list([net for _, members in groups for net in members])
    if not isinstance(corridors_raw, dict) or set(corridors_raw) - {name for name, _ in groups}:
        raise ValueError("corridors_raw must map the requested net or pair names to rectangles")
    corridors = {net: _rectangle(area) for net, area in corridors_raw.items()}
    scale, outline = units_per_mm(snapshot), _outline(snapshot)
    tolerance = _raw_mm(snapshot, tolerance_mm, "tolerance_mm")
    clearance = _raw_mm(snapshot, clearance_mm, "clearance_mm", zero=True)
    edge = _raw_mm(snapshot, edge_clearance_mm, "edge_clearance_mm", zero=True)
    positions = stack_positions(snapshot)
    paths = {net: _path(snapshot, net) for net in nets}
    if target_mm is None:
        target = max(path.length for path in paths.values())
    else:
        target = _raw_mm(snapshot, target_mm, "target_mm")
    operations, measurements = [], {}
    existing = list(snapshot["tables"]["tracks"])
    for name, members in groups:
        group = [paths[net] for net in members]
        lengths = [path.length for path in group]
        if max(lengths) - target > tolerance:
            raise ValueError(f"{name}: target requires shortening the route")
        gain = 0.0
        if target - min(lengths) > tolerance:
            if name not in corridors:
                raise ValueError(f"{name}: a tuning corridor is required")
            depth = max(1, round((target - sum(lengths) / len(lengths)) / TUNING_GAIN))
            gain = depth * TUNING_GAIN
            if any(abs(length + gain - target) > tolerance for length in lengths):
                raise ValueError(f"{name}: the target cannot be met at this tolerance while preserving skew")
            trunks = [sorted(path.tracks, key=lambda r: -math.dist(_point(r, "1"), _point(r, "2")))
                      for path in group]
            replacement = None
            for old in product(*trunks):
                if len(old) == 2:
                    options = _coupled_tuning(*old, depth, clearance)
                else:
                    options = ((rows,) for rows in _tuning_candidates(old[0], depth))
                checker = None
                for candidates in options:
                    if not all(_preserves_path(path, row, new, positions)
                               for path, row, new in zip(group, old, candidates)):
                        continue
                    if checker is None:
                        modeled = {**snapshot, "tables": {**snapshot["tables"],
                                   "tracks": [row for row in existing if all(row is not item for item in old)]}}
                        checker = SignalClearance(modeled, corridors[name], outline, clearance, edge)
                    if checker.clears([row for path in candidates for row in path]):
                        replacement = old, candidates
                        break
                if replacement is not None:
                    break
            if replacement is None:
                raise ValueError(f"{name}: no straight segment fits the requested tuning and clearance")
            for row, candidates in zip(*replacement):
                _replace_track(existing, operations, row, candidates)
        for net, path in zip(members, group):
            measurements[net] = {"before_mm": path.length / scale, "planned_mm": (path.length + gain) / scale,
                                 "via_length_mm": path.vertical / scale, "layer_ids": path.layers,
                                 "layer_id": path.layers[0] if len(path.layers) == 1 else None}
    lengths = [path["planned_mm"] for path in measurements.values()]
    spread = max(lengths) - min(lengths)
    if pairs is not None and spread > tolerance_mm + 1e-12:
        raise ValueError("Coupled tuning cannot bring all pair members within the requested group spread")
    return {"target_mm": target / scale, "tolerance_mm": tolerance_mm,
            "planned_spread_mm": spread,
            "pair_names": [name for name, _ in groups] if pairs is not None else [],
            "paths": measurements, "operations": operations}
