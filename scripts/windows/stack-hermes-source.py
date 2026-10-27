"""Check actual GPT/Agent imports in a bounded process with disposable user data."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(server_path, agent_root):
    sys.path.insert(0, str(server_path.parent))
    spec = importlib.util.spec_from_file_location('server', server_path)
    server = importlib.util.module_from_spec(spec)
    sys.modules['server'] = server
    spec.loader.exec_module(server)
    server.require_imports()
    if Path(server.HERMES_ROOT).resolve() != agent_root:
        raise RuntimeError('Hermes GPT selected a different Agent source.')
    modules = {}
    for name in ('file_tools', 'memory_tool', 'terminal_tool'):
        module_path = Path(getattr(server, name).__file__).resolve(strict=True)
        if not module_path.is_relative_to(agent_root):
            raise RuntimeError(f'{name} was loaded outside the selected Agent source.')
        modules[name] = str(module_path)
    # Matching metadata alone is insufficient: legacy discovery can pick another home in production.
    os.environ['HERMES_AGENT_ROOT'] = ''
    try:
        server.find_hermes_root()
    except RuntimeError:
        pass
    else:
        raise RuntimeError('Hermes GPT does not reject an invalid explicit Agent source.')
    print(json.dumps({'agentRoot': str(agent_root), 'server': str(server_path), 'modules': modules}))


def main():
    server_path, agent_root = (Path(value) for value in sys.argv[1:3])
    if not server_path.is_absolute() or not agent_root.is_absolute():
        raise RuntimeError('Hermes server and Agent source paths must be absolute.')
    server_path = server_path.resolve(strict=True)
    agent_root = agent_root.resolve(strict=True)
    if len(sys.argv) == 4 and sys.argv[3] == '--child':
        check(server_path, agent_root)
        return
    with tempfile.TemporaryDirectory(prefix='hermes-source-probe-') as data:
        # Do not inherit user auth, owner gates, PYTHONPATH or a real Hermes profile.
        env = {key: value for key, value in os.environ.items()
               if key.upper() in ('PATH', 'SYSTEMROOT', 'WINDIR', 'COMSPEC', 'PATHEXT', 'TEMP', 'TMP', 'LANG')}
        env.update({key: data for key in ('HOME', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'HERMES_HOME')})
        env['HERMES_AGENT_ROOT'] = str(agent_root)
        env['HERMES_DISABLE_LAZY_INSTALLS'] = '1'
        # Files avoid an unbounded pipe drain if an importing module leaves descendants alive.
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            result = subprocess.run(
                [sys.executable, '-I', '-B', '-X', 'utf8', str(Path(__file__).resolve()), str(server_path), str(agent_root), '--child'],
                cwd=data, env=env, stdout=stdout, stderr=stderr, timeout=30,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
            )
            if result.returncode:
                stderr.seek(max(0, stderr.tell() - 4000))
                raise RuntimeError('Hermes source/import preflight failed: ' + stderr.read().decode('utf-8', errors='replace'))
            # Agent imports may log to stdout. Only the final verified record is returned.
            stdout.seek(max(0, stdout.tell() - 65536))
            print(json.dumps(json.loads(stdout.read().decode('utf-8').strip().splitlines()[-1])))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        sys.exit(str(error))
