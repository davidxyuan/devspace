# Windows Watchdog Setup

DevSpace includes Windows scripts that can deploy a hidden Scheduled Task
watchdog. The watchdog checks every minute that:

- `devspace serve` is listening on the configured local port
- optional `hermes-gpt` is listening on the configured local port
- optional MCP router is listening when DevSpace and Hermes share one public URL
- the configured ngrok tunnel points at that local port
- duplicate or unhealthy DevSpace processes are cleaned up

For a personal machine where you can grant administrator rights, this installs
both DevSpace and Hermes GPT behind one ngrok URL:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -Components DevSpace,Hermes `
  -AllowedRoots "D:\projects" `
  -PublicBaseUrl "https://your-stable-domain.ngrok-free.dev" `
  -InstallTools
```

Add `-FullAccess` only when you want this MCP stack to expose the whole
machine: DevSpace allows every visible filesystem drive root, and Hermes GPT
enables write, patch, terminal, session search, and memory write tools.

The resulting ChatGPT MCP URLs are:

```text
https://your-stable-domain.ngrok-free.dev/<machine>/devspace_chatgpt/mcp
https://your-stable-domain.ngrok-free.dev/<machine>/hermes_chatgpt/mcp
```

`<machine>` defaults to the Windows hostname, lowercased and URL-safe. Override
it with `-MachineName david` when the hostname is not the name you want to see
inside ChatGPT.

## New computer quick install

If Git is not installed yet, download this repository as a ZIP from GitHub,
extract it, open PowerShell in the extracted folder, and run one of these
commands. `-InstallTools` installs Git, Node.js/npm, Python, and ngrok with
winget when they are missing.

For a direct ngrok Agent Endpoint:

```powershell
$env:NGROK_AUTHTOKEN = "paste-your-ngrok-token-here"

powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -PublicBaseUrl "https://your-agent-endpoint.ngrok-free.dev" `
  -NgrokEndpointMode AgentEndpoint `
  -MachineName "$env:COMPUTERNAME" `
  -McpNameSuffix "$env:COMPUTERNAME" `
  -FullAccess `
  -InstallTools
```

For a shared public ngrok Cloud Endpoint with one internal endpoint per
computer:

```powershell
$env:NGROK_AUTHTOKEN = "paste-your-ngrok-token-here"

powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -PublicBaseUrl "https://your-cloud-endpoint.ngrok-free.dev" `
  -NgrokEndpointMode CloudEndpoint `
  -NgrokAgentBaseUrl "https://${env:COMPUTERNAME}-devspace.internal" `
  -MachineName "$env:COMPUTERNAME" `
  -McpNameSuffix "$env:COMPUTERNAME" `
  -FullAccess `
  -InstallTools
```

Remove `-FullAccess` and pass `-AllowedRoots "D:\projects;C:\Users\you\code"`
when you want a narrow filesystem allowlist. Omit `-UserMode` when you want the
installer to request administrator permission and register the watchdog with the
highest run level.

Cloud Endpoint mode also writes a Traffic Policy file and a merge-rule file
under `%USERPROFILE%\.devspace`. Paste the full policy when this is the only
computer on the Cloud Endpoint, or merge the rule into the existing
`on_http_request:` list when several computers share one public URL.

For this TYO machine, the shortest Agent Endpoint install is:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-chatgpt-tyo-agent.ps1
```

It installs the public URLs:

```text
https://shush-underuse-obnoxious.ngrok-free.dev/tyo/devspace_chatgpt/mcp
https://shush-underuse-obnoxious.ngrok-free.dev/tyo/hermes_chatgpt/mcp
```

Name the ChatGPT connectors `devspace_chatgpt_tyo` and
`hermes_chatgpt_tyo`.

The TYO Agent helper also keeps `/c02250073/...` as a route alias for existing
connector entries that were created before the machine was renamed to `tyo`.
For a different legacy hostname, pass:

```powershell
-RouteAliasMachineNames "old-machine-slug"
```

