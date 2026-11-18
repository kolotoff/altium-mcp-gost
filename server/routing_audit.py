# Portions adapted from Quilter PCB routing test tools.
# Copyright 2026 Allegro Labs, Inc. (Quilter). MIT; see LICENSES/Quilter-MIT.txt.
"""Compare saved Altium inventories and optional native DRC reports."""

import csv
import hashlib
import io
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path, PureWindowsPath

from .drc_classic import classic_fields
from .drc_compact import COMPACT_HEADER, read_compact_drc


HEADERS = {
    "board": "field value",
    "nets": (
        "net pin_count via_count routed_length_raw connectivity_invalid"
        " connections_visible"
    ),
    "pads": (
        "refdes pad net x_raw y_raw layer_id layer rotation_degrees top_x_size_raw"
        " top_y_size_raw hole_size_raw selected"
    ),
    "tracks": "net x1_raw y1_raw x2_raw y2_raw width_raw layer_id layer selected",
    "vias": (
        "net x_raw y_raw size_raw hole_size_raw low_layer_id high_layer_id selected"
    ),
    "connections": (
        "net x1_raw y1_raw x2_raw y2_raw layer1_id layer2_id mode redundant selected"
    ),
    "rules": "name kind_id priority drc_enabled scope1 scope2 summary",
}
LIMITS = [
    "Legacy AllLayers inventory omits some mechanical objects.",
    "Pad records are a placement proxy; component objects are not exported.",
    "Polygons, arcs, pad stacks, stackup, and reference continuity are not modeled.",
    "Connection counts need native reconciliation; invalid flags do not prove"
    " topology.",
    "Unchanged exported rules do not prove complete rules or active online DRC.",
    "A completed comparison does not establish routing or electrical acceptance.",
]


def read_source(path, encoding):
    """Read one stable file and return its text and identity."""
    before = path.stat()
    data = path.read_bytes()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError(f"Source changed while reading: {path}")
    return data.decode(encoding), {
        "path": str(path.resolve()),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "mtime_ns": after.st_mtime_ns,
    }


EXTRA_HEADERS = {
    "components": "refdes comment footprint x_raw y_raw rotation_degrees layer_id layer",
    "layers": "stack_index layer_id layer_name copper_thickness_raw",
    "arcs": "net x_raw y_raw radius_raw start_angle end_angle width_raw layer_id selected",
    "polygons": "name net layer_id definition",
}


def read_inventory(directory, encoding="utf-8-sig"):
    """Load a complete export and reconcile its declared counts."""
    sources = []
    status, identity = read_source(directory / "inventory-status.txt", encoding)
    sources.append(identity)
    if status.strip() != "complete":
        raise ValueError(f"Inventory is incomplete: {directory}: {status.strip()}")
    tables = {}
    directory = Path(directory)
    headers = dict(HEADERS)
    for name, header in EXTRA_HEADERS.items():
        if (directory / f"{name}.tsv").exists():
            headers[name] = header
    for name, header in headers.items():
        text, identity = read_source(directory / f"{name}.tsv", encoding)
        sources.append(identity)
        reader = csv.DictReader(
            io.StringIO(text), delimiter="\t", quoting=csv.QUOTE_NONE
        )
        if reader.fieldnames != header.split():
            raise ValueError(f"Unexpected {name}.tsv header: {directory}")
        rows = list(reader)
        if any(None in row or None in row.values() for row in rows):
            raise ValueError(f"Malformed {name}.tsv row: {directory}")
        tables[name] = rows
    if any(
        row == {"field": "field_encoding", "value": "json-string"}
        for row in tables["board"]
    ):
        for rows in tables.values():
            for row in rows:
                for field, value in row.items():
                    row[field] = json.loads('"' + value + '"')
    board_rows = tables.pop("board")
    board = {row["field"]: row["value"] for row in board_rows}
    if len(board) != len(board_rows):
        raise ValueError(f"Duplicate board field: {directory}")
    for field in (
        "board_file",
        "coordinate_units",
        "internal_units_per_mil",
        "x_origin_raw",
        "y_origin_raw",
    ):
        if not board.get(field):
            raise ValueError(f"Missing board field {field}: {directory}")
    if not PureWindowsPath(board["board_file"]).is_absolute():
        raise ValueError(f"Board identity is not a full Windows path: {directory}")
    net_names = [row["net"] for row in tables["nets"]]
    if len(net_names) != len(set(net_names)) or "" in net_names:
        raise ValueError(f"Empty or duplicate net name: {directory}")
    counts = {
        "net_count": len(tables["nets"]),
        "pad_count": len(tables["pads"]),
        "track_segment_count": len(tables["tracks"]),
        "via_count": len(tables["vias"]),
        "rule_count": len(tables["rules"]),
        "connection_object_count": len(tables["connections"]),
        "nonredundant_ratsnest_connections": sum(remaining_edges(tables).values()),
        "redundant_connection_objects": sum(
            row["redundant"] == "true" for row in tables["connections"]
        ),
        "connectivity_invalid_nets": sum(
            row["connectivity_invalid"] == "true" for row in tables["nets"]
        ),
    }
    for field, count in counts.items():
        if int(board[field]) != count:
            raise ValueError(
                f"{directory}: {field} declares {board[field]}, found {count}"
            )
    for name in EXTRA_HEADERS:
        if name in tables:
            count = len(tables[name])
            if int(board.get(name + "_count", -1)) != count:
                raise ValueError(f"{name} count does not match board metadata")
            counts[name + "_count"] = count
    if int(board["internal_units_per_mil"]) <= 0:
        raise ValueError(f"Invalid unit conversion: {directory}")
    for name in ("pads", "tracks", "vias", "connections", "arcs", "polygons"):
        if name not in tables:
            continue
        if any(row["net"] and row["net"] not in net_names for row in tables[name]):
            raise ValueError(f"Unknown net in {name}.tsv: {directory}")
    for source in sources:
        stat = Path(source["path"]).stat()
        if (stat.st_size, stat.st_mtime_ns) != (source["bytes"], source["mtime_ns"]):
            raise ValueError(
                f"Source changed during export comparison: {source['path']}"
            )
    return {"board": board, "tables": tables, "counts": counts, "sources": sources}


