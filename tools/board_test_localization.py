"""Localization helpers shared by board test-description generators."""

from __future__ import annotations

from typing import Any, Mapping


LANGUAGE_MODES = ("source", "ru", "en", "zh", "en-zh")

UI_TEXT = {
    "footer": {"ru": "ТЕСТОВЫЙ ДОСТУП К ПЛАТЕ", "en": "BOARD TEST ACCESS", "zh": "电路板测试访问"},
    "scope": {"ru": "Область", "en": "Scope", "zh": "范围"},
    "result_rule": {"ru": "Результат и правило", "en": "Result and rule", "zh": "结果与规则"},
    "pad": {"ru": "Контакт", "en": "Pad", "zh": "焊盘"},
    "pcb_net": {"ru": "Цепь платы", "en": "PCB net", "zh": "PCB 网络"},
    "source_net": {"ru": "Исходная цепь", "en": "Source net", "zh": "源网络"},
    "hole_mm": {"ru": "Отверстие, мм", "en": "Hole mm", "zh": "孔径 mm"},
    "top": {"ru": "Верхняя сторона", "en": "Top", "zh": "顶面"},
    "bottom": {"ru": "Нижняя сторона", "en": "Bottom", "zh": "底面"},
    "map_top": {"source": "ВЕРХНЯЯ СТОРОНА КАРТА ТЕСТОВОГО ДОСТУПА", "ru": "ВЕРХНЯЯ СТОРОНА КАРТА ТЕСТОВОГО ДОСТУПА", "en": "TOP SIDE TEST ACCESS MAP", "zh": "顶面测试访问图"},
    "map_bottom": {"source": "НИЖНЯЯ СТОРОНА КАРТА ТЕСТОВОГО ДОСТУПА", "ru": "НИЖНЯЯ СТОРОНА КАРТА ТЕСТОВОГО ДОСТУПА", "en": "BOTTOM SIDE TEST ACCESS MAP", "zh": "底面测试访问图"},
    "map_3d_top": {"source": "3D КАРТА ТЕСТОВОГО ДОСТУПА ВЕРХНЕЙ СТОРОНЫ", "ru": "3D КАРТА ТЕСТОВОГО ДОСТУПА ВЕРХНЕЙ СТОРОНЫ", "en": "TOP SIDE 3D TEST ACCESS MAP", "zh": "顶面三维测试访问图"},
    "map_3d_bottom": {"source": "3D КАРТА ТЕСТОВОГО ДОСТУПА НИЖНЕЙ СТОРОНЫ", "ru": "3D КАРТА ТЕСТОВОГО ДОСТУПА НИЖНЕЙ СТОРОНЫ", "en": "BOTTOM SIDE 3D TEST ACCESS MAP", "zh": "底面三维测试访问图"},
    "testpoint": {"source": "Контрольные точки", "ru": "Контрольные точки", "en": "Test points", "zh": "测试点"},
    "solder-bridge": {"source": "SB элементы", "ru": "Элементы SB", "en": "SB elements", "zh": "SB 元件"},
    "keystone-5016": {"source": "Keystone 5016", "ru": "Контакты Keystone 5016", "en": "Keystone 5016", "zh": "Keystone 5016 触点"},
    "through-hole-signal": {"source": "Отверстия ≥ 1 мм", "ru": "Сигнальные отверстия ≥ 1 мм", "en": "Signal holes ≥ 1 mm", "zh": "信号孔 ≥ 1 mm"},
    "crop_alt": {
        "ru": "Ортогональный фрагмент платы с расположением {designator}",
        "en": "Cropped orthographic PCB view locating {designator}",
        "zh": "用于定位 {designator} 的 PCB 正交局部图",
    },
}


def localized_text(
    value: Any,
    mode: str,
    *,
    translations: Mapping[str, Any] | None = None,
    separator: str = "\n",
) -> str:
    if mode not in LANGUAGE_MODES:
        raise ValueError(f"unsupported language mode: {mode}")
    original = value
    candidate = value
    if isinstance(value, str) and translations and value in translations:
        candidate = translations[value]
    if not isinstance(candidate, Mapping):
        return str(candidate)
    if mode == "source":
        for key in ("source", "en", "ru", "zh"):
            if candidate.get(key):
                return str(candidate[key])
        return ""
    if mode == "ru":
        for key in ("ru", "source"):
            if candidate.get(key):
                return str(candidate[key])
        if isinstance(original, str):
            return original
        raise ValueError("localized text is missing language 'ru'")
    if mode == "en-zh":
        english = str(candidate.get("en", "")).strip()
        chinese = str(candidate.get("zh", "")).strip()
        if not english or not chinese:
            raise ValueError("en-zh text requires both 'en' and 'zh' values")
        return english + separator + chinese
    text = str(candidate.get(mode, "")).strip()
    if not text:
        raise ValueError(f"localized text is missing language {mode!r}")
    return text


def ui_text(key: str, mode: str, *, separator: str = "\n", **format_values: str) -> str:
    text = localized_text(UI_TEXT[key], mode, separator=separator)
    return text.format(**format_values)
