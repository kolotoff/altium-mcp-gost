"""Independent saved-file checkpoints with verified manifests; never saves Altium.

Hashing/immutable-file reuse adapted from Quilter checkpoint_storage.py (MIT).
Copyright 2026 Allegro Labs, Inc.; see LICENSES/Quilter-MIT.txt.
"""

import argparse
import hashlib
import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path


GENERATED = Path(__file__).resolve().parents[2] / "generated"


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def bounded_file(root, relative):
    relative = Path(relative)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Manifest path must remain inside its checkpoint")
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError("Manifest file is missing or escapes checkpoint")
    return path


def verify(directory):
    root = Path(directory).resolve()
    manifest = json.loads(
        (root / "checkpoint-manifest.json").read_text(encoding="utf-8")
    )
    if manifest.get("schema") != "altium-mcp-checkpoint/v1":
        raise ValueError("Unsupported checkpoint schema")
    seen = set()
    for row in manifest["files"]:
        if row["path"] in seen:
            raise ValueError("Duplicate manifest path")
        seen.add(row["path"])
        path = bounded_file(root, row["path"])
        if path.stat().st_size != row["bytes"] or digest(path) != row["sha256"]:
            raise ValueError(f"Checkpoint bytes changed: {row['path']}")
    actual = {
        p.relative_to(root).as_posix()
        for p in root.rglob("*")
        if p.is_file() and p.relative_to(root).as_posix() != "checkpoint-manifest.json"
    }
    if actual != seen:
        raise ValueError("Checkpoint file coverage differs from manifest")
    return manifest


def copy_checkpoint(source, destination, reference=None, immutable_paths=()):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if (
        not source.is_dir()
        or not destination.is_relative_to(GENERATED.resolve())
        or destination == GENERATED.resolve()
    ):
        raise ValueError(
            "Source must be a directory; destination must be inside generated/"
        )
    if destination.is_relative_to(source):
        raise ValueError("Checkpoint destination must be outside source")
    immutable = set(immutable_paths)
    reference_root = Path(reference).resolve() if reference else None
    if reference_root and not reference_root.is_relative_to(GENERATED.resolve()):
        raise ValueError(
            "Hardlink references must be archival checkpoints inside generated/"
        )
    reference_manifest = verify(reference_root) if reference_root else {"files": []}
    reference_files = {row["path"]: row for row in reference_manifest["files"]}
    destination.mkdir(parents=True, exist_ok=False)
    rows = []
    for original in sorted(source.rglob("*")):
        if original.is_symlink():
            raise ValueError(
                "Checkpoint sources cannot contain symlinks/junction escapes"
            )
        if (
            not original.is_file()
            or original.relative_to(source).as_posix() == "checkpoint-manifest.json"
        ):
            continue
        relative = original.relative_to(source).as_posix()
        original = bounded_file(source, relative)
        before = original.stat()
        sha = digest(original)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        reused = False
        if reference_root and relative in immutable and relative in reference_files:
            row = reference_files[relative]
            if (row["bytes"], row["sha256"]) == (before.st_size, sha):
                os.link(bounded_file(reference_root, relative), target)
                reused = True
        if not reused:
            shutil.copy2(original, target)
        after = original.stat()
        if (before.st_size, before.st_mtime_ns) != (
            after.st_size,
            after.st_mtime_ns,
        ) or digest(target) != sha:
            raise ValueError(
                "Source changed during checkpoint copy; incomplete output retained"
            )
        rows.append(
            {
                "path": relative,
                "bytes": before.st_size,
                "sha256": sha,
                "shared_immutable_hardlink": reused,
            }
        )
    if immutable - {r["path"] for r in rows}:
        raise ValueError("Immutable list contains paths absent from source")
    manifest = {
        "schema": "altium-mcp-checkpoint/v1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "source": str(source),
        "native_save_verified": False,
        "files": rows,
    }
    with (destination / "checkpoint-manifest.json").open(
        "x", encoding="utf-8"
    ) as stream:
        json.dump(manifest, stream, indent=2)
    verify(destination)
    return {
        "directory": str(destination),
        "file_count": len(rows),
        "shared_files": sum(r["shared_immutable_hardlink"] for r in rows),
        "native_save_verified": False,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    copy = sub.add_parser("copy")
    copy.add_argument("source")
    copy.add_argument("destination")
    copy.add_argument("--reference")
    copy.add_argument("--immutable-path", action="append", default=[])
    check = sub.add_parser("verify")
    check.add_argument("directory")
    args = parser.parse_args(argv)
    try:
        result = (
            copy_checkpoint(
                args.source, args.destination, args.reference, args.immutable_path
            )
            if args.command == "copy"
            else {"verified": True, "file_count": len(verify(args.directory)["files"])}
        )
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(str(error))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
