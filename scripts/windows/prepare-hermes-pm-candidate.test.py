"""Exercise the release-preparation CLI with a local Git/PM fixture; no network."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name("prepare-hermes-pm-candidate.py")
SPEC = importlib.util.spec_from_file_location("preparation", SCRIPT)
PREPARATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARATION)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pm-preparation-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "來源 with spaces"
        self.source.mkdir()
        (self.source / ".gitattributes").write_text("* text eol=lf\n", encoding="utf-8")
        self.out = self.base / "候選 with spaces"
        (self.source / "pm").mkdir()
        (self.source / "hermes_cli").mkdir()
        for name in ("pm/__init__.py", "hermes_cli/__init__.py"):
            (self.source / name).write_text("", encoding="utf-8")
        for name in ("pm/lock.json", "uv.lock", "pyproject.toml"):
            (self.source / name).write_text("{}", encoding="utf-8")
        (self.source / "pm/build_env.py").write_text('''
import argparse, os, pathlib, venv
p = argparse.ArgumentParser()
p.add_argument('--source'); p.add_argument('--out'); p.add_argument('--cache')
p.add_argument('--extra')
a = p.parse_args()
assert a.extra == 'all'
assert not any(k in os.environ for k in ('OPENAI_API_KEY', 'HERMES_OWNER_ENABLED', 'PYTHONPATH'))
assert pathlib.Path(os.environ['HERMES_HOME']).parent == pathlib.Path(a.out).parent
assert not pathlib.Path('.env').exists()
assert not pathlib.Path('untracked.txt').exists()
venv.EnvBuilder(with_pip=False).create(a.out)
print(pathlib.Path(a.out) / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python'))
''', encoding="utf-8")
        (self.source / "hermes_cli/main.py").write_text("print('Hermes fixture help')\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/NousResearch/hermes-agent.git")
        self.git("add", ".")
        self.commit()
        (self.source / ".env").write_text("DO_NOT_COPY=secret", encoding="utf-8")
        (self.source / "untracked.txt").write_text("preserve", encoding="utf-8")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True).strip()

    def commit(self):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.revision = self.git("rev-parse", "HEAD")

    def prepare(self, revision=None, patch=None, extra=()):
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--source", str(self.source),
                               "--revision", revision or self.revision, "--out", str(self.out),
                               *(["--patch", str(patch)] if patch else []), *extra],
                              env={**os.environ, "OPENAI_API_KEY": "fixture-never-inherit",
                                   "HERMES_OWNER_ENABLED": "1", "PYTHONPATH": str(self.base)},
                              text=True, capture_output=True)

    def candidate_patch(self):
        cli = self.source / "hermes_cli/main.py"
        original = cli.read_bytes()
        cli.write_text("print('Hermes patched fixture help')\n", encoding="utf-8")
        patch = self.base / "candidate.patch"
        patch.write_bytes(subprocess.check_output(
            ["git", "-C", str(self.source), "diff", "--binary", "HEAD"]))
        cli.write_bytes(original)
        return patch

    def test_patch_is_applied_only_to_snapshot_and_records_exact_provenance(self):
        patch = self.candidate_patch()
        result = self.prepare(patch=patch)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["upstreamRevision"], self.revision)
        self.assertNotEqual(report["revision"], self.revision)
        self.assertEqual(report["patchSha256"], hashlib.sha256(patch.read_bytes()).hexdigest())
        self.assertEqual((self.out / "candidate.patch").read_bytes(), patch.read_bytes())
        self.assertIn("patched", (self.out / "payload/hermes_cli/main.py").read_text())
        self.assertNotIn("patched", (self.source / "hermes_cli/main.py").read_text())
        self.assertEqual(self.git("rev-parse", "HEAD"), self.revision)
        self.assertFalse(report["activationEligible"])
        parent = subprocess.check_output(["git", "-C", str(self.out / "payload"), "rev-parse", "HEAD^"], text=True).strip()
        self.assertEqual(parent, self.revision)

    def test_patch_conflict_stops_before_pm_build_and_preserves_source(self):
        patch = self.candidate_patch()
        cli = self.source / "hermes_cli/main.py"
        cli.write_text("print('Hermes changed upstream')\n", encoding="utf-8")
        self.git("add", "hermes_cli/main.py")
        self.commit()
        result = self.prepare(patch=patch)
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertIn("patch-check failed", report["error"])
        self.assertFalse((self.out / "runtime").exists())
        self.assertNotIn("pm-build", [c["step"] for c in report["commands"]])
        self.assertEqual(cli.read_text(), "print('Hermes changed upstream')\n")

    def test_fixed_snapshot_builds_and_records_non_activatable_runtime(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((self.out / "preparation.json").read_text(encoding="utf-8"))
        self.assertEqual(report["state"], "prepared")
        self.assertEqual(report["revision"], self.revision)
        self.assertFalse(report["activationEligible"])
        self.assertTrue(Path(report["python"]).is_file())
        self.assertEqual(len(report["smoke"]), 3)
        self.assertIn("uv.lock", report["inputHashes"])
        self.assertFalse((self.out / "candidate.json").exists())
        self.assertEqual((self.source / "untracked.txt").read_text(), "preserve")

    def test_wrong_commit_is_rejected_before_build(self):
        result = self.prepare("1" * 40)
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertFalse(report["activationEligible"])
        self.assertFalse((self.out / "payload").exists())

    def test_existing_output_is_preserved(self):
        self.out.mkdir()
        marker = self.out / "preparation.json"
        marker.write_text("existing evidence")
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "existing evidence")

    def test_gpt_source_requires_revision_before_creating_output(self):
        result = self.prepare(extra=["--gpt-source", str(self.source)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("supplied together", result.stderr)
        self.assertFalse(self.out.exists())

    def test_gpt_origin_is_checked_before_pm_build(self):
        result = self.prepare(extra=["--gpt-source", str(self.source), "--gpt-revision", self.revision])
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertIn("GPT origin", report["error"])
        self.assertNotIn("pm-build", [step["step"] for step in report["commands"]])

    def test_gpt_snapshot_excludes_local_data_and_rejects_mutation(self):
        gpt = self.base / "GPT 來源"
        gpt.mkdir()
        (gpt / ".gitattributes").write_text("* text eol=lf\n", encoding="utf-8")
        (gpt / "pyproject.toml").write_text('[project]\nname="hermes-gpt"\nversion="0.14.0"\ndependencies=[]\n')
        for command in (["init", "-q"], ["remote", "add", "origin", "https://github.com/davidxyuan/hermes-gpt.git"],
                        ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]):
            subprocess.run(["git", "-C", str(gpt), *command], check=True, capture_output=True)
        revision = subprocess.check_output(["git", "-C", str(gpt), "rev-parse", "HEAD"], text=True).strip()
        (gpt / ".env").write_text("secret-do-not-copy")

        def mutate_snapshot(root, snapshot, *args):
            self.assertFalse((snapshot / ".env").exists())
            self.assertNotEqual(snapshot, gpt)
            (snapshot / "pyproject.toml").write_text("changed")

        with mock.patch.object(PREPARATION, "prepare_pair", side_effect=mutate_snapshot):
            with self.assertRaisesRegex(ValueError, "GPT candidate inputs changed"):
                PREPARATION.prepare(self.source, self.revision, self.out, gpt_source=gpt, gpt_revision=revision)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertFalse(report["activationEligible"])
        self.assertIn("hermes-gpt", (gpt / "pyproject.toml").read_text())
        self.assertEqual((gpt / ".env").read_text(), "secret-do-not-copy")

    def test_failed_pm_build_is_recorded_and_does_not_run_smoke(self):
        (self.source / "pm/build_env.py").write_text("raise SystemExit(37)\n")
        self.git("add", "pm/build_env.py")
        self.commit()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertEqual(report["commands"][-1]["exitCode"], 37)
        self.assertEqual(report["smoke"], [])
        self.assertFalse(report["activationEligible"])

    def test_smoke_failure_cannot_mark_prepared(self):
        (self.source / "hermes_cli/main.py").write_text("raise SystemExit(38)\n")
        self.git("add", "hermes_cli/main.py")
        self.commit()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertEqual(report["commands"][-1]["exitCode"], 38)
        self.assertFalse(report["activationEligible"])

    def test_source_mutation_during_smoke_cannot_mark_prepared(self):
        (self.source / "hermes_cli/main.py").write_text(
            "from pathlib import Path\nPath('uv.lock').write_text('changed')\nprint('Hermes fixture')\n")
        self.git("add", "hermes_cli/main.py")
        self.commit()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertIn("inputs changed", report["error"])
        self.assertEqual((self.source / "uv.lock").read_text(), "{}")

    def test_changed_commit_with_clean_files_cannot_mark_prepared(self):
        (self.source / "hermes_cli/main.py").write_text(
            "import subprocess\nsubprocess.run(['git','-c','user.name=Fixture','-c',"
            "'user.email=fixture@example.invalid','commit','--allow-empty','-qm','changed'],check=True)\n"
            "print('Hermes fixture')\n")
        self.git("add", "hermes_cli/main.py")
        self.commit()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.out / "preparation.json").read_text())
        self.assertEqual(report["state"], "failed")
        self.assertFalse(report["activationEligible"])


class PairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pm-pair-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.gpt = self.base / "gpt"
        self.gpt.mkdir()
        (self.gpt / "pyproject.toml").write_text(
            '[project]\nname="hermes-gpt"\nversion="0.14.0"\ndependencies=["mcp[cli]>=2"]\n')
        self.agent = {"python": "fixture", "packages": [{"name": "hermes-agent", "version": "0.0.0"},
                                                       {"name": "mcp", "version": "2.0.0"}]}
        self.resolved = {"python": "fixture", "packages": [{"name": "mcp", "version": "2.0.0"},
                                                          {"name": "new-extra", "version": "1.2.3"}]}
        self.rebuilt = json.loads(json.dumps(self.resolved))
        self.mcp_passed = True
        self.calls = []
        self.pair = {}

    def run_step(self, label, command, cwd):
        self.calls.append(label)
        if label in ("pair-resolution", "pair-runtime"):
            # The PM fixture consumes the actual requirements handed to the external builder.
            requirements = Path(command[command.index("--requirements") + 1]).read_text()
            self.assertIn("mcp==2.0.0", requirements)
            self.assertNotIn("hermes-agent", requirements)
            self.assertEqual("new-extra==1.2.3" in requirements, label == "pair-runtime")
            executable = self.base / label / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
            executable.parent.mkdir(parents=True)
            executable.touch()
            return str(executable)
        if label.endswith("-inventory"):
            return json.dumps(self.resolved if label == "pair-resolution-inventory" else self.rebuilt)
        if label == "pair-source":
            return json.dumps({"agentRoot": str(self.base / "agent"), "server": str(self.gpt / "server.py")})
        if label == "pair-mcp":
            Path(command[-1]).write_text(json.dumps({"passed": self.mcp_passed}))
            return ""
        self.fail(label)

    def prepare_pair(self):
        PREPARATION.prepare_pair(self.base / "agent", self.gpt, Path(sys.executable),
                                 self.base, self.agent, self.run_step, self.pair)

    def test_complete_resolved_set_is_rebuilt_before_real_checks(self):
        self.prepare_pair()
        self.assertEqual(self.pair["state"], "verified")
        self.assertEqual((self.base / "pair-requirements.txt").read_text(), "mcp==2.0.0\nnew-extra==1.2.3\n")
        self.assertEqual(self.calls[-2:], ["pair-source", "pair-mcp"])
        self.assertEqual(self.pair["requirementsSha256"], hashlib.sha256((self.base / "pair-requirements.txt").read_bytes()).hexdigest())

    def test_agent_version_drift_fails_before_rebuild(self):
        self.resolved["packages"][0]["version"] = "2.1.0"
        with self.assertRaisesRegex(ValueError, "frozen Agent"):
            self.prepare_pair()
        self.assertNotIn("pair-runtime", self.calls)

    def test_new_dependency_drift_fails_before_smoke(self):
        self.rebuilt["packages"][1]["version"] = "9.0"
        with self.assertRaisesRegex(ValueError, "complete resolved package set"):
            self.prepare_pair()
        self.assertNotIn("pair-source", self.calls)

    def test_unexpected_rebuilt_dependency_fails_before_smoke(self):
        self.rebuilt["packages"].append({"name": "unexpected", "version": "1"})
        with self.assertRaisesRegex(ValueError, "complete resolved package set"):
            self.prepare_pair()
        self.assertNotIn("pair-source", self.calls)

    def test_unsuccessful_mcp_receipt_cannot_mark_verified(self):
        self.mcp_passed = False
        with self.assertRaisesRegex(ValueError, "MCP verification"):
            self.prepare_pair()
        self.assertNotEqual(self.pair["state"], "verified")

    def test_duplicate_normalized_package_is_rejected(self):
        self.resolved["packages"] += [{"name": "new_extra", "version": "1.2.3"}]
        with self.assertRaisesRegex(ValueError, "Duplicate runtime package"):
            self.prepare_pair()

    def test_pair_cannot_silently_install_another_agent(self):
        self.resolved["packages"].append({"name": "hermes-agent", "version": "0.0.0"})
        with self.assertRaisesRegex(ValueError, "second Agent"):
            self.prepare_pair()


if __name__ == "__main__":
    unittest.main()
