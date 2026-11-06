"""Foreground, bounded gateway supervision for a newly created isolated profile.

Run with the prepared Agent's Python. No service/task installation or forced running-child stop.
"""
import argparse
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

import psutil

MAX_STARTS = 4
WINDOW_SECONDS = 900
RETRY_SECONDS = 3
STOP_SECONDS = 180
TERMINAL = {"stopped", "fatal_configuration", "retry_exhausted"}


class _JobAccounting(ctypes.Structure):
    _fields_ = [(name, ctypes.c_longlong) for name in (
        "totalUserTime", "totalKernelTime", "periodUserTime", "periodKernelTime"
    )] + [(name, wintypes.DWORD) for name in (
        "pageFaults", "totalProcesses", "activeProcesses", "terminatedProcesses"
    )]


class ProcessJob:
    """Kernel exit barrier, without kill-on-close or breakaway permissions."""

    def __init__(self):
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self._create = kernel.CreateJobObjectW
        self._create.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self._create.restype = wintypes.HANDLE
        self._assign = kernel.AssignProcessToJobObject
        self._assign.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self._assign.restype = wintypes.BOOL
        self._query = kernel.QueryInformationJobObject
        self._query.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                               wintypes.DWORD, ctypes.c_void_p]
        self._query.restype = wintypes.BOOL
        self._close = kernel.CloseHandle
        self._close.argtypes = [wintypes.HANDLE]
        self._close.restype = wintypes.BOOL
        self._resume = ctypes.WinDLL("ntdll").NtResumeProcess
        self._resume.argtypes = [wintypes.HANDLE]
        self._resume.restype = wintypes.LONG
        self.handle = self._create(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())

    def start(self, command, **kwargs):
        # Bind before any child code can spawn an unobserved descendant.
        child = subprocess.Popen(command, creationflags=subprocess.CREATE_NO_WINDOW | 0x4, **kwargs)
        try:
            if not self._assign(self.handle, int(child._handle)):
                raise ctypes.WinError(ctypes.get_last_error())
            status = self._resume(int(child._handle))
            if status < 0:
                raise OSError(f"NtResumeProcess failed: 0x{status & 0xffffffff:08x}")
        except Exception:
            # Only this never-started suspended child may be discarded; use its original handle.
            child.kill()
            child.wait(timeout=10)
            raise
        return child

    def active_count(self):
        info = _JobAccounting()
        if not self._query(self.handle, 1, ctypes.byref(info), ctypes.sizeof(info), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return info.activeProcesses

    def close(self):
        if self.handle:
            if not self._close(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("x", encoding="utf-8") as f:
            json.dump(value, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


@contextmanager
def ownership(home):
    with (home / ".devspace-gateway.lock").open("a+b") as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError("Another supervisor owns this profile") from exc
        try:
            yield
        finally:
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def prepared_runtime(prepared):
    prepared = prepared.resolve(strict=True)
    receipt = read(prepared / "preparation.json")
    root = prepared / "payload"
    python = prepared / "runtime" / "Scripts" / "python.exe"
    if receipt["state"] != "prepared" or Path(receipt["python"]).resolve() != python:
        raise ValueError("A completed PM preparation receipt is required")
    if not os.path.samefile(sys.executable, python):
        raise ValueError("Use this prepared runtime's Python interpreter")
    for name in ("pyproject.toml", "uv.lock", "pm/lock.json"):
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != receipt["inputHashes"][name]:
            raise ValueError("Prepared dependency inputs changed")
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"],
                                   text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip()
    dirty = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"],
                                    text=True, creationflags=subprocess.CREATE_NO_WINDOW).strip()
    if head != receipt["revision"] or dirty:
        raise ValueError("Prepared source changed")
    return root, python


def isolated_environment(home):
    env = {k: v for k, v in os.environ.items()
           if k.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT"}}
    for key in ("HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "HERMES_HOME",
                "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TEMP", "TMP"):
        env[key] = str(home)
    env.update(HERMES_DISABLE_LAZY_INSTALLS="1", HERMES_GATEWAY_EXTERNAL_SUPERVISOR="1",
               GATEWAY_MULTIPLEX_PROFILES="false", PYTHONUTF8="1")
    return env


def supervise(home, state, gateway, command, env):
    """Only own children may receive the official graceful-stop marker."""
    state_path = home / ".devspace-gateway.json"
    control_path = home / ".devspace-gateway-stop.json"
    known = {}
    child = None
    job = None

    def save(phase, **details):
        state.update(phase=phase, updatedAt=datetime.now(timezone.utc).isoformat(), **details)
        write(state_path, state)

    def live_children():
        return [{"pid": pid, "startTime": started} for (pid, started), p in known.items() if p.is_running()]

    def identity():
        return gateway.get_running_pid_identity_strict(home / "gateway.pid")

    if state["phase"] not in TERMINAL:
        raise RuntimeError("Previous supervisor did not finish; preserve it for inspection")
    if identity() is not None:
        raise RuntimeError("An existing gateway owns this profile")
    state.update(runId=uuid.uuid4().hex, supervisor={"pid": os.getpid(), "startTime": psutil.Process().create_time()})
    try:
        job = ProcessJob()
        control_path.unlink(missing_ok=True)
        while True:
            if control_path.exists() and read(control_path).get("runId") == state["runId"]:
                save("stopped")
                return 0
            state["starts"] = [t for t in state["starts"] if time.time() - t < WINDOW_SECONDS]
            if len(state["starts"]) >= MAX_STARTS:
                save("retry_exhausted")
                return 1
            state["starts"].append(time.time())
            # Persist intent before spawn: a manager crash must never authorize a second owner.
            save("starting", child=None, gateway=None, stopMarkerSent=False, error=None,
                 survivingChildren=[], jobActiveProcesses=None)
            with (home / "supervised-gateway.log").open("a", encoding="utf-8") as log:
                child = job.start(command, cwd=home, env=env, stdin=subprocess.DEVNULL,
                                  stdout=log, stderr=subprocess.STDOUT)
                process = None
                try:
                    process = psutil.Process(child.pid)
                    known[(process.pid, process.create_time())] = process
                    save("starting", child={"pid": process.pid, "startTime": process.create_time()})
                except psutil.NoSuchProcess:
                    if child.poll() is None:
                        raise
                stopping_at = None
                while child.poll() is None:
                    # Polling supplies identity diagnostics; job accounting proves ordinary descendants exited.
                    try:
                        descendants = process.children(recursive=True)
                    except psutil.NoSuchProcess:
                        if child.poll() is None:
                            raise
                        break
                    for descendant in descendants:
                        try:
                            known[(descendant.pid, descendant.create_time())] = descendant
                        except psutil.NoSuchProcess:
                            pass
                    current = identity()
                    if current:
                        if current not in known or not known[current].is_running():
                            raise RuntimeError("Gateway identity is outside the owned child tree")
                        phase = "stopping" if stopping_at else "running"
                        record = {"pid": current[0], "startTime": current[1]}
                        if state["phase"] != phase or state.get("gateway") != record:
                            save(phase, gateway=record)
                    if control_path.exists() and read(control_path).get("runId") == state["runId"]:
                        if stopping_at is None:
                            stopping_at = time.monotonic()
                            save("stopping")
                        if current and not state.get("stopMarkerSent"):
                            if not gateway.write_planned_stop_marker(current[0]):
                                raise RuntimeError("Graceful stop marker could not be written")
                            save("stopping", stopMarkerSent=True)
                    if stopping_at and time.monotonic() - stopping_at > STOP_SECONDS:
                        raise RuntimeError("Graceful stop timed out; child preserved")
                    time.sleep(0.5)
                code = child.wait()
            # The venv launcher may have exited while its worker or descendants remain alive.
            survivors = live_children()
            active = job.active_count()
            if survivors or active:
                save("waiting_descendants", exitCode=code, jobActiveProcesses=active)
                remaining = STOP_SECONDS if stopping_at is None else max(
                    0, STOP_SECONDS - (time.monotonic() - stopping_at))
                deadline = time.monotonic() + remaining
                if survivors:
                    psutil.wait_procs([known[(p["pid"], p["startTime"])] for p in survivors], timeout=remaining)
                active = job.active_count()
                while active and time.monotonic() < deadline:
                    time.sleep(min(.1, max(0, deadline - time.monotonic())))
                    active = job.active_count()
                survivors = live_children()
            state["jobActiveProcesses"] = active
            if survivors or active or identity() is not None:
                raise RuntimeError(f"Child exited with surviving processes; preserved: {survivors}; job active: {active}")
            known.clear()
            save("exited", exitCode=code, child=None, gateway=None)
            if stopping_at or code == 0:
                save("stopped")
                return 0
            if code == 78:
                save("fatal_configuration")
                return 78
            # 75 is an explicit handoff; other nonzero exits are crashes. Both consume the budget.
            save("retry_wait")
            deadline = time.monotonic() + RETRY_SECONDS
            while time.monotonic() < deadline:
                if control_path.exists() and read(control_path).get("runId") == state["runId"]:
                    save("stopped")
                    return 0
                time.sleep(0.1)
    except Exception as exc:
        save("attention_required", error=str(exc), survivingChildren=live_children())
        raise
    finally:
        if job is not None:
            job.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "run", "stop", "status"))
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--prepared", type=Path)
    args = parser.parse_args()
    home = args.home.resolve()
    path = home / ".devspace-gateway.json"
    if args.action == "init":
        if not args.prepared:
            parser.error("init requires --prepared")
        prepared_runtime(args.prepared)
        home.mkdir()  # Never adopt an existing user profile, even an empty directory.
        write(path, {"schema": 1, "home": str(home), "prepared": str(args.prepared.resolve()),
                     "phase": "stopped", "starts": []})
        return 0
    state = read(path)
    if state["schema"] != 1 or state["home"] != str(home):
        raise ValueError("Profile ownership record mismatch")
    if args.action == "status":
        print(json.dumps(state, indent=2))
        return 0
    if args.action == "stop":
        if state["phase"] in TERMINAL:
            return 0
        owner = state["supervisor"]
        p = psutil.Process(owner["pid"])
        if p.create_time() != owner["startTime"] or not p.is_running():
            raise RuntimeError("Supervisor identity changed; no stop request sent")
        write(home / ".devspace-gateway-stop.json", {"runId": state["runId"]})
        return 0
    root, python = prepared_runtime(Path(state["prepared"]))
    env = isolated_environment(home)
    os.environ.clear()
    os.environ.update(env)
    sys.path.insert(0, str(root))
    from gateway import status
    from hermes_cli._launchers import runtime_command
    # The official launcher also supplies the command shape used by strict identity checks.
    command = runtime_command(root, ["gateway", "run", "--external-supervisor"],
                              python=python, home=home)
    with ownership(home):
        # Re-read after obtaining the lock so a racing invocation cannot overwrite another owner.
        return supervise(home, read(path), status, command, env)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