## ngrok endpoint modes

The installer supports two ngrok modes. `AgentEndpoint` is the default and is
the simpler mode to test first after corporate TLS/proxy restrictions are
removed.

### Mode 1: direct public Agent Endpoint

Use this when the public URL is created directly by the ngrok agent.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -AllowedRoots "$env:USERPROFILE\projects" `
  -PublicBaseUrl "https://your-agent-endpoint.ngrok-free.dev" `
  -NgrokEndpointMode AgentEndpoint
```

The watchdog starts ngrok like this:

```text
ngrok http http://127.0.0.1:8765 --url https://your-agent-endpoint.ngrok-free.dev --log stdout
```

The public MCP URLs are:

```text
https://your-agent-endpoint.ngrok-free.dev/<machine>/devspace_chatgpt/mcp
https://your-agent-endpoint.ngrok-free.dev/<machine>/hermes_chatgpt/mcp
```

For routed installs, the installer stores DevSpace's `publicBaseUrl` as the
DevSpace route base:

```text
https://your-agent-endpoint.ngrok-free.dev/<machine>/devspace_chatgpt
```

The ngrok agent still uses only the public origin as its `--url`:

```text
https://your-agent-endpoint.ngrok-free.dev
```

This split is required so DevSpace OAuth metadata points at the routed MCP URL
while ngrok registers a valid agent endpoint URL.

### Mode 2: public Cloud Endpoint forwarded to internal Agent Endpoints

Use this when the public URL is a Cloud Endpoint managed in the ngrok dashboard.
Each local ngrok agent exposes only an internal endpoint, and the Cloud Endpoint
Traffic Policy forwards each machine path to the matching internal endpoint.
This is the mode to use when several computers must share one public Cloud
Endpoint at the same time.

For TYO, run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-chatgpt-tyo-cloud.ps1 `
  -PublicBaseUrl "https://your-cloud-endpoint.ngrok-free.dev"
```

The installer writes two Cloud Endpoint policy files:

```text
%USERPROFILE%\.devspace\ngrok-cloud-endpoint-tyo.policy.yml
%USERPROFILE%\.devspace\ngrok-cloud-endpoint-tyo.rule.yml
```

Use the `.policy.yml` file as the full Traffic Policy when this is the only
machine on the Cloud Endpoint. It looks like:

```yaml
on_http_request:
  - name: DevSpace tyo router
    expressions:
      - req.url.path.startsWith("/tyo/") || req.url.path.startsWith("/.well-known/oauth-authorization-server/tyo/") || req.url.path.startsWith("/.well-known/oauth-protected-resource/tyo/")
    actions:
      - type: forward-internal
        config:
          url: https://tyo-devspace.internal
          binding: internal
```

For another machine, run the same installer with a different `-MachineName`, then
copy that machine's `.rule.yml` content under the same `on_http_request:` list
in the Cloud Endpoint Traffic Policy. Do not paste a second `on_http_request:`
top-level key. Each machine keeps its own internal endpoint, so they can coexist.

To install or switch manually to Cloud Endpoint mode:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -AllowedRoots "$env:USERPROFILE\projects" `
  -PublicBaseUrl "https://your-cloud-endpoint.ngrok-free.dev" `
  -NgrokEndpointMode CloudEndpoint `
  -NgrokAgentBaseUrl "https://<machine>-devspace.internal" `
  -MachineName "<machine>" `
  -McpNameSuffix "<machine>"
```

The watchdog starts ngrok like this:

```text
ngrok http http://127.0.0.1:8765 --url https://<machine>-devspace.internal --binding internal --log stdout
```

The public MCP URLs still use the Cloud Endpoint:

```text
https://your-cloud-endpoint.ngrok-free.dev/<machine>/devspace_chatgpt/mcp
https://your-cloud-endpoint.ngrok-free.dev/<machine>/hermes_chatgpt/mcp
```

### Switching modes after install

To switch back to a direct public Agent Endpoint:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -PublicBaseUrl "https://your-agent-endpoint.ngrok-free.dev" `
  -NgrokEndpointMode AgentEndpoint `
  -MachineName "tyo" `
  -McpNameSuffix "tyo" `
  -SkipNpmInstall `
  -SkipHermesInstall `
  -SkipHermesAgentInstall
```

