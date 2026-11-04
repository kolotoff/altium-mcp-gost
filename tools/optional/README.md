# Optional standalone utilities

These utilities are separate from the MCP request loop. All their generated
outputs belong under the repository's `generated/` directory. They do not save
Altium documents. Upstream MIT notice: `LICENSES/Quilter-MIT.txt`.

## Passive capture and timelapse

Install the optional `capture` extra in an appropriate isolated environment:

```powershell
python -m pip install '.[capture]'
python -B tools/optional/altium_capture/recorder.py --run-id review --once
python -B tools/optional/altium_capture/recorder.py --run-id review
python -B tools/optional/altium_capture/recorder.py --run-id review --stop
```

The recorder verifies Altium's process and window handle, uses native WGC pixels
with per-monitor DPI checks, and never activates/restores/moves a window or falls
back to desktop capture. Multiple windows require an explicit `--hwnd`. Minimized,
hidden, blank or geometrically inconsistent captures are rejected. The default
interval is 300 seconds. Output is `generated/optional-capture/runs/<run-id>/`.
The same run ID resumes a verified manifest; an OS lock prevents two writers.
Failed captures are gaps, not fabricated frames. Heartbeat, time labels, atomic
video replacement and graceful stopping are retained from the upstream utility.

FFmpeg is provided through `imageio-ffmpeg`; `windows-capture==2.0.1` is Windows
only. The default MCP installation does not import either package. Test extras:
`.[capture,capture-tests]`; run `python -B -m unittest discover -s
tools/optional/altium_capture -p 'test_*.py'`. Tests use mocked frame capture and
local encoding, not a live Altium capture qualification.

Playback omission remains available through `--omit-playback FIRST_FRAME
LAST_FRAME --omission-reason TEXT`, and `--reencode-only` rebuilds playback.
Stop the recorder first. These operations back up the prior manifest/video under
the run directory and retain all original PNG files and capture history.

## Saved-file checkpoints

```powershell
python -B tools/optional/checkpoints.py copy 'D:\Boards\Project' 'D:\Develop\Altium\Ai\altium-mcp\generated\checkpoints\review-001'
python -B tools/optional/checkpoints.py verify 'D:\Develop\Altium\Ai\altium-mcp\generated\checkpoints\review-001'
```

The default is a complete independent copy with a SHA-256 manifest. A changed
source during copying, escaped paths, unexpected files or changed checkpoint bytes
fail verification. Incomplete output is retained for inspection. Copying existing
disk files does not establish that the open Altium document was saved or reopened.

Optional `--reference <verified-archive> --immutable-path <relative-file>` reuses
only explicitly listed matching immutable files by hardlink. Both archives must
be under `generated/`. Hardlinked bytes remain shared; reserve this mode for
archives that will not be edited. Native PCB copies are independent by default.
The utility performs no automatic compaction, pruning or source-file mutation and
uses Python 3.10-compatible streaming hashing.
