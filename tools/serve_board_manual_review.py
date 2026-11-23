"""Run the offline board-manual review app with automatic workspace saving."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


DEFAULT_PORT = 8765
MAX_BODY = 2 * 1024 * 1024
STATE_PREFIX = "board-manual-review:v1:"
REVISION = re.compile(r"[a-f0-9]{64}")
AUTOSAVE_META = b'<meta name="review-autosave" content="off">'


def validate_key(key: str) -> None:
    if not key.startswith(STATE_PREFIX) or len(key) > 8192:
        raise ValueError("Invalid review key.")
    revisions = json.loads(key[len(STATE_PREFIX):])
    if not isinstance(revisions, list) or not 1 <= len(revisions) <= 60 or any(
        not isinstance(pair, list) or len(pair) != 2 or
        not isinstance(pair[0], str) or not REVISION.fullmatch(pair[0]) or pair[0] != pair[1]
        for pair in revisions
    ):
        raise ValueError("Invalid draft revisions.")


def validate_state(state: object) -> None:
    if not isinstance(state, dict) or not isinstance(state.get("units"), dict):
        raise ValueError("Invalid review state.")
    notes = state.get("notes")
    if not isinstance(notes, list) or any(
        not isinstance(note, dict) or any(
            not isinstance(note.get(field), str) for field in ("draft", "section", "text", "quote")
        )
        for note in notes
    ):
        raise ValueError("Invalid review notes.")


class ReviewStore:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()

    def _read(self) -> dict:
        if not self.path.exists():
            return {"format": 1, "reviews": {}}
        data = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("format") != 1 or not isinstance(data.get("reviews"), dict):
            raise ValueError("Invalid saved review file.")
        return data

    def _write(self, data: dict) -> None:
        fd, name = tempfile.mkstemp(dir=self.path.parent, prefix=".review-state-", suffix=".tmp")
        temporary = Path(name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
                json.dump(data, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(self.path)
        finally:
            temporary.unlink(missing_ok=True)

    def read(self, key: str) -> dict:
        with self.lock:
            return self._read()["reviews"].get(key, {"version": 0, "state": None})

    def initialize(self) -> None:
        with self.lock:
            data = self._read()
            if not self.path.exists():
                self._write(data)

    def save(self, key: str, version: int, state: dict) -> tuple[bool, dict]:
        with self.lock:
            data = self._read()
            current = data["reviews"].get(key, {"version": 0, "state": None})
            if current["state"] == state:
                return True, current
            if current["version"] != version:
                return False, current
            saved = {"version": version + 1, "state": state}
            data["reviews"][key] = saved
            self._write(data)
            return True, saved


def read_page(path: Path) -> bytes:
    content = path.read_bytes()
    if content.count(AUTOSAVE_META) != 1:
        raise ValueError("Regenerate this page with generate_board_manual_review.py before serving it.")
    return content.replace(AUTOSAVE_META, b'<meta name="review-autosave" content="on">')


class ReviewServer(ThreadingHTTPServer):
    def __init__(self, port: int, page: Path):
        read_page(page)
        self.page = page
        self.store = ReviewStore(page.with_name("review-state.json"))
        super().__init__(("127.0.0.1", port), ReviewHandler)
        try:
            self.store.initialize()
        except (OSError, ValueError):
            self.server_close()
            raise
        self.host_header = f"127.0.0.1:{self.server_port}"
        self.origin = f"http://{self.host_header}"


class ReviewHandler(BaseHTTPRequestHandler):
    server: ReviewServer

    def log_message(self, format: str, *args) -> None:
        return

    def respond(self, status: HTTPStatus, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def json_response(self, status: HTTPStatus, body: dict) -> None:
        self.respond(status, json.dumps(body, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def review_key(self) -> str:
        query = parse_qs(urlsplit(self.path).query, max_num_fields=4)
        key = query.get("review", [""])[0]
        validate_key(key)
        return key

    def do_GET(self) -> None:
        if self.headers.get("Host") != self.server.host_header:
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "Use the app's loopback address."})
            return
        path = urlsplit(self.path).path
        try:
            if path in ("/", "/index.html"):
                self.respond(HTTPStatus.OK, read_page(self.server.page), "text/html; charset=utf-8")
            elif path == "/api/review-state":
                key = self.review_key()
                self.json_response(HTTPStatus.OK, self.server.store.read(key))
            else:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Not found."})
        except (OSError, ValueError):
            self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Could not read this review."})

    def do_PUT(self) -> None:
        if self.headers.get("Host") != self.server.host_header or self.headers.get("Origin") != self.server.origin:
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "This app accepts writes from its own page only."})
            return
        if urlsplit(self.path).path != "/api/review-state":
            self.json_response(HTTPStatus.NOT_FOUND, {"error": "Not found."})
            return
        if self.headers.get_content_type() != "application/json":
            self.json_response(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "Use JSON."})
            return
        try:
            key = self.review_key()
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                self.json_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "Invalid review size."})
                return
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("Invalid save request.")
            version = payload.get("version")
            state = payload.get("state")
            if type(version) is not int or version < 0:
                raise ValueError("Invalid review version.")
            validate_state(state)
        except (ValueError, TypeError):
            self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Invalid save request."})
            return
        try:
            saved, current = self.server.store.save(key, version, state)
        except (OSError, ValueError):
            self.json_response(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "Could not save the workspace review."})
            return
        self.json_response(HTTPStatus.OK if saved else HTTPStatus.CONFLICT, current)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("page", type=Path, help="Existing review index.html generated from the Markdown drafts")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Loopback port (default: {DEFAULT_PORT})")
    parser.add_argument("--open", action="store_true", help="Open the app in the default browser")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    try:
        server = ReviewServer(args.port, args.page.resolve())
    except (OSError, ValueError) as error:
        parser.exit(1, f"Could not start the review app: {error}\n")
    with server:
        print(f"Review app: {server.origin}/", flush=True)
        print(f"Review state: {server.store.path}", flush=True)
        if args.open:
            webbrowser.open(f"{server.origin}/")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
