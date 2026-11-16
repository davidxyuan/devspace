"""Ephemeral CI gateway probe. No production task, token or profile is used."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
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
parser.add_argument("--baseline", type=Path, required=True)
parser.add_argument("--worker", action="store_true")
parser.add_argument("--fail-start", action="store_true")
args = parser.parse_args()
HOME = args.home.resolve()
REPORT = args.report.resolve()
PREPARED = args.prepared.resolve()
BASELINE = args.baseline.resolve()
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
        fault = "raise SystemExit(78)" if args.fail_start else FAULT
        command[index] = source.replace("runpy.run_module(", f"exec({fault!r}); runpy.run_module(", 1)
        assert looks_like_gateway_runtime_command_line(" ".join(command)), "Probe changed gateway identity"
        return command

    _launchers.runtime_command = fault_command
    sys.argv = [str(MANAGER), "run", "--home", str(HOME)]
    raise SystemExit(manager.main())

assert os.name == "nt" and os.environ.get("GITHUB_ACTIONS") == "true", "Run only on an ephemeral GitHub Windows runner"
assert not REPORT.exists(), "Never overwrite previous probe evidence"
assert psutil.virtual_memory().available >= 1536 * 1024**2, "Need at least 1.5 GiB available before this small gateway probe"
manager.prepared_runtime(PREPARED)
manager.prepared_runtime(BASELINE, require_interpreter=False)
receipts = {path: manager.read(path / "preparation.json") for path in (BASELINE, PREPARED)}
assert receipts[BASELINE]["upstreamRevision"] != receipts[PREPARED]["upstreamRevision"], "Need two distinct official versions"
for path, receipt in receipts.items():
    assert receipt["pair"]["state"] == "verified"
    assert manager.read(path / receipt["pair"]["mcpReport"])["passed"] is True
state_path = HOME / ".devspace-gateway.json"
initial = manager.read(state_path)
assert initial["phase"] == "stopped" and initial["starts"] == []
assert initial["home"] == str(HOME)
assert Path(initial["prepared"]).resolve() == BASELINE
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

report = {"scope": "Two real pinned gateways with managed profile switch/rollback; isolated loopback only, no installed task or chat/model call. GPT pairing is verified separately in disposable MCP profiles. Startup failure and data migration are injected test faults.",
          "prepared": str(PREPARED), "revision": manager.read(PREPARED / "preparation.json")["revision"],
          "versions": [{"prepared": str(path), "upstreamRevision": receipt["upstreamRevision"],
                        "revision": receipt["revision"], "gptRevision": receipt["pair"]["revision"]}
                       for path, receipt in receipts.items()],
          "home": str(HOME), "port": port, "events": [], "passed": False}
observed = set()
observed_details = {}
worker = None

def event(kind, value):
    report["events"].append({"at": time.time(), "kind": kind, "value": value})
    manager.write(REPORT, report)
    print(kind, json.dumps(value), flush=True)

def runtime_ready(identity, health, control, runtime, revision):
    expected = {"pid": identity["pid"], "start_time": round(identity["startTime"] * 100),
                "hermes_home": str(HOME), "code_sha": revision}
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


def wait_observed_exit(identities, deadline):
    for pid, start in identities:
        try:
            process = psutil.Process(pid)
            if process.create_time() == start:
                process.wait(timeout=max(0, deadline - time.monotonic()))
        except psutil.NoSuchProcess:
            pass


def ready(prepared, previous=None):
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
                    key = (process.pid, process.create_time())
                    observed.add(key)
                    if key not in observed_details:
                        observed_details[key] = process.as_dict(attrs=["pid", "ppid", "create_time", "name", "exe"])
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
                if runtime_ready(state["gateway"], health, control, runtime, receipts[prepared]["revision"]):
                    event("ready", {"prepared": str(prepared), "identity": state["gateway"], "health": health, "control": control,
                                    "runtime": {k: runtime[k] for k in ("gateway_state", "pid", "start_time", "answering_pid", "answered_at")}})
                    return state["gateway"]
            except (OSError, ValueError):
                pass
        time.sleep(.25)
    raise TimeoutError("Gateway readiness deadline expired")

def start(prepared, label, *, fail=False):
    global worker
    assert worker is None or worker.poll() is not None, "Previous manager has not exited"
    report["stage"] = label
    # Keep the parent's open log outside the profile that will be exchanged.
    with REPORT.with_name(f"gateway-{label}.log").open("x", encoding="utf-8") as log:
        worker = subprocess.Popen([receipts[prepared]["python"], "-I", "-B", str(Path(__file__).resolve()),
                                   "--worker", "--home", str(HOME), "--report", str(REPORT),
                                   "--prepared", str(prepared), "--baseline", str(BASELINE),
                                   *(["--fail-start"] if fail else [])],
                                  env=env, stdout=log, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
    process = psutil.Process(worker.pid)
    observed.add((process.pid, process.create_time()))
    event("started_manager", {"prepared": str(prepared), "label": label, "pid": process.pid,
                              "startTime": process.create_time(), "injectedStartupFailure": fail})


def stopped(expected_starts, *, failed=False):
    stop_deadline = time.monotonic() + 190
    if not failed:
        state = manager.read(state_path)
        manager.write(HOME / ".devspace-gateway-stop.json", {"runId": state["runId"]})
    assert worker.wait(timeout=max(0, stop_deadline - time.monotonic())) == (78 if failed else 0)
    final = manager.read(state_path)
    assert final["phase"] == ("fatal_configuration" if failed else "stopped"), final
    assert len(final["starts"]) == expected_starts and final["jobActiveProcesses"] == 0, final
    # Waiting for the launcher does not join its descendants; all share the original stop deadline.
    wait_observed_exit(observed, stop_deadline)
    for pid, start_time in observed:
        assert not observed_alive(pid, start_time), f"Owned process still alive: {pid}"
    shutil.copyfile(HOME / "supervised-gateway.log", REPORT.with_name(f"gateway-{report['stage']}-runtime.log"))
    event("stopped_no_survivors", {"final": final, "observedIdentities": sorted(observed)})


def rollback(before, transaction):
    result = manager.profile_update(HOME, "rollback", None)
    assert result["phase"] == "rolled_back" and result["id"] == transaction["id"], result
    assert manager.profile_inventory(HOME) == before, "Rollback did not restore every file, stream and metadata field"
    assert Path(manager.read(state_path)["prepared"]) == BASELINE
    with contextlib.closing(sqlite3.connect(HOME / "rollback-proof.sqlite3")) as db:
        assert db.execute("pragma integrity_check").fetchone() == ("ok",)
        assert db.execute("select * from history").fetchall() == [("baseline data",)]
    event("full_profile_restored", {"transaction": result, "entries": len(before), "sqliteIntegrity": "ok"})


try:
    start(BASELINE, "baseline")
    ready(BASELINE)
    stopped(1)
    with contextlib.closing(sqlite3.connect(HOME / "rollback-proof.sqlite3")) as db, db:
        db.execute("create table history(message text)")
        db.execute("insert into history values ('baseline data')")
    (HOME / "rollback-proof.txt").write_text("baseline data", encoding="utf-8")
    (HOME / "rollback-proof.txt:notes").write_text("baseline stream", encoding="utf-8")
    before = manager.profile_inventory(HOME)
    transaction = manager.profile_update(HOME, "switch", PREPARED)
    event("selected_candidate", transaction)
    start(PREPARED, "candidate")
    first = ready(PREPARED)
    manager.write(HOME / "test-fault.json", first)
    event("requested_owned_child_crash_37", first)
    second = ready(PREPARED, first)
    assert second != first
    ack = pause_gateway_for_update(HOME)
    assert ack and ack.get("pausing") and ack.get("pid") == second["pid"], ack
    event("official_pause_for_update", ack)
    third = ready(PREPARED, second)
    assert third != second
    event("replacement_after_official_handoff", third)
    stopped(4)
    with contextlib.closing(sqlite3.connect(HOME / "rollback-proof.sqlite3")) as db, db:
        db.execute("alter table history add column migration integer")
        db.execute("update history set message='candidate data', migration=1")
    (HOME / "rollback-proof.txt:notes").write_text("candidate stream", encoding="utf-8")
    (HOME / "candidate-only").write_text("preserve in failed profile", encoding="utf-8")
    rollback(before, transaction)
    assert (manager.control_directory(HOME) / transaction["id"] / "failed" / "candidate-only").exists()
    start(BASELINE, "restored-baseline")
    ready(BASELINE)
    stopped(2)

    before = manager.profile_inventory(HOME)
    transaction = manager.profile_update(HOME, "switch", PREPARED)
    event("selected_candidate_for_failed_start", transaction)
    start(PREPARED, "failed-start", fail=True)
    stopped(3, failed=True)
    rollback(before, transaction)
    start(BASELINE, "restored-after-failed-start")
    ready(BASELINE)
    stopped(3)
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
    report["observedProcesses"] = list(observed_details.values())
    survivors = []
    for pid, start in observed:
        if observed_alive(pid, start):
            survivors.append({"pid": pid, "startTime": start})
    report["survivingObservedIdentities"] = survivors
    report["lastState"] = manager.read(state_path)
    report["finishedAt"] = time.time()
    manager.write(REPORT, report)
