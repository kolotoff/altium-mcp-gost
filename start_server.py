"""Bootstrap for the Altium MCP extension.

Two roles in one file:

  python start_server.py           the LAUNCHER Claude Desktop runs. Makes
                                   sure a ready venv exists, then execs
                                   server/main.py inside it.
  python start_server.py --build   the BUILDER. Creates the venv and installs
                                   the pinned requirements, then exits.

The builder is a separate, DETACHED process on purpose. Claude Desktop gives
a server about 60 s to answer `initialize` and then kills it, and it also
restarts servers freely (extension install, app update, new session). A pip
install that runs inside the launcher dies with it, leaving a half-built venv
and a lock nobody will release. A detached builder finishes regardless, so a
restarted launcher finds the venv ready or a build genuinely in progress.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent

# The hash-locked set exported by uv. Installed when present, so no
# dependency of mcp floats to a release it was never tested with (pydantic
# 2.14 breaking mcp 1.5.0 at import was one).
LOCKED_REQUIREMENTS = SCRIPT_DIR / "requirements.txt"

# Fallback when the lock file is missing, or pins wheels the interpreter has
# none for (a newer Python than the lock was made with).
REQUIREMENTS = [
    # mcp declares the pydantic range it supports (per Python version), so
    # pydantic needs no entry of its own here
    "mcp[cli]==1.30.0",
    "pillow>=11.1.0",
    "python-docx>=1.1.2",
    "pywin32>=310",
]


def _locked_text():
    try:
        return LOCKED_REQUIREMENTS.read_text(encoding="utf-8")
    except OSError:
        return ""


def _marker_payload():
    # Both inputs, so a change to either the lock file or the fallback list
    # invalidates the venv. Not which one was installed: that is decided at
    # build time and must not make a ready venv look stale.
    return "\n".join(REQUIREMENTS) + "\n--locked--\n" + _locked_text()


def _data_dir():
    # Per-user and OUTSIDE both the extension folder and AppData. Claude
    # Desktop replaces the extension folder on every update, which used to
    # throw the venv away and put the slow first build back inside the
    # client's startup timeout. AppData is out because Claude Desktop is an
    # MSIX package: writes its child processes make under AppData are
    # redirected into the package's LocalCache, so a venv built from a normal
    # terminal and one built by the server would be in different places.
    # The profile root is not redirected. ALTIUM_MCP_HOME overrides this.
    override = os.environ.get("ALTIUM_MCP_HOME")
    if override:
        return Path(override)
    return Path.home() / ".altium-mcp"


def _venv_key():
    # One venv per (requirements, interpreter version). Changing either gets a
    # fresh directory instead of mutating one another process may be using.
    text = _marker_payload() + "|py%d.%d" % sys.version_info[:2]
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


DATA_DIR = _data_dir()
VENVS_DIR = DATA_DIR / "venvs"
VENV_DIR = VENVS_DIR / _venv_key()
PYTHON_EXE = VENV_DIR / "Scripts" / "python.exe"
MARKER = VENV_DIR / ".requirements-installed"
BUILD_LOG = DATA_DIR / "build.log"

# How long the launcher waits for the venv before giving up on THIS start.
# Just under Claude Desktop's ~60 s initialize timeout, so the launcher gets
# to say why it is exiting instead of being killed mid-sentence.
LAUNCH_WAIT_SECONDS = 50
LEGACY_LOCK_MAX_AGE = 1800
# A venv another launch has not used for this long, and that nothing runs
# from, is deleted after a build (see _prune_old_venvs)
KEEP_UNUSED_DAYS = 14


def venv_is_ready():
    # python.exe alone is not enough: `python -m venv` can succeed and the pip
    # install still fail, leaving an interpreter with no mcp module. The marker
    # is written last and records what was installed, so a change to
    # the requirements also invalidates it.
    if not PYTHON_EXE.exists():
        return False
    try:
        return MARKER.read_text(encoding="utf-8") == _marker_payload()
    except OSError:
        return False


def _manual_build_message(reason):
    command = subprocess.list2cmdline([sys.executable, str(Path(__file__).resolve()), "--build"])
    return (
        "%s\n\n"
        "Build log: %s\n"
        "Run the builder directly in Command Prompt to build and mark the "
        "environment ready outside the client's startup timeout.\n"
        "  %s"
        % (reason, BUILD_LOG, command)
    )


# --- lock -------------------------------------------------------------------

def _pid_alive(pid):
    if pid <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    import ctypes
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def _legacy_builder_alive(venv_name):
    """Keep environments from the previous PID-based builder while it runs."""
    path = VENVS_DIR / (venv_name + ".lock")
    try:
        age = time.time() - path.stat().st_mtime
        pid = int(path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return False
    return age < LEGACY_LOCK_MAX_AGE and _pid_alive(pid)


@contextmanager
def _build_guard(venv_name, *, create=True):
    """Hold a stable OS lock until the file closes or the process exits."""
    path = VENVS_DIR / (venv_name + ".build-lock")
    if create:
        VENVS_DIR.mkdir(parents=True, exist_ok=True)
    try:
        lock = path.open("a+b" if create else "r+b")
    except FileNotFoundError:
        if create:
            raise
        yield True
        return
    with lock:
        try:
            if os.name == "nt":
                import msvcrt
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
        else:
            yield True


# --- builder ----------------------------------------------------------------

def _build_venv():
    # An existing tree here is a partial build or one whose requirements moved.
    # Either way it cannot be trusted. Removing it first is what stops
    # `python -m venv` failing with WinError 183 on a half-created directory.
    if VENV_DIR.exists():
        shutil.rmtree(VENV_DIR, ignore_errors=True)
        if VENV_DIR.exists():
            raise RuntimeError(
                "Could not remove the existing virtual environment at %s. "
                "Something is holding it open." % VENV_DIR
            )
    subprocess.check_call([sys.executable, "-m", "venv", str(VENV_DIR)])
    pip = [str(VENV_DIR / "Scripts" / "pip.exe"), "install", "--quiet"]
    installed = False
    if _locked_text():
        # Hashes in the file put pip in hash-checking mode for every package.
        try:
            subprocess.check_call(pip + ["-r", str(LOCKED_REQUIREMENTS)])
            installed = True
        except subprocess.CalledProcessError as exc:
            print("locked install failed (%s); falling back to %s" % (exc, REQUIREMENTS))
    if not installed:
        subprocess.check_call(pip + REQUIREMENTS)
    MARKER.write_text(_marker_payload(), encoding="utf-8")
    _prune_old_venvs()


def _venvs_in_use():
    """Names of the venvs under VENVS_DIR a running process was started from.

    A venv's Scripts\\python.exe stays alive as long as the server it started,
    so a running server shows up here. None when the process list cannot be
    read: then nothing counts as unused.
    """
    if os.name != "nt":
        return None
    import ctypes
    from ctypes import wintypes
    try:
        psapi, kernel32 = ctypes.WinDLL("psapi"), ctypes.WinDLL("kernel32")
        pids = (wintypes.DWORD * 4096)()
        needed = wintypes.DWORD()
        if not psapi.EnumProcesses(pids, ctypes.sizeof(pids), ctypes.byref(needed)):
            return None
        def long_form(path):
            # A process reports its image path in the form it was started
            # with, and the folder may be given in either: compare the long
            # forms of both, not 8.3 short names (C:\Users\SIBOVA~1\...)
            buf = ctypes.create_unicode_buffer(32768)
            n = kernel32.GetLongPathNameW(path, buf, len(buf))
            return os.path.normcase(buf.value if 0 < n < len(buf) else path)

        root = long_form(str(VENVS_DIR)) + os.sep
        names = set()
        for pid in pids[:needed.value // ctypes.sizeof(wintypes.DWORD)]:
            handle = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
            if not handle:
                continue
            try:
                buf = ctypes.create_unicode_buffer(32768)
                size = wintypes.DWORD(len(buf))
                if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                    path = long_form(buf.value)
                    if path.startswith(root):
                        names.add(path[len(root):].split(os.sep)[0])
            finally:
                kernel32.CloseHandle(handle)
        return names
    except (OSError, AttributeError):
        return None


def _prune_old_venvs():
    # Venvs keyed to another requirement list or interpreter. Deleting one a
    # server still runs from removes every file that is not locked, and the
    # server then fails on whatever it imports next (a screenshot's PNG
    # encoder, say); its next launch cannot rebuild it either, as the locked
    # files stay. So a venv is kept while a process runs from it, while
    # another builder is building it, and for KEEP_UNUSED_DAYS after its
    # last launch: two clients may launch with different interpreters (Claude
    # Desktop and Claude Code, or "py" with and without PY_PYTHON), and each
    # keeps its venv instead of rebuilding it every time the other ran.
    in_use = _venvs_in_use()
    if in_use is None:
        return
    cutoff = time.time() - KEEP_UNUSED_DAYS * 86400
    for child in VENVS_DIR.iterdir():
        if not child.is_dir() or child == VENV_DIR:
            continue
        if child.name.endswith(".trash"):
            shutil.rmtree(child, ignore_errors=True)
            continue
        if child.name in in_use:
            continue
        with _build_guard(child.name) as acquired:
            if not acquired or _legacy_builder_alive(child.name):
                continue
            try:
                last_used = (child / MARKER.name).stat().st_mtime
            except OSError:
                last_used = 0  # never finished building
            if last_used > cutoff:
                continue
            # Renamed first, so a delete that stops half way never leaves a
            # broken venv under a name a launcher would pick up
            trash = child.with_name(child.name + ".trash")
            try:
                os.rename(child, trash)
            except OSError:
                continue
            shutil.rmtree(trash, ignore_errors=True)


def _builder_alive(venv_name):
    """True while a builder holds the lock for that venv."""
    with _build_guard(venv_name, create=False) as acquired:
        return not acquired or _legacy_builder_alive(venv_name)


def build_main():
    """Entry point of the detached builder process."""
    try:
        with _build_guard(VENV_DIR.name) as acquired:
            if not acquired or _legacy_builder_alive(VENV_DIR.name):
                print("another builder is running; nothing to do")
                return 0
            if venv_is_ready():
                return 0
            started = time.time()
            print("building %s" % VENV_DIR)
            _build_venv()
            print("ready in %.0f s" % (time.time() - started))
        return 0
    except Exception as exc:  # noqa: BLE001 - anything here must reach the log
        print("BUILD FAILED: %s" % exc)
        return 1
    finally:
        sys.stdout.flush()


def _spawn_builder():
    """Start the builder detached from this process, its console and its job."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(Path(__file__).resolve()), "--build"]
    log = open(BUILD_LOG, "a", encoding="utf-8", errors="replace")
    log.write("\n=== %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
    log.flush()
    kwargs = dict(stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                  close_fds=True)
    if os.name == "nt":
        # Give the builder and its children a windowless console of their own.
        # With DETACHED_PROCESS, venv or pip launchers can open a new console
        # when they start the actual interpreter.
        flags = (subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP
                 | subprocess.CREATE_BREAKAWAY_FROM_JOB)
        try:
            subprocess.Popen(cmd, creationflags=flags, **kwargs)
        except OSError:
            # Breakaway refused by the parent's job object; the builder can
            # still outlive the launcher, just not a job-wide kill.
            flags &= ~subprocess.CREATE_BREAKAWAY_FROM_JOB
            subprocess.Popen(cmd, creationflags=flags, **kwargs)
    else:
        subprocess.Popen(cmd, start_new_session=True, **kwargs)
    log.close()


def _build_log_tail(lines=12):
    try:
        return "\n".join(BUILD_LOG.read_text(encoding="utf-8", errors="replace")
                         .splitlines()[-lines:])
    except OSError:
        return "(no build log)"


# --- launcher ---------------------------------------------------------------

def _mark_used():
    # The marker's modification time is the venv's last launch, which keeps
    # it from being pruned while it is in use (see _prune_old_venvs)
    try:
        os.utime(MARKER)
    except OSError:
        pass


def ensure_venv():
    if venv_is_ready():
        _mark_used()
        return str(PYTHON_EXE)

    if not _builder_alive(VENV_DIR.name):
        _spawn_builder()

    started = time.time()
    seen_builder = False
    while time.time() - started < LAUNCH_WAIT_SECONDS:
        time.sleep(0.5)
        if venv_is_ready():
            _mark_used()
            return str(PYTHON_EXE)
        if _builder_alive(VENV_DIR.name):
            seen_builder = True
        elif seen_builder or time.time() - started > 5:
            # A builder ran (or never managed to start) and there is still no
            # marker: the build failed. Say so now rather than sit out the
            # deadline.
            raise RuntimeError(_manual_build_message(
                "Building the environment failed.\n%s" % _build_log_tail()))

    raise RuntimeError(_manual_build_message(
        "The virtual environment at %s is still being built (slow network?). "
        "The build continues in the background; restart the extension in a "
        "minute." % VENV_DIR))


if __name__ == "__main__":
    if "--build" in sys.argv[1:]:
        sys.exit(build_main())
    venv_python = ensure_venv()
    server_path = str(SCRIPT_DIR / "server" / "main.py")
    # main.py keeps config.json in the same per-user folder; hand it the
    # resolved location so the two can never disagree.
    env = dict(os.environ, ALTIUM_MCP_HOME=str(DATA_DIR))
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    # Pass the MCP client's pipes explicitly because the child has its own console.
    sys.exit(subprocess.call([venv_python, server_path], env=env, creationflags=flags,
                             stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr))
