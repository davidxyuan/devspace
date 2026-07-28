# Windows 混合版本升級與 TYO 能力驗證報告

日期：2026-07-28

## 1. 問題背景

TYO 曾出現以下混合狀態：

- DevSpace：`1.0.4`，已在 `codex/windows-fixed-port-conflicts` / `ca7c10a`
- Hermes-GPT：`0.2.0`，仍在舊版 `master`

原本的 `upgrade-existing-tested-stack.ps1` 只接受：

1. DevSpace 與 Hermes-GPT 都低於目標版本：整套升級。
2. DevSpace 與 Hermes-GPT 都等於目標版本：只套用能力設定。

其中一個元件先升級、另一個仍舊時，installer 會以 mixed state 拒絕，無法接手部分成功、人工修復或分階段部署。

## 2. 新 installer 設計

### 2.1 逐元件狀態機

DevSpace 與 Hermes-GPT 各自判定：

- `Keep`：版本與受測 commit 均符合。
- `Upgrade`：版本低於受測目標。
- `Refuse`：版本高於目標、版本相同但 commit 不符、repo 或 remote 無法辨識。

兩個元件狀態組成整體動作：

- `Upgrade`：兩者都升級。
- `UpgradeDevSpace`：只升級 DevSpace。
- `UpgradeHermes`：只升級 Hermes-GPT。
- `CapabilitiesOnly`：兩者都已是受測版本，只更新能力設定或驗證。

### 2.2 安全機制

已實作：

1. **固定版本與 commit**：不以 branch 最新 HEAD 當成安裝目標。
2. **remote 依 URL 辨識**：支援 `origin`、`fork` 或其他名稱，也正規化 HTTPS／SSH GitHub URL。
3. **只要求待升級元件 repo 乾淨**：保留元件不因 build 產物或其他元件狀態被誤擋。
4. **停止權限預檢**：在停止排程或服務前，用 Windows process handle 驗證 installer 是否有權終止所有受管理 PID。
5. **固定 Port 保護**：DevSpace、Hermes、Router Port 被未知程序占用時拒絕搶占，不自動換 Port、不終止未知程序。
6. **串流 MCP 健康檢查**：HTTP 只讀取 response headers，避免 `/mcp` stream 因保持連線而被誤判逾時。
7. **本機完整 installer package**：既有機器升級不再執行 mutable raw branch 腳本；升級邏輯、Watchdog 與 OAuth migration 必須來自同一 checkout/package。
8. **一致性備份**：保存關鍵 `.devspace` 設定、OAuth／SQLite state、Watchdog task XML、Git bundle、回復 branch、Hermes venv 與 Hermes home。
9. **按元件操作**：只對需要升級的元件執行 fetch、checkout、npm/pip install、build 與 tests。
10. **自動 rollback**：安裝、設定或健康檢查失敗時，預設嘗試恢復原 commit、runtime、設定與排程。
11. **背景執行器**：可把升級請求寫成 JSON，由獨立 PowerShell process 執行並輸出 `status.json`，避免 MCP 本身重啟時中斷升級流程。
12. **完整 package validator**：在其他電腦執行前檢查必要腳本與 PowerShell parser。

## 3. TYO 實機開發期間發現並修正的問題

### 3.1 PowerShell 大小寫變數碰撞

PowerShell 變數不分大小寫。第一版同時使用：

- `$HermesVersion`：目標版本
- `$hermesVersion`：目前版本

兩者其實是同一變數，造成舊 Hermes `0.2.0` 被誤判成「版本相同但 commit 不符」。

已改為明確命名：

- `$PinnedHermesVersion`
- `$CurrentHermesVersion`
- `$PinnedDevSpaceVersion`
- `$CurrentDevSpaceVersion`

此問題由真實 Git worktree fixture 發現，不是只靠單元測試。

### 3.2 舊 Hermes PID 權限較高

舊 Hermes process 由較高權限啟動，User-mode Watchdog 無法停止。新 installer 現在會在任何服務停止前先檢查 process terminate 權限，並要求使用系統管理員 PowerShell或先手動停止，不會在半停機狀態才失敗。

### 3.3 `/mcp` 是串流 endpoint

一般 `Invoke-WebRequest` 等待 body 完整結束會逾時。新版改成 `HttpCompletionOption.ResponseHeadersRead`，只要取得可接受的 HTTP status 就完成健康檢查。

### 3.4 ChatGPT App 工具 schema 可能過期

本機 MCP Runtime 重啟後可以註冊新增工具，但 ChatGPT 已建立的 App 不一定自動重新掃描。Hermes doctor 也回報 connector re-registration 無自動 API；需要在 ChatGPT 端重新連線、重新掃描工具，必要時移除後重建 App。

## 4. 四種版本組合實機 fixture

使用真實 Git worktree 與 TYO 現有設定執行 `-DryRun`：

| DevSpace | Hermes-GPT | 偵測結果 |
|---|---|---|
| 1.0.4 / 受測 commit | 0.5.0 / 受測 commit | `CapabilitiesOnly` |
| 1.0.4 / 受測 commit | 0.2.0 / 舊 commit | `UpgradeHermes` |
| 1.0.1 / 舊 commit | 0.5.0 / 受測 commit | `UpgradeDevSpace` |
| 1.0.1 / 舊 commit | 0.2.0 / 舊 commit | `Upgrade` |

