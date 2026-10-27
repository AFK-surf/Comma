# Tasks and background execution

## Canonical lifecycle

Tasks use Conversation-owned status. Cards only project it. Participants are Agents.
The owning Router can complete a delivered one-shot or Loop Task with no pending work or decision. This excludes recurring, Triage, and legacy Workflow Tasks.
Messages never reopen Tasks. Escalation means blocked work needs the initiator, not routine approval.
Clients show an `escalated` Task as Needs input. A Worker's question card reaches the Router, which sets the Task `escalated` while the person answers and `active` when work resumes.

A Router prompt notice ends the source reply with each Task's confirmed status and its consequence. If the reply is already sent, follow up promptly.
Report failed writes truthfully, suppress same-status retries, and explain reopening.
Terminal Slack notices keep exact source/target, Session, installation, and IFC checks. They add no internal-write authority and no exactly-once delivery.

## Ordinary Tasks

Each Task has one Worker. Routers delegate commands and own status. Workers publish Messages.
One create-only metadata write commits a new Task and its first command. Earlier failures leave no Task. A same-request retry drops uncommitted Messages.
After a grace period, `SalixIM.TaskWorkerWatch` reminds a silent Worker once, then tells the initiator once in that Task.
If the Router stops after a Worker result on an active Task, the watch tells the Router once per result. This excludes recurring, Workflow, and Triage Tasks, and a Loop Task while its Loop is active.
The watch covers only a Worker whose Salix Session reports activity. A [station Task](#station-tasks) has no such Session.

For a Task with a QQ card, the watch also posts working, blocked and paused notices to that card.

Provider cards and client timeouts cannot complete, cancel, or reopen Tasks. Telegram review cards complete Tasks through owner review only.

## Station Tasks

A Task with `runs_on` uses a VMM, Cloudflare, physical Station, or a [sandbox](../compute-devices.md#coding-sandboxes) of its own. Its Worker Session runs there.
`SalixWeb.StationTasks` invites the station, gives it each Message (`task.put`) and writes its posts into the Task as the Worker (`task.post`).
A desktop station must be connected when the Task is made; the Group's Cloud VM need not be: the VM is woken or made, and its station invited and given the Task once the VM is ready.
The Worker participant is delivered nothing, and its Session id names no Session Salix runs, so `SalixIM.TaskWorkerWatch` reminds and reports nothing for it.

`SalixIM.StationTaskWatch` watches a station Task instead.
A delegation is the latest Message given to the Worker that the Worker did not write; the first Worker Message after it answers it.
One timer per active station Task with an unanswered delegation; no scan, no poll.
The owner hands each appended Message to the watch: a Message costs no read. A check reads the Task's last 50 Messages and the station's standing (`SalixIM.Ports.TaskStations.standing/2`); once the station has the delegation, it also asks where its Session stands (`task.status`: one request, answered at once, starting nothing there). The next check comes after `recheck_ms` (10 minutes).
A delegation older than the 50-Message window is still waited for.
The stages below come from the standing and the Session's status. Thresholds count from the delegation; set them in `config :salix_im, :station_task_watch`.

| Stage | Meaning | Default threshold |
| --- | --- | --- |
| `vm_not_ready` | The Cloud VM or coding sandbox is not `ready`, or the Group has no Cloud VM. For the Cloud VM the Router is told once (`task_worker_stopped`, `vm_not_ready`) | 10 minutes (`vm_not_ready_ms`) |
| `station_offline` | The station's connector is not connected | 10 minutes (`station_offline_ms`) |
| `not_given` | The station was not given the delegation yet | 10 minutes (`not_given_ms`) |
| `running` | The station's Session runs a turn, or waits on work it started. Not a stall | 2 hours (`running_ms`), one `station_task_running` info event |
| `idle_no_reply` | The Session runs nothing, has nothing pending and posted nothing, or the station has no Session of the Task left | 10 minutes (`idle_no_reply_ms`), see below |
| `cannot_start` | Messages are pending, and the station's runtime does not start a turn. `last_failure` says why | 10 minutes (`cannot_start_ms`), or at once for a sign-in, quota or billing failure |
| `given_no_reply` | The station has the delegation and cannot say where its Session stands (a station from before `task.status`, no answer in 10 s, or a Session idle with Messages pending, held) | 30 minutes (`given_no_reply_ms`) |

A standing that cannot be read is no stage: the watch logs it and checks again after `recheck_ms`.
For `idle_no_reply` the watch reminds and reports as `SalixIM.TaskWorkerWatch` does inside Salix, with the same Messages and idempotency keys, at most once each per delegation.
When the delegation and the Session's idleness (`for_ms`, a duration the station measures) are both `idle_no_reply_ms` old, it appends one `task_worker_nudge` to the Worker, which runs a turn on it, and logs `station_task_nudged`.
Idle that long again after the reminder, with no reply, it appends one `task_worker_stopped` to the Router (`reason: stopped_after_reminder`), which ends the Router's `wait_for`.
For `cannot_start` there is no reminder. The watch appends `task_worker_stopped` (`reason: cannot_start`, with `last_failure`) once the stage is `cannot_start_ms` old, or at once when `last_failure` reads as a sign-in, quota or billing problem.
A `running` Session is never reminded. Sent reminders and reports are read from the Task's Messages, so a restarted watch sends neither twice. A failed append is retried at most 5 times, the stage waiting for it. With no Router to tell, the stall is still logged and counted.
A station whose Sessions of the Task ended answers `gone` to `task.put`. Salix removes it from the Task; new Messages do not reach it and the standing is `:not_station`.
When a check finds that with the delegation unanswered, the watch appends one `task_worker_stopped` for the Router (`reason: station_left`), logs `station_task_stalled` with stage `station_left`, and ends. A Router told for the epoch is not told again; an answered delegation ends quietly.
`place` comes from the Task record's `runs_on` (a Task from before it: the last standing read, else `other`).
The watch logs `station_task_stalled` once per delegation and stage: waiting stages when the delegation is as old as the threshold; `idle_no_reply`, `cannot_start` and `station_left` when the Router is told. A reminder that works is no incident.
The event carries `group_id`, `conversation_id`, `worker_agent_id`, `stage`, `place` (`cloud_vm`, `sandbox` or `device`), `vm_status`, `station_state`, `pending_messages`, `last_failure`, `epoch_seq` and `age_ms`.
The counter `salix.station_tasks.stalled.total{phase, kind}` counts the same events (`phase` is the stage, `kind` the place).
A reported delegation answered later logs `station_task_recovered` with its total wait.
Each answered delegation records `salix.station_tasks.first_reply.seconds{kind}`.
The Cloud Monitoring policy `comma_alerting:station_task_stalled` (P2, staging) fires for `place=cloud_vm` on every stage but `running` and `given_no_reply`, not for a canary.
A Task of a Group named in `canary_group_ids` is the [Cloud VM canary](../observability.md#cloud-vm-canary). Its events and samples carry `canary`; two more staging policies watch it.
The station reports its own failures (a failed turn, a runtime that did not start) as Worker Messages, which answer the delegation.
A desktop station that goes offline is logged and counted only: a closed laptop is no failure.
A station from before `task.status` answers an error, taken for `given_no_reply`: Salix, station and VM image release in any order.
A restarted watch rebuilds the delegation from the Messages. One younger than `stale_ms` (24 hours) can be reported a second time; an older one is logged as `station_task_stale` and not watched, and its first reply is not recorded.
A failure inside the watch is logged as `station_task_watch_failed` and the check is made again; it never stops the Task's owner.

## Continuation and containment

Follow-ups use the intended Task, not the latest active one. Resumed Tasks keep the new request's authority and audience.
Private input or a scheduled result does not become public because the Task already has a public reply.
See [IFC](../verification.md) for source and destination checks.

Schedules create bounded work through existing owners. Keep schedule identity, trigger occurrence, and Task activation distinct for retries.
An overdue trigger must not cause unbounded synchronous fan-out. The scheduler cannot widen the original disclosure audience.
A Task that is not `active` skips its windows and keeps its Schedule; only an ended Task or an unbound Schedule deletes it ([rules](../observability.md#task-schedule-lifecycle)).

## Background loops

A Loop is Agent-owned C that spinfoam runs on its lease holder. It is not a Schedule, Session, or Task, and has no occurrences or history.
Timers, events, and host capabilities drive it. Only `agent.notify` wakes its target Session. It uses `loop:<id>:<dedup_key>` to deduplicate guest retries.

`loop.create` records its path, SHA-256, config, and creator authority. Each load rereads and checks the hash. Changed or deleted files fail.

The next sweep restarts the owner Server of a stranded active Loop, one bounded page per node per minute.
Every load bumps the Loop's incarnation. Host calls require the current incarnation.
A `loop.state.put` checkpoint returns as `config.state` on the next load.
A Loop that returns is `paused(exited)`. A fault reloads it from its checkpoint at most three times an hour, then it is `failed`.
Each terminal outcome notifies the Session once. Archive pauses Loops with reason `archive`. Unarchive resumes them.
A Loop a Worker creates in a Task belongs to it (one per Task). Only that Task's rounds manage it, and the Task's end deletes it.
A [Loop Task](../architecture/DOMAIN_CONCEPTS.md#loop-tasks)'s Loop is written `pending` by the Task's request and gets its program from the Worker. The Task's end or archive ends it and keeps the row as `ended`.

A Loop may declare a trigger (`every_minutes`, or `cron` with an IANA `timezone`) and limits (`max_runs`, `ends_at`, `stop_condition`) on its row.
`loop.next_run` answers the trigger's next time after `after_ms`, in the trigger's timezone, and records it as `next_run_at`. After missed windows it answers the latest missed one.
Each delivered `agent.notify` is one run (`run_count`); the same source counts once. The run that reaches `max_runs` ends the Loop.
The first wake, `loop.next_run` or load at or after `ends_at` ends the Loop, and each node's minute sweep ends one page of the rest.
A guest wait (`sf_sleep_ms`, `sf_event_next`) returns after at most 24 hours.

Capabilities are a closed allowlist: `agent.notify`, `loop.state.put`, `loop.state.get`, `loop.ack`, `loop.log`, `loop.next_run`, registry tools classified `safety: read`, environment tools (`env.*`, `device.*`), SSH tools (`ssh.*`), `im_api.internal.read_conversation`, `composio.execute`, `web.http_request`, and `decide`.
Spinfoam admits only allowlisted calls. Product Loops also enforce pinned source and owner consent.
`composio.execute` permits provider writes. SSH tools permit commands, terminal interaction, file transfers, and host trust changes. `ssh.download` requires a `/drive` destination. No other writes are available.
Tools run through the same dispatch and IFC boundary as a round, with the Loop's sealed origin and the creator's tool disclosure.
A Loop acts with its creator's authority through the delegated principal `schedule|loop:<id>|<creator>`.
`agent.notify` admits six wakes per ten minutes per Loop. One hour of continuous limiting pauses the Loop with reason `budget`.
The built-ins (`agent.notify`, `loop.state.*`, `loop.ack`, `loop.log`, `loop.next_run`) bypass dependency admission, so a full Tenant cannot refuse a checkpoint or a wake. Each guest has at most one host call in flight.
Tool calls still take a `tool` slot. The node logs refused, timed-out, or failed built-in calls with the Loop and capability.

External events reach a Loop through `POST /v1/agent-groups/:group_id/loops/:loop_id/events` with a group API key.
`202` means PostgreSQL kept the event on its Loop, not that the guest processed it.
The guest calls `loop.ack` after a quiet decision or a durable downstream handoff. ACK insertion and pending removal share one transaction, fenced by the current incarnation.
Event payloads are data. They carry no authority and cannot widen the allowlist.

`loop.webhook` enables, rotates, or revokes one secret inbound URL per Loop. Only the owning Agent can manage it. `enable` keeps an existing URL.
`loop.list` and `loop.get` return the saved URL to the owning Agent. The Loop row stores the random 256-bit secret.
The secret authorizes event submission to that Loop only. Unknown or revoked secrets return `404` without delivery.
Keep the URL private. Rotation or revocation rejects later admissions, but does not cancel an event already admitted.
Deletion removes the URL. Pause and archive keep it, but reject events with `409`.

Send `POST /v1/loop-webhooks/:secret` with `Content-Type: application/json` and a JSON object. No Authorization header is required.
The event topic is `webhook`, and its payload is the full object.
`Idempotency-Key` supplies an optional event ID of at most 128 bytes. Without it, every request gets a fresh ID.
The group-key endpoint keeps its event envelope and payload-hash default.
Each Loop keeps up to 32 pending 16 KiB events. Repeated IDs keep the original payload and deadline.
The Reconciler replays the same IDs after adoption and each minute. Replay cannot restart a failed call in the same object, so guests own bounded provider and model retries.
After 15 minutes without ACK, the next owner sweep fails the Loop and keeps pending events.
Explicit resume grants 15 more minutes. Process restart does not. Pause keeps pending work. Deletion discards it.
Summary queries omit payloads. Active Group payloads total at most 50 MiB, excluding metadata and paused Loops.
ACK, Session admission, visible Message append, and external delivery are separate facts. Use stable downstream deduplication keys. Exactly-once external effects are not promised.

Shared Redis admits 60 requests per Loop per minute and 6,000 globally per minute. Global admission runs before secret lookup.
Limiting and full mailboxes return `429` with `Retry-After`. Limiter or storage outages return `503`.
Telemetry excludes URL secrets. Forward repair must keep pending events and ACKs.

See [Composio triggers](../identity-security.md#composio-trigger-authorization).

Each transition into `active` (create, resume, unarchive) is admitted atomically under the Group's lock. An unarchived Loop that the quota refuses stays `paused(quota)`.
The spinfoam child restarts with backoff at most five times an hour. Then the node reports Loops unavailable.
Runtime facts: [SalixAgent.Loops](../../systems/apps/salix_agent/lib/salix_agent/loops.ex) and [its Host, Reconciler and Capabilities](../../systems/apps/salix_agent/lib/salix_agent/loops/).

## Scripts

`salix.call` runs any canonical tool through the calling round's session tool dispatch. Disclosure, IFC, and dependency admission apply as for a direct call.

## Decision capability design

`decide` classifies runtime data, filters events, and selects data sources for scripts and Loops.
It returns decisions without reading sources, running tools, or granting authority. The caller supplies bounded candidates and applies thresholds in code.
Use `choice` for one candidate, separate `noul` questions for multiple matches, and `score` for ordered relevance.
An explicit `none` choice means no suitable candidate. Uncertainty is a successful answer, not a transport error.
[Jev](https://docs.typesafe.ai/introduction) [confidence](https://docs.typesafe.ai/confidence) describes a distribution, not correctness.

### Dispatch and authority

The canonical registry tool is `decide`. Scripts reach it through `salix.call`. Loops call it through their allowlist and ordinary session tool dispatch.
Agent disclosure, IFC, Loop incarnation checks, and dependency admission stay authoritative.
The capability adds no entity, persistent decision record, permission grant, or speculative replay eligibility.
Provider egress follows the public-egress policy. Restricted sources require the authorized flow before any provider request. By owner decision, the server-side [voice profile](../messaging-voice.md#voice-profile) sends Router session text without IFC filtering.
A decision keeps its source dependencies. It cannot authorize access or remove source restrictions.

The provider endpoint, model, and key are operator configuration, never tool arguments.
The server loads `decide.api_key`, `endpoint`, `model`, and `provider` from `config.json` at startup.
`endpoint` is the full request URL and can point to a Jev-compatible service.
Defaults: `https://api.typesafe.ai/v1/systemone`, `jev-1.13.0`, and `typesafe`.
Cloudflare Clef uses a Workers AI `ai/run` URL, model `clef`, and provider `cloudflare`. The adapter unwraps `result`.
An absent or empty `api_key` disables the provider. Invalid configuration returns `not_configured`.
Provider traffic passes through the LLM metering and encrypted-archive seam with Agent, Session, round, Tenant, and billing context.
No input, credentials, or raw provider errors enter metric labels or ordinary error messages.
Provider bodies have a 64 KiB read cap. Oversized responses archive the bounded prefix with a truncation marker, then fail.

## Archive

Archive is read-only and keeps Messages, history, and resources.
`archived_from_status` and `archived_at` define restore. Product authorization gates archive and restore.
Archive unbinds a Task Schedule; restore does not rebind it.
A local card is not archive state.

## Telegram topics

Enable BotFather Threaded Mode and Disallow users to create new threads.
General and unbound topics enter Router. Bound topics enter their Task.
`telegram.open_task_topic` adds a text Participant. User and Worker turns skip Router by default. Router instructions skip Topic.
Retirement restores normal routing. Explicit and saved targets stay unchanged.
Comma owns history, files, approval, and status controls. Service events keep Task status.
Reserve before the creation HTTP call. Recover uncertain creation manually. Never retry uncertain sends. Disconnect revokes access.
Task streams keep Worker identity during waits, except for activity and typing.

## Graph retirement release

The exclusive migration keeps Task IDs, history, files, Sessions, status, and the responsible Worker.
Graph state becomes historical metadata. Extra graph Agents become inactive. Worker and initiator get ordinary subscriptions.
Only active Tasks get a deduplicated handoff. Missing ownership or conflicting history fails conversion.
Late graph tool calls cannot advance state. External effects are not exactly-once.

1. Follow [human shutdown approval and recovery](../release-operations.md).
2. Inspect affected Tasks with bounded reads.
3. Back up affected Conversation and participant storage and record restore evidence.
4. Run `SalixIM.Release.retire_task_graphs(confirm_no_writers: true)` in an approved mainline release.
5. Keep writers stopped through conversion and projection writes (2,100 seconds, pages of at most 500 keys).

Before conversion, restore the saved snapshot if needed. After conversion, forward-repair with the same history and deduplication keys. Do not use the old runtime.
