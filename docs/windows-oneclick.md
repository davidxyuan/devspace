# Windows installation and updates

Extract the one-click ZIP and double-click **Install-DevSpace.cmd**. Keep the
setup window open until completion. The launcher locates compatible Node.js
(`>=22.19 <27`); if missing, it uses Windows App Installer (`winget`) to install
Node.js LTS. If winget is unavailable, the error identifies the prerequisite to
install before retrying. Internet access is needed for missing dependencies.

The package copies its verified payload into a directory under
`%LOCALAPPDATA%\DevSpaceStack\packages`. You can remove the extracted ZIP folder
after successful installation. This does not copy another computer's credentials.

## Existing and new computers

Stack Setup detects configuration and executable paths in `%USERPROFILE%\.devspace`.
An existing installation keeps its working directories, ports, routes, capability
settings, owner credentials, ngrok endpoint and account configuration. Blank token
fields keep existing credentials. Unchecked existing components remain installed
and enabled; use the operational Dashboard to change their service state.

A new computer needs an ngrok authtoken, public domain and approved workspace
folders. No ngrok or ChatGPT account password is requested. Cloud Endpoint users
must already have the matching internal endpoint and forwarding policy configured.
The installer does not create Cloud Endpoint resources or change accounts for you.

**Install missing / apply settings** prepares dependencies, saves recovery data,
verifies ownership of old Watchdog tasks and processes, installs the current Tray,
and checks local readiness. Unknown or invalid configuration is reported without
overwriting it. Windows permissions can require an administrator to retire an old
system-owned task; an ownership or permission failure is reported before replacement.

The Tray menu and the Dashboard stay separate from installation workers. Jobs and
their logs persist under `.devspace\stack-management`, so restarting the monitoring
Host does not erase an installation's status. Only one operation can change an
installation at a time. A disconnected page is not treated as successful completion.

## Components and updates

Both dashboards show Node/npm, Git, Python, official DevSpace, the DevSpace Fork,
Hermes GPT, Hermes Agent, Router, ngrok, legacy Watchdog and the current Tray.
Installed state, current version, source and permitted actions appear separately.
Use **Check latest** to refresh remote versions. Cached results remain visible
offline; unavailable or stale data does not authorize an update.

Official DevSpace and the Fork share an npm package name but are different
sources. Updating one does not silently replace the other. Updates use a pinned
candidate in a separate managed directory, validate it, then switch the configured
runtime with a recovery backup. Dirty working directories, unknown sources,
diverged history and mismatched tracked branches disable the update action.
Commit or otherwise resolve that source outside this installer before checking again.

Hermes Agent release tags and product version numbers can differ. Its managed
executable path is retained in Watchdog configuration and used by the managed
Hermes service; unrelated terminal shortcuts are not rewritten. Existing custom
Agent forks or channels without a verified upgrade path remain untouched.

The historical tested-pair manifest is separate from remotely available versions
and the current one-click package fingerprint. A latest version is not represented
as having passed this project's full stack tests merely because it was published.

## Recovery and development

Configuration and migration backups remain under `.devspace\configuration-backups`.
Failures report whether rollback completed or requires inspection; preserve those
backups until the restored installation has been checked. Do not delete operation
records or recovery files to force a second installer over an unresolved failure.

From the source checkout, `npm run stack:setup` opens Setup and
`npm run stack:package` creates a timestamped ZIP under `releases/`. The package
contains current built `dist` files and Windows scripts, a dependency lock file,
file hashes and honest workspace/dirty provenance. It does not publish a release.
Run `npm test`, `npm run typecheck`, and `npm run test:windows-watchdog` before
packaging a changed source tree. Fresh-machine behavior has isolated Windows
process/filesystem coverage; a separate clean-PC deployment remains a distinct check.
