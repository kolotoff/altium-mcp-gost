"""Read-only validation using native queries and existing routing evidence."""

import asyncio
import json
import re
from collections import Counter
from html import escape
from pathlib import Path, PureWindowsPath

from .pcb_routing import (
    RoutingService,
    output_directory,
    summarize_drc_artifacts,
    validate_board_path,
    write_json,
)
from .routing_audit import read_snapshot, same_board
from .routing_operations import field_text


SCHEMA = "altium-mcp-project-validation/v1"
SCOPE = (
    "The verdict covers the recorded checks. Native ERC, complete DRC coverage, "
    "DRC freshness, and electrical or manufacturing sign-off are outside its scope."
)


def _stage(name, status, summary, *, action=None, counts=None, evidence=None):
    return {
        "name": name,
        "status": status,
        "summary": summary,
        "action": action,
        "counts": counts or {},
        "evidence": evidence or {},
    }


async def _project(execute, project, board):
    if not project:
        return _stage(
            "project",
            "skipped",
            "No live project was requested.",
            action="Supply the full path of the open PCB project to check its schematic.",
        ), None
    response = await execute(
        "project_variant_maintenance",
        {
            "exclude_footprint_names": [],
            "layer_moves": [f"PROJECT_VARIANT_COMPONENTS|{project}|{board}"],
        },
    )
    request = {
        key: response[key]
        for key in ("request_id", "execution_state")
        if response.get(key)
    }
    result = response.get("result")
    if response.get("success") and isinstance(result, str):
        result = json.loads(result)
    # The bridge preserves the structured result when it lifts a native
    # failure into the outer response. A missing prerequisite still skips
    # this stage even when that normalization has already happened.
    if isinstance(result, dict) and result.get("code") == "schematic_not_validated":
        return _stage(
            "project",
            "skipped",
            result.get("error", "The project schematic has not been validated."),
            action="Validate the project in Altium, then rerun this tool.",
            evidence=request,
        ), None
    if not response.get("success"):
        return _stage(
            "project",
            "error",
            response.get("error", "Altium query failed."),
            action=(
                "Inspect get_altium_command_status before retrying."
                if "execution_state" in request
                else "Check the Altium bridge and open project."
            ),
            evidence=request,
        ), None
    if not isinstance(result, dict):
        raise ValueError("Project query returned an invalid response")
    if not result.get("success"):
        return _stage(
            "project",
            "error",
            result.get("error", "Project query failed."),
            action="Check that the exact PCB belongs to the open project.",
            evidence=request,
        ), None
    if not same_board(project, result.get("path", "")) or not same_board(
        board, result.get("board_file", "")
    ):
        raise ValueError("Project query did not confirm both the project and PCB paths")
    components = result.get("components")
    if not isinstance(components, list) or any(
        not isinstance(row, dict)
        or not isinstance(row.get("designator"), str)
        or not isinstance(row.get("footprint"), str)
        for row in components
    ):
        raise ValueError("Project query returned invalid compiled components")
    return _stage(
        "project",
        "pass",
        "Read compiled components for the project that owns the PCB.",
        counts={"compiled_components": len(components)},
        evidence={
            **request,
            "project_path": result["path"],
            "board_file": result["board_file"],
        },
    ), components


async def _snapshot(execute, board, supplied, directory, unresolved):
    if not supplied and unresolved:
        return _stage(
            "pcb_snapshot",
            "skipped",
            "The prior Altium request is unresolved.",
            action="Inspect get_altium_command_status or supply an existing snapshot.",
        ), None
    snapshot_dir = supplied
    if not supplied:
        response = await RoutingService(execute).snapshot(
            board, str(directory / "pcb-snapshot")
        )
        if not response.get("success"):
            return _stage(
                "pcb_snapshot",
                "error",
                response.get("error", "PCB snapshot failed."),
                action=(
                    "Inspect get_altium_command_status before retrying."
                    if response.get("execution_state")
                    else "Activate the exact PCB or supply a snapshot."
                ),
                evidence={
                    key: response[key]
                    for key in ("request_id", "operation_directory", "execution_state")
                    if response.get(key)
                },
            ), None
        snapshot_dir = response["snapshot_directory"]
    snapshot = await asyncio.to_thread(read_snapshot, Path(snapshot_dir))
    if not same_board(board, snapshot["board"]["board_file"]):
        raise ValueError("Snapshot does not identify the expected PCB")
    manifest = snapshot["manifest"]
    return _stage(
        "pcb_snapshot",
        "pass",
        "Verified the sealed PCB inventory and its board path.",
        counts={
            key: snapshot["counts"][key]
            for key in (
                "components_count",
                "net_count",
                "nonredundant_ratsnest_connections",
                "connectivity_invalid_nets",
            )
        },
        evidence={
            "directory": snapshot["directory"],
            "source": "existing_snapshot" if supplied else "live_snapshot",
            "snapshot_id": manifest["snapshot_id"],
            "created_utc": manifest["created_utc"],
            "fingerprint": manifest["fingerprint"],
            "counts": manifest["counts"],
        },
    ), snapshot["tables"]["components"]


