"""Persist and reconcile the in-flight receipt for the Altium file bridge."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from .altium_files import read_altium_text


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8-sig", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


@dataclass(frozen=True)
class ResidentSession:
    """A leased native run with a request path unique to that run."""

    directory: Path
    bundle_key: str
    token: str
    executable: str

    @classmethod
    def load(cls, directory: Path) -> ResidentSession | None:
        try:
            ticket = json.loads((directory / "bridge-resident.json").read_text(encoding="utf-8-sig"))
        except (FileNotFoundError, ValueError):
            return None
        if isinstance(ticket, dict):
            key, token, exe = (ticket.get(name) for name in ("bundle_key", "token", "executable"))
            if (isinstance(key, str) and re.fullmatch(r"[0-9a-f]{12}", key)
                    and isinstance(token, str) and re.fullmatch(r"[0-9a-f]{32}", token)
                    and isinstance(exe, str) and exe):
                return cls(directory, key, token, exe)
        return None

    @classmethod
    def start(cls, directory: Path, bundle_key: str, executable: str) -> ResidentSession:
        session = cls(directory, bundle_key, uuid4().hex, executable)
        session.lease.touch()
        try:
            atomic_json(directory / "bridge-resident.json", {
                "bundle_key": bundle_key, "token": session.token, "executable": executable,
            })
        except OSError:
            session.lease.unlink(missing_ok=True)
            raise
        return session

    def _path(self, extension: str) -> Path:
        return self.directory / f"bridge-resident-{self.token}.{extension}"

    @property
    def lease(self) -> Path:
        return self._path("lease")

    @property
    def ready(self) -> Path:
        return self._path("ready")

    @property
    def settling(self) -> Path:
        return self._path("settling")

    @property
    def request(self) -> Path:
        return self._path("request.json")


class PendingCommand:
    """Track commands that may still be executing after a timeout or restart."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.path = directory / "pending-command.json"

    def load(self) -> dict | None:
        try:
            receipt = json.loads(self.path.read_text(encoding="utf-8-sig"))
        except FileNotFoundError:
            return None
        request_id = receipt.get("request_id") if isinstance(receipt, dict) else None
        if not isinstance(request_id, str) or not re.fullmatch(r"[0-9a-f]{32}", request_id):
            raise ValueError(f"Invalid Altium command receipt: {self.path}")
        return receipt

    def write(self, receipt: dict) -> None:
        atomic_json(self.path, receipt)

    def archive(self, receipt: dict, response: dict | None = None) -> None:
        request_id = receipt["request_id"]
        if response is not None:
            atomic_json(self.directory / f"response-{request_id}.json", response)
        self.path.replace(self.directory / f"completed-{request_id}.json")

    def discard(self) -> None:
        self.path.unlink(missing_ok=True)

    def response(self, request_id: str, *, legacy: bool = False) -> dict | None:
        paths = [self.directory / "response.json"]
        if legacy:
            paths.append(self.directory / f"response-{request_id}.json")
        for path in paths:
            try:
                value = json.loads(read_altium_text(path), strict=False)
            except (OSError, UnicodeError, json.JSONDecodeError):
                continue
            if (
                isinstance(value, dict)
                and isinstance(value.get("success"), bool)
                and value.get("request_id") == request_id
            ):
                return value
        return None

    def status(self) -> dict:
        receipt = self.load()
        if receipt is None:
            return {"pending": False}
        return {
            **receipt,
            "pending": True,
            "terminal_response_available": self.response(receipt["request_id"], legacy=True) is not None,
        }
