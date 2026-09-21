"""Overlay test-map labels and leaders on orthographic PCB 3D renders."""

from __future__ import annotations

import argparse
import base64
import copy
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

if __package__:
    from .board_test_localization import LANGUAGE_MODES, ui_text
    from .pcb_3d_registration import CameraRegistration, load_registration
else:
    from board_test_localization import LANGUAGE_MODES, ui_text
    from pcb_3d_registration import CameraRegistration, load_registration


SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def qname(name: str) -> str:
    return f"{{{SVG}}}{name}"


def build_page(
    map_path: Path,
    render_path: Path,
    output_path: Path,
    *,
    registration: CameraRegistration,
    side: str | None = None,
    language_mode: str = "source",
) -> None:
    side = side or ("bottom" if registration.mirror_x else "top")
    root = ET.parse(map_path).getroot()
    boards = [element for element in root if element.tag == qname("svg")]
    if len(boards) != 1:
        raise ValueError(f"expected one board viewport in {map_path}, found {len(boards)}")
    board = boards[0]
    box_width, box_height = float(board.get("width", "0")), float(board.get("height", "0"))
    if box_width <= 0 or box_height <= 0:
        raise ValueError(f"invalid board viewport in {map_path}")
    with Image.open(render_path) as render:
        if render.format != "PNG":
            raise ValueError(f"3D render must be PNG: {render_path}")
        registration.validate_image_size(render.size)
        image_ratio = render.width / render.height
    camera_ratio = ((registration.right_mm - registration.left_mm) /
                    (registration.top_mm - registration.bottom_mm))
    if abs(image_ratio / camera_ratio - 1) > 0.002:
        raise ValueError(f"3D render aspect ratio does not match camera registration: {render_path}")

    view = [float(value) for value in board.get("viewBox", "").split()]
    if len(view) != 4:
        raise ValueError(f"invalid board viewBox in {map_path}")
    view_x, view_y, view_width, view_height = view
    board_x, board_y = float(board.attrib["x"]), float(board.attrib["y"])
    if registration.mirror_x:
        reflection_axis_twice = 2.0 * view_x + view_width
        camera_left = reflection_axis_twice - registration.right_mm
        camera_right = reflection_axis_twice - registration.left_mm
    else:
        camera_left = registration.left_mm
        camera_right = registration.right_mm
    camera_top = -registration.top_mm
    camera_bottom = -registration.bottom_mm

    image_x = board_x + (camera_left - view_x) / view_width * box_width
    image_y = board_y + (camera_top - view_y) / view_height * box_height
    image_width = (camera_right - camera_left) / view_width * box_width
    image_height = (camera_bottom - camera_top) / view_height * box_height

    clip_id = "board-3d-viewport"
    defs = next((element for element in root if element.tag == qname("defs")), None)
    if defs is None:
        defs = ET.Element(qname("defs"))
        root.insert(0, defs)
    clip = ET.SubElement(defs, qname("clipPath"), {"id": clip_id})
    ET.SubElement(clip, qname("rect"), {
        "x": board.attrib["x"],
        "y": board.attrib["y"],
        "width": board.attrib["width"],
        "height": board.attrib["height"],
    })

    image = ET.Element(qname("image"), {
        "x": f"{image_x:.6f}",
        "y": f"{image_y:.6f}",
        "width": f"{image_width:.6f}",
        "height": f"{image_height:.6f}",
        "preserveAspectRatio": "xMidYMid meet",
        "clip-path": f"url(#{clip_id})",
        "data-registration": "altium-camera-mm",
        "href": "data:image/png;base64," + base64.b64encode(render_path.read_bytes()).decode("ascii"),
    })
    position = list(root).index(board)
    root.remove(board)
    root.insert(position, image)

    anchors: dict[str, tuple[str, str]] = {}
    for element in list(root):
        if element.tag != qname("circle"):
            continue
        callout = element.get("data-callout")
        if callout:
            if callout in anchors:
                raise ValueError(f"duplicate callout anchor: {callout}")
            anchors[callout] = (element.attrib["cx"], element.attrib["cy"])
            root.remove(element)
        else:
            radius = float(element.attrib["r"])
            square = ET.Element(qname("rect"), {
                "x": f"{float(element.attrib['cx']) - radius:.3f}",
                "y": f"{float(element.attrib['cy']) - radius:.3f}",
                "width": f"{2 * radius:.3f}",
                "height": f"{2 * radius:.3f}",
                "fill": element.get("fill", "#000000"),
            })
            position = list(root).index(element)
            root.remove(element)
            root.insert(position, square)

    leaders: set[str] = set()
    for element in list(root):
        if element.tag != qname("line") or not element.get("data-callout"):
            continue
        callout = element.attrib["data-callout"]
        if callout in leaders or callout not in anchors:
            raise ValueError(f"missing or duplicate callout leader: {callout}")
        leaders.add(callout)
        element.set("x2", anchors[callout][0])
        element.set("y2", anchors[callout][1])
        halo = copy.deepcopy(element)
        halo.attrib.pop("data-callout", None)
        halo.set("data-line-halo", callout)
        halo.set("stroke", "#FFFFFF")
        halo.set("stroke-width", "0.78")
        root.insert(list(root).index(element), halo)

    label_elements = [element for element in root if element.get("data-label-for")]
    labels = {element.get("data-callout") for element in label_elements}
    if not anchors or set(anchors) != leaders or set(anchors) != labels or len(label_elements) != len(anchors):
        raise ValueError("the 3D map must retain one label and leader for every SVG-map anchor")
    if any(element.tag == qname("circle") for element in root.iter()):
        raise ValueError("the annotated 3D map must contain no vector circles")

    title = next((element for element in root if element.get("data-map-title") == "2d"), None)
    if title is None:
        title = next((element for element in root if element.tag == qname("text")), None)
    if title is None:
        raise ValueError("the map has no title element")
    title.text = ui_text(f"map_3d_{side}", language_mode, separator=" / ")
    title.set("data-map-title", "3d")
    root.set("data-language-mode", language_mode)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top-map", type=Path, required=True)
    parser.add_argument("--bottom-map", type=Path, required=True)
    parser.add_argument("--top-render", type=Path, required=True)
    parser.add_argument("--bottom-render", type=Path, required=True)
    parser.add_argument("--registration", type=Path, required=True)
    parser.add_argument("--language-mode", choices=LANGUAGE_MODES, default="source")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    build_page(
        args.top_map,
        args.top_render,
        args.output_dir / "pcb-test-3d-map-top.svg",
        registration=load_registration(args.registration, "top"),
        side="top",
        language_mode=args.language_mode,
    )
    build_page(
        args.bottom_map,
        args.bottom_render,
        args.output_dir / "pcb-test-3d-map-bottom.svg",
        registration=load_registration(args.registration, "bottom"),
        side="bottom",
        language_mode=args.language_mode,
    )
    print(args.output_dir.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
