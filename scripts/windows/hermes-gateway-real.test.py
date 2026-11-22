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
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    gpt_port = s.getsockname()[1]
config_dir = HOME.with_name(HOME.name + "-tray")
config_dir.mkdir()
CONFIG = config_dir / "devspace-watchdog.config.json"
manager.write(CONFIG, dict(manager.prepared_pair(BASELINE), stateDir=str(config_dir), hermesHome=str(HOME),
                           hermesEnabled=True, hermesPort=gpt_port,
                           capabilities={"hermes": {"filesystemScope": "restricted", "allowedRoots": [str(HOME)], "ownerMode": False}}))
original_config = CONFIG.read_bytes()
(HOME / ".env").write_text(f"API_SERVER_KEY={secrets.token_hex(32)}\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT={port}\nGATEWAY_MULTIPLEX_PROFILES=false\n", encoding="utf-8")
env = manager.isolated_environment(HOME)
probe_env = {**env, **{key: os.environ[key] for key in
    ('GITHUB_ACTIONS', 'GITHUB_SHA', 'RUNNER_ENVIRONMENT', 'RUNNER_OS', 'RUNNER_TEMP', 'COMPUTERNAME')}}
os.environ.clear()
os.environ.update(env)
sys.path.insert(0, str(PREPARED / "payload"))
from gateway.control_socket import pause_gateway_for_update

