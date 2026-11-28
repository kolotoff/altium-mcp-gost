"""Artifact-oriented routing workflows. Live access is injected from the MCP bridge."""

from __future__ import annotations

import asyncio
import csv
import hashlib
import json
import shutil
import uuid
from collections import Counter
from pathlib import Path, PureWindowsPath

from . import routing_audit as audit
from .drc_compact import CAPTURE_SCHEMA, capture_path
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
from .signal_routing import plan_length_match, plan_pair


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


def validate_board_path(value):
    field_text(value, "expected_board")
    if (
        not PureWindowsPath(value).is_absolute()
        or PureWindowsPath(value).suffix.lower() != ".pcbdoc"
    ):
        raise ValueError("Expected board must be an absolute .PcbDoc path")
    return value


def _baseline(snapshot, directory, *, include_float_values=False):
    source_directory = Path(snapshot["directory"])
    source = source_directory / "board-signature.txt"
    shutil.copyfile(source, directory / "baseline-signature.txt")
    if (
        hashlib.sha256((directory / "baseline-signature.txt").read_bytes()).hexdigest()
        != snapshot["manifest"]["fingerprint"]
    ):
        raise ValueError("Baseline signature changed while staging the operation")
    if include_float_values and (
        sealed := snapshot["manifest"]["files"].get(audit.ROUTING_FLOAT_VALUES)
    ):
        values = (source_directory / audit.ROUTING_FLOAT_VALUES).read_bytes()
        if len(values) != sealed["bytes"] or hashlib.sha256(values).hexdigest() != sealed["sha256"]:
            raise ValueError("Baseline float values changed while staging the operation")
        (directory / f"baseline-{audit.ROUTING_FLOAT_VALUES}").write_bytes(values)