四種組合全部正確判定，沒有修改正式服務。

## 5. Installer 測試結果

以下全部通過：

- PowerShell parser
- capability dependency validation
- mixed component state tests
- fixed Port conflict policy tests
- Watchdog Hermes health tests
- ngrok install tests
- tested stack installer tests
- existing stack upgrade safety-marker tests
- detached runner Dry Run 與 `status.json`
- installer package validator
- `npm run test:windows-watchdog`
- TYO current-state live Dry Run

## 6. TYO DevSpace GPT 能力實測

### 6.1 本機 Runtime

- `127.0.0.1:7676/healthz`：HTTP 200
- Watchdog capability：`toolMode=full`
- Widgets：`full`
- Skills：開啟
- Subagents：開啟
- Full-mode source 已確認會註冊 `grep`、`glob`、`ls`，以及基本 `open_workspace/read/edit/write/bash`。

### 6.2 Sub-agent provider

本機 provider availability snapshot：

- Codex：available
- Claude：available
- OpenCode：available
- Pi：available
- Cursor：available
- Copilot：available

實際 session 測試：

- Codex session 成功建立並啟動 worker，但 provider 回覆：本機 Codex CLI 太舊，不支援目前的 `gpt-5.6-sol`，需要升級 Codex CLI。
- OpenCode session 成功建立並啟動 worker，但 OpenCode server 在 5 秒內未完成啟動而逾時。

結論：DevSpace Sub-agent 框架、session store、detached worker 與 provider discovery 正常；個別 provider 還需版本／啟動設定修復，不能只因 availability=true 就宣告 end-to-end 成功。

### 6.3 ChatGPT DevSpace App

本次驗證期間 `cloud_endpoint_devspace_tyo` 在 ChatGPT 端被停用，無法繼續直接呼叫；先前 App schema 只顯示 5 個工具，未包含 full-mode 的 `grep/glob/ls`，且 `open_workspace` 曾回傳空的 agent provider 清單。

這與本機 source/config/provider snapshot 不一致，判定為 ChatGPT App schema／連線未重新載入。需要重新連線或重建 DevSpace App 後再做最終 MCP end-to-end 測試。

## 7. TYO Hermes GPT 能力實測

### 7.1 已成功

- Operator：`enabled=true`
- Level：`owner`
- Apply mode：`direct`
- Owner mode ready：`true`
- Terminal：實際執行成功
- Private Network：透過一般 Hermes Terminal 存取 DevSpace health，HTTP 200
- Workspace Read／Write／Patch：實際成功
- Workspace Run Test：`git status --short` 實際成功；PowerShell／cmd 被安全 allowlist 正確拒絕
- Base Write／Patch：實際成功
- Skill Create／View／Delete：實際成功
- Cron registry／heartbeat：可讀、正常，目前 0 jobs
- Session search：可執行
- Gateway：running
- Bridge／Codex Runner status：enabled、write enabled、Codex CLI available
- Codex Runner Dry Run：成功產生真實 Codex CLI argv
- Runtime tool registration：本機 `build_server().list_tools()` 包含 Vision、Web、Codex、Cron、Skills、Workspace、Owner 等完整工具

### 7.2 功能開啟，但外部 provider／環境尚未完成

- **Web**：工具與環境 gate 已開；實際搜尋進入 Hermes web provider，但 TYO 沒有 Firecrawl／其他 Web provider 設定，因此失敗。
- **Vision**：工具與環境 gate 已開；本機圖片成功讀入、轉 base64 並進入 vision model selection，但公司 SSL／provider connection 失敗。
- **Memory Write**：環境 gate 已開，但 Hermes memory backend 回覆「Memory is not available」，需要在 Hermes config 完成 memory backend。
- **Codex Runner 實際背景工作**：工作成功啟動並取得 PID/thread ID；測試是從短生命週期 Python child 啟動，child 結束後 watcher metadata 被標為 orphaned。要以 ChatGPT 直接暴露的 `hermes_codex_*` MCP 工具重測，需先重新掃描 Hermes App schema。

### 7.3 ChatGPT Hermes App schema

Hermes Runtime 實際註冊的工具多於 ChatGPT 目前顯示的工具。ChatGPT App 尚未直接顯示：

- `hermes_vision_analyze`
- `hermes_web_search`
- `hermes_web_extract`
- `hermes_codex_*`
- 部分新 cron/operator 工具

需要重新連線／重新掃描 Hermes App。重新掃描後才能做真正由 ChatGPT 直接呼叫這些新工具的最終驗收。

## 8. 跨電腦部署結論

新 installer 已具備跨電腦升級所需的主要安全能力，但正式部署仍應遵守：

1. 使用完整、固定 commit 的 installer checkout/package。
2. 先執行 package validator。
3. 先執行 `-DryRun`。
4. 既有機器建議用系統管理員 PowerShell。
5. 透過 MCP 發動時使用 detached launcher。
6. 確認 backup 路徑與 `status.json`。
7. 完成後重新掃描 ChatGPT 的 DevSpace／Hermes App 工具。
8. 另外配置 Web、Vision、Memory 與各 Sub-agent provider，不把「開關已開」等同「provider 已可用」。

詳細操作見：`docs/windows-tested-stack-install-upgrade-guide.zh-TW.md`。
