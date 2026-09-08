# 2026-09-08 舊機升級檢查

透過各台既有 Hermes MCP 執行唯讀檢查，未升級、停止服務或變更 Git 設定。

| 電腦 | Endpoint | Node / CLI / ngrok | 新 Tray | 來源檢查 | 管理員權限 |
|---|---|---|---|---|---|
| NT1 C02180288 | Agent | 路徑均存在 | 未安裝 | 有未提交修改 | 有 |
| NT2R C02200041 | Cloud | 路徑均存在 | 未安裝 | Git dubious ownership，無法判定乾淨 | 無 |
| FrameStation C02180034 | Cloud | 路徑均存在 | 未安裝 | 有未提交修改 | 無 |

三台皆有啟用的 `DevSpaceNgrokWatchdogUserPoller`，使用 PowerShell；舊腳本皆不支援 `legacy-watchdog-poller.disabled` 停用標記。
因此不能將目前電腦的無管理員暫停方式直接套到這三台，也不能直接覆蓋舊來源。
升級時應先備份設定與排程，保留舊來源，在獨立安裝位置使用新版套件；切換前需要具權限的人停用舊排程，並逐台驗證本機及公開 MCP 連線。

Hermes operator doctor 三台皆回報缺少 gateway PID / heartbeat；這與本次 MCP 工具成功回應並不矛盾，不能單憑該項診斷判定 MCP 斷線。

本報告只證明檢查當時的檔案、設定與工具可達狀態，不代表三台已升級或通過新版部署驗證。
