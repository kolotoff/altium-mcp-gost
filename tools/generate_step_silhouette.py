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


NUM_RE = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?"


def vec_sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


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


def parse_step_edges(path: Path) -> list[tuple[float, float, float, float]]:
    text = path.read_text(encoding="latin-1", errors="ignore")
    records = split_step_records(text)

    points: dict[int, tuple[float, float, float]] = {}
    directions: dict[int, tuple[float, float, float]] = {}
    vertices: dict[int, int] = {}
    placements: dict[int, tuple[int, int, int]] = {}
    circles: dict[int, tuple[int, float]] = {}
    edges: list[tuple[int, int, int, bool]] = []

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

        match = re.match(rf"#(\d+)\s*=\s*CIRCLE\s*\(\s*[^,]*,\s*#(\d+)\s*,\s*({NUM_RE})\s*\)\s*;?$", record)
        if match:
            circles[int(match.group(1))] = (int(match.group(2)), float(match.group(3)))
            continue

        match = re.match(
            r"#(\d+)\s*=\s*EDGE_CURVE\s*\(\s*(?:'[^']*'|\$|\*)\s*,\s*#(\d+)\s*,\s*#(\d+)\s*,\s*#(\d+)\s*,\s*\.(T|F)\.\s*\)\s*;?$",
            record,
        )
        if match:
            edges.append((int(match.group(2)), int(match.group(3)), int(match.group(4)), match.group(5) == "T"))

    def point_for_vertex(vertex_id: int) -> tuple[float, float, float] | None:
        point_id = vertices.get(vertex_id)
        if point_id is None:
            return None
        return points.get(point_id)

    def project(point: tuple[float, float, float]) -> tuple[float, float]:
        return (point[0], point[2])

    raw_segments: list[tuple[float, float, float, float]] = []
    for start_vertex, end_vertex, curve_id, _same_sense in edges:
        start = point_for_vertex(start_vertex)
        end = point_for_vertex(end_vertex)
        if start is None or end is None:
            continue

        if curve_id in circles:
            placement_id, radius = circles[curve_id]
            placement = placements.get(placement_id)
            if placement is not None:
                center_id, axis_id, ref_id = placement
                center = points.get(center_id)
                axis = directions.get(axis_id)
                x_dir = directions.get(ref_id)
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
                        point = (
                            center[0] + radius * (math.cos(theta) * x_dir[0] + math.sin(theta) * y_dir[0]),
                            center[1] + radius * (math.cos(theta) * x_dir[1] + math.sin(theta) * y_dir[1]),
                            center[2] + radius * (math.cos(theta) * x_dir[2] + math.sin(theta) * y_dir[2]),
                        )
                        arc_points.append(project(point))
                    raw_segments.extend(
                        (arc_points[index][0], arc_points[index][1], arc_points[index + 1][0], arc_points[index + 1][1])
                        for index in range(len(arc_points) - 1)
                    )
                    continue

        p1 = project(start)
        p2 = project(end)
        raw_segments.append((p1[0], p1[1], p2[0], p2[1]))

    return raw_segments


def bbox_for_segments(segments: list[tuple[float, float, float, float]]) -> tuple[float, float, float, float]:
    xs = [value for segment in segments for value in (segment[0], segment[2])]
    ys = [value for segment in segments for value in (segment[1], segment[3])]
    return (min(xs), min(ys), max(xs), max(ys))


def scale_segments(
    segments: list[tuple[float, float, float, float]],
    target_bbox: tuple[float, float, float, float],
) -> list[tuple[float, float, float, float]]:
    source_left, source_bottom, source_right, source_top = bbox_for_segments(segments)
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

    model_cache: dict[Path, list[tuple[float, float, float, float]]] = {}
    lines: list[str] = []
    used_models: dict[str, str] = {}
    skipped: dict[str, str] = {}
    normalized_bboxes: dict[str, dict[str, list[float]]] = {}
    model_rotation_metadata: dict[str, dict[str, float | str | None]] = {}
    missing_rotation_metadata: list[str] = []

    for body in bodies:
        footprint = str(body["footprint"])
        model_path = embedded_model_path(footprint, model_dir)
        if model_path is None:
            skipped[footprint] = f"exact embedded STEP model not found in {model_dir}"
            continue

        if model_path not in model_cache:
            model_cache[model_path] = parse_step_edges(model_path)

        raw_segments = model_cache[model_path]
        if not raw_segments:
            skipped[footprint] = "no projected STEP edges"
            continue

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
        source_segments = raw_segments
        if projection_rotation_deg != 0.0:
            source_segments = rotate_segments(raw_segments, bbox_for_segments(raw_segments), projection_rotation_deg)
            model_rotation_metadata[footprint] = {
                "projection_rotation_deg": round(projection_rotation_deg, 6),
                "model_3d_rotz_deg": round(float(model_state["rotz"]), 6) if model_state else None,
                "model_name": str(model_state["model_name"]) if model_state else None,
            }

        scaled = scale_segments(source_segments, normalized_bbox)
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
                "missing_rotation_metadata": missing_rotation_metadata,
            },
            indent=2,
        )
    )
    return 0 if lines else 1


if __name__ == "__main__":
    raise SystemExit(main())
