"""Readiness regression without launching a gateway or loading probe configuration."""
import ast
from pathlib import Path
import unittest

source = Path(__file__).with_name("hermes-gateway-real.test.py").read_text(encoding="utf-8")
function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == "runtime_ready")
namespace = {"HOME": Path("isolated-profile")}
exec(compile(ast.Module(body=[function], type_ignores=[]), "probe-readiness", "exec"), namespace)


class ReadinessTests(unittest.TestCase):
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
