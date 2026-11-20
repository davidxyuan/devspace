"""Exercise the official Windows gateway launcher with a finite, recorded child."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch


def fixture(expected):
    home = Path(os.environ["HERMES_HOME"]).resolve(strict=True)
    assert home == expected and home.parent.name.startswith("HermesLauncherTest-")
    count = len(list(home.glob("launch-*.json")))
    codes = json.loads((home / "codes.json").read_text())
    code = codes[count] if count < len(codes) else 99
    with (home / f"launch-{count + 1}.json").open("x") as output:
        json.dump({"pid": os.getpid(), "code": code, "time": time.time()}, output)
    return code


def prepare(directory, user):
    from hermes_cli import gateway_windows as windows

    def render(name, codes, owned=False):
        home = directory / name
        home.mkdir()
        (home / "codes.json").write_text(json.dumps(codes))
        if owned:
            (home / "gateway.pid").touch()
        launcher = home / "gateway.vbs"
        argv = [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--fixture", str(home)]
        with patch.object(windows, "_gateway_run_argv", return_value=argv):
            script = windows._build_gateway_vbs_script(sys.executable, str(home), str(home), "")
        launcher.write_bytes(script.encode("utf-16"))
        return launcher

    report = {}
    for name, code, owned, expected in [
        ("clean", 0, False, 0), ("fatal", 78, False, 0), ("owned", 1, True, 0),
        ("failure", 1, False, 1), ("crash", 37, False, 37), ("handoff", 75, False, 75),
    ]:
        launcher = render(name, [code], owned)
        observed = subprocess.run(["cscript.exe", "//Nologo", str(launcher)], timeout=20).returncode
        receipt = json.loads((launcher.parent / "launch-1.json").read_text())
        assert receipt["code"] == code and observed == expected, (name, receipt, observed, expected)
        report[name] = {"child": code, "launcher": observed}
    print(json.dumps(report))
    (directory / "exit-codes.json").write_text(json.dumps(report))
    launcher = render("scheduled", [37, 0])
    xml = windows._build_scheduled_task_xml(directory.name, launcher, user)
    (directory / "task.xml").write_bytes(xml.encode("utf-16"))


if __name__ == "__main__":
    # The Scheduler starts a fresh logon environment without the workflow variables.
    if sys.argv[1:2] == ["--fixture"] and len(sys.argv) == 3:
        sys.exit(fixture(Path(sys.argv[2]).resolve(strict=True)))
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.name != "nt":
        sys.exit("Requires a disposable GitHub-hosted Windows runner")
    prepared, directory = (Path(v).resolve(strict=True) for v in sys.argv[1:3])
    assert all(p.is_relative_to(Path(os.environ["RUNNER_TEMP"]).resolve()) for p in (prepared, directory))
    os.environ["HERMES_HOME"] = str(directory)
    sys.path.insert(0, str(prepared / "payload"))
    prepare(directory, sys.argv[3])
