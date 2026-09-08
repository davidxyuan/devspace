# Windows management contract

The Setup Node process owns asynchronous operations independently of the Watchdog Host. Both web pages use these endpoints; the Host forwards component requests asynchronously and serves cached inventory. Long work must not run on the Host request loop or WinForms thread.

- `GET /api/components`: `{schemaVersion:1,revision,checkedAt,remoteCheckedAt,refreshing,components:[],blockers:[]}`.
- `POST /api/components/refresh`: `{}` returns `202 {ok:true,jobId}`.
- `POST /api/components/action`: `{componentId,action,expectedRevision,requestId}` returns `202 {ok:true,jobId}`. Only backend registered sources and actions are accepted.
- `GET /api/job?id=...`: `{id,type,componentId,action,phase,step,startedAt,updatedAt,finishedAt,exitCode,result,error,lines:[{timestamp,source,text}]}`. Phases: queued, running, completed, failed, rollback_failed.
- `/api/status` adds `inventory`, `activeJob`, `activeJobId`, `configurationFingerprint` to its existing shape. Configuration apply sends the fingerprint; existing unselected components stay enabled. An omitted or unchanged field preserves existing settings.

Component IDs: `node`, `npm`, `git`, `python`, `devspace-official`, `devspace-tray-fork`, `hermes-gpt`, `hermes-agent`, `router`, `ngrok`, `legacy-watchdog`, `tray`.

Each component contains `id,label,installState` (installed/missing/partial/unknown), `runtimeState` (running/stopped/unknown/n/a), `installedVersion`, `path`, `source:{kind,repository,branch,head,trackingRef,dirty}`, `latest:{state,version,tag,commit,url,checkedAt,reason}`, `tested` (historical manifest entry or null), `actions:[{id,label,enabled,reason}]`, `detail`. Version tag and product version are separate. Unknown remote data never means missing installation. A dirty source is never replaced or implicitly switched to another channel.

`stack-management.cjs` exports async `collectInventory({installDir,packageRoot,checkLatest,cache,...testDependencies})`, `planComponentAction(request,inventory)`, async `executeComponentAction(plan,callbacks)`. The planner returns a pinned source/target and execution stages. Executor callbacks are `run(command,args,options)`, `log(text)`, `activate(candidate,plan)`. The root coordinator owns persistence, exclusive operation ownership and transactional activation. The module owns discovery, source validation, staging and candidate validation. No secrets appear in inventory, plans or durable job JSON.

Operations serialize for each canonical InstallDir. A PowerShell worker holds an exclusive management lock while its child Node worker executes. A durable active-job reservation also blocks other mutations if the supervisor or Setup console exits unexpectedly; it never expires by age. Only children carrying the matching job identity and private operation token may participate. Host, bootstrap and installer mutations consult both guards. Persistent Host, Tray and Setup processes discard inherited operation tokens. Staged workers and payloads remain outside any runtime being replaced. Prior running/stopped and task enabled states must survive successful migration and rollback. Offline checks preserve cached evidence and report staleness.
