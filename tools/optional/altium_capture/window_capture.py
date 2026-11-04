# Portions adapted from Quilter PCB routing test tools.
# Copyright 2026 Allegro Labs, Inc. (Quilter). MIT; see LICENSES/Quilter-MIT.txt.
"""Capture the verified Altium window without sending desktop input."""

from __future__ import annotations

import ctypes
import os
from ctypes import wintypes
from pathlib import Path

from PIL import Image, ImageStat

CAPTURE_METHOD = "Windows.Graphics.Capture HWND"


class MonitorInfo(ctypes.Structure):
    """Read physical monitor and work-area rectangles from Win32."""

    _fields_ = [
        ("size", wintypes.DWORD),
        ("monitor", wintypes.RECT),
        ("work", wintypes.RECT),
        ("flags", wintypes.DWORD),
    ]


class CaptureError(RuntimeError):
    """Report an unavailable or invalid Altium window capture."""


class AltiumWindow:
    """Find and inspect an Altium main window through read-only Win32 calls."""

    def __init__(self) -> None:
        if os.name != "nt":
            raise CaptureError("Altium window capture requires Windows.")
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.dwmapi = ctypes.WinDLL("dwmapi", use_last_error=True)
        self.user32.SetProcessDpiAwarenessContext.argtypes = [wintypes.HANDLE]
        self.user32.SetProcessDpiAwarenessContext.restype = wintypes.BOOL
        self.user32.SetThreadDpiAwarenessContext.argtypes = [wintypes.HANDLE]
        self.user32.SetThreadDpiAwarenessContext.restype = wintypes.HANDLE
        self.user32.GetThreadDpiAwarenessContext.argtypes = []
        self.user32.GetThreadDpiAwarenessContext.restype = wintypes.HANDLE
        self.user32.GetAwarenessFromDpiAwarenessContext.argtypes = [wintypes.HANDLE]
        self.user32.GetAwarenessFromDpiAwarenessContext.restype = ctypes.c_int
        # This affects only the capture worker, before any window reads or WGC import.
        if not self.user32.SetProcessDpiAwarenessContext(-4):
            if ctypes.get_last_error() != 5:  # Already set is the only allowed failure.
                raise CaptureError(
                    "Cannot set per-monitor capture-process DPI awareness."
                )
        if not self.user32.SetThreadDpiAwarenessContext(-4):
            raise CaptureError("Cannot set per-monitor capture-thread DPI awareness.")
        if (
            self.user32.GetAwarenessFromDpiAwarenessContext(
                self.user32.GetThreadDpiAwarenessContext()
            )
            != 2
        ):
            raise CaptureError("Capture thread is not per-monitor DPI aware.")
        self.user32.GetDpiForWindow.argtypes = [wintypes.HWND]
        self.user32.GetDpiForWindow.restype = wintypes.UINT
        self.user32.GetWindowRect.argtypes = [
            wintypes.HWND,
            ctypes.POINTER(wintypes.RECT),
        ]
        self.user32.GetWindowRect.restype = wintypes.BOOL
        self.user32.GetClientRect.argtypes = [
            wintypes.HWND,
            ctypes.POINTER(wintypes.RECT),
        ]
        self.user32.GetClientRect.restype = wintypes.BOOL
        self.user32.MonitorFromWindow.argtypes = [wintypes.HWND, wintypes.DWORD]
        self.user32.MonitorFromWindow.restype = wintypes.HANDLE
        self.user32.GetMonitorInfoW.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(MonitorInfo),
        ]
        self.user32.GetMonitorInfoW.restype = wintypes.BOOL
        self.dwmapi.DwmGetWindowAttribute.argtypes = [
            wintypes.HWND,
            wintypes.DWORD,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        self.dwmapi.DwmGetWindowAttribute.restype = ctypes.c_long
        for name in ("IsWindow", "IsWindowVisible", "IsIconic"):
            fn = getattr(self.user32, name)
            fn.argtypes = [wintypes.HWND]
            fn.restype = wintypes.BOOL
        self.user32.GetWindowTextW.argtypes = [
            wintypes.HWND,
            wintypes.LPWSTR,
            ctypes.c_int,
        ]
        self.user32.GetWindowTextW.restype = ctypes.c_int
        self.user32.GetWindowThreadProcessId.argtypes = [
            wintypes.HWND,
            ctypes.POINTER(wintypes.DWORD),
        ]
        self.user32.GetWindowThreadProcessId.restype = wintypes.DWORD
        self.user32.GetForegroundWindow.argtypes = []
        self.user32.GetForegroundWindow.restype = wintypes.HWND
        self.kernel32.OpenProcess.argtypes = [
            wintypes.DWORD,
            wintypes.BOOL,
            wintypes.DWORD,
        ]
        self.kernel32.OpenProcess.restype = wintypes.HANDLE
        self.kernel32.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        self.kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
        self.kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel32.CloseHandle.restype = wintypes.BOOL

    def title(self, hwnd: int) -> str:
        """Read the current window title without activating the window."""
        title = ctypes.create_unicode_buffer(4096)
        self.user32.GetWindowTextW(hwnd, title, len(title))
        return title.value

    def inspect(self, hwnd: int) -> dict:
        """Require Altium's process and title before accepting a window handle."""
        if not self.user32.IsWindow(hwnd):
            raise CaptureError(f"Altium window {hwnd} does not exist in this session.")
        title = self.title(hwnd)
        if " - Altium Designer (" not in title:
            raise CaptureError(f"Window {hwnd} is not an Altium main window.")
        pid = wintypes.DWORD()
        self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        handle = self.kernel32.OpenProcess(0x1000, False, pid.value)
        if not handle:
            raise CaptureError(f"Cannot inspect Altium process {pid.value}.")
        executable = ctypes.create_unicode_buffer(32768)
        length = wintypes.DWORD(len(executable))
        try:
            if not self.kernel32.QueryFullProcessImageNameW(
                handle, 0, executable, ctypes.byref(length)
            ):
                raise CaptureError("Cannot verify Altium's executable path.")
        finally:
            self.kernel32.CloseHandle(handle)
        if Path(executable.value).name.casefold() != "x2.exe":
            raise CaptureError("The selected window does not belong to X2.EXE.")
        if self.user32.IsIconic(hwnd):
            raise CaptureError("Altium is minimized; capture skipped.")
        if not self.user32.IsWindowVisible(hwnd):
            raise CaptureError("Altium is hidden; capture skipped.")
        return {
            "hwnd": hwnd,
            "pid": pid.value,
            "title": title,
            "executable": executable.value,
            "is_foreground": self.user32.GetForegroundWindow() == hwnd,
        }

    def find(self, requested_hwnd: int | None) -> dict:
        """Use the requested handle or require exactly one Altium main window."""
        if requested_hwnd is not None:
            return self.inspect(requested_hwnd)
        handles = []
        callback_type = ctypes.WINFUNCTYPE(
            wintypes.BOOL, wintypes.HWND, wintypes.LPARAM
        )

        @callback_type
        def collect(hwnd, _):
            if " - Altium Designer (" in self.title(hwnd):
                handles.append(int(hwnd))
            return True

        self.user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
        self.user32.EnumWindows.restype = wintypes.BOOL
        if not self.user32.EnumWindows(collect, 0):
            raise CaptureError("Cannot enumerate windows in this Windows session.")
        if len(handles) != 1:
            raise CaptureError(
                f"Expected one Altium main window; found {len(handles)}. "
                "Use --hwnd only after checking the current window identity."
            )
        return self.inspect(handles[0])

    def geometry(self, hwnd: int) -> dict:
        """Read physical bounds and the target window's DPI without changing them."""
        window = wintypes.RECT()
        client = wintypes.RECT()
        visible = wintypes.RECT()
        if not self.user32.GetWindowRect(hwnd, ctypes.byref(window)):
            raise CaptureError("Cannot read Altium's window bounds.")
        if not self.user32.GetClientRect(hwnd, ctypes.byref(client)):
            raise CaptureError("Cannot read Altium's client bounds.")
        if (
            self.dwmapi.DwmGetWindowAttribute(
                hwnd, 9, ctypes.byref(visible), ctypes.sizeof(visible)
            )
            != 0
        ):
            raise CaptureError("Cannot read Altium's visible physical bounds.")
        monitor = MonitorInfo()
        monitor.size = ctypes.sizeof(monitor)
        if not self.user32.GetMonitorInfoW(
            self.user32.MonitorFromWindow(hwnd, 2), ctypes.byref(monitor)
        ):
            raise CaptureError("Cannot read Altium's monitor bounds.")
        dpi = self.user32.GetDpiForWindow(hwnd)
        if not dpi:
            raise CaptureError("Cannot read Altium's window DPI.")
        return {
            "window_rect_px": rectangle(window),
            "client_rect_px": rectangle(client),
            "visible_bounds_px": rectangle(visible),
            "monitor_bounds_px": rectangle(monitor.monitor),
            "work_bounds_px": rectangle(monitor.work),
            "window_dpi": dpi,
        }


def rectangle(rect: wintypes.RECT) -> list[int]:
    """Convert a Win32 rectangle into JSON-compatible physical coordinates."""
    return [rect.left, rect.top, rect.right, rect.bottom]


def capture_graphics_window(hwnd: int) -> Image.Image:
    """Copy one HWND-targeted WGC frame before releasing its native pixel buffer."""
    from windows_capture import WindowsCapture

    images = []
    capture = WindowsCapture(window_hwnd=hwnd, cursor_capture=False, draw_border=False)

    @capture.event
    def on_frame_arrived(frame, control):
        try:
            if not images:
                pixels = frame.frame_buffer.copy()
                images.append(
                    Image.frombytes(
                        "RGB",
                        (frame.width, frame.height),
                        pixels.tobytes(),
                        "raw",
                        "BGRX",
                    )
                )
        finally:
            control.stop()

    @capture.event
    def on_closed():
        pass

    # The caller runs this in a subprocess with a capture timeout.
    capture.start()
    if not images:
        raise CaptureError("Altium capture closed before producing a frame.")
    return images[0]


def capture_metadata(size: tuple[int, int], before: dict, after: dict) -> dict:
    """Reject geometry races or scaled frames and report accepted physical sizes."""
    if before != after:
        raise CaptureError("Altium display, bounds, or DPI changed during capture.")
    left, top, right, bottom = after["visible_bounds_px"]
    window_size = (right - left, bottom - top)
    if size != window_size:
        raise CaptureError(
            f"Capture size {size} does not match visible window bounds {window_size}."
        )
    left, top, right, bottom = after["monitor_bounds_px"]
    return {
        "capture_method": CAPTURE_METHOD,
        "monitor_width_px": right - left,
        "monitor_height_px": bottom - top,
        "window_width_px": window_size[0],
        "window_height_px": window_size[1],
        "capture_width_px": size[0],
        "capture_height_px": size[1],
        "window_dpi": after["window_dpi"],
        "capture_dpi_awareness": "per-monitor-v2",
    }


def validate_image(image: Image.Image) -> None:
    """Reject tiny, uniform, or almost entirely black capture results."""
    if image.width < 320 or image.height < 200:
        raise CaptureError(f"Capture is too small: {image.size}.")
    if max(ImageStat.Stat(image).stddev) < 2:
        raise CaptureError("Capture is nearly uniform; frame rejected as blank.")
    center = image.crop(
        (
            image.width // 4,
            image.height // 4,
            image.width * 3 // 4,
            image.height * 3 // 4,
        )
    ).convert("L")
    histogram = center.histogram()
    if sum(histogram[:6]) / (center.width * center.height) > 0.999:
        raise CaptureError(
            "Capture center is nearly all black; frame rejected as blank."
        )


def capture_window(hwnd: int | None) -> tuple[Image.Image, dict]:
    """Capture only Altium and recheck its identity after the capture returns."""
    windows = AltiumWindow()
    identity = windows.find(hwnd)
    before_geometry = windows.geometry(identity["hwnd"])
    image = capture_graphics_window(identity["hwnd"])
    after = windows.inspect(identity["hwnd"])
    if identity["pid"] != after["pid"]:
        raise CaptureError("Altium's process changed during capture; frame rejected.")
    after_geometry = windows.geometry(identity["hwnd"])
    after["capture_metadata"] = capture_metadata(
        image.size, before_geometry, after_geometry
    )
    after["geometry"] = after_geometry
    validate_image(image)
    return image, after
