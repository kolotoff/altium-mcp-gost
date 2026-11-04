# Portions adapted from Quilter PCB routing test tools.
# Copyright 2026 Allegro Labs, Inc. (Quilter). MIT; see LICENSES/Quilter-MIT.txt.
"""Record Altium screenshots and a cumulative local timelapse."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont
from window_capture import CAPTURE_METHOD, capture_window

WORKSPACE = Path(__file__).resolve().parents[3] / "generated" / "optional-capture"
FRAME_PATTERN = re.compile(r"frames/[0-9]{8}T[0-9]{12}Z-[a-f0-9]{8}\.png\Z")
GIB = 1024**3
SUBPROCESS_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def utc_now() -> str:
    """Return a UTC timestamp with an explicit timezone."""
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def parse_utc(value: str) -> datetime:
    """Require a timezone-aware UTC timestamp."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.utcoffset() is None or parsed.utcoffset().total_seconds() != 0:
        raise ValueError("Timestamp must use UTC.")
    return parsed


def run_directory(runs_root: Path, run_id: str) -> Path:
    """Resolve a single safe run directory below the configured runs root."""
    reserved = re.fullmatch(r"(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])", run_id)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", run_id) or reserved:
        raise ValueError(
            "Run ID must be 1-80 letters, digits, hyphens, or underscores."
        )
    root = runs_root.resolve()
    result = (root / run_id).resolve()
    if result.parent != root:
        raise ValueError("Run directory must be directly below the runs root.")
    return result


def frame_path(run_dir: Path, relative: str) -> Path:
    """Reject frame paths outside this run, including redirected directories."""
    if not isinstance(relative, str) or not FRAME_PATTERN.fullmatch(relative):
        raise ValueError("Manifest contains an invalid frame path.")
    resolved = (run_dir / relative).resolve()
    if not resolved.is_relative_to(run_dir.resolve()):
        raise ValueError("Frame path escapes the run directory.")
    return resolved


def replace_with_retry(source: Path, destination: Path, label: str) -> None:
    """Replace a complete file, briefly retrying Windows access and sharing denials."""
    for attempt, delay in enumerate((0.05, 0.1, 0.2, 0.4, 0.8, None)):
        try:
            os.replace(source, destination)
        except OSError as error:
            if getattr(error, "winerror", None) not in (5, 32, 33) or delay is None:
                raise
            if attempt == 0:
                print(
                    f"{utc_now()} {label}: replacement delayed; retrying: {error}",
                    file=sys.stderr,
                    flush=True,
                )
            time.sleep(delay)
        else:
            if attempt:
                print(
                    f"{utc_now()} {label}: replacement recovered after"
                    f" {attempt} retries",
                    file=sys.stderr,
                    flush=True,
                )
            return


def atomic_json(path: Path, value: dict) -> None:
    """Replace flushed JSON, briefly retrying Windows sharing or access denials."""
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        replace_with_retry(temporary, path, "manifest")
    finally:
        temporary.unlink(missing_ok=True)


class RunLock:
    """Hold an OS lock so only one recorder can write to a run."""

    def __init__(self, run_dir: Path) -> None:
        self.path = run_dir / "recorder.lock"
        self.handle = None

    def __enter__(self):
        import msvcrt

        self.handle = self.path.open("a+b")
        if self.path.stat().st_size == 0:
            self.handle.write(b"0")
            self.handle.flush()
        self.handle.seek(0)
        try:
            msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            self.handle.close()
            raise RuntimeError(
                "Another recorder already holds this run's lock."
            ) from None
        return self

    def __exit__(self, *_):
        import msvcrt

        self.handle.seek(0)
        msvcrt.locking(self.handle.fileno(), msvcrt.LK_UNLCK, 1)
        self.handle.close()


