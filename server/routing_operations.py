"""General explicit routing plans and exact requested-versus-actual reconciliation.

Adapted from Quilter reconcile_tracks.py patterns (MIT; LICENSES/Quilter-MIT.txt).
No board names, net classes, coordinate exceptions or fixed route widths occur here.
"""

from __future__ import annotations

from copy import deepcopy
import math

from .routing_audit import compare_snapshots, records
from .routing_geometry import via_overlaps_pad_bounds


GEOMETRY_FIELDS = {
    "track": ("x1_raw", "y1_raw", "x2_raw", "y2_raw", "width_raw", "layer_id"),
    "via": (
        "x_raw",
        "y_raw",
        "size_raw",
        "hole_size_raw",
        "low_layer_id",
        "high_layer_id",
    ),
    "pad": ("x_raw", "y_raw", "layer_id"),
    "arc": (
        "x_raw",
        "y_raw",
        "radius_raw",
        "start_angle",
        "end_angle",
        "width_raw",
        "layer_id",
    ),
}
TABLES = {"track": "tracks", "via": "vias", "polygon": "polygons"}


def integer(value, field):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError(f"{field} must be an exact integer")
    result = int(value)
    if str(result) != str(value) or not -2147483648 <= result <= 2147483647:
        raise ValueError(f"{field} must be a signed 32-bit decimal integer")
    return result


def field_text(value, field, *, allow_empty=False):
    if (
        not isinstance(value, str)
        or (not value and not allow_empty)
        or any(c in value for c in "\t\r\n\0")
    ):
        raise ValueError(f"{field} must be a single nonempty TSV field")
    return value


def geometry(kind, row):
    if kind == "polygon":
        return field_text(row["definition"], "polygon definition")
    fields = GEOMETRY_FIELDS[kind]
    values = []
    for key in fields:
        if kind == "arc" and key in {"start_angle", "end_angle"}:
            value = str(row[key])
            if not math.isfinite(float(value)) or any(c in value for c in "\t\r\n,"):
                raise ValueError("Arc angles must be finite native decimal strings")
            values.append(value)
        else:
            values.append(integer(row[key], key))
    if kind == "track":
        left, right = tuple(values[:2]), tuple(values[2:4])
        if left == right or values[4] <= 0:
            raise ValueError("Track must have positive width and distinct endpoints")
        if left > right:
            values[:4] = [*right, *left]
    if kind == "via" and not 0 < values[3] < values[2]:
        raise ValueError("Via hole must be positive and smaller than outer diameter")
    return ",".join(map(str, values))


def primitive_identity(kind, row):
    return (
        row["net"],
        geometry(kind, row),
        row.get("name", "") if kind == "polygon" else "",
    )


