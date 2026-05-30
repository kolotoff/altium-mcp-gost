from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path


EXCHANGE_DIR = Path(r"C:\Users\Public\altium_mcp")
RESPONSE_FILE = EXCHANGE_DIR / "response.json"
OUTPUT_FILE = EXCHANGE_DIR / "3d_body_silhouette.txt"
DEFAULT_EMBEDDED_MODEL_DIR = EXCHANGE_DIR / "embedded_3d_models"
STEP_EXTENSIONS = {".stp", ".step"}
ALTIUM_WORKSPACE_OFFSET_MM = 1270.0
COORDINATE_WRAP_THRESHOLD_MM = 500.0
ALTIUM_TOP_PROJECTION_Z_BASELINE_DEG = 180.0
ALTIUM_TOP_PROJECTION_ROTATION_CORRECTION_DEG = 90.0
ROTATION_EPSILON_DEG = 1e-6
FACE_VISIBLE_EPSILON = 1e-6
COPLANAR_FACE_DOT = 0.9999
OCCLUSION_EPSILON_MM = 0.01
POINT_EPSILON_MM = 1e-5
OUTPUT_COORD_DECIMALS = 3
OUTPUT_MIN_LINE_LENGTH_MM = 0.03
PROJECTION_LINE_WIDTH_MM = 0.1
OPTIMIZE_POINT_GRID_MM = 0.001
COLLINEAR_DISTANCE_TOLERANCE_MM = 0.01
COLLINEAR_GAP_TOLERANCE_MM = 0.02
ARC_RADIAL_TOLERANCE_MM = 0.025
ARC_MIN_SWEEP_DEG = 3.0
ARC_MAX_SWEEP_DEG = 355.0
ARC_MERGE_ANGLE_TOLERANCE_DEG = 0.5
ARC_BBOX_TOLERANCE_MM = 0.05
MIN_VISIBLE_LINE_LENGTH_FACTOR = 0.5
MIN_VISIBLE_ARC_LENGTH_FACTOR = 1.0
MIN_VISIBLE_ARC_RADIUS_FACTOR = 1.0
STROKE_COVERAGE_DISTANCE_FACTOR = 0.5
STROKE_COVERAGE_MAX_LENGTH_FACTOR = 4.0
STROKE_COVERAGE_SAMPLE_STEP_FACTOR = 0.33
LINE_GAP_BRIDGE_MAX_FACTOR = 2.5
HEIGHT_AXIS_MISMATCH_FACTOR = 4.0
HEIGHT_AXIS_MISMATCH_MIN_MM = 5.0
CONTACT_COMPONENT_SIZE_GRID_MM = 0.02
CONTACT_COMPONENT_MIN_REPETITIONS = 4
CONTACT_COMPONENT_MAX_AREA_FRACTION = 0.12
CONTACT_COMPONENT_MAX_HEIGHT_FRACTION = 0.65
CONTACT_COMPONENT_MAX_HEIGHT_MM = 1.5
CONTACT_COMPONENT_EDGE_BAND_FRACTION = 0.15
CONTACT_COMPONENT_EDGE_BAND_MIN_MM = 0.3
CONTACT_COMPONENT_MIN_EDGE_RATIO = 0.5
CONTACT_COMPONENT_ORIGIN_SHIFT_MARGIN_MM = 0.05
CONTACT_COMPONENT_HIGH_PLANE_NUDGE_FRACTION = 0.2
CONTACT_COMPONENT_HIGH_PLANE_NUDGE_MIN_DELTA_MM = 0.25


NUM_RE = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?"


def vec_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vec_neg(v):
    return (-v[0], -v[1], -v[2])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def norm(v):
    mag = math.sqrt(dot(v, v))
    if mag <= 1e-12:
        return (0.0, 0.0, 0.0)
    return (v[0] / mag, v[1] / mag, v[2] / mag)


def parse_tuple(text: str) -> tuple[float, ...]:
    return tuple(float(item) for item in re.findall(NUM_RE, text))


def parse_ref_list(text: str) -> list[int]:
    return [int(item) for item in re.findall(r"#(\d+)", text)]


def split_step_records(text: str) -> list[str]:
    records: list[str] = []
    current: list[str] = []
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        current.append(ch)
        if ch == "'":
            if i + 1 < len(text) and text[i + 1] == "'":
                current.append(text[i + 1])
                i += 1
            else:
                in_string = not in_string
        elif ch == ";" and not in_string:
            records.append("".join(current).strip())
            current = []
        i += 1
    return records


def parse_step_geometry(path: Path) -> dict:
    text = path.read_text(encoding="latin-1", errors="ignore")
    records = split_step_records(text)

    points: dict[int, tuple[float, float, float]] = {}
    directions: dict[int, tuple[float, float, float]] = {}
    vertices: dict[int, int] = {}
    placements: dict[int, tuple[int, int, int]] = {}
    circles: dict[int, tuple[int, float]] = {}
    planes: dict[int, int] = {}
    edges: dict[int, tuple[int, int, int, bool]] = {}
    oriented_edges: dict[int, tuple[int, bool]] = {}
    edge_loops: dict[int, list[int]] = {}
    face_bounds: dict[int, tuple[int, bool]] = {}
    faces: dict[int, tuple[list[int], int, bool]] = {}

    for record in records:
        record = " ".join(record.split())
        match = re.match(rf"#(\d+)\s*=\s*CARTESIAN_POINT\s*\(\s*[^,]*,\s*\((.*?)\)\s*\)\s*;?$", record)
        if match:
            values = parse_tuple(match.group(2))
            if len(values) == 3:
                points[int(match.group(1))] = (values[0], values[1], values[2])
            continue

        match = re.match(rf"#(\d+)\s*=\s*DIRECTION\s*\(\s*[^,]*,\s*\((.*?)\)\s*\)\s*;?$", record)
        if match:
            values = parse_tuple(match.group(2))
            if len(values) == 3:
                directions[int(match.group(1))] = norm((values[0], values[1], values[2]))
            continue

        match = re.match(r"#(\d+)\s*=\s*VERTEX_POINT\s*\(\s*[^,]*,\s*#(\d+)\s*\)\s*;?$", record)
        if match:
            vertices[int(match.group(1))] = int(match.group(2))
            continue

        match = re.match(
            r"#(\d+)\s*=\s*AXIS2_PLACEMENT_3D\s*\(\s*[^,]*,\s*#(\d+)\s*,\s*#(\d+)\s*,\s*#(\d+)\s*\)\s*;?$",
            record,
        )
        if match:
            placements[int(match.group(1))] = (
                int(match.group(2)),
                int(match.group(3)),
                int(match.group(4)),
            )
            continue

        match = re.match(r"#(\d+)\s*=\s*PLANE\s*\(\s*[^,]*,\s*#(\d+)\s*\)\s*;?$", record)
        if match:
            planes[int(match.group(1))] = int(match.group(2))
            continue

        match = re.match(rf"#(\d+)\s*=\s*CIRCLE\s*\(\s*[^,]*,\s*#(\d+)\s*,\s*({NUM_RE})\s*\)\s*;?$", record)
        if match:
            circles[int(match.group(1))] = (int(match.group(2)), float(match.group(3)))
            continue

        match = re.match(
            r"#(\d+)\s*=\s*EDGE_CURVE\s*\(\s*(?:'[^']*'|\$|\*)\s*,\s*#(\d+)\s*,\s*#(\d+)\s*,\s*#(\d+)\s*,\s*\.(T|F)\.\s*\)\s*;?$",
            record,
        )
        if match:
            edges[int(match.group(1))] = (
                int(match.group(2)),
                int(match.group(3)),
                int(match.group(4)),
                match.group(5) == "T",
            )
            continue

        match = re.match(
            r"#(\d+)\s*=\s*ORIENTED_EDGE\s*\(\s*(?:'[^']*'|\$|\*)\s*,\s*\*\s*,\s*\*\s*,\s*#(\d+)\s*,\s*\.(T|F)\.\s*\)\s*;?$",
            record,
        )
        if match:
            oriented_edges[int(match.group(1))] = (int(match.group(2)), match.group(3) == "T")
            continue

        match = re.match(r"#(\d+)\s*=\s*EDGE_LOOP\s*\(\s*[^,]*,\s*\((.*?)\)\s*\)\s*;?$", record)
        if match:
            edge_loops[int(match.group(1))] = parse_ref_list(match.group(2))
            continue

        match = re.match(
            r"#(\d+)\s*=\s*(FACE_OUTER_BOUND|FACE_BOUND)\s*\(\s*[^,]*,\s*#(\d+)\s*,\s*\.(T|F)\.\s*\)\s*;?$",
            record,
        )
        if match:
            face_bounds[int(match.group(1))] = (int(match.group(3)), match.group(2) == "FACE_OUTER_BOUND")
            continue

        match = re.match(
            r"#(\d+)\s*=\s*ADVANCED_FACE\s*\(\s*[^,]*,\s*\((.*?)\)\s*,\s*#(\d+)\s*,\s*\.(T|F)\.\s*\)\s*;?$",
            record,
        )
        if match:
            faces[int(match.group(1))] = (parse_ref_list(match.group(2)), int(match.group(3)), match.group(4) == "T")

    return {
        "points": points,
        "directions": directions,
        "vertices": vertices,
        "placements": placements,
        "circles": circles,
        "planes": planes,
        "edges": edges,
        "oriented_edges": oriented_edges,
        "edge_loops": edge_loops,
        "face_bounds": face_bounds,
        "faces": faces,
    }


def point_for_vertex(geometry: dict, vertex_id: int) -> tuple[float, float, float] | None:
    point_id = geometry["vertices"].get(vertex_id)
    if point_id is None:
        return None
    return geometry["points"].get(point_id)


def rotation_angle_from_state(state: dict | None, key: str, default: float = 0.0) -> float:
    if state is None:
        return default
    value = state.get(key)
    if value is None:
        return default
    return float(value)


def rotate_x(point: tuple[float, float, float], angle_deg: float) -> tuple[float, float, float]:
    radians = math.radians(angle_deg)
    cos_a = math.cos(radians)
    sin_a = math.sin(radians)
    x, y, z = point
    return (x, y * cos_a - z * sin_a, y * sin_a + z * cos_a)


def rotate_y(point: tuple[float, float, float], angle_deg: float) -> tuple[float, float, float]:
    radians = math.radians(angle_deg)
    cos_a = math.cos(radians)
    sin_a = math.sin(radians)
    x, y, z = point
    return (x * cos_a + z * sin_a, y, -x * sin_a + z * cos_a)


