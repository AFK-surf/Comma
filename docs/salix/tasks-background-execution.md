# Tasks and background execution

## Canonical lifecycle

Tasks use Conversation-owned status; cards only project it. Participants are Agents.
The owning Router may complete delivered one-shot Tasks with no pending work/decision,
not recurring, Triage or legacy Workflow Tasks. Messages never reopen Tasks.
Escalation means blocked work needs the initiator, not routine approval.

Router prompt notices end the source reply with each Task's confirmed status and
status-specific consequence; if already sent, follow up promptly. Report failed
writes truthfully, suppress same-status retries, and explain reopening.
Terminal Slack notices retain exact source/target, Session, installation and IFC
checks, not new internal-write authority or exactly-once delivery.
System-core TLA+ mappings are unchanged; runtime regressions cover authorization.

## Ordinary Tasks

Each Task has one Worker. Routers delegate commands and own status; Workers publish Messages.
One create-only metadata write commits a new Task and its first command.
Earlier failures leave no Task. A same-request retry drops uncommitted Messages.
`SalixIM.TaskWorkerWatch` reminds a stopped, silent Worker once, then notifies the initiator without another Task.

Provider cards and client timeouts cannot independently complete, cancel, or reopen Tasks.
Telegram review cards complete Tasks through owner review only.

## Continuation and containment

Follow-ups use the contextually intended Task, not merely the latest active one.
A resumed Task must preserve the authority and audience of the new request.
Private input or a scheduled result does not become public merely because the Task already has a public reply.
See [IFC](../verification.md) for source and destination checks.

Schedules create bounded work through existing owners.
Keep schedule identity, trigger occurrence, and Task activation distinct for retries.
Do not let an overdue trigger cause unbounded synchronous fan-out.
The scheduler does not grant a broader disclosure audience than the original request.

## Background loops

A Loop is Agent-owned C executed by spinfoam on its lease holder, not a Schedule, Session or Task; it has no occurrences or history.
Timers, events and host capabilities drive it. Only `agent.notify` wakes its target Session.
This ordinary delivery uses `loop:<id>:<dedup_key>` to deduplicate guest retries.

`loop.build` uses spinfoam's embedded TinyCC-to-eBPF compiler and VM on the owner node.
`loop.sdk` supplies its `spinfoam.h`, constraints and capabilities, without a template.
Owner-requested Comma proactive watches use one bundled Loop program. Only integer C is supported: no floating point or signed division/modulo.
Compilation needs no host toolchain or privilege and has no alternative path.
`loop.build` writes the ELF once to Agent VFS with the round's audience label.
`loop.create` records its path, SHA-256, config and creator authority. Loads reread and check the hash; changed/deleted files fail.

`SalixAgent.Server` claims adopt active Loops; passivation/fencing releases them.
Active Loops keep the Agent resident: idle park renews its lease.
A stranded active Loop (no object attached, or attached on a departed node) has its owner Server restarted by the next sweep, one bounded page per node per minute.
Every load bumps the Loop's incarnation. A host call from an object that is not the current incarnation is refused.
A checkpoint written through `loop.state.put` returns as `config.state` on the next load.
A Loop that returns is `paused(exited)`. A fault reloads it from its checkpoint at most three times an hour, then it is `failed`.
Each terminal outcome notifies the Session once. Archive pauses Loops with reason `archive`; unarchive resumes them.

Capabilities are a closed allowlist: `agent.notify`, `loop.state.put`, `loop.state.get`, `loop.ack`, `loop.log`, registry tools classified `safety: read`, environment tools (`env.*`, `device.*`), SSH tools (`ssh.*`), and `im_api.internal.read_conversation`, `composio.execute`, `web.http_request`, plus `decide`.
Ordinary Loops may call the allowlist. Product Loops also enforce their pinned source and owner consent. Spinfoam refuses other names.
`composio.execute` permits provider writes. SSH tools permit commands, terminal interaction, file transfers, and host trust changes. `ssh.download` requires a `/drive` destination. Other writes outside this allowlist are unavailable. Tools run through the same dispatch and IFC boundary as a round, with the Loop's sealed origin and the creator's tool disclosure.
A Loop acts with its creator's authority through the kernel's delegated-principal wrapper `schedule|loop:<id>|<creator>`.
`agent.notify` admits six wakes per ten minutes per Loop; an hour of continuous limiting pauses the Loop with reason `budget`.

