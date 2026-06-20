# Windows Watchdog Setup

DevSpace includes Windows scripts that can deploy a hidden Scheduled Task
watchdog. The watchdog checks every minute that:

- `devspace serve` is listening on the configured local port
- the configured ngrok tunnel points at that local port
- duplicate or unhealthy DevSpace processes are cleaned up

Run from an elevated PowerShell, or let the installer request elevation:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\windows\install-devspace-watchdog.ps1 `
  -AllowedRoots "D:\projects" `
  -PublicBaseUrl "https://your-stable-domain.ngrok-free.dev" `
  -InstallTools
```

`-InstallTools` uses `winget` to install missing prerequisites:

- Git for Windows
- Node.js LTS and npm
- ngrok

The installer builds this checkout by default and registers
`DevSpaceNgrokWatchdogPoller` with `RunLevel: Highest`. It deploys:

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
