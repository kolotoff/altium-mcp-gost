"""Exercise the production bridge with simulated Altium responses."""

import asyncio
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, patch

from server import main
from server.altium_transport import ResidentSession, atomic_json


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
            ROUTING_NATIVE_DRC_TIMEOUT=0.25, RESIDENT_POLL=0.005,
            RESIDENT_PICKUP_TIMEOUT=0.04, RESIDENT_DRAIN_TIMEOUT=0.04,
        ))
        self.start_patch(patch.dict(main.os.environ, {"ALTIUM_MCP_REUSE_BRIDGE": "0"}))
        self.start_patch(patch.object(main, "altium_limit_problem", return_value=None))
        self.start_patch(patch.object(main.sandbox, "altium_hung", return_value=False))
        self.start_patch(patch.object(main, "_dismiss_altium_dialogs"))
        self.start_patch(patch.object(main.AltiumBridge, "ensure_paths", new=AsyncMock(return_value=None)))
        self.start_patch(patch.object(main.AltiumBridge, "_altium_running", return_value=True))
        self.start_patch(patch.object(main.AltiumBridge, "stop_script_debugger", new=AsyncMock()))

    def start_patch(self, patcher):
        patcher.start()
        self.addCleanup(patcher.stop)

    def claim(self, path=None):
        path = self.request if path is None else path
        request = json.loads(path.read_text(encoding="utf-8-sig"))
        path.unlink()
        return request

    def reply(self, request):
        atomic_json(self.response, dict(success=True, request_id=request["request_id"], result=request["command"]))

    def enable_resident(self, bridge):
        bridge._resident_enabled = True
        bundle = self.root / "Altium_API_123456abcdef.pas"
        self.start_patch(patch.object(main.script_bundle, "ensure_bundle", return_value=bundle))
        bridge.config.script_path = str(main.DEFAULT_SCRIPT_PATH)
        return bundle

    async def test_specialization_failure_and_custom_projects_use_the_full_bundle(self):
        bridge = main.AltiumBridge()
        bridge.config.altium_exe_path = main.sys.executable
        bridge.config.script_path = str(main.DEFAULT_SCRIPT_PATH)
        bundle = self.root / "full.pas"
        bundle_dir = self.root / "bridge"
        with patch.object(main.script_bundle, "ensure_bundle",
                          side_effect=[ValueError("unknown branch"), bundle]) as build, \
                patch.object(bridge, "_launch_bridge_file", return_value=True) as launch:
            self.assertTrue(await bridge.run_altium_script("missing_branch"))
            self.assertEqual(build.call_args_list[0].kwargs, {"command": "missing_branch"})
            build.assert_called_with(bridge.config.script_path, bundle_dir)
            launch.assert_called_once_with(bundle, "Run")

        project = self.root / "custom.PrjScr"
        project.touch()
        bridge.config.script_path = str(project)
        with patch.object(main.script_bundle, "ensure_bundle", return_value=bundle) as build, \
                patch.object(bridge, "_launch_bridge_file", return_value=True) as launch:
            self.assertTrue(await bridge.run_altium_script("get_board_summary"))
            build.assert_called_once_with(str(project), bundle_dir)
            launch.assert_called_once_with(bundle, "Run")

    def test_resident_build_uses_the_command_group_for_the_default_bridge(self):
        bridge = main.AltiumBridge()
        bridge._resident_enabled = True
        bridge.config.script_path = str(main.DEFAULT_SCRIPT_PATH)
        bundle = self.root / "bridge.pas"
        with patch.object(main.script_bundle, "ensure_bundle", return_value=bundle) as build:
            for command, group in (
                ("get_layout", "placement"), ("check_placement", "placement"),
                ("get_component_pins", "placement"), ("get_net_connections", "placement"),
                ("get_schematic_pins", "schematic"), ("create_symbols_batch", "symbols"),
                ("list_open_documents", "routing"),
            ):
                self.assertEqual(bridge._resident_bundle(command), bundle)
                build.assert_called_with(bridge.config.script_path, self.root / "bridge",
                                         resident=True, resident_group=group)
            build.reset_mock()
            self.assertIsNone(bridge._resident_bundle("save_current_document"))
            build.assert_not_called()

    def test_resident_build_failure_only_disables_the_failed_group(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        routing_bundle = self.root / "routing_123456abcdef.pas"
        with patch.object(main.script_bundle, "ensure_bundle", side_effect=[
            ValueError("bad symbols unit"), routing_bundle,
        ]) as build:
            self.assertIsNone(bridge._resident_bundle("create_schematic_symbol"))
            self.assertIsNone(bridge._resident_bundle("get_symbol_primitives"))
            self.assertEqual(bridge._resident_bundle("pcb_routing"), routing_bundle)
        self.assertEqual(build.call_count, 2)

    async def test_resident_start_failure_only_disables_the_failed_group(self):
        bridge = main.AltiumBridge()
        bundle = self.enable_resident(bridge)

        async def one_shot(command):
            self.reply(self.claim())
            return True

        with patch.object(bridge, "_launch_bridge_file", return_value=False), \
                patch.object(bridge, "run_altium_script", side_effect=one_shot):
            result = await bridge.execute_command("create_symbols_batch", {})
        self.assertTrue(result["success"])
        self.assertIsNone(bridge._resident_bundle("get_symbol_primitives"))
        self.assertEqual(bridge._resident_bundle("pcb_routing"), bundle)

    async def test_resident_reused_by_separate_servers_and_drained_for_sandbox(self):
        first, second = main.AltiumBridge(), main.AltiumBridge()
        bundle = self.enable_resident(first)
        second._resident_enabled = True
        second.config.script_path = str(main.DEFAULT_SCRIPT_PATH)
        leases = []

        async def native():
            session = ResidentSession.load(self.root)
            leases.append(session)
            session.ready.touch()
            try:
                while session.lease.exists():
                    if session.request.exists():
                        self.reply(self.claim(session.request))
                    await asyncio.sleep(.001)
            finally:
                session.ready.unlink()

        workers = []

        def launch(path, entry):
            self.assertEqual((path, entry), (bundle, "RunResident"))
            workers.append(asyncio.create_task(native()))
            return True

        with patch.object(first, "_launch_bridge_file", side_effect=launch) as boot, \
                patch.object(second, "_launch_bridge_file") as unexpected:
            try:
                self.assertTrue((await first.execute_command("list_open_documents", {}))["success"])
                self.assertTrue((await second.execute_command("pcb_routing", {"operation": "snapshot"}))["success"])
                async with second.exclusive_execution() as problem:
                    self.assertIsNone(problem)
                    self.assertFalse(leases[0].lease.exists())
                    self.assertFalse(leases[0].ready.exists())
                boot.assert_called_once()
                unexpected.assert_not_called()
            finally:
                for worker in workers:
                    worker.cancel()
                await asyncio.gather(*workers, return_exceptions=True)

    async def test_stale_resident_mailbox_withdrawn_before_one_shot_fallback(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        executable = os.path.normcase(os.path.normpath(bridge.config.altium_exe_path))
        stale = ResidentSession.start(self.root, "123456abcdef", executable)
        stale.ready.touch()

        async def launch(command):
            self.assertEqual(command, "pcb_routing")
            self.assertFalse(stale.request.exists())
            self.assertFalse(stale.lease.exists())
            self.reply(self.claim())
            return True

        with patch.object(bridge, "run_altium_script", side_effect=launch) as one_shot, \
                patch.object(main.AltiumBridge, "_resident_may_own_marker", return_value=False), \
                patch.object(bridge, "_launch_bridge_file") as resident_launch:
            result = await bridge.execute_command("pcb_routing", {"operation": "batch"})
        self.assertTrue(result["success"])
        one_shot.assert_awaited_once()
        resident_launch.assert_not_called()

    async def test_live_resident_can_finish_ui_work_before_claiming_next_request(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        executable = os.path.normcase(os.path.normpath(bridge.config.altium_exe_path))
        session = ResidentSession.start(self.root, "123456abcdef", executable)
        session.ready.touch()
        settling = session.settling
        settling.touch()

        async def resume_polling():
            while not session.request.exists():
                await asyncio.sleep(.002)
            await asyncio.sleep(.1)
            settling.unlink(missing_ok=True)
            if session.request.exists():
                self.reply(self.claim(session.request))

        async def launch(command):
            self.reply(self.claim())
            return True

        with patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", .5), \
                patch.object(bridge, "run_altium_script", side_effect=launch) as one_shot:
            worker = asyncio.create_task(resume_polling())
            try:
                result = await bridge.execute_command("create_pcb_rule", {})
                self.assertTrue(result["success"])
                one_shot.assert_not_called()
            finally:
                worker.cancel()
                await asyncio.gather(worker, return_exceptions=True)

    async def test_resident_switch_waits_for_the_old_group_to_finish_ui_work(self):
        bridge = main.AltiumBridge()
        placement_bundle = self.enable_resident(bridge)
        executable = os.path.normcase(os.path.normpath(bridge.config.altium_exe_path))
        old = ResidentSession.start(self.root, "000000000000", executable)
        old.ready.touch()
        old.settling.touch()
        finished = asyncio.Event()

        async def finish_old():
            while old.lease.exists():
                await asyncio.sleep(.002)
            await asyncio.sleep(.1)
            old.ready.unlink()
            old.settling.unlink()
            finished.set()

        def launch(bundle, entry):
            self.assertTrue(finished.is_set())
            self.assertEqual((bundle, entry), (placement_bundle, "RunResident"))
            current = ResidentSession.load(self.root)
            self.assertNotEqual(old.token, current.token)
            self.reply(self.claim(current.request))
            return True

        with patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", .5), \
                patch.object(bridge, "_launch_bridge_file", side_effect=launch) as boot, \
                patch.object(bridge, "run_altium_script") as one_shot:
            worker = asyncio.create_task(finish_old())
            try:
                self.assertTrue((await bridge.execute_command("get_layout", {}))["success"])
                boot.assert_called_once()
                one_shot.assert_not_called()
            finally:
                worker.cancel()
                await asyncio.gather(worker, return_exceptions=True)

    async def test_resident_switch_timeout_leaves_the_next_request_unstarted(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        executable = os.path.normcase(os.path.normpath(bridge.config.altium_exe_path))
        retiring = ResidentSession.start(self.root, "000000000000", executable)
        retiring.ready.touch()
        retiring.settling.touch()
        with patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", .08), \
                patch.object(main.AltiumBridge, "_resident_may_own_marker", return_value=True), \
                patch.object(bridge, "_launch_bridge_file") as boot, \
                patch.object(bridge, "run_altium_script") as one_shot:
            for _ in range(2):
                result = await bridge.execute_command("get_layout", {})
                self.assertEqual(result["execution_state"], "not_started")
            async with bridge.exclusive_execution() as problem:
                self.assertEqual(problem["execution_state"], "not_started")
        self.assertEqual(bridge.command_status(), {"pending": False})
        self.assertFalse(retiring.lease.exists())
        self.assertTrue(retiring.ready.exists())
        self.assertTrue(retiring.settling.exists())
        boot.assert_not_called()
        one_shot.assert_not_called()

    async def test_reuse_timeout_withdraws_unclaimed_work_without_launching_behind_ui(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        executable = os.path.normcase(os.path.normpath(bridge.config.altium_exe_path))
        active = ResidentSession.start(self.root, "123456abcdef", executable)
        active.ready.touch()
        active.settling.touch()
        with patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", .08), \
                patch.object(main.AltiumBridge, "_resident_may_own_marker", return_value=True), \
                patch.object(bridge, "_launch_bridge_file") as boot, \
                patch.object(bridge, "run_altium_script") as one_shot:
            result = await bridge.execute_command("create_pcb_rule", {})
        self.assertEqual(result["execution_state"], "not_started")
        self.assertEqual(bridge.command_status(), {"pending": False})
        self.assertFalse(active.request.exists())
        self.assertFalse(active.lease.exists())
        self.assertTrue(active.ready.exists())
        boot.assert_not_called()
        one_shot.assert_not_called()

    async def test_retirement_removes_settling_markers_from_a_dead_process(self):
        stale = ResidentSession.start(self.root, "000000000000", "X2.EXE")
        stale.ready.touch()
        stale.settling.touch()
        with patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", .08), \
                patch.object(main.AltiumBridge, "_resident_may_own_marker", return_value=False):
            self.assertTrue(await main.AltiumBridge._retire_resident(stale, defer_if_live=True))
        self.assertFalse(stale.lease.exists())
        self.assertFalse(stale.ready.exists())
        self.assertFalse(stale.settling.exists())

    async def test_sandbox_does_not_start_behind_the_idle_bridge_message_pump(self):
        bridge = main.AltiumBridge()
        idle = ResidentSession.start(self.root, "000000000000", "X2.EXE")
        idle.ready.touch()
        with patch.object(main.AltiumBridge, "_resident_may_own_marker", return_value=True):
            async with bridge.exclusive_execution() as problem:
                self.assertEqual(problem["execution_state"], "not_started")
        self.assertFalse(idle.lease.exists())
        self.assertTrue(idle.ready.exists())

    def test_only_processes_older_than_the_ready_marker_can_own_it(self):
        session = ResidentSession.start(self.root, "000000000000", str(self.root / "X2.EXE"))
        session.ready.touch()
        written = session.ready.stat().st_mtime
        with patch.object(main.win_processes, "pids_by_name", return_value=[123]), \
                patch.object(main.win_processes, "image_path", return_value=session.executable), \
                patch.object(main.win32api, "OpenProcess") as open_process, \
                patch.object(main.win32process, "GetProcessTimes", side_effect=[
                    {"CreationTime": datetime.fromtimestamp(written - 1, timezone.utc)},
                    {"CreationTime": datetime.fromtimestamp(written + 1, timezone.utc)},
                    OSError("unknown"),
                ]):
            self.assertTrue(main.AltiumBridge._resident_may_own_marker(session))
            self.assertFalse(main.AltiumBridge._resident_may_own_marker(session))
            self.assertTrue(main.AltiumBridge._resident_may_own_marker(session))
            self.assertEqual(open_process.return_value.Close.call_count, 3)
        with patch.object(main.win_processes, "pids_by_name", return_value=[123]), \
                patch.object(main.win_processes, "image_path", return_value=str(self.root / "other" / "X2.EXE")):
            self.assertFalse(main.AltiumBridge._resident_may_own_marker(session))

    async def test_late_routing_response_keeps_handoff_protected(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        active = None
        request = None

        def launch(bundle, entry):
            nonlocal active, request
            active = ResidentSession.load(self.root)
            active.ready.touch()
            active.settling.touch()
            request = self.claim(active.request)
            return True

        with patch.object(main, "ROUTING_MUTATION_TIMEOUT", .025), \
                patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", .08), \
                patch.object(main.AltiumBridge, "_resident_may_own_marker", return_value=True), \
                patch.object(bridge, "_launch_bridge_file", side_effect=launch) as boot, \
                patch.object(bridge, "run_altium_script") as one_shot:
            timed_out = await bridge.execute_command("pcb_routing", {"operation": "batch"}, timeout=.025)
            self.assertEqual(timed_out["execution_state"], "unknown")
            self.assertTrue(bridge.command_status()["pending"])
            self.reply(request)
            next_request = await bridge.execute_command("get_layout", {})
            self.assertEqual(next_request["execution_state"], "not_started")
            self.assertEqual(bridge.command_status(), {"pending": False})
            boot.assert_called_once()
            one_shot.assert_not_called()
        self.assertTrue(active.ready.exists())
        self.assertTrue(active.settling.exists())

    async def test_response_timeout_keeps_exchange_locked_until_stop_settles(self):
        bridge = main.AltiumBridge()
        stop_sent = asyncio.Event()

        async def launch(command):
            self.claim()
            return True

        async def stop():
            stop_sent.set()

        with patch.object(bridge, "run_altium_script", side_effect=launch), \
                patch.object(bridge, "stop_script_debugger", side_effect=stop), \
                patch.object(bridge, "STOP_SETTLE", .08):
            task = asyncio.create_task(bridge.execute_command("edit", {}, timeout=.025))
            try:
                await asyncio.wait_for(stop_sent.wait(), 1)
                self.assertTrue(bridge._command_lock.locked())
                self.assertFalse(task.done())
                self.assertEqual((await task)["execution_state"], "unknown")
            finally:
                await asyncio.gather(task, return_exceptions=True)

    async def test_released_resident_ends_the_settling_wait_without_stealing_request(self):
        session = ResidentSession.start(self.root, "123456abcdef", "X2.EXE")
        session.ready.touch()
        session.settling.touch()
        session.request.touch()

        async def release():
            await asyncio.sleep(.09)
            session.lease.unlink()

        with patch.object(main, "RESIDENT_SETTLING_PICKUP_TIMEOUT", 5):
            worker = asyncio.create_task(release())
            started, _ = await asyncio.gather(
                asyncio.wait_for(main.AltiumBridge._wait_for_start(.04, session.request, resident=session), .6),
                worker,
            )
        self.assertFalse(started)
        self.assertTrue(session.request.exists())

    async def test_resident_claim_at_pickup_deadline_is_not_replayed(self):
        bridge = main.AltiumBridge()
        self.enable_resident(bridge)
        executable = os.path.normcase(os.path.normpath(bridge.config.altium_exe_path))
        session = ResidentSession.start(self.root, "123456abcdef", executable)
        session.ready.touch()

        async def pickup_deadline(timeout, path, *, resident):
            self.assertEqual(path, session.request)
            self.assertEqual(resident, session)
            self.reply(self.claim(path))
            return False

        with patch.object(bridge, "_wait_for_start", side_effect=pickup_deadline), \
                patch.object(bridge, "run_altium_script") as one_shot:
            result = await bridge.execute_command("pcb_routing", {"operation": "batch"})
        self.assertTrue(result["success"])
        one_shot.assert_not_called()

    async def test_clients_share_an_os_writer_lock(self):
        active = 0
        maximum = 0
        jobs = []

        async def launch(command):
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

        async def complete(command):
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
        async def launch(command):
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

        async def launch(command):
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

                async def abandon(command):
                    self.claim()
                    return True

                with patch.object(bridge, "run_altium_script", side_effect=abandon):
                    first = await bridge.execute_command("edit", {}, timeout=0.015)
                request_id = first["request_id"]
                target = self.root / f"response-{request_id}.json" if legacy else self.response
                atomic_json(target, dict(success=True, request_id=request_id))

                restarted = main.AltiumBridge()
                self.assertTrue(restarted.command_status()["terminal_response_available"])

                async def complete(command):
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

        async def launch(command):
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

    async def test_sandbox_keeps_shared_lock_after_client_cancellation(self):
        bridge, second = main.AltiumBridge(), main.AltiumBridge()
        started, complete = asyncio.Event(), asyncio.Event()

        @main._serialized_sandbox
        async def sandbox_operation():
            started.set()
            await complete.wait()

        async def launch(command):
            self.reply(self.claim())
            return True

        with patch.object(main, "altium_bridge", bridge), patch.object(second, "run_altium_script", side_effect=launch) as launch:
            task = asyncio.create_task(sandbox_operation())
            await started.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            following = asyncio.create_task(second.execute_command("read", {}, timeout=1))
            try:
                await asyncio.sleep(0.025)
                launch.assert_not_awaited()
            finally:
                complete.set()
            self.assertTrue((await following)["success"])

    async def test_waits_for_transient_hung_state_before_rejecting_a_command(self):
        bridge = main.AltiumBridge()

        async def launch(command):
            self.reply(self.claim())
            return True

        with (
            patch.object(main.sandbox, "altium_hung", side_effect=[True, False]),
            patch.object(bridge, "run_altium_script", side_effect=launch),
        ):
            self.assertTrue((await bridge.execute_command("read", {}, timeout=1))["success"])

    async def test_drc_refuses_existing_dialog_before_publishing_request(self):
        import drc

        bridge = main.AltiumBridge()
        with (patch.object(main, "altium_bridge", bridge),
              patch.object(drc, "find_dialog", return_value=123),
              patch.object(bridge, "run_altium_script", new=AsyncMock()) as launch):
            reply = json.loads(await main.run_drc(None))
        self.assertFalse(reply["success"])
        self.assertIn("already open", reply["error"])
        launch.assert_not_awaited()
        self.assertFalse(self.request.exists())

    async def test_drc_driver_waits_for_the_queued_command_to_start(self):
        import drc

        first, bridge = main.AltiumBridge(), main.AltiumBridge()
        first_started, first_complete = asyncio.Event(), asyncio.Event()
        drc_request = None
        driver_started = asyncio.Event()

        async def launch_first(command):
            request = self.claim()
            first_started.set()
            await first_complete.wait()
            self.reply(request)
            return True

        async def launch_drc(command):
            nonlocal drc_request
            drc_request = self.claim()
            return True

        async def drive(outcome, *_args, **_kwargs):
            self.assertEqual(drc_request["command"], "run_drc")
            outcome.pressed = True
            driver_started.set()
            atomic_json(self.response, dict(success=True, request_id=drc_request["request_id"], result={}))

        with (patch.object(main, "altium_bridge", bridge),
              patch.object(first, "run_altium_script", side_effect=launch_first),
              patch.object(bridge, "run_altium_script", side_effect=launch_drc),
              patch.object(drc, "find_dialog", return_value=None) as check,
              patch.object(drc, "drive_dialog", side_effect=drive)):
            before = asyncio.create_task(first.execute_command("read", {}, timeout=1))
            await first_started.wait()
            pending = asyncio.create_task(main.run_drc(None))
            try:
                await asyncio.sleep(0.025)
                check.assert_not_called()
                self.assertFalse(driver_started.is_set())
            finally:
                first_complete.set()
            self.assertTrue((await before)["success"])
            self.assertTrue(json.loads(await pending)["ran"])

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

        async def launch(command):
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