report = {"scope": "Two real pinned gateways, offline profile/configuration switch and rollback, Tray-launched paired GPT, and test conversation history read by each Agent. Startup failure and a separate SQLite schema change are injected. Runs on isolated loopback without a model call or automatic Tray lifecycle orchestration.",
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

def check_session_history(prepared, action):
    # Each version must open the profile with its own interpreter and storage implementation.
    probe = """
import contextlib, json, os, sqlite3, sys
from pathlib import Path
payload, home, action = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
assert Path(os.environ['HERMES_HOME']).resolve() == home
sys.path.insert(0, str(payload))
import hermes_state
assert Path(hermes_state.__file__).resolve().parent == payload
path = home / 'state.db'
session = 'devspace-rollback-evidence'
expected = [('user', 'before upgrade')]
if action != 'restore':
    with hermes_state.SessionDB(path) as db:
        if action == 'seed':
            assert db.get_session(session) is None
            db.create_session(session, 'cli')
            db.append_message(session, *expected[0])
        elif action == 'upgrade':
            assert [(m['role'], m['content']) for m in db.get_messages(session)] == expected
            expected.append(('assistant', 'after upgrade'))
            db.append_message(session, *expected[-1])
        else:
            raise ValueError(action)
with hermes_state.SessionDB(path, read_only=True) as db:
    assert db.get_session(session)['id'] == session
    messages = [(m['role'], m['content']) for m in db.get_messages(session)]
    assert messages == expected, messages
with contextlib.closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as conn:
    assert conn.execute('pragma integrity_check').fetchall() == [('ok',)]
    schema = conn.execute('select version from schema_version').fetchone()[0]
print(json.dumps(dict(action=action, schema=schema, messages=messages)))
"""
    result = subprocess.run([receipts[prepared]["python"], "-I", "-B", "-c", probe,
                             str(prepared / "payload"), str(HOME), action],
                            env=env, cwd=HOME, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"Hermes session {action} failed: {result.stderr}")
    evidence = json.loads(result.stdout)
    event("session_history", dict(evidence, agentRevision=receipts[prepared]["upstreamRevision"]))
    return evidence["schema"]

def wait_observed_exit(identities, deadline):
    for pid, start in identities:
        try:
            process = psutil.Process(pid)
            if process.create_time() == start:
                process.wait(timeout=max(0, deadline - time.monotonic()))
        except psutil.NoSuchProcess:
            pass


def check_command(prepared):
    return subprocess.run([receipts[prepared]["python"], "-I", "-B", str(MANAGER),
                           "check", "--home", str(HOME), "--prepared", str(prepared)],
                          env=env, capture_output=True, text=True, timeout=20,
                          creationflags=subprocess.CREATE_NO_WINDOW)


def ready(prepared, previous=None):
    deadline = time.monotonic() + 180
    last_check = None
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
                check = check_command(prepared)
                last_check = {"exitCode": check.returncode, "stdout": check.stdout, "stderr": check.stderr}
                result = json.loads(check.stdout) if check.stdout.strip() else {}
                # The product command must attest readiness; HTTP alone binds before full startup.
                if (check.returncode == 0 and result.get("ready") is True and health.get("status") == "ok"
                        and result.get("gateway") == state["gateway"]
                        and result.get("revision") == receipts[prepared]["revision"]
                        and result.get("prepared") == str(prepared)):
                    event("ready", {"prepared": str(prepared), "identity": state["gateway"], "health": health,
                                    "check": result})
                    return state["gateway"]
            except (OSError, ValueError):
                pass
        time.sleep(.25)
    raise TimeoutError(f"Gateway readiness deadline expired; last product check: {last_check}")

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


def verify_pair(prepared):
    evidence = REPORT.with_name(f"paired-{report['stage']}.json")
    powershell = Path(env['SYSTEMROOT']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
    command = [str(powershell), '-NoLogo', '-NoProfile', '-File',
               str(MANAGER.with_name('watchdog-hermes-pair.test.ps1')),
               '-Prepared', str(prepared), '-ProfileHome', str(HOME), '-ReportPath', str(evidence), '-ConfigPath', str(CONFIG)]
    with evidence.with_suffix('.log').open('x', encoding='utf-8') as log:
        result = subprocess.run(command, env=probe_env, stdout=log, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW, timeout=180)
    pair_result = manager.read(evidence) if evidence.exists() else None
    event('tray_paired_mcp', {'exitCode': result.returncode, 'report': str(evidence), 'result': pair_result})
    assert result.returncode == 0 and pair_result and pair_result['passed'], 'Tray paired MCP validation failed'
    assert pair_result['processes'] and pair_result['observedProcessesExited'] and pair_result['gatewayUnchanged'], pair_result
    # GPT exited before any profile snapshot; the selected gateway remains live and ready.
    ready(prepared)


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
        assert not manager.process_alive(pid, start_time), f"Owned process still alive: {pid}"
    check = check_command(Path(final["prepared"]))
    assert check.returncode == 1 and json.loads(check.stdout)["ready"] is False, check
    event("check_rejected_stopped_gateway", json.loads(check.stdout))
    shutil.copyfile(HOME / "supervised-gateway.log", REPORT.with_name(f"gateway-{report['stage']}-runtime.log"))
    event("stopped_no_survivors", {"final": final, "observedIdentities": sorted(observed)})


def rollback(before, transaction):
    backup = manager.profile_inventory(manager.control_directory(HOME) / transaction["id"] / "previous")
    changes = {path: {"before": before.get(path), "backup": backup.get(path)}
               for path in before.keys() | backup.keys() if before.get(path) != backup.get(path)}
    if changes:
        event("backup_changed_before_rollback", changes)
    result = manager.profile_update(HOME, "rollback", None)
    assert result["phase"] == "rolled_back" and result["id"] == transaction["id"], result
    assert manager.profile_inventory(HOME) == before, "Rollback did not restore every file, stream and metadata field"
    assert CONFIG.read_bytes() == original_config, "Rollback did not restore original configuration bytes"
    assert Path(manager.read(state_path)["prepared"]) == BASELINE
    with contextlib.closing(sqlite3.connect(HOME / "rollback-proof.sqlite3")) as db:
        assert db.execute("pragma integrity_check").fetchone() == ("ok",)
        assert db.execute("select * from history").fetchall() == [("baseline data",)]
    event("full_profile_restored", {"transaction": result, "entries": len(before), "sqliteIntegrity": "ok",
                                    "originalConfigurationRestored": True})


try:
    start(BASELINE, "baseline")
    ready(BASELINE)
    verify_pair(BASELINE)
    stopped(1)
    baseline_schema = check_session_history(BASELINE, "seed")
    with contextlib.closing(sqlite3.connect(HOME / "rollback-proof.sqlite3")) as db, db:
        db.execute("create table history(message text)")
        db.execute("insert into history values ('baseline data')")
    (HOME / "rollback-proof.txt").write_text("baseline data", encoding="utf-8")
    (HOME / "rollback-proof.txt:notes").write_text("baseline stream", encoding="utf-8")
    before = manager.profile_inventory(HOME)
    transaction = manager.profile_update(HOME, "switch", PREPARED, CONFIG)
    event("selected_candidate", transaction)
    start(PREPARED, "candidate")
    first = ready(PREPARED)
    wrong = check_command(BASELINE)
    assert wrong.returncode == 1 and "expected preparation" in wrong.stderr, wrong
    event("check_rejected_wrong_preparation", {"exitCode": wrong.returncode, "error": wrong.stderr})
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
    verify_pair(PREPARED)
    stopped(4)
    check_session_history(PREPARED, "upgrade")
    with contextlib.closing(sqlite3.connect(HOME / "rollback-proof.sqlite3")) as db, db:
        db.execute("alter table history add column migration integer")
        db.execute("update history set message='candidate data', migration=1")
    (HOME / "rollback-proof.txt:notes").write_text("candidate stream", encoding="utf-8")
    (HOME / "candidate-only").write_text("preserve in failed profile", encoding="utf-8")
    rollback(before, transaction)
    assert (manager.control_directory(HOME) / transaction["id"] / "failed" / "candidate-only").exists()
    start(BASELINE, "restored-baseline")
    ready(BASELINE)
    verify_pair(BASELINE)
    stopped(2)
    assert check_session_history(BASELINE, "restore") == baseline_schema

    before = manager.profile_inventory(HOME)
    transaction = manager.profile_update(HOME, "switch", PREPARED)
    event("selected_candidate_for_failed_start", transaction)
    start(PREPARED, "failed-start", fail=True)
    stopped(3, failed=True)
    rollback(before, transaction)
    start(BASELINE, "restored-after-failed-start")
    ready(BASELINE)
    verify_pair(BASELINE)
    stopped(3)
    assert check_session_history(BASELINE, "restore") == baseline_schema
    report["passed"] = True
except Exception as exc:
    report["error"] = repr(exc)
    try:
        control = manager.control_directory(HOME)
        transaction = manager.read(control / 'update.json')
        if transaction['phase'] == 'copying':
            folder = control / transaction['id']
            before = manager.read(folder / 'before.json')
            differences = {}
            for name, directory in (('original', HOME), ('copy', folder / 'next')):
                actual = manager.profile_inventory(directory)
                differences[name] = {path: {'before': before.get(path), 'actual': actual.get(path)}
                                     for path in before.keys() | actual.keys() if before.get(path) != actual.get(path)}
            event('profile_copy_differences', differences)
            shutil.copyfile(folder / 'copy.log', REPORT.with_name('profile-copy.log'))
    except Exception as diagnostic_error:
        report['copyDiagnosticError'] = repr(diagnostic_error)
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
        if manager.process_alive(pid, start):
            survivors.append({"pid": pid, "startTime": start})
    report["survivingObservedIdentities"] = survivors
    report["lastState"] = manager.read(state_path)
    report["finishedAt"] = time.time()
    manager.write(REPORT, report)
