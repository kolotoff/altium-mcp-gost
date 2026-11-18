"""Exercise the production bridge with simulated Altium responses."""

import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server import main
from server.altium_transport import atomic_json


class TransportTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.request = self.root / "request.json"
        self.response = self.root / "response.json"
        self.start_patch(patch.multiple(
            main, EXCHANGE_DIR=self.root, REQUEST_FILE=self.request,
            RESPONSE_FILE=self.response, PROGRESS_FILE=self.root / "progress.txt",
            STUCK_MARKER=self.root / "mcp_script_stuck.txt", START_TIMEOUT=0.08,
            EXCHANGE_POLL=0.005, ROUTING_MUTATION_TIMEOUT=0.25,
            ROUTING_NATIVE_DRC_TIMEOUT=0.25,
        ))
        self.start_patch(patch.object(main, "altium_limit_problem", return_value=None))
        self.start_patch(patch.object(main.sandbox, "altium_hung", return_value=False))
        self.start_patch(patch.object(main, "_dismiss_altium_dialogs"))
        self.start_patch(patch.object(main.AltiumBridge, "ensure_paths", new=AsyncMock(return_value=None)))
        self.start_patch(patch.object(main.AltiumBridge, "_altium_running", return_value=True))
        self.start_patch(patch.object(main.AltiumBridge, "stop_script_debugger", new=AsyncMock()))

    def start_patch(self, patcher):
        patcher.start()
        self.addCleanup(patcher.stop)

    def claim(self):
        request = json.loads(self.request.read_text(encoding="utf-8-sig"))
        self.request.unlink()
        return request

    def reply(self, request):
        atomic_json(self.response, dict(success=True, request_id=request["request_id"], result=request["command"]))

    async def test_clients_share_an_os_writer_lock(self):
        active = 0
        maximum = 0
        jobs = []

        async def launch():
            nonlocal active, maximum
            request = self.claim()
            active += 1
            maximum = max(maximum, active)

            async def complete():
                nonlocal active
                await asyncio.sleep(0.02)
                active -= 1
                self.reply(request)

            jobs.append(asyncio.create_task(complete()))
            return True

        first, second = main.AltiumBridge(), main.AltiumBridge()
        with patch.object(main.AltiumBridge, "run_altium_script", side_effect=launch):
            replies = await asyncio.gather(
                first.execute_command("one", {}, timeout=1), second.execute_command("two", {}, timeout=1),
            )
            await asyncio.gather(*jobs)
        self.assertEqual(maximum, 1)
        self.assertEqual([r["result"] for r in replies], ["one", "two"])
        self.assertNotEqual(replies[0]["request_id"], replies[1]["request_id"])

    async def test_legacy_fork_lock_blocks_request_publication(self):
        legacy = main.ExchangeLock(self.root / "command.lock")
        self.assertTrue(await legacy.acquire(1))
        bridge = main.AltiumBridge()

        async def complete():
            self.reply(self.claim())
            return True

        with patch.object(bridge, "run_altium_script", side_effect=complete) as launch:
            task = asyncio.create_task(bridge.execute_command("edit", {}, timeout=1))
            try:
                await asyncio.sleep(0.02)
                launch.assert_not_called()
                self.assertFalse(self.request.exists())
            finally:
                legacy.release()
            self.assertTrue((await task)["success"])

    async def test_wrong_response_id_blocks_next_launch(self):
        async def launch():
            self.claim()
            atomic_json(self.response, {"success": True, "request_id": "wrong"})
            return True

        bridge = main.AltiumBridge()
        with patch.object(bridge, "run_altium_script", side_effect=launch) as launcher:
            first = await bridge.execute_command("edit", {}, timeout=0.025)
            second = await bridge.execute_command("edit", {}, timeout=0.025)
        self.assertEqual(first["execution_state"], "unknown")
        self.assertFalse(second["success"])
        self.assertEqual(launcher.await_count, 1)
        self.assertFalse(bridge.command_status()["terminal_response_available"])

    async def test_routing_mutation_and_native_drc_can_exceed_standard_timeout(self):
        jobs = []

        async def launch():
            request = self.claim()

            async def complete():
                await asyncio.sleep(0.04)
                self.reply(request)

            jobs.append(asyncio.create_task(complete()))
            return True

        bridge = main.AltiumBridge()
        with patch.object(bridge, "run_altium_script", side_effect=launch):
            for operation in ("batch", "native_drc"):
                with self.subTest(operation=operation):
                    result = await bridge.execute_command("pcb_routing", {"operation": operation}, timeout=0.01)
                    self.assertTrue(result["success"])
                    self.assertEqual(len(result["request_id"]), 32)
            await asyncio.gather(*jobs)

    async def test_terminal_response_clears_pending_across_restart(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                bridge = main.AltiumBridge()

                async def abandon():
                    self.claim()
                    return True

                with patch.object(bridge, "run_altium_script", side_effect=abandon):
                    first = await bridge.execute_command("edit", {}, timeout=0.015)
                request_id = first["request_id"]
                target = self.root / f"response-{request_id}.json" if legacy else self.response
                atomic_json(target, dict(success=True, request_id=request_id))

                restarted = main.AltiumBridge()
                self.assertTrue(restarted.command_status()["terminal_response_available"])

                async def complete():
                    self.reply(self.claim())
                    return True

                with patch.object(restarted, "run_altium_script", side_effect=complete) as launch:
                    self.assertTrue((await restarted.execute_command("read", {}, timeout=0.1))["success"])
                launch.assert_awaited_once()
                self.assertTrue((self.root / f"completed-{request_id}.json").is_file())
                self.assertTrue((self.root / f"response-{request_id}.json").is_file())
                self.assertFalse(restarted.command_status()["pending"])

    async def test_cancellation_keeps_lock_until_native_completion(self):
        launched, release = asyncio.Event(), asyncio.Event()
        jobs = []

        async def launch():
            request = self.claim()

            async def complete():
                if request["command"] == "first":
                    launched.set()
                    await release.wait()
                self.reply(request)

            jobs.append(asyncio.create_task(complete()))
            return True

        bridge = main.AltiumBridge()
        with patch.object(bridge, "run_altium_script", side_effect=launch):
            first = asyncio.create_task(bridge.execute_command("first", {}, timeout=1))
            await launched.wait()
            first.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await first
            second = asyncio.create_task(bridge.execute_command("second", {}, timeout=1))
            try:
                await asyncio.sleep(0.02)
                self.assertEqual(len(jobs), 1)
            finally:
                release.set()
            self.assertTrue((await second)["success"])
            await asyncio.gather(*jobs)

    async def test_unclaimed_request_can_be_withdrawn(self):
        bridge = main.AltiumBridge()
        with patch.object(bridge, "run_altium_script", return_value=True):
            result = await bridge.execute_command("edit", {}, timeout=0.025)
        self.assertIn("not executed", result["error"])
        self.assertFalse(self.request.exists())
        self.assertFalse(bridge.command_status()["pending"])

    async def test_watcher_can_abort_query_and_allow_selection_restore(self):
        bridge = main.AltiumBridge()
        bridge.STOP_SETTLE = 0
        published = asyncio.Event()

        async def launch():
            request = self.claim()
            if request["command"] == "query_restore":
                self.reply(request)
            published.set()
            return True

        async def watch(abort):
            self.assertTrue(published.is_set())
            abort.set()

        with patch.object(bridge, "run_altium_script", side_effect=launch):
            reply = await bridge.execute_command("query_objects", {}, timeout=0.1, watcher=watch)
            self.assertTrue(reply["aborted"])
            self.assertFalse(bridge.command_status()["pending"])
            self.assertTrue((await bridge.execute_command("query_restore", {}, timeout=0.1))["success"])
