"""Serialized, correlated file exchange with the single Altium script writer."""

from __future__ import annotations

import asyncio
import json
import os
import time
import uuid
from pathlib import Path


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8-sig", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


class FileCommandTransport:
    """A timeout is unresolved execution, never permission to repeat a mutation.

    The OS lock also serializes separate MCP server processes. A pending receipt
    survives a server restart and blocks replacement of a request whose script
    may still execute. A correlated terminal response releases that receipt.
    """

    def __init__(
        self,
        directory: Path,
        launch,
        timeout: float = 120,
        poll: float = 0.1,
        mutation_timeout: float | None = None,
        native_drc_timeout: float | None = None,
    ):
        self.directory = Path(directory)
        self.launch = launch
        self.timeout = timeout
        self.poll = poll
        self.mutation_timeout = mutation_timeout
        self.native_drc_timeout = native_drc_timeout
        self._lock = asyncio.Lock()
        self._tasks = set()

    def status(self) -> dict:
        pending = self.directory / "pending-command.json"
        if not pending.exists():
            return {"pending": False}
        receipt = json.loads(pending.read_text(encoding="utf-8-sig"))
        response = self._response(receipt["request_id"])
        return {
            "pending": True,
            **receipt,
            "terminal_response_available": response is not None,
        }

    def _response(self, request_id: str):
        path = self.directory / f"response-{request_id}.json"
        if not path.exists():
            return None
        try:
            value = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            return None  # A partial write is not a terminal response.
        if (
            not isinstance(value, dict)
            or not isinstance(value.get("success"), bool)
            or value.get("request_id") != request_id
        ):
            return None
        return value

    async def execute(self, command: str, params: dict) -> dict:
        # Caller cancellation must not release the single-writer lock early.
        task = asyncio.create_task(self._execute(command, params))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            task.add_done_callback(
                lambda done: done.exception() if not done.cancelled() else None
            )
            raise

    async def _execute(self, command: str, params: dict) -> dict:
        async with self._lock:
            self.directory.mkdir(parents=True, exist_ok=True)
            with (self.directory / "command.lock").open("a+b") as handle:
                handle.seek(0, 2)
                if handle.tell() == 0:
                    handle.write(b"\0")
                    handle.flush()
                deadline = time.monotonic() + self.timeout
                while True:
                    try:
                        self._os_lock(handle, True)
                        break
                    except OSError:
                        if time.monotonic() >= deadline:
                            return {
                                "success": False,
                                "error": "Altium command channel is busy",
                            }
                        await asyncio.sleep(self.poll)
                try:
                    return await self._exchange(command, params)
                except (OSError, ValueError) as error:
                    return {
                        "success": False,
                        "error": str(error),
                        "execution_state": "inspect_pending_receipt",
                    }
                finally:
                    self._os_lock(handle, False)

    @staticmethod
    def _os_lock(handle, acquire: bool) -> None:
        handle.seek(0)
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(
                handle.fileno(), msvcrt.LK_NBLCK if acquire else msvcrt.LK_UNLCK, 1
            )
        else:
            import fcntl

            fcntl.flock(
                handle, fcntl.LOCK_EX | fcntl.LOCK_NB if acquire else fcntl.LOCK_UN
            )

    async def _exchange(self, command: str, params: dict) -> dict:
        pending = self.directory / "pending-command.json"
        if pending.exists():
            receipt = json.loads(pending.read_text(encoding="utf-8-sig"))
            terminal = self._response(receipt["request_id"])
            if terminal is None:
                return {
                    "success": False,
                    "error": "Previous Altium command is unresolved; inspect its status before retrying",
                    "execution_state": "unknown",
                    "pending_command": receipt,
                }
            # Preserve the old receipt/response for recovery and inspection.
            os.replace(
                pending, self.directory / f"completed-{receipt['request_id']}.json"
            )
        if "request_id" in params or "command" in params:
            raise ValueError("Reserved transport fields cannot be overridden")
        request_id = uuid.uuid4().hex
        receipt = {
            "request_id": request_id,
            "command": command,
            "created_unix": time.time(),
            "operation_directory": params.get("operation_directory"),
        }
        atomic_json(pending, receipt)
        atomic_json(
            self.directory / "request.json",
            {"request_id": request_id, "command": command, **params},
        )
        if not await self.launch():
            pending.unlink()
            return {
                "success": False,
                "error": "Failed to launch Altium script",
                "request_id": request_id,
            }
        timeout = self.timeout
        if (
            command == "pcb_routing"
            and params.get("operation") in {"batch", "polygon", "repour", "undo"}
            and self.mutation_timeout is not None
        ):
            timeout = max(timeout, self.mutation_timeout)
        if (
            command == "pcb_routing"
            and params.get("operation") == "native_drc"
            and self.native_drc_timeout is not None
        ):
            timeout = max(timeout, self.native_drc_timeout)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self._response(request_id)
            if response is not None:
                os.replace(pending, self.directory / f"completed-{request_id}.json")
                return response
            await asyncio.sleep(self.poll)
        return {
            "success": False,
            "error": "Altium response timed out; execution may have partially completed",
            "request_id": request_id,
            "execution_state": "unknown",
            "pending_command": receipt,
        }