def _designators(schematic, pcb):
    if schematic is None or pcb is None:
        return _stage(
            "designators",
            "skipped",
            "The comparison requires the compiled schematic and a verified PCB snapshot.",
        )
    schematic_ids = Counter(row["designator"].strip() for row in schematic)
    pcb_ids = Counter(row["refdes"].strip() for row in pcb)
    footprinted = {
        row["designator"].strip() for row in schematic if row["footprint"].strip()
    }
    findings = {
        "footprinted_schematic_only": sorted(footprinted - pcb_ids.keys() - {""}),
        "pcb_only": sorted(pcb_ids.keys() - schematic_ids.keys() - {""}),
        "duplicate_schematic_designators": sorted(
            ref for ref, n in schematic_ids.items() if ref and n > 1
        ),
        "duplicate_pcb_designators": sorted(
            ref for ref, n in pcb_ids.items() if ref and n > 1
        ),
    }
    counts = {name: len(refs) for name, refs in findings.items()}
    counts.update(
        blank_schematic_designators=schematic_ids[""], blank_pcb_designators=pcb_ids[""]
    )
    if any(counts.values()):
        return _stage(
            "designators",
            "review",
            "The inventories contain designator differences.",
            action="Review the listed designators in the project and PCB, including intentional board-only parts.",
            counts=counts,
            evidence=findings,
        )
    return _stage(
        "designators",
        "pass",
        "Footprinted schematic designators and PCB component designators reconcile.",
        counts=counts,
    )


async def _drc(board, report, baseline, directory):
    if not report:
        return _stage(
            "native_drc",
            "skipped",
            "No existing native DRC report was supplied.",
            action="Supply an English native text DRC report for the exact PCB.",
        )
    summary = await asyncio.to_thread(
        summarize_drc_artifacts, report, board, baseline, str(directory / "native-drc")
    )
    counts = {"violations": summary["total"], "waived": summary["waived"]}
    if summary["format"] == "compact":
        counts["native_warnings"] = summary["warning_count"]
    if baseline:
        counts.update(
            added=summary["added_occurrences"], removed=summary["removed_occurrences"]
        )
    status, action = "pass", None
    notes = ["Read the supplied native DRC report and checked its totals."]
    if summary["board_identity_source"] == "caller":
        notes.append(
            "The compact report omits PCB identity. The caller supplied the board association."
        )
        status = "review"
        action = "Use a compact export with its PCB capture receipt to verify board identity."
    if summary["warning_count"]:
        notes.append("Altium reported native DRC warnings.")
        status = "review"
        action = "Review the native DRC warnings in the report."
    if baseline and summary["passed_comparison_policy"] is None:
        notes.append("The compact baseline comparison could not compare waiver counts.")
        status = "review"
        action = "Review the DRC comparison with the unavailable waiver counts in mind."
    if summary["total"] or summary["passed_comparison_policy"] is False:
        status = "fail"
        action = "Inspect the DRC ledger and any change in processed rules or waivers."
    return _stage(
        "native_drc",
        status,
        " ".join(notes),
        counts=counts,
        action=action,
        evidence={
            "summary_path": str(Path(summary["output_directory"]) / "drc-summary.json"),
            "ledger_path": str(
                Path(summary["output_directory"]) / "drc-all-findings.tsv"
            ),
            "categories": summary["categories"],
            "format": summary["format"],
            "board_identity_source": summary["board_identity_source"],
            "passed_baseline_comparison": summary["passed_comparison_policy"],
            "freshness_verified": False,
        },
    )


def _error(name, exc, action):
    return _stage(name, "error", str(exc) or type(exc).__name__, action=action)


