# DevSpace Watchdog Tray and Control Center

The DevSpace Watchdog is an opt-in Windows lifecycle and control layer for an
existing DevSpace, Hermes, MCP Router, and ngrok installation. It replaces the
steady-state, every-minute PowerShell poller with one persistent notification
area process and an internal timer.

This repository feature does not install itself. Building or testing the
repository does not register HKCU Run, start the Tray, disable a Scheduled Task,
or change an endpoint. Deployment requires an explicit installer command.

## 1. Architecture

```text
Windows logon
  -> HKCU Run
  -> wscript.exe //B //NoLogo
  -> run-devspace-watchdog-tray-hidden.vbs
  -> Windows PowerShell -STA (one persistent process)
       -> WinForms NotifyIcon
       -> internal local/public health timers
       -> conservative per-service recovery
       -> TCP listener bound only to 127.0.0.1
            -> DevSpace Control Center
```

The health timer does not launch PowerShell, `cmd.exe`, or another console host.
Managed processes are launched only for an explicit start/restart or a confirmed
recovery. Those launches are hidden and use fixed executable paths plus validated
arguments.

Implementation files:

- `watchdog-control-core.ps1`: validation, state, health, recovery, controls,
  configuration impact, backup, and rollback.
- `devspace-watchdog-tray.ps1`: single-instance Tray, timers, loopback HTTP
  handling, menus, and dashboard API.
- `devspace-control-center.html`: local Control Center UI.
- `run-devspace-watchdog-tray-hidden.vbs`: hidden STA launcher.
- `install-devspace-watchdog-tray.ps1`: opt-in migration installer.
- `uninstall-devspace-watchdog-tray.ps1`: removes the Tray without stopping
  managed services.
- `restore-old-watchdog.ps1`: restores the pre-Tray configuration and legacy
  Scheduled Task.

The existing `devspace-watchdog.ps1` remains available for rollback and older
installations. It is not deleted by Tray migration.

## 2. Tray

The Tray uses a configuration-path-derived named mutex, so aliases of the same
installation cannot create multiple instances. A named stop event lets the
uninstaller close the Tray without stopping any managed service.

Icon states:

| Color | Meaning |
| --- | --- |
| Green | Enabled local services and cached public MCP probes are healthy. |
| Yellow | Checking, degraded, recovering, partially manually stopped, or in maintenance. |
| Red | Recovery failed or a configured port has an unrecognized owner. |
| Gray | Every enabled service is persistently stopped by the user. |

The context menu provides:

- Open Dashboard
- Status
- Start All, Stop All, Restart All
- per-service Start, Stop, and Restart
- Maintenance Mode and Resume Auto Recovery
- Open Logs
- Exit Tray

`Exit Tray` closes only monitoring and UI. `Stop All` first persists
`stopped_by_user`, then stops only identity-matched DevSpace, Hermes, Router, and
ngrok processes. An unknown process is never killed to free a configured port.

## 3. Optional tools and multi-machine behavior

The Watchdog core manages DevSpace, Hermes, MCP Router, and ngrok as the base stack. Codex, OpenCodex, and C2C are optional local capabilities and are auto-detected instead of required by configuration.

This is intentional for mixed deployments such as TYO, NT1, and NT2R:

- A machine without Codex remains healthy and does not show Codex/C2C controls.
- A machine with Codex shows Codex runtime state plus the independently detected `codex-with-chatgpt` and `tyo-c2c-orchestrator` skills.
- OpenCodex is shown only when its local home is present. Proxy health and Tray presence are reported separately.
- An installed-but-stopped OpenCodex Tray can be repaired from the Tray/Dashboard. The Watchdog never installs Codex/OpenCodex merely because they are absent.
- Base-service runtime failures continue to use the existing confirmed-failure recovery state machine. Missing or damaged installation files fail closed into recovery diagnostics rather than downloading arbitrary software automatically.

The optional-tool layer is deliberately separate from `$script:WatchdogServiceNames`, so adding C2C to a Codex-capable workstation cannot make a non-Codex production station unhealthy.

For future installer-backed repair, use the repository's pinned tested-stack installer/upgrade flow behind an explicit operator confirmation. Do not turn a missing optional tool into an unattended package installation.

## 4. Dashboard