def remaining_edges(tables):
    """Count only nonredundant ratsnest edges by exact net name."""
    return Counter(
        row["net"]
        for row in tables["connections"]
        if row["mode"] == "ratsnest" and row["redundant"] == "false"
    )


def records(rows, track=False, fields=None):
    """Count records without selection, normalizing undirected track endpoints."""
    result = Counter()
    for row in rows:
        record = {key: value for key, value in row.items() if key != "selected"}
        if fields is not None:
            record = {key: record[key] for key in fields}
        if track:
            first, second = sorted(
                (
                    (int(record["x1_raw"]), int(record["y1_raw"])),
                    (int(record["x2_raw"]), int(record["y2_raw"])),
                )
            )
            record.update(
                x1_raw=str(first[0]),
                y1_raw=str(first[1]),
                x2_raw=str(second[0]),
                y2_raw=str(second[1]),
            )
        result[tuple(sorted(record.items()))] += 1
    return result


def delta(before, after):
    """Preserve duplicate occurrences in an exact record comparison."""
    added, removed = after - before, before - after
    return {
        "added_count": added.total(),
        "removed_count": removed.total(),
        "added": [
            {"record": dict(key), "count": count}
            for key, count in sorted(added.items())
        ],
        "removed": [
            {"record": dict(key), "count": count}
            for key, count in sorted(removed.items())
        ],
    }


def compare_inventories(before, after, allowed_nets=None):
    """Report whole-board, per-net, immutable-record, and geometry changes."""
    old, new = before["tables"], after["tables"]
    changes = {
        name: delta(
            records(old[name], track=name == "tracks"),
            records(new[name], track=name == "tracks"),
        )
        for name in ("pads", "rules", "tracks", "vias")
    }
    changes["net_assignments"] = delta(
        records(old["nets"], fields=("net", "pin_count")),
        records(new["nets"], fields=("net", "pin_count")),
    )
    immutable_board = (
        "coordinate_units",
        "internal_units_per_mil",
        "x_origin_raw",
        "y_origin_raw",
    )
    board_changes = {
        field: {"baseline": before["board"][field], "current": after["board"][field]}
        for field in immutable_board
        if before["board"][field] != after["board"][field]
    }
    old_edges, new_edges = remaining_edges(old), remaining_edges(new)
    geometry_nets = {
        entry["record"]["net"]
        for name in ("tracks", "vias")
        for direction in ("added", "removed")
        for entry in changes[name][direction]
    }
    nets = []
    for name in sorted(set(old_edges) | set(new_edges) | geometry_nets):
        if old_edges[name] != new_edges[name] or name in geometry_nets:
            nets.append(
                {
                    "net": name,
                    "baseline_remaining": old_edges[name],
                    "current_remaining": new_edges[name],
                    "reduction": old_edges[name] - new_edges[name],
                    "newly_complete": old_edges[name] > 0 and new_edges[name] == 0,
                    "geometry_changed": name in geometry_nets,
                }
            )
    regressions = []
    for name in ("pads", "rules", "net_assignments"):
        if changes[name]["added_count"] or changes[name]["removed_count"]:
            regressions.append(f"Immutable {name} records changed")
    if board_changes:
        regressions.append("Board origin or units changed")
    for name in ("tracks", "vias"):
        if changes[name]["removed_count"]:
            regressions.append(f"Baseline {name} removed or modified")
    if any(net["reduction"] < 0 for net in nets):
        regressions.append("Remaining edges increased on at least one net")
    unexpected = (
        sorted({net["net"] for net in nets} - allowed_nets)
        if allowed_nets is not None
        else []
    )
    if unexpected:
        regressions.append("Changes outside the allowed net set")
    return {
        "baseline_board": before["board"],
        "current_board": after["board"],
        "baseline_counts": before["counts"],
        "current_counts": after["counts"],
        "remaining_reduction": old_edges.total() - new_edges.total(),
        "newly_complete_nets": sum(net["newly_complete"] for net in nets),
        "changed_nets": nets,
        "unexpected_nets": unexpected,
        "immutable_board_changes": board_changes,
        "changes": changes,
        "regressions": regressions,
    }