External events reach a Loop through `POST /v1/agent-groups/:group_id/loops/:loop_id/events` with a group API key.
`202` means PostgreSQL retained the event on its Loop, not that the guest processed it.
The guest calls `loop.ack` after a quiet decision or a durable downstream handoff.
ACK insertion and pending removal share one transaction, fenced by the current Loop incarnation.
Event payloads are data. They carry no authority and cannot widen the Loop's allowlist.

`loop.webhook` enables, rotates, or revokes one secret inbound URL per Loop.
Only the owning Agent can manage it. `enable` preserves an existing URL.
`loop.list` and `loop.get` return the saved URL to the owning Agent.
The Loop row stores the random 256-bit secret directly so these reads can recover the URL.
The secret authorizes event submission to that Loop only. The Loop owner controls the expected secret.
The ingress verifies it with an indexed lookup. Unknown or revoked secrets return `404` without delivery.
Keep the URL private. Rotation or revocation rejects subsequent admission checks, but does not cancel an event already admitted or in flight.
Deletion removes the URL. Pause and archive retain it, but reject events with `409`.

Send `POST /v1/loop-webhooks/:secret` with `Content-Type: application/json` and a JSON object.
No Authorization header is required. The event topic is `webhook`, and its payload is the full object.
The request body limit is 16 KiB before parsing. `Idempotency-Key` supplies an optional event ID of at most 128 bytes.
Without that header, each request gets a fresh ID, including requests with identical bodies.
The existing group-key endpoint keeps its event envelope and payload-hash default.
Each Loop retains up to 32 pending 16 KiB events. Repeated IDs preserve the original payload and deadline.
The Reconciler replays the same IDs after adoption and each minute, including resident Loops.
Guests own bounded provider/model retries: spinfoam mailbox deduplication means replay cannot restart a failed call in the same object.
After 15 minutes without ACK, the next owner sweep fails the Loop, retains pending events and explains retry/discard.
Explicit resume grants 15 more minutes; process restart does not. Pause preserves pending work; deletion discards it.
Summary queries omit payloads. Active Group payloads total at most 50 MiB, excluding JSON metadata and paused Loops.
ACK, durable Session admission, visible Message append and external delivery are separate facts.
Stable downstream deduplication keys are required; exactly-once external effects are not promised.

Shared Redis admits 60 requests per Loop/minute and 6,000 globally/minute.
Global admission precedes secret lookup; expiring per-Loop buckets follow it, bounding unknown-secret traffic.
Limiting/full mailboxes return `429` with `Retry-After`; limiter/storage outages return `503`.
Existing bounded HTTP and `loop_event` telemetry exclude URL secrets.
The additive pending-events column preserves Loop facts and ownership. Pre-release volatile admissions are unrecoverable.
Post-cutover forward repair must preserve pending events and ACKs.

