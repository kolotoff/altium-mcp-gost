"""Read Altium's compact batch DRC text and its optional capture receipt."""

import json
import re
from collections import Counter
from pathlib import Path, PureWindowsPath


COMPACT_HEADER = "Warnings|Total|"
CAPTURE_SCHEMA = "altium-mcp-native-drc-capture/v1"


def capture_path(report_path):
    return report_path.with_name(report_path.name + ".capture.json")


def _capture_identity(report_path, source):
    path = capture_path(report_path)
    try:
        capture = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return None
    if not isinstance(capture, dict) or capture.get("schema") != CAPTURE_SCHEMA:
        raise ValueError(f"Invalid compact DRC capture receipt: {path}")
    board = capture.get("board_file")
    if (
        not isinstance(board, str)
        or not PureWindowsPath(board).is_absolute()
        or PureWindowsPath(board).suffix.lower() != ".pcbdoc"
        or not re.fullmatch(r"[0-9a-f]{32}", str(capture.get("request_id", "")))
        or capture.get("report_sha256") != source["sha256"]
    ):
        raise ValueError(
            f"Compact DRC capture receipt does not match the report: {path}"
        )
    return capture


def parse_compact_drc(text, source):
    """Check the header, per-rule counts, footer and native detail rows."""
    totals = {}
    sections = []
    warnings = Counter()
    rule_counts = Counter()
    details = []
    footer_seen = False
    for line in text.splitlines():
        if not line.strip():
            continue
        if footer_seen:
            details.append(line)
            continue
        kind, separator, entry = line.partition("|")
        name, last_separator, count_text = entry.rpartition("|")
        if (
            kind not in {"Warnings", "Violations", "Rule Violations"}
            or not separator
            or not last_separator
            or not name
            or not re.fullmatch(r"[0-9]+", count_text)
        ):
            raise ValueError(f"Invalid compact DRC summary row: {source['path']}")
        count = int(count_text)
        if name == "Total":
            if totals.setdefault(kind, count) != count:
                raise ValueError(f"Conflicting compact DRC totals: {source['path']}")
            footer_seen = kind == "Rule Violations"
        elif kind == "Rule Violations":
            sections.append({"rule": name, "count": count})
            rule_counts[name] += count
        elif kind == "Warnings":
            warnings[name] += count
        else:
            raise ValueError(f"Invalid compact DRC violation total: {source['path']}")

    findings = Counter()
    detail_counts = Counter()
    warning_details = Counter()
    labels = sorted(rule_counts.keys() | warnings.keys(), key=len, reverse=True)
    for line in details:
        label = next((name for name in labels if line.startswith(name + "|")), None)
        if label is None:
            raise ValueError(f"Compact DRC detail has no summary row: {source['path']}")
        fields = line[len(label) + 1 :].split("|", 2)
        if (
            len(fields) != 3
            or not fields[2].strip()
            or label in rule_counts
            and label in warnings
        ):
            raise ValueError(f"Invalid compact DRC detail row: {source['path']}")
        if label in warnings:
            warning_details[label] += 1
        else:
            detail_counts[label] += 1
            # Preserve supplied location columns when they distinguish occurrences.
            finding = "|".join(fields) if fields[0] or fields[1] else fields[2]
            findings[(("rule", label), ("finding", finding.strip()))] += 1

    total = totals.get("Violations")
    if (
        not sections
        or total != totals.get("Rule Violations")
        or total != findings.total()
        or rule_counts != detail_counts
        or totals.get("Warnings") != warnings.total()
        or any(count > warnings[label] for label, count in warning_details.items())
    ):
        raise ValueError(
            f"Compact DRC details and subtotals do not reconcile: {source['path']}"
        )
    return {
        "sections": sections,
        "warnings": dict(warnings),
        "findings": findings,
        "total": total,
        "waived": None,
    }


def read_compact_drc(path: Path, text, source):
    report = parse_compact_drc(text, source)
    capture = _capture_identity(path, source)
    metadata = {"PCB File": capture["board_file"]} if capture else {}
    return {
        **report,
        "format": "compact",
        "source": source,
        "metadata": metadata,
        "capture": capture,
    }
