"""A lock shared by every server process that uses the exchange folder.

All servers write the same request.json and read the same response.json, so
two of them (two Claude sessions, or Claude Desktop and Claude Code) must
never have a command in flight at the same time: the second request would
overwrite the first before Altium reads it, and the first server would then
take the second one's reply for a stale one and delete it (issue #38).

The lock is a byte-range lock on a file in the exchange folder. Windows
releases it when the owning process exits, so a crashed or killed server
never leaves it held.
"""

import asyncio
import msvcrt
import time
from pathlib import Path


class ExchangeLock:
    def __init__(self, path: Path, *compatibility_paths: Path):
        self.paths = (path, *compatibility_paths)
        self._files = []

    def _try_lock(self, path: Path) -> bool:
        f = open(path, "a+b")
        try:
            # Older fork servers write the first byte before locking it. Set
            # it up before holding the range so they can reach their lock wait.
            f.seek(0, 2)
            if f.tell() == 0:
                f.write(b"\0")
                f.flush()
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            f.close()
            return False
        self._files.append(f)
        return True

    async def acquire(self, timeout: float, poll: float = 0.1) -> bool:
        """Wait up to `timeout` seconds for the lock; False if another server kept it."""
        deadline = time.monotonic() + timeout
        acquired = False
        try:
            for path in self.paths:
                while not self._try_lock(path):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return False
                    await asyncio.sleep(min(poll, remaining))
            acquired = True
            return True
        finally:
            if not acquired:
                self.release()

    def release(self) -> None:
        while self._files:
            f = self._files.pop()
            try:
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            except OSError:
                pass
            f.close()
