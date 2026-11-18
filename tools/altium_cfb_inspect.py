"""Inspect useful records in Altium compound-binary documents.

The utility is intentionally read-only and does not require Altium Designer.
It currently supports stream discovery, PCB board-outline bounds, and text
records stored in a schematic document's FileHeader stream.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from pathlib import Path

# Support both `python -m tools.…` and direct invocation from a checkout.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server.compound_file import CFBError, CompoundBinaryFile


ALTIUM_COORD_TO_MM = 0.0254 / 10_000.0


@dataclass(frozen=True)
class BoardBounds:
    vertices: int
    xmin_mm: float
    xmax_mm: float
    ymin_mm: float
    ymax_mm: float
    width_mm: float
    height_mm: float


def extract_board_bounds(cfb: CompoundBinaryFile) -> BoardBounds:
    data = cfb.read_stream("BoardRegions/Data")
    header_start = data.find(b"V7_LAYER=")
    if header_start < 4:
        raise CFBError("BoardRegions/Data does not contain a V7_LAYER header")

    header_length = struct.unpack_from("<I", data, header_start - 4)[0]
    count_offset = header_start + header_length
    if count_offset + 4 > len(data):
        raise CFBError("BoardRegions/Data has a truncated contour header")
    vertex_count = struct.unpack_from("<I", data, count_offset)[0]
    coordinate_count = vertex_count * 2
    coordinates_offset = count_offset + 4
    coordinates_size = coordinate_count * 8
    if vertex_count < 1 or coordinates_offset + coordinates_size > len(data):
        raise CFBError("BoardRegions/Data has an invalid contour vertex count")

    values = struct.unpack_from(f"<{coordinate_count}d", data, coordinates_offset)
    x_values = values[0::2]
    y_values = values[1::2]
    xmin = min(x_values) * ALTIUM_COORD_TO_MM
    xmax = max(x_values) * ALTIUM_COORD_TO_MM
    ymin = min(y_values) * ALTIUM_COORD_TO_MM
    ymax = max(y_values) * ALTIUM_COORD_TO_MM
    return BoardBounds(
        vertices=vertex_count,
        xmin_mm=xmin,
        xmax_mm=xmax,
        ymin_mm=ymin,
        ymax_mm=ymax,
        width_mm=xmax - xmin,
        height_mm=ymax - ymin,
    )


def iter_schematic_text(cfb: CompoundBinaryFile) -> Iterable[str]:
    data = cfb.read_stream("FileHeader")
    offset = 0
    while offset + 4 <= len(data):
        record_size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        if record_size > len(data) - offset:
            raise CFBError("FileHeader contains a truncated record")
        record = data[offset : offset + record_size]
        offset += record_size
        decoded = record.decode("utf-8", "ignore")
        if "Text=" not in decoded and "%UTF8%Text=" not in decoded:
            continue
        fields: dict[str, str] = {}
        for part in decoded.split("|"):
            if "=" in part:
                key, value = part.split("=", 1)
                fields[key] = value
        value = fields.get("%UTF8%Text", fields.get("Text", ""))
        if value:
            yield value.replace("~1", "\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect read-only data in Altium PcbDoc and SchDoc CFB files."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    streams = subparsers.add_parser("streams", help="List all compound-file streams")
    streams.add_argument("input", type=Path, help="Altium document path")
    streams.add_argument("--json", action="store_true", help="Emit JSON")

    bounds = subparsers.add_parser(
        "board-bounds", help="Read the bounding box of the PCB board-region contour"
    )
    bounds.add_argument("input", type=Path, help="PcbDoc path")
    bounds.add_argument("--json", action="store_true", help="Emit JSON")

    schematic = subparsers.add_parser(
        "schematic-text", help="Extract Text fields from schematic FileHeader records"
    )
    schematic.add_argument("input", type=Path, help="SchDoc path")
    schematic.add_argument("--json", action="store_true", help="Emit a JSON array")
    return parser


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    args = build_parser().parse_args(argv)
    try:
        cfb = CompoundBinaryFile(args.input)
        if args.command == "streams":
            result: object = cfb.stream_paths()
        elif args.command == "board-bounds":
            result = asdict(extract_board_bounds(cfb))
        elif args.command == "schematic-text":
            result = list(iter_schematic_text(cfb))
        else:  # pragma: no cover - argparse enforces known commands
            raise AssertionError(args.command)

        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        elif args.command == "board-bounds":
            for key, value in result.items():
                if isinstance(value, float):
                    print(f"{key}={value:.6f}")
                else:
                    print(f"{key}={value}")
        else:
            print("\n".join(result))
        return 0
    except (OSError, CFBError, KeyError, struct.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