It is also safe to rerun this command after `config.json` already contains a
routed DevSpace URL such as
`https://host/<machine>/devspace_chatgpt`; the installer derives the ngrok
Agent Endpoint URL from the origin and will not pass the path to `ngrok --url`.

To switch to a Cloud Endpoint plus internal endpoint:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -PublicBaseUrl "https://your-cloud-endpoint.ngrok-free.dev" `
  -NgrokEndpointMode CloudEndpoint `
  -NgrokAgentBaseUrl "https://<machine>-devspace.internal" `
  -MachineName "<machine>" `
  -McpNameSuffix "<machine>" `
  -SkipNpmInstall `
  -SkipHermesInstall `
  -SkipHermesAgentInstall
```

After switching, force one watchdog run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\.devspace\devspace-watchdog.ps1" `
  -Once `
  -ConfigPath "$env:USERPROFILE\.devspace\devspace-watchdog.config.json"
```

### Manual verification

Check the local router:

```powershell
Invoke-RestMethod http://127.0.0.1:8765/__router/status
```

Check the local ngrok agent API:

```powershell
Invoke-RestMethod http://127.0.0.1:4040/api/tunnels
```

Check public routing after ngrok connects:

```powershell
Invoke-WebRequest `
  -Method Post `
  -ContentType "application/json" `
  -Body "{}" `
  "https://<public-base-url>/<machine>/devspace_chatgpt/mcp"
```

A `401` response from `devspace_chatgpt` means the request reached DevSpace but
did not include the owner token. A `406` response from `hermes_chatgpt` usually
means the request reached Hermes without the MCP headers it expects.

For a real MCP initialize check against Hermes, include MCP-compatible headers:

```powershell
$body = @{
  jsonrpc = "2.0"
  id = 1
  method = "initialize"
  params = @{
    protocolVersion = "2025-06-18"
    capabilities = @{}
    clientInfo = @{ name = "manual-check"; version = "1.0" }
  }
} | ConvertTo-Json -Depth 8

Invoke-WebRequest `
  -Method Post `
  -Headers @{ Accept = "application/json, text/event-stream"; "Content-Type" = "application/json" } `
  -Body $body `
  "https://<public-base-url>/<machine>/hermes_chatgpt/mcp"
```

### Corporate security allowlist notes

Both ngrok modes require `ngrok.exe` to establish a TLS control connection to
ngrok. By default, the agent connects to `connect.ngrok-agent.com:443`. If a
corporate TLS inspection product such as Kaspersky Endpoint Security replaces
that certificate and the agent cannot validate it, both modes will fail before
any DevSpace or Hermes traffic can reach this machine.

Ask IT to allow one of these, in order of preference:

- mark `ngrok.exe` as a trusted application whose encrypted traffic is not
  scanned
- exclude `connect.ngrok-agent.com` from encrypted connection scanning
- allow the chosen public endpoint hostname, the `.internal` endpoint hostname
  for Cloud Endpoint mode, and `dashboard.ngrok.com` for manual dashboard setup

Runtime does not require Bash. The scheduled task uses `wscript.exe` with
`run-devspace-watchdog-hidden.vbs` as a hidden launcher so the per-minute
watchdog does not flash a console window. The watchdog then launches PowerShell,
Node.js, Python, and ngrok in hidden/background mode. `run-hermes-gpt.cmd`
remains for legacy fallback; current installs start Hermes GPT directly through
Python when the virtual environment is present.

For a locked-down company machine where you do not have administrator rights,
use standard-user mode. This mode does not request elevation and registers a
limited scheduled task for the current Windows user:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -Components DevSpace,Hermes `
  -AllowedRoots "$env:USERPROFILE\projects" `
  -PublicBaseUrl "https://your-stable-domain.ngrok-free.dev"