class RoutingService:
    def __init__(self, execute, continue_drc_warning=None):
        self.execute = execute
        self.continue_drc_warning = continue_drc_warning
        self._drc_tasks = set()

    async def _native(self, operation, board, directory, snapshot_id="", **params):
        response = await self.execute(
            "pcb_routing",
            {
                "operation": operation,
                "expected_board": validate_board_path(board),
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
        validate_board_path(expected_board)
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

    async def export_drc(self, expected_board, output=""):
        board = str(PureWindowsPath(validate_board_path(expected_board)))
        directory = output_directory(output, "native-drc")
        task = asyncio.create_task(self._export_drc(board, directory))
        self._drc_tasks.add(task)
        task.add_done_callback(self._drc_tasks.discard)
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            # The native command and its warning handler must finish together.
            task.add_done_callback(lambda done: done.exception() if not done.cancelled() else None)
            raise

    async def _export_drc(self, board, directory):
        watcher = None
        if self.continue_drc_warning is not None:
            watcher = asyncio.create_task(self.continue_drc_warning(directory))
        try:
            response = await self._native("native_drc", board, directory)
        finally:
            if watcher is not None:
                watcher.cancel()
                await asyncio.gather(watcher, return_exceptions=True)
        if not response["success"]:
            return {
                **response,
                "recovery": "Check the command receipt and DRC operation status before retrying.",
            }
        report_path = directory / "native-drc.txt"
        report = await asyncio.to_thread(audit.read_drc, report_path)
        request_id = response["request_id"]
        if (
            report.get("format") != "compact"
            or not audit.same_board(board, response["board_file"])
            or response.get("saved") is not False
            or not isinstance(response.get("pcb_modified_before"), bool)
            or not isinstance(response.get("pcb_modified_after"), bool)
            or not isinstance(request_id, str)
            or len(request_id) != 32
        ):
            raise ValueError("Native DRC did not confirm the board, report, and editor state")
        receipt = capture_path(report_path)
        write_json(receipt, {
            "schema": CAPTURE_SCHEMA,
            "board_file": response["board_file"],
            "request_id": request_id,
            "report_sha256": report["source"]["sha256"],
            "pcb_modified_before": response["pcb_modified_before"],
            "pcb_modified_after": response["pcb_modified_after"],
            "saved": False,
        })
        return {
            **response,
            "report_path": str(report_path),
            "capture_path": str(receipt),
            "violations": report["total"],
            "waived": report["waived"],
            "warning_count": sum(report["warnings"].values()),
            "rule_sections": len(report["sections"]),
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
        undo_group=False,
    ):
        before = audit.read_snapshot(Path(snapshot_directory))
        return await self._batch(before, operations, apply, output, allow_via_in_pad, undo_group)

    async def _batch(self, before, operations, apply, output, allow_via_in_pad, undo_group=False):
        plan = plan_batch(before, operations, allow_via_in_pad=allow_via_in_pad)
        directory = output_directory(output, "routing-batches")
        _baseline(before, directory, include_float_values=apply)
        (directory / "operations.tsv").write_text(batch_tsv(plan), encoding="utf-8-sig")
        write_json(
            directory / "plan.json", {
                **{k: v for k, v in plan.items() if k != "expected"}, "undo_group": undo_group,
            }
        )
        if not apply:
            return {
                "success": True,
                "applied": False,
                "operation_count": len(operations),
                "nets": plan["nets"],
                "baseline_fingerprint": plan["baseline_fingerprint"],
                "operation_directory": str(directory),
                "undo_group": undo_group,
            }
        snapshot_id = uuid.uuid4().hex
        result = await self._native(
            "batch",
            before["board"]["board_file"],
            directory,
            snapshot_id,
            allow_via_in_pad="true" if allow_via_in_pad else "false",
            undo_group="true" if undo_group else "false",
        )
        write_json(directory / "native-result.json", result)
        if not result["success"]:
            return {**result, "undo_group": undo_group}
        audit.seal_inventory(directory, snapshot_id)
        after = audit.read_snapshot(directory)
        verification = reconcile_batch(before, after, plan)
        write_json(directory / "reconciliation.json", verification)
        return {
            "success": verification["verified"],
            "applied": True,
            "completed_rows": result.get("completed_rows"),
            "undo_steps": result.get("undo_steps"),
            "verified": verification["verified"],
            "geometry_mismatches": verification["geometry_mismatches"],
            "regressions": verification["audit"]["regressions"],
            "operation_directory": str(directory),
            "snapshot_directory": str(directory),
            "native_drc_required": True,
            "saved": False,
        }

    async def signal_plan(self, kind, snapshot_directory, apply, output, **options):
        before = await asyncio.to_thread(audit.read_snapshot, Path(snapshot_directory))
        planner = {"pair": plan_pair, "length-match": plan_length_match}[kind]
        plan = await asyncio.to_thread(planner, before, **options)
        operations = plan.pop("operations")
        directory = output_directory(output, "signal-routing")
        path = directory / "signal-plan.json"
        write_json(path, {
            **plan, "operations": operations,
            "snapshot_directory": before["directory"],
            "baseline_fingerprint": before["manifest"]["fingerprint"],
            "parameters": options,
        })
        result = {
            "success": True, "applied": False, **plan, "operation_count": len(operations),
            "report_path": str(path), "native_drc_required": bool(operations),
            "limits": [
                "Models straight-edged board perimeter, track centerlines, pad envelopes, via copper and drill spacing, and conservative arc bounds.",
                "Use a corridor clear of keepouts, cutouts, fills, regions and poured copper.",
                "Run native DRC for scoped clearance, differential coupling and width after applying.",
            ],
        }
        if apply and operations:
            batch_directory = directory / "batch"
            try:
                result.update(await self._batch(
                    before, operations, True, str(batch_directory), False, undo_group=True
                ))
            except (ValueError, OSError) as error:
                result.update(success=False, error=str(error), operation_directory=str(batch_directory))
            if not result["success"] and result["applied"] is False:
                result["applied"] = None
                result.setdefault("recovery", "Inspect the operation receipt and live geometry before retrying.")
        return result

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
    reported_board = report["metadata"].get("PCB File")
    if reported_board and not audit.same_board(expected_board, reported_board):
        raise ValueError("Native DRC does not identify the expected board")
    if not reported_board and not PureWindowsPath(expected_board).is_absolute():
        raise ValueError("A standalone compact DRC report requires an absolute expected PCB path")
    baseline = audit.read_drc(Path(baseline_path)) if baseline_path else None
    comparison = (
        audit.compare_drc_data(baseline, report, expected_board, reject_categories)
        if baseline
        else None
    )
    directory = output_directory(output, "routing-drc")
    ledger = audit.drc_ledger(report, baseline)
    totals = Counter(row["category"] for row in ledger)
    warnings = report.get("warnings", {})
    identity_source = "capture" if report.get("capture") else "report" if reported_board else "caller"
    format_info = {
        "format": report.get("format", "classic"),
        "expected_board": expected_board,
        "board_identity_source": identity_source,
        "warning_count": sum(warnings.values()),
    }
    summary = {
        **format_info,
        "metadata": report["metadata"],
        "source": report["source"],
        "total": report["total"],
        "waived": report["waived"],
        "warnings": warnings,
        "capture": report.get("capture"),
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
    waived = report["waived"] if report["waived"] is not None else "unavailable"
    lines = [
        "# Native DRC occurrences",
        "",
        f"Violations **{report['total']}** · Waived **{waived}**",
        "",
        "Exact textual occurrence changes do not independently establish physical defect changes.",
    ]
    if warnings:
        lines.extend(["", "## Native warnings", ""])
        lines.extend(f"- {message} ({count})" for message, count in warnings.items())
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
        **format_info,
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
