"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const Database = require("better-sqlite3");

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "stack-database-e2e-"));
const write = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };
const ps = s => "'" + s.replaceAll("'", "''") + "'";
try {
  const scripts = path.join(temp, "scripts"), install = path.join(temp, "install");
  const oldRoot = path.join(temp, "old"), candidateRoot = path.join(temp, "candidate");
  // Data lives outside the watchdog installation. This must follow the runtime's
  // configuration contract, not assume InstallDir contains the SQLite database.
  const state = path.join(temp, "custom-data"), dbPath = path.join(state, "devspace.sqlite");
  fs.mkdirSync(state, { recursive: true });
  let db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.exec("CREATE TABLE marker(value TEXT); INSERT INTO marker VALUES('original');");
  db.close();
  // Exit without closing SQLite, leaving committed data in a real WAL. The
  // snapshot must preserve that data, not only the main database file.
  const walWriter = path.join(temp, "wal.cjs");
  write(walWriter, `const D=require(${JSON.stringify(require.resolve("better-sqlite3"))}); const d=new D(${JSON.stringify(dbPath)}); d.pragma('wal_autocheckpoint=0'); d.exec("INSERT INTO marker VALUES('committed-in-wal')"); process.exit(0);`);
  const walRun = spawnSync(process.execPath, [walWriter], { encoding: "utf8" });
  assert.equal(walRun.status, 0, walRun.stderr);
  assert.ok(fs.statSync(dbPath + "-wal").size > 32, "fixture contains committed WAL frames");
  const before = fs.readFileSync(dbPath);
  fs.mkdirSync(scripts, { recursive: true });
  for (const name of fs.readdirSync(__dirname).filter(n => /\.(ps1|cjs)$/.test(n) && !n.includes("test")))
    fs.copyFileSync(path.join(__dirname, name), path.join(scripts, name));
  write(path.join(scripts, "devspace-watchdog-bootstrap.ps1"), "param($Mode,$ConfigPath,$RuntimeDirectory)");
  for (const root of [oldRoot, candidateRoot]) {
    write(path.join(root, "package.json"), JSON.stringify({ name: "@waishnav/devspace", type: "module" }));
    write(path.join(root, "dist/cli.js"), "// stopped fixture runtime");
    write(path.join(root, "dist/config.js"), `export function loadConfig() { return { stateDir: ${JSON.stringify(state)} }; }`);
    write(path.join(root, "dist/db/client.js"), "import {join} from 'node:path'; export const databasePath = dir => join(dir, 'devspace.sqlite');");
    write(path.join(root, "dist/user-config.js"), `export const devspaceConfigDir = () => ${JSON.stringify(install)};`);
    for (const name of ["devspace-stack-setup.cjs", "stack-management.cjs", "stack-host-management.ps1", "install-devspace-watchdog-tray.ps1"])
      write(path.join(root, "scripts/windows", name), "// fixture");
  }
  const configPath = path.join(install, "devspace-watchdog.config.json");
  write(configPath, JSON.stringify({ stateDir: install, cliPath: path.join(oldRoot, "dist/cli.js"), nodePath: process.execPath, port: 49123, devspaceEnabled: false, custom: "keep" }));
  const configBefore = fs.readFileSync(configPath);
  const mutate = path.join(temp, "migrate.cjs");
  write(mutate, `const Database = require(${JSON.stringify(require.resolve("better-sqlite3"))}); const d=new Database(${JSON.stringify(dbPath)}); d.exec("ALTER TABLE marker ADD COLUMN new_schema TEXT; UPDATE marker SET value='candidate';"); d.close();`);
  const installer = path.join(candidateRoot, "fail-installer.ps1");
  write(installer, `param($InstallDir,$OriginalTransactionPath,[switch]$Confirm)\n& ${ps(process.execPath)} ${ps(mutate)}\nif ($LASTEXITCODE -ne 0) { throw 'fixture mutation failed' }\n[IO.File]::WriteAllText(${ps(path.join(temp, "mutated"))},'yes')\nthrow 'candidate failed after database migration'`);
  const candidatePath = path.join(temp, "candidate.json");
  write(candidatePath, JSON.stringify({ kind: "devspace", componentId: "devspace-tray-fork", action: "update", root: candidateRoot, cliPath: path.join(candidateRoot, "dist/cli.js"), installerPath: installer }));
  const harness = path.join(temp, "run.ps1");
  write(harness, `$ErrorActionPreference='Stop'
function Get-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) return @() }
function Get-CimInstance { [CmdletBinding()]param($ClassName,$Filter) return @() }
function Get-NetTCPConnection { [CmdletBinding()]param($LocalPort,$State) return @() }
try { & ${ps(path.join(scripts, "stack-activate.ps1"))} -InstallDir ${ps(install)} -CandidatePath ${ps(candidatePath)}; throw 'unexpected success' }
catch { if ($_.Exception.Message -notmatch 'original configuration restored') { throw }; Write-Output $_.Exception.Message }
`);
  const run = spawnSync("powershell.exe", ["-NoProfile", "-File", harness], { encoding: "utf8", windowsHide: true, timeout: 30000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.equal(fs.readFileSync(path.join(temp, "mutated"), "utf8"), "yes", "failure occurs after the candidate migrated the database");
  assert.deepEqual(fs.readFileSync(configPath), configBefore, "restore original runtime configuration");
  assert.deepEqual(fs.readFileSync(dbPath), before, "restore the database from before candidate migration");
  db = new Database(dbPath, { readonly: true });
  assert.deepEqual(db.prepare("SELECT * FROM marker").all(), [{ value: "original" }, { value: "committed-in-wal" }]);
  db.close();
  const safety = path.join(temp, "database-safety.ps1");
  write(safety, `$ErrorActionPreference='Stop'
. ${ps(path.join(scripts, "watchdog-install-transaction.ps1"))}
$data = ${ps(dbPath)}
$tx = Start-InstallTransaction ${ps(install)} @() @() @()
$held = [IO.File]::Open($data,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try {
  try { Add-InstallDatabaseSnapshot $tx $data; throw 'unexpected snapshot' }
  catch { if ($_.Exception.Message -eq 'unexpected snapshot') { throw } }
  if ($tx.files.Count -ne 0) { throw 'A locked database recorded a usable backup' }
} finally { $held.Dispose() }
Add-InstallDatabaseSnapshot $tx $data
$before = Get-WatchdogFileSha256 $data
[IO.File]::WriteAllText($tx.files[0].backup,'corrupt')
try { Undo-InstallTransaction $tx; throw 'unexpected restore' }
catch { if ($_.Exception.Message -notmatch 'missing or corrupt') { throw } }
if ((Get-WatchdogFileSha256 $data) -ne $before) { throw 'Corrupt backup changed live bytes' }
$absent = Join-Path ${ps(state)} 'originally-absent.sqlite'
$tx2 = Start-InstallTransaction ${ps(install)} @() @() @()
Add-InstallDatabaseSnapshot $tx2 $absent
[IO.File]::WriteAllText($absent,'candidate data')
Undo-InstallTransaction $tx2
if ([IO.File]::Exists($absent)) { throw 'Candidate database survived rollback of absent original' }
`);
  const safetyRun = spawnSync("powershell.exe", ["-NoProfile", "-File", safety], { encoding: "utf8", windowsHide: true, timeout: 30000 });
  assert.equal(safetyRun.status, 0, safetyRun.stdout + safetyRun.stderr);
  // First installation has no previous CLI, but must still preserve any existing database.
  const freshConfig = JSON.parse(configBefore);
  freshConfig.cliPath = "";
  write(configPath, JSON.stringify(freshConfig));
  write(path.join(install, "config.json"), JSON.stringify({ allowedRoots: [temp] }));
  write(path.join(install, "watchdog-tray-state.json"), JSON.stringify({ desired: { devspace: "stopped_by_user" } }));
  const firstInstall = JSON.parse(fs.readFileSync(candidatePath));
  firstInstall.action = "install";
  write(candidatePath, JSON.stringify(firstInstall));
  const freshRun = spawnSync("powershell.exe", ["-NoProfile", "-File", harness], { encoding: "utf8", windowsHide: true, timeout: 30000 });
  assert.equal(freshRun.status, 0, freshRun.stdout + freshRun.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(configPath)), freshConfig);
  console.log("Activation rollback restores both configuration and the custom-state database.");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