class Manifest:
    """Serialize capture results and an independent heartbeat atomically."""

    def __init__(self, run_dir: Path, interval: float) -> None:
        self.run_dir = run_dir
        self.path = run_dir / "manifest.json"
        self.lock = threading.Lock()
        now = utc_now()
        if self.path.exists():
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
            if self.data["run_id"] != run_dir.name:
                raise ValueError("Manifest run ID does not match its directory.")
            if self.data["interval_seconds"] != interval:
                raise ValueError(
                    "Resume requires the manifest's existing capture interval."
                )
            parse_utc(self.data["started_utc"])
            for entry in self.data["frames"]:
                path = frame_path(run_dir, entry["file"])
                parse_utc(entry["captured_utc"])
                if not path.is_file() or path.stat().st_size != entry["bytes"]:
                    raise ValueError(
                        f"Recorded frame is missing or changed: {entry['file']}"
                    )
            playback_frames(self.data)
            previous = self.data.get("heartbeat_utc")
            if previous and (parse_utc(now) - parse_utc(previous)).total_seconds() > 30:
                self.data.setdefault("gaps", []).append(
                    {
                        "started_utc": previous,
                        "ended_utc": now,
                        "message": (
                            "Recorder resumed; no captures are claimed during this"
                            " interval."
                        ),
                    }
                )
        else:
            self.data = {
                "run_id": run_dir.name,
                "started_utc": now,
                "interval_seconds": interval,
                "heartbeat_utc": now,
                "last_capture_utc": None,
                "last_error": None,
                "frames": [],
                "errors": [],
                "gaps": [],
            }
        self.update(
            status="running",
            recorder_pid=os.getpid(),
            heartbeat_utc=now,
            stopped_utc=None,
        )

    def update(self, **fields) -> None:
        """Persist new fields while excluding concurrent heartbeat writes."""
        with self.lock:
            self.data.update(fields)
            atomic_json(self.path, self.data)

    def snapshot(self) -> dict:
        """Return a consistent manifest copy for an encoder or caller."""
        with self.lock:
            return copy.deepcopy(self.data)

    def capture(self, entry: dict, identity: dict) -> None:
        """Append a completed frame without replacing earlier captures."""
        with self.lock:
            if any(frame["file"] == entry["file"] for frame in self.data["frames"]):
                raise ValueError("A frame with this path is already recorded.")
            self.data["frames"].append(entry)
            self.data.update(
                last_capture_utc=entry["captured_utc"],
                last_error=None,
                window=identity,
            )
            if "capture_metadata" in entry:
                self.data["capture_metadata"] = entry["capture_metadata"]
                self.data["capture_method"] = entry["capture_metadata"][
                    "capture_method"
                ]
            else:
                self.data.pop("capture_metadata", None)
            atomic_json(self.path, self.data)

    def error(self, message: str, kind: str, expected_utc: str | None = None) -> None:
        """Append failures and make skipped capture intervals explicit."""
        now = utc_now()
        with self.lock:
            self.data["errors"].append({"utc": now, "message": message, "kind": kind})
            self.data["last_error"] = message
            if kind == "capture":
                self.data.setdefault("gaps", []).append(
                    {
                        "started_utc": expected_utc or now,
                        "ended_utc": now,
                        "message": message,
                    }
                )
            atomic_json(self.path, self.data)
        print(f"{now} {kind}: {message}", file=sys.stderr, flush=True)


