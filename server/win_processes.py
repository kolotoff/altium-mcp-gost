"""Running Windows processes, read in-process instead of through tasklist.

Starting `tasklist` took about 110 ms per call and blocked the server's
event loop while it ran. A Toolhelp snapshot answers the same question in a
few milliseconds.

The kernel32 functions are bound on a private WinDLL instance: setting
argtypes on ctypes.windll.kernel32 would change them for every other caller
in the process.
"""
import ctypes
import os
from ctypes import wintypes

TH32CS_SNAPPROCESS = 0x00000002
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.c_size_t),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", wintypes.LONG),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.WCHAR * 260),
    ]


_kernel32 = None
_get_window_thread_process_id = None


def _k32():
    global _kernel32
    if _kernel32 is None:
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        k.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        k.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        k.Process32FirstW.restype = wintypes.BOOL
        k.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
        k.Process32NextW.restype = wintypes.BOOL
        k.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
        k.OpenProcess.restype = wintypes.HANDLE
        k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k.QueryFullProcessImageNameW.restype = wintypes.BOOL
        k.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                                 wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
        k.CloseHandle.restype = wintypes.BOOL
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        _kernel32 = k
    return _kernel32


def pids_by_name(exe_name: str) -> list:
    """IDs of the running processes whose executable is exe_name (any case).

    Raises OSError when the process list cannot be read, so a caller can tell
    "not running" from "unknown".
    """
    k = _k32()
    snapshot = k.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if not snapshot or snapshot == INVALID_HANDLE_VALUE:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
        wanted = exe_name.lower()
        pids = []
        more = k.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            if entry.szExeFile.lower() == wanted:
                pids.append(entry.th32ProcessID)
            more = k.Process32NextW(snapshot, ctypes.byref(entry))
        return pids
    finally:
        k.CloseHandle(snapshot)


def image_path(pid: int) -> str:
    """Full path of a process's executable ('' if it cannot be read)."""
    k = _k32()
    handle = k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(32768)
        size = wintypes.DWORD(len(buf))
        if k.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return buf.value
        return ""
    finally:
        k.CloseHandle(handle)


def window_process_id(hwnd: int) -> int:
    """Process owning the window, or zero if the window is gone."""
    global _get_window_thread_process_id
    if _get_window_thread_process_id is None:
        get_pid = ctypes.WinDLL("user32").GetWindowThreadProcessId
        get_pid.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        get_pid.restype = wintypes.DWORD
        _get_window_thread_process_id = get_pid
    pid = wintypes.DWORD()
    _get_window_thread_process_id(hwnd, ctypes.byref(pid))
    return pid.value


def window_image_path(hwnd: int) -> str:
    pid = window_process_id(hwnd)
    return image_path(pid) if pid else ""


def window_belongs_to(hwnd: int, executable: str) -> bool:
    """Check an HWND against the full executable path, including the install."""
    if not executable:
        return False
    actual = window_image_path(hwnd)
    if not actual:
        return False
    return os.path.normcase(os.path.realpath(actual)) == os.path.normcase(os.path.realpath(executable))
