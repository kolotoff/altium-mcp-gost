"""Overlay test-map labels and leaders on orthographic PCB 3D renders."""

from __future__ import annotations

import argparse
import base64
import copy
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image


SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def qname(name: str) -> str:
    return f"{{{SVG}}}{name}"


def build_page(map_path: Path, render_path: Path, output_path: Path) -> None:
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
        image_ratio = render.width / render.height
    board_ratio = box_width / box_height
    if abs(image_ratio / board_ratio - 1) > 0.02:
        raise ValueError(f"3D render aspect ratio does not match board viewport: {render_path}")

    image = ET.Element(qname("image"), {
        "x": board.attrib["x"],
        "y": board.attrib["y"],
        "width": board.attrib["width"],
        "height": board.attrib["height"],
        "preserveAspectRatio": "xMidYMid meet",
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

    for element in root:
        if element.tag == qname("text") and element.text and "КАРТА ТЕСТОВОГО ДОСТУПА" in element.text:
            element.text = "3D КАРТА ТЕСТОВОГО ДОСТУПА"
            break

    output_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top-map", type=Path, required=True)
    parser.add_argument("--bottom-map", type=Path, required=True)
    parser.add_argument("--top-render", type=Path, required=True)
    parser.add_argument("--bottom-render", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    build_page(args.top_map, args.top_render, args.output_dir / "pcb-test-3d-map-top.svg")
    build_page(args.bottom_map, args.bottom_render, args.output_dir / "pcb-test-3d-map-bottom.svg")
    print(args.output_dir.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