def plan_batch(before, operations, *, allow_via_in_pad=False):
    if not isinstance(operations, list) or not 1 <= len(operations) <= 256:
        raise ValueError("Batch requires 1-256 explicit operations")
    known = {r["net"] for r in before["tables"]["nets"]}
    layers = {int(r["layer_id"]) for r in before["tables"]["layers"]}
    expected = deepcopy(before)
    normalized = []
    old_targets = set()
    destinations = set()
    for index, operation in enumerate(operations):
        kind, action = operation.get("kind"), operation.get("action")
        if kind not in TABLES or action not in {"add", "edit", "remove"}:
            raise ValueError(
                "Supported operations are track/via/polygon add, edit or remove"
            )
        if kind == "polygon":
            raise ValueError("Use set_pcb_polygon_outline for polygon changes")
        old = operation.get("old")
        new = operation.get("new")
        if (
            action == "add"
            and old is not None
            or action == "remove"
            and new is not None
        ):
            raise ValueError("Add must omit old; remove must omit new")
        row = old if action == "remove" else new
        if not isinstance(row, dict):
            raise ValueError(
                "Each operation requires its exact old/new primitive record"
            )
        net = field_text(row.get("net"), "net", allow_empty=action != "add")
        if net and net not in known or action == "add" and not net:
            raise ValueError("New copper requires a known assigned board net")
        table = TABLES[kind]
        old_geometry = new_geometry = "-"
        if action != "add":
            if not isinstance(old, dict) or old.get("net") != net:
                raise ValueError("Edit must preserve the old net assignment")
            old_geometry = geometry(kind, old)
            identity = (kind, net, old_geometry)
            if identity in old_targets:
                raise ValueError("A primitive can be targeted only once per batch")
            old_targets.add(identity)
            matches = [
                r
                for r in before["tables"][table]
                if primitive_identity(kind, r) == primitive_identity(kind, old)
            ]
            if len(matches) != 1:
                raise ValueError("Old primitive must match exactly one snapshot record")
            expected["tables"][table].remove(matches[0])
        if action != "remove":
            new_geometry = geometry(kind, new)
            if kind == "track" and integer(new["layer_id"], "layer_id") not in layers:
                raise ValueError("Track layer is not in the snapshot copper stack")
            if kind == "via":
                if action == "add" and (
                    integer(new["low_layer_id"], "low_layer_id"),
                    integer(new["high_layer_id"], "high_layer_id"),
                ) != (1, 32):
                    raise ValueError(
                        "New vias currently support Top-Bottom through span only"
                    )
                if (
                    not {
                        integer(new["low_layer_id"], "low_layer_id"),
                        integer(new["high_layer_id"], "high_layer_id"),
                    }
                    <= layers
                ):
                    raise ValueError("Via span is absent from the copper stack")
                if action == "edit" and any(
                    int(new[k]) != int(old[k])
                    for k in ("low_layer_id", "high_layer_id")
                ):
                    raise ValueError(
                        "Editing an existing via must preserve its qualified drill span"
                    )
            if kind == "via":
                center = (int(new["x_raw"]), int(new["y_raw"]))
                for existing in before["tables"]["vias"]:
                    if (
                        int(existing["x_raw"]),
                        int(existing["y_raw"]),
                    ) == center and not (
                        old is not None
                        and primitive_identity(kind, existing)
                        == primitive_identity(kind, old)
                    ):
                        raise ValueError("Via center is already occupied")
                for pad in before["tables"]["pads"]:
                    if via_overlaps_pad_bounds(new, pad):
                        if not allow_via_in_pad or pad["net"] != net:
                            raise ValueError(
                                "Via in pad requires explicit allowance and the same assigned net"
                            )
            destination = (
                kind,
                new_geometry
                if kind != "via"
                else ",".join(new_geometry.split(",")[:2]),
            )
            if destination in destinations:
                raise ValueError("Duplicate destination geometry in batch")
            destinations.add(destination)
            # Reject overlap with any original primitive except this exact target.
            collisions = [
                r
                for r in before["tables"][table]
                if geometry(kind, r) == new_geometry
                and not (
                    old is not None
                    and primitive_identity(kind, r) == primitive_identity(kind, old)
                )
            ]
            if collisions:
                raise ValueError("Destination geometry is already occupied")
            record = {k: str(integer(new[k], k)) for k in GEOMETRY_FIELDS[kind]}
            record.update(net=net, selected="false")
            if kind == "track":
                record["layer"] = (
                    next(
                        r["layer"]
                        for r in before["tables"]["tracks"]
                        if r["layer_id"] == record["layer_id"]
                    )
                    if any(
                        r["layer_id"] == record["layer_id"]
                        for r in before["tables"]["tracks"]
                    )
                    else next(
                        r["layer_name"]
                        for r in before["tables"]["layers"]
                        if r["layer_id"] == record["layer_id"]
                    )
                )
            expected["tables"][table].append(record)
        normalized.append(
            {
                "row": index + 1,
                "kind": kind,
                "action": action,
                "net": net,
                "old_geometry": old_geometry,
                "new_geometry": new_geometry,
            }
        )
    return {
        "operations": normalized,
        "expected": expected,
        "nets": sorted({r["net"] for r in normalized if r["net"]}),
        "baseline_fingerprint": before["manifest"]["fingerprint"],
    }


def reconcile_batch(before, after, plan):
    audit = compare_snapshots(
        before, after, allowed_nets=plan["nets"] or None, allow_removals=True
    )
    mismatches = {}
    if records(before["tables"]["arcs"]) != records(after["tables"]["arcs"]):
        audit["regressions"].append("Unrequested arc changes during track/via batch")
    for table in ("tracks", "vias"):
        # Native legacy layer display strings are presentation, not geometry.
        fields = ("net",) + GEOMETRY_FIELDS["track" if table == "tracks" else "via"]
        expected = records(
            plan["expected"]["tables"][table], track=table == "tracks", fields=fields
        )
        actual = records(after["tables"][table], track=table == "tracks", fields=fields)
        if expected != actual:
            mismatches[table] = {
                "missing_count": sum((expected - actual).values()),
                "unexpected_count": sum((actual - expected).values()),
            }
    return {
        "verified": not mismatches and not audit["regressions"],
        "geometry_mismatches": mismatches,
        "audit": audit,
        "native_drc_required": True,
        "saved": False,
    }


def batch_tsv(plan):
    lines = ["kind\taction\tnet\told_geometry\tnew_geometry"]
    for row in plan["operations"]:
        lines.append(
            "\t".join(
                row[k]
                for k in ("kind", "action", "net", "old_geometry", "new_geometry")
            )
        )
    return "\n".join(lines) + "\n"
