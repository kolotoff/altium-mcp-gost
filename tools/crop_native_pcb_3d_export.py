"""Crop connector views from native orthographic Altium PCB 3D exports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


MM_PER_MIL = 0.0254


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", type=Path, required=True)
    parser.add_argument("--bottom", type=Path, required=True)
    parser.add_argument("--components", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--board-width-mm", type=float, required=True)
    parser.add_argument("--board-height-mm", type=float, required=True)
    parser.add_argument("--board-origin-x-mil", type=float, required=True)
    parser.add_argument("--board-origin-y-mil", type=float, required=True)
    parser.add_argument("--crop-width-px", type=int, default=760)
    parser.add_argument("--crop-height-px", type=int, default=430)
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


def add_label(image: Image.Image, designator: str, side: str) -> None:
    draw = ImageDraw.Draw(image, "RGBA")
    font = load_font(28, bold=True)
    text = f"{designator}  |  {side}"
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
    board_width_mil = args.board_width_mm / MM_PER_MIL
    board_height_mil = args.board_height_mm / MM_PER_MIL
    vertical_flips = {str(value).upper() for value in args.flip_vertical_designator}
    outputs: list[Path] = []
    for component in sorted(components, key=lambda value: value["designator"]):
        side = "bottom" if component.get("layer") == "Bottom Layer" else "top"
        source = bottom if side == "bottom" else top
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
        add_label(crop, component["designator"], side)
        output = args.output_dir / f"{component['designator']}.png"
        crop.convert("RGB").save(output, optimize=True)
        outputs.append(output)
    if args.contact_sheet:
        make_contact_sheet(outputs, args.contact_sheet)
    print(f"created {len(outputs)} connector crops in {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
