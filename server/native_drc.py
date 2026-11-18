"""Continue Altium's polygon warning with the check-only button."""

import asyncio
import base64
import json
import logging
import os
import subprocess
import sys


LOGGER = logging.getLogger(__name__)

POLYGON_WARNING_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$name = [IO.Path]::GetFileNameWithoutExtension($env:ALTIUM_DRC_EXE)
$eda = @(Get-Process -Name $name -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $env:ALTIUM_DRC_EXE -and $_.SessionId -eq
        [Diagnostics.Process]::GetCurrentProcess().SessionId })
if ($eda.Count -ne 1) { exit 2 }
$ae = [System.Windows.Automation.AutomationElement]
$condition = [System.Windows.Automation.PropertyCondition]
$scope = [System.Windows.Automation.TreeScope]
$processMatch = $condition::new($ae::ProcessIdProperty, $eda[0].Id)
$run = $condition::new($ae::NameProperty, 'Run DRC')
$repour = $condition::new($ae::NameProperty, 'Repour Polygons and Run DRC')
$cancel = $condition::new($ae::NameProperty, 'Cancel')
while ($true) {
    try {
        $status = Get-Content -LiteralPath $env:ALTIUM_DRC_STATUS -Raw | ConvertFrom-Json
        if ($status.phase -ne 'native_drc_running') { exit 0 }
    } catch { Start-Sleep -Milliseconds 300; continue }
    $dialogs = @($ae::RootElement.FindAll($scope::Children, $processMatch) |
        Where-Object { -not $_.Current.IsOffscreen -and
            $_.Current.ClassName -eq 'TMessageForm' -and $_.Current.Name -eq 'Design Rule Check' })
    if ($dialogs.Count -eq 1) {
        $button = $dialogs[0].FindFirst($scope::Descendants, $run)
        if ($null -ne $button -and $button.Current.IsEnabled -and
            $null -ne $dialogs[0].FindFirst($scope::Descendants, $repour) -and
            $null -ne $dialogs[0].FindFirst($scope::Descendants, $cancel)) {
            $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            exit 0
        }
    }
    Start-Sleep -Milliseconds 300
}
"""


async def continue_polygon_warning(directory, altium_exe):
    if sys.platform != "win32" or not altium_exe:
        return
    path = directory / "operation-status.json"
    while True:
        try:
            status = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            await asyncio.sleep(0.2)
            continue
        if status["phase"] == "native_drc_running":
            break
        await asyncio.sleep(0.2)
    encoded = base64.b64encode(POLYGON_WARNING_SCRIPT.encode("utf-16le")).decode(
        "ascii"
    )
    try:
        process = await asyncio.create_subprocess_exec(
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            encoded,
            env={
                **os.environ,
                "ALTIUM_DRC_EXE": altium_exe,
                "ALTIUM_DRC_STATUS": str(path),
            },
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except OSError:
        LOGGER.warning("Could not start the Altium DRC dialog helper")
        return
    try:
        if await process.wait():
            LOGGER.warning(
                "Altium DRC dialog helper could not identify one active Altium instance"
            )
    finally:
        if process.returncode is None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
            await process.wait()
