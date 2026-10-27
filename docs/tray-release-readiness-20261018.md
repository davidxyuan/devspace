# Tray／watchdog 正式版準備：執行結果

更新：2026-10-27，台灣時間。**候選的來源選擇與更新前檢查已實作，保留既有 gateway 監督器的升級阻擋。官方新版的隔離 MCP 讀取，以及另加 Windows 控制管線修正的真實 gateway 啟動／故障恢復／更新交接／正常停止已通過。10/25 補上可重播的 Windows 補丁與直接啟用 PM 的阻擋。完整升級回復與 VM 生命週期仍待驗證；正式版尚未完成，也未部署。**

基準 `9c06667745470b8470b53bdbaefc88d011ad76d8`；獨立目錄 `D:\devspace-release-20261018`；候選分支 `codex/tray-release-readiness-20261018`。正式 `D:\devspace` 與目前服務未切換；現場查核限 TYO，其他四台未操作。

10/26 完整 Windows watchdog 回歸退出 0，包含 49 個必要套件檔案檢查。10/27 型別檢查、建置、完整核心測試、隔離 CLI 啟動皆退出 0；PM 準備 9 項、gateway 監督器 17 項測試通過。監督器測試保留不明 owner 的案例曾產生 `ResourceWarning`，其測試子程序隨後自然退出，查核時已不存在。CI 已納入此候選分支的 push 及手動執行，Windows 回歸前先準備 Python。遠端 CI、正式部署與 VM 證據須分開核對，不能由本機通過推定；以下 10/25 以前的紀錄保留其當時範圍。

## 已完成的程式修正

- **資料回復：** 透過實際 DevSpace 設定取得資料庫位置；先確認新舊位置相符，再停止已識別服務並備份 SQLite、WAL／journal。快照與回復取得整組檔案的獨占鎖；備份雜湊不符或有其他寫入者時中止。候選啟動失敗後，一併回復設定及資料。涵蓋自訂資料目錄、未 checkpoint 的已提交 WAL、首次安裝、檔案占用及備份損壞測試。
- **Agent 來源同步：** 啟用／回復一起切換 `hermesAgentExe` 和 `hermesAgentWorkingDirectory`；Host、舊 watchdog、安裝器產生的 launcher 都傳入獨立 `HERMES_AGENT_ROOT`。來源與使用者資料目錄分開；無效來源、混入舊模組或缺依賴會拒絕啟動。安裝／更新在停止服務之前，用實際 GPT Python 與暫存資料驗證必要模組的真實來源；檢查禁止自動安裝依賴，並有 30 秒上限。管理工作副本與發布包均包含該檢查程式。
- **來源建置：** 按候選的單一 lockfile 與固定 `packageManager` 使用 npm／pnpm，執行建置及測試；工具只裝在候選目錄。啟動入口取自套件 `bin.devspace`，驗證實際路徑留在套件內。歧義鎖檔、工具版本不符、缺測試、入口越界均拒絕。
- **固定安裝組合：** 安裝器與管理器共用 `stack-release-manifest.json`。乾淨安裝固定來源／提交／版本；npm 另核對完整性。Agent 固定來源安裝失敗會保留現場並報錯，已移除改跑浮動官方安裝器的 fallback。
- **發布檢查：** CI 補上 source build、核心／Windows 測試、隔離實際啟動，再打包與乾淨 VM 驗證。ZIP 只有成功才上傳，失敗診斷另存；包內來源 SHA／dirty／fingerprint 必須一致。新增執行期檔案已納入包內容及完整性檢查。
- **上游發現：** 新增三個官方來源的固定 release 查詢、錯誤狀態與每週 GitHub Actions 工作流程。查詢已在本機實測；workflow 尚未推送／啟用。它只產出候選資訊，不自動安裝、合併、建立 PR 或提升 stable。
- **新版安裝契約：** 發現 Hermes Agent 的 `pm/lock.json` 時，舊快速安裝器與更新器在建立 venv／pip 安裝及切換服務前拒絕，保留現場。官方 `pyproject.toml` 的占位版本 `0.0.0` 不再顯示為真正 release 版本，改用已解析至提交的發行標籤。這是相容性阻擋，尚不是完整 PM 更新支援。
- **候選驗證資料隔離：** Hermes 更新器的 venv 建立、依賴安裝、模組匯入、測試及 CLI smoke 共用候選內的獨立資料／暫存目錄；只保留必要系統環境，不繼承現用 profile、API key、Owner gates 或 Python 路徑。驗證禁用 Agent 自動安裝依賴，明確啟用 GPT HTTP 測試。這是避免誤用現場資料的環境隔離，不是限制程式檔案存取的 OS 沙箱。
- **官方 PM 候選準備入口：** `scripts/windows/prepare-hermes-pm-candidate.py` 從指定的官方來源 checkout 核對完整提交，將已提交內容取到全新目錄，再用官方 `pm.build_env` 建置 frozen `all` 依賴；不複製原目錄的忽略／未追蹤檔案。保存來源／鎖檔雜湊、實際 Python 與套件版本、三項 CLI smoke、各步退出碼及失敗紀錄。已有輸出不可覆寫；`preparation.json` 固定 `activationEligible=false`，不是更新器的 `candidate.json`。新增手動 GitHub Actions 入口及 CI 行為測試，尚未推送或執行遠端工作流程。
- **保留 gateway 監督器：** Agent 更新交易目前只管理 GPT，無法安全停止及回復獨立 gateway。新增停服務前檢查：既有 `Hermes_Gateway*.vbs`／`.cmd` 或同名排程存在時阻擋更新；Running／Ready／Disabled 都不當成 gateway 已退出，排程查詢錯誤也直接中止。移除啟用及 rollback 時重新產生 launcher 的行為，避免快照還原後又覆蓋客製監督器。這是已知 launcher／排程的保護，不是完整手動 gateway 探測或生命週期支援。

