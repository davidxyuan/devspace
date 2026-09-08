# Tray recovery checkpoint — 2026-09-08 16:17 +08:00

- Recovered history: D:\devspace-clean-backups\session-recovery-20260908-154901\recovered-conversation.md. Its heading timestamps are UTC, despite earlier intended Taiwan conversion. Original JSONL remains the timestamp authority. UI history indexing is not repaired.
- Fixed bootstrap role discovery: ignore an unreadable CIM row only when Get-Process confirms the PID no longer exists; a live unreadable process still blocks recovery. Lifecycle and supervisor tests passed.
- Deployed bootstrap SHA256: 47CF5A46720CDB0140B1ED1FAADFE4AE6979A9AEBAFC4430696463159446A60D (source and live equal).
- Current recovery uses on-demand current-user scheduled task DevSpaceWatchdogIndependent-537d551c36c3487787285c87f89b7c85, executing installed bootstrap Mode Watch, hidden. Supervisor PID 61828 parent 2512 (svchost.exe); Host 58588; Tray 50116 Healthy; dashboard HTTP 200. These are point-in-time observations, not reboot/exit durability proof.
- Earlier attempt to run the installer from that task exited with LastTaskResult 1073741845; no completion marker. Evidence: D:\devspace-clean-backups\independent-tray-20260908-161230. The task action was subsequently changed to bootstrap Watch to restore service. Installer exit cause is unresolved.
- Codex transport stopped at 2026-09-08T05:55:35.022Z, matching previous Host/Tray disappearance. Process-tree termination is a strong hypothesis, not proven kill attribution.

## Still outstanding

- Integrate independent startup into installer with transaction/rollback/uninstall coverage; current on-demand task is a machine recovery measure. Existing login startup remains configured. No actual reboot or Codex-close test performed.
- Protected legacy minute poller still needs administrator permission to disable; its script is quiesced, but console creation may remain.
- Real Cloud Policy API application needs the account API key and selected endpoint; only mock/local validation completed.
- Remote upgrades require resolving dirty checkouts and ownership/permission issues documented in the earlier preflight report.
- Original conversation is preserved/exported, but app history index repair remains unresolved.