def rotate_view_xy(u: float, v: float, angle_deg: float) -> tuple[float, float]:
    angle_deg = normalize_rotation_degrees(angle_deg)
    if angle_deg == 0.0:
        return (u, v)
    radians = math.radians(angle_deg)
    cos_a = math.cos(radians)
    sin_a = math.sin(radians)
    return (u * cos_a - v * sin_a, u * sin_a + v * cos_a)


def transform_model_point(point: tuple[float, float, float], state: dict | None) -> tuple[float, float, float]:
    rotated = rotate_x(point, rotation_angle_from_state(state, "rotx", 90.0))
    rotated = rotate_y(rotated, rotation_angle_from_state(state, "roty"))

    # Altium's common STEP placement for these PcbLib bodies uses ROTX=90,
    # which maps STEP Y to board height and STEP Z to board Y. Use view
    # coordinates that preserve the previous top-projection convention:
    # source X -> view X, source Z -> view Y, source Y -> view height.
    u = rotated[0]
    v = -rotated[1]
    w = rotated[2]
    u, v = rotate_view_xy(u, v, projection_rotation_from_model_state(state))
    return (u, v, w)


def transform_model_vector(vector: tuple[float, float, float], state: dict | None) -> tuple[float, float, float]:
    return transform_model_point(vector, state)


def edge_polyline_points(geometry: dict, edge_id: int) -> list[tuple[float, float, float]]:
    edge = geometry["edges"].get(edge_id)
    if edge is None:
        return []

    start_vertex, end_vertex, curve_id, _same_sense = edge
    start = point_for_vertex(geometry, start_vertex)
    end = point_for_vertex(geometry, end_vertex)
    if start is None or end is None:
        return []

    if curve_id in geometry["circles"]:
        placement_id, radius = geometry["circles"][curve_id]
        placement = geometry["placements"].get(placement_id)
        if placement is not None:
            center_id, axis_id, ref_id = placement
            center = geometry["points"].get(center_id)
            axis = geometry["directions"].get(axis_id)
            x_dir = geometry["directions"].get(ref_id)
            if center is not None and axis is not None and x_dir is not None and radius > 0:
                y_dir = norm(cross(axis, x_dir))

                def angle(point):
                    rel = vec_sub(point, center)
                    return math.atan2(dot(rel, y_dir), dot(rel, x_dir))

                a1 = angle(start)
                a2 = angle(end)
                delta = (a2 - a1 + math.pi) % (2.0 * math.pi) - math.pi
                if abs(delta) < 1e-9 and math.dist(start, end) > 1e-6:
                    delta = 2.0 * math.pi

                steps = max(2, min(24, int(math.ceil(abs(delta) * radius / 0.12))))
                arc_points = []
                for index in range(steps + 1):
                    theta = a1 + delta * index / steps
                    arc_points.append(
                        (
                            center[0] + radius * (math.cos(theta) * x_dir[0] + math.sin(theta) * y_dir[0]),
                            center[1] + radius * (math.cos(theta) * x_dir[1] + math.sin(theta) * y_dir[1]),
                            center[2] + radius * (math.cos(theta) * x_dir[2] + math.sin(theta) * y_dir[2]),
                        )
                    )
                return arc_points

    return [start, end]


def projected_segments_for_edges(
    geometry: dict,
    state: dict | None,
    edge_ids: list[int],
    occluder_faces: list[dict] | None = None,
    adjacent_face_ids_by_edge: dict[int, set[int]] | None = None,
    view_sign: int = 1,
) -> tuple[list[tuple[float, float, float, float]], int]:
    segments: list[tuple[float, float, float, float]] = []
    occluded_segments = 0
    for edge_id in edge_ids:
        points = [transform_model_point(point, state) for point in edge_polyline_points(geometry, edge_id)]
        for index in range(len(points) - 1):
            p1 = points[index]
            p2 = points[index + 1]
            if math.hypot(p2[0] - p1[0], p2[1] - p1[1]) < 1e-9:
                continue

            adjacent_face_ids = set()
            if adjacent_face_ids_by_edge is not None:
                adjacent_face_ids = adjacent_face_ids_by_edge.get(edge_id, set())

            if occluder_faces is not None and segment_is_occluded(p1, p2, occluder_faces, adjacent_face_ids, view_sign):
                occluded_segments += 1
                continue

            segments.append((p1[0], p1[1], p2[0], p2[1]))
    return segments, occluded_segments


def face_normal(geometry: dict, face: tuple[list[int], int, bool], state: dict | None) -> tuple[float, float, float] | None:
    _bound_ids, surface_id, same_sense = face
    placement_id = geometry["planes"].get(surface_id)
    if placement_id is None:
        return None

    placement = geometry["placements"].get(placement_id)
    if placement is None:
        return None

    _center_id, axis_id, _ref_id = placement
    axis = geometry["directions"].get(axis_id)
    if axis is None:
        return None

    normal = axis if same_sense else vec_neg(axis)
    return norm(transform_model_vector(normal, state))


def face_plane_point(geometry: dict, face: tuple[list[int], int, bool], state: dict | None) -> tuple[float, float, float] | None:
    _bound_ids, surface_id, _same_sense = face
    placement_id = geometry["planes"].get(surface_id)
    if placement_id is None:
        return None

    placement = geometry["placements"].get(placement_id)
    if placement is None:
        return None

    center_id, _axis_id, _ref_id = placement
    point = geometry["points"].get(center_id)
    if point is None:
        return None
    return transform_model_point(point, state)


def oriented_loop_points(geometry: dict, loop_id: int, state: dict | None) -> list[tuple[float, float, float]]:
    result: list[tuple[float, float, float]] = []
    for oriented_edge_id in geometry["edge_loops"].get(loop_id, []):
        oriented_edge = geometry["oriented_edges"].get(oriented_edge_id)
        if oriented_edge is None:
            continue

        edge_id, forward = oriented_edge
        points = edge_polyline_points(geometry, edge_id)
        if not forward:
            points = list(reversed(points))
        transformed = [transform_model_point(point, state) for point in points]
        if result and transformed and math.dist(result[-1], transformed[0]) <= POINT_EPSILON_MM:
            transformed = transformed[1:]
        result.extend(transformed)

    if len(result) > 2 and math.dist(result[0], result[-1]) <= POINT_EPSILON_MM:
        result.pop()
    return result


def face_polygons(geometry: dict, face: tuple[list[int], int, bool], state: dict | None) -> tuple[list[list[tuple[float, float]]], list[list[tuple[float, float]]]]:
    bound_ids, _surface_id, _same_sense = face
    outers: list[list[tuple[float, float]]] = []
    holes: list[list[tuple[float, float]]] = []
    for bound_id in bound_ids:
        bound = geometry["face_bounds"].get(bound_id)
        if bound is None:
            continue
        loop_id, is_outer = bound
        points = oriented_loop_points(geometry, loop_id, state)
        polygon = [(point[0], point[1]) for point in points]
        if len(polygon) < 3:
            continue
        if is_outer:
            outers.append(polygon)
        else:
            holes.append(polygon)
    return outers, holes


def point_near_segment_2d(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
    epsilon: float = POINT_EPSILON_MM,
) -> bool:
    px, py = point
    x1, y1 = start
    x2, y2 = end
    dx = x2 - x1
    dy = y2 - y1
    length_sq = dx * dx + dy * dy
    if length_sq <= epsilon * epsilon:
        return math.hypot(px - x1, py - y1) <= epsilon
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / length_sq))
    nearest_x = x1 + t * dx
    nearest_y = y1 + t * dy
    return math.hypot(px - nearest_x, py - nearest_y) <= epsilon


def point_in_polygon_strict(point: tuple[float, float], polygon: list[tuple[float, float]]) -> bool:
    if len(polygon) < 3:
        return False

    for index, start in enumerate(polygon):
        end = polygon[(index + 1) % len(polygon)]
        if point_near_segment_2d(point, start, end):
            return False

    x, y = point
    inside = False
    previous_x, previous_y = polygon[-1]
    for current_x, current_y in polygon:
        if (current_y > y) != (previous_y > y):
            intersection_x = (previous_x - current_x) * (y - current_y) / (previous_y - current_y) + current_x
            if x < intersection_x:
                inside = not inside
        previous_x, previous_y = current_x, current_y
    return inside


def face_contains_point(face_info: dict, point: tuple[float, float]) -> bool:
    if not any(point_in_polygon_strict(point, polygon) for polygon in face_info["outers"]):
        return False
    return not any(point_in_polygon_strict(point, polygon) for polygon in face_info["holes"])


def face_height_at(face_info: dict, u: float, v: float) -> float | None:
    normal = face_info["normal"]
    plane_point = face_info["plane_point"]
    if abs(normal[2]) <= FACE_VISIBLE_EPSILON:
        return None
    return plane_point[2] - (normal[0] * (u - plane_point[0]) + normal[1] * (v - plane_point[1])) / normal[2]


def segment_is_occluded(
    p1: tuple[float, float, float],
    p2: tuple[float, float, float],
    face_infos: list[dict],
    adjacent_face_ids: set[int],
    view_sign: int = 1,
) -> bool:
    midpoint = ((p1[0] + p2[0]) / 2.0, (p1[1] + p2[1]) / 2.0)
    segment_height = (p1[2] + p2[2]) / 2.0

    for face_info in face_infos:
        if face_info["face_id"] in adjacent_face_ids:
            continue
        if not face_contains_point(face_info, midpoint):
            continue
        face_height = face_height_at(face_info, midpoint[0], midpoint[1])
        if face_height is None:
            continue
        if view_sign >= 0:
            if face_height > segment_height + OCCLUSION_EPSILON_MM:
                return True
        elif face_height < segment_height - OCCLUSION_EPSILON_MM:
            return True
    return False


def visible_edge_projection(geometry: dict, state: dict | None) -> dict:
    if state is not None and state.get("_projection_axis_override"):
        return visible_edge_projection_for_side(geometry, state, 1)

    candidates = [visible_edge_projection_for_side(geometry, state, 1), visible_edge_projection_for_side(geometry, state, -1)]
    return max(
        candidates,
        key=lambda candidate: (
            candidate["stats"].get("visible_projected_segments", 0),
            candidate["stats"].get("visible_edges", 0),
        ),
    )