def label_frame(image: Image.Image, captured_utc: str, started_utc: str) -> Image.Image:
    """Append UTC and elapsed-time labels without covering the screenshot."""
    elapsed = max(
        0, int((parse_utc(captured_utc) - parse_utc(started_utc)).total_seconds())
    )
    hours, remainder = divmod(elapsed, 3600)
    minutes, seconds = divmod(remainder, 60)
    font_size = max(18, min(36, image.width // 80))
    band_height = font_size * 2
    result = Image.new("RGB", (image.width, image.height + band_height), "#101721")
    result.paste(image, (0, 0))
    ImageDraw.Draw(result).text(
        (font_size // 2, image.height + font_size // 2),
        f"{captured_utc}  |  elapsed {hours:02}:{minutes:02}:{seconds:02}",
        fill="white",
        font=ImageFont.load_default(size=font_size),
    )
    return result


def capture_worker(output: Path, started_utc: str, hwnd: int | None) -> None:
    """Capture in an isolated process so a blocked window call can time out."""
    image, identity = capture_window(hwnd)
    captured_utc = utc_now()
    image = label_frame(image, captured_utc, started_utc)
    identity["capture_metadata"].update(
        frame_width_px=image.width, frame_height_px=image.height
    )
    with output.open("xb") as target:
        image.save(target, format="PNG")
        target.flush()
        os.fsync(target.fileno())
    print(json.dumps({"captured_utc": captured_utc, "window": identity}), flush=True)


def check_disk(
    run_dir: Path, frame_bytes: int, max_frame_bytes: int, min_free_bytes: int
) -> None:
    """Stop adding captures at the frame budget or free-disk reserve."""
    if frame_bytes >= max_frame_bytes:
        raise RuntimeError("Source-frame disk budget reached; capture skipped.")
    if shutil.disk_usage(run_dir).free < min_free_bytes:
        raise RuntimeError(
            "Free disk space is below the configured reserve; capture skipped."
        )


def record_frame(run_dir: Path, manifest: Manifest, args: argparse.Namespace) -> None:
    """Publish one completed screenshot from a timeout-bounded capture worker."""
    state = manifest.snapshot()
    current_bytes = sum(entry["bytes"] for entry in state["frames"])
    max_bytes = int(args.max_frame_gib * GIB)
    reserve = int(args.min_free_gib * GIB)
    check_disk(run_dir, current_bytes, max_bytes, reserve)
    temporary = run_dir / f".capture-{uuid.uuid4().hex}.png"
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "_capture",
        "--output",
        str(temporary),
        "--started-utc",
        state["started_utc"],
    ]
    if args.hwnd is not None:
        command.extend(["--hwnd", str(args.hwnd)])
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=args.capture_timeout_seconds,
            creationflags=SUBPROCESS_FLAGS,
        )
        if result.returncode:
            raise RuntimeError(
                result.stderr.strip()[-2000:] or "Capture worker failed."
            )
        details = json.loads(result.stdout)
        captured = parse_utc(details["captured_utc"])
        size = temporary.stat().st_size
        check_disk(run_dir, current_bytes + size, max_bytes, reserve)
        relative = (
            f"frames/{captured.strftime('%Y%m%dT%H%M%S%fZ')}-{uuid.uuid4().hex[:8]}.png"
        )
        destination = frame_path(run_dir, relative)
        # Windows rename refuses an existing destination instead of overwriting it.
        temporary.rename(destination)
        manifest.capture(
            {
                "file": relative,
                "captured_utc": details["captured_utc"],
                "bytes": size,
                "capture_metadata": details["window"]["capture_metadata"],
            },
            details["window"],
        )
    finally:
        temporary.unlink(missing_ok=True)


def playback_frames(state: dict) -> list[dict]:
    """Select playback frames while retaining the full capture history."""
    frames = state["frames"]
    indices = {entry["file"]: index for index, entry in enumerate(frames)}
    if len(indices) != len(frames):
        raise ValueError("Manifest contains duplicate frame paths.")
    omitted = set()
    for omission in state.get("playback_omissions", []):
        first = indices.get(omission.get("first_frame"))
        last = indices.get(omission.get("last_frame"))
        reason = omission.get("reason")
        if first is None or last is None or first > last:
            raise ValueError(
                "Playback omission must name an ordered existing frame range."
            )
        if not isinstance(reason, str) or not reason.strip() or len(reason) > 500:
            raise ValueError("Playback omission requires a reason of 1-500 characters.")
        selected = set(range(first, last + 1))
        if omitted & selected:
            raise ValueError("Playback omissions must not overlap.")
        omitted.update(selected)
    if frames and len(omitted) == len(frames):
        raise ValueError("Playback omission cannot exclude every frame.")
    return [entry for index, entry in enumerate(frames) if index not in omitted]


def encode_timelapse(
    run_dir: Path, state: dict, fps: float, timeout: float = 180
) -> int:
    """Replace the cumulative MP4 only after FFmpeg completes successfully."""
    frames = playback_frames(state)
    if not frames:
        raise ValueError("No source frames are available for encoding.")
    token = uuid.uuid4().hex
    playlist = run_dir / f".encode-{token}.ffconcat"
    video = run_dir / f".encode-{token}.mp4"
    lines = ["ffconcat version 1.0"]
    for entry in frames:
        source = frame_path(run_dir, entry["file"])
        if not source.is_file():
            raise ValueError(f"Missing source frame: {entry['file']}")
        lines.extend([f"file '{entry['file']}'", f"duration {1 / fps:.9f}"])
    lines.append(f"file '{frames[-1]['file']}'")
    try:
        playlist.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = subprocess.run(
            [
                imageio_ffmpeg.get_ffmpeg_exe(),
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-f",
                "concat",
                "-safe",
                "1",
                "-i",
                str(playlist),
                "-vf",
                "scale=1600:900:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=1600:900:(ow-iw)/2:(oh-ih)/2",
                "-r",
                str(fps),
                "-frames:v",
                str(len(frames)),
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "23",
                "-pix_fmt",
                "yuv420p",
                "-threads",
                "2",
                "-movflags",
                "+faststart",
                str(video),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
            creationflags=SUBPROCESS_FLAGS,
        )
        if result.returncode or not video.is_file() or video.stat().st_size == 0:
            raise RuntimeError(
                result.stderr.strip()[-2000:] or "FFmpeg produced no video."
            )
        replace_with_retry(video, run_dir / "timelapse.mp4", "video")
        return len(frames)
    finally:
        playlist.unlink(missing_ok=True)
        video.unlink(missing_ok=True)


def edit_playback(run_dir: Path, args: argparse.Namespace) -> int:
    """Back up and edit playback under the recorder lock without capturing."""
    with RunLock(run_dir):
        path = run_dir / "manifest.json"
        state = json.loads(path.read_text(encoding="utf-8"))
        if state["run_id"] != run_dir.name:
            raise ValueError("Manifest run ID does not match its directory.")
        for entry in state["frames"]:
            source = frame_path(run_dir, entry["file"])
            if not source.is_file() or source.stat().st_size != entry["bytes"]:
                raise ValueError(
                    f"Recorded frame is missing or changed: {entry['file']}"
                )
        playback_frames(state)
        if args.omit_playback:
            first, last = args.omit_playback
            omission = {
                "first_frame": first,
                "last_frame": last,
                "reason": args.omission_reason,
                "created_utc": utc_now(),
            }
            state.setdefault("playback_omissions", []).append(omission)
            playback_frames(state)
            frames = {entry["file"]: entry for entry in state["frames"]}
            omission.update(
                started_utc=frames[first]["captured_utc"],
                ended_utc=frames[last]["captured_utc"],
            )
            backup = run_dir / "playback-backups" / uuid.uuid4().hex
            backup.mkdir(parents=True)
            hashes = {}
            for name in ("manifest.json", "timelapse.mp4"):
                source = run_dir / name
                if source.is_file():
                    destination = backup / name
                    shutil.copy2(source, destination)
                    digest = hashlib.sha256(source.read_bytes()).hexdigest()
                    if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
                        raise RuntimeError(
                            f"Playback backup verification failed: {name}"
                        )
                    hashes[name] = digest
            omission["backup"] = {
                "directory": backup.relative_to(run_dir).as_posix(),
                "sha256": hashes,
            }
        state["playback_pending"] = True
        state["playback_error"] = None
        atomic_json(path, state)
        try:
            count = encode_timelapse(run_dir, state, args.fps)
        except Exception as error:
            state["playback_error"] = str(error)
            atomic_json(path, state)
            raise
        state.update(
            timelapse_file="timelapse.mp4",
            timelapse_updated_utc=utc_now(),
            timelapse_frame_count=count,
            timelapse_source_frame_count=len(state["frames"]),
            timelapse_omitted_frame_count=len(state["frames"]) - count,
            playback_pending=False,
            playback_error=None,
        )
        atomic_json(path, state)
        print(
            json.dumps(
                {
                    "retained_raw_frames": len(state["frames"]),
                    "video_frames": count,
                    "omitted_frames": len(state["frames"]) - count,
                }
            )
        )
    return 0


def heartbeat(
    manifest: Manifest, finished: threading.Event, failures: list[str]
) -> None:
    """Update liveness every 15 seconds, including during captures and encoding."""
    while not finished.wait(15):
        try:
            manifest.update(heartbeat_utc=utc_now())
        except Exception as error:
            message = f"Heartbeat write failed: {error}"
            failures.append(message)
            print(message, file=sys.stderr, flush=True)
            finished.set()


def positive_number(value: str) -> float:
    """Reject nonfinite and nonpositive numeric options."""
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("Value must be a finite positive number.")
    return number


def arguments(argv=None) -> argparse.Namespace:
    """Read the recorder's capture, retention, and stop options."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--interval-seconds", type=positive_number, default=300)
    parser.add_argument("--hwnd", type=lambda value: int(value, 0))
    parser.add_argument(
        "--once", action="store_true", help="Capture and encode once, then exit."
    )
    parser.add_argument(
        "--stop", action="store_true", help="Request a graceful stop of this run."
    )
    parser.add_argument("--fps", type=positive_number, default=4)
    parser.add_argument("--capture-timeout-seconds", type=positive_number, default=30)
    parser.add_argument("--max-frame-gib", type=positive_number, default=4)
    parser.add_argument("--min-free-gib", type=positive_number, default=5)
    parser.add_argument(
        "--omit-playback",
        nargs=2,
        metavar=("FIRST_FRAME", "LAST_FRAME"),
        help=(
            "Omit an inclusive existing frame range from playback without deleting"
            " captures."
        ),
    )
    parser.add_argument("--omission-reason")
    parser.add_argument(
        "--reencode-only",
        action="store_true",
        help=(
            "Rebuild playback with existing omissions; do not capture or change"
            " liveness."
        ),
    )
    args = parser.parse_args(argv)
    if args.omit_playback and not args.omission_reason:
        parser.error("--omit-playback requires --omission-reason")
    if args.omission_reason and not args.omit_playback:
        parser.error("--omission-reason requires --omit-playback")
    if (args.omit_playback or args.reencode_only) and (args.once or args.stop):
        parser.error("Playback editing cannot be combined with capture or stop.")
    if args.omit_playback and args.reencode_only:
        parser.error("Use either --omit-playback or --reencode-only.")
    return args


def run(args: argparse.Namespace) -> int:
    """Run capture independently until stopped, preserving resumable files."""
    run_dir = run_directory(WORKSPACE / "runs", args.run_id)
    if args.omit_playback or args.reencode_only:
        if not (run_dir / "manifest.json").is_file():
            raise ValueError("Playback editing requires an existing run manifest.")
        return edit_playback(run_dir, args)
    if args.stop:
        if not (run_dir / "manifest.json").is_file():
            raise ValueError("Cannot stop a run without a manifest.")
        (run_dir / "stop.request").touch(exist_ok=True)
        return 0
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "frames").mkdir(exist_ok=True)
    with RunLock(run_dir):
        manifest = Manifest(run_dir, args.interval_seconds)
        manifest.update(
            capture_method=CAPTURE_METHOD,
            heartbeat_interval_seconds=15,
            max_frame_gib=args.max_frame_gib,
            min_free_gib=args.min_free_gib,
            fps=args.fps,
        )
        (run_dir / "stop.request").unlink(missing_ok=True)
        finished = threading.Event()
        heartbeat_failures = []
        thread = threading.Thread(
            target=heartbeat, args=(manifest, finished, heartbeat_failures), daemon=True
        )
        thread.start()
        exit_code = 0
        try:
            while not finished.is_set() and not (run_dir / "stop.request").exists():
                expected = utc_now()
                next_capture = time.monotonic() + args.interval_seconds
                try:
                    record_frame(run_dir, manifest, args)
                except Exception as error:
                    manifest.error(str(error), "capture", expected)
                    exit_code = 1
                else:
                    try:
                        encoding_state = manifest.snapshot()
                        count = encode_timelapse(run_dir, encoding_state, args.fps)
                    except Exception as error:
                        manifest.error(str(error), "encode")
                        exit_code = 1
                    else:
                        manifest.update(
                            timelapse_file="timelapse.mp4",
                            timelapse_updated_utc=utc_now(),
                            timelapse_frame_count=count,
                            timelapse_source_frame_count=len(encoding_state["frames"]),
                            timelapse_omitted_frame_count=len(encoding_state["frames"])
                            - count,
                            playback_pending=False,
                            playback_error=None,
                        )
                        exit_code = 0
                if args.once:
                    break
                while time.monotonic() < next_capture:
                    if finished.wait(min(1, max(0, next_capture - time.monotonic()))):
                        break
                    if (run_dir / "stop.request").exists():
                        finished.set()
                        break
        except KeyboardInterrupt:
            pass
        finally:
            finished.set()
            thread.join(timeout=5)
            if heartbeat_failures:
                manifest.error(heartbeat_failures[0], "heartbeat")
                exit_code = 1
            manifest.update(
                status="stopped", stopped_utc=utc_now(), heartbeat_utc=utc_now()
            )
    return exit_code


def main() -> int:
    """Dispatch the normal recorder or its private capture subprocess."""
    if len(sys.argv) > 1 and sys.argv[1] == "_capture":
        parser = argparse.ArgumentParser()
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--started-utc", required=True)
        parser.add_argument("--hwnd", type=int)
        args = parser.parse_args(sys.argv[2:])
        capture_worker(args.output, args.started_utc, args.hwnd)
        return 0
    return run(arguments())


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        sys.exit(1)
