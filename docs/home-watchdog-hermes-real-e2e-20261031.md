# Home Watchdog — genuine Hermes MCP kill/recovery E2E, 2026-10-31

## Scope and result

Home only (DESKTOP-KT81K8N); TYO, NT1 and NT2R were not changed.

**The real Hermes MCP failure and automatic restart passed.** The initial post-restart health check exposed an additional identity-evidence compatibility bug, which was fixed and verified before sign-off.

- 2026-10-31 14:43:42 UTC: verified exact executable identity, process birth times, parents and auto/healthy preflight, saved Watchdog state, then terminated the two **real** Hermes MCP Python processes (PIDs 31968 and 30916). The separate Hermes Gateway (PID 2196), DevSpace (31160), Router (33448), ngrok (32248), Host and Tray were not terminated.
- About 14:43:57 UTC: Watchdog correctly reported a missing Hermes managed process, then Suspect/Confirming.
- 14:45:14.6838495 UTC: Watchdog recorded Hermes `recovery`, reason `confirmed_failure`, attempt 1, result `dispatched`.
- 14:45:14–19 UTC: new managed Hermes Python parent PID 1824 and listener process PID 1800 started; TCP 4750 accepted connections.
- Initially, the dashboard remained Degraded because the existing exact-PID legacy attestation correctly invalidated with the killed old PIDs while Windows still did not expose a listening PID. The recovered new processes had **strict executable and command-line identity**.
- Implemented a compatibility refinement: when `strictIdentityVerified` (or the still-valid exact-PID attestation) is true, no unknown TCP listener PID exists, local TCP is reachable, and the expected service-specific semantic protocol is healthy, allow `healthEvidence=strict_process_and_protocol` (or `attested_process_and_protocol`) and Healthy; keep `listenerFound=false` when Windows doesn't reveal a listener owner.
- Validated with the real newly recovered Hermes process: it became Healthy with `health_legacy_mcp=True` and `strict_process_and_protocol` evidence. The Dashboard returned Healthy/Auto and Hermes recovery `attemptCount=0`, with original other-backend PIDs unchanged.

## Safety assertions

The protocol-backed fallback is **not** accepted merely because TCP port is reachable: strict current process command/executable matching or valid PID/birth-time attestation is required, as well as a service-specific semantic response. An explicitly unknown listener PID remains a conflict. Invalid MCP protocol does not become Healthy. Simulated PID reuse, mismatching command lines and modified config attestations are rejected.

Tests:
- `scripts/windows/watchdog-control-core.test.ps1`: PASS.
- `scripts/windows/watchdog-strict-recovery-identity.test.ps1`: PASS (new strict-process fallback positive and negative tests).
- Source-to-installed core logic verified by direct read-only real Home health probe before the live patch, then actual Dashboard healthy snapshots afterwards.

## Important limitation

**DevSpace MCP itself was NOT terminated for an independent end-to-end kill test.** Its only active code-control MCP would go offline; a separate scheduled test harness was drafted but the later launch/check was not successfully authorized. No DevSpace kill should be inferred from this report. A fully independent recovery channel and verified fallback are prerequisites to a future DevSpace kill experiment. The standalone DevSpace test driver in `.devspace/configuration-backups` was not run.

No claim is made that every fault type, repeated crash loop, or DevSpace self-hosting disconnection has been E2E-tested. The successful real Hermes test nonetheless validates the common Watchdog recovery state machine and actual managed service launch path.
