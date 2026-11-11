"""Real Windows directory/SQLite transactions; no production profile or gateway."""
import contextlib
import ctypes
import importlib.util
import io
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("manager", Path(__file__).with_name("hermes-gateway-supervisor.py"))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gateway-profile-")
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "profile"
        self.old = self.base / "old-runtime"
        self.new = self.base / "new-runtime"
        self.old.mkdir()
        self.new.mkdir()
        self.runtime = patch.object(manager, "prepared_runtime", return_value=(self.new, Path(sys.executable)))
        self.validate_runtime = self.runtime.start()
        self.call("init", "--prepared", str(self.old))
        (self.home / "config.yaml").write_text("model: old\n", encoding="utf-8")
        (self.home / "empty").mkdir()
        (self.home / "config.yaml:notes").write_text("alternate stream", encoding="utf-8")
        with contextlib.closing(sqlite3.connect(self.home / "state.db")) as db, db:
            db.execute("create table history(message text)")
            db.execute("insert into history values ('old conversation')")
        self.control = manager.control_directory(self.home)
        self.before = manager.profile_inventory(self.home)

    def tearDown(self):
        self.runtime.stop()
        self.temp.cleanup()

    def call(self, action, *args):
        with patch.object(sys, "argv", ["manager", action, "--home", str(self.home), *args]), contextlib.redirect_stdout(io.StringIO()):
            return manager.main()

    def switch(self):
        self.call("switch", "--prepared", str(self.new))
        return manager.read(self.control / "update.json")

    def test_switch_then_full_rollback_restores_sqlite_streams_permissions_and_version(self):
        record = self.switch()
        self.assertEqual(record["phase"], "trial")
        self.assertEqual(manager.read(self.home / ".devspace-gateway.json")["prepared"], str(self.new))
        self.assertEqual((self.home / "config.yaml:notes").read_text(), "alternate stream")
        (self.home / "config.yaml").write_text("model: new\n")
        (self.home / "candidate-only").write_text("must not leak into restored profile")
        with contextlib.closing(sqlite3.connect(self.home / "state.db")) as db, db:
            db.execute("alter table history add column migration integer")
            db.execute("update history set message='changed', migration=1")
        self.assertEqual(self.call("rollback"), 0)
        self.assertEqual(manager.profile_inventory(self.home), self.before)
        self.assertFalse((self.home / "candidate-only").exists())
        with contextlib.closing(sqlite3.connect(self.home / "state.db")) as db:
            self.assertEqual(db.execute("select * from history").fetchall(), [("old conversation",)])
            self.assertEqual(db.execute("pragma integrity_check").fetchone(), ("ok",))
        self.assertTrue((self.control / record["id"] / "failed" / "candidate-only").exists())

    def test_accept_retains_backup_and_allows_a_later_switch(self):
        record = self.switch()
        self.call("accept")
        self.assertEqual(manager.profile_inventory(self.control / record["id"] / "previous"), self.before)
        self.assertEqual(manager.read(self.control / "update.json")["phase"], "accepted")
        self.call("switch", "--prepared", str(self.old))
        self.call("rollback")
        self.assertEqual(manager.read(self.home / ".devspace-gateway.json")["prepared"], str(self.new))

    def test_second_switch_is_rejected_without_overwriting_pending_record(self):
        record = self.switch()
        with self.assertRaisesRegex(RuntimeError, "requires accept or rollback"):
            self.call("switch", "--prepared", str(self.old))
        self.assertEqual(manager.read(self.control / "update.json"), record)

    def test_incomplete_job_or_live_owner_blocks_exchange(self):
        path = self.home / ".devspace-gateway.json"
        initial = manager.read(path)
        process = manager.psutil.Process()
        for changes in ({"phase": "running"}, {"runId": "interrupted", "jobActiveProcesses": None},
                        {"supervisor": {"pid": process.pid, "startTime": process.create_time()}}):
            with self.subTest(changes=changes):
                manager.write(path, dict(initial, **changes))
                before = manager.profile_inventory(self.home)
                with self.assertRaises(RuntimeError):
                    self.switch()
                self.assertEqual(manager.profile_inventory(self.home), before)
                self.assertFalse((self.control / "update.json").exists())

    def test_old_profile_schema_is_not_silently_adopted(self):
        path = self.home / ".devspace-gateway.json"
        manager.write(path, dict(manager.read(path), schema=1))
        with self.assertRaisesRegex(ValueError, "ownership mismatch"):
            self.switch()

    def test_code_inside_profile_is_rejected(self):
        nested = self.home / "runtime"
        nested.mkdir()
        with self.assertRaisesRegex(ValueError, "must be separate"):
            self.call("switch", "--prepared", str(nested))
        self.assertFalse((self.control / "update.json").exists())

    def test_hardlinked_data_is_preserved_without_copying(self):
        external = self.base / "external"
        external.write_text("external data")
        os.link(external, self.home / "linked")
        with self.assertRaisesRegex(ValueError, "Linked profile"):
            self.switch()
        self.assertEqual(external.read_text(), "external data")
        self.assertFalse((self.control / "update.json").exists())

    def test_copy_failure_preserves_original_and_can_be_rolled_back(self):
        with patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 8)):
            with self.assertRaisesRegex(RuntimeError, "copy failed"):
                self.switch()
        self.assertEqual(manager.profile_inventory(self.home), self.before)
        self.call("rollback")
        self.assertEqual(manager.read(self.control / "update.json")["phase"], "rolled_back")

    def test_interrupted_copy_blocks_run_and_rollback_without_exit_proof(self):
        with patch.object(manager.subprocess, "run", side_effect=SystemExit("copy interrupted")):
            with self.assertRaises(SystemExit):
                self.switch()
        with self.assertRaisesRegex(RuntimeError, "no exit proof"):
            self.call("rollback")
        self.validate_runtime.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "Incomplete profile exchange"):
            self.call("run")
        self.validate_runtime.assert_not_called()
        self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_real_worker_exit_between_renames_can_restore_the_original(self):
        code = """
import importlib.util, os, pathlib, sys
spec=importlib.util.spec_from_file_location('m', sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.prepared_runtime=lambda *a, **kw: None
rename=pathlib.Path.rename
def interrupt(path, target):
    rename(path, target)
    os._exit(91)
pathlib.Path.rename=interrupt
m.profile_update(pathlib.Path(sys.argv[2]), 'switch', pathlib.Path(sys.argv[3]))
"""
        child = subprocess.run([sys.executable, "-I", "-B", "-c", code, manager.__file__, str(self.home), str(self.new)],
                               capture_output=True, text=True, timeout=30,
                               creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(child.returncode, 91, child.stderr)
        self.assertFalse(self.home.exists())
        self.call("rollback")
        self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_sidecar_lock_remains_held_across_profile_rename(self):
        moved = self.base / "temporarily-moved"
        code = """
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location('m', sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with m.ownership(pathlib.Path(sys.argv[2])): pass
"""
        with manager.ownership(self.home):
            self.home.rename(moved)
            try:
                child = subprocess.run([sys.executable, "-I", "-B", "-c", code, manager.__file__, str(self.home)],
                                       capture_output=True, text=True, timeout=15,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
                self.assertNotEqual(child.returncode, 0)
                self.assertIn("Another supervisor", child.stderr)
            finally:
                moved.rename(self.home)

    def test_interruption_after_each_exchange_move_is_recoverable(self):
        original = Path.rename
        for move_number in (1, 2):
            count = 0
            def crash(path, target):
                nonlocal count
                result = original(path, target)
                count += 1
                if count == move_number:
                    raise SystemExit("simulated interruption after rename")
                return result
            with self.subTest(move_number=move_number), patch.object(Path, "rename", crash):
                with self.assertRaisesRegex(SystemExit, "interruption"):
                    self.switch()
            self.call("rollback")
            self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_interruption_after_each_rollback_move_is_recoverable(self):
        original = Path.rename
        for move_number in (1, 2):
            self.switch()
            count = 0
            def crash(path, target):
                nonlocal count
                result = original(path, target)
                count += 1
                if count == move_number:
                    raise SystemExit("simulated interruption after rename")
                return result
            with self.subTest(move_number=move_number), patch.object(Path, "rename", crash):
                with self.assertRaises(SystemExit):
                    self.call("rollback")
            self.call("rollback")
            self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_unknown_or_changed_candidate_blocks_rollback(self):
        self.switch()
        path = self.home / ".devspace-gateway.json"
        manager.write(path, dict(manager.read(path), phase="attention_required"))
        with self.assertRaisesRegex(RuntimeError, "not stopped"):
            self.call("rollback")
        self.assertEqual(manager.read(path)["phase"], "attention_required")

    def test_original_tampering_blocks_rollback(self):
        record = self.switch()
        (self.control / record["id"] / "previous" / "config.yaml:notes").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "Original profile changed"):
            self.call("rollback")
        self.assertEqual(manager.read(self.home / ".devspace-gateway.json")["prepared"], str(self.new))

    def test_open_nonsharing_file_blocks_exchange_and_preserves_original(self):
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        create = kernel.CreateFileW
        create.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p,
                           ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        create.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        # Share reads/writes but not delete, so copying can finish and rename must fail.
        handle = create(str(self.home / "config.yaml"), 0x80000000, 3, None, 3, 0, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            with self.assertRaises(OSError):
                self.switch()
            self.assertEqual(manager.profile_inventory(self.home), self.before)
        finally:
            kernel.CloseHandle(handle)
        self.call("rollback")


if __name__ == "__main__":
    unittest.main()
