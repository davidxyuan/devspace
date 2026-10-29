# Isolated Windows gateway supervisor candidate

This foreground manager is a validation candidate for official Hermes Agent's
`gateway run --external-supervisor` contract. It is not installed into Tray,
Task Scheduler or the live user profile. Existing gateway activation protections
remain in place. It requires a completed `prepare-hermes-pm-candidate.py` receipt
and that preparation's Python interpreter; dependency locks and tracked source
are checked before launch.

Use a **new** profile directory. `init` refuses every existing directory, including
empty ones. Configure only that new profile's gateway adapters and credentials.
The manager clears inherited credentials and fixes its home paths to this profile.
It disables cross-profile multiplexing and lazy dependency installation.

```powershell
$python = 'D:\hermes-pm-candidate\runtime\Scripts\python.exe'
$manager = '.\scripts\windows\hermes-gateway-supervisor.py'
& $python -I -B $manager init --prepared D:\hermes-pm-candidate --home D:\hermes-gateway-new-test
# Configure the new profile, then run in a foreground terminal:
& $python -I -B $manager run --home D:\hermes-gateway-new-test
# From another terminal, request a graceful stop:
& $python -I -B $manager stop --home D:\hermes-gateway-new-test
& $python -I -B $manager status --home D:\hermes-gateway-new-test
```

The profile contains `.devspace-gateway.json` and `supervised-gateway.log`.
`status` prints the last persisted record; it is not a live health assertion.
`stop` queues a request for the same supervisor PID and creation time. Completion
requires observing `stopped`, the manager's exit and the gateway's exit.

- One OS-held lock permits one manager per profile. A pre-existing gateway or
  incomplete previous manager run blocks a launch without changing its record.
- Exit 0 stops. Exit 78 stops with a configuration failure. Exit 75 hands off to
  a replacement. Other nonzero exits retry, with at most four starts in 15 minutes;
  the budget persists across manager invocations.
- Stop requests use the official PID-and-start-time-bound planned-stop marker.
  The manager never force-kills. A stop exceeding 180 seconds is preserved for
  inspection instead of spawning a replacement.
- Launch uses the official `runtime_command` so the gateway's strict identity
  check recognizes its command line. After launcher exit, `waiting_descendants`
  waits for already observed PID/start identities to exit naturally within the
  existing stop budget (180 seconds, or the remainder of an ongoing stop).
  No replacement starts while those descendants remain alive.
- A gateway outside the observed child tree, ambiguous ownership or surviving
  observed descendants causes `attention_required`. That state blocks another
  run. The last record includes surviving PID and creation-time identities.
- Descendant tracking is polling-based. It cannot prove the absence of a process
  that launches and reparents between observations. A manager crash is therefore
  not automatically recovered or adopted; production supervision still needs
  the VM lifecycle and ownership validation.

The Windows test script uses harmless real child processes plus a simulated
gateway identity/stop interface. It covers exit semantics, retry limits, locks,
stop races, surviving descendants and preservation of uncertain ownership.
These are not real gateway crash recovery, task/login/reboot, upgrade/rollback,
ChatGPT connection or 24-hour stability evidence.

On 2026-10-24, the manager suite passed 17 tests. A separate real Windows
loopback-only probe passed initial startup, an owned child self-exit with code 37,
automatic recovery, official `pause-for-update` acknowledgement and replacement,
and the official graceful-stop marker. Each ready state checked HTTP plus live
control-pipe PID/start/home/source identity. Independent post-run inspection found
all 47 observed process identities gone and port 5320 no longer listening.

This real probe used local Hermes commit
`7bfe8dcfb5ca0ecebbe61ac0f13ae03fd52f119f`, based on official v0.22.2
`d923a5eb487a17c0a68801bba9ef0f56c81040a8`. It is a patched candidate, not the
unmodified official release: the original Windows pipe dispatcher blocked the
gateway event loop while `pause-for-update` waited for that same loop. Dispatching
the handler off-loop fixes the deadlock without extending the client's two-second
timeout. Targeted canonical tests passed 5 tests, with 19 POSIX tests skipped;
all 12 `scripts/check` checks passed. The new prepared runtime retained the same
115 package versions and dependency inputs as the original prepared runtime.

Evidence is under
`C:\Users\david.yuan\Documents\Codex\2026-10-06\d\outputs`:
`hermes-gateway-supervisor-20261024-r6-real.json`, `-r6-cleanup.json`, and
`hermes-gateway-supervisor-20261024-completion.md`. Earlier failures remain saved.
Update handoff does not prove changing versions or rollback; VM, login/reboot,
production adoption, model/chat requests and long-run stability remain unverified.

```powershell
& $python -I -B scripts/windows/hermes-gateway-supervisor.test.py -v
```

The candidate preparation workflow runs this suite using the frozen prepared
runtime. The candidate workflow is published. [Run 40716862013](https://github.com/davidxyuan/devspace/actions/runs/40716862013)
passed on 2026-10-28: preparation, 17 supervisor tests, real gateway crash recovery,
official update handoff, and graceful stop with all 49 observed process identities
exited. This does not validate version switching, interactive login/reboot, or production deployment.

## Carrying the Windows fix across upstream updates

`scripts/windows/patches/hermes-windows-control-pipe.patch` contains the tested
control-pipe change and its two regression tests. The candidate workflow passes
it explicitly to `prepare-hermes-pm-candidate.py --patch`. Preparation applies it
only inside the new source snapshot, before PM builds dependencies. The input
checkout stays untouched. A conflict or an already applied patch stops the build;
review the upstream change and patch instead of skipping it automatically.

The receipt records `upstreamRevision`, the patched local `revision`, and
`patchSha256`; `candidate.patch` preserves the exact bytes used. The patched commit
is local provenance, not an official release commit. It is not promised to have
the same commit ID on repeated builds. Preparation still sets
`activationEligible=false`, and the current activation entry point also rejects
PM-owned candidate or configured current Agent roots before stopping services.

On 2026-10-25, real Git replay onto the pinned official base produced exactly the
same complete source tree as the 10/24 tested candidate; reapplying was rejected.
Nine preparation tests passed, including patch provenance and conflict rejection.
This is patch replay and fixture evidence, not a second frozen PM build or a
gateway/upgrade/rollback run. The workflow verifies preparation and manager
fixtures; a future upstream candidate still needs its Agent control-pipe tests
and real lifecycle validation before release.
