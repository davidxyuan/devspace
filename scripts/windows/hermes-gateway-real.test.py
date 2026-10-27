"""Ephemeral CI gateway probe. No production task, token or profile is used."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
import urllib.request

import psutil

MANAGER = Path(__file__).with_name("hermes-gateway-supervisor.py")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--home", type=Path, required=True)
parser.add_argument("--report", type=Path, required=True)
parser.add_argument("--prepared", type=Path, required=True)
parser.add_argument("--worker", action="store_true")
args = parser.parse_args()
HOME = args.home.resolve()
REPORT = args.report.resolve()
PREPARED = args.prepared.resolve()
spec = importlib.util.spec_from_file_location("manager", MANAGER)
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)

# Fault injection exists only in this disposable probe's child bootstrap.
FAULT = '''
import threading,os,time,json
from pathlib import Path
import psutil
def inject():
    path=Path(os.environ['HERMES_HOME'])/'test-fault.json'
    while True:
        if path.exists():
            request=json.loads(path.read_text())
            p=psutil.Process()
            if request=={'pid':p.pid,'startTime':p.create_time()}:
                path.unlink()
                os._exit(37)
        time.sleep(.1)
threading.Thread(target=inject,daemon=True).start()
'''

if args.worker:
    sys.path.insert(0, str(PREPARED / "payload"))
    from hermes_cli import _launchers
    from gateway.status import looks_like_gateway_runtime_command_line
    original_command = _launchers.runtime_command

    def fault_command(*a, **kw):
        command = original_command(*a, **kw)
        assert looks_like_gateway_runtime_command_line(" ".join(command)), "Official launcher identity rejected"
        index = command.index("-c") + 1
        source = command[index]
        assert source.count("runpy.run_module(") == 1
        command[index] = source.replace("runpy.run_module(", f"exec({FAULT!r}); runpy.run_module(", 1)
        assert looks_like_gateway_runtime_command_line(" ".join(command)), "Probe changed gateway identity"
        return command

    _launchers.runtime_command = fault_command
    sys.argv = [str(MANAGER), "run", "--home", str(HOME)]
    raise SystemExit(manager.main())

assert os.name == "nt" and os.environ.get("GITHUB_ACTIONS") == "true", "Run only on an ephemeral GitHub Windows runner"
assert not REPORT.exists(), "Never overwrite previous probe evidence"
assert psutil.virtual_memory().available >= 1536 * 1024**2, "Need at least 1.5 GiB available before this small gateway probe"
manager.prepared_runtime(PREPARED)
state_path = HOME / ".devspace-gateway.json"
initial = manager.read(state_path)
assert initial["phase"] == "stopped" and initial["starts"] == []
assert initial["home"] == str(HOME)
assert Path(initial["prepared"]).resolve() == PREPARED
assert not (HOME / ".env").exists(), "Never overwrite an existing profile configuration"
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
(HOME / ".env").write_text(f"API_SERVER_KEY={secrets.token_hex(32)}\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT={port}\nGATEWAY_MULTIPLEX_PROFILES=false\n", encoding="utf-8")
env = manager.isolated_environment(HOME)
os.environ.clear()
os.environ.update(env)
sys.path.insert(0, str(PREPARED / "payload"))
from gateway.control_socket import identify_gateway, pause_gateway_for_update, query_gateway_control

report = {"scope": "Real pinned gateway candidate, isolated loopback API only; no chat/model call or installed task",
          "prepared": str(PREPARED), "revision": manager.read(PREPARED / "preparation.json")["revision"],
          "home": str(HOME), "port": port, "events": [], "passed": False}
observed = set()
worker = None

def event(kind, value):
    report["events"].append({"at": time.time(), "kind": kind, "value": value})
    manager.write(REPORT, report)
    print(kind, json.dumps(value), flush=True)

def runtime_ready(identity, health, control, runtime):
    expected = {"pid": identity["pid"], "start_time": round(identity["startTime"] * 100),
                "hermes_home": str(HOME)}
    return (health.get("status") == "ok" and bool(control) and bool(runtime)
            and all(control.get(k) == v and runtime.get(k) == v for k, v in expected.items())
            and runtime.get("gateway_state") == "running"
            and runtime.get("answering_pid") == identity["pid"])


def observed_alive(pid, start):
    try:
        process = psutil.Process(pid)
        if process.create_time() != start:
            return False
        # Windows can retain creation metadata after exit; a signaled process handle is authoritative.
        process.wait(timeout=0)
        return False
    except psutil.NoSuchProcess:
        return False
    except psutil.TimeoutExpired:
        return True


def ready(previous=None):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if worker.poll() is not None:
            raise RuntimeError(f"Manager exited {worker.returncode}: {manager.read(state_path)}")
        state = manager.read(state_path)
        for key in ("supervisor", "child", "gateway"):
            if state.get(key):
                observed.add((state[key]["pid"], state[key]["startTime"]))
        try:
            parent = psutil.Process(worker.pid)
            for process in [parent, *parent.children(recursive=True)]:
                try:
                    observed.add((process.pid, process.create_time()))
                except psutil.NoSuchProcess:
                    pass
        except psutil.NoSuchProcess:
            pass
        if state.get("gateway") and state["gateway"] != previous and state["phase"] == "running":
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    health = json.load(response)
                control = identify_gateway(HOME)
                runtime = query_gateway_control(HOME, "status")
                # HTTP binds before runner.start completes; require the live runtime's serving state.
                if runtime_ready(state["gateway"], health, control, runtime):
                    event("ready", {"identity": state["gateway"], "health": health, "control": control,
                                    "runtime": {k: runtime[k] for k in ("gateway_state", "pid", "start_time", "answering_pid", "answered_at")}})
                    return state["gateway"]
            except (OSError, ValueError):
                pass
        time.sleep(.25)
    raise TimeoutError("Gateway readiness deadline expired")

try:
    with (HOME / "test-manager.log").open("x", encoding="utf-8") as log:
        worker = subprocess.Popen([sys.executable, "-I", "-B", str(Path(__file__).resolve()),
                                   "--worker", "--home", str(HOME), "--report", str(REPORT),
                                   "--prepared", str(PREPARED)],
                                  env=env, stdout=log, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        report["workerPid"] = worker.pid
        first = ready()
        manager.write(HOME / "test-fault.json", first)
        event("requested_owned_child_crash_37", first)
        second = ready(first)
        assert second != first
        ack = pause_gateway_for_update(HOME)
        assert ack and ack.get("pausing") and ack.get("pid") == second["pid"], ack
        event("official_pause_for_update", ack)
        third = ready(second)
        assert third != second
        event("replacement_after_official_handoff", third)
        state = manager.read(state_path)
        manager.write(HOME / ".devspace-gateway-stop.json", {"runId": state["runId"]})
        assert worker.wait(timeout=190) == 0
        final = manager.read(state_path)
        assert final["phase"] == "stopped" and len(final["starts"]) == 3, final
        for pid, start in observed:
            assert not observed_alive(pid, start), f"Owned process still alive: {pid}"
        event("graceful_stop_no_survivors", {"final": final, "observedIdentities": sorted(observed)})
        report["passed"] = True
except Exception as exc:
    report["error"] = repr(exc)
    if worker and worker.poll() is None:
        state = manager.read(state_path)
        manager.write(HOME / ".devspace-gateway-stop.json", {"runId": state["runId"]})
        try:
            worker.wait(timeout=190)
        except subprocess.TimeoutExpired:
            report["cleanupPending"] = "Graceful stop did not complete; no force kill"
    raise
finally:
    report["observedIdentities"] = sorted(observed)
    survivors = []
    for pid, start in observed:
        if observed_alive(pid, start):
            survivors.append({"pid": pid, "startTime": start})
    report["survivingObservedIdentities"] = survivors
    report["lastState"] = manager.read(state_path)
    report["finishedAt"] = time.time()
    manager.write(REPORT, report)
