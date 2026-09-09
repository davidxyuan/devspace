# 「雙Agent自動協作_002」與 repo 核對結果

核對日期：2026-09-09；實機部署追蹤更新：2026-09-10。來源對話：`6aa0fcc0-8f40-83ee-8cf5-4930ffe30d67`。
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
| TYO／CTF 每分鐘排程改每日或停用 | **權限阻擋已實測** | 2026-09-10 兩台均已備份舊排程並嘗試停用，Windows 回覆存取被拒；仍 Enabled、`PT1M`，既有 logical quiesce 保留。需由具該 task 修改權限的人處理 |
| NT1 恢復連線並重測新 domain/token | **連線受阻** | 本次 Hermes status 回 `McpServerError: Session terminated`；DevSpace open_workspace 回 `-32603 Internal error`，無法取得 NT1 workspace 或 runtime 證據 |
| 真實 Agent／Cloud Endpoint 切換實驗 | **尚未驗證** | 程式測試包含 switch、restore、Cloud policy preview/apply/readback；新帳號的真實 token、endpoint/policy 與實機切換不在本次程式驗證之內 |
| 新版部署至四台實機 | **TYO 完成；其餘有阻擋** | 2026-09-10 TYO 已部署 `69e3e44`；CTF 安裝遭安全軟體中止後已回復健康舊版；FrameStation operator policy 為唯讀；NT1 connector 未恢復。詳見下方實機紀錄 |

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

## 2026-09-10 實機部署紀錄

使用者授權後，部署目標固定為 `69e3e44c3c013a4b14128e1404ec75c1b63f803b`。先核對 machine、install path、現有檔案與 supervisor task，再使用既有 installer／lifecycle／stack operation lock。帳號 credential、domain 與 Cloud policy 沒有變更。

| 機台 | 最終結果 | 現場證據 |
|---|---|---|
| TYO `C02250073` | **完成部署，GREEN Healthy** | 安裝器的 11 個檔案逐一符合 install record SHA256，另更新 legacy watchdog 與 Router；Dashboard 已提供 Restore 與 request usage；Host／Tray／Supervisor heartbeat 正常 |
| CTF `C02200041` | **部署受阻，已回復舊版，GREEN Healthy** | Kaspersky Endpoint Security Event 4662 記錄安裝腳本；臨時 task exit `1073741845`（`0x40000015`）。中止後 11 個原檔逐一核對備份 SHA256 並恢復，原 install record 保留；未部署新版 Router／legacy watchdog |
| FrameStation | **等待 operator 權限** | 兩次讀取均 `enabled=false`、`level=read_only`、`apply_mode=dry_run`、`mutation_allowed=false`；未繞過政策進行部署 |
| NT1 | **等待連線恢復** | 再次呼叫 Hermes operator status 仍回 `McpServerError: Session terminated`，無法建立實機版本或 runtime 證據 |

TYO 的 Supervisor 原本已停止、heartbeat 過期，本次經既有流程恢復。第一次安裝遇到程序身分無法確認，自動回復；確認該 PID 已退出後重試成功，沒有放寬身分檢查。成功安裝備份：

- `C:\Users\david.yuan\.devspace\configuration-backups\tray-install-20260910-062538-20c3b246`
- Router／legacy watchdog 備份：`C:\Users\david.yuan\.devspace\configuration-backups\backend-69e3e44-20260910-063051-ceda84d2`
- Backend 操作結果：`C:\Users\david.yuan\.devspace\rollout-69e3e44-backend-result.json`

TYO 新版 Router PID `48308`；DevSpace `59644`、Hermes `43896`、ngrok `49548` 維持原 PID。公開 DevSpace MCP 回合法 OAuth challenge、Hermes 回 JSON-RPC，兩者 HTTP 200。`router-request-usage.json` 已產生 schema 1 紀錄及 `savedAt`，本次公開探測歸入 Watchdog；local status refresh 不增加公開 request 總數。這是實機落盤證據，沒有額外重啟 Router 來宣稱實機跨重啟保存。

CTF 的直接遠端安裝期間，Hermes 探測逾時且被 Watchdog 重啟，安裝回復；後改由同一使用者的臨時排程執行，避免依附遠端請求。此次安裝在寫入 Tray payload 後遭中止，Kaspersky 事件與中止時間一致。已停止繼續部署，從下列備份恢復原檔並重啟原 Supervisor；沒有變更 Kaspersky 設定、排程 ACL 或 operator policy：

- 已驗證的恢復備份：`C:\Users\op.yo\.devspace\configuration-backups\tray-install-20260910-063404-697ee24e`
- 安裝 transcript／最終狀態：`C:\Users\op.yo\.devspace\configuration-backups\rollout-69e3e44-20260910\deployment-transcript.log`、`deployment-result.json`
- 原始暫存套件、可檢視的部署／恢復腳本留在同一資料夾，供 IT 稽核；臨時 `DevSpaceRollout-69e3e44-8b77bc64` task 已核對 action、SID 與狀態後移除。

CTF 恢復後 Host `15972`、Tray `6384`、Supervisor `10632`；DevSpace `12464`、Hermes `17320`、Router `10964`、ngrok `13720`，四個服務 healthy、無 identity conflict。從 TYO 獨立探測 CTF 公開 MCP，DevSpace OAuth challenge 與 Hermes JSON-RPC 均通過。此處 PID 是 2026-09-10 06:37（台灣時間）的快照。

### 剩餘工作與解鎖條件

1. **CTF 部署**：IT 檢視 Kaspersky Event 4662 與 transcript，核准／排除安裝中止原因後，再依固定 revision 和備份流程部署。原版目前已恢復健康。
2. **TYO／CTF legacy poller**：由具排程修改權限者核對 `\DevSpaceNgrokWatchdogUserPoller` 的 action、config path 與執行帳號，再停用或改成每日。兩台現在仍為每分鐘；logical quiesce 不能保證 Windows 不建立視窗。
3. **FrameStation／NT1**：前者需由該機操作者啟用允許部署的 operator mode；後者需先恢復 ngrok／connector，再取得 machine 與檔案版本證據。已有備妥修正版，尚未在兩台寫入。
4. **真實新帳號切換／Restore**：等待目標 domain 與該機 Dashboard Saved ngrok accounts 內已保存的 credential；token 不應貼入對話。尚未用真實新帳號驗證 Agent／Cloud Endpoint 切換及恢復。
5. **關閉 Codex／登出／重開機耐久性**：未執行這些使用者工作階段操作，不能由目前 heartbeat 與排程 Running 狀態推論全部通過。
