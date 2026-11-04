"""Offline routing audits. Live document operations are available through MCP."""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.pcb_routing import (
    compare_snapshot_artifacts,
    output_directory,
    snapshot_observations,
    summarize_drc_artifacts,
    write_json,
)
from server.routing_audit import compare_inventories, read_inventory


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    compare = sub.add_parser("compare")
    compare.add_argument("baseline")
    compare.add_argument("current")
    compare.add_argument("--allowed-nets", type=Path)
    compare.add_argument("--allow-removals", action="store_true")
    compare.add_argument(
        "--legacy-tsv",
        action="store_true",
        help="Read unsealed donor exports; not valid mutation baselines",
    )
    drc = sub.add_parser("drc")
    drc.add_argument("report")
    drc.add_argument("--expected-board", required=True)
    drc.add_argument("--baseline", default="")
    layers = sub.add_parser("layers")
    layers.add_argument("snapshot")
    layers.add_argument("policy", type=Path)
    clearance = sub.add_parser("clearance")
    clearance.add_argument("snapshot")
    clearance.add_argument("segments", type=Path)
    clearance.add_argument("--clearance-mm", type=float, required=True)
    for command in (compare, drc, layers, clearance):
        command.add_argument("--output-directory", default="")
    args = parser.parse_args(argv)
    try:
        if args.command == "compare":
            allowed = (
                args.allowed_nets.read_text(encoding="utf-8-sig").splitlines()
                if args.allowed_nets
                else None
            )
            if args.legacy_tsv:
                result = compare_inventories(
                    read_inventory(Path(args.baseline)),
                    read_inventory(Path(args.current)),
                    set(allowed) if allowed is not None else None,
                )
                directory = output_directory(
                    args.output_directory, "legacy-routing-comparisons"
                )
                write_json(directory / "comparison.json", result)
                result = {
                    "passed_policy": not result["regressions"],
                    "regressions": result["regressions"],
                    "report_path": str(directory / "comparison.json"),
                }
            else:
                result = compare_snapshot_artifacts(
                    args.baseline,
                    args.current,
                    args.output_directory,
                    allowed_nets=allowed,
                    allow_removals=args.allow_removals,
                )
        elif args.command == "drc":
            result = summarize_drc_artifacts(
                args.report, args.expected_board, args.baseline, args.output_directory
            )
        elif args.command == "layers":
            policy = json.loads(args.policy.read_text(encoding="utf-8-sig"))
            result = snapshot_observations(
                "layers", args.snapshot, args.output_directory, **policy
            )
        else:
            segments = json.loads(args.segments.read_text(encoding="utf-8-sig"))
            result = snapshot_observations(
                "clearance",
                args.snapshot,
                args.output_directory,
                segments=segments,
                clearance_mm=args.clearance_mm,
            )
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return (
            1
            if result.get("passed_policy") is False
            or result.get("passed_comparison_policy") is False
            or result.get("exception_count", 0) > 0
            else 0
        )
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