現在的 release policy 只接受 `candidate`，沒有可用的 stable 提升流程。手動指定更新仍按已登錄來源取得固定候選提交，再跑原有隔離建置／測試；這不等於整組 stable 驗證。後續正式提升必須綁定同一來源提交、產物雜湊和實際證據，不能只靠 JSON 自稱 passed。

## 目前固定組合的界線

| 元件 | 乾淨安裝候選 |
|---|---|
| DevSpace official | 1.0.8／`fe712e2b6c07231d2a76503bf2a674b165850616`，npm integrity 固定 |
| Hermes GPT | 0.14.0／`8306b95a95281f3ac2014a1237aa26e68b3f49b4` |
| Hermes Agent fork | 0.21.1／`601d98c2709f766290cc3627b035ab73cfd54232`，沿用原快速安裝的固定基準 |

這不是 TYO 現在的安裝組合，也未宣稱三者已整合通過。Agent 不是目前 TYO 的 0.21.3，更不是官方 0.22.2；既有安裝不會被這份清單直接降版。清單內未修補的官方 GPT 尚不具備新的來源契約，會被新檢查拒絕；修補後產物尚未發布並重新固定，因此這份清單目前不可當作正式整組安裝。Python 遞移依賴尚未完整鎖定至正式清單，仍不足以宣稱正式安裝完全可重現。Node 24.14.0 是本次本機驗證版本，非所有受支援 Node／OS 組合均已測過。

## 實際通過的驗證

