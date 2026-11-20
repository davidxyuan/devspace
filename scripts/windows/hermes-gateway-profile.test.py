"""Real Windows directory/SQLite transactions; no production profile or gateway."""
import contextlib
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
from types import SimpleNamespace
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

    def test_init_preserves_a_profile_created_while_claiming_ownership(self):
        self.home = self.base / "other-profile"
        control = manager.control_directory(self.home)
        mkdir = Path.mkdir
        def concurrent_mkdir(path, *args, **kwargs):
            mkdir(path, *args, **kwargs)
            if path == control:
                mkdir(self.home)
                (self.home / "keep").write_text("existing data")
        with patch.object(Path, "mkdir", concurrent_mkdir), self.assertRaises(FileExistsError):
            self.call("init", "--prepared", str(self.new))
        self.assertEqual([p.name for p in self.home.iterdir()], ["keep"])
        self.assertEqual((self.home / "keep").read_text(), "existing data")
        self.assertFalse(control.exists())

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

    def pair_config(self, prepared):
        return {"hermesPython": str(prepared / "python.exe"), "hermesServer": str(prepared / "server.py"),
                "hermesWorkingDirectory": str(prepared), "hermesAgentWorkingDirectory": str(prepared / "agent"),
                "hermesAgentExe": str(prepared / "agent.exe")}

    def configuration(self):
        install = self.base / "installation"
        install.mkdir()
        self.config = install / "devspace-watchdog.config.json"
        self.original_config = json.dumps(dict(self.pair_config(self.old), stateDir=str(install),
                                             hermesHome=str(self.home), custom={"keep": "資料"}), indent=4).encode("utf-8")
        self.config.write_bytes(self.original_config)
        Path(str(self.config) + ":notes").write_text("config stream")
        self.addCleanup(patch.stopall)
        patch.object(manager, "prepared_pair", side_effect=self.pair_config).start()

    def test_configuration_and_profile_switch_and_restore_together(self):
        self.configuration()
        security = manager.profile_inventory(self.config.parent)[self.config.name]["security"]
        self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.assertEqual(manager.read(self.config)["hermesWorkingDirectory"], str(self.new))
        self.assertEqual(manager.read(self.config)["custom"], {"keep": "資料"})
        self.assertEqual(manager.profile_inventory(self.config.parent)[self.config.name]["security"], security)
        self.call("rollback")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(Path(str(self.config) + ":notes").read_text(), "config stream")
        self.assertEqual(manager.profile_inventory(self.config)["."]["security"], security)
        self.assertEqual(manager.profile_inventory(self.home), self.before)
        retained = list(self.config.parent.glob("*.previous/" + self.config.name))
        self.assertTrue(any(p.read_bytes() == self.original_config for p in retained))
        # Subsequent updates must retain the recorded configuration binding.
        self.switch()
        self.assertEqual(manager.read(self.config)["hermesWorkingDirectory"], str(self.new))
        self.call("accept")

    def test_configuration_copy_failure_preserves_original_metadata(self):
        self.configuration()
        before = manager.profile_inventory(self.config)
        with patch.object(manager.subprocess, "run", return_value=SimpleNamespace(returncode=8)):
            with self.assertRaisesRegex(RuntimeError, "Configuration copy failed"):
                manager.replace_configuration(self.config, b"candidate")
        self.assertEqual(manager.profile_inventory(self.config), before)

    def test_configuration_rename_failure_retains_original_and_backup(self):
        self.configuration()
        before = manager.profile_inventory(self.config)
        with patch.object(manager.os, "replace", side_effect=OSError("configuration occupied")):
            with self.assertRaisesRegex(OSError, "configuration occupied"):
                manager.replace_configuration(self.config, b"candidate")
        self.assertEqual(manager.profile_inventory(self.config), before)
        retained = list(self.config.parent.glob("*.previous/" + self.config.name))
        self.assertEqual(len(retained), 1)
        self.assertEqual(manager.profile_inventory(retained[0]), before)

    def test_wrong_configuration_is_rejected_before_profile_copy(self):
        self.configuration()
        config = json.loads(self.original_config)
        for key, value in (("hermesHome", str(self.base)), ("hermesPython", "unrelated"), ("stateDir", str(self.base))):
            with self.subTest(key=key):
                self.config.write_text(json.dumps(dict(config, **{key: value})))
                with self.assertRaises(ValueError):
                    self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
                self.assertEqual(manager.profile_inventory(self.home), self.before)
                self.assertFalse((self.control / "update.json").exists())

    def test_configuration_publish_failure_can_restore_both(self):
        self.configuration()
        with patch.object(manager, "replace_configuration", side_effect=OSError("configuration locked")):
            with self.assertRaisesRegex(OSError, "configuration locked"):
                self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.assertEqual(manager.read(self.control / "update.json")["phase"], "exchanging")
        with self.assertRaisesRegex(RuntimeError, "Incomplete profile exchange"):
            self.call("run")
        self.call("rollback")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_exit_after_configuration_publish_stays_blocked_until_rollback(self):
        self.configuration()
        original = manager.replace_configuration
        def interrupt(path, content):
            original(path, content)
            raise SystemExit("after configuration publish")
        with patch.object(manager, "replace_configuration", side_effect=interrupt):
            with self.assertRaises(SystemExit):
                self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.assertEqual(manager.read(self.config)["hermesWorkingDirectory"], str(self.new))
        with self.assertRaisesRegex(RuntimeError, "Incomplete profile exchange"):
            self.call("run")
        self.call("rollback")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_exit_between_profile_moves_restores_bound_configuration(self):
        self.configuration()
        original = Path.rename
        def interrupt(path, target):
            original(path, target)
            raise SystemExit("after profile move")
        with patch.object(Path, "rename", interrupt):
            with self.assertRaises(SystemExit):
                self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.assertFalse(self.home.exists())
        with self.assertRaises(FileExistsError):
            self.call("init", "--prepared", str(self.new))
        self.assertFalse(self.home.exists(), "Initialization must leave the rollback destination free")
        self.call("rollback")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_configuration_restore_failure_never_releases_launch_barrier(self):
        self.configuration()
        self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        with patch.object(manager, "replace_configuration", side_effect=OSError("restore locked")):
            with self.assertRaisesRegex(OSError, "restore locked"):
                self.call("rollback")
        self.assertEqual(manager.read(self.control / "update.json")["phase"], "restoring")
        with self.assertRaisesRegex(RuntimeError, "Incomplete profile exchange"):
            self.call("run")
        self.call("rollback")
        self.assertEqual(self.config.read_bytes(), self.original_config)
        self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_external_configuration_change_blocks_rollback_without_overwriting_it(self):
        self.configuration()
        self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.config.write_text('{"unknown":"preserve"}')
        before = manager.profile_inventory(self.home)
        with self.assertRaisesRegex(ValueError, "changed outside"):
            self.call("rollback")
        self.assertEqual(self.config.read_text(), '{"unknown":"preserve"}')
        self.assertEqual(manager.profile_inventory(self.home), before)

    def test_configuration_backup_corruption_blocks_profile_restore(self):
        self.configuration()
        self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        record = manager.read(self.control / "update.json")
        (self.control / record["id"] / "config-original.json").write_text("corrupt")
        before = manager.profile_inventory(self.home)
        with self.assertRaisesRegex(ValueError, "backup changed"):
            self.call("rollback")
        self.assertEqual(manager.profile_inventory(self.home), before)

    def test_trial_configuration_must_match_before_accept_or_start(self):
        self.configuration()
        self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.config.write_bytes(self.original_config)
        with self.assertRaisesRegex(ValueError, "does not select the trial"):
            self.call("accept")
        self.validate_runtime.reset_mock()
        with self.assertRaisesRegex(ValueError, "selected profile disagree"):
            self.call("run")
        self.validate_runtime.assert_not_called()

    def test_bound_configuration_cannot_be_redirected_on_next_switch(self):
        self.configuration()
        self.call("switch", "--prepared", str(self.new), "--config", str(self.config))
        self.call("accept")
        with self.assertRaisesRegex(ValueError, "bound to another"):
            self.call("switch", "--prepared", str(self.old), "--config", str(self.base / "other.json"))
        record = manager.read(self.control / "update.json")
        manager.write(self.control / "update.json", dict(record, id="../outside"))
        with self.assertRaisesRegex(ValueError, "ownership mismatch"):
            self.call("run")

    def test_settled_update_allows_unrelated_settings_but_not_runtime_redirection(self):
        self.configuration()
        for action in ("accept", "rollback"):
            target = self.new if action == "accept" else self.old
            with self.subTest(action=action):
                self.call("switch", "--prepared", str(target), "--config", str(self.config))
                self.call(action)
                record = manager.read(self.control / "update.json")
                folder = self.control / record["id"]
                config = manager.read(self.config)
                manager.write(self.config, dict(config, custom={"changed": True}))
                manager.checked_configuration(record, folder)
                self.assertEqual(manager.read(self.config)["custom"], {"changed": True})
                manager.write(self.config, dict(config, hermesServer="unrelated"))
                with self.assertRaisesRegex(ValueError, "selected profile disagree"):
                    self.call("run")
                manager.write(self.config, config)

    @unittest.skipUnless(os.environ.get('GITHUB_ACTIONS') == 'true' and
                         os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted',
                         'Distinct file-owner fixture requires the disposable elevated Windows runner')
    def test_nondefault_file_owner_survives_switch_and_rollback(self):
        path = self.home / 'config.yaml'
        original = manager.profile_inventory(self.home)['config.yaml']['security']
        command = "$ErrorActionPreference='Stop'; $a=Get-Acl -LiteralPath $env:DEVSPACE_OWNER_FIXTURE; $a.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User); Set-Acl -LiteralPath $env:DEVSPACE_OWNER_FIXTURE -AclObject $a"
        # Windows PowerShell must load its own modules, not pwsh's inherited module path.
        env = {key: value for key, value in os.environ.items() if key.upper() != 'PSMODULEPATH'}
        result = subprocess.run([str(Path(os.environ['SYSTEMROOT']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
                                 '-NoLogo', '-NoProfile', '-Command', command], timeout=20,
                                env={**env, 'DEVSPACE_OWNER_FIXTURE': str(path)},
                                creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.before = manager.profile_inventory(self.home)
        changed = self.before['config.yaml']['security']
        self.assertNotEqual(changed, original, 'Fixture must use an owner different from new files')
        self.switch()
        self.assertEqual(manager.profile_inventory(self.home)['config.yaml']['security'], changed)
        self.call('rollback')
        self.assertEqual(manager.profile_inventory(self.home), self.before)

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

    def test_ntfs_internal_directory_bit_does_not_change_inventory(self):
        original = Path.lstat

        def ntfs_stat(path, *args, **kwargs):
            info = original(path, *args, **kwargs)
            if not info.st_file_attributes & 16:
                return info
            return SimpleNamespace(st_file_attributes=info.st_file_attributes | 0x10000000,
                                   st_mode=info.st_mode, st_nlink=info.st_nlink,
                                   st_mtime_ns=info.st_mtime_ns)

        with patch.object(Path, "lstat", ntfs_stat):
            self.assertEqual(manager.profile_inventory(self.home), self.before)

    def test_changed_backup_attributes_block_rollback(self):
        record = self.switch()
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        get, set_attributes = kernel.GetFileAttributesW, kernel.SetFileAttributesW
        get.argtypes = [ctypes.c_wchar_p]
        get.restype = ctypes.c_ulong
        set_attributes.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong]
        set_attributes.restype = ctypes.c_int
        for name, bit in (("empty", 2), ("config.yaml", 1)):  # Hidden directory and read-only file.
            path = str(self.control / record["id"] / "previous" / name)
            before = get(path)
            with self.subTest(name=name):
                self.assertTrue(set_attributes(path, before | bit))
                try:
                    with self.assertRaisesRegex(ValueError, "Original profile changed"):
                        self.call("rollback")
                finally:
                    self.assertTrue(set_attributes(path, before))
        self.call("rollback")
        self.assertEqual(manager.profile_inventory(self.home), self.before)

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
