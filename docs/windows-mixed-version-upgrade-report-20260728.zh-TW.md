# Windows 混合版本升級設計報告（2026-07-28）

## 問題紀錄

TYO 電腦出現以下已安裝狀態：

- DevSpace：1.0.4，已在 `codex/windows-fixed-port-conflicts` / `ca7c10a`
- Hermes-GPT：0.2.0，仍在舊版 `master`

原本的 `upgrade-existing-tested-stack.ps1` 只接受兩種狀態：

1. DevSpace 與 Hermes-GPT 都低於目標版本：整套升級。
2. DevSpace 與 Hermes-GPT 都等於目標版本：只套用能力設定。

因此只要其中一個元件先升級、另一個仍為舊版，就會被判定為 mixed state 並拒絕執行。這使正常的部分成功、人工修復或分階段部署無法由 installer 接手。

## 建議設計

Installer 應把 DevSpace 與 Hermes-GPT 視為兩個可獨立升級、但在完成後需共同驗證的元件，而不是只判斷整套版本組合。

每個元件各自判定：

- `Keep`：版本與受測 commit 均符合。
- `Upgrade`：版本低於目標版本。
- `Refuse`：版本高於目標、版本相同但 commit 不符合，或 repo 無法辨識。

整體執行計畫由兩個元件狀態組合而成：

- `Upgrade`：兩者都需要升級。
- `UpgradeDevSpace`：只升級 DevSpace。
- `UpgradeHermes`：只升級 Hermes-GPT。
- `CapabilitiesOnly`：兩者均已到目標版本，只更新能力設定。

## 必要安全規則

1. 升級前先建立一致性備份：`.devspace`、資料庫、排程 XML、需要升級的 repo、Hermes 本機資料。
2. 只停止 installer 管理的 PID；固定服務 Port 被其他程式占用時必須拒絕，不可自動換 Port或終止未知程序。
3. Git remote 不應假設一定叫 `origin`；應依 URL 找出符合的 remote 名稱。
4. 現有 Hermes 舊版可能尚未安裝 Python distribution metadata，版本應優先從 `pyproject.toml` 讀取。
5. 只對需要升級的元件執行 fetch、checkout、套件安裝與 build。
6. 能力設定應獨立於版本升級；升級完成後可一次套用完整 capability profile。
7. 完成後必須驗證 DevSpace、Hermes-GPT、MCP Router、本機與公開 MCP route，以及 OAuth owner token 未被改寫。
8. 任何步驟失敗時保留 rollback manifest，並重新啟動原排程；不可在未驗證狀態下宣告成功。

## 本次修正

本機修正版新增 `UpgradeDevSpace` 與 `UpgradeHermes` 狀態，並調整 remote 偵測、Hermes 版本讀取、按元件備份與按元件升級流程。

本次 TYO 升級應判定為：

`UpgradeHermes`

也就是保留目前 DevSpace 1.0.4，只將 Hermes-GPT 升級至 0.5.0，接著套用完整能力設定並執行全鏈路驗證。
