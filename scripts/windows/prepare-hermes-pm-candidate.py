"""Prepare pinned Agent source and an optional reviewed patch without installing a service."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

REPOSITORY = "https://github.com/NousResearch/hermes-agent.git"
BOOTSTRAP = "import runpy,sys; sys.path.insert(0,sys.argv.pop(1)); runpy.run_module(sys.argv.pop(1),run_name='__main__')"
INVENTORY = "import importlib.metadata as m,json,sys; print(json.dumps({'python':sys.version,'packages':sorted([{'name':d.metadata['Name'],'version':d.version} for d in m.distributions()],key=lambda d:d['name'])}))"


def package_pins(runtime):
    pins = {}
    for package in runtime["packages"]:
        name, version = package["name"], package["version"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or not re.fullmatch(r"[A-Za-z0-9.+!_-]+", version):
            raise ValueError("Invalid runtime package identity")
        name = re.sub(r"[-_.]+", "-", name).lower()
        if name in pins:
            raise ValueError(f"Duplicate runtime package: {name}")
        pins[name] = version
    return pins


def prepare_pair(root, gpt, python, destination, agent_runtime, run, pair):
    project = tomllib.loads((gpt / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    if project["name"] != "hermes-gpt" or not isinstance(project["dependencies"], list):
        raise ValueError("Expected Hermes GPT dependency manifest")
    dependencies = project["dependencies"]
    if any(not isinstance(dep, str) or not dep.strip() or "\n" in dep or "\r" in dep for dep in dependencies):
        raise ValueError("Invalid GPT dependency requirement")
    pins = package_pins(agent_runtime)
    # GPT imports the explicitly pinned Agent source; do not install hermes-agent==0.0.0 from an index.
    del pins["hermes-agent"]
    requirements = destination / "pair-input.txt"
    requirements.write_text("\n".join(f"{name}=={version}" for name, version in sorted(pins.items())) +
                            "\n" + "\n".join(dependencies) + "\n", encoding="utf-8")
    pair.update(state="resolving", version=project["version"], inputSha256=hashlib.sha256(requirements.read_bytes()).hexdigest())

    def build(label, requirements):
        target = destination / label
        built = run(label, [sys.executable, "-I", "-B", "-X", "utf8", "-c", BOOTSTRAP, str(root), "pm.build_env",
                           "--requirements", str(requirements), "--out", str(target), "--python", str(python),
                           "--cache", str(destination / "cache")], root)
        executable = target / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        if not built or Path(built.splitlines()[-1]).absolute() != executable or not executable.is_file():
            raise ValueError("PM did not return the expected paired interpreter")
        runtime = json.loads(run(label + "-inventory", [str(executable), "-I", "-B", "-X", "utf8", "-c", INVENTORY], root))
        actual = package_pins(runtime)
        if "hermes-agent" in actual:
            raise ValueError("Paired dependencies must not install a second Agent distribution")
        if runtime["python"] != agent_runtime["python"] or any(actual.get(name) != version for name, version in pins.items()):
            raise ValueError("Paired runtime changed the frozen Agent Python or dependencies")
        return executable, runtime, actual

    _, resolved, resolved_pins = build("pair-resolution", requirements)
    pair["resolvedRuntime"] = resolved
    lock = destination / "pair-requirements.txt"
    lock.write_text("\n".join(f"{name}=={version}" for name, version in sorted(resolved_pins.items())) + "\n", encoding="utf-8")
    pair.update(state="rebuilding", requirementsSha256=hashlib.sha256(lock.read_bytes()).hexdigest())
    executable, runtime, actual = build("pair-runtime", lock)
    if actual != resolved_pins:
        raise ValueError("Paired rebuild does not match the complete resolved package set")
    pair.update(python=str(executable), runtime=runtime, state="checking")
    scripts = Path(__file__).resolve().parent
    pair["sourceCheck"] = json.loads(run("pair-source", [str(executable), "-I", "-B", "-X", "utf8",
        str(scripts / "stack-hermes-source.py"), str(gpt / "server.py"), str(root)], destination))
    smoke = destination / "pair-mcp.json"
    run("pair-mcp", [str(executable), "-I", "-B", "-X", "utf8", str(scripts / "stack-hermes-mcp-smoke.py"),
                     str(gpt / "server.py"), str(root), str(smoke)], destination)
    if json.loads(smoke.read_text(encoding="utf-8")).get("passed") is not True:
        raise ValueError("Paired MCP verification did not pass")
    pair.update(state="verified", mcpReport=smoke.name)


def prepare(source, revision, destination, patch=None, gpt_source=None, gpt_revision=None):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("A full lowercase commit SHA is required")
    source = source.resolve(strict=True)
    if (gpt_source is None) != (gpt_revision is None):
        raise ValueError("GPT source and full revision must be supplied together")
    if gpt_source is not None:
        if not re.fullmatch(r"[0-9a-f]{40}", gpt_revision):
            raise ValueError("A full lowercase GPT commit SHA is required")
        gpt_source = gpt_source.resolve(strict=True)
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Output must be a new directory; existing evidence is never overwritten")
    destination = destination.resolve()
    if destination.is_relative_to(source) or (gpt_source is not None and destination.is_relative_to(gpt_source)):
        raise ValueError("Output must be outside the source checkout")
    destination.mkdir()
    env = {k: v for k, v in os.environ.items()
           if k.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "LANG"}}
    home = destination / "home"
    home.mkdir()
    for key in ("HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "XDG_CONFIG_HOME",
                "XDG_DATA_HOME", "XDG_CACHE_HOME", "HERMES_HOME", "TEMP", "TMP"):
        env[key] = str(home)
    (destination / "gitconfig").touch()
    env.update(HERMES_RUNTIME_DIR=str(destination / "tools"), HERMES_DISABLE_LAZY_INSTALLS="1",
               PYTHONUTF8="1", UV_NATIVE_TLS="true", GIT_TERMINAL_PROMPT="0",
               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(destination / "gitconfig"))
    report = {"repository": REPOSITORY, "upstreamRevision": revision, "revision": revision, "state": "preparing",
              "activationEligible": False, "startedAt": datetime.now(timezone.utc).isoformat(),
              "scope": "Candidate preparation and optional isolated GPT pairing; no service activation or release promotion",
              "commands": [], "smoke": []}

    def run(label, command, cwd):
        log = destination / (label + ".log")
        entry = {"step": label, "argv": [str(arg) for arg in command], "log": log.name}
        report["commands"].append(entry)
        print(label, flush=True)
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                    stdout=output, stderr=subprocess.STDOUT,
                                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        entry["exitCode"] = result.returncode
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {log}")
        return log.read_text(encoding="utf-8", errors="replace").strip()

    try:
        def git(label, *args, cwd=source):
            return run(label, ["git", *args], cwd)

        if git("source-origin", "remote", "get-url", "origin") != REPOSITORY:
            raise ValueError("Source origin is not the official Agent repository")
        if git("source-head", "rev-parse", "HEAD") != revision:
            raise ValueError("Source HEAD does not match the requested commit")
        if git("source-status", "status", "--porcelain", "--untracked-files=no"):
            raise ValueError("Tracked source changes must be committed before preparation")
        root = destination / "payload"
        root.mkdir()
        git("init", "init", "-q", cwd=root)
        # Fetch only committed objects: ignored .env, local profiles and caches never enter the snapshot.
        git("snapshot", "-c", "protocol.file.allow=always", "fetch", "--no-tags", "--depth=1",
            str(source), revision, cwd=root)
        git("checkout", "checkout", "--detach", revision, cwd=root)
        git("origin", "remote", "add", "origin", REPOSITORY, cwd=root)
        if git("snapshot-head", "rev-parse", "HEAD", cwd=root) != revision:
            raise ValueError("Snapshot commit mismatch")
        if gpt_source is not None:
            component = json.loads(Path(__file__).with_name("stack-release-manifest.json").read_text(encoding="utf-8"))["components"]["hermes-gpt"]
            repository = "https://github.com/" + component["repository"] + ".git"
            if (git("gpt-origin", "remote", "get-url", "origin", cwd=gpt_source) != repository or
                    git("gpt-head", "rev-parse", "HEAD", cwd=gpt_source) != gpt_revision or
                    git("gpt-status", "status", "--porcelain", "--untracked-files=no", cwd=gpt_source)):
                raise ValueError("GPT origin, commit or tracked source does not match the requested candidate")
            gpt = destination / "gpt-payload"
            gpt.mkdir()
            git("gpt-init", "init", "-q", cwd=gpt)
            git("gpt-snapshot", "-c", "protocol.file.allow=always", "fetch", "--no-tags", "--depth=1",
                str(gpt_source), gpt_revision, cwd=gpt)
            git("gpt-checkout", "checkout", "--detach", gpt_revision, cwd=gpt)
            pair = report["pair"] = {"repository": repository, "revision": gpt_revision, "root": str(gpt),
                                     "pyprojectSha256": hashlib.sha256((gpt / "pyproject.toml").read_bytes()).hexdigest()}
        if patch is not None:
            patch_bytes = patch.resolve(strict=True).read_bytes()
            saved_patch = destination / "candidate.patch"
            saved_patch.write_bytes(patch_bytes)
            report["patchSha256"] = hashlib.sha256(patch_bytes).hexdigest()
            # Never silently skip conflicts or a patch already incorporated upstream.
            git("patch-check", "apply", "--check", "--index", str(saved_patch), cwd=root)
            git("patch-apply", "apply", "--index", str(saved_patch), cwd=root)
            git("patch-commit", "-c", "user.name=DevSpace candidate preparation", "-c",
                "user.email=candidate@devspace.invalid", "commit", "-qm", "Apply validation patch", cwd=root)
            revision = git("patched-head", "rev-parse", "HEAD", cwd=root)
            report["revision"] = revision
        inputs = ["pyproject.toml", "uv.lock", "pm/lock.json"]
        def hashes():
            return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in inputs}
        report["inputHashes"] = hashes()
        runtime = destination / "runtime"
        built = run("pm-build", [sys.executable, "-I", "-B", "-X", "utf8", "-c", BOOTSTRAP, str(root), "pm.build_env",
                                "--source", str(root), "--out", str(runtime),
                                "--cache", str(destination / "cache"), "--extra", "all"], root)
        python = runtime / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
        if not built or Path(built.splitlines()[-1]).absolute() != python or not python.is_file():
            raise ValueError("PM did not return the expected candidate interpreter")
        report["python"] = str(python)
        inventory = run("runtime", [str(python), "-I", "-B", "-X", "utf8", "-c", INVENTORY], root)
        report["runtime"] = json.loads(inventory)
        for label, args in (("version", ["--version"]), ("help", ["--help"]), ("gateway-help", ["gateway", "--help"])):
            output = run(label, [str(python), "-I", "-B", "-X", "utf8", "-c", BOOTSTRAP, str(root), "hermes_cli.main", *args], root)
            if not re.search(r"hermes|usage|options", output, re.IGNORECASE):
                raise ValueError(f"{label} did not return recognizable CLI output")
            report["smoke"].append({"args": args, "exitCode": 0, "log": label + ".log"})
        if gpt_source is not None:
            prepare_pair(root, gpt, python, destination, report["runtime"], run, pair)
            if (git("gpt-final-head", "rev-parse", "HEAD", cwd=gpt) != gpt_revision or
                    git("gpt-final-status", "status", "--porcelain", "--untracked-files=no", cwd=gpt)):
                raise ValueError("GPT candidate inputs changed during preparation")
        if (git("final-head", "rev-parse", "HEAD", cwd=root) != revision or
                hashes() != report["inputHashes"] or
                git("snapshot-status", "status", "--porcelain", "--untracked-files=no", cwd=root)):
            raise ValueError("Frozen candidate inputs changed during preparation")
        report["state"] = "prepared"
    except Exception as error:
        report.update(state="failed", error=str(error))
        if "pair" in report:
            report["pair"]["state"] = "failed"
        raise
    finally:
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        (destination / "preparation.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--patch", type=Path, help="Apply a reviewed patch only to the new snapshot; conflicts stop preparation")
    parser.add_argument("--gpt-source", type=Path, help="Optional pinned GPT checkout for a separate dependency rebuild and real readonly MCP check")
    parser.add_argument("--gpt-revision", help="Full GPT commit SHA; requires --gpt-source")
    args = parser.parse_args()
    try:
        prepare(args.source, args.revision, args.out, args.patch, args.gpt_source, args.gpt_revision)
    except Exception as error:
        parser.exit(1, f"{error}\n")
