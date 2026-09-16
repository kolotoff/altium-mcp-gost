"""Build a deterministic PCB test-access inventory from Altium readback JSON."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


MM_PER_MIL = 0.0254
GENERATED_NET = re.compile(r"^Net[A-Za-z0-9_]+$")


def load_payload(path: Path) -> Any:
    raw = path.read_bytes().decode("utf-8-sig", errors="replace")
    value = json.loads(raw)
    if isinstance(value, dict) and "result" in value:
        value = value["result"]
    if isinstance(value, dict) and "components" in value:
        value = value["components"]
    return value


def load_overrides(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("source-net overrides must be a JSON object")
    return {str(key).upper(): str(net).strip() for key, net in value.items() if str(net).strip()}


def source_net(designator: str, pad: str, net: str, overrides: dict[str, str]) -> str:
    for key in (f"{designator}:{pad}", f"{designator}.*", net):
        replacement = overrides.get(key.upper())
        if replacement:
            return replacement
    return net


def category_labels(categories: list[str]) -> str:
    labels = {
        "testpoint": "Test point",
        "solder-bridge": "SB control",
        "keystone-5016": "Keystone 5016",
        "through-hole-signal": "Through-hole signal pad",
    }
    return ", ".join(labels[value] for value in categories)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--components", type=Path, required=True)
    parser.add_argument("--pins", type=Path, required=True)
    parser.add_argument("--source-net-overrides", type=Path)
    parser.add_argument("--minimum-hole-mm", type=float, default=1.0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    components = load_payload(args.components)
    pin_records = load_payload(args.pins)
    if not isinstance(components, list) or not isinstance(pin_records, list):
        raise SystemExit("components and pins inputs must contain JSON arrays")
    if not any("hole_size" in pad for record in pin_records for pad in record.get("pins", [])):
        raise SystemExit("pin readback lacks hole_size; cannot verify the >= 1 mm selection rule")

    component_by_designator = {
        str(record.get("designator", "")): record
        for record in components
        if str(record.get("designator", ""))
    }
    pins_by_designator = {
        str(record.get("designator", "")): list(record.get("pins", []))
        for record in pin_records
        if str(record.get("designator", ""))
    }
    overrides = load_overrides(args.source_net_overrides)
    unresolved: list[str] = []
    items: list[dict[str, Any]] = []

    for designator, component in component_by_designator.items():
        footprint = str(component.get("footprint", "")).strip()
        footprint_upper = footprint.upper()
        categories: list[str] = []
        if "TESTPOINT" in footprint_upper:
            categories.append("testpoint")
        if designator.upper().startswith("SB"):
            categories.append("solder-bridge")
        if footprint_upper == "KEYSTONE 5016":
            categories.append("keystone-5016")

        pins = pins_by_designator.get(designator, [])
        eligible_holes = [
            pad
            for pad in pins
            if not str(pad.get("name", "")).upper().startswith("MP")
            and str(pad.get("net", "")).strip()
            and float(pad.get("hole_size") or 0.0) * MM_PER_MIL + 1e-9 >= args.minimum_hole_mm
        ]
        if eligible_holes:
            categories.append("through-hole-signal")
        if not categories:
            continue

        selected_pins = pins
        if categories == ["through-hole-signal"]:
            selected_pins = eligible_holes

        normalized_pins: list[dict[str, Any]] = []
        for pad in selected_pins:
            pad_name = str(pad.get("name", "")).strip()
            pcb_net = str(pad.get("net", "")).strip() or "NC"
            resolved_net = source_net(designator, pad_name, pcb_net, overrides)
            if GENERATED_NET.match(resolved_net):
                unresolved.append(f"{designator}.{pad_name}={resolved_net}")
            normalized_pins.append(
                {
                    "pad": pad_name,
                    "pcb_net": pcb_net,
                    "source_net": resolved_net,
                    "hole_mm": round(float(pad.get("hole_size") or 0.0) * MM_PER_MIL, 3),
                }
            )

        side = "bottom" if str(component.get("layer", "")).lower().startswith("bottom") else "top"
        items.append(
            {
                "designator": designator,
                "name": category_labels(categories),
                "categories": categories,
                "footprint": footprint,
                "side": side,
                "layer": str(component.get("layer", "")),
                "x": component.get("x"),
                "y": component.get("y"),
                "width": component.get("width"),
                "height": component.get("height"),
                "rotation": component.get("rotation"),
                "pins": normalized_pins,
            }
        )

    if unresolved:
        print("unresolved generated source nets: " + ", ".join(unresolved), file=sys.stderr)
        return 2

    order = {"testpoint": 0, "solder-bridge": 1, "keystone-5016": 2, "through-hole-signal": 3}
    items.sort(key=lambda item: (min(order[value] for value in item["categories"]), item["side"], item["designator"].upper()))
    counts = {key: sum(key in item["categories"] for item in items) for key in order}
    payload = {
        "minimum_hole_mm": args.minimum_hole_mm,
        "counts": counts,
        "components": items,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
