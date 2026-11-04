# Portions adapted from Quilter PCB routing test tools.
# Copyright 2026 Allegro Labs, Inc. (Quilter). MIT; see LICENSES/Quilter-MIT.txt.
"""Check recorder recovery, capture rejection, and playable video output."""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:
    import imageio_ffmpeg
    import numpy
except ImportError:
    raise unittest.SkipTest("Install the optional capture and capture-tests extras") from None
if importlib.util.find_spec("windows_capture") is None:
    raise unittest.SkipTest("Optional capture tests require the Windows capture extra")
import recorder
from PIL import Image, ImageDraw
from window_capture import (
    CAPTURE_METHOD,
    CaptureError,
    capture_graphics_window,
    capture_metadata,
    validate_image,
)


class RecorderTests(unittest.TestCase):
    """Exercise file behavior with generated data outside the repository."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="astra-recorder-test-")
        self.addCleanup(self.temporary.cleanup)
        self.run_dir = Path(self.temporary.name) / "test-run"
        (self.run_dir / "frames").mkdir(parents=True)

    def add_frame(self, number=0, color="red", size=(640, 360)):
        captured = f"2026-09-29T01:{number:02}:00.000Z"
        image = Image.new("RGB", size, color)
        ImageDraw.Draw(image).rectangle((5, 5, 60, 60), fill="white")
        image = recorder.label_frame(image, captured, "2026-09-29T01:00:00.000Z")
        relative = f"frames/20260929T01{number:02}00000000Z-{number:08x}.png"
        destination = recorder.frame_path(self.run_dir, relative)
        image.save(destination)
        return {
            "file": relative,
            "captured_utc": captured,
            "bytes": destination.stat().st_size,
        }

    def test_safe_run_ids_and_frame_paths(self):
        for run_id in ("..", "../other", "a/b", "C:escape", "CON", "x."):
            with self.subTest(run_id=run_id), self.assertRaises(ValueError):
                recorder.run_directory(Path(self.temporary.name), run_id)
        for path in ("../outside.png", "frames/../../outside.png", "C:/file.png"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                recorder.frame_path(self.run_dir, path)

    def test_resume_preserves_frames_and_refuses_changed_frame(self):
        manifest = recorder.Manifest(self.run_dir, 300)
        entry = self.add_frame()
        original_bytes = recorder.frame_path(self.run_dir, entry["file"]).read_bytes()
        manifest.capture(entry, {"hwnd": 1})
        manifest.update(heartbeat_utc="2026-09-29T01:00:00.000Z")
        resumed = recorder.Manifest(self.run_dir, 300)
        self.assertEqual(resumed.snapshot()["frames"], [entry])
        self.assertEqual(
            recorder.frame_path(self.run_dir, entry["file"]).read_bytes(),
            original_bytes,
        )
        self.assertEqual(len(resumed.snapshot()["gaps"]), 1)
        with self.assertRaises(ValueError):
            resumed.capture(entry, {"hwnd": 1})
        recorder.frame_path(self.run_dir, entry["file"]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            recorder.Manifest(self.run_dir, 300)

    def test_resume_rejects_interval_change(self):
        recorder.Manifest(self.run_dir, 300)
        with self.assertRaisesRegex(ValueError, "existing capture interval"):
            recorder.Manifest(self.run_dir, 5)

    def test_atomic_manifest_recovers_from_windows_rename_denials(self):
        path = self.run_dir / "manifest.json"
        replace = recorder.os.replace
        for code in (5, 32, 33):
            with self.subTest(winerror=code):
                recorder.atomic_json(path, {"frames": ["existing"]})
                error = PermissionError("manifest replacement denied")
                error.winerror = code
                attempts = []

                def denied_then_replace(temporary, destination):
                    self.assertEqual(
                        json.loads(path.read_text()), {"frames": ["existing"]}
                    )
                    self.assertEqual(
                        json.loads(temporary.read_text()),
                        {"frames": ["existing", "new"]},
                    )
                    attempts.append(temporary)
                    if len(attempts) <= 2:
                        raise error
                    replace(temporary, destination)

                output = io.StringIO()
                with (
                    mock.patch("recorder.os.replace", side_effect=denied_then_replace),
                    mock.patch("recorder.time.sleep") as sleep,
                    contextlib.redirect_stderr(output),
                ):
                    recorder.atomic_json(path, {"frames": ["existing", "new"]})
                self.assertEqual(len(attempts), 3)
                self.assertEqual(len(set(attempts)), 1)
                self.assertEqual(
                    sleep.call_args_list, [mock.call(0.05), mock.call(0.1)]
                )
                self.assertEqual(
                    json.loads(path.read_text()), {"frames": ["existing", "new"]}
                )
                self.assertEqual(list(self.run_dir.glob(".manifest.json.*.tmp")), [])
                self.assertIn("replacement delayed; retrying", output.getvalue())
                self.assertIn(
                    "replacement recovered after 2 retries", output.getvalue()
                )

    def test_atomic_manifest_stops_retrying_and_preserves_old_json(self):
        path = self.run_dir / "manifest.json"
        recorder.atomic_json(path, {"frames": ["existing"]})
        original = path.read_bytes()
        error = PermissionError("persistent manifest denial")
        error.winerror = 5
        with (
            mock.patch("recorder.os.replace", side_effect=error) as replace,
            mock.patch("recorder.time.sleep") as sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(PermissionError) as raised:
                recorder.atomic_json(path, {"frames": ["existing", "new"]})
        self.assertIs(raised.exception, error)
        self.assertEqual(replace.call_count, 6)
        self.assertEqual(sleep.call_count, 5)
        self.assertLessEqual(sum(call.args[0] for call in sleep.call_args_list), 1.55)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(list(self.run_dir.glob(".manifest.json.*.tmp")), [])

    def test_atomic_manifest_does_not_retry_other_errors(self):
        path = self.run_dir / "manifest.json"
        for code in (None, 3, 112):
            with self.subTest(winerror=code):
                error = OSError("unrelated write failure")
                if code is not None:
                    error.winerror = code
                with (
                    mock.patch("recorder.os.replace", side_effect=error) as replace,
                    mock.patch("recorder.time.sleep") as sleep,
                ):
                    with self.assertRaises(OSError) as raised:
                        recorder.atomic_json(path, {"frames": []})
                self.assertIs(raised.exception, error)
                replace.assert_called_once()
                sleep.assert_not_called()
                self.assertFalse(path.exists())
                self.assertEqual(list(self.run_dir.glob(".manifest.json.*.tmp")), [])

    def test_persistent_heartbeat_failure_stays_visible_and_stops_recording(self):
        manifest = recorder.Manifest(self.run_dir, 300)
        finished = mock.Mock()
        finished.wait.side_effect = (False, True)
        failures = []
        error = PermissionError("persistent manifest denial")
        error.winerror = 5
        output = io.StringIO()
        with (
            mock.patch("recorder.os.replace", side_effect=error) as replace,
            mock.patch("recorder.time.sleep"),
            contextlib.redirect_stderr(output),
        ):
            recorder.heartbeat(manifest, finished, failures)
        self.assertEqual(replace.call_count, 6)
        finished.set.assert_called_once()
        self.assertEqual(len(failures), 1)
        self.assertIn("Heartbeat write failed", failures[0])
        self.assertIn(failures[0], output.getvalue())
        self.assertNotIn("replacement recovered", output.getvalue())

    @unittest.skipUnless(os.name == "nt", "Run locking requires Windows msvcrt.")
    def test_only_one_recorder_can_hold_a_run(self):
        with recorder.RunLock(self.run_dir):
            with self.assertRaisesRegex(RuntimeError, "already holds"):
                with recorder.RunLock(self.run_dir):
                    self.fail("Second lock succeeded.")
        with recorder.RunLock(self.run_dir):
            pass

    def test_capture_error_records_an_explicit_gap(self):
        manifest = recorder.Manifest(self.run_dir, 300)
        manifest.error(
            "Altium is minimized; capture skipped.", "capture", "2026-09-29T01:00:00Z"
        )
        state = json.loads((self.run_dir / "manifest.json").read_text())
        self.assertEqual(state["frames"], [])
        self.assertEqual(state["last_error"], state["errors"][0]["message"])
        self.assertEqual(state["gaps"][0]["started_utc"], "2026-09-29T01:00:00Z")

    @unittest.skipUnless(
        os.name == "nt", "The native capture adapter requires Windows windows-capture."
    )
    def test_graphics_capture_copies_pixels_before_stopping(self):
        pixels = numpy.array([[[0, 0, 255, 255], [255, 0, 0, 255]]], dtype=numpy.uint8)
        handlers = {}
        native = mock.Mock()
        native.event.side_effect = lambda callback: handlers.setdefault(
            callback.__name__, callback
        )
        control = mock.Mock()
        control.stop.side_effect = lambda: pixels.fill(0)
        native.start.side_effect = lambda: handlers["on_frame_arrived"](
            mock.Mock(frame_buffer=pixels, width=2, height=1), control
        )
        with mock.patch(
            "windows_capture.WindowsCapture", return_value=native
        ) as factory:
            image = capture_graphics_window(68060)
        factory.assert_called_once_with(
            window_hwnd=68060, cursor_capture=False, draw_border=False
        )
        self.assertEqual(image.getpixel((0, 0)), (255, 0, 0))
        self.assertEqual(image.getpixel((1, 0)), (0, 0, 255))
        self.assertFalse(pixels.any())
        control.stop.assert_called_once()

    @unittest.skipUnless(
        os.name == "nt", "The native capture adapter requires Windows windows-capture."
    )
    def test_closed_capture_without_frame_is_an_error(self):
        native = mock.Mock()
        with mock.patch("windows_capture.WindowsCapture", return_value=native):
            with self.assertRaisesRegex(CaptureError, "before producing a frame"):
                capture_graphics_window(68060)

    def test_capture_rejects_scaled_pixels_and_geometry_changes(self):
        geometry = {
            "visible_bounds_px": [0, 0, 1600, 900],
            "monitor_bounds_px": [0, 0, 1600, 960],
            "window_dpi": 192,
        }
        metadata = capture_metadata((1600, 900), geometry, geometry.copy())
        self.assertEqual(metadata["monitor_height_px"], 960)
        self.assertEqual(metadata["capture_height_px"], 900)
        self.assertEqual(metadata["window_dpi"], 192)
        with self.assertRaisesRegex(CaptureError, "does not match"):
            capture_metadata((800, 450), geometry, geometry)
        for key, value in (
            ("window_dpi", 96),
            ("monitor_bounds_px", [0, 0, 1920, 1080]),
            ("visible_bounds_px", [10, 10, 1610, 910]),
        ):
            with self.subTest(key=key), self.assertRaisesRegex(CaptureError, "changed"):
                capture_metadata((1600, 900), geometry, {**geometry, key: value})

    def test_raw_capture_and_saved_frame_dimensions_remain_distinct(self):
        identity = {
            "capture_metadata": {
                "capture_method": CAPTURE_METHOD,
                "capture_width_px": 640,
                "capture_height_px": 360,
            }
        }
        destination = self.run_dir / "worker.png"
        output = io.StringIO()
        with mock.patch(
            "recorder.capture_window",
            return_value=(Image.new("RGB", (640, 360), "red"), identity),
        ):
            with contextlib.redirect_stdout(output):
                recorder.capture_worker(destination, "2026-09-29T01:00:00Z", 68060)
        details = json.loads(output.getvalue())
        metadata = details["window"]["capture_metadata"]
        with Image.open(destination) as saved:
            self.assertEqual(
                saved.size, (metadata["frame_width_px"], metadata["frame_height_px"])
            )
        self.assertEqual(metadata["capture_height_px"], 360)
        self.assertGreater(metadata["frame_height_px"], metadata["capture_height_px"])
        manifest = recorder.Manifest(self.run_dir, 300)
        entry = {**self.add_frame(), "capture_metadata": metadata}
        manifest.capture(entry, details["window"])
        state = manifest.snapshot()
        self.assertEqual(state["capture_metadata"], metadata)
        self.assertEqual(state["frames"][0]["capture_metadata"], metadata)

    def test_blank_results_are_rejected_before_labeling(self):
        for color in ("black", "white", "#555555"):
            with self.subTest(color=color), self.assertRaises(CaptureError):
                validate_image(Image.new("RGB", (640, 360), color))
        partial = Image.new("RGB", (640, 360), "white")
        ImageDraw.Draw(partial).rectangle((160, 90, 480, 270), fill="black")
        with self.assertRaisesRegex(CaptureError, "center"):
            validate_image(partial)
        ImageDraw.Draw(partial).rectangle((250, 150, 400, 250), fill="red")
        validate_image(partial)

    def test_timestamp_band_preserves_capture_pixels(self):
        image = Image.new("RGB", (640, 360), "red")
        labeled = recorder.label_frame(
            image, "2026-09-30T14:02:03Z", "2026-09-29T01:00:00Z"
        )
        self.assertEqual(labeled.crop((0, 0, 640, 360)).tobytes(), image.tobytes())
        self.assertGreater(labeled.height, image.height)

    def test_capture_timeout_leaves_no_frame(self):
        manifest = recorder.Manifest(self.run_dir, 300)
        args = recorder.arguments(["--run-id", "test-run"])
        with mock.patch("recorder.check_disk"), mock.patch(
            "recorder.subprocess.run",
            side_effect=subprocess.TimeoutExpired("capture", 30),
        ):
            with self.assertRaises(subprocess.TimeoutExpired):
                recorder.record_frame(self.run_dir, manifest, args)
        self.assertEqual(manifest.snapshot()["frames"], [])
        self.assertEqual(list((self.run_dir / "frames").iterdir()), [])

    def test_disk_budget_rejects_capture_before_launch(self):
        with self.assertRaisesRegex(RuntimeError, "budget"):
            recorder.check_disk(self.run_dir, 100, 100, 0)
        with mock.patch("recorder.shutil.disk_usage", return_value=mock.Mock(free=10)):
            with self.assertRaisesRegex(RuntimeError, "reserve"):
                recorder.check_disk(self.run_dir, 1, 100, 11)

    def test_failed_encode_preserves_prior_video(self):
        old_video = self.run_dir / "timelapse.mp4"
        old_video.write_bytes(b"previous complete video")
        state = {"frames": [self.add_frame()]}
        with (
            mock.patch(
                "recorder.imageio_ffmpeg.get_ffmpeg_exe", return_value="ffmpeg.exe"
            ),
            mock.patch(
                "recorder.subprocess.run",
                return_value=mock.Mock(returncode=1, stderr="failed"),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "failed"):
                recorder.encode_timelapse(self.run_dir, state, 4)
        self.assertEqual(old_video.read_bytes(), b"previous complete video")
        self.assertEqual(list(self.run_dir.glob(".encode-*")), [])

    def test_video_replacement_retries_windows_denials(self):
        old_video = self.run_dir / "timelapse.mp4"
        old_video.write_bytes(b"previous complete video")
        state = {"frames": [self.add_frame()]}
        replace = recorder.os.replace
        error = PermissionError("video replacement denied")
        error.winerror = 5
        attempts = []

        def encode(*args, **kwargs):
            Path(args[0][-1]).write_bytes(b"new complete video")
            return mock.Mock(returncode=0, stderr="")

        def replace_after_denial(source, destination):
            attempts.append(destination)
            if len(attempts) < 3:
                self.assertEqual(old_video.read_bytes(), b"previous complete video")
                raise error
            replace(source, destination)

        with (
            mock.patch("recorder.subprocess.run", side_effect=encode),
            mock.patch("recorder.os.replace", side_effect=replace_after_denial),
            mock.patch("recorder.time.sleep") as sleep,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(recorder.encode_timelapse(self.run_dir, state, 4), 1)
        self.assertEqual(old_video.read_bytes(), b"new complete video")
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(list(self.run_dir.glob(".encode-*")), [])

    def test_video_replacement_preserves_prior_video_after_persistent_denial(self):
        old_video = self.run_dir / "timelapse.mp4"
        old_video.write_bytes(b"previous complete video")
        state = {"frames": [self.add_frame()]}
        error = PermissionError("video replacement denied")
        error.winerror = 5

        def encode(*args, **kwargs):
            Path(args[0][-1]).write_bytes(b"new complete video")
            return mock.Mock(returncode=0, stderr="")

        with (
            mock.patch("recorder.subprocess.run", side_effect=encode),
            mock.patch("recorder.os.replace", side_effect=error) as replace,
            mock.patch("recorder.time.sleep"),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(PermissionError):
                recorder.encode_timelapse(self.run_dir, state, 4)
        self.assertEqual(replace.call_count, 6)
        self.assertEqual(old_video.read_bytes(), b"previous complete video")
        self.assertEqual(list(self.run_dir.glob(".encode-*")), [])

    def test_playback_range_validation_and_inclusive_boundaries(self):
        frames = [self.add_frame(i) for i in range(4)]
        omission = {
            "first_frame": frames[1]["file"],
            "last_frame": frames[2]["file"],
            "reason": "Reviewed idle interval",
        }
        state = {"frames": frames, "playback_omissions": [omission]}
        self.assertEqual(recorder.playback_frames(state), [frames[0], frames[3]])
        self.assertEqual(state["frames"], frames)
        invalid = [
            {**omission, "first_frame": "missing"},
            {**omission, "first_frame": frames[3]["file"]},
            {**omission, "reason": " "},
            {
                **omission,
                "first_frame": frames[0]["file"],
                "last_frame": frames[3]["file"],
            },
        ]
        for item in invalid:
            with self.subTest(item=item), self.assertRaises(ValueError):
                recorder.playback_frames(
                    {"frames": frames, "playback_omissions": [item]}
                )
        with self.assertRaisesRegex(ValueError, "overlap"):
            recorder.playback_frames(
                {"frames": frames, "playback_omissions": [omission, omission]}
            )

    @unittest.skipUnless(os.name == "nt", "Run locking requires Windows msvcrt.")
    def test_playback_edit_preserves_raw_history_backup_and_resume(self):
        manifest = recorder.Manifest(self.run_dir, 300)
        entries = [
            self.add_frame(i, color)
            for i, color in enumerate(("red", "green", "blue", "magenta"))
        ]
        for entry in entries:
            manifest.capture(entry, {"hwnd": 1})
        manifest.update(status="stopped", progress=[{"text": "Preserve this evidence"}])
        original_manifest = (self.run_dir / "manifest.json").read_bytes()
        original_frames = {
            entry["file"]: recorder.frame_path(self.run_dir, entry["file"]).read_bytes()
            for entry in entries
        }
        (self.run_dir / "timelapse.mp4").write_bytes(b"original video")
        args = recorder.arguments(
            [
                "--run-id",
                "test-run",
                "--omit-playback",
                entries[1]["file"],
                entries[2]["file"],
                "--omission-reason",
                "Reviewed idle interval",
            ]
        )
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(recorder.edit_playback(self.run_dir, args), 0)
        state = json.loads((self.run_dir / "manifest.json").read_text())
        self.assertEqual(state["frames"], entries)
        self.assertEqual(state["progress"], [{"text": "Preserve this evidence"}])
        self.assertEqual(state["status"], "stopped")
        self.assertEqual(state["timelapse_frame_count"], 2)
        self.assertEqual(state["timelapse_source_frame_count"], 4)
        self.assertEqual(state["timelapse_omitted_frame_count"], 2)
        self.assertFalse(state["playback_pending"])
        backup = self.run_dir / state["playback_omissions"][0]["backup"]["directory"]
        self.assertEqual((backup / "manifest.json").read_bytes(), original_manifest)
        self.assertEqual((backup / "timelapse.mp4").read_bytes(), b"original video")
        for relative, data in original_frames.items():
            self.assertEqual(
                recorder.frame_path(self.run_dir, relative).read_bytes(), data
            )
        stream = imageio_ffmpeg.read_frames(str(self.run_dir / "timelapse.mp4"))
        try:
            next(stream)
            decoded = list(stream)
        finally:
            stream.close()
        self.assertEqual(len(decoded), 2)
        colors = [
            Image.frombytes("RGB", (1600, 900), frame).getpixel((800, 400))
            for frame in decoded
        ]
        self.assertGreater(colors[0][0], 200)
        self.assertLess(colors[0][2], 20)
        self.assertGreater(colors[1][0], 200)
        self.assertGreater(colors[1][2], 200)
        resumed = recorder.Manifest(self.run_dir, 300)
        resumed.capture(self.add_frame(4, "cyan"), {"hwnd": 1})
        self.assertEqual(
            recorder.encode_timelapse(self.run_dir, resumed.snapshot(), 4), 3
        )
        self.assertEqual(len(resumed.snapshot()["frames"]), 5)
        self.assertEqual(len(resumed.snapshot()["playback_omissions"]), 1)

    @unittest.skipUnless(os.name == "nt", "Run locking requires Windows msvcrt.")
    def test_failed_playback_rebuild_keeps_omission_and_old_video(self):
        manifest = recorder.Manifest(self.run_dir, 300)
        entries = [self.add_frame(i) for i in range(3)]
        for entry in entries:
            manifest.capture(entry, {"hwnd": 1})
        (self.run_dir / "timelapse.mp4").write_bytes(b"prior complete video")
        args = recorder.arguments(
            [
                "--run-id",
                "test-run",
                "--omit-playback",
                entries[1]["file"],
                entries[1]["file"],
                "--omission-reason",
                "Reviewed idle interval",
            ]
        )
        with mock.patch(
            "recorder.encode_timelapse", side_effect=RuntimeError("encode failed")
        ):
            with self.assertRaisesRegex(RuntimeError, "encode failed"):
                recorder.edit_playback(self.run_dir, args)
        state = json.loads((self.run_dir / "manifest.json").read_text())
        self.assertEqual(state["frames"], entries)
        self.assertTrue(state["playback_pending"])
        self.assertEqual(state["playback_error"], "encode failed")
        self.assertEqual(recorder.playback_frames(state), [entries[0], entries[2]])
        self.assertEqual(
            (self.run_dir / "timelapse.mp4").read_bytes(), b"prior complete video"
        )
        retry = recorder.arguments(["--run-id", "test-run", "--reencode-only"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(recorder.edit_playback(self.run_dir, retry), 0)
        self.assertFalse(
            json.loads((self.run_dir / "manifest.json").read_text())["playback_pending"]
        )

    @unittest.skipUnless(os.name == "nt", "Run locking requires Windows msvcrt.")
    def test_playback_edit_refuses_active_writer_before_any_change(self):
        recorder.Manifest(self.run_dir, 300)
        before = (self.run_dir / "manifest.json").read_bytes()
        args = recorder.arguments(["--run-id", "test-run", "--reencode-only"])
        with recorder.RunLock(self.run_dir), self.assertRaisesRegex(
            RuntimeError, "lock"
        ):
            recorder.edit_playback(self.run_dir, args)
        self.assertEqual((self.run_dir / "manifest.json").read_bytes(), before)
        self.assertFalse((self.run_dir / "playback-backups").exists())

    def test_mp4_decodes_all_frames_with_changing_window_sizes(self):
        state = {
            "frames": [self.add_frame(0, "red"), self.add_frame(1, "blue", (800, 600))]
        }
        recorder.encode_timelapse(self.run_dir, state, 4)
        stream = imageio_ffmpeg.read_frames(str(self.run_dir / "timelapse.mp4"))
        try:
            metadata = next(stream)
            frames = list(stream)
        finally:
            stream.close()
        self.assertEqual(metadata["size"], (1600, 900))
        self.assertEqual(len(frames), 2)
        first = Image.frombytes("RGB", (1600, 900), frames[0]).getpixel((800, 400))
        second = Image.frombytes("RGB", (1600, 900), frames[1]).getpixel((800, 400))
        self.assertGreater(first[0], 200)
        self.assertGreater(second[2], 200)
        self.assertLess(second[0], 20)


if __name__ == "__main__":
    unittest.main()