```

Install only one MCP by changing `-Components`:

```powershell
-Components DevSpace
-Components Hermes
```

`-InstallTools` uses `winget` to install missing prerequisites:

- Git for Windows
- Node.js LTS and npm
- Python 3, when `Hermes` is selected
- ngrok

The installer builds this checkout by default. In administrator mode it registers
`DevSpaceNgrokWatchdogPoller` with `RunLevel: Highest`; in standard-user mode it
registers `DevSpaceNgrokWatchdogUserPoller` with `RunLevel: Limited`. It deploys:

```text
%USERPROFILE%\.devspace\devspace-watchdog.ps1
%USERPROFILE%\.devspace\run-devspace-watchdog-hidden.vbs
%USERPROFILE%\.devspace\devspace-watchdog.config.json
%USERPROFILE%\.devspace\mcp-router.cjs
%USERPROFILE%\.devspace\run-hermes-gpt.cmd
```

When `Hermes` is selected, the installer also checks for Hermes Agent. If it is
missing, it runs the official Windows installer and skips the interactive setup
wizard; configure Hermes credentials separately after install.

In standard-user mode, the task is registered through `schtasks.exe` and runs
`wscript.exe "%USERPROFILE%\.devspace\run-devspace-watchdog-hidden.vbs" -Once`
every minute. This avoids visible PowerShell or cmd windows while keeping the
task usable without administrator rights. When ngrok cannot connect, the
watchdog leaves the existing ngrok process running so the agent can reconnect
instead of killing and restarting it every minute.

If you use a non-ngrok tunnel, pass `-SkipNgrok` and manage the tunnel
separately. A stable public base URL is still required for ChatGPT or another
remote MCP client to reconnect after restarts.

Standard-user mode can only manage processes and folders the current Windows
user can access. It is intended for corporate machines where administrator rights
are unavailable. Install Git, Node.js, npm, and ngrok through approved company
channels first, then run the installer with `-UserMode`.

## Troubleshooting

The installer prints `DevSpace watchdog install failed.` followed by a `Fix:`
line for common setup problems. The most common cases are:

| Error text | What to do |
| --- | --- |
| `Node.js LTS is missing`, `npm is missing`, `Git is missing`, `Python is missing`, or `ngrok.exe is missing` | Rerun the same command with `-InstallTools`, or install the missing tool manually and open a new PowerShell window. |
| `winget.exe is not available` | Install App Installer/winget first, or install the missing tools manually. |
| `Missing -PublicBaseUrl` | Pass the stable public origin, for example `-PublicBaseUrl "https://example.ngrok-free.dev"`. Do not include `/mcp`. |
| `ngrok authtoken setup failed` | Check the token at `https://dashboard.ngrok.com/get-started/your-authtoken`, set `$env:NGROK_AUTHTOKEN`, and rerun. |
| `schtasks.exe failed to register DevSpaceNgrokWatchdogUserPoller` | Open PowerShell as Administrator, delete the stale task with `schtasks.exe /Delete /TN DevSpaceNgrokWatchdogUserPoller /F`, then rerun. |
| A cmd or PowerShell window flashes every minute | Update to this branch and rerun the installer. The task action should be `wscript.exe "%USERPROFILE%\.devspace\run-devspace-watchdog-hidden.vbs" -Once`. |
| Public URL returns `502` | Check `http://127.0.0.1:8765/__router/status`, then check `%USERPROFILE%\.devspace\devspace-watchdog.log` and `ngrok-watchdog.err.log`. |
| ngrok reports `ERR_NGROK_18021` | The ngrok account has too many concurrent endpoints. Stop another endpoint in the ngrok dashboard or use a plan with more endpoint capacity. |
| Cloud Endpoint URL does not reach this computer | Merge the generated `.rule.yml` into the Cloud Endpoint Traffic Policy, then wait one minute or run `%USERPROFILE%\.devspace\devspace-watchdog.ps1 -Once`. |
