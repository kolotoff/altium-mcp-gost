"""Crop connector views from native orthographic Altium PCB 3D exports."""

from __future__ import annotations

import argparse
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

if __package__:
    from .board_test_localization import LANGUAGE_MODES, ui_text
    from .pcb_3d_registration import CameraRegistration, load_registration
else:
    from board_test_localization import LANGUAGE_MODES, ui_text
    from pcb_3d_registration import CameraRegistration, load_registration


MM_PER_MIL = 0.0254


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", type=Path, required=True)
    parser.add_argument("--bottom", type=Path, required=True)
    parser.add_argument("--components", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--board-width-mm", type=float)
    parser.add_argument("--board-height-mm", type=float)
    parser.add_argument("--board-origin-x-mil", type=float)
    parser.add_argument("--board-origin-y-mil", type=float)
    parser.add_argument("--top-svg", type=Path)
    parser.add_argument("--bottom-svg", type=Path)
    parser.add_argument(
        "--registration",
        type=Path,
        help="Camera registration JSON emitted with the orthographic 3D renders.",
    )
    parser.add_argument("--crop-width-px", type=int, default=760)
    parser.add_argument("--crop-height-px", type=int, default=430)
    parser.add_argument("--language-mode", choices=LANGUAGE_MODES, default="source")
    parser.add_argument(
        "--bottom-transform",
        choices=("flip-x", "flip-y", "rotate-180", "none"),
        default="flip-x",
    )
    parser.add_argument(
        "--flip-vertical-designator",
        action="append",
        default=[],
        help="Flip the finished source crop vertically before adding its label and arrow; may be repeated.",
    )
    parser.add_argument("--contact-sheet", type=Path)
    return parser.parse_args()


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    windows = Path("C:/Windows/Fonts")
    candidates = (
        windows / ("msyhbd.ttc" if bold else "msyh.ttc"),
        windows / ("arialbd.ttf" if bold else "arial.ttf"),
        windows / ("segoeuib.ttf" if bold else "segoeui.ttf"),
    )
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


def point_for_component(
    component: dict,
    *,
    image_size: tuple[int, int],
    board_width_mil: float,
    board_height_mil: float,
    origin_x_mil: float,
    origin_y_mil: float,
    bottom_transform: str,
) -> tuple[float, float]:
    image_width, image_height = image_size
    x = float(component["x"]) - origin_x_mil
    y = float(component["y"]) - origin_y_mil
    px = x / board_width_mil * image_width
    py = image_height - y / board_height_mil * image_height
    if component.get("layer") == "Bottom Layer":
        if bottom_transform in ("flip-x", "rotate-180"):
            px = image_width - px
        if bottom_transform in ("flip-y", "rotate-180"):
            py = image_height - py
    return px, py


def crop_with_padding(image: Image.Image, center: tuple[float, float], size: tuple[int, int]) -> Image.Image:
    crop_width, crop_height = size
    left = int(round(center[0] - crop_width / 2))
    top = int(round(center[1] - crop_height / 2))
    right = left + crop_width
    bottom = top + crop_height
    source_left = max(0, left)
    source_top = max(0, top)
    source_right = min(image.width, right)
    source_bottom = min(image.height, bottom)
    canvas = Image.new("RGB", (crop_width, crop_height), "white")
    if source_right > source_left and source_bottom > source_top:
        region = image.crop((source_left, source_top, source_right, source_bottom)).convert("RGB")
        canvas.paste(region, (source_left - left, source_top - top))
    return canvas


def parse_numbers(text: str) -> list[float]:
    return [float(value) for value in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", text)]


def exported_designator_aliases(element: ET.Element) -> list[str]:
    """Return logical designator aliases for panelized Altium SVG instances."""
    component = str(element.get("data-component") or "").strip()
    if not component:
        return []
    aliases = [component]
    instance = str(element.get("data-instance") or "").strip()
    if instance == component:
        aliases.append(f"{component}_1")
    else:
        match = re.fullmatch(re.escape(component) + r"-(\d+)", instance)
        if match:
            aliases.append(f"{component}_{match.group(1)}")
        elif instance:
            aliases.append(instance)
    return list(dict.fromkeys(aliases))


def svg_component_pixels(
    path: Path,
    image_size: tuple[int, int],
    *,
    bottom: bool,
    registration: CameraRegistration | None = None,
) -> dict[str, tuple[float, float]]:
    root = ET.parse(path).getroot()
    view = parse_numbers(root.get("viewBox", ""))
    if len(view) != 4:
        raise ValueError(f"invalid board SVG viewBox: {path}")
    view_x, view_y, view_width, view_height = view
    positions: dict[str, tuple[float, float]] = {}
    for suffix in ("-assembly", "-pads"):
        for element in root.iter():
            identifier = element.get("id", "")
            aliases = exported_designator_aliases(element)
            if not aliases or not identifier.endswith(suffix) or all(alias in positions for alias in aliases):
                continue
            match = re.search(r"translate\(\s*([-+0-9.eE]+)[ ,]+([-+0-9.eE]+)\s*\)", element.get("transform", ""))
            if not match:
                continue
            x, y = float(match.group(1)), float(match.group(2))
            if registration is not None:
                registration.validate_image_size(image_size)
                center = registration.pixel_for_physical(x, y)
            else:
                if bottom:
                    x = 2.0 * view_x + view_width - x
                local_x = x - view_x
                local_y = -y - view_y
                center = (
                    local_x / view_width * image_size[0],
                    local_y / view_height * image_size[1],
                )
            for alias in aliases:
                positions.setdefault(alias, center)
    return positions


def add_label(image: Image.Image, designator: str, side: str, language_mode: str = "source") -> None:
    draw = ImageDraw.Draw(image, "RGBA")
    font = load_font(28, bold=True)
    text = f"{designator}  |  {ui_text(side, language_mode, separator=' / ')}"
    box = draw.textbbox((0, 0), text, font=font)
    width = box[2] - box[0] + 28
    height = box[3] - box[1] + 20
    draw.rounded_rectangle((14, 14, 14 + width, 14 + height), radius=8, fill=(255, 255, 255, 225), outline=(33, 72, 94, 210), width=2)
    draw.text((28, 22), text, font=font, fill=(24, 50, 74, 255))


def add_locator_arrow(image: Image.Image) -> None:
    """Draw a compact vertical translucent arrow at the component origin."""
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay, "RGBA")
    target = (image.width // 2, image.height // 2)
    shaft_top = max(64, target[1] - 82)
    head_length = 20
    half_width = 11
    color = (218, 24, 42, 165)
    outline = (154, 8, 24, 205)
    draw.line(
        ((target[0], shaft_top), (target[0], target[1] - head_length + 1)),
        fill=color,
        width=7,
    )
    points = [
        target,
        (target[0] - half_width, target[1] - head_length),
        (target[0] + half_width, target[1] - head_length),
    ]
    draw.polygon(points, fill=color, outline=outline)
    image.alpha_composite(overlay)


def make_contact_sheet(paths: list[Path], output: Path) -> None:
    thumbs: list[Image.Image] = []
    for path in paths:
        image = Image.open(path).convert("RGB")
        image.thumbnail((380, 215), Image.Resampling.LANCZOS)
        thumbs.append(image)
    columns = 4
    rows = (len(thumbs) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * 390, rows * 225), "white")
    for index, image in enumerate(thumbs):
        sheet.paste(image, ((index % columns) * 390 + 5, (index // columns) * 225 + 5))
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, quality=92)


def main() -> int:
    args = parse_args()
    top = Image.open(args.top).convert("RGB")
    bottom = Image.open(args.bottom).convert("RGB")
    if top.size != bottom.size:
        raise SystemExit(f"top and bottom image sizes differ: {top.size} vs {bottom.size}")
    payload = json.loads(args.components.read_text(encoding="utf-8-sig"))
    components = payload.get("components", payload)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    use_svg_positions = args.top_svg is not None or args.bottom_svg is not None
    if use_svg_positions:
        if args.top_svg is None or args.bottom_svg is None:
            raise SystemExit("--top-svg and --bottom-svg must be supplied together")
        if args.registration is None:
            raise SystemExit(
                "--registration is required with assembly SVGs so component origins "
                "are mapped through the actual Altium 3D camera"
            )
        top_registration = load_registration(args.registration, "top")
        bottom_registration = load_registration(args.registration, "bottom")
        top_positions = svg_component_pixels(
            args.top_svg, top.size, bottom=False, registration=top_registration)
        bottom_positions = svg_component_pixels(
            args.bottom_svg, bottom.size, bottom=True, registration=bottom_registration)
    else:
        required = (args.board_width_mm, args.board_height_mm, args.board_origin_x_mil, args.board_origin_y_mil)
        if any(value is None for value in required):
            raise SystemExit(
                "supply --top-svg/--bottom-svg, or all board width/height/origin arguments"
            )
        board_width_mil = args.board_width_mm / MM_PER_MIL
        board_height_mil = args.board_height_mm / MM_PER_MIL
    vertical_flips = {str(value).upper() for value in args.flip_vertical_designator}
    outputs: list[Path] = []
    for component in sorted(components, key=lambda value: value["designator"]):
        side = "bottom" if component.get("layer") == "Bottom Layer" else "top"
        source = bottom if side == "bottom" else top
        if use_svg_positions:
            positions = bottom_positions if side == "bottom" else top_positions
            if component["designator"] not in positions:
                raise SystemExit(f"component {component['designator']} is missing from the {side} assembly SVG")
            center = positions[component["designator"]]
        else:
            center = point_for_component(
                component,
                image_size=source.size,
                board_width_mil=board_width_mil,
                board_height_mil=board_height_mil,
                origin_x_mil=args.board_origin_x_mil,
                origin_y_mil=args.board_origin_y_mil,
                bottom_transform=args.bottom_transform,
            )
        crop = crop_with_padding(source, center, (args.crop_width_px, args.crop_height_px)).convert("RGBA")
        if str(component["designator"]).upper() in vertical_flips:
            crop = ImageOps.flip(crop)
        add_locator_arrow(crop)
        add_label(crop, component["designator"], side, args.language_mode)
        output = args.output_dir / f"{component['designator']}.png"
        crop.convert("RGB").save(output, optimize=True)
        outputs.append(output)
    if args.contact_sheet:
        make_contact_sheet(outputs, args.contact_sheet)
    print(f"created {len(outputs)} connector crops in {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