The DevSpace Control Center binds a `TcpListener` to `127.0.0.1` only. It never
binds `0.0.0.0`, an IPv6 wildcard, or a LAN interface. Its port defaults to 8777
and is configurable in `controlCenter.dashboardPort`.

Sections:

- **Overview**: process, PID, port, protocol evidence, uptime, recovery count,
  and public endpoint status.
- **Control**: all-service and individual Start, Stop, Restart, Retry, Keep
  Stopped, Maintenance, and Resume actions.
- **Network & MCP**: validated endpoint, domain, port, machine, name, label, and
  route settings with an impact preview.
- **ngrok Setup**: guided Agent/Cloud endpoint switch and generated Traffic
  Policy.
- **Logs & Recovery**: bounded health/recovery history and configuration
  rollback.

Mutation requests are accepted only when all of these are true:

- the TCP peer is loopback;
- `Host` exactly names `127.0.0.1` and the configured dashboard port;
- `Origin` is the same loopback origin;
- a per-process random control token from the served page matches;
- the method and content type are expected;
- the body is at most 64 KiB;
- the route, action, and every input field are allowlisted.

There is no CORS opt-in, arbitrary command endpoint, arbitrary file path, or
secret-rendering endpoint. Dynamic values are inserted with DOM `textContent`,
not dynamic HTML.

Critical actions require explicit confirmation:

- `STOP ALL`
- `RESTART ALL`
- `APPLY`
- `ROLLBACK`

## 5. Health model

Local probes run every 5 seconds by default; public probes run every 45 seconds.
Both intervals are configurable within bounded ranges. Probe work runs in a
PowerShell runspace inside the Tray process, not in a child process, so slow
network responses do not freeze the notification UI or create a console.

### DevSpace

Evidence includes:

1. an identity-matched Node process;
2. ownership of the configured listener port;
3. semantic `/healthz` JSON (`ok: true`, `name: devspace`);
4. expected MCP behavior at `/mcp`.

An unauthenticated DevSpace MCP probe is valid only when it returns either a
valid JSON-RPC response or the expected OAuth Bearer challenge with
`resource_metadata`. A plain HTTP 200 page is not healthy.

### Hermes

Evidence includes an identity-matched Python process, listener ownership, and an
MCP `initialize` request that returns a valid JSON-RPC result or error. HTML,
empty 200 responses, and unrelated JSON are rejected.

### MCP Router

The Router must have the expected Node command, own its fixed port, and return
semantic `__router/status` JSON for the configured machine and routes.

### ngrok

The expected ngrok process must own the Inspector port. `/api/tunnels` must show
the configured Agent/Internal endpoint and the exact Router upstream. A running
process with an empty tunnel list is reported as reconnecting/degraded, not
blindly restarted every cycle.

ngrok builds without `--web-addr` are supported. Their Inspector port remains
4040; the dashboard rejects an unsupported port override.

### Public MCP

The public DevSpace and Hermes route paths receive real MCP `initialize`
requests. HTTP reachability and MCP protocol validity are recorded separately.
This prevents an ngrok warning page or unrelated HTTP 200 response from being
reported as MCP healthy.

## 6. Auto Recovery

Each service has an independent state machine:

```text
Healthy -> Suspect -> Confirming -> Recovering -> Healthy
                                      |
                                      -> RecoveryFailed
```

The first failure never restarts a service. The default confirmation threshold
is two consecutive failures. Recovery affects only the failed service:

- DevSpace failure does not restart Hermes, Router, or ngrok.
- Router failure restarts only Router.
- ngrok failure does not restart local MCP servers.
- public failure with healthy local services is diagnosed through ngrok/public
  evidence and is not converted into a full-stack restart.

Default retry delays are 0, 10, 30, 60, and 120 seconds, with five attempts.
After the maximum, the service enters `RecoveryFailed` and automatic mutation
stops. The dashboard shows the attempt count, last error, last recovery, next
retry, Retry, Keep Stopped, and Open Logs.

Busy protection is fail-closed for DevSpace and Hermes. When an identity-matched
MCP process still owns its port but its protocol probe is temporarily
inconclusive, automatic recovery does not kill it. This protects long MCP calls,
builds, file operations, and tool invocations. Router semantic failure and an
ngrok tunnel mismatch remain recoverable after confirmation. Manual Retry is an
explicit operator restart and warns that it can interrupt active work. An
unrecognized port owner always blocks both automatic and manual process mutation.

