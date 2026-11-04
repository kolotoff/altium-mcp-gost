"""Artifact-oriented routing workflows. Live access is injected from the MCP bridge."""

from __future__ import annotations

import csv
import hashlib
import json
import shutil
import uuid
from collections import Counter
from pathlib import Path, PureWindowsPath

from . import routing_audit as audit
from .routing_geometry import (
    audit_layer_usage,
    electrical_findings,
    preview_clearance,
    segment_segment,
)
from .routing_operations import (
    batch_tsv,
    field_text,
    geometry,
    integer,
    plan_batch,
    reconcile_batch,
)


GENERATED = Path(__file__).resolve().parents[1] / "generated"


def output_directory(value="", label="routing"):
    root = GENERATED.resolve()
    if value and not Path(value).is_absolute():
        raise ValueError("Explicit output directories must be absolute")
    path = Path(value).resolve() if value else root / label / uuid.uuid4().hex
    if not path.is_absolute() or not path.is_relative_to(root) or path == root:
        raise ValueError("Outputs must be inside the repository generated directory")
    path.mkdir(parents=True, exist_ok=False)
    return path


def write_json(path, value):
    with Path(path).open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")


def _board(value):
    field_text(value, "expected_board")
    if (
        not PureWindowsPath(value).is_absolute()
        or PureWindowsPath(value).suffix.lower() != ".pcbdoc"
    ):
        raise ValueError("Expected board must be an absolute .PcbDoc path")
    return value


def _baseline(snapshot, directory):
    source = Path(snapshot["directory"]) / "board-signature.txt"
    shutil.copyfile(source, directory / "baseline-signature.txt")
    if (
        hashlib.sha256((directory / "baseline-signature.txt").read_bytes()).hexdigest()
        != snapshot["manifest"]["fingerprint"]
    ):
        raise ValueError("Baseline signature changed while staging the operation")


