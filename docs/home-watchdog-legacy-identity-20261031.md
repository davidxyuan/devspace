# Home-only Watchdog legacy-process identity compatibility (2026-10-31)

Home can retain old, externally functioning DevSpace/Hermes/Router/ngrok processes after the monitoring Host restarts. The new Host sometimes cannot read those old processes' Windows CommandLine/ExecutablePath; the strict matcher then incorrectly reports them as missing. The Windows listener-owner API can also return no PID even while loopback TCP is responsive.

To avoid confusing a functioning orphan with a missing process, `watchdog-control-core.ps1` supports a **manually verified, exact-PID attestation** stored in the configured state directory. Generate it only while Maintenance is active, after strict process/port verification with `scripts/windows/watchdog-legacy-attestation.ps1` from an independent operator PowerShell environment. Its default is preview; `-Apply` writes once only when the target does not already exist. Do not copy this state file to another machine.

The evidence binds machine slug, Windows user, config SHA256, process name, PID, and exact UTC creation ticks (serialized as a string to avoid JSON/JavaScript number rounding). Every health poll invalidates the attestation if the PID has disappeared or been reused, if the config/user changed, or if newly readable command-line evidence fails the strict matcher. Unknown listener owners remain identity conflicts. If Windows does not expose a listener PID, TCP reachability never becomes `healthy=true`; rather it remains an indeterminate, non-restartable observation while the port is reachable. This bridge is NOT a bypass for process ownership or a justification to resume Auto.

Security: the state file uses the user's existing restricted `.devspace` ACL. Only the account, Administrators, and SYSTEM should have write rights; a local administrator or compromised account can already alter the Watchdog runtime.

## Protocol-backed health when Windows cannot disclose the listener PID

For services with an exact-PID attestation, when Windows' listen-owner query returns **no PID**, the core verifies the TCP socket and the existing service-specific semantic protocol. DevSpace requires its healthz and MCP OAuth challenge; Hermes requires the exact health response or its recognized legacy MCP fingerprint; Router requires the configured machine slug and route status; ngrok requires the exact public Agent Endpoint URL and expected local upstream. If and only if all of the necessary evidence passes, the service may be Healthy with `healthEvidence=attested_process_and_protocol` and `protocolAttestedWithoutListener=true`. The actual `listenerFound` remains false—never fabricate a PID. Any explicitly unknown listening PID remains an identity conflict, even if a protocol endpoint responds.

If the protocol fails, the port is unreachable, the original PID disappears or gets reused, or the config hash changes, the fallback is invalidated; it must **never** claim Healthy. A reachable but unverified endpoint defers destructive recovery. Each machine can use the same code, but does not create an attestation unless its own Windows observer truly needs one. Never copy Home's attestation to TYO, NT1 or NT2R.

## Auto safety and caveat

Verify with `powershell -NoProfile -File scripts/windows/watchdog-control-core.test.ps1` and multiple fresh `http://127.0.0.1:8777/api/status` snapshots. Only consider Auto after every enabled service reports healthy/protocolHealthy without identity conflict, the supervisor/Tray are stable, backup is verified, and there is no active mutation or recovery. Do not use Restart All for validation. The fallback does not certify a kernel listener PID; for security it binds the legacy process identity independently and verifies live application semantics.

Legacy attestations are intentionally invalid when a service's PID changes. After a legitimate backend process restart, a privileged observer must generate fresh evidence using strict matching, or normal strict PID recognition must resume. A legacy process replacement might therefore temporarily show degraded status until re-attestation. This is safer than blindly restarting or trusting a new unknown process.

No modification is intended for TYO, NT1, or NT2R in this Home-only deployment.