- `npm ci`、`npm run typecheck`、`npm run build`、完整 `npm test`。
- 來源契約修正後完整 `npm run test:windows-watchdog` exit 0；包含真實隔離更新、資料回復、跨程序工作、排程保護、Host／Tray 回應與 Router 回歸。其後新增的 PM 拒絕、版本顯示、預檢禁用自動安裝及候選資料隔離，以相關管理器／安裝器／預檢測試驗證通過；實際元件更新 E2E 另確認子程序沒有繼承父程序的假 API key／Owner gate，僅寫候選資料目錄，強制啟用失敗後回復設定及原服務狀態。部分服務程序仍為模擬，不能取代實際登入／重開測試。
- 實際候選 CLI 在獨立設定、隨機埠與臨時資料庫啟動：healthz、OAuth discovery、MCP 未授權拒絕與資料庫建立皆通過。
- 上游查詢／固定版本契約測試通過。npm 打包清單已確認包含 `stack-hermes-source.py`；發布包檢查通過。本次沒有發布 ZIP。
- Hermes GPT 候選 Python 3.11 完整回歸：1690 passed、15 skipped，HTTP smoke 已啟用；新增測試環境隔離案例另外 5 passed。套件建置、twine check 與 hygiene 通過，產出 wheel／sdist，未發布。
- 同一候選在 PM Python 3.14.7／新版依賴的完整回歸：1691 passed、15 skipped，HTTP smoke 已啟用，279.92 秒。第一次完整執行的憑證 relay 測試曾遇到 Windows 10053 連線中止；單案、同組 44 項與第二次完整執行通過，未改 timeout、測試或 relay 實作。首次失敗原因仍未確認，不能抹成從未失敗。
- 另以官方 Windows `all` 的 118 個執行期套件版本建立 GPT 測試環境，完整回歸 **1691 passed、15 skipped，335.70 秒，exit 0**；這次包含 MCP 2.0.0，與上述核心依賴環境分開保存。59 個交付模組的候選來源、wheel、實際安裝檔雜湊相同，執行期與測試環境的 118 個版本相符；這是本機完整性查核，非簽章或 stable 發布證明。
- 官方 Agent 使用 canonical `scripts/run_tests.sh` 驗證啟動器選擇、更新重建入口、Windows gateway 冷啟動／desktop 生命週期及 job teardown：**4 檔、11 passed、exit 0**。主要為模擬測試及測試子程序，未在本機註冊真實 gateway 排程，不能取代 VM 啟停／登入／重開證據。
- 10/21 更新交易修正後，管理器、實際元件更新／失敗回復 E2E、SQLite 回復 E2E、activation E2E、46 個必要檔案的發布包檢查及 `git diff --check` 通過。最後補強的 activation E2E 再次通過：分別只有 VBS、只有 CMD、三種排程狀態及查詢失敗時，設定／原 launcher 不變，排程事件與控制 Host 呼叫數不增加。這些使用臨時安裝目錄及模擬的服務／排程 API，不代表真實排程整合已完成。
- 新增 PM 準備入口已完成兩次獨立的實際 frozen 建置，最後一次另核對結束時 HEAD：Python 3.14.7、115 個 Agent runtime 套件、三項 CLI smoke 退出 0，兩次輸入鎖檔雜湊及套件版本相同。最後增加的 UTF-8 參數修正另以真實 Git／venv 的中文與空白路徑 fixture 驗證；**7 項行為測試通過**，涵蓋錯誤提交、已有輸出保留、PM／CLI 失敗、鎖檔變動、乾淨檔案但 HEAD 被改變。fixture 不替代真正官方建置。準備入口只產生 Agent runtime，故其 115 個套件與含 GPT 的 118 個套件環境不同。
- 官方 Agent 0.22.2 經 PM 的鎖檔建置，在獨立 Python 3.14.7 環境通過核心依賴安裝；再以核心已安裝版本與 GPT 候選 wheel 建立獨立 PM side environment。實際 MCP initialize／tools list／operator status／兩行檔案讀取通過，必要模組均來自固定官方 Agent 來源，operator 維持 read_only、owner inactive。這是本機 stdio MCP，不是正式 connector 或 ChatGPT 網頁驗證。
- 既有 TYO 的兩個真實 Codex connector 唯讀呼叫成功：DevSpace `package.json` 1–8 行、Hermes `hermes_operator_status`。這是現行服務的證據，不是候選，也不是 ChatGPT 網頁長串流。

曾有個別測試在並行工作時未取得慢速客戶端結果；沒有藉修改 timeout 掩蓋，獨立重跑及最終完整順序回歸均通過。過程中舊 fixture 的浮動版本假設已隨固定版本契約修正。原始失敗記錄保留。

主要證據在 `C:\Users\david.yuan\Documents\Codex\2026-10-06\d\outputs`：

