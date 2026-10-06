# Windows Watchdog 心跳與管理頁回應修復

健康檢查使用背景 PowerShell runspace，但舊版逾時後在 Host 主迴圈同步呼叫 Stop()。若檢查停留在原生呼叫，取消也會等待，連帶停止管理頁與心跳更新。自動服務修復同樣曾在套用檢查結果時同步執行。

修正使用非同步取消，直到工作結束才釋放唯一的檢查槽；取消未完成時不建立替代工作。管理頁顯示 Health check delayed，設定交易暫時拒絕執行。自動服務修復沿用既有背景交易槽與管理鎖，退出時等待交易及檢查收尾。此修正隔離慢呼叫，不強制終止執行緒；原生呼叫若永不返回，檢查會維持延遲狀態，不能宣稱監測已恢復。

Supervisor 現在在程序查詢後重讀心跳，並在停止前確認兩次相同程序身分與失效原因。讀取失敗、程序身分不明或已恢復正常時保留程序，記錄 recovery_deferred 或 recovery_suppressed；確認過期或工作階段不符才記錄 recovery_started 並進入既有身分驗證與停止流程。

驗證包含 watchdog-health-responsive.test.ps1：在原生等待中觸發取消，透過正式 Host 主迴圈持續發送真實 HTTP 請求並讀取心跳，另驗證背景修復、單一檢查槽及退出收尾。watchdog-supervisor.test.ps1 涵蓋短暫讀取失敗、慢程序查詢、停止前恢復、身分變化與工作階段判斷。兩項測試均可用 -SourceDirectory 指向舊版來源作反向驗證，並已納入 npm run test:windows-watchdog。

部署先備份 runtime 與安裝記錄，經 Bootstrap Stop、排程退出及 CheckStopped 證明後替換已驗證檔案，再由既有排程啟動並驗證真實 MCP 呼叫。有限時間的測試不能保證日後所有網路、記憶體或服務故障均不會發生。
