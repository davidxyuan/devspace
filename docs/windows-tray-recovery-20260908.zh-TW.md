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

## Repo 接續處理 — 2026-09-08

已比對本文件與 `codex/windows-watchdog-tray-control-center`（起點 `0fa8850`，起始工作樹乾淨；與本機 origin tracking ref 無差異）。

### 已補齊的原始碼

- 安裝器建立目前使用者、非提升權限、按需執行的 `DevSpaceWatchdogSupervisor-<安裝目錄雜湊>` 排程。既有登入 Run 與桌面 Watch 入口會轉交此排程。
- 排程使用 `Interactive`、`IgnoreNew`、無執行時間上限；獨立 supervisor 不再由 installer 的 `Process.Start` 建立。
- 操作前核對安裝目錄、完整 action、帳號 SID、權限與排程設定；Windows 回傳帳號名稱時先解析為 SID。不同身分的同名排程不覆蓋、不刪除。
- 安裝失敗會清理本次建立的排程，還原前一份安裝紀錄；既有排程沿用。解除安裝及 `restore-old-watchdog.ps1` 也處理新排程。
- 清理排程前等待 lifecycle stop 讓 supervisor 自行退出；不以強制停止整個排程程序樹作為捷徑。
- 新增 `watchdog-independent-task.test.ps1` 並納入 Windows 回歸命令，涵蓋排程建立／沿用／失敗、身分拒絕、安裝紀錄回復、Watch 轉交、手動恢復與防遞迴。

### 實測證據與界線

- 完整 `npm run test:windows-watchdog` 通過（exit 0），包含新排程測試與 39 個必要套件檔案檢查；`git diff --check` 通過。

- 隔離的原生排程測試成功：child PID 37864、parent PID 2512（svchost），測試啟動器 PID 16084。使用暫存測試腳本，沒有啟動或停止正式後端；測試排程與 fixture 已清除。
- 本次唯讀檢查時，舊臨時 recovery 排程為 Ready，supervisor 心跳停在 `2026-09-08T08:36:10.4849125+00:00`。先前 16:17 的 Healthy/PID 紀錄不能視為目前健康證據。
- 後續重新驗證 `watchdog-independent-task`、installer transaction、supervisor、lifecycle、control-core、39 檔 package validation 與 `git diff --check` 均通過。完整 Windows suite 再跑時會停在既有 `stack-component-action.e2e.test.cjs:223` rollback-result assertion；同一 assertion 已在乾淨 HEAD worktree 重現，和本次 Supervisor 變更無關。

### 正式部署與 Kaspersky 實證 — 2026-09-08 晚間

- 直接執行 `install-devspace-watchdog-tray.ps1 -AllowLegacyQuiesce` 再次以 `1073741845`（`0x40000015`）非正常結束。Kaspersky Endpoint Security Event Log 事件 4662 在同一時間記錄完全相同的 `ProcessPath=D:\devspace\scripts\windows\install-devspace-watchdog-tray.ps1` 與 command line，因此舊 installer 異常退出原因已定位為 Endpoint Security 行為攔截，而非 installer 自行 `throw`。
- 未關閉 Kaspersky、未更改 ACL。改採低行為密度的分段部署：先備份 live runtime 與 install record 至 `C:\Users\david.yuan\.devspace\configuration-backups\manual-supervisor-20260908-184239`，再複製並逐檔 SHA256 驗證 `devspace-watchdog-bootstrap.ps1`、`watchdog-install-transaction.ps1`、`uninstall-devspace-watchdog-tray.ps1`、`restore-old-watchdog.ps1`。
- 正式建立並驗證 `DevSpaceWatchdogSupervisor-91c7c7172f26`：目前使用者、`Interactive`、`Limited`、`IgnoreNew`、`PT0S`，action 明確帶 `-Mode Watch -ScheduledSupervisor`。Supervisor process parent 為 PID 2512 `svchost.exe`，證明不依附 Codex/Hermes launcher process。
- install record 已加入 `supervisorTask`，上述四個 runtime 的 installed SHA256 亦更新為 live hash；舊 rollback payload 保留。
- 原臨時 `DevSpaceWatchdogIndependent-537d551c36c3487787285c87f89b7c85` 已在 lifecycle stop 後回到 Ready，再精確移除；正式 Supervisor 為唯一獨立 watchdog supervisor。
- 已做登入路徑等價實測：正式 Supervisor/Host/Tray 先 lifecycle Stop，再執行 HKCU Run 使用的 `bootstrap -Mode Watch`；launcher 立即返回，由正式 Scheduled Task 重新啟動新的 Supervisor/Host/Tray。Public probe 的 persisted `nextProbeUtc` 保持 6 小時節流，沒有因 handoff 被強制重置。
- 發現 Host restart 後雖沿用 6 小時 public probe 排程，但舊成功 probe snapshot 只存在記憶體，導致 Tray 在下一輪排程前持續顯示 `Checking public MCP`。已修正為：`consecutiveFailures=0`、`lastSuccessUtc` 合法且尚未到 `nextProbeUtc` 時，從 persisted state 還原 `persisted_success` 顯示，不新增 ngrok request。實機 Host PID `62876 -> 19652` 後 Overall 直接維持 `GREEN / Healthy`，`lastAttemptUtc=2026-09-08T11:11:37.8058935Z` 與 `nextProbeUtc=2026-09-08T17:11:37.8058935Z` 均未改變。
- 尚未直接重開 Windows 或真正登出使用者；這兩項屬會中斷目前工作階段的 destructive durability test，仍需在可重開機的維護窗口執行。

### 仍需外部條件或另行驗證

| 項目 | 狀態 |
|---|---|
| 正式安裝與退出／重新登入持續性 | 正式 Supervisor 已部署；lifecycle Stop → HKCU Run 等價 `Mode Watch` handoff 實測通過。只剩真實 reboot/logoff 維護窗口驗證 |
| 受保護的 legacy minute poller | 已直接嘗試 `Disable-ScheduledTask`，Windows 回 `0x80070005 Access is denied`；script-level quiesce 仍有效，真正 Disable 需要管理員帳號，未更改 ACL 或安全政策 |
| 真實 Cloud Policy 套用 | TYO 使用 Agent Endpoint，本機不需要 Cloud Policy；Cloud Endpoint 舊機仍需要其帳號 API key 與選定 `ep_...` endpoint，未 PATCH 未提供的真實帳號 |
| 三台舊機升級 | 仍需逐台處理；優先採獨立 clean clone，避免覆蓋 dirty checkout / dubious ownership，並在切換前處理舊 poller quiesce |
| 原始對話索引修復 | 已有匯出檔；本次未改 Codex 私有資料庫／索引，仍屬未解決產品資料索引問題 |
| 舊 installer 排程異常退出 | 原因已由 Kaspersky Event Log 直接定位；all-in-one PowerShell installer 仍會被 Endpoint Security 終止，正式機目前以分段部署完成，不以停用 AV 規避 |