class RoutingService:
    def __init__(self, execute):
        self.execute = execute

    async def _native(self, operation, board, directory, snapshot_id="", **params):
        response = await self.execute(
            "pcb_routing",
            {
                "operation": operation,
                "expected_board": _board(board),
                "operation_directory": str(directory),
                "snapshot_id": snapshot_id,
                **params,
            },
        )
        if not response.get("success", False):
            return {
                "success": False,
                "operation_directory": str(directory),
                **response,
                "recovery": "Inspect operation-status.json, batch-audit.tsv and fresh native geometry before retrying.",
            }
        result = response.get("result", {})
        if isinstance(result, str):
            result = json.loads(result)
        if not isinstance(result, dict):
            raise ValueError("Native routing response must be an object")
        return {
            "success": True,
            **result,
            "operation_directory": str(directory),
            "request_id": response.get("request_id"),
        }

    async def snapshot(self, expected_board, output=""):
        _board(expected_board)
        directory = output_directory(output, "routing-snapshots")
        snapshot_id = uuid.uuid4().hex
        response = await self._native(
            "snapshot", expected_board, directory, snapshot_id
        )
        if not response["success"]:
            return response
        manifest = audit.seal_inventory(directory, snapshot_id)
        return {
            "success": True,
            "snapshot_directory": str(directory),
            "snapshot_id": snapshot_id,
            "board_file": manifest["board_file"],
            "fingerprint": manifest["fingerprint"],
            "counts": manifest["counts"],
            "limits": manifest["limits"],
        }

    async def selectors(
        self, operation, snapshot_directory, selectors, output="", zoom=False
    ):
        before = audit.read_snapshot(Path(snapshot_directory))
        if not isinstance(selectors, list) or not 1 <= len(selectors) <= 256:
            raise ValueError("Provide 1-256 object selectors")
        known = {r["net"] for r in before["tables"]["nets"]}
        layers = {int(r["layer_id"]) for r in before["tables"]["layers"]}
        lines = ["kind\tnet\tgeometry\tlayer_id"]
        for selector in selectors:
            kind = selector.get("kind", "all")
            permitted = (
                {"track", "via", "pad", "arc"}
                if operation == "rules"
                else {"all", "track", "via", "pad", "arc", "polygon", "connection"}
            )
            if kind not in permitted:
                raise ValueError("Unsupported selector kind")
            net = field_text(selector.get("net"), "net")
            if net not in known:
                raise ValueError(f"Unknown net: {net}")
            record = selector.get("record")
            if record is not None and (
                kind not in {"track", "via", "pad", "arc"} or record.get("net") != net
            ):
                raise ValueError(
                    "Exact records require track/via/pad/arc kind and matching net"
                )
            key = geometry(kind, record) if record is not None else ""
            layer = integer(selector.get("layer_id", 1), "layer_id")
            if operation == "rules" and (not key or layer not in layers):
                raise ValueError(
                    "Rule queries require an exact existing primitive and an actual copper layer"
                )
            lines.append("\t".join((kind, net, key, str(layer))))
        directory = output_directory(output, "routing-inspection")
        _baseline(before, directory)
        (directory / "selectors.tsv").write_text(
            "\n".join(lines) + "\n", encoding="utf-8-sig"
        )
        result = await self._native(
            operation,
            before["board"]["board_file"],
            directory,
            zoom="true" if zoom else "false",
        )
        write_json(directory / "result.json", result)
        if operation == "rules" and result["success"]:
            return {
                "success": True,
                "object_count": len(result.get("objects", [])),
                "objects": result.get("objects", [])[:8],
                "report_path": str(directory / "result.json"),
                "scope": result.get("scope"),
            }
        return result

    async def batch(
        self,
        snapshot_directory,
        operations,
        apply=False,
        output="",
        allow_via_in_pad=False,
    ):
        before = audit.read_snapshot(Path(snapshot_directory))
        plan = plan_batch(before, operations, allow_via_in_pad=allow_via_in_pad)
        directory = output_directory(output, "routing-batches")
        _baseline(before, directory)
        (directory / "operations.tsv").write_text(batch_tsv(plan), encoding="utf-8-sig")
        write_json(
            directory / "plan.json", {k: v for k, v in plan.items() if k != "expected"}
        )
        if not apply:
            return {
                "success": True,
                "applied": False,
                "operation_count": len(operations),
                "nets": plan["nets"],
                "baseline_fingerprint": plan["baseline_fingerprint"],
                "operation_directory": str(directory),
            }
        snapshot_id = uuid.uuid4().hex
        result = await self._native(
            "batch",
            before["board"]["board_file"],
            directory,
            snapshot_id,
            allow_via_in_pad="true" if allow_via_in_pad else "false",
        )
        write_json(directory / "native-result.json", result)
        if not result["success"]:
            return result
        audit.seal_inventory(directory, snapshot_id)
        after = audit.read_snapshot(directory)
        verification = reconcile_batch(before, after, plan)
        write_json(directory / "reconciliation.json", verification)
        return {
            "success": verification["verified"],
            "applied": True,
            "completed_rows": result.get("completed_rows"),
            "verified": verification["verified"],
            "geometry_mismatches": verification["geometry_mismatches"],
            "regressions": verification["audit"]["regressions"],
            "operation_directory": str(directory),
            "snapshot_directory": str(directory),
            "native_drc_required": True,
            "saved": False,
        }

    async def polygon(
        self, snapshot_directory, name, net, layer_id, vertices, apply=False, output=""
    ):
        before = audit.read_snapshot(Path(snapshot_directory))
        field_text(name, "polygon name")
        field_text(net, "net")
        if net not in {r["net"] for r in before["tables"]["nets"]}:
            raise ValueError("Unknown polygon net")
        layer = integer(layer_id, "layer_id")
        if layer not in {int(r["layer_id"]) for r in before["tables"]["layers"]}:
            raise ValueError("Polygon layer is absent from the copper stack")
        if not isinstance(vertices, list) or any(
            not isinstance(pair, (list, tuple)) or len(pair) != 2 for pair in vertices
        ):
            raise ValueError("Vertices must be x/y pairs")
        points = [tuple(integer(v, "vertex") for v in pair) for pair in vertices]
        if points and points[0] == points[-1]:
            points.pop()
        if (
            not 3 <= len(points) <= 256
            or any(len(p) != 2 for p in points)
            or len(set(points)) != len(points)
        ):
            raise ValueError("Polygon requires 3-256 distinct x/y vertex pairs")
        if (
            sum(
                a[0] * b[1] - b[0] * a[1]
                for a, b in zip(points, points[1:] + points[:1])
            )
            == 0
        ):
            raise ValueError("Polygon must have nonzero area")
        edges = list(zip(points, points[1:] + points[:1]))
        for i, (a, b) in enumerate(edges):
            for j, (c, d) in enumerate(edges[:i]):
                if (i - j) % len(points) in {1, len(points) - 1}:
                    continue
                if segment_segment(a, b, c, d) == 0:
                    raise ValueError("Polygon boundary self-intersects")
        matches = [r for r in before["tables"]["polygons"] if r["name"] == name]
        if len(matches) > 1:
            raise ValueError("Polygon name is ambiguous")
        old = matches[0] if matches else None
        if old and (old["net"] != net or int(old["layer_id"]) != layer):
            raise ValueError("Outline edits preserve the existing polygon net/layer")
        directory = output_directory(output, "routing-polygons")
        _baseline(before, directory)
        lines = [
            "action\tname\tnet\tlayer_id\told_definition",
            "\t".join(
                (
                    "edit" if old else "add",
                    name,
                    net,
                    str(layer),
                    old["definition"] if old else "-",
                )
            ),
        ]
        lines.extend(f"{x}\t{y}" for x, y in points)
        (directory / "polygon.tsv").write_text(
            "\n".join(lines) + "\n", encoding="utf-8-sig"
        )
        if not apply:
            return {
                "success": True,
                "applied": False,
                "action": "edit" if old else "add",
                "vertex_count": len(points),
                "operation_directory": str(directory),
            }
        snapshot_id = uuid.uuid4().hex
        result = await self._native(
            "polygon", before["board"]["board_file"], directory, snapshot_id
        )
        write_json(directory / "native-result.json", result)
        if not result["success"]:
            return result
        audit.seal_inventory(directory, snapshot_id)
        after = audit.read_snapshot(directory)
        comparison = audit.compare_snapshots(
            before, after, allowed_nets=[net], allow_polygon_changes=True
        )
        actual = [r for r in after["tables"]["polygons"] if r["name"] == name]
        verified = len(actual) == 1
        if verified:
            segments = [s.split(",") for s in actual[0]["definition"].split(";")[1:]]
            verified = (
                actual[0]["net"] == net
                and int(actual[0]["layer_id"]) == layer
                and all(
                    len(s) == 8 and s[0] == "0" and all(float(v) == 0 for v in s[3:])
                    for s in segments
                )
                and [(int(s[1]), int(s[2])) for s in segments] == points
            )
            if old:
                verified = (
                    verified
                    and old["definition"].split(";")[0]
                    == actual[0]["definition"].split(";")[0]
                )
            else:
                settings = actual[0]["definition"].split(";")[0].split(",")
                # Native eSignalLayerPolygon, ePolySolid,
                # ePolygonPourOver_SameNet, RemoveDead=True.
                verified = (
                    verified
                    and len(settings) == 14
                    and settings[:4] == ["0", "5", "1", "true"]
                )
        before_other = [r for r in before["tables"]["polygons"] if r["name"] != name]
        after_other = [r for r in after["tables"]["polygons"] if r["name"] != name]
        verified = (
            verified
            and audit.records(before_other) == audit.records(after_other)
            and all(
                audit.records(before["tables"][table], track=table == "tracks")
                == audit.records(after["tables"][table], track=table == "tracks")
                for table in ("tracks", "vias", "arcs")
            )
            and not comparison["regressions"]
        )
        write_json(
            directory / "reconciliation.json",
            {"verified": verified, "comparison": comparison},
        )
        return {
            "success": verified,
            "applied": True,
            "verified": verified,
            "snapshot_directory": str(directory),
            "repour_required": True,
            "native_drc_required": True,
            "saved": False,
        }

    async def repour(self, snapshot_directory, apply=False, output=""):
        before = audit.read_snapshot(Path(snapshot_directory))
        directory = output_directory(output, "routing-repour")
        _baseline(before, directory)
        if not apply:
            return {
                "success": True,
                "applied": False,
                "polygon_count": len(before["tables"]["polygons"]),
                "operation_directory": str(directory),
            }
        snapshot_id = uuid.uuid4().hex
        result = await self._native(
            "repour", before["board"]["board_file"], directory, snapshot_id
        )
        write_json(directory / "native-result.json", result)
        if not result["success"]:
            return result
        audit.seal_inventory(directory, snapshot_id)
        after = audit.read_snapshot(directory)
        comparison = audit.compare_snapshots(before, after, allow_removals=True)
        write_json(directory / "comparison.json", comparison)
        return {
            "success": True,
            "repour_requested": True,
            "copper_observations": result.get("copper_observations"),
            "snapshot_directory": str(directory),
            "regressions_requiring_review": comparison["regressions"],
            "native_drc_required": True,
            "saved": False,
        }

    async def undo(self, snapshot_directory, steps=1, apply=False, output=""):
        before = audit.read_snapshot(Path(snapshot_directory))
        steps = integer(steps, "steps")
        if not 1 <= steps <= 256:
            raise ValueError("Undo requires 1-256 steps")
        directory = output_directory(output, "routing-undo")
        _baseline(before, directory)
        if not apply:
            return {
                "success": True,
                "applied": False,
                "steps": steps,
                "operation_directory": str(directory),
            }
        snapshot_id = uuid.uuid4().hex
        result = await self._native(
            "undo",
            before["board"]["board_file"],
            directory,
            snapshot_id,
            steps=str(steps),
        )
        write_json(directory / "native-result.json", result)
        if not result["success"]:
            return result
        audit.seal_inventory(directory, snapshot_id)
        comparison = audit.compare_snapshots(
            before,
            audit.read_snapshot(directory),
            allow_removals=True,
            allow_polygon_changes=True,
        )
        write_json(directory / "comparison.json", comparison)
        return {
            "success": True,
            "undo_requested": steps,
            "snapshot_directory": str(directory),
            "saved": False,
            "verification": "Compare this snapshot with the intended pre-edit snapshot; an Undo request alone does not prove restoration.",
        }