- [來源修正後完整 Windows 回歸](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261019-source-windows-full.log)
- [核心測試](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261018-core-tests.log)
- [上游固定版本快照](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261019-upstream-discovery.json)
- [真實 MCP 唯讀結果](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261019-mcp-readonly.json)
- [觀察器分解結果](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261019-observer-review.json)
- [Hermes GPT 完整回歸](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-release-20261019-final-full-tests.log)
- [官方 Agent PM 建置](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261019-pm-build.json)
- [新組合真實 MCP 驗證](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261020-mcp-verified.json)
- [Python 3.14 完整回歸](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-release-20261020-python314-confirmation.log)
- [保留的首次 relay 失敗](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-release-20261020-python314-full.log)
- [更新器候選資料隔離測試](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261020-validation-isolation-green.log)
- [隔離資料與實際更新回復 E2E](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261020-validation-isolation-e2e-canonical.log)
- [官方 all 依賴建置](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261020-pm-all-build.json)
- [all 環境啟動入口](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261020-cli-all-smoke.json)
- [all 組合實際 MCP 讀取](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261020-mcp-all-verified.json)
- [all 依賴 GPT 完整回歸](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-release-20261020-python314-all-full.log)
- [候選來源／wheel／安裝檔完整性](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-release-20261020-candidate-integrity.json)
- [官方 Agent 入口與生命週期測試](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261020-launcher-tests.json)
- [gateway 退出碼相容性探針](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261020-gateway-exit-contract.log)
- [PM 候選準備行為測試](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261020-pm-prepare-unicode-final-tests.log)
- [固定提交實際 PM 準備結果](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261020-pm-preparation-final.json)
- [兩次獨立 PM 建置比對](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261020-pm-repeatability.json)
- [gateway 更新交易回歸](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261021-gateway-regression.json)
- [最後版本的 activation 行為測試與來源雜湊](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261021-gateway-final-activation.json)
- [官方 gateway 契約查核，含保留的失敗](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261021-gateway-contract-complete.json)
- [Windows 真實子程序存活／自然退出探針](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-agent-20261021-windows-liveness.json)

## Hermes 來源整理與新版相容性

現場 GPT 位於 `C:\Users\david.yuan\hermes-gpt-v010-canary`，HEAD `eb7ab43b581377323492fd6aee78e82c56985413`，tracked 檔案乾淨，但仍有未追蹤 `nul`，未刪除。候選 `D:\hermes-gpt-release-20261019` 以官方 v0.14.0／`8306b95a95281f3ac2014a1237aa26e68b3f49b4` 為基準。官方已有的程序存活與 gateway 健康查核保留；只移植仍缺的 Windows 隱藏視窗與逾時子程序清理，再加入明確來源選擇。逾時後若子程序無法清除，會在限定時間返回清理未確認，避免因繼承管線而無限阻塞。

Agent managed payload 的 HEAD 為 `bc22af07d94b8bd67c3a95b6c4d6d189472b7052`，有 Windows gateway launcher 監督修正；`hermes_cli/model_switch_providers.py` 另有未提交的 Nous 模型清單上限調整與 `.bak.nous-uncap-20261012`。原檔均保留。

**已由真實 MCP 確認：GPT 實際回報的 Agent root 仍為舊 `AppData\Local\hermes\hermes-agent`，與設定中的 managed Agent 執行檔不同。** 目前及官方 v0.14 的 `candidate_roots()` 都會搜尋舊預設目錄，沒有獨立 `HERMES_AGENT_ROOT` 選擇契約。Tray 設定 cwd／PATH 不等於更換 Python 載入來源。不可用把 `HERMES_HOME` 改成程式碼目錄的方式修補，因為它還承載使用者資料／profile。

明確來源契約已在候選中實作並完成上述真實 MCP 核對；現行服務尚未部署此修正，原不一致仍待受控切換解除。

