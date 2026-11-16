"""Readiness regression without launching a gateway or loading probe configuration."""
import ast
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock

functions = []
for filename, names in (("hermes-gateway-supervisor.py", ("check_runtime", "process_alive")),
                        ("hermes-gateway-real.test.py", ("wait_observed_exit",))):
    source = Path(__file__).with_name(filename).read_text(encoding="utf-8")
    functions.extend(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name in names)
namespace = {"datetime": datetime, "timezone": timezone}
exec(compile(ast.Module(body=functions, type_ignores=[]), "probe-readiness", "exec"), namespace)


class ReadinessTests(unittest.TestCase):
    def test_descendants_share_the_original_stop_deadline(self):
        class Gone(Exception): pass
        class StillRunning(Exception): pass
        first, second, reused = Mock(), Mock(), Mock()
        first.create_time.return_value = 1
        second.create_time.return_value = 2
        reused.create_time.return_value = 99
        api = SimpleNamespace(Process=Mock(side_effect=[first, second, reused, Gone]), NoSuchProcess=Gone)
        namespace.update(psutil=api, time=SimpleNamespace(monotonic=Mock(side_effect=[103, 108])))
        namespace["wait_observed_exit"]([(1, 1), (2, 2), (3, 3), (4, 4)], 110)
        first.wait.assert_called_once_with(timeout=7)
        second.wait.assert_called_once_with(timeout=2)
        reused.wait.assert_not_called()
        api.Process.side_effect = [first]
        first.wait.side_effect = StillRunning
        namespace["time"].monotonic.return_value = 111
        namespace["time"].monotonic.side_effect = None
        with self.assertRaises(StillRunning):
            namespace["wait_observed_exit"]([(1, 1)], 110)
        first.wait.assert_called_with(timeout=0)

    def test_exit_evidence_checks_liveness_beyond_retained_identity(self):
        class Gone(Exception): pass
        class StillRunning(Exception): pass
        process = Mock()
        process.create_time.return_value = 1234.5
        api = SimpleNamespace(Process=Mock(return_value=process), NoSuchProcess=Gone, TimeoutExpired=StillRunning)
        namespace["psutil"] = api
        alive = namespace["process_alive"]
        process.wait.side_effect = StillRunning
        self.assertTrue(alive(42, 1234.5))
        process.wait.assert_called_once_with(timeout=0)
        process.wait.side_effect = None
        process.wait.return_value = 0
        self.assertFalse(alive(42, 1234.5), "retained creation metadata does not imply a running process")
        process.wait.reset_mock()
        self.assertFalse(alive(42, 9999), "reused PID is not the observed process")
        process.wait.assert_not_called()
        api.Process.side_effect = Gone
        self.assertFalse(alive(42, 1234.5))


class RuntimeCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.revision = "a" * 40
        self.identity = {"pid": 42, "startTime": 1234.567}
        self.state = {"schema": 2, "profileId": "owned", "runId": "run-1", "home": str(self.home),
                      "prepared": "expected-preparation", "phase": "running",
                      "supervisor": {"pid": 41, "startTime": 1230}, "gateway": self.identity}
        self.control = {"pid": 42, "start_time": 123457, "hermes_home": str(self.home), "code_sha": self.revision}
        self.runtime = dict(self.control, gateway_state="running", answering_pid=42)
        self.gateway = SimpleNamespace(get_running_pid_identity_strict=Mock(return_value=(42, 1234.567)))
        self.query = Mock(side_effect=lambda home, verb, **kw: self.control if verb == "identify" else self.runtime)
        self.read = Mock(return_value=self.state)
        self.alive = Mock(return_value=True)
        self.original_alive = namespace["process_alive"]
        namespace.update(read=self.read, process_alive=self.alive)
        self.addCleanup(namespace.update, process_alive=self.original_alive)

    def check(self):
        return namespace["check_runtime"](self.home, self.state, self.gateway, self.query, self.revision)["ready"]

    def test_live_queries_require_same_fully_started_runtime(self):
        self.assertTrue(self.check())
        self.assertEqual(self.query.call_args_list[0].args, (self.home, "identify"))
        self.assertEqual(self.query.call_args_list[1].args, (self.home, "status"))
        self.assertTrue(all(call.kwargs == {"timeout": 2} for call in self.query.call_args_list))
        original = self.runtime
        for changes in ({"gateway_state": "starting"}, {"pid": 43}, {"start_time": 123456},
                        {"hermes_home": "production-profile"}, {"answering_pid": 43},
                        {"code_sha": "b" * 40}, {"code_sha": None}):
            with self.subTest(changes=changes):
                self.runtime = dict(original, **changes)
                self.assertFalse(self.check())
        self.runtime = original
        self.control = dict(self.control, code_sha="b" * 40)
        self.assertFalse(self.check())
        self.control = None
        self.assertFalse(self.check())
        self.runtime = None
        self.assertFalse(self.check())

    def test_dead_or_reused_process_cannot_pass_on_persisted_state(self):
        self.alive.return_value = False
        self.assertFalse(self.check())
        self.query.assert_not_called()
        self.alive.return_value = True
        self.gateway.get_running_pid_identity_strict.return_value = (42, 9999)
        self.assertFalse(self.check())
        self.query.assert_not_called()

    def test_exit_during_control_queries_is_rejected(self):
        self.alive.side_effect = [True, True, False]
        self.assertFalse(self.check())
        self.assertEqual(self.query.call_count, 2)

    def test_lifecycle_changes_are_rejected_but_regular_heartbeats_are_allowed(self):
        self.read.return_value = dict(self.state, updatedAt="new heartbeat")
        self.assertTrue(self.check())
        for changes in ({"runId": "run-2"}, {"prepared": "other-version"}, {"profileId": "other"},
                        {"phase": "stopping"}, {"gateway": dict(self.identity, pid=43)},
                        {"supervisor": {"pid": 99, "startTime": 1230}}):
            with self.subTest(changes=changes):
                self.read.return_value = dict(self.state, **changes)
                self.assertFalse(self.check())

    def test_pending_stop_is_not_ready_even_before_manager_acknowledges_it(self):
        (self.home / ".devspace-gateway-stop.json").touch()
        self.read.side_effect = [self.state, {"runId": "run-1"}]
        self.assertFalse(self.check())
        self.read.side_effect = [self.state, {"runId": "previous-run"}]
        self.assertTrue(self.check())

    def test_starting_and_stopped_phases_do_not_query_gateway(self):
        for phase in ("starting", "stopped", "stopping", "fatal_configuration"):
            self.state["phase"] = phase
            self.assertFalse(self.check())
        self.query.assert_not_called()


if __name__ == "__main__":
    unittest.main()
