from __future__ import annotations

import argparse
import json
import re
import struct
import zlib
from pathlib import Path


EXCHANGE_DIR = Path(r"C:\Users\Public\altium_mcp")
DEFAULT_RESPONSE_FILE = EXCHANGE_DIR / "response.json"
DEFAULT_OUTPUT_DIR = EXCHANGE_DIR / "embedded_3d_models"

FREE_SECT = 0xFFFFFFFF
END_OF_CHAIN = 0xFFFFFFFE
COMPOUND_FILE_MAGIC = bytes.fromhex("d0 cf 11 e0 a1 b1 1a e1")


def safe_filename(name: str) -> str:
    return re.sub(r'[<>:"/\\|?*]+', "_", Path(name).name).strip() or "embedded_model.stp"


class CompoundFile:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if self.data[:8] != COMPOUND_FILE_MAGIC:
            raise ValueError(f"{path} is not an OLE compound file")

        self.sector_size = 1 << struct.unpack_from("<H", self.data, 0x1E)[0]
        self.mini_sector_size = 1 << struct.unpack_from("<H", self.data, 0x20)[0]
        self.num_fat_sectors = struct.unpack_from("<I", self.data, 0x2C)[0]
        self.first_directory_sector = struct.unpack_from("<I", self.data, 0x30)[0]
        self.mini_stream_cutoff = struct.unpack_from("<I", self.data, 0x38)[0]
        self.first_mini_fat_sector = struct.unpack_from("<I", self.data, 0x3C)[0]
        self.num_mini_fat_sectors = struct.unpack_from("<I", self.data, 0x40)[0]
        self.first_difat_sector = struct.unpack_from("<I", self.data, 0x44)[0]
        self.num_difat_sectors = struct.unpack_from("<I", self.data, 0x48)[0]

        self.fat_sector_ids = self._read_difat()
        self.fat = self._read_fat()
        self.entries = self._read_directory()
        self.root_stream = self._read_regular_stream(self.entries[0]["start"], self.entries[0]["size"])
        self.mini_fat = self._read_mini_fat()

    def _sector_offset(self, sector_id: int) -> int:
        return (sector_id + 1) * self.sector_size

    def _sector_bytes(self, sector_id: int) -> bytes:
        offset = self._sector_offset(sector_id)
        return self.data[offset : offset + self.sector_size]

    def _read_difat(self) -> list[int]:
        entries = list(struct.unpack_from("<109I", self.data, 0x4C))
        difat_sector = self.first_difat_sector
        for _ in range(self.num_difat_sectors):
            if difat_sector in (FREE_SECT, END_OF_CHAIN):
                break
            sector = self._sector_bytes(difat_sector)
            sector_entries = list(struct.unpack("<" + "I" * (self.sector_size // 4), sector))
            entries.extend(sector_entries[:-1])
            difat_sector = sector_entries[-1]

        return [
            sector_id
            for sector_id in entries
            if sector_id not in (FREE_SECT, END_OF_CHAIN)
        ][: self.num_fat_sectors]

    def _read_fat(self) -> list[int]:
        fat: list[int] = []
        for sector_id in self.fat_sector_ids:
            fat.extend(struct.unpack("<" + "I" * (self.sector_size // 4), self._sector_bytes(sector_id)))
        return fat

    def _sector_chain(self, start: int) -> list[int]:
        chain: list[int] = []
        sector_id = start
        while sector_id not in (FREE_SECT, END_OF_CHAIN) and sector_id < len(self.fat):
            chain.append(sector_id)
            sector_id = self.fat[sector_id]
        return chain

    def _read_regular_stream(self, start: int, size: int | None = None) -> bytes:
        stream = b"".join(self._sector_bytes(sector_id) for sector_id in self._sector_chain(start))
        return stream[:size] if size is not None else stream

    def _read_directory(self) -> list[dict]:
        directory = self._read_regular_stream(self.first_directory_sector)
        entries: list[dict] = []
        for offset in range(0, len(directory), 128):
            entry = directory[offset : offset + 128]
            if len(entry) < 128:
                break

            name_length = struct.unpack_from("<H", entry, 64)[0]
            name = (
                entry[: max(0, name_length - 2)].decode("utf-16le", errors="replace")
                if name_length >= 2
                else ""
            )
            entries.append(
                {
                    "name": name,
                    "type": entry[66],
                    "left": struct.unpack_from("<I", entry, 68)[0],
                    "right": struct.unpack_from("<I", entry, 72)[0],
                    "child": struct.unpack_from("<I", entry, 76)[0],
                    "start": struct.unpack_from("<I", entry, 116)[0],
                    "size": struct.unpack_from("<Q", entry, 120)[0],
                }
            )
        return entries

    def _read_mini_fat(self) -> list[int]:
        if self.first_mini_fat_sector in (FREE_SECT, END_OF_CHAIN):
            return []

        mini_fat: list[int] = []
        for sector_id in self._sector_chain(self.first_mini_fat_sector)[: self.num_mini_fat_sectors]:
            mini_fat.extend(struct.unpack("<" + "I" * (self.sector_size // 4), self._sector_bytes(sector_id)))
        return mini_fat

    def _mini_sector_chain(self, start: int) -> list[int]:
        chain: list[int] = []
        sector_id = start
        while sector_id not in (FREE_SECT, END_OF_CHAIN) and sector_id < len(self.mini_fat):
            chain.append(sector_id)
            sector_id = self.mini_fat[sector_id]
        return chain

    def _read_mini_stream(self, start: int, size: int) -> bytes:
        stream = b"".join(
            self.root_stream[
                sector_id * self.mini_sector_size : sector_id * self.mini_sector_size + self.mini_sector_size
            ]
            for sector_id in self._mini_sector_chain(start)
        )
        return stream[:size]

    def read_stream(self, entry: dict) -> bytes:
        if entry["type"] == 5:
            return self._read_regular_stream(entry["start"], entry["size"])
        if entry["size"] < self.mini_stream_cutoff and entry["start"] not in (FREE_SECT, END_OF_CHAIN):
            return self._read_mini_stream(entry["start"], entry["size"])
        return self._read_regular_stream(entry["start"], entry["size"])

    def child_ids(self, entry_id: int) -> list[int]:
        def walk(node_id: int) -> list[int]:
            if node_id == FREE_SECT or node_id >= len(self.entries):
                return []
            entry = self.entries[node_id]
            return walk(entry["left"]) + [node_id] + walk(entry["right"])

        return walk(self.entries[entry_id]["child"])

    def find_storage(self, name: str, root_id: int = 0) -> int | None:
        for child_id in self.child_ids(root_id):
            entry = self.entries[child_id]
            if entry["type"] != 1:
                continue
            if entry["name"] == name:
                return child_id
            nested_id = self.find_storage(name, child_id)
            if nested_id is not None:
                return nested_id
        return None


def parse_model_records(data: bytes) -> list[dict[str, str]]:
    records: list[str] = []
    offset = 0
    while offset + 4 <= len(data):
        length = struct.unpack_from("<I", data, offset)[0]
        if length <= 0 or offset + 4 + length > len(data):
            break
        records.append(data[offset + 4 : offset + 4 + length].rstrip(b"\0").decode("latin-1", errors="ignore"))
        offset += 4 + length

    if not records:
        records = [
            item.decode("latin-1", errors="ignore")
            for item in data.split(b"\0")
            if b"NAME=" in item or b"MODEL.NAME=" in item
        ]

    parsed: list[dict[str, str]] = []
    for record in records:
        fields: dict[str, str] = {}
        for part in record.split("|"):
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            fields[key.strip().upper()] = value.strip()
        if fields:
            parsed.append(fields)
    return parsed


def source_to_pcblib_path(source: Path) -> Path:
    if source.suffix.lower() != ".json":
        return source

    data = json.loads(source.read_text(encoding="utf-8-sig"))
    result = data.get("result", data)
    library_path = result.get("library_path") if isinstance(result, dict) else None
    if not library_path:
        raise ValueError(f"{source} does not contain a library_path from 3D_BODY_DUMP")
    return Path(library_path)


def extract_embedded_steps(pcblib_path: Path, output_dir: Path) -> dict:
    compound = CompoundFile(pcblib_path)
    models_id = compound.find_storage("Models")
    if models_id is None:
        raise ValueError(f"{pcblib_path} does not contain a Models storage")

    model_children = compound.child_ids(models_id)
    data_entry = next(
        (compound.entries[child_id] for child_id in model_children if compound.entries[child_id]["name"] == "Data"),
        None,
    )
    if data_entry is None:
        raise ValueError(f"{pcblib_path} does not contain Models/Data metadata")

    model_records = parse_model_records(compound.read_stream(data_entry))
    model_streams = sorted(
        (
            compound.entries[child_id]
            for child_id in model_children
            if compound.entries[child_id]["type"] == 2 and compound.entries[child_id]["name"].isdigit()
        ),
        key=lambda entry: int(entry["name"]),
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    extracted: list[dict] = []
    skipped: list[dict] = []
    for index, entry in enumerate(model_streams):
        model_name = ""
        if index < len(model_records):
            model_name = model_records[index].get("NAME", "") or model_records[index].get("MODEL.NAME", "")
        if not model_name:
            model_name = f"embedded_model_{entry['name']}.stp"

        raw = compound.read_stream(entry)
        try:
            step_data = zlib.decompress(raw)
        except zlib.error as error:
            skipped.append({"stream": entry["name"], "model_name": model_name, "error": str(error)})
            continue

        if not step_data.lstrip().startswith(b"ISO-10303-21"):
            skipped.append({"stream": entry["name"], "model_name": model_name, "error": "not a STEP file"})
            continue

        output_file = output_dir / safe_filename(model_name)
        output_file.write_bytes(step_data)
        extracted.append(
            {
                "stream": entry["name"],
                "model_name": model_name,
                "output_file": str(output_file),
                "bytes": len(step_data),
            }
        )

    return {
        "library_path": str(pcblib_path),
        "output_dir": str(output_dir),
        "models_extracted": len(extracted),
        "models_skipped": len(skipped),
        "models": extracted,
        "skipped": skipped,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract embedded STEP models from an Altium PcbLib Models storage."
    )
    parser.add_argument(
        "source",
        nargs="?",
        default=str(DEFAULT_RESPONSE_FILE),
        help="PcbLib path, or a 3D_BODY_DUMP response JSON containing library_path.",
    )
    parser.add_argument(
        "output_dir",
        nargs="?",
        default=str(DEFAULT_OUTPUT_DIR),
        help="Directory where extracted .stp files are written.",
    )
    args = parser.parse_args()

    pcblib_path = source_to_pcblib_path(Path(args.source))
    result = extract_embedded_steps(pcblib_path, Path(args.output_dir))
    print(json.dumps(result, indent=2))
    return 0 if result["models_extracted"] > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
