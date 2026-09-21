"""Replace Altium's legacy shaded 3D workspace with a flat background color."""

from __future__ import annotations

import argparse
import statistics
from pathlib import Path

from PIL import Image, ImageChops


def corner_color(image: Image.Image, *, top: bool, sample: int = 8) -> tuple[int, int, int]:
    y0 = 0 if top else image.height - sample
    pixels = []
    for x0 in (0, image.width - sample):
        pixels.extend(image.crop((x0, y0, x0 + sample, y0 + sample)).convert("RGB").getdata())
    return tuple(int(statistics.median(pixel[channel] for pixel in pixels)) for channel in range(3))


def flatten_workspace(
    source: Path,
    output: Path,
    *,
    background: tuple[int, int, int] = (255, 255, 255),
    tolerance: int = 10,
) -> int:
    with Image.open(source) as opened:
        dpi = opened.info.get("dpi")
        image = opened.convert("RGB")
    top = corner_color(image, top=True)
    bottom = corner_color(image, top=False)
    gradient = Image.new("RGB", (1, image.height))
    gradient.putdata([
        tuple(round(top[channel] + (bottom[channel] - top[channel]) * y / max(1, image.height - 1))
              for channel in range(3))
        for y in range(image.height)
    ])
    gradient = gradient.resize(image.size)
    difference = ImageChops.difference(image, gradient).convert("L")
    mask = difference.point(lambda value: 255 if value <= tolerance else 0)
    replaced = sum(mask.histogram()[255:])
    flattened = Image.composite(Image.new("RGB", image.size, background), image, mask)
    output.parent.mkdir(parents=True, exist_ok=True)
    save_options = {"optimize": True}
    if dpi:
        save_options["dpi"] = dpi
    flattened.save(output, **save_options)
    return replaced


def parse_color(value: str) -> tuple[int, int, int]:
    value = value.strip()
    if len(value) != 7 or not value.startswith("#"):
        raise argparse.ArgumentTypeError("background must be #RRGGBB")
    try:
        return tuple(int(value[index:index + 2], 16) for index in (1, 3, 5))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("background must be #RRGGBB") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", type=Path, required=True)
    parser.add_argument("--bottom", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--background", type=parse_color, default=(255, 255, 255))
    parser.add_argument("--tolerance", type=int, default=10)
    args = parser.parse_args()
    if not 0 <= args.tolerance <= 255:
        parser.error("--tolerance must be between 0 and 255")
    for side, source in (("top", args.top), ("bottom", args.bottom)):
        output = args.output_dir / f"pcb-3d-{side}.png"
        replaced = flatten_workspace(
            source, output, background=args.background, tolerance=args.tolerance)
        print(f"{side}: replaced {replaced} workspace pixels -> {output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

