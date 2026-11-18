"""Field recognition for Altium's classic English .drc reports."""

import re


_COUNTS = {"Rule Violations", "Violations Detected", "Waived Violations"}
_TEXT = {"Processing Rule", "PCB File", "Date", "Time", "Time Elapsed", "ERROR"}


def classic_fields(text: str, *, strict_counts: bool = False):
    """Yield named report fields with parsed counts and verbatim finding text."""
    parse_count = re.fullmatch if strict_counts else re.match
    for line in text.splitlines():
        if line.startswith("   Violation between "):
            yield "finding", line.strip()
            continue
        name, colon, value = line.strip().partition(":")
        if not colon:
            continue
        name, value = name.rstrip(), value.strip()
        if name in _TEXT:
            yield name, value
        elif name in _COUNTS and (match := parse_count(r"\d+", value)):
            yield name, int(match[0])