官方 Agent 候選 `D:\hermes-agent-release-20261019` 固定於 [v0.22.2](https://github.com/NousResearch/hermes-agent/releases/tag/v0.22.2)／`d923a5eb487a17c0a68801bba9ef0f56c81040a8`，沒有修改。官方已包含 Nous picker 的 uncapped 名單，不再盲目攜帶現場同目的補丁；Windows gateway 生命週期已大幅變動，仍須實際啟停／登入／重開驗證，不能只由靜態比對宣稱舊修正全部被取代。

新版由官方 PM 管理工具、Python 3.14、依賴與啟動環境；`pyproject.toml` 的 `>=3.11,<3.15` 是讓舊版能進行更新，不能解讀為新版仍以 Python 3.11 運作。整合資料在 `D:\hermes-agent-validation-20261019`，包含獨立工具、資料、快取、生成的 lockfile 與 side environment，沒有改現行環境。合併依賴的最初查詢曾因 UnknownIssuer 失敗，原記錄保留；改用 PM 支援的作業系統信任憑證後成功，沒有關閉 TLS 驗證。這份 Windows 相容性環境不是完整官方 gateway／desktop 安裝，也尚未接入 Tray 更新交易。

10/20 已再用官方鎖檔建立 `all` 環境，`--version`／`--help`／`gateway --help` 均退出 0。以實際 Windows `all` 依賴精確版本加 GPT wheel 建立的另一個 PM side environment，共 118 個 distribution；來源預檢與兩個真正 MCP 唯讀呼叫也通過。`all` 是官方常用依賴集合，並非所有 messaging/provider extras；尚未啟動 gateway，也未驗證登入排程或取代現用 launcher。這組 MCP 2.0.0 與核心相容性測試的 MCP 2.3.0 不同，兩份結果必須分開判讀。

**新增的明確升級阻擋：官方 Windows gateway wrapper 不提供外部異常退出後的自動恢復。** 官方 `website/docs/user-guide/messaging/index.md` 明列 launcher 故意立即退出，Task Scheduler 的 RestartOnFailure 只涵蓋 launcher；真正 gateway 意外退出後需人工重啟。對官方產生的 CMD／VBS，以只寫 marker 後退出 37 的測試子程序實測，wrapper 回傳 0；沒有啟動正式 gateway 或改排程。探針另有一個正常退出 VBS 的 marker 競態，也是非同步啟動造成，不能當成另一個產品故障。這是官方已知設計與本地監督需求不相容，不能稱為新發現的上游 regression。現場舊版另有等待退出及有限重試的客製 VBS；新版自身還有 `/restart` 的程序重開協定，因此不可直接把舊迴圈貼回或只改成等待子程序就宣稱修復。

候選準備可使用下列入口；輸出只能放在全新、來源目錄以外的位置。它準備供驗證的 runtime，不產生可安裝 release，也不切換 Tray 設定。完整升級／回復仍需另行整合 gateway 監督與 GPT 配對環境。

10/21 進一步核對官方 `gateway run --external-supervisor`：主動重啟透過退出碼 75 交回外部管理器；致命設定錯誤使用 78。官方一般 Windows task launcher 的 `HERMES_SUPERVISED_CHILD` 只表示受監督啟動，不代表它能接手這個重啟協定。將兩者混用會讓 gateway 退出後無人重新啟動，因此不能只替舊 VBS 加一個等待參數。

在全新的官方 PM frozen `all`／`dev`／`test` 環境，以 canonical runner 查核上述契約及 restart-loop guard，**41 passed、1 failed**，不是全綠。唯一剩餘失敗是官方 `test_pid_exists_zombie_via_psutil_returns_false`：它模擬 POSIX zombie，卻未限制平台；實作明確在 Windows 跳過 zombie 探查、以 `pid_exists` 為準。另以真實 Windows 測試子程序檢查存活及自然退出，1 passed，沒有送出停止訊號或啟動 gateway。保留官方來源與失敗紀錄；這不足以證明所有 PID 重用／權限／崩潰情境都正確。首次查核另有缺少 `pytest-asyncio` 的環境失敗，之後改建官方完整測試環境，未直接修改既有 GPT 測試環境。

已新增 `scripts/windows/hermes-gateway-supervisor.py`，只接受全新隔離 profile 與已核對的 PM runtime，提供前景執行、官方正常停止標記、75 交接、78 停止及 15 分鐘最多四次啟動。檔案鎖防止同 profile 雙重管理；PID 加開始時間不符、未知 gateway、未結束的前輪或存活子程序都保留現場並阻擋再次啟動，不強制終止。此候選尚未接入 Tray／排程／升級交易；完整說明見 [隔離 gateway 管理器](hermes-gateway-supervisor.md)。

10/21 在準備好的 Python 3.14 runtime 中，15 項 Windows 程序測試通過，涵蓋正常退出、75、78、異常退出重試上限、停止與重試競態、孤留子程序、排他鎖及未知身分保留。測試抓到的「重試等待尾端收到停止要求仍多啟動一次」已修正為每次啟動前再次檢查停止要求。測試使用真實無害子程序及模擬 gateway 身分／停止介面，不等於真實 gateway 恢復。保留未知身分的案例刻意讓 fixture 自然退出，Python 因管理器未強制等待該程序而留下 ResourceWarning；程序最後已自然退出。

10/21 準備的真正官方 gateway 隔離 loopback 探針，當次在啟動前因主機可用 RAM 低於 1.5 GiB 門檻中止，沒有啟動 gateway 或寫入測試 adapter 設定。當時真實 gateway 異常退出恢復尚未驗證，原始證據保留：`outputs/hermes-gateway-supervisor-20261021-evidence.json`、`-tests-current.log`、`-real.log`。10/24 的新結果見下節，未合併或覆寫這次中止紀錄。

### 10/24 真實 Windows gateway 隔離驗證

原自製啟動形狀無法通過官方嚴格 PID／開始時間／命令列身分核對，管理器改用官方 `runtime_command`。另修正 launcher 已退出、已知子程序仍在自然退出時過早判定殘留的競態：先進入 `waiting_descendants`，在既有 180 秒停止預算或剩餘預算內等待；仍有存活者就保留並阻擋，不強制終止、不增加停止上限。管理器共 **17 項測試通過**。

未修補官方 Agent 的兩次真實執行皆在 `pause-for-update` 未取得 ACK；已定位 Windows named pipe 同步處理器卡住 asyncio 迴圈，而 pause handler 又等待同一迴圈。於另一個官方來源工作副本 `D:\hermes-agent-control-fix-20261024` 以 `asyncio.to_thread` 移出處理器，保留 profile context 及單一請求語意，未延長客戶端 2 秒 timeout。本地提交 `7bfe8dcfb5ca0ecebbe61ac0f13ae03fd52f119f` 以官方 `d923a5eb487a17c0a68801bba9ef0f56c81040a8` 為基準；原官方候選目錄未改動。canonical runner 相關三檔 **5 passed、19 POSIX skipped、0 failed**；`scripts/check` **12 checks 通過**。這不是完整官方測試套件通過。

此修補提交在 `D:\hermes-pm-control-fix-20261024` 重新 frozen 準備；115 個 runtime 套件版本及三個依賴輸入雜湊與原準備結果相同，三項 CLI smoke 退出 0，仍為 `activationEligible=false`。r4／r5 在實際啟動前 RAM 門檻失敗，profile 保持零次啟動、沒有測試 `.env`。r6 前連續三筆 psutil 可用 RAM 為 1787.27、1804.74、2054.70 MiB，通過 1536 MiB 門檻。

**r6 真實測試通過**：獨立 profile、loopback API；首次 PID 67696，注入該測試子程序自行 exit 37 後約 9.05 秒，替代 PID 71396 的 HTTP、live pipe identify 與 runtime status 均就緒。官方更新暫停 ACK 成功，接著替代 PID 65200 就緒。三次都核對 PID／開始時間／home／來源 SHA；最後透過官方停止標記正常退出，manager exit 0。獨立收尾核對 47 個觀察到的 PID／開始時間身分全數退出，5320 埠無監聽。log 中的 unclean-exit 警告對應故障注入；空白測試 profile 的 Nous 認證缺少警告保留，未執行模型／聊天測試。

同次 TYO 現行服務的兩個真實 Codex connector 唯讀呼叫成功；測試前仍存活的六個現行程序身分未變。另兩個早上紀錄的程序在 r6 前已不存在，不能宣稱所有現場程序整日未變，也不能將其退出歸因此測試。原有更新前保護維持，沒有切換現場 launcher。子程序追蹤仍使用輪詢，無法證明瞬間脫離父鏈的程序不存在；正式接管仍需程序容器／擁有權與 VM 生命週期驗證。**此結果只驗證更新交接，不是實際更換版本／rollback、ChatGPT 長串流或新的 24 小時觀察通過。**

完整證據索引：[10/24 完成紀錄](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/hermes-gateway-supervisor-20261024-completion.md)。先前啟動身分失敗、兩次未收到 ACK、暫態子程序誤判及 RAM 門檻中止資料全部保留，沒有以通過結果覆蓋。

### 10/25 更新相容性與直接啟用保護

已把昨天驗證的控制管線修正及兩項回歸測試保存為 `scripts/windows/patches/hermes-windows-control-pipe.patch`。候選準備入口可明確傳入 `--patch`，只在全新 snapshot 先做 `git apply --check --index`，再套用及記錄本地提交；保留官方基準提交、修補提交、補丁 SHA-256 和實際補丁。衝突或官方已納入修正時會停止，不能自動略過並宣稱相容。原來源與現場服務不變，輸出仍不可啟用。

真正 Git 重播在官方固定基準上產生的完整 tree 為 `0fc45b1ede19ecc00eada0223ac088c656738e08`，與 10/24 實測候選完全相同；重複套用被拒絕。準備入口共 **9 項測試通過**，包含未套補丁的舊路徑、修補來源追溯及衝突時不建置 PM。候選 GitHub workflow 已明確帶入補丁並保存證據，但仍未推送／執行；此工作流程只含準備與管理器 fixture，未宣稱未來官方新版已通過 Agent 契約或真實生命週期測試。

另外重現並修正直接呼叫 `stack-activate.ps1` 可以略過 Node 準備層 PM 阻擋的缺口：候選或目前設定的 Agent 來源含 `pm/lock.json` 時，現在於停止服務、操作排程、切換設定前拒絕。真實 PowerShell 啟用入口的隔離 fixture 測試確認兩種來源都被擋住，設定／排程／控制 Host 呼叫不變，舊非 PM 啟用及失敗回復仍通過。這是補齊拒絕邊界，並非實作 PM 升級／回復。

49 個必要套件項目檢查、workflow YAML 解析、npm dry-run 打包與差異格式檢查通過，補丁有進入套件清單；沒有建立或發布安裝包。原始 red／green 與重播證據見 [10/25 完成紀錄](C:/Users/david.yuan/Documents/Codex/2026-10-06/d/outputs/tray-release-20261025-completion.md)。

```powershell
python -I -B scripts/windows/prepare-hermes-pm-candidate.py `
  --source D:\hermes-agent-release-20261019 `
  --revision d923a5eb487a17c0a68801bba9ef0f56c81040a8 `
  --out D:\hermes-pm-candidate-new-run
```

bootstrap 需 Python 3.11 以上及 Git；實際 runtime 由固定來源的官方 PM 鎖檔決定。手動 workflow 從官方 repository 取得指定提交後呼叫同一入口，只上傳 JSON／log 證據；每週上游發現維持只查詢，不自動執行來源程式或提升版本。

## 觀察器與原七次缺口

原 10/15–16 觀察已結案，15 分鐘 heartbeat 維持 `PAUSED`。七次缺口無法補寫；本次沒有重開、延長或合併舊輪。

另做兩次各 60 秒的唯讀效能分解，皆 12 筆、最大間隔 5.016 秒，Host／Tray／Supervisor 的 PID 加開始時間相同。另存 `work/watchdog_sample_v2.py` 候選，重用經身分驗證的 Process 物件，減少 Windows 父程序查詢。

| 指標 | 原觀察器 | v2 短測 |
|---|---:|---:|
| 全系統 parent-map 查詢次數 | 192 | 110 |
| 採樣工作中位數 | 0.6175 秒 | 0.399 秒 |
| 採樣工作最大值 | 0.875 秒 | 0.485 秒 |
| Host 單核心 CPU 估計 | 27.02% | 30.35% |

兩次背景工作量不同，不能據此保證效能提升比例；Host CPU 成本仍待定位。v2 另通過 cache 重用、開始時間不符拒絕、自然退出程序移除測試；子程序數只涵蓋當筆已取樣者，新發現者可能下一筆才計入。Supervisor 每圈後睡眠 15 秒，不能套用統一 10 秒門檻判失聯；原先該自我檢查假設已更正。這些短測沒有重現或解釋歷史七次缺口，也不能排除慢速洩漏。

## 正式版尚缺的門檻

- [x] GPT 客製差異收斂、真正來源選擇及隔離 MCP 讀取驗證。
- [ ] 將官方 PM 安裝／啟動／回復契約完整接入 Tray，驗證 Agent gateway 生命週期。
- [ ] Python 依賴鎖定及整組相容性證明。
- [ ] 在可拋棄 Windows VM／使用者執行乾淨安裝、完整啟停、登入／重開、升級及回復；不在 TYO 現有使用者上繞過 VM 測試保護。
- [ ] ChatGPT 網頁接線、授權更新、長串流、取消和斷線恢復；完整 Codex 桌面退出再開。
- [ ] 候選先通過上述檢查後，再建立獨立固定 24 小時觀察及資源判讀。
- [ ] 將通過的同一產物與證據發布，再讓「建議更新」指向 stable；上游發現 workflow 必須先進入遠端預設分支才能排程執行。

資料回復仍不是斷電下多檔案原子交易；外部未知寫入者及回復中磁碟故障仍是風險，原備份必須保留。沒有做正式資料還原、服務切換、遠端 CI、新 24 小時觀察或正式發布。

10/20 唯讀查核：TYO 已啟用 hypervisor，但目前 PATH 未找到 WindowsSandbox／vmrun／VBoxManage，亦未找到 Hyper-V PowerShell 模組，當時可用實體 RAM 約 1.83 GiB。這只能說尚未找到可直接使用的測試 runner，不能斷言機器無法執行 VM；沒有啟用 Windows 功能、建立 VM 或更改權限。證據：`outputs/tray-release-20261020-vm-availability.json`。

10/21 經使用者明確授權，已安裝官方 VirtualBox 7.2.22（官方 SHA-256 與 Oracle 簽章核對通過，MSI 退出 0），僅安裝主程式／核心驅動，沒有橋接、host-only 或 USB 支援驅動。已在 `D:\tyo-windows11-validation-20261021` 建立獨立 Windows 11 VM：4 GiB RAM、2 vCPU、80 GiB 動態硬碟、UEFI／TPM 2.0／Secure Boot、NAT，未開共用資料夾或剪貼簿。VirtualBox 主程式位於 C 槽，所有 VM 資料及 Windows 映像位於 D 槽。

已下載 Microsoft 官方繁體中文 Windows 11 Enterprise 90 天評估 ISO（10.0.26300.9457，8,473,837,568 bytes），本機 SHA-256 `a35bddc76e064355d3a6ace8e32d35d6dae2bebd8538ae3ccc42f76d01dc4be1`，內含 setup.exe 的 Microsoft 簽章有效；未取得另一份 Microsoft 公布的整個 ISO 雜湊，不把局部簽章驗證稱為整個 ISO 的簽章驗證。自動安裝媒體已產生，保留 Windows 硬體需求檢查，測試密碼與答案檔只存於限制目前使用者／SYSTEM 的 private 目錄。

使用者決定先完成準備、待其釋出記憶體才啟動。**VM 保持關機，Windows 尚未安裝，真實 VM 升級／回復／登入／重開驗證仍未完成。** 啟動入口先要求 6 GiB 可用主機 RAM（4 GiB 給 VM、2 GiB 餘裕），再核對 VM 身分與 ISO；不自行關閉現有應用或重新開機。準備紀錄與最新記憶體缺額分別在同目錄 `preparation.json`、`last-memory-check.json`；入口與使用說明在 `README.md`。初次媒體查核因 VBoxManage 欄位名稱假設錯誤而中止，已按實際輸出修正並通過，保留初次及最後 log。

10/21 續查另修正乾淨 VM 安裝測試的資料保留問題：原本遇到既有 `WorkRoot` 會直接遞迴刪除，現在拒絕任何已存在的檔案或資料夾；清理前也檢查資料夾路徑及 reparse point。新增 guard 測試以 AST 只載入資料夾建立函式，三個案例確認新建含括號路徑、既有資料夾及檔案保留；沒有在 TYO 繞過 VM 保護或執行安裝測試。此回歸已接入 Windows 測試入口，48 項套件檔案檢查與 diff 格式檢查通過。證據：`outputs/tray-release-20261021-fresh-vm-guard.log`。當時 gateway 真實探針及 VM 安裝均未啟動；10/24 已另完成上述 gateway 隔離測試，VM 安裝仍未執行。