def _markdown_text(value):
    return re.sub(r"([\\`*_\[\]])", r"\\\1", escape(" ".join(value.split())))


def _write_report(directory, inputs, stages):
    problems = [row for row in stages if row["status"] in {"error", "fail"}]
    gaps = [row for row in stages if row["status"] in {"review", "skipped"}]
    verdict = "fail" if problems else "incomplete" if gaps else "pass"
    next_actions = [
        {"stage": row["name"], "action": row["action"]}
        for row in problems + gaps
        if row["action"]
    ]
    report = {
        "schema": SCHEMA,
        "success": True,
        "verdict": verdict,
        "scope": SCOPE,
        "inputs": inputs,
        "stages": stages,
        "next_actions": next_actions,
    }
    json_path = directory / "validation.json"
    markdown_path = directory / "VALIDATION.md"
    lines = [
        "# Altium project validation",
        "",
        f"**Verdict** {verdict}",
        "",
        f"PCB {_markdown_text(inputs['expected_board'])}",
        "",
        SCOPE,
        "",
        "[Full findings and provenance](validation.json)",
        "",
        "## Checks",
    ]
    for row in stages:
        lines.extend(
            [
                "",
                f"### {row['name']} · {row['status']}",
                "",
                _markdown_text(row["summary"]),
            ]
        )
        if row["counts"]:
            lines.append("")
            lines.extend(
                f"- {key.replace('_', ' ')} **{count if count is not None else 'unavailable'}**"
                for key, count in row["counts"].items()
            )
        if "ledger_path" in row["evidence"]:
            lines.extend(["", "[Native DRC findings](native-drc/DRC_APPENDIX.md)"])
    if next_actions:
        lines.extend(["", "## Next actions", ""])
        lines.extend(f"- {_markdown_text(item['action'])}" for item in next_actions)
    with markdown_path.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines) + "\n")
    write_json(json_path, report)
    return {
        "schema": SCHEMA,
        "success": True,
        "verdict": verdict,
        "scope": SCOPE,
        "stages": [
            {
                "name": row["name"],
                "status": row["status"],
                "summary": row["summary"][:400],
                "counts": row["counts"],
            }
            for row in stages
        ],
        "next_actions": next_actions,
        "report_path": str(json_path),
        "markdown_path": str(markdown_path),
    }


async def validate_project(
    execute,
    expected_board,
    project_path="",
    snapshot_directory="",
    drc_report_path="",
    baseline_drc_report_path="",
    output="",
):
    board = str(PureWindowsPath(validate_board_path(expected_board)))
    project = ""
    if project_path:
        project = str(PureWindowsPath(field_text(project_path, "project_path")))
        if (
            not PureWindowsPath(project).is_absolute()
            or PureWindowsPath(project).suffix.lower() != ".prjpcb"
        ):
            raise ValueError("Project must be an absolute .PrjPcb path")
        if any(char in project + board for char in '|"'):
            raise ValueError("Project and PCB paths must contain no pipe or quote")
    if baseline_drc_report_path and not drc_report_path:
        raise ValueError("A baseline DRC report requires a current DRC report")

    directory = output_directory(output, "project-validation")
    try:
        project_check, schematic = await _project(execute, project, board)
    except (OSError, TypeError, ValueError) as exc:
        project_check = _error(
            "project", exc, "Check the compiled schematic and Altium bridge."
        )
        schematic = None
    try:
        pcb_check, pcb = await _snapshot(
            execute,
            board,
            snapshot_directory,
            directory,
            project_check["evidence"].get("execution_state"),
        )
    except (OSError, KeyError, TypeError, ValueError) as exc:
        pcb_check = _error(
            "pcb_snapshot", exc, "Supply an intact snapshot or activate the exact PCB."
        )
        pcb = None
    try:
        drc = await _drc(board, drc_report_path, baseline_drc_report_path, directory)
    except (OSError, ValueError) as exc:
        drc = _error(
            "native_drc",
            exc,
            "Check the DRC report format, board path, and any supplied baseline.",
        )
    inputs = {
        "expected_board": board,
        "project_path": project or None,
        "snapshot_directory": snapshot_directory or None,
        "drc_report_path": drc_report_path or None,
        "baseline_drc_report_path": baseline_drc_report_path or None,
    }
    return await asyncio.to_thread(
        _write_report,
        directory,
        inputs,
        [project_check, pcb_check, _designators(schematic, pcb), drc],
    )
