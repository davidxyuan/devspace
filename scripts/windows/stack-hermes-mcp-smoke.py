"""Verify installed GPT/Agent sources through readonly MCP in a disposable profile."""
import asyncio
from datetime import datetime, timezone
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    server = Path(sys.argv[1]).resolve(strict=True)
    if server.name != "server.py":
        raise ValueError("Expected the installed server.py entry point")
    agent = Path(sys.argv[2]).resolve(strict=True)
    output = Path(sys.argv[3])
    record = {"checkedAt": datetime.now(timezone.utc).isoformat(), "python": sys.executable,
              "server": str(server), "agent": str(agent), "calls": [],
              "scope": "Isolated stdio MCP; not a deployed connector or ChatGPT web"}
    try:
        with tempfile.TemporaryDirectory(prefix="hermes-installed-mcp-") as temporary:
            fixture = Path(temporary) / "read-only-probe.txt"
            fixture.write_text("candidate-mcp-read-ok\nsecond-line\n", encoding="utf-8")
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
                    async with stdio_client(params, errlog=errors) as (read, write):
                        async with ClientSession(read, write) as session:
                            record["initialize"] = (await session.initialize()).model_dump(mode="json")
                            names = {tool.name for tool in (await session.list_tools()).tools}
                            assert {"hermes_operator_status", "hermes_read_file"} <= names
                            for name, args in (("hermes_operator_status", {}),
                                    ("hermes_read_file", {"path": str(fixture), "offset": 1, "limit": 2})):
                                result = await session.call_tool(name, args)
                                protocol_result = result.model_dump(mode="json", by_alias=True)
                                record["calls"].append({"tool": name, "result": protocol_result})
                                assert not protocol_result.get("isError"), f"{name} MCP error"
                                content = "\n".join(c.text for c in result.content if c.type == "text")
                                if name == "hermes_operator_status":
                                    status = json.loads(content)
                                    assert Path(status["hermes_agent_root"]).resolve() == agent, status
                                    assert Path(status["hermes_gpt_project_path"]).resolve() == server.parent, status
                                    assert not status.get("import_error"), status
                                    assert status["success"] and status["level"] == "read_only" and not status["owner_active"], status
                                else:
                                    assert "candidate-mcp-read-ok" in content and "second-line" in content, content
                            record["toolCount"] = len(names)
            record["packages"] = sorted([{"name": d.metadata["Name"], "version": d.version}
                                          for d in importlib.metadata.distributions()], key=lambda d: d["name"])
            record["passed"] = True
    except BaseException as error:
        record.update(passed=False, error=repr(error))
        raise
    finally:
        output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    asyncio.run(main())