## 7. Manual Stop

Desired state is stored in:

```text
%USERPROFILE%\.devspace\watchdog-tray-state.json
```

Values are `running` or `stopped_by_user` for each service. The file is replaced
atomically and survives Tray restart, logout/login, and reboot. A manually
stopped service is never auto-started. Only Start, Restart, or Retry changes it
back to `running`.

## 8. Maintenance Mode

Maintenance Mode is also persistent. Health monitoring, UI refresh, and event
logging continue, but automatic recovery is suspended. Use it before editing
configuration, updating binaries, debugging a port, or intentionally keeping a
service unhealthy. Resume Auto Recovery reenables state-machine actions.

If the desired-state file is corrupt or invalid, the Tray fails safe into
Maintenance Mode and records the parsing error instead of guessing that services
should be restarted.

## 9. Logs

Structured events are written to:

```text
%USERPROFILE%\.devspace\watchdog-tray-events.jsonl
```

Entries contain timestamp, service, event, cause, action, and result. Health
transitions, recovery attempts, manual actions, configuration changes, and
errors are included. Common credential assignments are redacted. The file is
size-bounded (2 MiB by default) and rotates to one `.1` file. Dashboard history
is also count-bounded.

Service stdout/stderr continues to use timestamped files in the state directory.

## 10. Agent Endpoint

AgentEndpoint mode points the local ngrok agent directly at the public
development domain:

```text
ngrok http http://127.0.0.1:<routerPort> \
  --url https://<public-domain> \
  --log stdout
```

The Router continues to expose machine-specific DevSpace and Hermes paths. The
public domain form accepts an HTTPS origin only: no credentials, path, query,
fragment, localhost, or shell characters.

## 11. Cloud Endpoint

CloudEndpoint mode gives the local agent an internal endpoint and binding:

```text
ngrok http http://127.0.0.1:<routerPort> \
  --url https://<machine>-devspace.internal \
  --binding internal \
  --log stdout
```

The Control Center generates both a full policy and a merge rule under the
state directory. The rule covers:

- `/<machine>/...`
- `/.well-known/oauth-authorization-server/<machine>/...`
- `/.well-known/oauth-protected-resource/<machine>/...`

No ngrok API key is requested or stored.

## 12. Agent to Cloud wizard

The wizard shows Current and Target modes, then:

1. generates the machine-specific Traffic Policy;
2. offers Copy Traffic Policy;
3. opens the ngrok Dashboard;
4. instructs the operator to create/update the Cloud Endpoint and merge the
   rule under the existing `on_http_request` list;
5. waits for Continue & Apply;
6. creates a local configuration backup;
7. writes each local configuration file atomically and restores the backup if
   any write fails;
8. restarts only impacted services.

The machine slug, routes, OAuth metadata prefixes, internal endpoint, ports,
and domain come from validated configuration. Nothing is hard-coded to TYO.

## 13. Cloud to Agent wizard

The wizard instructs the operator to:

1. open the ngrok Dashboard;
2. delete the Cloud Endpoint;
3. **not delete the Development Domain**;
4. return to the Control Center;
5. Continue & Apply.

If the public domain and route paths do not change, existing ChatGPT MCP URLs
are expected to remain unchanged. A changed domain or route produces a red
impact and a reconnect warning.

## 14. Domain changes

Changing Public Domain is a red-impact operation. Preview shows old and new
DevSpace/Hermes URLs and marks ChatGPT reconnect as required. Apply backs up
both `devspace-watchdog.config.json` and `config.json`, updates DevSpace's public
OAuth base, then restarts DevSpace, Router/ngrok only when required.

The Control Center never changes ChatGPT MCP registration itself.

## 15. MCP names and routes

- **Display Name** is dashboard text only. It is green impact and causes no
  service restart.
- **Internal MCP Name / Suffix** changes Router route names. It is yellow impact
  and requires Router restart, but not a URL reconnect by itself.
- **Route Path** changes a public MCP URL. It is red impact and can require a
  ChatGPT reconnect.

Paths must be lowercase absolute paths made from URL-safe segments. Traversal,
duplicate paths, query/fragment characters, backslashes, whitespace, and shell
characters are rejected.