def compare_snapshot_artifacts(baseline, current, output="", **policy):
    result = audit.compare_snapshots(
        audit.read_snapshot(Path(baseline)),
        audit.read_snapshot(Path(current)),
        **policy,
    )
    directory = output_directory(output, "routing-comparisons")
    write_json(directory / "comparison.json", result)
    return {
        "success": True,
        "passed_policy": not result["regressions"],
        "regressions": result["regressions"],
        "remaining_reduction": result["remaining_reduction"],
        "newly_complete_nets": result["newly_complete_nets"],
        "changed_net_count": len(result["changed_nets"]),
        "report_path": str(directory / "comparison.json"),
    }


def summarize_drc_artifacts(
    report_path, expected_board, baseline_path="", output="", reject_categories=None
):
    field_text(expected_board, "expected_board")
    if PureWindowsPath(expected_board).suffix.lower() != ".pcbdoc":
        raise ValueError("Expected DRC board identity must end in .PcbDoc")
    report = audit.read_drc(Path(report_path))
    if not audit.same_board(expected_board, report["metadata"]["PCB File"]):
        raise ValueError("Native DRC does not identify the expected board")
    baseline = audit.read_drc(Path(baseline_path)) if baseline_path else None
    comparison = (
        audit.compare_drc_reports(
            Path(baseline_path), Path(report_path), expected_board, reject_categories
        )
        if baseline
        else None
    )
    directory = output_directory(output, "routing-drc")
    ledger = audit.drc_ledger(report, baseline)
    totals = Counter(row["category"] for row in ledger)
    summary = {
        "metadata": report["metadata"],
        "source": report["source"],
        "total": report["total"],
        "waived": report["waived"],
        "categories": dict(totals),
        "sections": report["sections"],
        "comparison": comparison,
        "board_identity_absolute": PureWindowsPath(expected_board).is_absolute(),
        "live_board_identity_verified": False,
    }
    write_json(directory / "drc-summary.json", summary)
    write_json(directory / "electrical-findings.json", electrical_findings(ledger))
    with (directory / "drc-all-findings.tsv").open(
        "x", encoding="utf-8", newline=""
    ) as output_file:
        writer = csv.DictWriter(
            output_file,
            fieldnames=["id", "category", "rule", "finding", "exact_baseline_match"],
            delimiter="\t",
        )
        writer.writeheader()
        writer.writerows(ledger)
    lines = [
        "# Native DRC occurrences",
        "",
        f"Total: {report['total']}; waived: {report['waived']}",
        "",
        "Exact textual occurrence changes do not independently establish physical defect changes.",
    ]
    for row in ledger:
        lines.extend(
            [
                "",
                f"## {row['id']} — {row['category']}",
                "",
                row["rule"],
                "",
                row["finding"],
            ]
        )
    (directory / "DRC_APPENDIX.md").write_text("\n".join(lines), encoding="utf-8")
    return {
        "success": True,
        "total": report["total"],
        "waived": report["waived"],
        "categories": dict(totals),
        "added_occurrences": comparison["changes"]["added_count"]
        if comparison
        else None,
        "removed_occurrences": comparison["changes"]["removed_count"]
        if comparison
        else None,
        "passed_comparison_policy": comparison["passed"] if comparison else None,
        "output_directory": str(directory),
        "board_identity_absolute": PureWindowsPath(expected_board).is_absolute(),
        "live_board_identity_verified": False,
    }


