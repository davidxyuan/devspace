# Windows Watchdog Setup

DevSpace includes Windows scripts that can deploy a hidden Scheduled Task
watchdog. The watchdog checks every minute that:

- `devspace serve` is listening on the configured local port
- the configured ngrok tunnel points at that local port
- duplicate or unhealthy DevSpace processes are cleaned up

For a personal machine where you can grant administrator rights, run from an
elevated PowerShell, or let the installer request elevation:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -AllowedRoots "D:\projects" `
  -PublicBaseUrl "https://your-stable-domain.ngrok-free.dev" `
  -InstallTools
```

For a locked-down company machine where you do not have administrator rights,
use standard-user mode. This mode does not request elevation and registers a
limited scheduled task for the current Windows user:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -UserMode `
  -AllowedRoots "$env:USERPROFILE\projects" `
  -PublicBaseUrl "https://your-stable-domain.ngrok-free.dev"
```

`-InstallTools` uses `winget` to install missing prerequisites:

- Git for Windows
- Node.js LTS and npm
- ngrok

The installer builds this checkout by default. In administrator mode it registers
`DevSpaceNgrokWatchdogPoller` with `RunLevel: Highest`; in standard-user mode it
registers `DevSpaceNgrokWatchdogUserPoller` with `RunLevel: Limited`. It deploys:

```text
%USERPROFILE%\.devspace\devspace-watchdog.ps1
%USERPROFILE%\.devspace\run-devspace-watchdog-hidden.vbs
%USERPROFILE%\.devspace\devspace-watchdog.config.json
```

The task action runs through `wscript.exe`, so the per-minute monitor runs in
the background without a visible PowerShell window.

If you use a non-ngrok tunnel, pass `-SkipNgrok` and manage the tunnel
separately. A stable public base URL is still required for ChatGPT or another
remote MCP client to reconnect after restarts.

Standard-user mode can only manage processes and folders the current Windows
user can access. It is intended for corporate machines where administrator rights
are unavailable. Install Git, Node.js, npm, and ngrok through approved company
channels first, then run the installer with `-UserMode`.
