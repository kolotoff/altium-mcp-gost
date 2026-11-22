"""Presentation options shared by the end-user manual and its artwork."""

import math


def component_override(spec: dict, key: str, field: str) -> str:
    overrides = spec.get("component_overrides", {})
    entry = overrides.get(key) if isinstance(overrides, dict) else None
    value = entry.get(field) if isinstance(entry, dict) else None
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"component_overrides.{key}.{field} must contain text")
    return value.strip()


def interface_map_scale(spec: dict) -> float:
    value = spec.get("interface_map_scale", 1.0)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValueError("interface_map_scale must be a positive finite number")
    return float(value)
