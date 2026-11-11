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
import re
import stat
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
SETTLED_UPDATES = {"accepted", "rolled_back"}


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


@contextmanager
def json_access(path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateMutexW
    create.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    create.restype = wintypes.HANDLE
    wait = kernel.WaitForSingleObject
    wait.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    wait.restype = wintypes.DWORD
    release = kernel.ReleaseMutex
    release.argtypes = [wintypes.HANDLE]
    release.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    # Resolving the target opens it on Windows; resolve only its parent before taking the lock.
    name = hashlib.sha256(str(path.parent.resolve() / path.name).casefold().encode("utf-8")).hexdigest()
    handle = create(None, False, "Global\\DevSpaceGatewayJson-" + name)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    acquired = False
    try:
        result = wait(handle, 5000)
        acquired = result in (0, 0x80)
        if result != 0:
            raise RuntimeError(f"JSON access lock unavailable or abandoned: {result}")
        yield
    finally:
        if acquired:
            release(handle)
        kernel.CloseHandle(handle)


def read(path):
    # Serialize readers and publishers across processes; an open Windows reader can prevent rename.
    with json_access(path):
        return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("x", encoding="utf-8") as f:
            json.dump(value, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        with json_access(path):
            os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def control_directory(home):
    return home.with_name("." + home.name + ".devspace-gateway")


@contextmanager
def ownership(home):
    control = plain_path(control_directory(home))
    # New profiles keep the lock outside the directory that an update exchanges.
    path = control / "owner.lock" if control.exists() else home / ".devspace-gateway.lock"
    with path.open("a+b") as lock:
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


def prepared_runtime(prepared, *, require_interpreter=True):
    prepared = prepared.resolve(strict=True)
    receipt = read(prepared / "preparation.json")
    root = prepared / "payload"
    python = prepared / "runtime" / "Scripts" / "python.exe"
    if receipt["state"] != "prepared" or Path(receipt["python"]).resolve() != python or not python.is_file():
        raise ValueError("A completed PM preparation receipt is required")
    if require_interpreter and not os.path.samefile(sys.executable, python):
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


def plain_path(path):
    path = path.absolute()
    if path.drive.startswith("\\\\"):
        raise ValueError("Profile transactions require a local volume")
    for part in (path, *path.parents):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError(f"Reparse point is not supported: {part}")
    return path


def profile_inventory(home):
    """Fingerprint all streams and security; never follow links into another profile."""
    class StreamData(ctypes.Structure):
        _fields_ = [("size", ctypes.c_longlong), ("name", wintypes.WCHAR * 296)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    first, following, close = kernel.FindFirstStreamW, kernel.FindNextStreamW, kernel.FindClose
    first.argtypes = [wintypes.LPCWSTR, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    first.restype = wintypes.HANDLE
    following.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
    following.restype = wintypes.BOOL
    close.argtypes = [wintypes.HANDLE]
    close.restype = wintypes.BOOL
    security = ctypes.WinDLL("advapi32", use_last_error=True)
    get = security.GetFileSecurityW
    get.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
                   ctypes.POINTER(wintypes.DWORD)]
    get.restype = wintypes.BOOL
    convert = security.ConvertSecurityDescriptorToStringSecurityDescriptorW
    convert.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                       ctypes.POINTER(wintypes.LPWSTR), ctypes.c_void_p]
    convert.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p

    result = {}
    pending = [plain_path(home)]
    while pending:
        path = pending.pop()
        info = path.lstat()
        if info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT or (path.is_file() and info.st_nlink != 1):
            raise ValueError(f"Linked profile entry is not supported: {path}")
        size = wintypes.DWORD()
        get(str(path), 7, None, 0, ctypes.byref(size))
        descriptor = ctypes.create_string_buffer(size.value)
        if not get(str(path), 7, descriptor, size, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        sddl = wintypes.LPWSTR()
        if not convert(descriptor, 1, 7, ctypes.byref(sddl), None):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            entry = {"security": sddl.value, "attributes": info.st_file_attributes,
                     "mtime": info.st_mtime_ns, "streams": {}}
        finally:
            kernel.LocalFree(sddl)
        data = StreamData()
        handle = first(str(path), 0, ctypes.byref(data), 0)
        if handle == wintypes.HANDLE(-1).value:
            if ctypes.get_last_error() != 38:  # ERROR_HANDLE_EOF: a directory without streams.
                raise ctypes.WinError(ctypes.get_last_error())
        else:
            try:
                while True:
                    with open(str(path) + data.name, "rb") as stream:
                        entry["streams"][data.name] = hashlib.file_digest(stream, "sha256").hexdigest()
                    if not following(handle, ctypes.byref(data)):
                        if ctypes.get_last_error() != 38:
                            raise ctypes.WinError(ctypes.get_last_error())
                        break
            finally:
                close(handle)
        result[str(path.relative_to(home))] = entry
        if path.is_dir():
            pending.extend(path.iterdir())
    return result


def stopped_profile(home, owner):
    state = read(home / ".devspace-gateway.json")
    if state.get("schema") != 2 or state.get("profileId") != owner["profileId"] or state.get("home") != str(home):
        raise ValueError("Profile transaction ownership mismatch")
    if state["phase"] not in TERMINAL or state.get("survivingChildren"):
        raise RuntimeError("Profile is not stopped; existing processes preserved")
    if state.get("runId") and state.get("jobActiveProcesses") != 0:
        raise RuntimeError("Previous process job has no verified empty exit barrier")
    for key in ("supervisor", "child", "gateway"):
        identity = state.get(key)
        if identity:
            try:
                p = psutil.Process(identity["pid"])
                if p.create_time() == identity["startTime"]:
                    try:
                        p.wait(timeout=0)
                    except psutil.TimeoutExpired as exc:
                        raise RuntimeError("Profile process is still alive; preserved") from exc
            except psutil.NoSuchProcess:
                pass
    if (home / "gateway.pid").exists():
        raise RuntimeError("Gateway PID record remains; no profile exchange authorized")
    return state


def profile_update(home, action, prepared):
    """Offline switch/rollback for new managed profiles; retain every prior directory."""
    plain_path(home)
    control = plain_path(control_directory(home))
    owner = read(control / "profile.json")
    if owner.get("home") != str(home) or not re.fullmatch(r"[0-9a-f]{32}", owner.get("profileId", "")):
        raise ValueError("Profile transaction owner is invalid")
    path = control / "update.json"
    with ownership(home), json_access(home / ".devspace-gateway.json"):
        previous = read(path) if path.exists() else None
        if action == "switch":
            if previous and previous["phase"] not in SETTLED_UPDATES:
                raise RuntimeError("Previous update requires accept or rollback")
            state = stopped_profile(home, owner)
            if prepared is None:
                raise ValueError("switch requires --prepared")
            prepared = prepared.resolve(strict=True)
            for runtime in (Path(state["prepared"]).resolve(strict=True), prepared):
                if runtime.is_relative_to(home) or home.is_relative_to(runtime):
                    raise ValueError("Prepared code and profile data must be separate")
                prepared_runtime(runtime, require_interpreter=False)
            if prepared == Path(state["prepared"]):
                raise ValueError("Candidate is already selected")
            before = profile_inventory(home)
            transaction = uuid.uuid4().hex
            folder = control / transaction
            folder.mkdir()
            record = {"id": transaction, "profileId": owner["profileId"], "home": str(home),
                      "phase": "copying", "oldPrepared": state["prepared"], "prepared": str(prepared)}
            write(folder / "before.json", before)
            write(path, record)
            next_home = folder / "next"
            with (folder / "copy.log").open("wb") as log:
                result = subprocess.run([str(Path(os.environ["SYSTEMROOT"]) / "System32" / "robocopy.exe"),
                                         str(home), str(next_home), "/E", "/COPY:DATS", "/DCOPY:DAT",
                                         "/XJ", "/R:0", "/W:0", "/NP"], stdout=log, stderr=subprocess.STDOUT,
                                        creationflags=subprocess.CREATE_NO_WINDOW, timeout=300)
            record["copyExitCode"] = result.returncode
            write(path, record)
            if result.returncode >= 8 or result.returncode < 0:
                raise RuntimeError(f"Profile copy failed ({result.returncode}); original retained")
            if profile_inventory(home) != before or profile_inventory(next_home) != before:
                raise RuntimeError("Profile copy or original metadata changed; original retained")
            next_state = dict(state, prepared=str(prepared))
            write(next_home / ".devspace-gateway.json", next_state)
            record["phase"] = "exchanging"
            write(path, record)
            home.rename(folder / "previous")
            next_home.rename(home)
            record["phase"] = "trial"
            write(path, record)
            return record
        if not previous or previous["phase"] in SETTLED_UPDATES:
            raise RuntimeError("No pending profile update")
        record = previous
        if (record.get("profileId") != owner["profileId"] or record.get("home") != str(home)
                or not re.fullmatch(r"[0-9a-f]{32}", record.get("id", ""))
                or record.get("phase") not in {"copying", "exchanging", "trial", "restoring"}):
            raise ValueError("Update journal ownership mismatch")
        folder = plain_path(control / record["id"])
        backup = folder / "previous"
        before = read(folder / "before.json")
        if action == "accept":
            if record["phase"] != "trial":
                raise RuntimeError("Incomplete exchange cannot be accepted")
            state = stopped_profile(home, owner)
            if state["prepared"] != record["prepared"] or profile_inventory(backup) != before:
                raise ValueError("Selected candidate or backup changed")
            record["phase"] = "accepted"
        else:
            if record["phase"] == "copying" and "copyExitCode" not in record:
                raise RuntimeError("Interrupted copy has no exit proof; preserve for inspection")
            if backup.exists():
                if profile_inventory(backup) != before:
                    raise ValueError("Original profile changed; rollback blocked")
                if home.exists():
                    state = stopped_profile(home, owner)
                    if state["prepared"] != record["prepared"]:
                        raise ValueError("Candidate profile changed; rollback blocked")
                    profile_inventory(home)  # Validate links before moving the failed candidate.
                    record["phase"] = "restoring"
                    write(path, record)
                    home.rename(folder / "failed")
                backup.rename(home)
            elif not home.exists() or profile_inventory(home) != before:
                raise ValueError("Original profile cannot be identified; rollback blocked")
            record["phase"] = "rolled_back"
        write(path, record)
        return record


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
    parser.add_argument("action", choices=("init", "run", "stop", "status", "switch", "rollback", "accept"))
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--prepared", type=Path)
    args = parser.parse_args()
    home = plain_path(args.home).resolve()
    path = home / ".devspace-gateway.json"
    if args.action == "init":
        if not args.prepared:
            parser.error("init requires --prepared")
        if home.exists():
            raise FileExistsError(f"Profile already exists: {home}")
        prepared_runtime(args.prepared)
        prepared = args.prepared.resolve(strict=True)
        if prepared.is_relative_to(home) or home.is_relative_to(prepared):
            raise ValueError("Prepared code and profile data must be separate")
        home.mkdir()  # Never adopt an existing user profile, even an empty directory.
        control = plain_path(control_directory(home))
        control.mkdir()  # A previous control directory also blocks adoption.
        owner = {"home": str(home), "profileId": uuid.uuid4().hex}
        write(control / "profile.json", owner)
        write(path, {"schema": 2, **owner, "prepared": str(args.prepared.resolve()),
                     "phase": "stopped", "starts": []})
        return 0
    if args.action in ("switch", "rollback", "accept"):
        print(json.dumps(profile_update(home, args.action, args.prepared), indent=2))
        return 0
    state = read(path)
    if state["schema"] not in (1, 2) or state["home"] != str(home):
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
    with ownership(home):
        # Re-read after obtaining the lock so a racing invocation cannot overwrite another owner.
        if state["schema"] == 2:
            owner = read(control_directory(home) / "profile.json")
            if owner != {"home": str(home), "profileId": state["profileId"]}:
                raise ValueError("Profile transaction ownership mismatch")
            journal = control_directory(home) / "update.json"
            if journal.exists() and read(journal)["phase"] not in SETTLED_UPDATES | {"trial"}:
                raise RuntimeError("Incomplete profile exchange; rollback before starting")
            if read(path)["prepared"] != state["prepared"]:
                raise RuntimeError("Selected runtime changed while waiting for profile lock")
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
        return supervise(home, read(path), status, command, env)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
