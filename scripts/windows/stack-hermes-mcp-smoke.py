"""Verify installed GPT/Agent sources through readonly MCP in a disposable profile."""
import asyncio
import argparse
from datetime import datetime, timezone
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server', type=Path)
    parser.add_argument('agent', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--url')
    parser.add_argument('--home', type=Path)
    args = parser.parse_args()
    if bool(args.url) != bool(args.home):
        parser.error('--url and --home must be supplied together')
    if args.url:
        url = urlsplit(args.url)
        if (url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port or
                url.path != '/mcp' or url.username or url.password or url.query or url.fragment):
            raise ValueError('Only an explicit loopback MCP test endpoint is supported')
    server = args.server.resolve(strict=True)
    if server.name != "server.py":
        raise ValueError("Expected the installed server.py entry point")
    agent = args.agent.resolve(strict=True)
    output = args.output
    record = {"checkedAt": datetime.now(timezone.utc).isoformat(), "python": sys.executable,
              "server": str(server), "agent": str(agent), "calls": [],
              "passed": False, "pid": os.getpid(),
              "scope": "Isolated stdio MCP; not a deployed connector or ChatGPT web"}

    def checkpoint(stage):
        # A native exit can bypass finally. Keep the last completed boundary on disk,
        # with passed=False until calls, transport shutdown and profile cleanup finish.
        record.update(stage=stage, updatedAt=datetime.now(timezone.utc).isoformat())
        pending = output.with_suffix(".pending.json")
        pending.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        pending.replace(output)

    async def verify(session, fixture, expected_home):
        checkpoint('initializing')
        record['initialize'] = (await session.initialize()).model_dump(mode='json')
        checkpoint('listing-tools')
        names = {tool.name for tool in (await session.list_tools()).tools}
        record['toolCount'] = len(names)
        assert {'hermes_operator_status', 'hermes_read_file'} <= names
        for name, arguments in (('hermes_operator_status', {}),
                ('hermes_read_file', {'path': str(fixture), 'offset': 1, 'limit': 2})):
            checkpoint('calling:' + name)
            result = await session.call_tool(name, arguments)
            protocol_result = result.model_dump(mode='json', by_alias=True)
            record['calls'].append({'tool': name, 'result': protocol_result})
            assert not protocol_result.get('isError'), f'{name} MCP error'
            content = '\n'.join(c.text for c in result.content if c.type == 'text')
            if name == 'hermes_operator_status':
                status = json.loads(content)
                assert Path(status['hermes_agent_root']).resolve() == agent, status
                assert Path(status['hermes_gpt_project_path']).resolve() == server.parent, status
                assert Path(status['default_hermes_root']).resolve() == expected_home, status
                assert Path(status['audit_log_path']).resolve() == expected_home / 'logs' / 'hermes_gpt_operator_audit.jsonl', status
                assert not status.get('import_error'), status
                assert status['success'] and status['level'] == 'read_only' and not status['owner_active'], status
            else:
                assert 'candidate-mcp-read-ok' in content and 'second-line' in content, content
            checkpoint('verified:' + name)

    try:
        checkpoint("importing-mcp")
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client

        record["packages"] = sorted([{"name": d.metadata["Name"], "version": d.version}
                                      for d in importlib.metadata.distributions()], key=lambda d: d["name"])
        checkpoint("creating-profile")
        with tempfile.TemporaryDirectory(prefix="hermes-installed-mcp-") as temporary:
            fixture = Path(temporary) / "read-only-probe.txt"
            fixture.write_text("candidate-mcp-read-ok\nsecond-line\n", encoding="utf-8")
            if args.url:
                from mcp.client.streamable_http import streamable_http_client
                record.update(scope='Readonly loopback HTTP MCP against an already running test server; not a deployed connector or ChatGPT web',
                              url=args.url, home=str(args.home.resolve(strict=True)))
                async with asyncio.timeout(90):
                    async with streamable_http_client(args.url) as (read, write):
                        async with ClientSession(read, write) as session:
                            await verify(session, fixture, args.home.resolve(strict=True))
                record['passed'] = True
                checkpoint('complete')
                return
            env = {k: v for k, v in os.environ.items() if k.upper() in
                   ("PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP")}
            env.update({k: temporary for k in ("HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA",
                                             "XDG_CONFIG_HOME", "XDG_DATA_HOME", "HERMES_HOME")})
            env.update(HERMES_AGENT_ROOT=str(agent), HERMES_DISABLE_LAZY_INSTALLS="1", PYTHONUTF8="1")
            params = StdioServerParameters(command=sys.executable, args=["-I", "-B", "-X", "utf8", "-c",
                "import sys; sys.path.insert(0, sys.argv[1]); import server; server.main([])", str(server.parent)],
                env=env, cwd=temporary)
            async with asyncio.timeout(90):
                with output.with_suffix(".stderr.log").open("w", encoding="utf-8") as errors:
                    checkpoint("starting-server")
                    async with stdio_client(params, errlog=errors) as (read, write):
                        async with ClientSession(read, write) as session:
                            await verify(session, fixture, Path(temporary).resolve())
                        checkpoint("stopping-server")
            checkpoint("removing-profile")
        record["passed"] = True
        checkpoint("complete")
    except BaseException as error:
        record.update(passed=False, error=repr(error))
        raise
    finally:
        checkpoint(record.get("stage", "failed"))


if __name__ == "__main__":
    asyncio.run(main())