def read_drc(path, encoding="utf-8-sig"):
    """Parse complete native DRC findings and validate every reported subtotal."""
    text, source = read_source(path, encoding)
    if text.lstrip().startswith(COMPACT_HEADER):
        return read_compact_drc(path, text, source)
    findings = Counter()
    sections, metadata = [], {}
    rule, rule_count, total, waived = None, 0, None, None
    for field, value in classic_fields(text, strict_counts=True):
        if field == "ERROR":
            raise ValueError(f"Altium reported a DRC error: {path}: {value}")
        if field == "Processing Rule":
            if rule is not None:
                raise ValueError(f"Missing rule subtotal: {path}: {rule}")
            rule, rule_count = value, 0
        elif field == "finding":
            if rule is None:
                raise ValueError(f"Finding outside a rule: {path}")
            findings[(("rule", rule), ("finding", value))] += 1
            rule_count += 1
        elif field == "Rule Violations":
            if rule is None or rule_count != value:
                raise ValueError(f"Invalid rule subtotal: {path}: {rule}")
            sections.append({"rule": rule, "count": rule_count})
            rule = None
        elif field == "Violations Detected":
            total = value
        elif field == "Waived Violations":
            waived = value
        else:
            metadata[field] = value
    if rule is not None or total is None or waived is None or findings.total() != total:
        raise ValueError(f"Incomplete DRC or footer count mismatch: {path}")
    if "PCB File" not in metadata or not sections:
        raise ValueError(f"Missing DRC board identity or rule sections: {path}")
    return {
        "source": source,
        "metadata": metadata,
        "sections": sections,
        "findings": findings,
        "total": total,
        "waived": waived,
    }


def same_board(first, second):
    """Compare full Windows board paths without case differences."""
    return PureWindowsPath(first) == PureWindowsPath(second)


def category(rule):
    """Group native rule sections without discarding their full scope text."""
    prefixes = [
        ("Clearance Constraint", "Clearance"),
        ("Short-Circuit", "Short-Circuit"),
        ("Un-Routed", "Un-Routed Net"),
        ("Width Constraint", "Width"),
        ("Differential Pairs", "Differential pair coupling"),
        ("Hole Size", "Hole Size"),
        ("Hole To Hole", "Hole To Hole Clearance"),
        ("Minimum Solder", "Minimum Solder Mask Sliver"),
        ("Silk To Solder", "Silk To Solder Mask"),
        ("Silk to Silk", "Silk To Silk"),
        ("Net Antennae", "Net Antennae"),
        ("Board Clearance", "Board Clearance"),
        ("Board Outline", "Board Outline Clearance"),
        ("Delay Constraint", "Delay"),
        ("Matched", "Matched Lengths"),
        ("Room ", "Room Definition"),
        ("Component Clearance", "Component Clearance"),
    ]
    return next((name for prefix, name in prefixes if rule.startswith(prefix)), rule)


