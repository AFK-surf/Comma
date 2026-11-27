# Tasks and background execution

## Canonical lifecycle

Tasks use Conversation-owned status. Cards only project it. Participants are Agents.
The owning Router can complete a delivered one-shot or Loop Task with no pending work or decision. This excludes recurring, Triage and legacy Workflow Tasks. A running Loop without a stop condition needs a person's request.
Messages never reopen Tasks. Escalation means blocked work needs the initiator, not routine approval.
Clients show an `escalated` Task as Needs input. A Worker's question card reaches the Router, which sets it `escalated` while the person answers and `active` when work resumes.

A Router prompt notice ends the source reply with each Task's confirmed status and its consequence. If the reply is already sent, follow up promptly.
Report failed writes truthfully, suppress same-status retries, and explain reopening.
Terminal Slack notices keep exact source/target, Session, installation and IFC checks. They add no internal-write authority and no exactly-once delivery.

## Ordinary Tasks

Each Task has a primary Worker and may bind up to 6 Worker Sessions reusing `task_worker_agent_id` via Participant `target_key` slots (no new entity or DB migration). Routers delegate commands and own status; Workers publish Messages.
A person's Task Message reaches both. The Worker answers; the Router acts only for status, memory or Router-only actions, then posts the result.
One create-only metadata write commits a new Task and its first command. Earlier failures leave no Task; a same-request retry drops uncommitted Messages.
After a grace period, `SalixIM.TaskWorkerWatch` reminds a silent Worker once (`task_worker_nudge`), then tells the initiator once (`task_worker_stopped`). Passive `context_only` Messages and `wake_reason: "all_sessions"` Messages for secondary Workers do not obligate a reply. In a running Loop, Router notes owe no reply.
Each `task_worker_nudge` replies to its delegation (`reply_to_message_id`), and replies targeting the nudge move onto that delegation. Clients hide internal watch Messages (`task_status_pending`, `task_worker_nudge`, `task_worker_stopped`).
If the Router stops after a Worker result on an active Task and all active Workers are idle, the watch tells the Router once per result (excluding recurring, Workflow, Triage, and active Loop Tasks).
The watch covers only Salix Sessions reporting activity, not [station Tasks](#station-tasks). For a QQ card, it also posts working, blocked and paused notices.
Provider cards and client timeouts cannot complete, cancel, or reopen Tasks. Telegram review cards complete Tasks through owner review only.

### Multi-session Tasks

A Router may create a multi-session Task (`sessions` 1..6, `initial_wake`: `primary | all`, `human_wakeup_policy`: `primary_only | all_sessions`), add a secondary Session (`im_api.internal.task.add_session`, Router-only, IFC-registered), or toggle `human_wakeup_policy` (`im_api.internal.task.update`).
Exclusions in v1: Loop (including ended), Collaborative (`People`), Triage, Scheduled, legacy Task Graph, and `TaskRun.switch` on multi-session Tasks return `:bad_request`. `TaskRun.switch` vs `add_session` exclusion is enforced at the ConversationActor commit boundary with an in-memory switch guard (not a cross-system 2PC lock); an owner restart mid-switch falls back to Station `gone` cleanup.
Primary uses `target_key: nil` (`"lead"` alias) and `notification_filter.messages: "all"`; secondaries use unique slug `target_key` (`^[a-z0-9][a-z0-9_-]{0,31}$`, excluding `all`, `router`, `delegator`, `lead`) and `notification_filter.messages: "mentioned"`.
`ConversationActor` keeps visibility in `delivery_filter`/explicit `mentions` and freezes `metadata.wake_targets` (leading `@slot` only; `@all` Human/Router only; unaddressed secondary routes to Lead only, never `TaskContinuation` or `TaskCardProjection`).
Consecutive worker-to-worker handoffs cap at 8 (`worker_handoff_count`, reset on Human/Router messages); hop 9 wakes zero Workers and appends one Router notice (excluding Telegram bound-topic Router).
Unwoken Sessions incur zero turns or attachment materialization; on wake, delivery prepends live Task Roster and bounded catch-up (<= 200 scan, <= 20 visible non-system messages, <= 16 KiB, filenames only, reference only). `TaskExecution` grants apply only to primary.

## Station Tasks

A Task with `runs_on` uses a VMM, Cloudflare, physical Station, or a [sandbox](../compute-devices.md#coding-sandboxes) of its own; its Worker Session runs there. `SalixWeb.StationTasks` invites the station, sends Messages (`task.put`), and writes posts as the Worker (`task.post`). A desktop station must be connected at creation; a Group Cloud VM need not be (woken/created, then invited on connect). Its Worker participant receives no Salix deliveries and has no Salix Session, so `SalixIM.TaskWorkerWatch` skips it.

`SalixIM.StationTaskWatch` watches it instead. A delegation is the latest non-`context_only` Message given to the Worker that it did not write; the first Worker Message after it answers it. `task_worker_nudge` replies to its delegation (`reply_to_message_id`), and replies targeting it move onto that delegation. One timer runs per active station Task with an unanswered delegation (no scan or poll). The owner hands each appended Message to the watch. Checks read the last 50 Messages, station standing (`SalixIM.Ports.TaskStations.standing/2`), and—once given—Session status (`task.status`), rechecking after `recheck_ms`. Delegations past the 50-Message window remain waited on. Stages and thresholds (`config :salix_im, :station_task_watch`):

| Stage | Meaning | Default threshold |
| --- | --- | --- |
| `vm_not_ready` | Cloud VM/sandbox not `ready`, or no Cloud VM (Cloud VM notifies Router once: `task_worker_stopped`, `vm_not_ready`) | 10m (`vm_not_ready_ms`) |
| `station_offline` | Station connector offline | 10m (`station_offline_ms`) |
| `not_given` | Station not yet given the delegation | 10m (`not_given_ms`) |
| `running` | Session active or waiting on work; not a stall | 2h (`running_ms`), `station_task_running` info |
| `idle_no_reply` | Session idle with nothing pending and no post, or missing Session | 10m (`idle_no_reply_ms`) |
| `cannot_start` | Pending Messages cannot start a turn; `last_failure` explains | 10m (`cannot_start_ms`), or immediate for sign-in/quota/billing |
| `given_no_reply` | Delegation given, status unknown (pre-`task.status`, 10s timeout, idle with pending) | 30m (`given_no_reply_ms`) |

Unreadable standing is logged and rechecked after `recheck_ms`. For `idle_no_reply`, when delegation age and Session `for_ms` reach `idle_no_reply_ms`, the watch appends one `task_worker_nudge` (`station_task_nudged`); idle that long again without reply appends `task_worker_stopped` (`stopped_after_reminder`) to the Router. `cannot_start` skips the reminder and sends `task_worker_stopped` (`cannot_start` + `last_failure`). `running` is never reminded. Failed appends retry up to 5 times; missing Routers still log and count. If `task.put` answers `gone`, Salix removes the station (`:not_station`); an unanswered delegation appends `task_worker_stopped` (`station_left`) and logs `station_task_stalled`. `place` comes from `runs_on` (legacy: last standing or `other`). `station_task_stalled` and `salix.station_tasks.stalled.total{phase, kind}` record each delegation/stage once (`group_id`, `conversation_id`, `worker_agent_id`, `stage`, `place`, `vm_status`, `station_state`, `pending_messages`, `last_failure`, `epoch_seq`, `age_ms`). Recovery logs `station_task_recovered` and `salix.station_tasks.first_reply.seconds{kind}`. `comma_alerting:station_task_stalled` (P2) fires for `cloud_vm`/`sandbox` on all stages except `running`/`given_no_reply`. Station-reported failures answer the delegation; sandbox `failed`/`lost` ends the wait; offline desktop stations only log/count. Restarts rebuild state from Messages; delegations older than `stale_ms` (24h) log `station_task_stale`. `SalixIM.StationTaskWatchRecovery` starts owners on node boot and placement change (100 Tasks/page, `station_task_watch_recovery`); watch failures log `station_task_watch_failed` without stopping the owner.

## Continuation and containment

Follow-ups use the intended Task, not the latest active. Resumed Tasks keep the new request's authority and audience.
Private input or a scheduled result does not become public because the Task already has a public reply.
See [IFC](../verification.md) for source and destination checks.

Schedules create bounded work through existing owners. Keep schedule identity, trigger occurrence and Task activation distinct for retries.
An overdue trigger must not cause unbounded synchronous fan-out. The scheduler cannot widen the original disclosure audience.
A Task that is not `active` skips its windows and keeps its Schedule; only an ended Task or an unbound Schedule deletes it ([rules](../observability.md#task-schedule-lifecycle)).

## Background loops

A Loop is Agent-owned C that spinfoam runs on its lease holder. It is not a Schedule, Session, or Task, and has no occurrences or history.
Timers, events, and host capabilities drive it. Only `agent.notify` wakes its target Session. It uses `loop:<id>:<dedup_key>` to deduplicate guest retries.

`loop.create` records its path, SHA-256, config and creator authority. Each load checks the hash. Changed or deleted files fail.

The next sweep restarts the owner Server of a stranded active Loop, one page per node per minute.
Every load bumps the incarnation. Host calls require the current one.
A `loop.state.put` checkpoint returns as `config.state` on the next load.
A Loop that returns is `paused(exited)`. A fault reloads its checkpoint at most three times an hour, then it is `failed`.
Each terminal outcome notifies the Session once. Archive pauses Loops (`archive`); unarchive resumes them.
`loop.pause` with `until_device_id` lasts until that device connects.
A Loop a Worker creates in a Task belongs to it (one per Task). Only that Task's rounds manage it, and the Task's end deletes it.
The Task keeps its row (trigger, limits, runs, checkpoint). `loop.create` there again replaces the program and restarts it, except after its end or an archive pause.
A [Loop Task](../architecture/DOMAIN_CONCEPTS.md#loop-tasks)'s Loop is written `pending` by the Task's request and gets its program from the Worker. The Task's end or archive ends it and keeps the row as `ended`.

A Loop's row may hold a trigger (`every_minutes`, or `cron` with an IANA `timezone`) and limits (`max_runs`, `ends_at`, `stop_condition`).
`loop.next_run` records the trigger's next time (in its timezone) after `after_ms`, default the unreached `next_run_at`, as `next_run_at`; after missed ones, the latest.
Each delivered `agent.notify` is one run (`run_count`). The run that reaches `max_runs` ends the Loop.
The first wake, `loop.next_run` or load at or after `ends_at` ends the Loop, and each node's minute sweep ends one page of the rest.
A guest wait returns after at most 24 hours.

Capabilities are a closed allowlist: `agent.notify`, `loop.state.put`, `loop.state.get`, `loop.ack`, `loop.log`, `loop.next_run`, registry tools classified `safety: read`, environment tools (`env.*`, `device.*`), SSH tools (`ssh.*`), `im_api.internal.read_conversation`, `composio.execute`, `web.http_request`, `decide`, and `im_api.internal.task.create` once the Cloud VM retires ([Loop Tasks](../architecture/DOMAIN_CONCEPTS.md#loop-tasks)).
Spinfoam admits only allowlisted calls. Product Loops also enforce pinned source and consent.
`composio.execute` permits provider writes; SSH tools permit commands, terminal interaction, file transfers and host trust changes; `ssh.download` only to `/drive`. No other writes are available.
Tools run through the same dispatch and IFC boundary as a round, with the Loop's sealed origin and the creator's tool disclosure.
A Loop acts with its creator's authority through the delegated principal `schedule|loop:<id>|<creator>`.
`agent.notify` admits six wakes per ten minutes per Loop. One hour of continuous limiting pauses the Loop with reason `budget`.
The built-ins bypass dependency admission, so a full Tenant cannot refuse a checkpoint or a wake. Each guest has at most one host call in flight.
Tool calls still take a `tool` slot.
`loop.get` shows a running Loop's last failed host call (`runtime.last_host_error`); a non-zero exit records it in `failure` and the exit notice.

External events reach a Loop through `POST /v1/agent-groups/:group_id/loops/:loop_id/events` with a group API key.
`202` means PostgreSQL kept the event, not that the guest ran it.
The guest calls `loop.ack` after a quiet decision or a durable downstream handoff. ACK insertion and pending removal share one transaction, fenced by the current incarnation.
Event payloads are data: they carry no authority and cannot widen the allowlist.

`loop.webhook` enables, rotates, or revokes one secret inbound URL per Loop; `enable` keeps an existing URL.
Only the owning Agent manages it and reads it in `loop.list`/`loop.get`. The row keeps a random 256-bit secret.
The secret authorizes event submission to that Loop only. Unknown or revoked secrets get `404`.
Keep the URL private. Rotation or revocation rejects later admissions, not an event already admitted.
Deletion removes the URL; pause and archive keep it but reject events (`409`).

Send `POST /v1/loop-webhooks/:secret` with `Content-Type: application/json` and a JSON object, without an Authorization header.
The event topic is `webhook`, and its payload is the full object.
`Idempotency-Key` supplies an optional event ID of at most 128 bytes, else each request gets a fresh ID.
The group-key endpoint keeps its event envelope and payload-hash default.
Each Loop keeps up to 32 pending 16 KiB events. Repeated IDs keep the original payload and deadline.
The Reconciler replays the same IDs after adoption and each minute. Replay cannot restart a failed call in the same object, so guests own bounded provider and model retries.
After 15 minutes without ACK, the next owner sweep fails the Loop and keeps pending events.
Explicit resume, not a process restart, grants 15 more minutes. Pause keeps pending work; deletion discards it.
Active Group payloads total at most 50 MiB, excluding metadata and paused Loops.
ACK, Session admission, visible Message append, and external delivery are separate facts. Use stable downstream dedup keys; external effects are not exactly once.

Shared Redis admits 60 requests per Loop and 6,000 globally per minute; the global check runs before secret lookup.
Limiting and full mailboxes return `429` with `Retry-After`. Limiter or storage outages return `503`.
Telemetry excludes URL secrets. Forward repair must keep pending events and ACKs.

See [Composio triggers](../identity-security.md#composio-trigger-authorization).

`loop.subscribe` subscribes a Loop to a product event, now `meeting.completed`: one per finished meeting, ids and counts only ([Loop Tasks](../architecture/DOMAIN_CONCEPTS.md#loop-tasks)).

Each transition into `active` (create, resume, unarchive) is admitted atomically under the Group's lock. An unarchived Loop that the quota refuses stays `paused(quota)`.
The spinfoam child restarts with backoff at most five times an hour, then the node reports Loops unavailable.
Code: [SalixAgent.Loops](../../systems/apps/salix_agent/lib/salix_agent/loops.ex), [loops/](../../systems/apps/salix_agent/lib/salix_agent/loops/).

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
Cloudflare Clef uses a Workers AI `ai/run` URL, model `clef`, and provider `cloudflare`.
An absent or empty `api_key` disables the provider. Invalid configuration returns `not_configured`.
Provider traffic passes through the LLM metering and encrypted-archive seam with Agent, Session, round, Tenant, and billing context.
No input, credentials, or raw provider errors enter metric labels or ordinary error messages.
Provider bodies have a 64 KiB read cap. Oversized responses archive the bounded prefix with a truncation marker, then fail.

## Archive

Archive is read-only and keeps Messages, history and resources.
`archived_from_status` and `archived_at` define restore. Product authorization gates archive and restore.
Archive unbinds a Task Schedule; restore does not rebind it.
A local card is not archive state.

## Telegram topics

Enable BotFather Threaded Mode and Disallow users to create new threads.
General and unbound topics enter Router; bound topics enter their Task.
`telegram.open_task_topic` adds a text Participant. User and Worker turns skip Router by default unless the Task ended. Router instructions skip Topic.
Retirement restores normal routing. Explicit and saved targets stay unchanged.
Comma owns history, files, approval and status controls. Service events keep Task status.
Reserve before the creation HTTP call. Recover uncertain creation manually. Never retry uncertain sends. Disconnect revokes access.
Task streams keep Worker identity during waits, except activity and typing.

## Graph retirement release

The exclusive migration keeps Task IDs, history, files, Sessions, status and the responsible Worker.
Graph state becomes historical metadata. Extra graph Agents become inactive. Worker and initiator get ordinary subscriptions.
Only active Tasks get a deduplicated handoff. Missing ownership or conflicting history fails conversion.
Late graph tool calls cannot advance state. External effects are not exactly-once.

1. Follow [human shutdown approval and recovery](../release-operations.md).
2. Inspect affected Tasks with bounded reads.
3. Back up affected Conversation and participant storage and record restore evidence.
4. Run `SalixIM.Release.retire_task_graphs(confirm_no_writers: true)` in an approved mainline release.
5. Keep writers stopped through conversion and projection writes (2,100 seconds, pages of at most 500 keys).

Before conversion, restore the saved snapshot if needed. After conversion, forward-repair with the same history and deduplication keys. Do not use the old runtime.
