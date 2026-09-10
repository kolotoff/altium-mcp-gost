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

FREE_SECTOR = 0xFFFFFFFF
END_OF_CHAIN = 0xFFFFFFFE
CFB_SIGNATURE = bytes.fromhex("D0CF11E0A1B11AE1")
ALTIUM_COORD_TO_MM = 0.0254 / 10_000.0


class CFBError(ValueError):
    """Raised when an input is not a supported compound binary file."""


class CompoundBinaryFile:
    """Minimal read-only CFB reader sufficient for Altium document streams."""

    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if self.data[:8] != CFB_SIGNATURE:
            raise CFBError(f"{path} is not an OLE compound binary file")
        if len(self.data) < 512:
            raise CFBError(f"{path} has a truncated CFB header")

        self.sector_size = 1 << struct.unpack_from("<H", self.data, 30)[0]
        self.mini_sector_size = 1 << struct.unpack_from("<H", self.data, 32)[0]
        self.first_directory_sector = struct.unpack_from("<I", self.data, 48)[0]
        self.mini_stream_cutoff = struct.unpack_from("<I", self.data, 56)[0]
        self.first_mini_fat_sector = struct.unpack_from("<I", self.data, 60)[0]
        self.mini_fat_sector_count = struct.unpack_from("<I", self.data, 64)[0]
        first_difat_sector = struct.unpack_from("<I", self.data, 68)[0]
        difat_sector_count = struct.unpack_from("<I", self.data, 72)[0]

        fat_sectors = [
            sector
            for sector in struct.unpack_from("<109I", self.data, 76)
            if sector != FREE_SECTOR
        ]
        sector_id = first_difat_sector
        for _ in range(difat_sector_count):
            values = struct.unpack(
                f"<{self.sector_size // 4}I", self._sector(sector_id)
            )
            fat_sectors.extend(value for value in values[:-1] if value != FREE_SECTOR)
            sector_id = values[-1]

        fat_bytes = b"".join(self._sector(sector) for sector in fat_sectors)
        self.fat = list(struct.unpack(f"<{len(fat_bytes) // 4}I", fat_bytes))
        directory = self._read_chain(self.first_directory_sector)
        self.entries = self._parse_directory(directory)
        if not self.entries:
            raise CFBError(f"{path} contains no directory entries")

        root = self.entries[0]
        self.mini_stream = self._read_chain(root["start"])[: root["size"]]
        mini_fat_bytes = (
            self._read_chain(self.first_mini_fat_sector)[
                : self.mini_fat_sector_count * self.sector_size
            ]
            if self.mini_fat_sector_count
            else b""
        )
        self.mini_fat = (
            list(struct.unpack(f"<{len(mini_fat_bytes) // 4}I", mini_fat_bytes))
            if mini_fat_bytes
            else []
        )
        self._stream_paths = self._build_stream_paths()

    def _sector(self, sector_id: int) -> bytes:
        if sector_id in (FREE_SECTOR, END_OF_CHAIN):
            raise CFBError(f"invalid sector id 0x{sector_id:08X}")
        start = (sector_id + 1) * self.sector_size
        end = start + self.sector_size
        if start < 0 or end > len(self.data):
            raise CFBError(f"sector {sector_id} is outside the file")
        return self.data[start:end]

    def _read_chain(self, start: int) -> bytes:
        chunks: list[bytes] = []
        sector_id = start
        seen: set[int] = set()
        while sector_id not in (END_OF_CHAIN, FREE_SECTOR):
            if sector_id >= len(self.fat) or sector_id in seen:
                raise CFBError(f"invalid or cyclic FAT chain at sector {sector_id}")
            seen.add(sector_id)
            chunks.append(self._sector(sector_id))
            sector_id = self.fat[sector_id]
        return b"".join(chunks)

    def _read_mini_chain(self, start: int) -> bytes:
        chunks: list[bytes] = []
        sector_id = start
        seen: set[int] = set()
        while sector_id not in (END_OF_CHAIN, FREE_SECTOR):
            if sector_id >= len(self.mini_fat) or sector_id in seen:
                raise CFBError(
                    f"invalid or cyclic mini-FAT chain at sector {sector_id}"
                )
            seen.add(sector_id)
            offset = sector_id * self.mini_sector_size
            chunks.append(self.mini_stream[offset : offset + self.mini_sector_size])
            sector_id = self.mini_fat[sector_id]
        return b"".join(chunks)

    @staticmethod
    def _parse_directory(directory: bytes) -> list[dict[str, int | str]]:
        entries: list[dict[str, int | str]] = []
        for offset in range(0, len(directory), 128):
            record = directory[offset : offset + 128]
            if len(record) < 128:
                continue
            name_length = struct.unpack_from("<H", record, 64)[0]
            name = (
                record[: max(0, name_length - 2)].decode("utf-16le", "replace")
                if name_length >= 2
                else ""
            )
            entries.append(
                {
                    "name": name,
                    "type": record[66],
                    "left": struct.unpack_from("<I", record, 68)[0],
                    "right": struct.unpack_from("<I", record, 72)[0],
                    "child": struct.unpack_from("<I", record, 76)[0],
                    "start": struct.unpack_from("<I", record, 116)[0],
                    "size": struct.unpack_from("<Q", record, 120)[0],
                }
            )
        return entries

    def _build_stream_paths(self) -> dict[str, int]:
        result: dict[str, int] = {}

        def walk_siblings(index: int, parent: list[str]) -> None:
            if index in (FREE_SECTOR, END_OF_CHAIN) or index >= len(self.entries):
                return
            entry = self.entries[index]
            walk_siblings(int(entry["left"]), parent)
            name = str(entry["name"])
            path = parent + ([name] if name else [])
            if entry["type"] == 2:
                result["/".join(path)] = index
            if entry["type"] == 1:
                walk_siblings(int(entry["child"]), path)
            walk_siblings(int(entry["right"]), parent)

        walk_siblings(int(self.entries[0]["child"]), [])
        return result

    def stream_paths(self) -> list[str]:
        return sorted(self._stream_paths, key=str.casefold)

    def find_stream(self, path: str) -> str:
        expected = path.casefold()
        for candidate in self._stream_paths:
            if candidate.casefold() == expected:
                return candidate
        raise CFBError(f"stream {path!r} was not found in {self.path}")

    def read_stream(self, path: str) -> bytes:
        canonical_path = self.find_stream(path)
        entry = self.entries[self._stream_paths[canonical_path]]
        size = int(entry["size"])
        start = int(entry["start"])
        if size < self.mini_stream_cutoff:
            return self._read_mini_chain(start)[:size]
        return self._read_chain(start)[:size]


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
