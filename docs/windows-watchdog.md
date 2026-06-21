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

The task action runs through `wscript.exe`, so the per-minute monitor runs in
the background without a visible PowerShell window.

If you use a non-ngrok tunnel, pass `-SkipNgrok` and manage the tunnel
separately. A stable public base URL is still required for ChatGPT or another
remote MCP client to reconnect after restarts.

Standard-user mode can only manage processes and folders the current Windows
user can access. It is intended for corporate machines where administrator rights
are unavailable. Install Git, Node.js, npm, and ngrok through approved company
channels first, then run the installer with `-UserMode`.
