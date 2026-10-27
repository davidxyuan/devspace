"""Windows process tests for the external manager; not real gateway/VM evidence."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import psutil

spec = importlib.util.spec_from_file_location("supervisor", Path(__file__).with_name("hermes-gateway-supervisor.py"))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class NoGateway:
    def get_running_pid_identity_strict(self, path):
        return None


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gateway-manager-")
        self.home = Path(self.temp.name)
        self.state = {"phase": "stopped", "starts": []}
        self.retry = patch.object(manager, "RETRY_SECONDS", 0.1)
        self.retry.start()

    def tearDown(self):
        self.retry.stop()
        self.temp.cleanup()

    def run_child(self, code, gateway=None):
        return manager.supervise(self.home, self.state, gateway or NoGateway(),
                                 [sys.executable, "-I", "-B", "-c", code], manager.isolated_environment(self.home))

    def test_clean_exit_does_not_restart(self):
        self.assertEqual(self.run_child("pass"), 0)
        self.assertEqual(len(self.state["starts"]), 1)
        self.assertEqual(self.state["phase"], "stopped")

    def test_fatal_configuration_does_not_restart(self):
        self.assertEqual(self.run_child("raise SystemExit(78)"), 78)
        self.assertEqual(len(self.state["starts"]), 1)

    def test_crash_budget_persists(self):
        self.assertEqual(self.run_child("raise SystemExit(37)"), 1)
        self.assertEqual(len(self.state["starts"]), manager.MAX_STARTS)
        self.assertEqual(self.state["phase"], "retry_exhausted")
        self.assertEqual(self.run_child("raise Exception('must not run')"), 1)
        self.assertEqual(len(self.state["starts"]), manager.MAX_STARTS)

    def test_restart_handoff_launches_one_replacement(self):
        self.assertEqual(self.run_child("from pathlib import Path; p=Path('once'); seen=p.exists(); p.touch(); raise SystemExit(0 if seen else 75)"), 0)
        self.assertEqual(len(self.state["starts"]), 2)

    def test_incomplete_previous_run_is_preserved(self):
        self.state.update(phase="starting", runId="previous-owner")
        before = dict(self.state)
        with self.assertRaisesRegex(RuntimeError, "Previous supervisor"):
            self.run_child("pass")
        self.assertEqual(self.state, before)

    def test_existing_gateway_is_preserved(self):
        gateway = NoGateway()
        gateway.get_running_pid_identity_strict = lambda path: (os.getpid(), psutil.Process().create_time())
        before = dict(self.state)
        with self.assertRaisesRegex(RuntimeError, "existing gateway"):
            self.run_child("pass", gateway)
        self.assertEqual(self.state, before)

    def test_profile_lock_blocks_second_owner(self):
        with manager.ownership(self.home):
            code = "import importlib.util,pathlib; s=importlib.util.spec_from_file_location('m',%r); m=importlib.util.module_from_spec(s); s.loader.exec_module(m);\nwith m.ownership(pathlib.Path(%r)): pass" % (str(Path(manager.__file__)), str(self.home))
            result = subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another supervisor", result.stderr)

    def test_unobserved_owner_is_rejected_without_stop(self):
        calls = 0
        gateway = NoGateway()
        def identity(path):
            nonlocal calls
            calls += 1
            return None if calls == 1 else (os.getpid(), psutil.Process().create_time())
        gateway.get_running_pid_identity_strict = identity
        with self.assertRaisesRegex(RuntimeError, "outside the owned"):
            self.run_child("import time; time.sleep(1)", gateway)
        self.assertEqual(self.state["phase"], "attention_required")
        # These test children exit naturally; the manager must never force them down.
        for child in self.state["survivingChildren"]:
            try:
                p = psutil.Process(child["pid"])
                self.assertEqual(p.create_time(), child["startTime"])
                p.wait(timeout=5)
            except psutil.NoSuchProcess:
                pass

    def test_stop_during_retry_does_not_spawn_again(self):
        failure = []
        def stop():
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                path = self.home / ".devspace-gateway.json"
                if path.exists() and manager.read(path)["phase"] == "retry_wait":
                    manager.write(self.home / ".devspace-gateway-stop.json", {"runId": self.state["runId"]})
                    return
                time.sleep(0.01)
            failure.append("retry_wait not reached")
        thread = threading.Thread(target=stop)
        thread.start()
        self.assertEqual(self.run_child("raise SystemExit(37)"), 0)
        thread.join(timeout=11)
        self.assertFalse(failure)
        self.assertEqual(len(self.state["starts"]), 1)

    def test_graceful_stop_resets_marker_from_previous_run(self):
        self.state["stopMarkerSent"] = True
        gateway = NoGateway()
        markers = []
        def identity(path):
            pidfile = self.home / "fixture.json"
            if not pidfile.exists():
                return None
            pid, started = json.loads(pidfile.read_text())
            try:
                p = psutil.Process(pid)
                return (pid, started) if p.create_time() == started and p.is_running() else None
            except psutil.NoSuchProcess:
                return None
        def marker(pid):
            markers.append(pid)
            (self.home / "finish").touch()
            return True
        gateway.get_running_pid_identity_strict = identity
        gateway.write_planned_stop_marker = marker
        def stop():
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.state["phase"] == "running":
                    manager.write(self.home / ".devspace-gateway-stop.json", {"runId": self.state["runId"]})
                    return
                time.sleep(0.01)
        thread = threading.Thread(target=stop)
        thread.start()
        code = "import psutil,json,time; from pathlib import Path; p=psutil.Process(); Path('fixture.json').write_text(json.dumps([p.pid,p.create_time()])); deadline=time.monotonic()+8\nwhile not Path('finish').exists() and time.monotonic()<deadline: time.sleep(.05)\nraise SystemExit(0 if Path('finish').exists() else 78)"
        self.assertEqual(self.run_child(code, gateway), 0)
        thread.join(timeout=11)
        self.assertEqual(len(markers), 1)
        self.assertEqual(len(self.state["starts"]), 1)

    def test_surviving_descendant_prevents_replacement(self):
        code = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(4)']); time.sleep(1); raise SystemExit(37)"
        with patch.object(manager, "STOP_SECONDS", .1), self.assertRaisesRegex(RuntimeError, "surviving processes"):
            self.run_child(code)
        self.assertEqual(len(self.state["starts"]), 1)
        self.assertTrue(self.state["survivingChildren"])
        for child in self.state["survivingChildren"]:
            try:
                p = psutil.Process(child["pid"])
                self.assertEqual(p.create_time(), child["startTime"])
                p.wait(timeout=6)
            except psutil.NoSuchProcess:
                pass

    def test_waits_for_owned_descendants_before_replacement(self):
        descendant = "import os,json,psutil,time; from pathlib import Path; p=psutil.Process(); Path('descendant.json').write_text(json.dumps([p.pid,p.create_time()])); deadline=time.monotonic()+10\nwhile not Path('release').exists() and time.monotonic()<deadline: time.sleep(.01)"
        code = "import subprocess,sys,time; from pathlib import Path\nif Path('once').exists(): raise SystemExit(0)\nPath('once').touch(); subprocess.Popen([sys.executable,'-I','-B','-c',%r]); deadline=time.monotonic()+10\nwhile not Path('parent-exit').exists() and time.monotonic()<deadline: time.sleep(.01)\nraise SystemExit(75)" % descendant
        gateway = NoGateway()
        def identity(path):
            if (self.home / 'descendant.json').exists():
                (self.home / 'parent-exit').touch()
            return None
        gateway.get_running_pid_identity_strict = identity
        original_wait = psutil.wait_procs
        def wait_for_owned(processes, **kwargs):
            self.assertEqual(len(self.state['starts']), 1)
            self.assertEqual(self.state['phase'], 'waiting_descendants')
            self.assertTrue(processes)
            (self.home / 'release').touch()
            return original_wait(processes, **kwargs)
        try:
            with patch.object(psutil, 'wait_procs', side_effect=wait_for_owned) as waited:
                self.assertEqual(self.run_child(code, gateway), 0)
                waited.assert_called_once()
            self.assertEqual(len(self.state['starts']), 2)
            self.assertEqual(self.state['phase'], 'stopped')
        finally:
            (self.home / 'release').touch()
            if (self.home / 'descendant.json').exists():
                pid, started = json.loads((self.home / 'descendant.json').read_text(encoding='utf-8'))
                try:
                    p = psutil.Process(pid)
                    if p.create_time() == started:
                        p.wait(timeout=12)
                except psutil.NoSuchProcess:
                    pass

    def test_reused_supervisor_identity_does_not_receive_stop(self):
        state = {"schema": 1, "home": str(self.home.resolve()), "phase": "running", "runId": "old",
                 "supervisor": {"pid": os.getpid(), "startTime": psutil.Process().create_time() - 10}}
        manager.write(self.home / ".devspace-gateway.json", state)
        with patch.object(sys, "argv", ["manager", "stop", "--home", str(self.home)]):
            with self.assertRaisesRegex(RuntimeError, "identity changed"):
                manager.main()
        self.assertFalse((self.home / ".devspace-gateway-stop.json").exists())

    def test_init_never_adopts_existing_directory(self):
        sentinel = self.home / "keep"
        sentinel.write_text("user data")
        with patch.object(manager, "prepared_runtime"), patch.object(sys, "argv", [
                "manager", "init", "--home", str(self.home), "--prepared", str(self.home)]):
            with self.assertRaises(FileExistsError):
                manager.main()
        self.assertEqual(sentinel.read_text(), "user data")

    def test_corrupt_state_does_not_write_control(self):
        path = self.home / ".devspace-gateway.json"
        path.write_text("invalid")
        with patch.object(sys, "argv", ["manager", "stop", "--home", str(self.home)]):
            with self.assertRaises(json.JSONDecodeError):
                manager.main()
        self.assertEqual(path.read_text(), "invalid")
        self.assertFalse((self.home / ".devspace-gateway-stop.json").exists())

    def test_environment_does_not_inherit_credentials(self):
        with patch.dict(os.environ, {"API_SERVER_KEY": "production", "HERMES_HOME": "production"}):
            env = manager.isolated_environment(self.home)
        self.assertNotIn("API_SERVER_KEY", env)
        self.assertEqual(env["HERMES_HOME"], str(self.home))
        self.assertEqual(env["GATEWAY_MULTIPLEX_PROFILES"], "false")

    def test_run_uses_official_installation_bound_launcher(self):
        home = self.home.resolve()
        root = home / "payload"
        python = home / "runtime" / "python.exe"
        command = [str(python), "-I", "-m", "hermes_cli.main", "gateway", "run", "--external-supervisor"]
        launch = Mock(return_value=command)
        manager.write(home / ".devspace-gateway.json", {
            "schema": 1, "home": str(home), "prepared": str(home), "phase": "stopped", "starts": []})
        with patch.object(manager, "prepared_runtime", return_value=(root, python)), \
             patch.object(manager, "supervise", return_value=0) as supervise, \
             patch.dict(os.environ, {}, clear=False), patch.object(sys, "path", list(sys.path)), \
             patch.object(sys, "argv", ["manager", "run", "--home", str(home)]), \
             patch.dict(sys.modules, {"gateway": SimpleNamespace(status=NoGateway()),
                                      "hermes_cli._launchers": SimpleNamespace(runtime_command=launch)}):
            self.assertEqual(manager.main(), 0)
            launch.assert_called_once_with(root, ["gateway", "run", "--external-supervisor"],
                                           python=python, home=home)
            self.assertEqual(supervise.call_args.args[3], command)
            self.assertEqual(supervise.call_args.args[4]["HERMES_HOME"], str(home))


if __name__ == "__main__":
    unittest.main()
