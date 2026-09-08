# 本機 Tray 部署與驗證：2026-09-08

電腦：C02250073。安裝目錄：`C:\Users\david.yuan\.devspace`。

## 已部署

- 登入自動啟動 `Watch` supervisor；桌面、開始功能表的 `DevSpace Tray` 捷徑。
- Host、Tray 同時退出的自動復原；手動停止標記與升級鎖。
- Hermes 本機 OPTIONS 探測的明確逾時訊息，不再誤標為 public probe。
- Cloud Policy 預覽、備份、API 套用、讀回驗證；保留既有安全規則順序。
- MCP 名稱後綴欄位，以及管理代理遺失錯誤回應內容的修正。

最後一次安裝備份：
`C:\Users\david.yuan\.devspace\configuration-backups\tray-install-20260908-121124-83705c8c`

## 實機證據

- Dashboard：`http://127.0.0.1:8777/`，Healthy。
- DevSpace、Hermes 公開 MCP 探測皆 protocolHealthy=true。
- 12:06:40 雙程序退出復原：舊 Tray/Host PID 52888/47208，復原後 21880/26032；四個後端服務 PID 完全不變。
- supervisor 有獨立心跳；最終安裝等待並驗證 supervisor 自身 PID，而非僅驗證 Host/Tray。
- 桌面捷徑與 HKCU Run 皆指向目前安裝目錄的 bootstrap `-Mode Watch`。
- Cloud API 路徑通過本機代理驗證，回覆本機為 Agent Endpoint、無需 Cloud Policy。BOM 設定檔可正常讀取，錯誤內容不再遺失。
- 最終 `npm run test:windows-watchdog` 全部通過，套件檢查涵蓋 39 個必要檔案；`git diff --check` 通過。

## 驗證界線

- VBS 在本機啟動 PowerShell 時回覆「沒有使用權限」；登入與捷徑使用直接 PowerShell 啟動，未變更安全策略。
- 舊排程無權停用，已以腳本支援的標記暫停工作；排程本身仍會啟動，因此無法保證其不閃窗。重開機不能解除權限限制。
- 沒有實際重開機；已驗證登入啟動設定與執行中 supervisor。
- 「手動停止後以桌面捷徑重開」實機測試被自動批准審查以 `blocked by policy` 拒絕，未執行；手動停止標記已有模擬測試。
- 未取得 ngrok API Key，未對真實 Cloud Endpoint 執行 PATCH；預覽、規則保留、一次性套用、讀回、BOM 設定與安全規則順序由可執行模擬測試驗證。
- 三台舊機僅執行唯讀升級檢查，詳見同目錄的 `windows-upgrade-preflight-20260908.zh-TW.md`，未宣稱已升級。
