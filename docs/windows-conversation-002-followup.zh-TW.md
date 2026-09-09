# 「雙Agent自動協作_002」與 repo 核對結果

核對日期：2026-09-09。來源對話：`6aa0fcc0-8f40-83ee-8cf5-4930ffe30d67`。
Repo：`https://github.com/davidxyuan/devspace`，分支：`codex/windows-watchdog-tray-control-center`。
開始時 HEAD 為 `0c06930`，fetch 後與 origin 一致，工作目錄乾淨。

對話中的描述只作為待驗證線索。原對話最後上傳的 10 個 log 檔沒有隨引用提供；本次沒有宣稱重新讀過那些原始 log。

## 逐項核對

| 項目 | 本次結果 | 證據／剩餘條件 |
|---|---|---|
| Open Dashboard 點擊無反應 | 既有修正保留 | `7eb20ef` 使用 Windows shell association；現有回歸通過 |
| 跨 Windows Session 停止 Tray | 既有修正保留 | `4e04527` 使用 Global ManualReset stop event；本次未重新進行實機跨 Session 測試 |
| FrameStation 新 Tray 重載 | 對話已報告完成；本次未重新驗證 | 不把當時 PID／Dashboard 200 當成現在的執行證據 |
| legacy poller 提早退出 | 既有修正保留 | `0c06930` 在載入 config／modules 前檢查停用標記；不能因此保證 Windows 不建立視窗 |
| 舊 config 缺少 `ngrokWebAddrSupported` | **程式完成** | Host 和 legacy watchdog 都改為未確認支援時不加入旗標；自訂 Inspector port 在驗證／直接啟動時拒絕；process identity 仍驗證 Inspector |
| Quick Switch 失敗後恢復前一帳號 | **程式完成** | 加入 Restore Previous ngrok Account；切換前保存原 DPAPI record 與 domain/mode，支援 Host 重啟後讀取；恢復失敗保留 recovery point，拒絕不同 installation 的記錄 |
| rollback 啟動後立即死亡卻報已恢復 | **程式完成** | 回復舊 credential/config 後再次做 local ngrok 與 public MCP 驗證；失敗進入既有 maintenance/attention，不以 Process.Start 成功充當恢復成功 |
| public probe 額度 | **程式驗證完成** | 既有六小時週期維持；切帳號／恢復先等 local ready，再做一次 public MCP 驗證。Router 用量統計只使用本機資料，不新增 public request |
| Dashboard 累積 request 分類／保存 | **程式完成** | Today、Last 24 hours、This month、Since Router start；DevSpace／Hermes／Watchdog／Other-OAuth 分類不重複加總，local/unknown Host 另列；domain 切換與重啟保存有實際 loopback Router 測試 |
| component activation rollback E2E assertion | **本次驗證通過** | 單獨執行及完整 Windows suite 均經過真實候選套件 staging／activation failure／rollback；durable job 含原設定恢復訊息，因此未臆測修改 `stack-jobs.cjs` |
| TYO／CTF 每分鐘排程改每日或停用 | **待具權限維護** | 本次讀取 TYO `C02250073` 與 CTF `C02200041`：目前執行身份都非管理員，排程都仍 Enabled、`PT1M`。本次沒有修改 Task Scheduler、ACL 或安全政策 |
| NT1 恢復連線並重測新 domain/token | **連線受阻** | 本次 Hermes status 回 `McpServerError: Session terminated`；DevSpace open_workspace 回 `-32603 Internal error`，無法取得 NT1 workspace 或 runtime 證據 |
| 真實 Agent／Cloud Endpoint 切換實驗 | **尚未驗證** | 程式測試包含 switch、restore、Cloud policy preview/apply/readback；新帳號的真實 token、endpoint/policy 與實機切換不在本次程式驗證之內 |
| 新版部署至四台實機 | **尚未部署** | 本次修改 repo 並測試；既有 live `.devspace` 安裝檔、服務、ngrok 帳號及 Cloud policy 沒有被替換 |

## 驗證

- `npm run typecheck`
- `npm test`
- `npm run test:windows-watchdog`，包含新增 `mcp-router-usage.test.cjs`
- `git diff --check`

新增測試覆蓋：缺欄位啟動、錯誤 Inspector identity、自訂 port 拒絕、帳號恢復成功與失敗、原本不存在 DPAPI override、跨安裝身份拒絕、public verification 次數、request 分類、重啟／domain 隔離、日期範圍、歷史過期、寫入重試、損壞歷史保留，以及 UI 恢復操作與文字安全顯示。

## 使用與證據界線

用量依 Host／forwarded-Host 與目前 domain 的匹配推算入口，無法代表 ngrok 官方帳號用量，也不知道其他電腦或 ngrok 在進入 Router 前拒絕的 request。歷史自功能安裝後開始，以 Router 本機日期保存 62 天；24 小時視窗採分鐘 bucket，最多多含一分鐘。每 10 秒或 status refresh 批次落盤，強制終止可能遺失尚未保存的計數。寫入失敗及不完整歷史會顯示警告；損壞的原始檔不會被零值覆寫。

Restore 只保留最近一次切換前的帳號，不能補回安裝此功能前已遺失的 credential。原帳號使用 ngrok.yml／環境 credential 時，該來源必須仍維持原值。原本手動停止的服務意圖仍被保留。

原對話最後「Exit Tray 後 Supervisor 自動拉起」的說法不適用目前程式：**Exit Tray 會寫入 `watchdog-manual-stop.flag`**。維護重載應使用既有 lifecycle/bootstrap 路徑，不能用手動停止當成重載證據。

部署時應先依既有安裝流程備份並核對目標，再更新已驗證版本。Host/core、legacy watchdog、Dashboard HTML 與 Router 都有改動，僅更新 Tray UI 不會帶入本次功能。部署後仍需在各實機驗證 PID／health／public MCP，以及該機真正的帳號切換結果。