Composio trigger events use the provider event ID and trigger slug as the Loop event ID and topic.
The payload is the V3 event `data` object. See [Composio triggers](../identity-security.md#composio-trigger-authorization).

Quotas: 20 active Loops per Agent, 100 per Group, `spinfoam_max_objects` per node. Every transition into `active` (create, resume, unarchive) is admitted atomically under the Group's lock; an unarchived Loop the quota refuses stays `paused(quota)`. The spinfoam child restarts with backoff at most five times an hour, then the node reports Loops unavailable.
Runtime facts: [SalixAgent.Loops](../../systems/apps/salix_agent/lib/salix_agent/loops.ex), [Host](../../systems/apps/salix_agent/lib/salix_agent/loops/host.ex), [Reconciler](../../systems/apps/salix_agent/lib/salix_agent/loops/reconciler.ex), [Capabilities](../../systems/apps/salix_agent/lib/salix_agent/loops/capabilities.ex).

## Scripts

`script.run` and `script.run_file` run an agent-authored integer-C program once, inside the same spinfoam child, while the tool call waits.
A script is not a Loop: it has no row, no incarnation, no checkpoint, no events and no `agent.notify`. It is a transient part of one tool call.
The program is compiled by the embedded compiler (`sf.build.compile`, one synchronous request per run; spinfoam keeps no build cache) and the returned ELF is loaded directly. The ELF never enters the workspace.
`script.sdk` returns the guide, the compiler rules and the exact `spinfoam.h` of the node's binary.

The object is loaded with three capabilities. `salix.call {"tool", "args"}` executes any canonical tool through the calling round's own session tool dispatch, so disclosure, IFC and the outer dependency admission apply as they do to a direct call.
A tool failure returns as data (`{"ok": false, "error"}`); a JSON-RPC error would reach the guest as a bare `SF_HOST_ERROR`.
`script.result {"value"}` sets the return value and `script.log {"message"}` appends a console line. spinfoam's own `sf_log` frames are discarded when an object exits, so scripts do not use it.
`script.run` and `script.run_file` cannot be called from a script. `loop.*` and `agent.notify` are not script capabilities.

Limits: sources 32 files / 128 KiB, ELF 64 KiB, every JSON value and tool result 16 KiB (larger content is cut and marked `truncated`), 128 live handles, 5 s wall time counted as guest time only, at most 5 `script.run` calls per turn and `:salix_agent, :script_max_objects` (default 64) resident script objects per node.
Return 0 for success. A non-zero return, a fault, the wall limit, a lost child or a build failure is a model-only failed tool result that keeps the journal events and tool observations of the host calls that completed before it.
Terminal notifications are advisory: on the wall timer the run stops the object and reads its true terminal state, so a late exit notification still counts as the exit.
All Loop and script objects share the child's one execution thread; a busy script slows the node's Loops.
The two skill scripts that ship with the product (`ui-designer`, `website-manager`) are C programs run this way.
Runtime facts: [ScriptRun](../../systems/apps/salix_agent/lib/salix_agent/script_run.ex), [Build](../../systems/apps/salix_agent/lib/salix_agent/spinfoam/build.ex).

## Decision capability design

`decide` classifies runtime data, filters events, and selects data sources for scripts and Loops.
It returns decisions only. It does not read sources, execute selected tools, or grant authority.
The caller supplies bounded candidate descriptions and applies thresholds in code.
Use `choice` for one candidate, separate `noul` questions for multiple matches, and `score` for ordered relevance.
An explicit `none` choice represents no suitable candidate. Uncertainty is a successful answer, not a transport error.

Provider accuracy and latency require workload measurements before operational claims.
[Jev](https://docs.typesafe.ai/introduction) evaluates independent questions against shared state.
Its [confidence](https://docs.typesafe.ai/confidence) describes a distribution, not correctness or its largest probability.
The official [SDKs](https://docs.typesafe.ai/sdk) target Python and JavaScript.
Salix uses its existing Elixir HTTP library in a narrow adapter to avoid another runtime. Integration tests cover that adapter.

### Request and result

Arguments contain `state` (text, object, or array) and `questions` (one to eight named questions).
Each question has `type`, textual `instructions`, and type-specific `criteria`:

- `choice`: two to 32 option keys mapped to descriptions. The answer includes `choice`, `probabilities_bp`, and `confidence_bp`.
- `noul`: optional `true` and `false` descriptions. The answer includes `probability_bp`, without an invented confidence.
- `score`: two to ten ordered descriptions. The answer includes `score_milli`, `probabilities_bp`, and `confidence_bp`.

The response contains `model` and `answers`, keyed by the caller's question IDs.
Probability and confidence integers equal `floor(value * 10000)`. Score integers equal `floor(value * 1000)` on the original level scale.
This supports spinfoam's integer-only C. Quantized distributions can sum to less than 10000. Conversion never selects another winner.
Question and option keys contain at most 64 ASCII letters, digits, underscores, or hyphens.
Arguments have a 12 KiB encoded limit. Results must fit the 16 KiB host envelope, including JSON string escaping.
Oversized results fail before host publication. Decision JSON is never truncated.
Missing answers, invalid distributions, unknown options, and incompatible answer types fail the entire call without a default selection.

### Dispatch and authority

The canonical registry tool is `decide`; scripts reach it through `salix.call`.
Loops call `decide` through their explicit external-call allowlist and ordinary session tool dispatch.
Existing Agent disclosure, IFC, Loop incarnation checks, and dependency admission remain authoritative.
The capability adds no entity, persistent decision record, permission grant, or speculative replay eligibility.
Provider egress follows the existing public-egress policy. Restricted sources require the existing authorized flow before any provider request. By owner decision, the server-side [voice profile](../messaging-voice.md#voice-profile) sends Router session text without IFC filtering.
A decision preserves its source dependencies. It cannot authorize access or remove source restrictions.

The provider endpoint, model, and key are operator configuration, never tool arguments.
The server loads `decide.api_key`, `decide.endpoint`, and `decide.model` from `config.json` at startup.
`endpoint` is the full request URL, including the path, and can point to a Jev-compatible service.
Defaults are `https://api.typesafe.ai/v1/systemone` and `jev-1.13.0`.
An absent or empty `api_key` disables the provider. Invalid configuration returns `not_configured`.
Provider traffic passes through the LLM metering and encrypted-archive seam with Agent, Session, round, Tenant, and billing context.
No input, credentials, or raw provider errors enter metric labels or ordinary error messages.
Provider bodies have a 64 KiB read cap. Oversized responses archive the bounded prefix with a truncation marker, then fail.

A provider exchange has a two-second execution budget within the five-second tool deadline and makes at most one HTTP request, without redirects or automatic retries.
Scripts and Loops share admission limits. There can be 100 active Loops per Group, so per-Loop limits alone are insufficient.
Node-local fixed-window budgets admit 60 calls per minute and four per second for each Tenant/Group pair.
All callers share these buckets, including direct model calls. Buckets expire and reset on node restart.
These are not cluster quotas: a Group on N nodes can consume N times its node allowance.
Existing dependency admission bounds in-flight work per node and Tenant. Provider calls reserve their own dependency slot.
After dispatcher schema and authorization checks, capability failures return `{"error":{"code":"..."}}` as data.
Codes are `invalid_request`, `not_configured`, `context_unavailable`, `rate_limited`, `billing_unavailable`, `unavailable`, `timeout`, `provider_error`, `invalid_response`, and `result_too_large`.
Programs must check this object before reading `answers`. Dispatcher denials retain their existing guidance or host-error behavior.
Programs choose backoff, checkpointing, or `agent.notify` within its existing notification budget. There is no automatic large-model fallback.

### Model guidance and verification

Tool help and both SDK guides limit `decide` guidance to repeated runtime classification and source selection.
Agents must make current conversational judgments themselves, not create scripts for isolated reasoning.
Programs must handle uncertainty, no match, and errors without waking the Agent unnecessarily.

Prompt guidance is not a new authorization boundary.
Runtime tests must compile real C programs, branch on integer decisions, and cover Loop calls without model completion.
Adapter tests cover the wire request, malformed answers, timeouts, rate limits, and credential-safe errors.
Dispatch tests cover disclosure, restricted-source refusal, metering refusal, and attributed archival.
Existing system-core models retain ownership and authorization responsibility. This capability adds no distributed lifecycle or progress claim.
Implementation: [Decide](../../systems/apps/salix_agent/lib/salix_agent/decide.ex),
[HTTP adapter](../../systems/apps/salix_agent/lib/salix_agent/decide/provider.ex),
[request limits](../../systems/apps/salix_agent/lib/salix_agent/decide/limits.ex),
[LLM seam](../../systems/apps/salix_agent/lib/salix_agent/llm.ex).

## Archive

Archive is read-only Conversation state retaining Messages, history and resources.
`archived_from_status` and `archived_at` define restoration.
Product authorization controls archive and restore operations.
A local hidden card is not canonical archive state.

## Validation

Keep regressions for Task delegation, cancellation, archive restoration, human completion, and Worker recovery.
See [bounded Task search](../storage-search.md).

## Telegram topics

Enable BotFather Threaded Mode and Disallow users to create new threads.
General/unbound topics enter Router. Bound topics enter their Task.
`telegram.open_task_topic` adds a text Participant. User/Worker turns skip Router by default. Router instructions skip Topic.
Retirement restores normal routing. Explicit and saved targets stay unchanged.
Comma owns history, files, approval, and status controls. Service events preserve Task status.
Reserve before creation HTTP. Recover uncertain creation manually. Never retry uncertain sends. Disconnect revokes access.
Task streams retain Worker identity during waits, apart from activity/typing.

## Graph retirement release

The exclusive migration preserves Task IDs, history, files, Sessions, status, and the responsible Worker.
Graph state becomes historical metadata. Extra graph Agents become inactive. Worker and initiator receive ordinary subscriptions.
Only active Tasks receive a deduplicated handoff. Missing ownership or conflicting history fails conversion.
Late graph tool calls cannot advance state. Old runtimes may retain instructions. External effects are not exactly-once.

Follow [human shutdown approval and recovery](../release-operations.md). Inspect affected Tasks with bounded reads before execution. Back up affected Conversation and participant storage and record restore evidence.
An approved mainline release runs `SalixIM.Release.retire_task_graphs(confirm_no_writers: true)`.
Keep writers stopped through conversion and projection writes: 2,100 seconds, pages of at most 500 keys.
Before conversion, restore the saved snapshot if needed. Afterward, forward-repair with the same history and deduplication keys. Do not use the old runtime.