def visible_edge_projection_for_side(geometry: dict, state: dict | None, view_sign: int) -> dict:
    all_edge_ids = sorted(geometry["edges"])
    all_segments, _occluded = projected_segments_for_edges(geometry, state, all_edge_ids, view_sign=view_sign)
    if not all_segments:
        return {
            "segments": [],
            "source_bbox": None,
            "stats": {
                "visible_side": "top" if view_sign >= 0 else "bottom",
                "all_edges": len(all_edge_ids),
                "visible_edges": 0,
                "fallback_all_edges": False,
            },
        }

    source_bbox = bbox_for_segments(all_segments)
    edge_face_ids: dict[int, set[int]] = {}
    visible_edge_face_ids: dict[int, set[int]] = {}
    face_infos: dict[int, dict] = {}

    for face_id, face in geometry["faces"].items():
        normal = face_normal(geometry, face, state)
        plane_point = face_plane_point(geometry, face, state)
        if normal is None or plane_point is None:
            continue

        bound_ids, _surface_id, _same_sense = face
        face_edge_ids: set[int] = set()
        for bound_id in bound_ids:
            bound = geometry["face_bounds"].get(bound_id)
            if bound is None:
                continue
            loop_id, _is_outer = bound
            for oriented_edge_id in geometry["edge_loops"].get(loop_id, []):
                oriented_edge = geometry["oriented_edges"].get(oriented_edge_id)
                if oriented_edge is None:
                    continue
                edge_id, _forward = oriented_edge
                face_edge_ids.add(edge_id)
                edge_face_ids.setdefault(edge_id, set()).add(face_id)

        if view_sign * normal[2] <= FACE_VISIBLE_EPSILON:
            continue

        outers, holes = face_polygons(geometry, face, state)
        face_infos[face_id] = {
            "face_id": face_id,
            "normal": normal,
            "plane_point": plane_point,
            "outers": outers,
            "holes": holes,
        }
        for edge_id in face_edge_ids:
            visible_edge_face_ids.setdefault(edge_id, set()).add(face_id)

    top_visible_faces = list(face_infos.values())
    visible_edge_ids: list[int] = []
    coplanar_edges_removed = 0
    for edge_id, adjacent_visible_faces in visible_edge_face_ids.items():
        if len(adjacent_visible_faces) >= 2 and edge_face_ids.get(edge_id, set()).issubset(adjacent_visible_faces):
            normals = [face_infos[face_id]["normal"] for face_id in adjacent_visible_faces]
            first_normal = normals[0]
            if all(abs(dot(first_normal, normal)) >= COPLANAR_FACE_DOT for normal in normals[1:]):
                coplanar_edges_removed += 1
                continue
        visible_edge_ids.append(edge_id)

    visible_segments, occluded_segments_removed = projected_segments_for_edges(
        geometry,
        state,
        sorted(visible_edge_ids),
        top_visible_faces,
        visible_edge_face_ids,
        view_sign=view_sign,
    )

    fallback_all_edges = False
    if not visible_segments:
        visible_segments = all_segments
        fallback_all_edges = True

    return {
        "segments": visible_segments,
        "source_bbox": source_bbox,
        "stats": {
            "visible_side": "top" if view_sign >= 0 else "bottom",
            "all_edges": len(all_edge_ids),
            "all_projected_segments": len(all_segments),
            "top_visible_faces": len(top_visible_faces),
            "visible_edges": len(visible_edge_ids),
            "visible_projected_segments": len(visible_segments),
            "coplanar_edges_removed": coplanar_edges_removed,
            "occluded_segments_removed": occluded_segments_removed,
            "fallback_all_edges": fallback_all_edges,
        },
    }


def parse_step_edges(path: Path) -> list[tuple[float, float, float, float]]:
    geometry = parse_step_geometry(path)
    segments, _occluded = projected_segments_for_edges(geometry, None, sorted(geometry["edges"]))
    return segments


def bbox_for_segments(segments: list[tuple[float, float, float, float]]) -> tuple[float, float, float, float]:
    xs = [value for segment in segments for value in (segment[0], segment[2])]
    ys = [value for segment in segments for value in (segment[1], segment[3])]
    return (min(xs), min(ys), max(xs), max(ys))


def scale_segments(
    segments: list[tuple[float, float, float, float]],
    target_bbox: tuple[float, float, float, float],
    source_bbox: tuple[float, float, float, float] | None = None,
) -> list[tuple[float, float, float, float]]:
    if source_bbox is None:
        source_bbox = bbox_for_segments(segments)
    source_left, source_bottom, source_right, source_top = source_bbox
    target_left, target_bottom, target_right, target_top = target_bbox
    source_w = source_right - source_left
    source_h = source_top - source_bottom
    target_w = target_right - target_left
    target_h = target_top - target_bottom
    if source_w <= 1e-9 or source_h <= 1e-9:
        return []

    def map_point(x: float, y: float) -> tuple[float, float]:
        return (
            target_left + (x - source_left) * target_w / source_w,
            target_bottom + (y - source_bottom) * target_h / source_h,
        )

    scaled: list[tuple[float, float, float, float]] = []
    seen: set[tuple[int, int, int, int]] = set()
    for x1, y1, x2, y2 in segments:
        nx1, ny1 = map_point(x1, y1)
        nx2, ny2 = map_point(x2, y2)
        if math.hypot(nx2 - nx1, ny2 - ny1) < 0.03:
            continue

        a = (round(nx1, 3), round(ny1, 3))
        b = (round(nx2, 3), round(ny2, 3))
        key_points = sorted((a, b))
        key = (
            int(round(key_points[0][0] * 1000)),
            int(round(key_points[0][1] * 1000)),
            int(round(key_points[1][0] * 1000)),
            int(round(key_points[1][1] * 1000)),
        )
        if key in seen:
            continue
        seen.add(key)
        scaled.append((a[0], a[1], b[0], b[1]))
    return scaled


def place_segments_without_rescale(
    segments: list[tuple[float, float, float, float]],
    target_bbox: tuple[float, float, float, float],
    source_bbox: tuple[float, float, float, float] | None = None,
    rotation_deg: float = 0.0,
    anchor_bbox: tuple[float, float, float, float] | None = None,
) -> list[tuple[float, float, float, float]]:
    if source_bbox is None:
        source_bbox = bbox_for_segments(segments)

    source_left, source_bottom, source_right, source_top = source_bbox
    target_left, target_bottom, target_right, target_top = target_bbox
    source_center_x = (source_left + source_right) / 2.0
    source_center_y = (source_bottom + source_top) / 2.0
    anchor_left, anchor_bottom, anchor_right, anchor_top = anchor_bbox or target_bbox
    target_center_x = (anchor_left + anchor_right) / 2.0
    target_center_y = (anchor_bottom + anchor_top) / 2.0

    rotation_deg = normalize_rotation_degrees(rotation_deg)
    radians = math.radians(rotation_deg)
    cos_a = math.cos(radians)
    sin_a = math.sin(radians)

    def map_point(x: float, y: float) -> tuple[float, float]:
        rel_x = x - source_center_x
        rel_y = y - source_center_y
        return (
            target_center_x + rel_x * cos_a - rel_y * sin_a,
            target_center_y + rel_x * sin_a + rel_y * cos_a,
        )

    placed: list[tuple[float, float, float, float]] = []
    seen: set[tuple[int, int, int, int]] = set()
    for x1, y1, x2, y2 in segments:
        nx1, ny1 = map_point(x1, y1)
        nx2, ny2 = map_point(x2, y2)
        if math.hypot(nx2 - nx1, ny2 - ny1) < 0.03:
            continue

        a = (round(nx1, 3), round(ny1, 3))
        b = (round(nx2, 3), round(ny2, 3))
        key_points = sorted((a, b))
        key = (
            int(round(key_points[0][0] * 1000)),
            int(round(key_points[0][1] * 1000)),
            int(round(key_points[1][0] * 1000)),
            int(round(key_points[1][1] * 1000)),
        )
        if key in seen:
            continue
        seen.add(key)
        placed.append((a[0], a[1], b[0], b[1]))
    return placed


def normalize_target_bbox(
    target_bbox: tuple[float, float, float, float],
) -> tuple[tuple[float, float, float, float], bool]:
    left, bottom, right, top = target_bbox
    center_x = (left + right) / 2.0
    center_y = (bottom + top) / 2.0

    shift_x = 0.0
    shift_y = 0.0
    if abs(center_x) > COORDINATE_WRAP_THRESHOLD_MM:
        shift_x = round(center_x / ALTIUM_WORKSPACE_OFFSET_MM) * ALTIUM_WORKSPACE_OFFSET_MM
    if abs(center_y) > COORDINATE_WRAP_THRESHOLD_MM:
        shift_y = round(center_y / ALTIUM_WORKSPACE_OFFSET_MM) * ALTIUM_WORKSPACE_OFFSET_MM

    if shift_x == 0.0 and shift_y == 0.0:
        return target_bbox, False

    return (left - shift_x, bottom - shift_y, right - shift_x, top - shift_y), True


def normalize_model_name(name: str) -> str:
    return Path(name.replace("\\", "/")).name.upper()


