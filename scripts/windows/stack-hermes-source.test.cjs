"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const python = execFileSync("where.exe", ["python.exe"], { encoding: "utf8" }).trim().split(/\r?\n/)[0];
const root = fs.mkdtempSync(path.join(os.tmpdir(), "hermes-source-test-"));
try {
  const agent = path.join(root, "agent"), server = path.join(root, "server.py"), home = path.join(root, "real-home");
  fs.mkdirSync(agent); fs.mkdirSync(home);
  const code = `import os, types\nfrom pathlib import Path\ndef find_hermes_root():\n    value=os.environ['HERMES_AGENT_ROOT']\n    if not value: raise RuntimeError('invalid explicit source')\n    return Path(value).resolve()\nHERMES_ROOT=find_hermes_root()\nfor name in ('file_tools','memory_tool','terminal_tool'):\n    globals()[name]=types.SimpleNamespace(__file__=str(HERMES_ROOT/(name+'.py')))\ndef require_imports(): pass\nPath(os.environ['HERMES_HOME'],'import-created').touch()\nassert os.environ['USERPROFILE'] != ${JSON.stringify(home)}\nassert 'HERMES_GPT_OWNER_ACTIVE' not in os.environ\n`;
  for (const name of ["file_tools", "memory_tool", "terminal_tool"]) fs.writeFileSync(path.join(agent, name + ".py"), "");
  const run = () => spawnSync(python, [path.join(__dirname, "stack-hermes-source.py"), server, agent], { encoding: "utf8", timeout: 40000, windowsHide: true, env: { ...process.env, HERMES_HOME: home, USERPROFILE: home, HERMES_GPT_OWNER_ACTIVE: "1" } });
  fs.writeFileSync(server, code + "\nimport sys\nassert sys.dont_write_bytecode\nassert os.environ['HERMES_DISABLE_LAZY_INSTALLS']=='1'\n");
  let result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).agentRoot.toLowerCase(), fs.realpathSync.native(agent).toLowerCase());
  assert.deepEqual(fs.readdirSync(home), [], "probe touched real user data");
  fs.writeFileSync(server, code + "\ndef find_hermes_root(): return HERMES_ROOT\n");
  result = run();
  assert.notEqual(result.status, 0, "legacy discovery must not pass just because it found the same root");
  assert.match(result.stderr, /does not reject an invalid explicit Agent source/);
  fs.writeFileSync(server, code + "\nfile_tools.__file__=__file__\n");
  result = run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /outside the selected Agent source/);
  fs.writeFileSync(server, code + "\ndef require_imports(): raise RuntimeError('missing Agent dependency')\n");
  result = run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing Agent dependency/);
  const done = path.join(root, 'descendant-finished');
  const child = `import os,pathlib,time; time.sleep(1); pathlib.Path(${JSON.stringify(done)}).write_text(str(os.getpid()))`;
  fs.writeFileSync(server, `import subprocess,sys,time\nsubprocess.Popen([sys.executable,'-c',${JSON.stringify(child)}],cwd=${JSON.stringify(agent)})\ntime.sleep(10)\n`);
  const timeoutHarness = `import importlib.util,subprocess,sys\nspec=importlib.util.spec_from_file_location('probe',sys.argv[1]); probe=importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)\noriginal=subprocess.run\ndef short(*args,**kwargs):\n    assert kwargs['timeout']==30 and kwargs['stdout']!=subprocess.PIPE and kwargs['stderr']!=subprocess.PIPE\n    kwargs['timeout']=0.5\n    return original(*args,**kwargs)\nsubprocess.run=short\nsys.argv=sys.argv[1:]\nprobe.main()\n`;
  const started = Date.now();
  result = spawnSync(python, ['-B', '-c', timeoutHarness, path.join(__dirname, 'stack-hermes-source.py'), server, agent], { encoding: 'utf8', timeout: 5000, windowsHide: true });
  // Let only this fixture descendant finish naturally before deleting its temporary directory.
  const deadline = Date.now() + 3000;
  while (!fs.existsSync(done) && Date.now() < deadline) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /TimeoutExpired/);
  assert(fs.existsSync(done) && Date.now() - started < 4500, 'bounded probe or natural fixture cleanup failed');
  const childPid = Number(fs.readFileSync(done, 'utf8'));
  assert(Number.isSafeInteger(childPid) && childPid > 0);
  // The completion marker precedes process exit and release of the agent working directory.
  const waited = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
    `$ErrorActionPreference='Stop'; Get-Process -Id ${childPid} -ErrorAction SilentlyContinue | Wait-Process -Timeout 3; exit 0`],
    { encoding: 'utf8', timeout: 5000, windowsHide: true });
  assert.equal(waited.status, 0, waited.stderr);
  console.log("Hermes source probe: explicit selection, imports, fail-closed discovery and isolated data passed.");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