SNAPSHOT_SCHEMA = "altium-mcp-routing-snapshot/v1"
SNAPSHOT_LIMITS = [
    "Legacy AllLayers inventory can omit extended mechanical objects.",
    "Component placement, straight/arc tracks, copper stack and polygon definitions are exported.",
    "Poured copper, complete pad stacks, keepout semantics and reference continuity are not modeled.",
    "Cached connection counts require native reconciliation; invalid flags do not prove topology.",
    "Unchanged rule records do not establish complete batch or online DRC coverage.",
    "Snapshot comparison does not establish electrical or manufacturing acceptance.",
]


def seal_inventory(directory: Path, snapshot_id: str) -> dict:
    """Publish a new immutable snapshot only after every native table is complete."""
    directory = Path(directory)
    inventory = read_inventory(directory)
    if inventory["board"].get("snapshot_id") != snapshot_id:
        raise ValueError("Native export belongs to a different snapshot generation")
    if not set(EXTRA_HEADERS) <= inventory["tables"].keys():
        raise ValueError(
            "Versioned snapshots require component, layer, arc and polygon tables"
        )
    _, signature = read_source(directory / "board-signature.txt", "ascii")
    sources = inventory["sources"] + [signature]
    manifest = {
        "schema": SNAPSHOT_SCHEMA,
        "snapshot_id": snapshot_id,
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "board_file": inventory["board"]["board_file"],
        "fingerprint": signature["sha256"],
        "counts": inventory["counts"],
        "limits": SNAPSHOT_LIMITS,
        "files": {
            Path(row["path"]).name: {"sha256": row["sha256"], "bytes": row["bytes"]}
            for row in sources
        },
    }
    with (directory / "manifest.json").open("x", encoding="utf-8") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
    return manifest


def read_snapshot(directory: Path) -> dict:
    directory = Path(directory).resolve()
    manifest_path = directory / "manifest.json"
    manifest_text, identity = read_source(manifest_path, "utf-8-sig")
    manifest = json.loads(manifest_text)
    if not isinstance(manifest, dict) or manifest.get("schema") != SNAPSHOT_SCHEMA:
        raise ValueError("Unsupported or missing snapshot schema")
    expected_files = {f"{name}.tsv" for name in {*HEADERS, *EXTRA_HEADERS}} | {
        "inventory-status.txt",
        "board-signature.txt",
    }
    if set(manifest.get("files", {})) != expected_files:
        raise ValueError("Snapshot manifest has incomplete or unexpected file coverage")
    for name, expected in manifest["files"].items():
        path = directory / name
        if path.resolve().parent != directory:
            raise ValueError("Snapshot file escapes its directory")
        data = path.read_bytes()
        if (
            len(data) != expected["bytes"]
            or hashlib.sha256(data).hexdigest() != expected["sha256"]
        ):
            raise ValueError(f"Snapshot file was changed: {name}")
    inventory = read_inventory(directory)
    sources = inventory["sources"]
    if {Path(source["path"]).name for source in sources} != expected_files - {"board-signature.txt"}:
        raise ValueError("Snapshot file coverage changed while reading")
    for source in sources:
        name = Path(source["path"]).name
        if source["sha256"] != manifest["files"][name]["sha256"]:
            raise ValueError(f"Snapshot file changed while reading: {name}")
    if inventory["board"].get("snapshot_id") != manifest[
        "snapshot_id"
    ] or not same_board(inventory["board"]["board_file"], manifest["board_file"]):
        raise ValueError("Snapshot generation or board identity mismatch")
    if (
        manifest["counts"] != inventory["counts"]
        or manifest["fingerprint"] != manifest["files"]["board-signature.txt"]["sha256"]
    ):
        raise ValueError("Snapshot counts or fingerprint mismatch")
    after = manifest_path.stat()
    if (after.st_size, after.st_mtime_ns) != (identity["bytes"], identity["mtime_ns"]):
        raise ValueError("Snapshot manifest changed while reading")
    inventory["manifest"] = manifest
    inventory["directory"] = str(directory)
    return inventory