## 16. Connection Impact and configuration rollback

Preview levels:

| Level | Meaning |
| --- | --- |
| Green | No connection impact; display-only change. |
| Yellow | Temporary interruption or local restart; public MCP URLs unchanged. |
| Red | Public domain or route changes; ChatGPT reconnect may be required. |

Preview lists each before/after value, impacted services, ngrok Dashboard action,
and reconnect requirement. Apply is impossible without validation and typed
confirmation.

Before any write, non-secret configuration is copied to:

```text
%USERPROFILE%\.devspace\configuration-backups\<timestamp>-<id>\
```

The manifest records timestamp, change type, before/after editable settings,
file names, and SHA-256 hashes. Rollback verifies the identifier, containment,
allowlisted targets, file names, and hashes. It first backs up the current state,
then restores the selected version. A partial Apply error triggers automatic
file rollback.

`auth.json`, environment variables, ngrok auth configuration, tokens, and
credential stores are not copied or rendered.

## 17. Install

Prerequisite: a working legacy Windows stack with
`devspace-watchdog.config.json`. Commit and test the source before deployment.

Standalone opt-in migration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\install-devspace-watchdog-tray.ps1 `
  -InstallDir "$env:USERPROFILE\.devspace"
```

Or opt in during the existing installer:

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File .\scripts\windows\install-devspace-watchdog.ps1 `
  <existing arguments> `
  -InstallWatchdogTray
```

Without `-InstallWatchdogTray`, existing installers retain the legacy poller.

Migration order is enforced:

1. validate PowerShell, configuration, and loopback dashboard port ownership;
2. back up overwritten Tray files, current non-secret configs, HKCU Run value,
   and legacy Scheduled Task XML/state;
3. copy Tray files;
4. register the current-user HKCU Run value;
5. start the hidden Tray;
6. prove a fresh heartbeat, live Tray PID, loopback dashboard listener, and
   persisted service-management state;
7. only then disable the old Scheduled Task;
8. retain the old task for rollback.

The installer does not delete the old task. If readiness or task disabling
fails, it reenables the task, restores files/autostart, stops the failed Tray,
and reports the recovery backup. Managed services are not stopped by installer
rollback.

## 18. Uninstall and recovery

Normal uninstall:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\.devspace\uninstall-devspace-watchdog-tray.ps1"
```

It stops only the Tray, restores/removes the exact installed files when hashes
match, restores the previous HKCU Run value, and reenables the legacy task when
it was previously enabled. Modified files are left in place with a warning.
DevSpace, Hermes, Router, and ngrok are not stopped.

