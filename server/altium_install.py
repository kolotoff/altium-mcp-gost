"""Where Altium Designer (X2.EXE) is installed.

Every Altium installer records its build under HKLM\\SOFTWARE\\Altium\\Builds,
wherever the program went (another drive, a custom folder), so the registry
is asked first. A running Altium names its own executable. Scanning
C:\\Program Files\\Altium is the last resort, for an install the registry
does not list. Nothing here asks the user anything.
"""
import glob
import json
import os
import re
from pathlib import Path

import win_processes

BUILDS_KEY = r"SOFTWARE\Altium\Builds"
PROGRAM_FILES_ALTIUM = r"C:\Program Files\Altium"


def _version_key(version: str) -> tuple:
    """'26.11.1.5' -> (26, 11, 1, 5), for sorting builds newest first."""
    return tuple(int(n) for n in re.findall(r"\d+", str(version or "")))


def _read_builds() -> list:
    """The values of every build key in the registry, as dictionaries."""
    try:
        import winreg
    except ImportError:
        return []
    access = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
    try:
        root = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, BUILDS_KEY, 0, access)
    except OSError:
        return []
    builds = []
    with root:
        index = 0
        while True:
            try:
                name = winreg.EnumKey(root, index)
            except OSError:
                break
            index += 1
            values = {}
            try:
                with winreg.OpenKey(root, name, 0, access) as key:
                    for value in ("ProgramsInstallPath", "Version", "Installed"):
                        try:
                            values[value] = winreg.QueryValueEx(key, value)[0]
                        except OSError:
                            pass
            except OSError:
                continue
            builds.append(values)
    return builds


def registry_installs(builds=None) -> list:
    """X2.EXE paths of the installed builds in the registry, newest first.

    The program folder name says little about the version (AD25 holds
    26.11 after an in-place update), so the build's Version value orders
    them.
    """
    if builds is None:
        builds = _read_builds()
    found = []
    for build in builds:
        folder = str(build.get("ProgramsInstallPath") or "")
        if not folder or str(build.get("Installed", "True")).lower() == "false":
            continue
        found.append((_version_key(build.get("Version")), os.path.join(folder, "X2.EXE")))
    found.sort(key=lambda item: item[0], reverse=True)
    return [exe for _, exe in found]


def running_installs() -> list:
    """X2.EXE paths of the Altium instances running now."""
    paths = (win_processes.image_path(pid) for pid in win_processes.pids_by_name("X2.EXE"))
    return [path for path in paths if path]


def scanned_installs(base: str = PROGRAM_FILES_ALTIUM) -> list:
    """X2.EXE paths under base\\AD<n>, highest <n> first."""
    def ad_number(folder):
        match = re.search(r"AD(\d+)", os.path.basename(folder))
        return int(match.group(1)) if match else 0

    folders = sorted(glob.glob(os.path.join(base, "AD*")), key=ad_number, reverse=True)
    return [os.path.join(folder, "X2.EXE") for folder in folders]


def find_altium_exe() -> str:
    """Explicit executable override, or the newest Altium found."""
    override = os.environ.get("ALTIUM_EXE_PATH", "")
    if override and os.path.isfile(override):
        return override
    for source in (registry_installs, running_installs, scanned_installs):
        try:
            candidates = source()
        except OSError:
            continue
        for exe in candidates:
            if os.path.isfile(exe):
                return exe
    return ""


def configured_altium_exe() -> str:
    """Resolve a saved Altium path without migrating or writing configuration."""
    config_dir = Path(os.environ.get("ALTIUM_MCP_HOME") or Path.home() / ".altium-mcp")
    config = config_dir / "config.json"
    if not config.exists():
        config = Path(__file__).with_name("config.json")
    try:
        data = json.loads(config.read_text(encoding="utf-8-sig"))
        exe = data.get("altium_exe_path") if isinstance(data, dict) else None
        if isinstance(exe, str) and os.path.isfile(exe):
            return exe
    except (OSError, ValueError):
        pass
    return find_altium_exe()
