"""Exercise the managed client with a real Windows pipe and no Altium process."""

import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import unittest
from unittest.mock import patch

import pywintypes
import win32event
import win32file
import win32pipe
from winerror import ERROR_PIPE_CONNECTED

from server.managed_altium import (
    ManagedAltium, ManagedEndpoint, ManagedOutcomeUnknown, _exchange, _read_frame, _request, _wait_io, _write_frame,
)


class ManagedPipeTests(unittest.TestCase):
    def round_trip(self, response_id, before_send):
        pid = os.getpid()
        request_id = "a" * 32
        with ExitStack() as cleanup:
            handle = win32pipe.CreateNamedPipe(
                rf"\\.\pipe\altium-mcp-sdk-{pid}",
                win32pipe.PIPE_ACCESS_DUPLEX | win32file.FILE_FLAG_OVERLAPPED,
                win32pipe.PIPE_TYPE_BYTE | win32pipe.PIPE_READMODE_BYTE | win32pipe.PIPE_WAIT,
                1, 65536, 65536, 1000, None,
            )
            cleanup.callback(handle.Close)
            def server():
                deadline = time.monotonic() + 2.0
                operation = pywintypes.OVERLAPPED()
                operation.hEvent = win32event.CreateEvent(None, True, False, None)
                try:
                    try:
                        code = win32pipe.ConnectNamedPipe(handle, operation)
                        _wait_io(handle, operation, code, deadline)
                    except pywintypes.error as error:
                        if error.winerror != ERROR_PIPE_CONNECTED:
                            raise
                finally:
                    operation.hEvent.Close()
                request = _read_frame(handle, deadline)
                result = {"success": True, "result": "Вывод"}
                response = {"protocol": 1, "request_id": response_id, "state": "terminal", "result": result}
                encoded = json.dumps(response, ensure_ascii=False).encode() + b"\n"
                _write_frame(handle, encoded[:24], deadline)
                _write_frame(handle, encoded[24:], deadline)
                return request

            with ThreadPoolExecutor(max_workers=1) as pool:
                worker = pool.submit(server)
                request = _request("list_open_documents", request_id, {})
                try:
                    return _exchange(pid, request, 1.0, before_send)
                finally:
                    self.assertEqual(worker.result(timeout=3), request)

    def test_verified_peer_and_split_response(self):
        journal = []
        self.assertEqual(self.round_trip("a" * 32, lambda: journal.append(True)),
                         ("terminal", {"success": True, "result": "Вывод"}))
        self.assertEqual(journal, [True])

    def test_wrong_id_after_send_is_unknown(self):
        with self.assertRaises(ManagedOutcomeUnknown):
            self.round_trip("b" * 32, lambda: None)

    def test_ambiguous_process_inventory_never_uses_a_cached_endpoint(self):
        client = ManagedAltium()
        endpoint = ManagedEndpoint(42, "a" * 32, "test", "26.11", frozenset({"list_open_documents"}))
        with patch("server.managed_altium.win_processes.pids_by_name", side_effect=[[42], [42, 43]]), \
                patch("server.managed_altium._same_executable", return_value=True), \
                patch.object(client, "_probe", return_value=endpoint):
            self.assertIs(client._find_endpoint("X2.EXE"), endpoint)
            self.assertIsNone(client._find_endpoint("X2.EXE"))
