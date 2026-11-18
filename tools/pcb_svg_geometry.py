"""Component transforms and designator aliases in native Altium PCB SVGs."""

from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass


_NUMBER = r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"
_COMPONENT_TRANSFORM = re.compile(
    rf"translate\(\s*({_NUMBER})[ ,]+({_NUMBER})\s*\)"
    rf"(?:\s*rotate\(\s*({_NUMBER})\s*\))?"
    rf"(?:\s*scale\(\s*({_NUMBER})(?:[ ,]+({_NUMBER}))?\s*\))?"
)


def parse_numbers(text: str) -> list[float]:
    return [float(value) for value in re.findall(_NUMBER, text)]


@dataclass(frozen=True)
class ComponentTransform:
    x: float
    y: float
    cosine: float
    sine: float
    scale_x: float
    scale_y: float

    def to_board(self, local_x: float, local_y: float) -> tuple[float, float]:
        x = local_x * self.scale_x
        y = local_y * self.scale_y
        return (self.x + x * self.cosine - y * self.sine,
                self.y + x * self.sine + y * self.cosine)


def component_transform(element: ET.Element) -> ComponentTransform | None:
    match = _COMPONENT_TRANSFORM.fullmatch(element.get("transform", "").strip())
    if not match:
        return None
    x, y, degrees, scale_x, scale_y = match.groups()
    angle = math.radians(float(degrees or 0))
    return ComponentTransform(float(x), float(y), math.cos(angle), math.sin(angle),
                              float(scale_x or 1), float(scale_y or scale_x or 1))


def exported_designator_aliases(element: ET.Element) -> list[str]:
    """Return logical designator aliases for panelized Altium SVG instances."""
    component = str(element.get("data-component") or "").strip()
    if not component:
        return []
    aliases = [component]
    instance = str(element.get("data-instance") or "").strip()
    if instance == component:
        aliases.append(f"{component}_1")
    else:
        match = re.fullmatch(re.escape(component) + r"-(\d+)", instance)
        if match:
            aliases.append(f"{component}_{match.group(1)}")
        elif instance:
            aliases.append(instance)
    return aliases
