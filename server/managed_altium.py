"""Client for the optional Altium Designer managed editor extension."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
import math
import os
import re
import time
import uuid

import pywintypes
import win32event
import win32file
import win32pipe
from winerror import ERROR_IO_PENDING

from . import win_processes


PROTOCOL = 1
MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 64 * 1024 * 1024
PROBE_TIMEOUT = 0.5
SECURITY_SQOS_PRESENT = 0x00100000


class ManagedOutcomeUnknown(OSError):
    """A request may have reached the extension without a usable reply."""


@dataclass(frozen=True)
class ManagedEndpoint:
    pid: int
    instance_id: str
    build: str
    version: str
    commands: frozenset[str]


def _wait_io(handle, operation, code: int, deadline: float) -> int:
    if code == ERROR_IO_PENDING:
        milliseconds = max(0, math.ceil((deadline - time.monotonic()) * 1000))
        if win32event.WaitForSingleObject(operation.hEvent, milliseconds) != win32event.WAIT_OBJECT_0:
            try:
                win32file.CancelIo(handle)
            finally:
                # The kernel owns the buffer and OVERLAPPED until the I/O
                # completes, including when cancellation wins the race.
                try:
                    win32file.GetOverlappedResult(handle, operation, True)
                except pywintypes.error:
                    pass
            raise TimeoutError("Altium SDK pipe deadline expired")
    return win32file.GetOverlappedResult(handle, operation, False)


def _read_frame(handle, deadline: float) -> dict:
    data = bytearray()
    operation = pywintypes.OVERLAPPED()
    operation.hEvent = win32event.CreateEvent(None, True, False, None)
    try:
        buffer = win32file.AllocateReadBuffer(64 * 1024)
        while time.monotonic() < deadline:
            win32event.ResetEvent(operation.hEvent)
            code, _ = win32file.ReadFile(handle, buffer, operation)
            count = _wait_io(handle, operation, code, deadline)
            if not count:
                raise ValueError("Empty reply from Altium SDK pipe")
            data.extend(buffer[:count])
            if len(data) > MAX_RESPONSE:
                raise ValueError("Altium SDK pipe reply exceeded the frame limit")
            separator = data.find(b"\n", len(data) - count)
            if separator != -1:
                if separator != len(data) - 1:
                    raise ValueError("Unexpected data after Altium SDK pipe reply")
                return json.loads(data)
        raise TimeoutError("Altium SDK pipe deadline expired")
    finally:
        operation.hEvent.Close()


def _write_frame(handle, frame: bytes, deadline: float) -> None:
    operation = pywintypes.OVERLAPPED()
    operation.hEvent = win32event.CreateEvent(None, True, False, None)
    try:
        code, _ = win32file.WriteFile(handle, frame, operation)
        if _wait_io(handle, operation, code, deadline) != len(frame):
            raise OSError("Incomplete request to Altium SDK pipe")
    finally:
        operation.hEvent.Close()


def _exchange(pid: int, request: dict, timeout: float, before_send=None) -> tuple[str, dict] | None:
    try:
        frame = json.dumps(request, ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
    except (TypeError, ValueError, UnicodeError):
        return None
    if len(frame) > MAX_REQUEST:
        return None
    try:
        handle = win32file.CreateFile(
            rf"\\.\pipe\altium-mcp-sdk-{pid}",
            win32file.GENERIC_READ | win32file.GENERIC_WRITE,
            0, None, win32file.OPEN_EXISTING,
            win32file.FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT
            | win32file.SECURITY_IDENTIFICATION, None,
        )
    except pywintypes.error:
        return None
    try:
        try:
            if win32pipe.GetNamedPipeServerProcessId(handle) != pid:
                return None
        except pywintypes.error:
            return None
        if before_send:
            before_send()
        deadline = time.monotonic() + timeout
        try:
            _write_frame(handle, frame, deadline)
            reply = _read_frame(handle, deadline)
            if (
                not isinstance(reply, dict)
                or type(reply.get("protocol")) is not int or reply["protocol"] != PROTOCOL
                or reply.get("request_id") != request["request_id"]
                or reply.get("state") not in ("terminal", "not_started")
                or not isinstance(reply.get("result"), dict)
                or type(reply["result"].get("success")) is not bool
            ):
                raise ValueError("Uncorrelated or invalid Altium SDK pipe reply")
            result = reply["result"]
            if reply["state"] == "not_started" and (
                result["success"] or result.get("execution_state") not in (None, "not_started")
            ):
                raise ValueError("Contradictory Altium SDK refusal")
            return reply["state"], result
        except (pywintypes.error, OSError, ValueError) as error:
            raise ManagedOutcomeUnknown(str(error)) from error
    finally:
        handle.Close()


def _request(command: str, request_id: str, params: dict, instance_id: str | None = None) -> dict:
    request = {"protocol": PROTOCOL, "request_id": request_id, "command": command, "params": params}
    if instance_id is not None:
        request["instance_id"] = instance_id
    return request


def _same_executable(pid: int, executable: str) -> bool:
    actual = win_processes.image_path(pid)
    return bool(actual and os.path.normcase(os.path.realpath(actual)) ==
                os.path.normcase(os.path.realpath(executable)))


class ManagedAltium:
    """Discover and call the extension when a single configured editor is running."""

    def __init__(self):
        self._probe_target = None
        self._probe_deadline = 0.0
        self._endpoint = None

    @staticmethod
    def _probe(pid: int) -> ManagedEndpoint | None:
        try:
            reply = _exchange(pid, _request("hello", uuid.uuid4().hex, {}), PROBE_TIMEOUT)
        except (OSError, ValueError):
            return None
        if reply is None or reply[0] != "terminal":
            return None
        _, result = reply
        commands = result.get("commands")
        instance = result.get("instance_id")
        build = result.get("build")
        if (not result["success"] or result.get("pid") != pid
                or not isinstance(instance, str) or not re.fullmatch(r"[0-9a-f]{32}", instance)
                or not isinstance(build, str) or not build
                or not isinstance(commands, list) or not all(isinstance(c, str) for c in commands)):
            return None
        return ManagedEndpoint(pid, instance, build, str(result.get("version") or ""), frozenset(commands))

    def _find_endpoint(self, executable: str) -> ManagedEndpoint | None:
        try:
            pids = win_processes.pids_by_name("X2.EXE")
            if len(pids) != 1 or not _same_executable(pids[0], executable):
                return None
        except OSError:
            return None
        target = executable, pids[0]
        if target != self._probe_target or time.monotonic() >= self._probe_deadline:
            self._endpoint = self._probe(pids[0])
            self._probe_target = target
            self._probe_deadline = time.monotonic() + (5 if self._endpoint else 1)
        return self._endpoint

    async def endpoint(self, executable: str) -> ManagedEndpoint | None:
        return await asyncio.to_thread(self._find_endpoint, executable)

    async def execute(self, endpoint: ManagedEndpoint, request_id: str, command: str, params: dict,
                      timeout: float, before_send) -> tuple[str, dict] | None:
        return await asyncio.to_thread(
            _exchange, endpoint.pid, _request(command, request_id, params, endpoint.instance_id),
            timeout, before_send,
        )

    async def response(self, executable: str, receipt: dict) -> dict | None:
        pid, instance = receipt.get("pid"), receipt.get("instance_id")
        if type(pid) is not int or not isinstance(instance, str):
            return None
        try:
            if not await asyncio.to_thread(_same_executable, pid, executable):
                return None
            reply = await asyncio.to_thread(
                _exchange, pid, _request("status", uuid.uuid4().hex,
                                        {"target_request_id": receipt["request_id"]}, instance),
                PROBE_TIMEOUT,
            )
        except (OSError, ValueError):
            return None
        if reply is None or reply[0] != "terminal":
            return None
        _, status = reply
        result = status.get("result")
        if (status.get("success") and status.get("pid") == pid and status.get("instance_id") == instance
                and status.get("status") == "terminal" and isinstance(result, dict)
                and type(result.get("success")) is bool and result.get("execution_state") != "unknown"):
            return {**result, "request_id": receipt["request_id"]}
        return None