Full pre-Tray recovery:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\.devspace\restore-old-watchdog.ps1"
```

This stops the Tray, disables Tray autostart, snapshots the then-current config,
restores the install backup, re-registers/enables the old Scheduled Task, starts
it, and checks configured listener ports. Use `-DoNotStartLegacyWatchdog` when
an operator wants files/task restored without executing a watchdog cycle.

## 19. TYO pilot checklist

Do not treat source tests as a pilot. Run this checklist only in an explicitly
authorized TYO deployment window.

### Preflight

- [ ] Record feature branch and exact commit SHA.
- [ ] Confirm local commit equals the reviewed remote commit.
- [ ] Confirm repository worktree is clean.
- [ ] Confirm DevSpace, Hermes, Router, ngrok, and public MCP paths are healthy.
- [ ] Confirm the existing legacy task name, enabled state, and XML export.
- [ ] Confirm the recovery backup is outside Git and its hashes are recorded.
- [ ] Confirm ports 7676, 4750, 8766, 4040, and the selected dashboard port have
      expected owners.
- [ ] Confirm endpoint mode, public domain, machine slug, internal endpoint, and
      route paths from live config.
- [ ] Confirm no unrelated ngrok Dashboard or ChatGPT MCP change is planned.

### Install

- [ ] Run the standalone opt-in Tray installer once.
- [ ] Confirm no visible CMD/PowerShell window appears.
- [ ] Confirm exactly one Tray instance and one notification icon.
- [ ] Confirm heartbeat age is under 10 seconds.
- [ ] Confirm Dashboard listens only on `127.0.0.1`.
- [ ] Confirm all four services remain on their original PIDs immediately after
      migration when no recovery was needed.
- [ ] Confirm the old task is disabled, not deleted.
- [ ] Confirm the Startup ngrok bootstrap and OpenCodex Tray were not modified.

### Functional checks

- [ ] Exit Tray; prove all four services continue running; relaunch Tray.
- [ ] Enter Maintenance Mode; deliberately stop an approved test service; prove
      it is monitored but not recovered; resume and prove recovery.
- [ ] Stop one approved service; prove `stopped_by_user` persists across Tray
      restart and the service remains stopped; Start it manually.
- [ ] Simulate one failed probe; prove no restart.
- [ ] Simulate a confirmed missing process; prove only that service restarts.
- [ ] Run a long MCP/tool operation; prove busy protection does not restart the
      identity-matched listener.
- [ ] Verify Retry, Keep Stopped, attempts, error, recovery time, and next retry.
- [ ] Verify log rotation with a test-size threshold if authorized.

### Dashboard/security checks

- [ ] Verify LAN IP and `0.0.0.0` cannot reach the dashboard.
- [ ] Verify wrong Host, Origin, token, method, oversized body, invalid port,
      invalid domain, traversal route, and shell-like input are rejected.
- [ ] Verify display-only preview is green.
- [ ] Verify restart-only preview is yellow.
- [ ] Verify domain/route preview is red with old/new URLs.
- [ ] Create and roll back a harmless display-name change; verify both backups.

### Endpoint guided-mode checks

- [ ] Generate Agent-to-Cloud policy and compare machine, route, OAuth metadata,
      internal endpoint, and binding to the reviewed live topology.
- [ ] Verify the wizard does not request or store an ngrok API key.
- [ ] Verify Cloud-to-Agent instructions say not to delete the Development
      Domain.
- [ ] Do not press Continue or change the ngrok Dashboard unless that endpoint
      switch is separately authorized.

### Public validation and observation

- [ ] Run real MCP initialize checks for DevSpace and Hermes; do not accept plain
      HTTP 200 as success.
- [ ] Verify existing ChatGPT connectors without editing registration when URLs
      are unchanged.
- [ ] Observe at least 15 minutes: no per-minute ConsoleHost creation, no restart
      storm, no duplicate service, and no unexplained public disconnect.
- [ ] Reboot during the approved window; verify desired state and Maintenance
      persistence, single instance, and autostart.
- [ ] Record PASS/FAIL and residual risks separately from source test evidence.

### Rollback drill

- [ ] Run `restore-old-watchdog.ps1` only if rollback is authorized.
- [ ] Confirm Tray process stopped and HKCU Run entry removed/restored.
- [ ] Confirm previous config hashes restored.
- [ ] Confirm old task reenabled and running.
- [ ] Confirm DevSpace, Hermes, Router, ngrok, and public MCP protocol health.

## 20. Troubleshooting

| Symptom | Action |
| --- | --- |
| Installer says dashboard port has an unrecognized owner | Identify the PID; do not kill or move it automatically. Choose a reviewed free dashboard port in config. |
| Tray starts but stays yellow | Open Logs & Recovery and compare process, listener, semantic HTTP, MCP, Router, Inspector, and public layers. |
| DevSpace returns 401 | It is healthy only when the challenge is Bearer plus MCP resource metadata. A Basic or unrelated 401 is invalid. |
| Public URL returns 200 but UI says invalid MCP | Inspect the body; ngrok warning/HTML or unrelated JSON is intentionally rejected. |
| Service is busy/indeterminate | Wait for active work to complete. Auto Recovery will not kill the listener. Manual Retry is an explicit interruption. |
| Port identity conflict | Stop/reconfigure the unknown owner manually after confirming identity. The Tray fails closed. |
| ngrok process runs but tunnel is absent | Inspect `ngrok-watchdog.err.log`, Inspector tunnels, corporate TLS inspection, and the reviewed endpoint mode. Avoid restart storms. |
| RecoveryFailed | Review error and ownership, then Retry or Keep Stopped. Do not raise max retry simply to hide a root cause. |
| Tray installer fails | The legacy task should remain enabled. Use the printed recovery backup and inspect the install manifest. |
| Tray is broken after deployment | Run `restore-old-watchdog.ps1`; it retains a safety copy of the files present immediately before restore. |