def snapshot_observations(kind, snapshot_directory, output="", **options):
    snapshot = audit.read_snapshot(Path(snapshot_directory))
    result = (
        audit_layer_usage(snapshot, **options)
        if kind == "layers"
        else preview_clearance(snapshot, **options)
    )
    directory = output_directory(output, "routing-audits")
    path = directory / (
        "layer-usage.json" if kind == "layers" else "clearance-preview.json"
    )
    write_json(path, result)
    compact = {
        k: v
        for k, v in result.items()
        if k not in {"violations", "observations", "candidate_conflicts"}
    }
    if kind == "layers":
        compact["layers"] = {
            key: {
                **{k: v for k, v in value.items() if k != "nets"},
                "net_count": len(value["nets"]),
                "sample_nets": value["nets"][:8],
            }
            for key, value in result["layers"].items()
        }
    return {
        "success": True,
        "report_path": str(path),
        **compact,
        "exception_count": len(result.get("violations", []))
        if kind == "layers"
        else result["modeled_conflict_count"],
    }


def operation_status(operation_directory):
    path = Path(operation_directory).resolve()
    if not path.is_relative_to(GENERATED.resolve()):
        raise ValueError("Operation directory must be under generated")
    result = {"operation_directory": str(path)}
    for name in ("operation-status.json", "native-result.json", "reconciliation.json"):
        if (path / name).exists():
            value = json.loads((path / name).read_text(encoding="utf-8-sig"))
            if name == "reconciliation.json":
                value = {
                    k: v for k, v in value.items() if k not in {"audit", "comparison"}
                }
            if name == "native-result.json" and "polygon_definition" in value:
                definition = value.pop("polygon_definition")
                value["polygon_vertex_count"] = len(definition.split(";")) - 1
                value["full_result_path"] = str(path / name)
            result[name] = value
    result["snapshot_complete"] = (path / "manifest.json").exists()
    return result
