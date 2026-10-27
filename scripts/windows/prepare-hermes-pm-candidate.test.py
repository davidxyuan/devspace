"""Exercise the release-preparation CLI with a local Git/PM fixture; no network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("prepare-hermes-pm-candidate.py")


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

    def prepare(self, revision=None, patch=None):
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--source", str(self.source),
                               "--revision", revision or self.revision, "--out", str(self.out),
                               *(["--patch", str(patch)] if patch else [])],
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


if __name__ == "__main__":
    unittest.main()
