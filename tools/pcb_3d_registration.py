"""Shared camera registration for orthographic Altium PCB 3D exports."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CameraRegistration:
    left_mm: float
    right_mm: float
    bottom_mm: float
    top_mm: float
    mirror_x: bool
    image_width_px: int
    image_height_px: int

    def validate_image_size(self, image_size: tuple[int, int]) -> None:
        if image_size != (self.image_width_px, self.image_height_px):
            raise ValueError(
                "3D registration image size does not match the PNG: "
                f"{(self.image_width_px, self.image_height_px)} vs {image_size}"
            )
        if self.right_mm <= self.left_mm or self.top_mm <= self.bottom_mm:
            raise ValueError("3D registration camera bounds are invalid")

    def pixel_for_physical(self, x_mm: float, y_mm: float) -> tuple[float, float]:
        fraction_x = (x_mm - self.left_mm) / (self.right_mm - self.left_mm)
        if self.mirror_x:
            fraction_x = 1.0 - fraction_x
        fraction_y = (self.top_mm - y_mm) / (self.top_mm - self.bottom_mm)
        return fraction_x * self.image_width_px, fraction_y * self.image_height_px


def load_registration(path: Path, side: str) -> CameraRegistration:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    if payload.get("coordinate_units") != "mm":
        raise ValueError(f"unsupported 3D registration units in {path}")
    entry = payload.get(side)
    if not isinstance(entry, dict):
        raise ValueError(f"3D registration has no {side!r} entry: {path}")
    return CameraRegistration(
        left_mm=float(entry["left_mm"]),
        right_mm=float(entry["right_mm"]),
        bottom_mm=float(entry["bottom_mm"]),
        top_mm=float(entry["top_mm"]),
        mirror_x=bool(entry.get("mirror_x", side == "bottom")),
        image_width_px=int(entry["image_width_px"]),
        image_height_px=int(entry["image_height_px"]),
    )