def safe_float(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        return float(value.strip().replace("mil", ""))
    except ValueError:
        return None


def decode_identifier(value: str) -> str:
    chars: list[str] = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            codepoint = int(item)
        except ValueError:
            continue
        if 0 <= codepoint <= 0x10FFFF:
            chars.append(chr(codepoint))
    return "".join(chars).strip()


def parse_pcb_library_model_state(record: str) -> dict | None:
    fields: dict[str, str] = {}
    for part in record.split("|"):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        fields[key.strip().upper()] = value.strip()

    model_name = fields.get("MODEL.NAME")
    if not model_name:
        return None

    rotz = safe_float(fields.get("MODEL.3D.ROTZ"))
    if rotz is None:
        return None

    return {
        "model_name": model_name,
        "model_name_key": normalize_model_name(model_name),
        "identifier": decode_identifier(fields.get("IDENTIFIER", "")),
        "rotx": safe_float(fields.get("MODEL.3D.ROTX")),
        "roty": safe_float(fields.get("MODEL.3D.ROTY")),
        "rotz": rotz,
        "rotation_2d": safe_float(fields.get("MODEL.2D.ROTATION")) or 0.0,
    }


def load_pcb_library_model_states(library_path: Path | None) -> list[dict]:
    if library_path is None or not library_path.is_file():
        return []

    text = library_path.read_bytes().decode("latin-1", errors="ignore")
    states: list[dict] = []
    for record in text.split("\x00"):
        if "MODEL.NAME=" not in record or "MODEL.3D.ROTZ=" not in record:
            continue
        state = parse_pcb_library_model_state(record)
        if state is not None:
            states.append(state)
    return states


def model_state_for_body(states: list[dict], footprint: str, model_path: Path) -> dict | None:
    model_name_key = normalize_model_name(model_path.name)
    candidates = [state for state in states if state.get("model_name_key") == model_name_key]
    if not candidates:
        return None

    footprint_candidates = [
        state
        for state in candidates
        if state.get("identifier") and footprint_name_matches(str(state["identifier"]), footprint)
    ]
    if len(footprint_candidates) == 1:
        return footprint_candidates[0]
    if len(candidates) == 1:
        return candidates[0]
    return None


def model_state_for_footprint(states: list[dict], footprint: str) -> dict | None:
    candidates = [
        state
        for state in states
        if state.get("identifier") and footprint_name_matches(str(state["identifier"]), footprint)
    ]
    if len(candidates) == 1:
        return candidates[0]
    return None


def normalize_rotation_degrees(angle_deg: float) -> float:
    normalized = angle_deg % 360.0
    if abs(normalized) <= ROTATION_EPSILON_DEG or abs(normalized - 360.0) <= ROTATION_EPSILON_DEG:
        return 0.0
    return normalized


def projection_rotation_from_model_state(state: dict | None) -> float:
    if state is None:
        return 0.0
    rotz = state.get("rotz")
    if rotz is None:
        return 0.0
    rotx = state.get("rotx")
    baseline = ALTIUM_TOP_PROJECTION_Z_BASELINE_DEG
    if rotx is not None:
        normalized_rotx = normalize_rotation_degrees(float(rotx))
        if normalized_rotx in (0.0, 90.0, 270.0):
            baseline = 0.0
    rotation_2d = state.get("rotation_2d") or 0.0
    return normalize_rotation_degrees(baseline - float(rotz) + float(rotation_2d))


def transformed_model_extents(geometry: dict, state: dict | None) -> tuple[float, float, float] | None:
    points = geometry.get("points", {}).values()
    transformed = [transform_model_point(point, state) for point in points]
    if not transformed:
        return None

    return (
        max(point[0] for point in transformed) - min(point[0] for point in transformed),
        max(point[1] for point in transformed) - min(point[1] for point in transformed),
        max(point[2] for point in transformed) - min(point[2] for point in transformed),
    )


def transformed_model_height_state(geometry: dict, state: dict | None) -> dict | None:
    points = topological_vertex_points(geometry)
    if not points:
        points = list(geometry.get("points", {}).values())
    transformed = [transform_model_point(point, state) for point in points]
    if not transformed:
        return None

    min_z = min(point[2] for point in transformed)
    max_z = max(point[2] for point in transformed)
    component_contact = transformed_model_component_contact_plane_z(geometry, state)
    fallback_contact_plane = transformed_model_contact_plane_z(transformed)
    if component_contact is not None:
        contact_plane = component_contact["contact_plane_z_mm"]
        contact_method = component_contact["method"]
        contact_component_repetitions = component_contact.get("contact_component_repetitions")
    else:
        contact_plane = fallback_contact_plane
        contact_method = "topological_dense_plane" if fallback_contact_plane is not None else "absolute_min"
        contact_component_repetitions = None
    contact_standoff = -contact_plane if contact_plane is not None else -min_z
    result = {
        "min_z_mm": min_z,
        "max_z_mm": max_z,
        "overall_height_mm": max_z - min_z,
        "absolute_min_standoff_height_mm": -min_z,
        "contact_plane_z_mm": contact_plane if contact_plane is not None else min_z,
        "contact_plane_method": contact_method,
        "standoff_height_mm": contact_standoff,
    }
    if contact_component_repetitions is not None:
        result["contact_component_repetitions"] = contact_component_repetitions
    return result


def topological_vertex_points(geometry: dict) -> list[tuple[float, float, float]]:
    vertices = geometry.get("vertices", {})
    point_map = geometry.get("points", {})
    return [
        point_map[point_id]
        for point_id in vertices.values()
        if point_id in point_map
    ]


def transformed_model_component_contact_plane_z(geometry: dict, state: dict | None) -> dict[str, float | str] | None:
    components = transformed_vertex_components(geometry, state)
    if not components:
        return None

    all_points = [point for component in components for point in component["points"]]
    if not all_points:
        return None

    model_width = max(point[0] for point in all_points) - min(point[0] for point in all_points)
    model_depth = max(point[1] for point in all_points) - min(point[1] for point in all_points)
    model_height = max(point[2] for point in all_points) - min(point[2] for point in all_points)
    model_min_x = min(point[0] for point in all_points)
    model_max_x = max(point[0] for point in all_points)
    model_min_y = min(point[1] for point in all_points)
    model_max_y = max(point[1] for point in all_points)
    model_area = max(model_width * model_depth, 1e-9)
    max_contact_height = max(CONTACT_COMPONENT_MAX_HEIGHT_MM, model_height * CONTACT_COMPONENT_MAX_HEIGHT_FRACTION)
    edge_band = max(CONTACT_COMPONENT_EDGE_BAND_MIN_MM, min(model_width, model_depth) * CONTACT_COMPONENT_EDGE_BAND_FRACTION)

    grouped: dict[tuple[int, int, int], list[dict]] = {}
    for component in components:
        points = component["points"]
        if len(points) < 8:
            continue
        x_span = component["x_span"]
        y_span = component["y_span"]
        z_span = component["z_span"]
        if x_span <= POINT_EPSILON_MM or y_span <= POINT_EPSILON_MM:
            continue
        if x_span * y_span > model_area * CONTACT_COMPONENT_MAX_AREA_FRACTION:
            continue
        if z_span > max_contact_height:
            continue

        key = (
            int(round(x_span / CONTACT_COMPONENT_SIZE_GRID_MM)),
            int(round(y_span / CONTACT_COMPONENT_SIZE_GRID_MM)),
            int(round(z_span / CONTACT_COMPONENT_SIZE_GRID_MM)),
        )
        grouped.setdefault(key, []).append(component)

    repeated_groups: list[dict] = []
    for group in grouped.values():
        if len(group) < CONTACT_COMPONENT_MIN_REPETITIONS:
            continue

        edge_components = 0
        for component in group:
            center_x = (component["min_x"] + component["max_x"]) / 2.0
            center_y = (component["min_y"] + component["max_y"]) / 2.0
            if (
                center_x - model_min_x <= edge_band
                or model_max_x - center_x <= edge_band
                or center_y - model_min_y <= edge_band
                or model_max_y - center_y <= edge_band
            ):
                edge_components += 1

        edge_ratio = edge_components / len(group)
        if edge_ratio < CONTACT_COMPONENT_MIN_EDGE_RATIO:
            continue
        repeated_groups.append({"components": group, "edge_ratio": edge_ratio})

    if not repeated_groups:
        return None

    repeated_groups.sort(
        key=lambda group_info: (
            group_info["edge_ratio"],
            len(group_info["components"]),
            sum(len(component["points"]) for component in group_info["components"]),
            -min(component["min_z"] for component in group_info["components"]),
        ),
        reverse=True,
    )
    selected = repeated_groups[0]["components"]
    selected_points = [point for component in selected for point in component["points"]]
    contact_plane = transformed_model_contact_plane_z(selected_points, min_count_floor=4, max_count_fraction=0.2, total_count_fraction=0.02)
    if contact_plane is None:
        contact_plane = min(point[2] for point in selected_points)

    return {
        "contact_plane_z_mm": contact_plane,
        "method": "repeated_contact_components",
        "contact_component_repetitions": float(len(selected)),
    }


def transformed_vertex_components(geometry: dict, state: dict | None) -> list[dict]:
    vertices = geometry.get("vertices", {})
    if not vertices:
        return []

    adjacency: dict[int, set[int]] = {vertex_id: set() for vertex_id in vertices}
    for start_vertex, end_vertex, _curve_id, _same_sense in geometry.get("edges", {}).values():
        if start_vertex in adjacency and end_vertex in adjacency:
            adjacency[start_vertex].add(end_vertex)
            adjacency[end_vertex].add(start_vertex)

    components: list[dict] = []
    seen: set[int] = set()
    for vertex_id in vertices:
        if vertex_id in seen:
            continue
        stack = [vertex_id]
        seen.add(vertex_id)
        component_vertex_ids: list[int] = []
        while stack:
            current = stack.pop()
            component_vertex_ids.append(current)
            for neighbor in adjacency.get(current, set()):
                if neighbor not in seen:
                    seen.add(neighbor)
                    stack.append(neighbor)

        points = []
        for component_vertex_id in component_vertex_ids:
            point = point_for_vertex(geometry, component_vertex_id)
            if point is not None:
                points.append(transform_model_point(point, state))
        if not points:
            continue

        xs = [point[0] for point in points]
        ys = [point[1] for point in points]
        zs = [point[2] for point in points]
        components.append(
            {
                "points": points,
                "min_x": min(xs),
                "max_x": max(xs),
                "min_y": min(ys),
                "max_y": max(ys),
                "min_z": min(zs),
                "max_z": max(zs),
                "x_span": max(xs) - min(xs),
                "y_span": max(ys) - min(ys),
                "z_span": max(zs) - min(zs),
            }
        )

    return components


def transformed_model_contact_plane_z(
    transformed_points: list[tuple[float, float, float]],
    z_grid_mm: float = 0.001,
    min_count_floor: int = 8,
    max_count_fraction: float = 0.5,
    total_count_fraction: float = 0.08,
) -> float | None:
    if not transformed_points:
        return None

    z_counts: dict[float, int] = {}
    for point in transformed_points:
        z = round(point[2] / z_grid_mm) * z_grid_mm
        z = round(z, 6)
        z_counts[z] = z_counts.get(z, 0) + 1

    max_plane_count = max(z_counts.values())
    # The absolute minimum is often a sparse plastic/detail outlier. Use the
    # lowest dense Z plane as the real pad/contact plane. The plane can be
    # negative or positive depending on the STEP model's native origin.
    min_dense_count = max(
        min_count_floor,
        int(max_plane_count * max_count_fraction),
        int(len(transformed_points) * total_count_fraction),
    )
    dense_planes = [
        (z, count)
        for z, count in sorted(z_counts.items())
        if count >= min_dense_count
    ]
    if dense_planes:
        return dense_planes[0][0]

    return min(point[2] for point in transformed_points)


def aspect_ratio_for_bbox(bbox: tuple[float, float, float, float] | None) -> float | None:
    if bbox is None:
        return None

    width = abs(bbox[2] - bbox[0])
    height = abs(bbox[3] - bbox[1])
    if width <= 1e-9 or height <= 1e-9:
        return None

    return width / height


def aspect_error(source_aspect: float | None, target_aspect: float | None) -> float:
    if source_aspect is None or target_aspect is None:
        return 1e9
    return abs(math.log(source_aspect / target_aspect))


def projection_state_for_body(geometry: dict, model_state: dict | None, target_bbox: tuple[float, float, float, float], overall_height_mm: float) -> dict | None:
    if model_state is None or model_state.get("rotx") is None:
        return model_state

    current_extents = transformed_model_extents(geometry, model_state)
    if current_extents is None:
        return model_state

    current_height_extent = current_extents[2]
    height_threshold = max(overall_height_mm * HEIGHT_AXIS_MISMATCH_FACTOR, HEIGHT_AXIS_MISMATCH_MIN_MM)
    if normalize_rotation_degrees(float(model_state.get("rotx") or 0.0)) != 0.0:
        return model_state
    if current_height_extent <= height_threshold:
        return model_state

    target_aspect = aspect_ratio_for_bbox(target_bbox)
    base_rotz = float(model_state.get("rotz") or 0.0)
    rotation_candidates = [270.0, 90.0, 0.0, 180.0]
    candidates: list[tuple[float, float, float, dict]] = []

    for rotz_delta in rotation_candidates:
        candidate = dict(model_state)
        candidate["rotx"] = 90.0
        candidate["rotz"] = normalize_rotation_degrees(base_rotz + rotz_delta)
        candidate["_projection_axis_override"] = True
        extents = transformed_model_extents(geometry, candidate)
        if extents is None:
            continue

        height_error = abs(math.log((extents[2] + 1e-9) / (overall_height_mm + 1e-9)))
        projection = visible_edge_projection(geometry, candidate)
        source_aspect = aspect_ratio_for_bbox(projection.get("source_bbox"))
        projection_error = aspect_error(source_aspect, target_aspect)
        visible_segments = float(projection.get("stats", {}).get("visible_projected_segments", 0))
        candidates.append((height_error, projection_error, -visible_segments, candidate))

    if not candidates:
        return model_state

    return min(candidates, key=lambda item: (item[0], item[1], item[2]))[3]


def rotate_segments(
    segments: list[tuple[float, float, float, float]],
    target_bbox: tuple[float, float, float, float],
    angle_deg: float,
) -> list[tuple[float, float, float, float]]:
    angle_deg = normalize_rotation_degrees(angle_deg)
    if angle_deg == 0.0:
        return segments

    left, bottom, right, top = target_bbox
    center_x = (left + right) / 2.0
    center_y = (bottom + top) / 2.0
    radians = math.radians(angle_deg)
    cos_a = math.cos(radians)
    sin_a = math.sin(radians)

    def rotate_point(x: float, y: float) -> tuple[float, float]:
        dx = x - center_x
        dy = y - center_y
        return (
            center_x + dx * cos_a - dy * sin_a,
            center_y + dx * sin_a + dy * cos_a,
        )

    rotated: list[tuple[float, float, float, float]] = []
    for x1, y1, x2, y2 in segments:
        nx1, ny1 = rotate_point(x1, y1)
        nx2, ny2 = rotate_point(x2, y2)
        rotated.append((nx1, ny1, nx2, ny2))
    return rotated


def rounded_point(point: tuple[float, float]) -> tuple[float, float]:
    return (round(point[0], OUTPUT_COORD_DECIMALS), round(point[1], OUTPUT_COORD_DECIMALS))


def point_key(point: tuple[float, float]) -> tuple[int, int]:
    return (
        int(round(point[0] / OPTIMIZE_POINT_GRID_MM)),
        int(round(point[1] / OPTIMIZE_POINT_GRID_MM)),
    )


def point_from_key(key: tuple[int, int]) -> tuple[float, float]:
    return (key[0] * OPTIMIZE_POINT_GRID_MM, key[1] * OPTIMIZE_POINT_GRID_MM)


def segment_length(segment: tuple[float, float, float, float]) -> float:
    return math.hypot(segment[2] - segment[0], segment[3] - segment[1])


def canonical_segment_key(segment: tuple[float, float, float, float]) -> tuple[tuple[int, int], tuple[int, int]]:
    a = point_key((segment[0], segment[1]))
    b = point_key((segment[2], segment[3]))
    return tuple(sorted((a, b)))  # type: ignore[return-value]


def dedupe_segments(
    segments: list[tuple[float, float, float, float]],
) -> list[tuple[float, float, float, float]]:
    result: list[tuple[float, float, float, float]] = []
    seen: set[tuple[tuple[int, int], tuple[int, int]]] = set()
    for segment in segments:
        if segment_length(segment) < OUTPUT_MIN_LINE_LENGTH_MM:
            continue
        key = canonical_segment_key(segment)
        if key in seen:
            continue
        seen.add(key)
        result.append(segment)
    return result


def distance_point_to_line(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    length = math.hypot(dx, dy)
    if length <= 1e-12:
        return math.hypot(point[0] - start[0], point[1] - start[1])
    return abs((point[0] - start[0]) * dy - (point[1] - start[1]) * dx) / length


def points_are_collinear(points: list[tuple[float, float]], tolerance: float = COLLINEAR_DISTANCE_TOLERANCE_MM) -> bool:
    if len(points) <= 2:
        return True
    start = points[0]
    end = points[-1]
    if math.hypot(end[0] - start[0], end[1] - start[1]) < OUTPUT_MIN_LINE_LENGTH_MM:
        return False
    return all(distance_point_to_line(point, start, end) <= tolerance for point in points[1:-1])


def circle_from_points(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
) -> tuple[float, float, float] | None:
    ax, ay = a
    bx, by = b
    cx, cy = c
    determinant = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(determinant) <= 1e-9:
        return None

    a_sq = ax * ax + ay * ay
    b_sq = bx * bx + by * by
    c_sq = cx * cx + cy * cy
    center_x = (a_sq * (by - cy) + b_sq * (cy - ay) + c_sq * (ay - by)) / determinant
    center_y = (a_sq * (cx - bx) + b_sq * (ax - cx) + c_sq * (bx - ax)) / determinant
    radius = math.hypot(ax - center_x, ay - center_y)
    if radius <= OUTPUT_MIN_LINE_LENGTH_MM:
        return None
    return (center_x, center_y, radius)


def signed_angle_delta(start: float, end: float) -> float:
    return (end - start + math.pi) % (2.0 * math.pi) - math.pi


def fit_arc_to_points(points: list[tuple[float, float]]) -> dict | None:
    if len(points) < 4:
        return None
    if points_are_collinear(points):
        return None

    middle = points[len(points) // 2]
    circle = circle_from_points(points[0], middle, points[-1])
    if circle is None:
        return None

    center_x, center_y, radius = circle
    radial_errors = [
        abs(math.hypot(point[0] - center_x, point[1] - center_y) - radius)
        for point in points
    ]
    if max(radial_errors) > ARC_RADIAL_TOLERANCE_MM:
        return None

    angles = [math.atan2(point[1] - center_y, point[0] - center_x) for point in points]
    deltas = [signed_angle_delta(angles[index], angles[index + 1]) for index in range(len(angles) - 1)]
    nonzero_deltas = [delta for delta in deltas if abs(math.degrees(delta)) > 0.05]
    if not nonzero_deltas:
        return None

    positive = sum(1 for delta in nonzero_deltas if delta > 0)
    negative = sum(1 for delta in nonzero_deltas if delta < 0)
    if positive and negative:
        return None

    sweep = sum(nonzero_deltas)
    sweep_deg = abs(math.degrees(sweep))
    if sweep_deg < ARC_MIN_SWEEP_DEG or sweep_deg > ARC_MAX_SWEEP_DEG:
        return None

    if sweep > 0:
        start_angle = math.degrees(angles[0])
        end_angle = start_angle + sweep_deg
    else:
        start_angle = math.degrees(angles[-1])
        end_angle = start_angle + sweep_deg

    while start_angle < 0:
        start_angle += 360.0
        end_angle += 360.0
    while start_angle >= 360.0:
        start_angle -= 360.0
        end_angle -= 360.0

    point_bbox = bbox_for_points(points)
    arc_bbox = bbox_for_arc(center_x, center_y, radius, start_angle, end_angle)
    if (
        arc_bbox[0] < point_bbox[0] - ARC_BBOX_TOLERANCE_MM
        or arc_bbox[1] < point_bbox[1] - ARC_BBOX_TOLERANCE_MM
        or arc_bbox[2] > point_bbox[2] + ARC_BBOX_TOLERANCE_MM
        or arc_bbox[3] > point_bbox[3] + ARC_BBOX_TOLERANCE_MM
    ):
        return None

    return {
        "kind": "ARC",
        "cx": round(center_x, OUTPUT_COORD_DECIMALS),
        "cy": round(center_y, OUTPUT_COORD_DECIMALS),
        "r": round(radius, OUTPUT_COORD_DECIMALS),
        "start": round(start_angle, OUTPUT_COORD_DECIMALS),
        "end": round(end_angle, OUTPUT_COORD_DECIMALS),
    }


def bbox_for_points(points: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return (min(xs), min(ys), max(xs), max(ys))


def angle_in_arc_sweep(test_angle: float, start_angle: float, end_angle: float) -> bool:
    while test_angle < start_angle:
        test_angle += 360.0
    return start_angle <= test_angle <= end_angle


def bbox_for_arc(
    center_x: float,
    center_y: float,
    radius: float,
    start_angle: float,
    end_angle: float,
) -> tuple[float, float, float, float]:
    angles = [start_angle, end_angle]
    for cardinal_angle in (0.0, 90.0, 180.0, 270.0, 360.0, 450.0, 540.0, 630.0, 720.0):
        if angle_in_arc_sweep(cardinal_angle, start_angle, end_angle):
            angles.append(cardinal_angle)
    points = [
        (
            center_x + radius * math.cos(math.radians(angle)),
            center_y + radius * math.sin(math.radians(angle)),
        )
        for angle in angles
    ]
    return bbox_for_points(points)


def trace_segment_paths(
    segments: list[tuple[float, float, float, float]],
) -> list[list[tuple[float, float]]]:
    edge_keys: list[tuple[tuple[int, int], tuple[int, int]]] = []
    graph: dict[tuple[int, int], list[int]] = {}
    for segment in segments:
        a = point_key((segment[0], segment[1]))
        b = point_key((segment[2], segment[3]))
        if a == b:
            continue
        edge_index = len(edge_keys)
        edge_keys.append((a, b))
        graph.setdefault(a, []).append(edge_index)
        graph.setdefault(b, []).append(edge_index)

    unvisited = set(range(len(edge_keys)))

    def follow(start_edge: int, start_node: tuple[int, int]) -> list[tuple[float, float]]:
        nodes = [start_node]
        current_node = start_node
        edge_index = start_edge
        while edge_index in unvisited:
            unvisited.remove(edge_index)
            a, b = edge_keys[edge_index]
            next_node = b if current_node == a else a
            nodes.append(next_node)
            candidates = [candidate for candidate in graph.get(next_node, []) if candidate in unvisited]
            if len(candidates) != 1 or len(graph.get(next_node, [])) != 2:
                break
            current_node = next_node
            edge_index = candidates[0]
        return [rounded_point(point_from_key(node)) for node in nodes]

    paths: list[list[tuple[float, float]]] = []
    for edge_index, (a, b) in enumerate(edge_keys):
        if edge_index not in unvisited:
            continue
        if len(graph.get(a, [])) != 2:
            paths.append(follow(edge_index, a))
        elif len(graph.get(b, [])) != 2:
            paths.append(follow(edge_index, b))

    while unvisited:
        edge_index = next(iter(unvisited))
        a, _b = edge_keys[edge_index]
        paths.append(follow(edge_index, a))

    return [path for path in paths if len(path) >= 2]


def line_primitive(start: tuple[float, float], end: tuple[float, float]) -> dict | None:
    if math.hypot(end[0] - start[0], end[1] - start[1]) < OUTPUT_MIN_LINE_LENGTH_MM:
        return None
    return {
        "kind": "LINE",
        "x1": round(start[0], OUTPUT_COORD_DECIMALS),
        "y1": round(start[1], OUTPUT_COORD_DECIMALS),
        "x2": round(end[0], OUTPUT_COORD_DECIMALS),
        "y2": round(end[1], OUTPUT_COORD_DECIMALS),
    }


def rdp_simplify(points: list[tuple[float, float]], tolerance: float) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points
    start = points[0]
    end = points[-1]
    max_distance = -1.0
    split_index = 0
    for index, point in enumerate(points[1:-1], start=1):
        distance = distance_point_to_line(point, start, end)
        if distance > max_distance:
            max_distance = distance
            split_index = index
    if max_distance <= tolerance:
        return [start, end]
    left = rdp_simplify(points[: split_index + 1], tolerance)
    right = rdp_simplify(points[split_index:], tolerance)
    return left[:-1] + right


def primitives_from_path(path: list[tuple[float, float]]) -> list[dict]:
    if len(path) < 2:
        return []
    if points_are_collinear(path):
        primitive = line_primitive(path[0], path[-1])
        return [primitive] if primitive is not None else []

    arc = fit_arc_to_points(path)
    if arc is not None:
        return [arc]

    simplified = rdp_simplify(path, COLLINEAR_DISTANCE_TOLERANCE_MM)
    result: list[dict] = []
    for index in range(len(simplified) - 1):
        primitive = line_primitive(simplified[index], simplified[index + 1])
        if primitive is not None:
            result.append(primitive)
    return result


def merge_line_primitives(primitives: list[dict]) -> list[dict]:
    groups: dict[tuple[int, int], list[tuple[float, float, float, float, float, float]]] = {}
    passthrough: list[dict] = []
    for primitive in primitives:
        if primitive.get("kind") != "LINE":
            passthrough.append(primitive)
            continue

        x1 = float(primitive["x1"])
        y1 = float(primitive["y1"])
        x2 = float(primitive["x2"])
        y2 = float(primitive["y2"])
        dx = x2 - x1
        dy = y2 - y1
        length = math.hypot(dx, dy)
        if length < OUTPUT_MIN_LINE_LENGTH_MM:
            continue

        ux = dx / length
        uy = dy / length
        if ux < -1e-12 or (abs(ux) <= 1e-12 and uy < 0):
            ux = -ux
            uy = -uy
        normal_x = -uy
        normal_y = ux
        offset = normal_x * x1 + normal_y * y1
        angle = math.atan2(uy, ux)
        key = (int(round(angle / 0.001)), int(round(offset / COLLINEAR_DISTANCE_TOLERANCE_MM)))
        t1 = ux * x1 + uy * y1
        t2 = ux * x2 + uy * y2
        groups.setdefault(key, []).append((min(t1, t2), max(t1, t2), ux, uy, normal_x, normal_y, offset))

    merged: list[dict] = []
    for intervals in groups.values():
        intervals.sort(key=lambda item: item[0])
        current_start, current_end, ux, uy, normal_x, normal_y, offset = intervals[0]
        for start, end, *_rest in intervals[1:]:
            if start <= current_end + COLLINEAR_GAP_TOLERANCE_MM:
                current_end = max(current_end, end)
                continue
            primitive = line_primitive(
                (ux * current_start + normal_x * offset, uy * current_start + normal_y * offset),
                (ux * current_end + normal_x * offset, uy * current_end + normal_y * offset),
            )
            if primitive is not None:
                merged.append(primitive)
            current_start, current_end = start, end

        primitive = line_primitive(
            (ux * current_start + normal_x * offset, uy * current_start + normal_y * offset),
            (ux * current_end + normal_x * offset, uy * current_end + normal_y * offset),
        )
        if primitive is not None:
            merged.append(primitive)

    return passthrough + merged


def merge_arc_primitives(primitives: list[dict]) -> list[dict]:
    groups: dict[tuple[int, int, int], list[tuple[float, float]]] = {}
    passthrough: list[dict] = []
    by_key_values: dict[tuple[int, int, int], tuple[float, float, float]] = {}
    for primitive in primitives:
        if primitive.get("kind") != "ARC":
            passthrough.append(primitive)
            continue
        cx = float(primitive["cx"])
        cy = float(primitive["cy"])
        radius = float(primitive["r"])
        start = float(primitive["start"])
        end = float(primitive["end"])
        if end < start:
            end += 360.0
        if end - start < ARC_MIN_SWEEP_DEG:
            continue
        key = (
            int(round(cx / COLLINEAR_DISTANCE_TOLERANCE_MM)),
            int(round(cy / COLLINEAR_DISTANCE_TOLERANCE_MM)),
            int(round(radius / COLLINEAR_DISTANCE_TOLERANCE_MM)),
        )
        by_key_values.setdefault(key, (cx, cy, radius))
        groups.setdefault(key, []).append((start, end))

    merged: list[dict] = []
    for key, intervals in groups.items():
        cx, cy, radius = by_key_values[key]
        intervals.sort(key=lambda item: item[0])
        current_start, current_end = intervals[0]
        for start, end in intervals[1:]:
            if start <= current_end + ARC_MERGE_ANGLE_TOLERANCE_DEG:
                current_end = max(current_end, end)
                continue
            merged.append(
                {
                    "kind": "ARC",
                    "cx": round(cx, OUTPUT_COORD_DECIMALS),
                    "cy": round(cy, OUTPUT_COORD_DECIMALS),
                    "r": round(radius, OUTPUT_COORD_DECIMALS),
                    "start": round(current_start, OUTPUT_COORD_DECIMALS),
                    "end": round(current_end, OUTPUT_COORD_DECIMALS),
                }
            )
            current_start, current_end = start, end

        merged.append(
            {
                "kind": "ARC",
                "cx": round(cx, OUTPUT_COORD_DECIMALS),
                "cy": round(cy, OUTPUT_COORD_DECIMALS),
                "r": round(radius, OUTPUT_COORD_DECIMALS),
                "start": round(current_start, OUTPUT_COORD_DECIMALS),
                "end": round(current_end, OUTPUT_COORD_DECIMALS),
            }
        )

    return passthrough + merged


def primitive_arc_sweep_degrees(primitive: dict) -> float:
    start = float(primitive["start"])
    end = float(primitive["end"])
    while end < start:
        end += 360.0
    return end - start


def primitive_length(primitive: dict) -> float:
    if primitive.get("kind") == "LINE":
        return math.hypot(
            float(primitive["x2"]) - float(primitive["x1"]),
            float(primitive["y2"]) - float(primitive["y1"]),
        )
    if primitive.get("kind") == "ARC":
        return float(primitive["r"]) * math.radians(primitive_arc_sweep_degrees(primitive))
    return 0.0


def arc_endpoint(primitive: dict, angle_degrees: float) -> tuple[float, float]:
    radius = float(primitive["r"])
    angle = math.radians(angle_degrees)
    return (
        float(primitive["cx"]) + radius * math.cos(angle),
        float(primitive["cy"]) + radius * math.sin(angle),
    )


def distance_point_to_segment(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    length_sq = dx * dx + dy * dy
    if length_sq <= 1e-12:
        return math.hypot(point[0] - start[0], point[1] - start[1])
    projection = ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length_sq
    projection = max(0.0, min(1.0, projection))
    closest = (start[0] + projection * dx, start[1] + projection * dy)
    return math.hypot(point[0] - closest[0], point[1] - closest[1])


def distance_point_to_arc(point: tuple[float, float], primitive: dict) -> float:
    center = (float(primitive["cx"]), float(primitive["cy"]))
    radius = float(primitive["r"])
    start = float(primitive["start"])
    end = float(primitive["end"])
    point_angle = math.degrees(math.atan2(point[1] - center[1], point[0] - center[0]))
    while point_angle < 0:
        point_angle += 360.0

    if angle_in_arc_sweep(point_angle, start, end):
        return abs(math.hypot(point[0] - center[0], point[1] - center[1]) - radius)

    return min(
        math.hypot(point[0] - arc_endpoint(primitive, start)[0], point[1] - arc_endpoint(primitive, start)[1]),
        math.hypot(point[0] - arc_endpoint(primitive, end)[0], point[1] - arc_endpoint(primitive, end)[1]),
    )


def distance_point_to_primitive(point: tuple[float, float], primitive: dict) -> float:
    if primitive.get("kind") == "LINE":
        return distance_point_to_segment(
            point,
            (float(primitive["x1"]), float(primitive["y1"])),
            (float(primitive["x2"]), float(primitive["y2"])),
        )
    if primitive.get("kind") == "ARC":
        return distance_point_to_arc(point, primitive)
    return float("inf")


def primitive_sample_points(primitive: dict, step_mm: float) -> list[tuple[float, float]]:
    length = primitive_length(primitive)
    sample_count = max(2, min(64, int(math.ceil(length / step_mm)) + 1))

    if primitive.get("kind") == "LINE":
        x1 = float(primitive["x1"])
        y1 = float(primitive["y1"])
        x2 = float(primitive["x2"])
        y2 = float(primitive["y2"])
        return [
            (
                x1 + (x2 - x1) * index / (sample_count - 1),
                y1 + (y2 - y1) * index / (sample_count - 1),
            )
            for index in range(sample_count)
        ]

    if primitive.get("kind") == "ARC":
        start = float(primitive["start"])
        sweep = primitive_arc_sweep_degrees(primitive)
        return [
            arc_endpoint(primitive, start + sweep * index / (sample_count - 1))
            for index in range(sample_count)
        ]

    return []


def primitive_is_stroke_covered(candidate: dict, cover: dict, tolerance_mm: float, sample_step_mm: float) -> bool:
    samples = primitive_sample_points(candidate, sample_step_mm)
    if not samples:
        return False
    return all(distance_point_to_primitive(point, cover) <= tolerance_mm for point in samples)


def remove_small_visible_primitives(primitives: list[dict]) -> tuple[list[dict], dict[str, int]]:
    min_line_length = PROJECTION_LINE_WIDTH_MM * MIN_VISIBLE_LINE_LENGTH_FACTOR
    min_arc_length = PROJECTION_LINE_WIDTH_MM * MIN_VISIBLE_ARC_LENGTH_FACTOR
    min_arc_radius = PROJECTION_LINE_WIDTH_MM * MIN_VISIBLE_ARC_RADIUS_FACTOR
    result: list[dict] = []
    stats = {
        "short_lines_removed": 0,
        "short_arcs_removed": 0,
        "small_radius_arcs_removed": 0,
    }

    for primitive in primitives:
        length = primitive_length(primitive)
        if primitive.get("kind") == "LINE" and length < min_line_length:
            stats["short_lines_removed"] += 1
            continue
        if primitive.get("kind") == "ARC":
            if length < min_arc_length:
                stats["short_arcs_removed"] += 1
                continue
            if float(primitive["r"]) < min_arc_radius:
                stats["small_radius_arcs_removed"] += 1
                continue
        result.append(primitive)

    return result, stats


def remove_stroke_covered_primitives(primitives: list[dict]) -> tuple[list[dict], dict[str, int]]:
    max_candidate_length = PROJECTION_LINE_WIDTH_MM * STROKE_COVERAGE_MAX_LENGTH_FACTOR
    coverage_tolerance = PROJECTION_LINE_WIDTH_MM * STROKE_COVERAGE_DISTANCE_FACTOR
    sample_step = max(PROJECTION_LINE_WIDTH_MM * STROKE_COVERAGE_SAMPLE_STEP_FACTOR, OPTIMIZE_POINT_GRID_MM)
    lengths = [primitive_length(primitive) for primitive in primitives]
    result: list[dict] = []
    stats = {
        "stroke_covered_lines_removed": 0,
        "stroke_covered_arcs_removed": 0,
    }

    for index, primitive in enumerate(primitives):
        length = lengths[index]
        covered = False
        if length <= max_candidate_length:
            for other_index, other in enumerate(primitives):
                if other_index == index:
                    continue
                other_length = lengths[other_index]
                if other_length < length - POINT_EPSILON_MM:
                    continue
                if abs(other_length - length) <= POINT_EPSILON_MM and other_index > index:
                    continue
                if primitive_is_stroke_covered(primitive, other, coverage_tolerance, sample_step):
                    covered = True
                    break

        if covered:
            if primitive.get("kind") == "ARC":
                stats["stroke_covered_arcs_removed"] += 1
            else:
                stats["stroke_covered_lines_removed"] += 1
            continue

        result.append(primitive)

    return result, stats


def line_gap_bridge_key(primitive: dict) -> tuple[str, int] | None:
    if primitive.get("kind") != "LINE":
        return None

    x1 = float(primitive["x1"])
    y1 = float(primitive["y1"])
    x2 = float(primitive["x2"])
    y2 = float(primitive["y2"])
    if abs(x1 - x2) <= POINT_EPSILON_MM:
        return ("V", int(round(x1 / OPTIMIZE_POINT_GRID_MM)))
    if abs(y1 - y2) <= POINT_EPSILON_MM:
        return ("H", int(round(y1 / OPTIMIZE_POINT_GRID_MM)))
    return None


def add_line_gap_bridges(primitives: list[dict]) -> tuple[list[dict], int]:
    max_gap = PROJECTION_LINE_WIDTH_MM * LINE_GAP_BRIDGE_MAX_FACTOR
    grouped: dict[tuple[str, int], list[tuple[float, float, float, dict]]] = {}
    for primitive in primitives:
        key = line_gap_bridge_key(primitive)
        if key is None:
            continue

        if key[0] == "V":
            a = float(primitive["y1"])
            b = float(primitive["y2"])
        else:
            a = float(primitive["x1"])
            b = float(primitive["x2"])
        start = min(a, b)
        end = max(a, b)
        grouped.setdefault(key, []).append((start, end, end - start, primitive))

    bridged = list(primitives)
    existing_keys: set[tuple[tuple[int, int], tuple[int, int]]] = set()
    for primitive in primitives:
        if primitive.get("kind") == "LINE":
            existing_keys.add(
                canonical_segment_key(
                    (
                        float(primitive["x1"]),
                        float(primitive["y1"]),
                        float(primitive["x2"]),
                        float(primitive["y2"]),
                    )
                )
            )

    bridges_created = 0
    for key, spans in grouped.items():
        spans.sort(key=lambda item: (item[0], item[1]))
        axis, fixed_key = key
        fixed = fixed_key * OPTIMIZE_POINT_GRID_MM
        for index in range(len(spans) - 1):
            _current_start, current_end, current_length, _current_primitive = spans[index]
            next_start, _next_end, next_length, _next_primitive = spans[index + 1]
            gap = next_start - current_end
            if gap <= POINT_EPSILON_MM or gap > max_gap + POINT_EPSILON_MM:
                continue
            if gap > max(current_length, next_length) + POINT_EPSILON_MM:
                continue

            if axis == "V":
                bridge = {
                    "kind": "LINE",
                    "x1": fixed,
                    "y1": current_end,
                    "x2": fixed,
                    "y2": next_start,
                }
            else:
                bridge = {
                    "kind": "LINE",
                    "x1": current_end,
                    "y1": fixed,
                    "x2": next_start,
                    "y2": fixed,
                }

            bridge_key = canonical_segment_key(
                (
                    float(bridge["x1"]),
                    float(bridge["y1"]),
                    float(bridge["x2"]),
                    float(bridge["y2"]),
                )
            )
            if bridge_key in existing_keys:
                continue

            existing_keys.add(bridge_key)
            bridged.append(bridge)
            bridges_created += 1

    return bridged, bridges_created


def optimize_segments_to_primitives(
    segments: list[tuple[float, float, float, float]],
) -> tuple[list[dict], dict]:
    deduped = dedupe_segments(segments)
    paths = trace_segment_paths(deduped)
    primitives: list[dict] = []
    for path in paths:
        primitives.extend(primitives_from_path(path))
    primitives = merge_line_primitives(primitives)
    primitives = merge_arc_primitives(primitives)
    pre_prune_primitive_count = len(primitives)
    primitives, small_visible_stats = remove_small_visible_primitives(primitives)
    primitives, stroke_coverage_stats = remove_stroke_covered_primitives(primitives)
    primitives, line_gap_bridges_created = add_line_gap_bridges(primitives)

    line_keys: set[tuple[tuple[int, int], tuple[int, int]]] = set()
    arc_keys: set[tuple[int, int, int, int, int]] = set()
    result: list[dict] = []
    for primitive in primitives:
        if primitive.get("kind") == "LINE":
            key = canonical_segment_key(
                (
                    float(primitive["x1"]),
                    float(primitive["y1"]),
                    float(primitive["x2"]),
                    float(primitive["y2"]),
                )
            )
            if key in line_keys:
                continue
            line_keys.add(key)
        elif primitive.get("kind") == "ARC":
            key = (
                int(round(float(primitive["cx"]) * 1000)),
                int(round(float(primitive["cy"]) * 1000)),
                int(round(float(primitive["r"]) * 1000)),
                int(round(float(primitive["start"]) * 1000)),
                int(round(float(primitive["end"]) * 1000)),
            )
            if key in arc_keys:
                continue
            arc_keys.add(key)
        result.append(primitive)

    return result, {
        "input_segments": len(segments),
        "deduped_segments": len(deduped),
        "paths": len(paths),
        "pre_prune_primitives": pre_prune_primitive_count,
        "projection_line_width_mm": PROJECTION_LINE_WIDTH_MM,
        "optimized_primitives": len(result),
        "optimized_lines": sum(1 for primitive in result if primitive.get("kind") == "LINE"),
        "optimized_arcs": sum(1 for primitive in result if primitive.get("kind") == "ARC"),
        **small_visible_stats,
        **stroke_coverage_stats,
        "line_gap_bridges_created": line_gap_bridges_created,
    }


def primitive_record(footprint: str, primitive: dict) -> str:
    if primitive["kind"] == "ARC":
        return (
            f"{footprint}|ARC|{primitive['cx']:.3f}|{primitive['cy']:.3f}|"
            f"{primitive['r']:.3f}|{primitive['start']:.3f}|{primitive['end']:.3f}"
        )
    return (
        f"{footprint}|LINE|{primitive['x1']:.3f}|{primitive['y1']:.3f}|"
        f"{primitive['x2']:.3f}|{primitive['y2']:.3f}"
    )


def footprint_name_matches(stem: str, footprint: str) -> bool:
    footprint_upper = footprint.upper()
    stem_upper = stem.upper()
    if stem_upper == footprint_upper:
        return True

    if footprint_upper.startswith(stem_upper + "-") or footprint_upper.startswith(stem_upper + "_"):
        return True

    return re.search(rf"(^|[^A-Z0-9]){re.escape(footprint_upper)}($|[^A-Z0-9])", stem_upper) is not None


def footprint_family_contact_key(footprint: str) -> str | None:
    match = re.match(r"^(?P<prefix>.+?)-(?P<count>\d+)(?P<role>[A-Z]{1,4})(?P<suffix>[-_].*)?$", footprint)
    if not match:
        return None
    suffix = match.group("suffix") or ""
    prefix = re.sub(r"\([^)]+\)$", "", match.group("prefix"))
    return f"{prefix}|{match.group('role')}|{suffix}"


def apply_family_contact_z_consensus(optimization_stats: dict[str, dict]) -> None:
    groups: dict[tuple[str, float], list[tuple[str, dict]]] = {}
    family_records: dict[str, list[tuple[float, float, dict]]] = {}
    for footprint, stats in optimization_stats.items():
        if stats.get("computed_contact_plane_method") != "repeated_contact_components":
            continue
        family_key = stats.get("computed_contact_family_key")
        if not family_key:
            continue
        overall_height = float(stats.get("computed_overall_height_mm") or 0.0)
        body_overall_height = float(stats.get("computed_body_overall_height_mm") or overall_height)
        group_height = round(max(overall_height, body_overall_height), 3)
        groups.setdefault((str(family_key), group_height), []).append((footprint, stats))
        raw_z = stats.get("computed_model_z_mm_raw", stats.get("computed_model_z_mm"))
        if raw_z is not None:
            family_records.setdefault(str(family_key), []).append((group_height, float(raw_z), stats))

    family_offsets: dict[str, float] = {}
    for family_key, records in family_records.items():
        offset_counts: dict[float, int] = {}
        for group_height, raw_z, _stats in records:
            if abs(raw_z) > group_height + CONTACT_COMPONENT_ORIGIN_SHIFT_MARGIN_MM:
                continue
            offset = round(group_height - raw_z, 3)
            offset_counts[offset] = offset_counts.get(offset, 0) + 1
        if not offset_counts:
            continue
        best_offset, best_count = max(offset_counts.items(), key=lambda item: (item[1], -abs(item[0])))
        if best_count >= 3:
            family_offsets[family_key] = best_offset

    for (_family_key, group_height), records in groups.items():
        if len(records) < 3:
            continue

        family_offset = family_offsets.get(_family_key)
        plausible: list[float] = []
        for _footprint, stats in records:
            model_z = stats.get("computed_model_z_mm_raw", stats.get("computed_model_z_mm"))
            if model_z is None:
                continue
            model_z = float(model_z)
            if abs(model_z) <= group_height + CONTACT_COMPONENT_ORIGIN_SHIFT_MARGIN_MM:
                plausible.append(model_z)
        if len(plausible) < 2 and family_offset is None:
            continue

        consensus_z = round(group_height - family_offset, 6) if family_offset is not None else round(max(plausible), 6)
        highest_plausible_z = round(max(plausible), 6) if plausible else None
        for _footprint, stats in records:
            raw_z = stats.get("computed_model_z_mm_raw", stats.get("computed_model_z_mm"))
            if raw_z is None:
                continue
            raw_z = float(raw_z)
            if abs(raw_z) > group_height + CONTACT_COMPONENT_ORIGIN_SHIFT_MARGIN_MM:
                stats["computed_model_z_source"] = "component_contact_shifted_origin"
                continue
            if highest_plausible_z is not None and abs(raw_z - highest_plausible_z) <= 0.001:
                if consensus_z - raw_z >= CONTACT_COMPONENT_HIGH_PLANE_NUDGE_MIN_DELTA_MM:
                    nudged_z = round(
                        raw_z + (consensus_z - raw_z) * CONTACT_COMPONENT_HIGH_PLANE_NUDGE_FRACTION,
                        6,
                    )
                    stats["computed_model_z_mm"] = nudged_z
                    stats["computed_z_offset_mm"] = nudged_z
                    stats["computed_standoff_height_mm"] = nudged_z
                    stats["computed_model_z_source"] = "component_contact_group_high_plane_nudged"
                else:
                    stats["computed_model_z_source"] = "component_contact_group_high_plane"
                continue
            if abs(raw_z - consensus_z) <= 0.001:
                stats["computed_model_z_source"] = "component_contact"
                continue
            stats["computed_model_z_mm"] = consensus_z
            stats["computed_z_offset_mm"] = consensus_z
            stats["computed_standoff_height_mm"] = consensus_z
            stats["computed_model_z_source"] = "family_contact_consensus"


def embedded_model_path(footprint: str, model_dir: Path, model_name: str | None = None) -> Path | None:
    if model_name:
        model_name_key = normalize_model_name(model_name)
        model_name_matches = [
            path
            for path in model_dir.rglob("*")
            if path.is_file()
            and path.suffix.lower() in STEP_EXTENSIONS
            and normalize_model_name(path.name) == model_name_key
        ]
        if model_name_matches:
            return sorted(model_name_matches, key=lambda path: (len(path.stem), str(path).upper()))[0]

    footprint_matches = [
        path
        for path in model_dir.rglob("*")
        if path.is_file() and path.suffix.lower() in STEP_EXTENSIONS and footprint_name_matches(path.stem, footprint)
    ]
    if not footprint_matches:
        return None
    return sorted(footprint_matches, key=lambda path: (len(path.stem), str(path).upper()))[0]


def load_response_data(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    result = data.get("result", data)
    return result if isinstance(result, dict) else {}


def load_body_data(path: Path) -> list[dict]:
    return list(load_response_data(path).get("bodies", []))


def main() -> int:
    response_file = Path(sys.argv[1]) if len(sys.argv) > 1 else RESPONSE_FILE
    output_file = Path(sys.argv[2]) if len(sys.argv) > 2 else OUTPUT_FILE
    model_dir = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_EMBEDDED_MODEL_DIR
    library_path_arg = Path(sys.argv[4]) if len(sys.argv) > 4 else None

    response_data = load_response_data(response_file)
    bodies = list(response_data.get("bodies", []))
    library_path_text = str(response_data.get("library_path", "")).strip()
    library_path = library_path_arg or (Path(library_path_text) if library_path_text else None)
    model_states = load_pcb_library_model_states(library_path)

    model_cache: dict[Path, dict] = {}
    lines: list[str] = []
    used_models: dict[str, str] = {}
    skipped: dict[str, str] = {}
    normalized_bboxes: dict[str, dict[str, list[float]]] = {}
    model_rotation_metadata: dict[str, dict[str, float | str | None]] = {}
    missing_rotation_metadata: list[str] = []
    hidden_line_stats: dict[str, dict] = {}
    optimization_stats: dict[str, dict] = {}

    for body in bodies:
        footprint = str(body["footprint"])
        footprint_model_state = model_state_for_footprint(model_states, footprint)
        expected_model_name = (
            str(footprint_model_state["model_name"])
            if footprint_model_state is not None and footprint_model_state.get("model_name")
            else None
        )
        model_path = embedded_model_path(footprint, model_dir, expected_model_name)
        if model_path is None:
            skipped[footprint] = f"exact embedded STEP model not found in {model_dir}"
            continue

        if model_path not in model_cache:
            model_cache[model_path] = parse_step_geometry(model_path)

        target_bbox = (
            float(body["left_mm"]),
            float(body["bottom_mm"]),
            float(body["right_mm"]),
            float(body["top_mm"]),
        )
        normalized_bbox, was_normalized = normalize_target_bbox(target_bbox)
        if was_normalized:
            normalized_bboxes[footprint] = {
                "reported": [round(value, 5) for value in target_bbox],
                "used": [round(value, 5) for value in normalized_bbox],
            }

        model_state = model_state_for_body(model_states, footprint, model_path) or footprint_model_state
        if model_state is None:
            missing_rotation_metadata.append(footprint)

        projection_model_state = projection_state_for_body(
            model_cache[model_path],
            model_state,
            normalized_bbox,
            float(body.get("overall_height_mm") or 0.0),
        )
        projection_rotation_deg = projection_rotation_from_model_state(projection_model_state)
        if projection_model_state is not None:
            model_rotation_metadata[footprint] = {
                "projection_rotation_deg": round(projection_rotation_deg, 6),
                "model_3d_rotx_deg": round(float(model_state["rotx"]), 6) if model_state and model_state.get("rotx") is not None else None,
                "model_3d_roty_deg": round(float(model_state["roty"]), 6) if model_state and model_state.get("roty") is not None else None,
                "model_3d_rotz_deg": round(float(model_state["rotz"]), 6) if model_state else None,
                "model_2d_rotation_deg": round(float(model_state.get("rotation_2d") or 0.0), 6) if model_state else None,
                "projection_rotx_deg": round(float(projection_model_state["rotx"]), 6) if projection_model_state.get("rotx") is not None else None,
                "projection_rotz_deg": round(float(projection_model_state["rotz"]), 6) if projection_model_state.get("rotz") is not None else None,
                "projection_state_overridden": projection_model_state != model_state,
                "projection_axis_override": bool(projection_model_state.get("_projection_axis_override")),
                "model_name": str(projection_model_state["model_name"]),
            }

        projection = visible_edge_projection(model_cache[model_path], projection_model_state)
        source_segments = projection["segments"]
        source_bbox = projection["source_bbox"]
        hidden_line_stats[footprint] = projection["stats"]
        if not source_segments or source_bbox is None:
            skipped[footprint] = "no visible projected STEP edges"
            continue

        placement_rotation_deg = normalize_rotation_degrees(
            projection_rotation_deg + ALTIUM_TOP_PROJECTION_ROTATION_CORRECTION_DEG
        )
        scaled = place_segments_without_rescale(
            source_segments,
            normalized_bbox,
            source_bbox,
            placement_rotation_deg,
        )
        if not scaled:
            skipped[footprint] = "no scaled segments"
            continue

        primitives, footprint_optimization_stats = optimize_segments_to_primitives(scaled)
        footprint_optimization_stats["placement_rotation_deg"] = round(placement_rotation_deg, 6)
        footprint_optimization_stats["placement_preserves_step_scale"] = True
        height_state = transformed_model_height_state(model_cache[model_path], projection_model_state)
        if height_state is not None:
            footprint_optimization_stats["computed_z_offset_mm"] = round(height_state["standoff_height_mm"], 6)
            footprint_optimization_stats["computed_model_z_mm"] = round(height_state["standoff_height_mm"], 6)
            footprint_optimization_stats["computed_model_z_mm_raw"] = round(height_state["standoff_height_mm"], 6)
            footprint_optimization_stats["computed_body_standoff_height_mm"] = 0.0
            footprint_optimization_stats["computed_body_overall_height_mm"] = round(float(body.get("overall_height_mm") or 0.0), 6)
            footprint_optimization_stats["computed_standoff_height_mm"] = round(height_state["standoff_height_mm"], 6)
            footprint_optimization_stats["computed_contact_plane_z_mm"] = round(height_state["contact_plane_z_mm"], 6)
            footprint_optimization_stats["computed_contact_plane_method"] = height_state["contact_plane_method"]
            footprint_optimization_stats["computed_contact_family_key"] = footprint_family_contact_key(footprint)
            footprint_optimization_stats["computed_model_z_source"] = "component_contact"
            footprint_optimization_stats["computed_absolute_min_standoff_height_mm"] = round(height_state["absolute_min_standoff_height_mm"], 6)
            footprint_optimization_stats["computed_overall_height_mm"] = round(height_state["overall_height_mm"], 6)
            if "contact_component_repetitions" in height_state:
                footprint_optimization_stats["computed_contact_component_repetitions"] = int(height_state["contact_component_repetitions"])
        optimization_stats[footprint] = footprint_optimization_stats
        if not primitives:
            skipped[footprint] = "no optimized primitives"
            continue

        used_models[footprint] = str(model_path)
        for primitive in primitives:
            lines.append(primitive_record(footprint, primitive))

    apply_family_contact_z_consensus(optimization_stats)

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {
                "output_file": str(output_file),
                "footprints": len(used_models),
                "segments": len(lines),
                "used_models": used_models,
                "skipped": skipped,
                "normalized_bboxes": normalized_bboxes,
                "library_path": str(library_path) if library_path is not None else None,
                "model_rotation_metadata": model_rotation_metadata,
                "hidden_line_stats": hidden_line_stats,
                "optimization_stats": optimization_stats,
                "missing_rotation_metadata": missing_rotation_metadata,
            },
            indent=2,
        )
    )
    return 0 if lines else 1


if __name__ == "__main__":
    raise SystemExit(main())