def compare_snapshots(
    before: dict,
    after: dict,
    allowed_nets=None,
    *,
    allow_removals=False,
    allow_placement_changes=False,
    allow_rule_changes=False,
    allow_polygon_changes=False,
) -> dict:
    if not same_board(before["board"]["board_file"], after["board"]["board_file"]):
        raise ValueError("Snapshots describe different PCB paths")
    allowed = None if allowed_nets is None else set(allowed_nets)
    known = {row["net"] for row in after["tables"]["nets"]}
    if allowed is not None and (not allowed or not allowed <= known):
        raise ValueError("Allowed nets must be a nonempty subset of actual board nets")
    result = compare_inventories(before, after, allowed)
    if allow_removals:
        result["regressions"] = [
            r
            for r in result["regressions"]
            if r
            not in {
                "Baseline tracks removed or modified",
                "Baseline vias removed or modified",
            }
        ]
    if allow_placement_changes:
        result["regressions"] = [
            r for r in result["regressions"] if r != "Immutable pads records changed"
        ]
        pad_identity_fields = (
            "refdes",
            "pad",
            "net",
            "top_x_size_raw",
            "top_y_size_raw",
            "hole_size_raw",
        )
        if records(before["tables"]["pads"], fields=pad_identity_fields) != records(
            after["tables"]["pads"], fields=pad_identity_fields
        ):
            result["regressions"].append(
                "Pad identities, net assignments or dimensions changed"
            )
    if allow_rule_changes:
        result["regressions"] = [
            r for r in result["regressions"] if r != "Immutable rules records changed"
        ]
    for name in EXTRA_HEADERS:
        if (name in before["tables"]) != (name in after["tables"]):
            raise ValueError(f"Snapshot coverage differs for {name}")
        change = delta(
            records(before["tables"].get(name, [])),
            records(after["tables"].get(name, [])),
        )
        result["changes"][name] = change
        if not (change["added_count"] or change["removed_count"]):
            continue
        if name == "components" and not allow_placement_changes or name == "layers":
            result["regressions"].append(f"Immutable {name} records changed")
        if name == "polygons" and not allow_polygon_changes:
            result["regressions"].append("Polygon definitions changed")
        if name == "arcs" and change["removed_count"] and not allow_removals:
            result["regressions"].append("Baseline arcs removed or modified")
        changed_nets = {
            e["record"]["net"]
            for direction in ("added", "removed")
            for e in change[direction]
            if "net" in e["record"]
        }
        if allowed is not None and changed_nets - allowed:
            result["regressions"].append(f"{name} changes outside the allowed net set")
    result["limits"] = SNAPSHOT_LIMITS
    return result


def compare_drc_reports(
    baseline: Path, current: Path, expected_board: str = "", reject_categories=None
) -> dict:
    return compare_drc_data(
        read_drc(Path(baseline)), read_drc(Path(current)), expected_board, reject_categories
    )


def compare_drc_data(before, after, expected_board="", reject_categories=None):
    """Compare the same parsed report data that supplies the finding ledgers."""
    before_board = before["metadata"].get("PCB File")
    after_board = after["metadata"].get("PCB File")
    if not before_board or not after_board:
        raise ValueError("A compact DRC baseline comparison requires board capture receipts")
    if not same_board(before_board, after_board):
        raise ValueError("DRC reports describe different PCB paths")
    if expected_board and not same_board(expected_board, after_board):
        raise ValueError("DRC report does not identify the expected PCB")
    if before.get("format") != after.get("format"):
        raise ValueError("Exact DRC baseline comparison requires reports in the same format")
    changes = delta(before["findings"], after["findings"])
    coverage = delta(
        records(before["sections"], fields=("rule",)),
        records(after["sections"], fields=("rule",)),
    )
    regressions = []
    rejected = None if reject_categories is None else set(reject_categories)
    for entry in changes["added"]:
        if rejected is None or category(entry["record"]["rule"]) in rejected:
            regressions.append({"category": category(entry["record"]["rule"]), **entry})
    waiver_counts_available = before["waived"] is not None and after["waived"] is not None
    waiver_count_changed = before["waived"] != after["waived"] if waiver_counts_available else None
    changed = bool(regressions or coverage["added_count"] or coverage["removed_count"] or waiver_count_changed)
    return {
        "baseline": {k: v for k, v in before.items() if k != "findings"},
        "current": {k: v for k, v in after.items() if k != "findings"},
        "changes": changes,
        "processed_rule_changes": coverage,
        "waiver_count_changed": waiver_count_changed,
        "rejected_added_findings": regressions,
        "passed": False if changed else True if waiver_counts_available else None,
        "limits": [
            "Exact report occurrences are not independently verified physical defect changes.",
            "An absent finding does not prove a category was checked or passed.",
        ],
    }


def drc_ledger(report: dict, baseline=None) -> list[dict]:
    ledger = []
    for key, count in report["findings"].items():
        retained = min(count, baseline["findings"][key]) if baseline else 0
        for index in range(count):
            record = dict(key)
            ledger.append(
                {
                    "id": f"DRC-{len(ledger) + 1:04d}",
                    "category": category(record["rule"]),
                    **record,
                    "exact_baseline_match": index < retained,
                }
            )
    return ledger
