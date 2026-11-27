"""Clearance screening for candidate tracks and through vias in native units."""

from collections import defaultdict
from dataclasses import dataclass
import math

from .routing_geometry import (
    inside, point_segment, rectangle, segment_polygon, segment_segment, stack_positions, via_on_layer,
)


def point(row, suffix=""):
    return int(row["x" + suffix + "_raw"]), int(row["y" + suffix + "_raw"])


@dataclass(frozen=True)
class _Copper:
    net: str
    points: tuple
    radius: float = 0

    @property
    def bounds(self):
        x, y = zip(*self.points)
        return (min(x) - self.radius, min(y) - self.radius,
                max(x) + self.radius, max(y) + self.radius)

    def gap(self, obstacle):
        a, b = self.points
        if len(obstacle.points) == 2:
            distance = segment_segment(a, b, *obstacle.points)
        else:
            distance = segment_polygon(a, b, obstacle.points)
        return distance - self.radius - obstacle.radius


def _trace(row):
    return _Copper(row["net"], (point(row, "1"), point(row, "2")), int(row["width_raw"]) / 2)


def _disk(row, radius):
    return _Copper(row["net"], (point(row), point(row)), radius)


def _near(a, b, clearance):
    return (a[0] <= b[2] + clearance and b[0] <= a[2] + clearance
            and a[1] <= b[3] + clearance and b[1] <= a[3] + clearance)


class SignalClearance:
    """Model a corridor and the copper and drills that can interfere with it."""

    def __init__(self, snapshot, area, outline, clearance, edge, hole_clearance=0, mask_gap=0):
        self.positions = stack_positions(snapshot)
        self.area = area
        self.outline = outline
        self.edges = tuple(zip(outline, outline[1:] + outline[:1]))
        self.edge_bounds = tuple((min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
                                 for a, b in self.edges)
        self.clearance = clearance
        self.edge = edge
        x1, y1, x2, y2 = area
        corners = [(x1, y1), (x1, y2), (x2, y2), (x2, y1)]
        self.corridor_margin = 0
        if all(inside(corner, outline) for corner in corners):
            self.corridor_margin = min(
                segment_segment(a, b, c, d)
                for a, b in zip(corners, corners[1:] + corners[:1]) for c, d in self.edges
            )
        self.hole_clearance = hole_clearance
        self.mask_gap = mask_gap
        self.copper = defaultdict(list)
        self.pads = []
        self.drills = []
        self.via_masks = []
        tables = snapshot["tables"]
        for row in tables["tracks"]:
            self._add(_trace(row), (int(row["layer_id"]),))
        for row in tables["arcs"]:
            # A disk enclosing the full arc errs on the side of keeping it clear.
            self._add(_disk(row, int(row["radius_raw"]) + int(row["width_raw"]) / 2),
                      (int(row["layer_id"]),))
        for row in tables["vias"]:
            layers = [layer for layer in self.positions if via_on_layer(row, layer, self.positions)]
            via = _disk(row, int(row["size_raw"]) / 2)
            self._add(via, layers)
            if mask_gap and _near(area, via.bounds, mask_gap):
                self.via_masks.append((via.bounds, via))
            self.drills.append((point(row), int(row["hole_size_raw"]) / 2))
        for row in tables["pads"]:
            layer = int(row["layer_id"])
            pad = _Copper(row["net"], tuple(rectangle(
                point(row), int(row["top_x_size_raw"]), int(row["top_y_size_raw"]),
                float(row["rotation_degrees"]),
            )))
            self._add(pad, self.positions if layer == 74 else (layer,))
            if _near(area, pad.bounds, max(clearance, mask_gap)):
                self.pads.append((pad.bounds, pad))
            if int(row.get("hole_size_raw", 0)) > 0:
                self.drills.append((point(row), int(row["hole_size_raw"]) / 2))

    def _add(self, shape, layers):
        bounds = shape.bounds
        if _near(self.area, bounds, self.clearance):
            for layer in layers:
                self.copper[layer].append((bounds, shape))

    def _inside(self, shape):
        x1, y1, x2, y2 = self.area
        a, b = shape.points
        r = shape.radius
        if not all(x1 + r <= x <= x2 - r and y1 + r <= y <= y2 - r for x, y in (a, b)):
            return False
        # The trace or via capsule is wholly inside the rectangle. A rectangle
        # separated from the board perimeter by the required distance certifies
        # clearance for every capsule it contains.
        margin = self.corridor_margin
        if margin > 0 and margin >= self.edge:
            return True
        if margin <= 0 and not inside(a, self.outline):
            return False
        bound = (min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
        reach = r + self.edge
        return all(not _near(bound, box, reach) or segment_segment(a, b, c, d) >= reach
                   for (c, d), box in zip(self.edges, self.edge_bounds))

    def _conflicts(self, shape, obstacles):
        bounds = shape.bounds
        return any(shape.net != other.net and _near(bounds, box, self.clearance)
                   and shape.gap(other) < self.clearance - 1e-6
                   for box, other in obstacles)

    def clears(self, tracks, vias=()):
        candidates = defaultdict(list)
        for row in tracks:
            candidates[int(row["layer_id"])].append(_trace(row))
        drills = list(self.drills) if vias else []
        via_masks = list(self.via_masks)
        for row in vias:
            via = _disk(row, int(row["size_raw"]) / 2)
            if any(_near(via.bounds, box, 0) and via.gap(pad) <= 0 for box, pad in self.pads):
                return False
            if self.mask_gap:
                # A mask opening needs separation even between features on the same net.
                if any(_near(via.bounds, box, self.mask_gap) and via.gap(shape) < self.mask_gap - 1e-6
                       for box, shape in self.pads + via_masks):
                    return False
                via_masks.append((via.bounds, via))
            center = point(row)
            hole = int(row["hole_size_raw"]) / 2
            if any(math.dist(center, other) < hole + radius + self.hole_clearance - 1e-6
                   for other, radius in drills):
                return False
            drills.append((center, hole))
            # All planned vias are through. Their copper is a blocker even
            # on a layer carrying neither of the connected track legs.
            for layer in self.positions:
                candidates[layer].append(via)
        for layer, shapes in candidates.items():
            previous = []
            for shape in shapes:
                if (not self._inside(shape) or self._conflicts(shape, self.copper[layer])
                        or self._conflicts(shape, previous)):
                    return False
                previous.append((shape.bounds, shape))
        return True
