"""Readiness regression without launching a gateway or loading probe configuration."""
import ast
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest.mock import Mock

source = Path(__file__).with_name("hermes-gateway-real.test.py").read_text(encoding="utf-8")
functions = [n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name in ("runtime_ready", "observed_alive")]
namespace = {"HOME": Path("isolated-profile")}
exec(compile(ast.Module(body=functions, type_ignores=[]), "probe-readiness", "exec"), namespace)


class ReadinessTests(unittest.TestCase):
    def test_exit_evidence_checks_liveness_beyond_retained_identity(self):
        class Gone(Exception): pass
        class StillRunning(Exception): pass
        process = Mock()
        process.create_time.return_value = 1234.5
        api = SimpleNamespace(Process=Mock(return_value=process), NoSuchProcess=Gone, TimeoutExpired=StillRunning)
        namespace["psutil"] = api
        alive = namespace["observed_alive"]
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

    def test_http_success_requires_same_live_fully_started_gateway(self):
        identity = {"pid": 42, "startTime": 1234.567}
        control = {"pid": 42, "start_time": 123457, "hermes_home": str(namespace["HOME"])}
        runtime = dict(control, gateway_state="running", answering_pid=42)
        ready = namespace["runtime_ready"]
        self.assertTrue(ready(identity, {"status": "ok"}, control, runtime))
        for changes in ({"gateway_state": "starting"}, {"pid": 43}, {"start_time": 123456},
                        {"hermes_home": "production-profile"}, {"answering_pid": 43}):
            self.assertFalse(ready(identity, {"status": "ok"}, control, dict(runtime, **changes)))
        self.assertFalse(ready(identity, {"status": "ok"}, control, None))
        self.assertFalse(ready(identity, {"status": "error"}, control, runtime))


if __name__ == "__main__":
    unittest.main()
