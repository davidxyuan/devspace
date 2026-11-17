"""Prepared pair checks with local Git fixtures; never launch either service."""
import ast
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).with_name("hermes-gateway-supervisor.py")
names = {"prepared_source", "prepared_runtime", "prepared_pair", "plain_path", "main"}
functions = [n for n in ast.parse(SCRIPT.read_text(encoding="utf-8")).body
             if isinstance(n, ast.FunctionDef) and n.name in names]
namespace = dict(__file__=str(SCRIPT), __doc__="Fixture", argparse=argparse, hashlib=hashlib, importlib=importlib, json=json,
                 os=os, Path=Path, stat=stat, subprocess=subprocess, sys=sys,
                 read=lambda path: json.loads(path.read_text(encoding="utf-8")))
exec(compile(ast.Module(body=functions, type_ignores=[]), str(SCRIPT), "exec"), namespace)


class PairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="prepared-pair-")
        self.addCleanup(self.temp.cleanup)
        self.prepared = (Path(self.temp.name) / "pair ' & 測").resolve()
        self.prepared.mkdir()
        self.root = self.prepared / "payload"
        self.gpt = self.prepared / "gpt-payload"
        for root in (self.root, self.gpt):
            root.mkdir()
            (root / "pyproject.toml").write_text('[project]\nname="fixture"\n', encoding="utf-8")
        (self.root / "pm").mkdir()
        (self.root / "pm/lock.json").write_text("{}", encoding="utf-8")
        (self.root / "uv.lock").write_text("fixture", encoding="utf-8")
        (self.gpt / "server.py").write_text("raise RuntimeError('must not launch')", encoding="utf-8")
        for root in (self.root, self.gpt):
            for args in (("init", "-q"), ("add", "."),
                         ("-c", "user.name=Fixture", "-c", "user.email=test@invalid", "commit", "-qm", "fixture")):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
        self.agent_python = self.prepared / "runtime/Scripts/python.exe"
        self.pair_python = self.prepared / "pair-runtime/Scripts/python.exe"
        for file in (self.agent_python, self.pair_python):
            file.parent.mkdir(parents=True)
            file.write_bytes(b"not an executable")
        (self.agent_python.parent / "hermes.exe").write_bytes(b"not an executable")
        self.agent_runtime = {"python": "fixture-python", "packages": [{"name": "hermes-agent", "version": "0.1"}, {"name": "example_pkg", "version": "1"}]}
        self.pair_runtime = {"python": "fixture-python", "packages": [{"name": "example-pkg", "version": "1"}, {"name": "mcp", "version": "2"}]}
        for name in ("pair-input.txt", "pair-requirements.txt"):
            (self.prepared / name).write_text("example-pkg==1\nmcp==2\n", encoding="utf-8")
        self.receipt = {"state": "prepared", "python": str(self.agent_python),
                        "revision": self.head(self.root), "runtime": self.agent_runtime,
                        "inputHashes": {name: self.digest(self.root / name) for name in ("pyproject.toml", "uv.lock", "pm/lock.json")},
                        "pair": {"state": "verified", "root": str(self.gpt), "python": str(self.pair_python),
                                 "revision": self.head(self.gpt), "runtime": self.pair_runtime,
                                 "resolvedRuntime": self.pair_runtime,
                                 "pyprojectSha256": self.digest(self.gpt / "pyproject.toml"),
                                 "inputSha256": self.digest(self.prepared / "pair-input.txt"),
                                 "requirementsSha256": self.digest(self.prepared / "pair-requirements.txt")}}
        self.save()
        original = subprocess.check_output
        def output(args, **kwargs):
            if args[0] == "git":
                return original(args, **kwargs)
            self.assertIn(args[0], (str(self.agent_python), str(self.pair_python)))
            self.assertEqual(args[1:5], ["-I", "-B", "-X", "utf8"])
            return json.dumps(self.actual[args[0]])
        self.actual = {str(self.agent_python): self.agent_runtime, str(self.pair_python): self.pair_runtime}
        self.output = patch.object(subprocess, "check_output", side_effect=output).start()
        self.addCleanup(patch.stopall)

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def head(root):
        return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()

    def save(self):
        (self.prepared / "preparation.json").write_text(json.dumps(self.receipt), encoding="utf-8")

    def check(self):
        return namespace["prepared_pair"](self.prepared)

    def test_verified_pair_supplies_both_exact_runtime_roots(self):
        self.assertEqual(self.check(), {"hermesPython": str(self.pair_python), "hermesServer": str(self.gpt / "server.py"),
                                      "hermesWorkingDirectory": str(self.gpt), "hermesAgentWorkingDirectory": str(self.root),
                                      "hermesAgentExe": str(self.agent_python.parent / "hermes.exe")})

    def test_changed_gpt_source_is_rejected_before_python_executes(self):
        (self.gpt / "server.py").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.check()
        self.assertTrue(all(c.args[0][0] == "git" for c in self.output.call_args_list))

    def test_wrong_gpt_commit_is_rejected(self):
        self.receipt["pair"]["revision"] = "f" * 40
        self.save()
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.check()

    def test_unverified_or_redirected_pair_is_rejected(self):
        for key, bad in (("state", "checking"), ("root", str(self.root)), ("python", str(self.agent_python))):
            with self.subTest(key=key):
                original = self.receipt["pair"][key]
                self.receipt["pair"][key] = bad
                self.save()
                with self.assertRaises(ValueError):
                    self.check()
                self.receipt["pair"][key] = original
        self.assertTrue(all(c.args[0][0] == "git" for c in self.output.call_args_list))

    def test_changed_pair_input_or_lock_is_rejected(self):
        for name in ("pair-input.txt", "pair-requirements.txt"):
            with self.subTest(name=name):
                path = self.prepared / name
                original = path.read_bytes()
                path.write_bytes(b"changed")
                with self.assertRaisesRegex(ValueError, "dependency inputs changed"):
                    self.check()
                path.write_bytes(original)

    def test_changed_runtime_packages_or_python_are_rejected(self):
        for executable in (self.agent_python, self.pair_python):
            original = self.actual[str(executable)]
            for change in ({"python": "different"}, {"packages": []},
                           {"packages": [dict(p, version="999") for p in original["packages"]]},
                           {"packages": original["packages"] + [{"name": "unexpected", "version": "1"}]}):
                with self.subTest(executable=executable, change=change):
                    self.actual[str(executable)] = dict(original, **change)
                    with self.assertRaisesRegex(ValueError, "runtime changed"):
                        self.check()
            self.actual[str(executable)] = original

    def test_package_inventory_error_is_not_a_success(self):
        previous = self.output.side_effect
        def timeout(args, **kwargs):
            if args[0] == "git":
                return previous(args, **kwargs)
            self.assertEqual(kwargs["timeout"], 30)
            raise subprocess.TimeoutExpired("inventory", 30)
        self.output.side_effect = timeout
        with self.assertRaises(subprocess.TimeoutExpired):
            self.check()

    def test_missing_agent_entrypoint_is_rejected(self):
        (self.agent_python.parent / "hermes.exe").unlink()
        with self.assertRaises(ValueError):
            self.check()

    def test_configuration_cli_keeps_code_and_home_separate_without_creating_profile(self):
        home = self.prepared.parent / "profile"
        output = io.StringIO()
        with patch.object(sys, "argv", [str(SCRIPT), "pair-config", "--home", str(home), "--prepared", str(self.prepared)]), contextlib.redirect_stdout(output):
            self.assertEqual(namespace["main"](), 0)
        self.assertEqual(json.loads(output.getvalue())["hermesHome"], str(home))
        self.assertFalse(home.exists())

    def test_configuration_cli_rejects_overlapping_home_before_inspecting_runtime(self):
        prepare = Mock()
        with patch.dict(namespace, prepared_pair=prepare):
            for home in (self.prepared, self.prepared.parent, self.prepared / "profile"):
                with self.subTest(home=home), patch.object(sys, "argv", [str(SCRIPT), "pair-config", "--home", str(home), "--prepared", str(self.prepared)]):
                    with self.assertRaisesRegex(ValueError, "must be separate"):
                        namespace["main"]()
        prepare.assert_not_called()


if __name__ == "__main__":
    unittest.main()
