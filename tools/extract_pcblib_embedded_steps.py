from __future__ import annotations

import argparse
import json
import re
import struct
import sys
import zlib
from pathlib import Path


# Support both `python -m tools.…` and direct invocation from a checkout.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server.compound_file import CompoundBinaryFile


EXCHANGE_DIR = Path(r"C:\Users\Public\altium_mcp")
DEFAULT_RESPONSE_FILE = EXCHANGE_DIR / "response.json"
DEFAULT_OUTPUT_DIR = EXCHANGE_DIR / "embedded_3d_models"

def safe_filename(name: str) -> str:
    return re.sub(r'[<>:"/\\|?*]+', "_", Path(name).name).strip() or "embedded_model.stp"


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
    compound = CompoundBinaryFile(pcblib_path)
    model_storage = None
    for path in compound.stream_paths():
        storage, _, name = path.rpartition("/")
        if storage.rsplit("/", 1)[-1].casefold() == "models" and name.casefold() == "data":
            model_storage = storage
            model_records = parse_model_records(compound.read_stream(path))
            break
    if model_storage is None:
        raise ValueError(f"{pcblib_path} does not contain Models/Data metadata")

    model_streams = []
    for path in compound.stream_paths():
        storage, _, name = path.rpartition("/")
        if storage == model_storage and name.isdigit():
            model_streams.append((name, path))
    model_streams.sort(key=lambda stream: int(stream[0]))

    output_dir.mkdir(parents=True, exist_ok=True)
    extracted: list[dict] = []
    skipped: list[dict] = []
    for index, (name, path) in enumerate(model_streams):
        model_name = ""
        if index < len(model_records):
            model_name = model_records[index].get("NAME", "") or model_records[index].get("MODEL.NAME", "")
        if not model_name:
            model_name = f"embedded_model_{name}.stp"

        raw = compound.read_stream(path)
        try:
            step_data = zlib.decompress(raw)
        except zlib.error as error:
            skipped.append({"stream": name, "model_name": model_name, "error": str(error)})
            continue

        if not step_data.lstrip().startswith(b"ISO-10303-21"):
            skipped.append({"stream": name, "model_name": model_name, "error": "not a STEP file"})
            continue

        output_file = output_dir / safe_filename(model_name)
        output_file.write_bytes(step_data)
        extracted.append(
            {
                "stream": name,
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
