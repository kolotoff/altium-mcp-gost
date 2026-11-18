"""Clear a wedged Altium script executor, without a human in the loop.

A DelphiScript runtime error leaves the script PAUSED IN THE DEBUGGER. While
paused, every later RunScript silently does nothing, so recovery has to be
automatic or every later experiment is a false negative.

Primary mechanism: Altium registers "Stop Debugging" as the process
`EditScript:Stop`, and processes can be dispatched into the already-running
instance from the command line:

    X2.EXE -REditScript:Stop

That is the same channel the sandbox runner already uses to launch scripts
(`-RScriptingSystem:RunScript(...)`), so it needs no window focus and no
synthetic keystrokes - which is exactly why the previous SendKeys approach was
unreliable. Ctrl+F3 only reaches the debugger when the script editor happens to
be the active document, so it silently failed whenever a schematic or library
had focus, while still reporting "sent".

SendKeys is kept as a fallback, and success is VERIFIED by running a trivial
probe script rather than assumed - a wedge is defined by scripts silently doing
nothing, so the only honest test is whether a script produces output.

Usage:
    python dev/unwedge.py            # stop debugger, close dialogs, verify
    python dev/unwedge.py --no-verify
"""
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
if not __package__:
    sys.path.insert(0, str(REPO))
from dev.capture_window import _title, find_altium_windows  # noqa: E402
from altium_install import configured_altium_exe  # noqa: E402
from sandbox import altium_dialogs, answer_dialog  # noqa: E402
from win_processes import window_belongs_to, window_process_id  # noqa: E402

EXCHANGE = Path("C:/Users/Public/altium_mcp")
PROBE_PRJ = REPO / "dev" / "sandbox" / "Sandbox.PrjScr"
PROBE_RESULT = EXCHANGE / "sandbox_result.json"


def close_dialogs(executable):
    """Close modal error dialogs. They block input and can mask the wedge."""
    count = 0
    for dialog in altium_dialogs(executable):
        if dialog.is_error_box and window_belongs_to(dialog.hwnd, executable):
            answer_dialog(dialog)
            count += 1
    return count


def stop_via_process(executable):
    """Dispatch EditScript:Stop into the running instance. No focus needed."""
    try:
        subprocess.Popen([executable, "-REditScript:Stop"])
        time.sleep(1.5)
        return True, "EditScript:Stop dispatched"
    except OSError as e:
        return False, str(e)


def stop_via_keys(executable):
    """Fallback: Ctrl+F3, after forcing a script document to the front."""
    hits = find_altium_windows(executable)
    if not hits:
        return False, "no Altium window"
    hits.sort(key=lambda h: (0 if ".pas" in _title(h)
                             else 1 if ".PrjScr" in _title(h) else 2))
    hwnd = hits[0]
    if not window_belongs_to(hwnd, executable):
        return False, "Altium window closed before debugger stop"
    ps = f"""
Add-Type -AssemblyName System.Windows.Forms
$sig = @'
using System;
using System.Runtime.InteropServices;
public class FG {{
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}}
'@
Add-Type -TypeDefinition $sig
[FG]::ShowWindow([IntPtr]{hwnd}, 9) | Out-Null
[FG]::SetForegroundWindow([IntPtr]{hwnd}) | Out-Null
Start-Sleep -Milliseconds 400
$ownerPid = [uint32]0
[FG]::GetWindowThreadProcessId([IntPtr]{hwnd}, [ref]$ownerPid) | Out-Null
if ([FG]::GetForegroundWindow() -ne [IntPtr]{hwnd} -or $ownerPid -ne {window_process_id(hwnd)}) {{
    Write-Output 'Altium did not retain foreground'
    exit 1
}}
[System.Windows.Forms.SendKeys]::SendWait('^{{F3}}')
Start-Sleep -Milliseconds 400
Write-Output 'sent'
"""
    r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                       capture_output=True, text=True, timeout=60)
    return "sent" in r.stdout, (r.stdout or r.stderr).strip()[:160]


def executor_alive(executable, timeout=45):
    """Prove the executor runs again by having it write a result file."""
    from dev.sandbox_runner import inject, SANDBOX_PAS
    saved = SANDBOX_PAS.read_text(encoding="utf-8")
    try:
        inject("ResultText := '{\"probe\": \"alive\"}';")
        if PROBE_RESULT.exists():
            PROBE_RESULT.unlink()
        subprocess.Popen(
            f'"{executable}" -RScriptingSystem:RunScript('
            f'ProjectName="{PROBE_PRJ}"^|ProcName="Sandbox>Run")', shell=True)
        start = time.time()
        while time.time() - start < timeout:
            if PROBE_RESULT.exists():
                return True
            time.sleep(0.5)
            close_dialogs(executable)
        return False
    finally:
        SANDBOX_PAS.write_text(saved, encoding="utf-8")


def unwedge(verbose=True, verify=True, *, executable=None):
    executable = configured_altium_exe() if executable is None else executable
    if not executable:
        if verbose:
            print("Altium X2.EXE not found")
        return False
    n = close_dialogs(executable)
    if verbose and n:
        print(f"closed {n} dialog(s)")

    ok, info = stop_via_process(executable)
    if verbose:
        print(f"EditScript:Stop -> {info}")
    close_dialogs(executable)

    if not verify:
        return ok

    if executor_alive(executable):
        if verbose:
            print("executor VERIFIED alive")
        return True

    if verbose:
        print("still wedged after process dispatch; trying Ctrl+F3")
    ok, info = stop_via_keys(executable)
    if verbose:
        print(f"Ctrl+F3 -> {info}")
    close_dialogs(executable)
    alive = executor_alive(executable)
    if verbose:
        print("executor VERIFIED alive" if alive
              else "STILL WEDGED - restart Altium (sandbox_runner --auto-restart)")
    return alive


if __name__ == "__main__":
    sys.exit(0 if unwedge(verify="--no-verify" not in sys.argv) else 1)
