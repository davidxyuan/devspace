# Home Watchdog — independent-channel E2E follow-up (2026-11-01)

## Scope

Home `DESKTOP-KT81K8N` only. Do **not** interpret isolated scheduling tests or failed termination attempts as a successful DevSpace, Router or ngrok failure/recovery E2E. TYO, NT1 and NT2R were not touched.

## Previously completed genuine recovery

- Hermes MCP was genuinely terminated and restored twice. The second run was hands-off, with Watchdog detecting the failure, dispatching attempt 1 and restoring Healthy on a new PID.
- Source-backed fix is on branch `codex/home-watchdog-healthy-auto-20261031`, commit `1a210e9493bcfe106c5287c59be24e8f5c8a6c12`.

## Independent Windows recovery channel tested

Windows Task Scheduler ran under `DESKTOP-KT81K8N\david`, without DevSpace/Hermes parent process. Its sentinel produced a separate file and exited 0. A disposable PowerShell process was genuinely terminated by Windows `taskkill /F` in an isolated task, with exit 0. No production service was involved in this control test.

A Home-independent Watchdog E2E script checked current Dashboard Auto/Healthy, process PID and birth times, precise manually recorded legacy attestation, exact target service, protected process tree, status, logs, local TCP health and fallback restrictions. It waited 12 seconds before destructive action, to prevent its initiating MCP request being in the process tree.

**Important**: invoking the script directly from DevSpace is not safe: its own bash/PowerShell processes are DevSpace descendants, and the safety gate correctly rejected them. Even a scheduled task may be unable to read old processes' CommandLine/ExecutablePath, so a valid PID+birth-time attestation was required. The separate scheduled dry-run passed.

## Actual Home tests and evidence

| Target | Independent scheduled preflight | Genuine process terminated? | Result |
|---|---|---|---|
| DevSpace MCP, old PID 31160 | PASS, verified identity and root | **NO** | First attempt aborted on transient child PID changes. Fresh process-tree safeguards resolved this. `Stop-Process` then returned Access Denied on the old main PID; Windows `taskkill /F` also returned nonzero. Main service stayed Healthy. |
| Router, old PID 33448 | PASS | **NO** | Windows `taskkill /F` returned nonzero on the original Router main PID; service stayed Healthy. |
| ngrok, old PID 32248 | PASS | **NOT ATTEMPTED** | Deliberately preserved the sole cloud tunnel because there is no independent Home DeskPilot/remote desktop rescue connection and both other managed-node termination tests hit restrictions. |
| Home reboot / complete external network interruption | Not applicable | **NOT ATTEMPTED** | Without an independently authorized and validated Home rescue access channel, these actions can strand the machine and invalidate all remote observations. |

The main production processes all belong to the user's Windows account. A non-mutating Win32 `OpenProcess(PROCESS_TERMINATE)` check succeeded on DevSpace, Hermes, Router and ngrok, but successful handle acquisition does **not** prove `Stop-Process` or `taskkill` will succeed; the latter two refused DevSpace and Router. The exact cause of this difference is unconfirmed; do not attribute it to antivirus without more evidence.

Original evidence on Home: `.devspace\configuration-backups\home-independent-e2e-20261101-<service>.jsonl`, `home-e2e-terminate-rights-20261101.json`, `home-native-terminate-test-20261101.json` and `home-e2e-cleanup-20261101.json`.

## Cleanup and current health

All eight temporary E2E Task Scheduler entries were unregistered; no delayed duplicate kill task remains. The original `HomeFullTraySupervisor` remains Running. At 2026-10-31 17:56 UTC (2026-11-01 01:56 Asia/Taipei), Dashboard was overall **Healthy**, `maintenanceMode=false` (Auto), four managed services **Healthy**, `phase=Healthy`, `attemptCount=0`. Main PIDs were DevSpace 31160, Hermes 19184, Router 33448 and ngrok 32248.

All Watchdog Core persistence/security/recovery/Tray regression tests and the strict+semantic identity regression test pass in the existing clean Git snapshot.

## Prerequisites for the remaining destructive tests

1. Obtain an **authorized independent control channel on Home itself** (not TYO or NT1); the two currently connected DeskPilot devices were identified as `C02250073` and `C02200041`, neither is Home.
2. Determine why the approved user-level scheduled task can terminate a disposable test process but not the old DevSpace/Router managed processes. Resolve via normal Windows access controls, service lifecycle, or a locally approved operator; do not bypass security controls or weaken anti-malware.
3. Re-test single services sequentially with an independently executing bounded fallback, and verify new PID, live protocol, public ChatGPT MCP access, Dashboard Healthy and recovery attempt reset. Only then consider full-tunnel/network-outage or reboot scenarios, preferably in an agreed maintenance window with local fallback and post-boot access.

**Outcome:** The independent test harness and all non-disruptive safety gates passed, but the genuine DevSpace, Router, ngrok and full-network/reboot E2E scenarios remain **unverified** due to concrete platform safety/permission constraints. Never mark these as PASS.
