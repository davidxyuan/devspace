# Windows Tested Stack 安裝與升級指南

適用目標：

- DevSpace `1.0.4` / `ca7c10a39b5c099455db662c3aba9007b5eb34e3`
- Hermes-GPT `0.5.0` / `db5ffa1bd2e4fcfecdebb2bcf479334144e1cbe3`
- Windows 10／11 PowerShell 5.1 以上

> 既有機器升級前，建議使用「以系統管理員身分執行」的 PowerShell。Installer 會先檢查是否有權安全停止受管理程序；權限不足時會在停止任何服務前拒絕。

## 1. 取得固定 installer package

```powershell
Set-Location C:\Temp
git clone --branch codex/windows-mixed-version-upgrade-support `
  https://github.com/davidxyuan/devspace.git devspace-installer
Set-Location C:\Temp\devspace-installer
```

確認 commit 與工作目錄：

```powershell
git log -1 --oneline
git status --short
```

## 2. 驗證 installer package

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\validate-tested-stack-installer-package.ps1

npm ci
npm run test:windows-watchdog
```

Package validator 與 Windows tests 都通過後再進行正式升級。

## 3. 既有機器：先 Dry Run

Installer 會從既有 Watchdog config 自動找到 DevSpace 與 Hermes repo；通常不用手動指定路徑。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\detect-and-apply-tested-stack.ps1 `
  -DryRun
```

可能的結果：

- `CapabilitiesOnly`
- `UpgradeDevSpace`
- `UpgradeHermes`
- `Upgrade`

遇到版本較新、相同版本但 commit 不符、未知 repo、固定 Port 衝突或無法停止 PID 時，installer 會拒絕而不修改系統。

## 4. 既有機器：套用全部能力

以下為高權限設定。只應用在個人或明確授權的機器。

```powershell
$capabilities = @(
  'DevSpaceToolMode=full'
  'DevSpaceWidgets=full'
  'DevSpaceSkills=On'
  'DevSpaceSubagents=On'
  'HermesBridge=On'
  'HermesReadOnlyTools=On'
  'HermesVision=On'
  'HermesWeb=On'
  'HermesDiagnostics=On'
  'HermesRunner=On'
  'HermesRunnerWrite=On'
  'HermesWorkspaceWrite=On'
  'HermesMemoryWrite=On'
  'HermesTerminal=On'
  'HermesOperator=On'
  'HermesOperatorDirect=On'
  'HermesOwnerMode=On'
  'HermesCron=On'
  'HermesCronWrite=On'
  'HermesSkillWrite=On'
  'HermesPrivateNetwork=On'
  'HermesFilesystemScope=full'
) -join ';'

$roots = @('C:\', 'D:\')

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\detect-and-apply-tested-stack.ps1 `
  -CapabilitySelection $capabilities `
  -HermesAllowedRoots $roots `
  -Detached
```

若機器還有 `H:\`、`T:\` 等確實需要操作的磁碟，再加入 `$roots`。不要預設開放不存在或不需要的磁碟。

## 5. 查看 detached 升級狀態

啟動指令會顯示 run directory，例如：

```text
C:\Users\<user>\AppData\Local\DevSpaceUpgradeRuns\20260728-143717
```

查看狀態：

```powershell
Get-Content '<run-directory>\status.json'
Get-Content '<run-directory>\upgrade.out.log' -Tail 100
Get-Content '<run-directory>\upgrade.err.log' -Tail 100
```

成功狀態：

```json
{
  "state": "completed",
  "exitCode": 0
}
```

## 6. 升級後驗證

```powershell
Get-NetTCPConnection -State Listen -LocalPort 4750,7676,8766 |
  Sort-Object LocalPort |
  Format-Table LocalAddress,LocalPort,OwningProcess

Invoke-WebRequest http://127.0.0.1:7676/healthz -UseBasicParsing
Invoke-WebRequest http://127.0.0.1:8766/__router/status -UseBasicParsing

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\detect-and-apply-tested-stack.ps1 `
  -VerifyOnly
```

預期固定 Port：

| Port | 服務 |
|---:|---|
| 4750 | Hermes-GPT |
| 7676 | DevSpace |
| 8766 | MCP Router |

## 7. 備份與回復

預設備份位置：

```text
C:\Users\<user>\DevSpaceUpgradeBackups\<timestamp>-<machine>-<action>
```

其中包含：

- `rollback-manifest.json`
- Watchdog task XML
- 關鍵 `.devspace` 設定
- DevSpace／Hermes Git bundle（依實際升級元件）
- Hermes venv 與 Hermes home（升級 Hermes 時）
- 外部 DevSpace state／OAuth SQLite（若存在）

正式升級失敗時會預設執行自動 rollback。只有在除錯且已準備人工回復時才使用 `-NoAutoRollback`。

## 8. 全新電腦安裝

先準備：

- 公開 MCP Base URL
- ngrok AgentEndpoint 或 CloudEndpoint 設定
- DevSpace allowed roots
- Hermes allowed roots

範例：

```powershell
$capabilities = @(
  'DevSpaceToolMode=full'
  'DevSpaceWidgets=full'
  'DevSpaceSkills=On'
  'DevSpaceSubagents=On'
  'HermesBridge=On'
  'HermesReadOnlyTools=On'
  'HermesDiagnostics=On'
  'HermesTerminal=On'
  'HermesOperator=On'
  'HermesOperatorDirect=On'
  'HermesOwnerMode=On'
  'HermesFilesystemScope=full'
) -join ';'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\windows\detect-and-apply-tested-stack.ps1 `
  -PublicBaseUrl 'https://<your-domain>/<machine>/devspace_chatgpt' `
  -NgrokEndpointMode CloudEndpoint `
  -NgrokAgentBaseUrl 'https://<machine>-devspace.internal' `
  -MachineName '<machine>' `
  -AllowedRoots 'C:\;D:\' `
  -CapabilitySelection $capabilities `
  -HermesAllowedRoots @('C:\','D:\') `
  -UserMode
```

先以 `-DryRun` 檢查參數，再移除 `-DryRun` 正式執行。

## 9. ChatGPT App 重新掃描

DevSpace／Hermes Runtime 新增工具後，ChatGPT 已建立的 App 不一定自動更新 schema。

升級後：

1. 在 ChatGPT Apps 中重新連線並重新掃描工具。
2. 工具清單仍舊時，移除該 App 後以原 MCP URL 重新建立。
3. DevSpace 應看到 full-mode 工具，例如 `grep`、`glob`、`ls`。
4. Hermes 應看到新增工具，例如 Vision、Web、Codex Runner、Cron、Skills、Workspace 與 Operator tools。

## 10. 功能開關不等於 provider 可用

升級完成後還要分別驗證：

- Codex CLI 版本與登入狀態
- OpenCode server 啟動
- Claude／Pi／Cursor／Copilot provider
- Vision model provider 與公司憑證
- Web provider（Firecrawl、Tavily 等）
- Hermes memory backend

Installer 負責版本、設定、安全重啟與回復；外部 provider 的帳號、API key、網路與公司 CA 仍需各機器自行配置。
