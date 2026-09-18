"""Export auditable connector-pin, source-net, firmware-port and power maps.

The input is the reviewed end-user board-description JSON.  It must retain
both the physical PCB pad net and the named source-side net for every pin.
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path


FIELDS = (
    "board", "connector", "pin", "connector_net", "source_net",
    "function", "interface_group", "ardupilot_port", "mcu_peripheral",
    "mcu_pin", "power_source_net", "power_voltage", "power_path",
    "power_domain", "trace_status", "trace_note",
)


def pin_sort_key(pin: str) -> tuple[str, int]:
    prefix = "".join(ch for ch in pin if not ch.isdigit())
    number = "".join(ch for ch in pin if ch.isdigit())
    return prefix, int(number) if number else 0


def flatten(spec: dict) -> list[dict[str, str]]:
    board = str(spec.get("board_id", "")).strip()
    if not board:
        raise ValueError("spec is missing board_id")
    records: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for group in spec["connector_groups"]:
        for item in group["items"]:
            connector = str(item["designator"])
            for pin in item["pins"]:
                number = str(pin["pin"])
                key = connector, number
                if key in seen:
                    raise ValueError(f"duplicate connector/pin: {connector}/{number}")
                seen.add(key)
                if "connector_net" not in pin:
                    raise ValueError(f"missing physical PCB net: {connector}/{number}")
                source_net = str(pin["net"])
                connector_net = str(pin["connector_net"])
                if source_net.startswith("Net"):
                    raise ValueError(f"unresolved source net: {connector}/{number} {source_net}")
                if not connector_net:
                    trace_status = "unconnected"
                elif source_net == "NC":
                    trace_status = "source_not_assigned"
                elif source_net == connector_net:
                    trace_status = "direct_net"
                else:
                    trace_status = "traced_source"
                records.append({
                    "board": board,
                    "connector": connector,
                    "pin": number,
                    "connector_net": connector_net,
                    "source_net": source_net,
                    "function": str(pin.get("function", "")),
                    "interface_group": str(pin.get("group", "")),
                    "ardupilot_port": str(pin.get("ardupilot_port", "")),
                    "mcu_peripheral": str(pin.get("mcu_peripheral", "")),
                    "mcu_pin": str(pin.get("mcu_pin", "")),
                    "power_source_net": str(pin.get("power_source_net", "")),
                    "power_voltage": str(pin.get("power_voltage", "")),
                    "power_path": str(pin.get("power_path", "")),
                    "power_domain": str(pin.get("power_domain", "")),
                    "trace_status": trace_status,
                    "trace_note": str(pin.get("trace_note", "")),
                })
    return sorted(records, key=lambda record: (record["connector"], pin_sort_key(record["pin"])))


def interface_mappings(records: list[dict[str, str]], prefix: str) -> list[dict]:
    groups: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for record in records:
        port = record["ardupilot_port"]
        if port.startswith(prefix):
            peripheral = record["mcu_peripheral"].split("_", 1)[0]
            groups[port, peripheral].append(record)
    result = []
    for (port, peripheral), pins in sorted(groups.items()):
        result.append({
            "ardupilot_port": port,
            "mcu_peripheral": peripheral,
            "connector_pins": [
                {"connector": row["connector"], "pin": row["pin"],
                 "connector_net": row["connector_net"],
                 "source_net": row["source_net"], "mcu_pin": row["mcu_pin"],
                 "mcu_signal": row["mcu_peripheral"]}
                for row in pins
            ],
        })
    return result


def export(spec: dict, csv_path: Path, json_path: Path) -> dict:
    records = flatten(spec)
    payload = {
        "schema_version": 1,
        "board": spec["board_id"],
        "firmware_source": spec.get("firmware_source", ""),
        "records": records,
        "uart_mappings": interface_mappings(records, "SERIAL"),
        "i2c_mappings": interface_mappings(records, "I2C bus"),
        "trace_exceptions": [
            {"connector": row["connector"], "pin": row["pin"],
             "connector_net": row["connector_net"],
             "reason": row["trace_note"]}
            for row in records if row["trace_status"] == "source_not_assigned"
        ],
    }
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(records)
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.data.read_text(encoding="utf-8-sig"))
    payload = export(spec, args.csv, args.json)
    print(f"{len(payload['records'])} pins, {len(payload['uart_mappings'])} serial mappings, "
          f"{len(payload['i2c_mappings'])} I2C mappings, "
          f"{len(payload['trace_exceptions'])} trace exceptions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
