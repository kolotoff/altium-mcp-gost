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
ROTATION_EPSILON_DEG = 1e-6
FACE_VISIBLE_EPSILON = 1e-6
COPLANAR_FACE_DOT = 0.9999
OCCLUSION_EPSILON_MM = 0.01
POINT_EPSILON_MM = 1e-5


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

            if occluder_faces is not None and segment_is_occluded(p1, p2, occluder_faces, adjacent_face_ids):
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
) -> bool:
    midpoint = ((p1[0] + p2[0]) / 2.0, (p1[1] + p2[1]) / 2.0)
    segment_height = (p1[2] + p2[2]) / 2.0

    for face_info in face_infos:
        if face_info["face_id"] in adjacent_face_ids:
            continue
        if not face_contains_point(face_info, midpoint):
            continue
        face_height = face_height_at(face_info, midpoint[0], midpoint[1])
        if face_height is not None and face_height > segment_height + OCCLUSION_EPSILON_MM:
            return True
    return False


def visible_edge_projection(geometry: dict, state: dict | None) -> dict:
    all_edge_ids = sorted(geometry["edges"])
    all_segments, _occluded = projected_segments_for_edges(geometry, state, all_edge_ids)
    if not all_segments:
        return {
            "segments": [],
            "source_bbox": None,
            "stats": {"all_edges": len(all_edge_ids), "visible_edges": 0, "fallback_all_edges": False},
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

        if normal[2] <= FACE_VISIBLE_EPSILON:
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
    )

    fallback_all_edges = False
    if not visible_segments:
        visible_segments = all_segments
        fallback_all_edges = True

    return {
        "segments": visible_segments,
        "source_bbox": source_bbox,
        "stats": {
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
    rotation_2d = state.get("rotation_2d") or 0.0
    return normalize_rotation_degrees(ALTIUM_TOP_PROJECTION_Z_BASELINE_DEG - float(rotz) + float(rotation_2d))


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


def footprint_name_matches(stem: str, footprint: str) -> bool:
    footprint_upper = footprint.upper()
    stem_upper = stem.upper()
    if stem_upper == footprint_upper:
        return True

    return re.search(rf"(^|[^A-Z0-9]){re.escape(footprint_upper)}($|[^A-Z0-9])", stem_upper) is not None


def embedded_model_path(footprint: str, model_dir: Path) -> Path | None:
    matches = [
        path
        for path in model_dir.rglob("*")
        if path.is_file() and path.suffix.lower() in STEP_EXTENSIONS and footprint_name_matches(path.stem, footprint)
    ]
    if not matches:
        return None
    return sorted(matches, key=lambda path: (len(path.stem), str(path).upper()))[0]


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

    for body in bodies:
        footprint = str(body["footprint"])
        model_path = embedded_model_path(footprint, model_dir)
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

        model_state = model_state_for_body(model_states, footprint, model_path)
        if model_state is None:
            missing_rotation_metadata.append(footprint)

        projection_rotation_deg = projection_rotation_from_model_state(model_state)
        if model_state is not None:
            model_rotation_metadata[footprint] = {
                "projection_rotation_deg": round(projection_rotation_deg, 6),
                "model_3d_rotx_deg": round(float(model_state["rotx"]), 6) if model_state.get("rotx") is not None else None,
                "model_3d_roty_deg": round(float(model_state["roty"]), 6) if model_state.get("roty") is not None else None,
                "model_3d_rotz_deg": round(float(model_state["rotz"]), 6),
                "model_2d_rotation_deg": round(float(model_state.get("rotation_2d") or 0.0), 6),
                "model_name": str(model_state["model_name"]),
            }

        projection = visible_edge_projection(model_cache[model_path], model_state)
        source_segments = projection["segments"]
        source_bbox = projection["source_bbox"]
        hidden_line_stats[footprint] = projection["stats"]
        if not source_segments or source_bbox is None:
            skipped[footprint] = "no visible projected STEP edges"
            continue

        scaled = scale_segments(source_segments, normalized_bbox, source_bbox)
        if not scaled:
            skipped[footprint] = "no scaled segments"
            continue

        used_models[footprint] = str(model_path)
        for x1, y1, x2, y2 in scaled:
            lines.append(f"{footprint}|{x1:.3f}|{y1:.3f}|{x2:.3f}|{y2:.3f}")

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
                "missing_rotation_metadata": missing_rotation_metadata,
            },
            indent=2,
        )
    )
    return 0 if lines else 1


if __name__ == "__main__":
    raise SystemExit(main())
