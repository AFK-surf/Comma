# Agent runtime

## Agent and Session

Agents own identity, configuration, and runtime binding.
Sessions own history and control state; their actor commits by retained-revision CAS.
Repair, activation, compaction, and rounds share that revision through `commit_revision`.
Startup, unretained writes, and unknown outcomes reload storage. CAS conflicts discard the resident revision.
Activation commits materialization, visible-reply installation, the prompt snapshot, and active status in one CAS.
Fence assistant intent before effects. Replayable reads may overlap that fence.
Conversation, Participant, and login have separate lifecycles.
Resolve configuration using the canonical Agent tenant, not a request-supplied owner.
Role configuration builds use supervised reply workers.
Do not persist a live process or connector-run ID as the Agent's stable identity.

Routers coordinate intent and delegate ordinary Worker Tasks.
Role instructions do not replace server tool authorization.
See [Tools](tools-integrations.md) and [IFC](verification.md).

Explicit migration preserves the Session/native IDs and queued input. It freezes creation
and dispatch, seals the source, then commits the target binding. Ordinary rebind leaves old
Sessions pinned. See the [migration contract](compute-devices.md#session-迁移协议).

## User dependency liveness

LLMs, compaction, tools, runtimes, and Connectors need bounded lanes, owner identities, deadlines, cancellation, and stale-result fences. They must not indefinitely block core control or another tenant.

`SalixAgent.DependencyJob` carries the owner token, monitors the actor and task, and settles completion or cancellation once.
Late dependency results must not revive a cancelled owner or obsolete activation.
Core delivery staging uses a bounded RPC deadline and owner/Session fences.
Go Connectors consume this contract. They do not own Salix liveness.

Unconditional progress excludes S3 and database availability.
Preserve transient retryability. Do not classify a storage outage as poison input to make a loop appear bounded.
A bounded dependency error is a valid terminal outcome. An unbounded silent retry is not.

## Input, compaction, and continuation

Accepted pending input must survive owner restart and context compaction.
Do not drop fresh input because an earlier provider request or compactor finishes late.
Keep durable input identity separate from model context.
A context-window summary does not authorize additional disclosure or tool requests.

Compaction preserves runtime label facts through the actual host transformation.
Keep label and fresh-input property regressions even when abstract authorization laws have Lean proofs.
Manual and automatic compaction share durable continuation boundaries.
A normal state flush does not independently promise archive retry or completion.
See [Storage](storage-search.md) for format 3 sealing and recovery.

A canonical Router in a generic `wait_for` can yield to a queued human request.
A running async tool does not own that scheduling slot. Its durable call record and source provenance survive the yield.
Yield does not cancel the tool, complete the old request successfully, or report the old result as a result of the new request.
Active rounds, `auto_wait`, reply repair, and blocking provider obligations retain their existing guards.
Current-source runtime input is processed before a yield. The yield commit rechecks the wait and transcript snapshot.
This policy does not guarantee progress during storage failure or interrupt a running model request.

Active Routers cannot yield; queue pressure prompts delegation, not input reordering.
IM/Comma guards preserve queued input and send authorization.

On timeout or recovery, `SalixAgent.WaitExtension` re-arms `wait_for` while `SalixIM.RouterWaitProbe` finds a busy Worker. Wait/timer IDs rotate. The accumulated limit is `wait_for_extension_ceiling_seconds` (1800 seconds). The last extension fits the budget. Auto-waits, idle Workers, unavailable probes and exhausted budgets wake.
`SalixIM.TaskWorkerWatch` monitors active Tasks. After a grace, it reminds a silent stopped Worker once, then notifies the Router once per delegation. Workers that replied are left alone.

Two consecutive non-settling rounds fail the current turn (`runaway_unsettled_round_cap=2`). A fenced commit records abandonment of its replies/cards, aborts presentation/repair, and ACKs only its transcript. No model or notification send is required. Queued input and accepted async operations survive; nothing claims delivery or cancellation. Tool progress and fresh input reset this counter; waits consume no rounds.
Other guards stop at five identical results or `input_round_cap=120`. Model/guard failures without a safe notification path retire locally only without blocking cards or pending sends; accepted work and queued input survive. Guard wakes do not reset counters.

## Runtime control and observability

The verified kernel owns immutable Session values, event reduction, AgentLoop decisions, acceptance, activation, presentation, disclosure, and repair.
The host queries opaque handles and owns storage CAS, scheduling, cancellation, transport, external authority, entropy, writes, and presentation effects.
Lean commands select each step from observations and return external requests or terminal results.
The host retains an opaque authorization checkpoint across failed commits without comparing scopes or selecting presentation identities.
Round executes complete output and tool-batch plans. Lean selects repair finalization and encodes provider traffic. Tool adapters encode tool observations.
The request projection selects the compaction prefix, live messages, diagnostic redaction, and source annotations in Lean.
Later result reads do not replace earlier reader-page bodies. History reduction uses the existing compaction boundary, not per-request page folding.
Single-page envelope limits and diagnostic disclosure rules still apply. This preserves page prefixes, but does not guarantee provider cache hits.
Round passes its resident Session handle and transient activation facts to the LLM seam.
Lean projects prompt, context, attachment provenance, and runtime pages into provider JSON without exporting Session or intermediate messages to Elixir.
Observations contain only requested attachment preparations or authoritative async-result records.
Lean batches result-record reads, validates attachment provenance, then batches approved attachment reads.
Inbound attachments become workspace-file path notes. Only template-approved tool reads request image bytes.
Attachment projection needs at most two continuations, none for empty batches.
Elixir executes batches in order without extra concurrency. Selected active references bound each batch.
Projection cannot mutate Session or persist activation facts. Response acceptance owns those writes.
Elixir supplies Router authority, source-tool availability, disclosure, result sizing, image preparation, stored-result reads, credentials, callbacks, and network calls.
Lean owns Anthropic Messages, OpenAI Chat, and Responses bodies, headers, parsing, usage, and stream reconstruction.
Stream state stays in the native heap and produces ordered text, tool, and classified reasoning callbacks.
Lean decodes partial Responses argument strings before a complete SSE line arrives. It rejects inconsistent prefixes and preserves opaque reasoning data.
Lean selects Responses retries and the watchdog phase. Elixir executes the delay, timeout, cancellation, and HTTP operations.
Request guidance grants no tool authority or delivery guarantee.
Lean owns compaction and its fence. Elixir calls the model.
Lean selects settlement, onboarding completion, guidance budgets, wait timeouts, activation retry deadlines, and compaction recovery batches.
Restart planning reconciles durable capability requests with their Session executions.
Request deadlines drive recovery independently of model waits.
Stored outcomes survive. Lookup retries are bounded. Tools never re-execute.
Direct-poll results do not wake the model. See [callback recovery](tools-integrations.md#capability-request-recovery).
Elixir owns process liveness, timer delivery, archival attempts, and conditional commits. Lean classifies agent-loop provider errors.
Provider retry proofs prohibit transport retries after successful stream data and after the attempt budget ends.
Round allows five provider retries. Backoff starts at five seconds for 429/529 and 250 ms for other retryable errors.
Local backoff caps at one minute. `Retry-After` applies in full. A delay beyond the request deadline cancels retry.
Chat streams require `[DONE]` or a recognized finish reason. Missing completion or malformed SSE returns retryable `incomplete_stream`.
`length` returns `output_token_limit` before argument validation. Completed invalid arguments remain non-retryable.
Archive queries return ordered records and reject sequence gaps before the host starts segment I/O.
Use complete decisions or consumer projections for Session interactions, not host-side rules composed from field getters.
Reducer proofs do not establish timely external responses or remote cancellation.
Status and alerts must expose terminal errors.

The encrypted archive observes inbound, provider traffic, tool dispatch/results, and visible replies. Its failure cannot fail the Agent task.
See [Observability](observability.md) for the loss and confidentiality boundaries.

### Responses caching

`Session.Request` separates transient reminders from history.
Responses appends developer reminders outside instructions. History roles and other protocols stay unchanged.
Only kernel-built reminders change role. Text and external tags cannot select it. Authorization and repair redaction stay unchanged.

GPT-5.6+ excludes later developer messages from implicit cache boundaries; even short user reminders can displace reusable prefixes.
See [OpenAI caching](https://developers.openai.com/api/docs/guides/prompt-caching).
Reuse requires identical prefixes, eligible endpoints, and available cache. Compaction, prompt changes, and extended tool-result groups can prevent it.
Multi-round HTTP tests prove structure only. Live cache, cost, and reminder-following comparisons remain pending.
Usage telemetry measures reads/writes. No migration or new state.

## Validation

Test cancellation, stale results, input preservation, compaction, codecs, host facts and dependency failures through real adapters or controlled fixtures.
The Lean proof boundary is documented in [Verification](verification.md).

### Working state and durable fences

`InternalSessionStore.write_revision/3` changes an owner-local working Revision, retaining its durable baseline and pending events without acknowledging storage.
`durable_fence/4` persists through snapshot CAS and recovery prerequisites. Conflicts fail closed without replaying dirty plans against another owner state.

Ambiguous CAS compares raw read-back with retained upload bytes, not re-encoded state or markers.
Four settlement attempts precede four read-only attempts. An unchanged base or initial absence stays uncertain. Exhaustion returns `commit_indeterminate` without replay authority. A foreign version means conflict.
`flush_id` is diagnostic, not durable-success evidence.

Lean separates `write` from `durable_fence`. Input acknowledgments, including duplicates, and subsequent effects wait for the fence.
A working-state ledger hit cannot confirm durable acceptance.
For a committed revision, the fence checks ownership and epoch without another write. For pending work, it commits the frozen candidate first.
Direct-log staging carries a working input/frontier revision into activation within one owner callback.
The combined CAS admits the input, advances its source frontier, and records activation.
Generic delivery keeps its durable acknowledgment. A busy Router leaves unadmitted inputs in the source log.
Input, activation, log, and recovery commands retain their native Revision and continuation through writes and CAS, including first creation.
The host validates events, repairs command-argument UTF-8, and performs external effects.
Native revisions retain materialization plans through activation and persistence.
Only a native CAS result or committed revision can resume the captured fence continuation. The host cannot fabricate success.
Fresh revisions retain absence until create-if-absent succeeds.
The first tool fence includes assistant intent and running-call recovery records.
After canonical resolution and authorization, batches of at most four trusted replayable reads can start while persistence runs.
`Tools.replayable_read?/1` owns eligibility. HTTP, plugin, script, mixed, and larger batches keep intent-before-dispatch ordering.
Normal dependency admission, timeouts, provenance, and archive seams still apply.
Failed persistence cancels speculative dependencies and withholds results. No exactly-once external execution is promised.
The owner joins the frozen fence before another mailbox entry can change the revision.

For eligible async settlements, the Actor prepares activation in memory and computes alongside persistence within one callback.
The command stops at its fence without reporting durable success to Lean.
Provider deltas and results remain gated until fence success publishes Thinking with the durable activation scope.

A completion queues without a wake while a batch sibling runs locally or awaits a terminal commit retry.
The last settlement wakes and materializes every queued result. Wait deadlines and other input can still wake independently.
Speculation requires no due sibling settlement, a quiet mailbox, and no LLM, compaction, or reply-backoff hold.
Configuration prewarm and refresh rules are below.

Terminal results without workspace or skill events use the Session checkpoint as their receipt.
They do not access the workspace operation ledger. Large results and their reader references share that durable checkpoint.
Mutations and callback setup retain workspace receipts. Recovery never automatically repeats an interrupted effect.
A failed fence keeps provider output gated while settlement retry retains the tool result.
A retry that commits without the speculative activation cancels that provider dependency.
The next activation uses the committed revision without repeating the completed tool.
The persistence worker uses the initiating Actor's frozen runtime epoch.

Before reading durable Session state, provider tests call `SalixAgent.TestSupport.join_session_owner/2`.

### Delivery to first model request

`SalixStore.ReadScope` shares control reads within a delivery chain, activation, or provider/tool response callback.
Admission carries the caller's scope into the Session owner. Parallel configuration reads return their memo to that owner.
Errors are not cached. Writers invalidate changed keys. Outside a scope, reads reach storage.

A resident owner answers source-frontier queries from its committed revision. A busy owner leaves the input in the source log.
Cold sessions read storage. Direct-log admission joins input, frontier, and activation in one CAS.
Generic delivery retains its durable acknowledgment and separate wake.
A coalesced `:process` hint can join terminal settlement. Other queued work and sibling settlements still defer speculative continuation.

`RoundConfigPrewarm` starts configuration after Agent classification for a nonresident Session.
The claim installs ownership before its lease-index write. Generation binding reads the Session and adopts `RoundConfigCache.prewarm/2`.
Catalog, skill, plugin, and template reads overlap placement, claim, and delivery commit.
Snapshots younger than `round_config_refresh_min_age_ms` (default two seconds) are reused. Older snapshots start one background refresh.
Static skill materialization uses its existing versioned cache and invalidation. Committed configuration events invalidate the round snapshot immediately.
Each activation resolves live provider credentials alongside the current Agent record. A changed binding discards that preparation and resolves the current record.
Changed runtime or catalog versions rebuild the snapshot. Failed resolution withholds dispatch. Worker source grants bind per activation.
A cached catalog never grants permission to dispatch a tool.

Router startup checks its canonical Session. Switching stops the actor before retirement.
Stored revisions bypass birth probes. New Sessions retain them.
A live ownership cell routes locally. A fresh RPC head naming another owner fences that cell at its epoch before retry.
See the [TLA+ mapping](../tla/salix/README.md).
Wake returns placement errors. `queued` means the wake was sent, not that processing started.

A yielded wait joins the working revision without a store request. Activation or a separate fence persists it in the same processing entry.
The activation CAS overlaps provider computation. The owner joins the fence before another mailbox entry can write.
Failure cancels the speculative request and reloads storage. Pending provider calls, compaction, and retry timers block speculation.
Ingress regressions are in `apps/salix_im/test/slack_latency_reproduction_test.exs`.

## Internal session residency

Internal actors have no idle TTL. Memory permitting, they retain working revisions and round configuration.
External lifecycles, Agent lease release, and fencing remain unchanged.

`SessionResidency` samples local memory once per second. On cgroup v2 it reads
`memory.current`, `memory.max`, and `memory.stat` from the container namespace.
Inactive file cache is excluded from the soft working-set estimate, not from the
hard charge check. The default high/low working-set watermarks are 80%/65%.
Charge at 95% also starts pressure mode; charge must fall below 90% to leave it.
These margins reduce risk but cannot prevent OOM after arbitrary allocation bursts.

Under pressure, CLOCK scans at most 16 actors per sample. Real command admission
sets a reference bit; observation and recovery scans do not. A referenced actor
gets one extra scan before it becomes a candidate. Only the actor can retire
itself. It closes its atomic admission gate, checks pending work and its mailbox,
and stops normally only when safe. Admitted calls hold pins through their replies.
Casts hold pins through enqueue. Dead callers cannot leave permanent pins.
Commands rejected by a closed gate return `session_actor_retiring` before enqueue.
Callers must use the existing retry/recovery path, not assume execution occurred.

Pressure rejects starts of absent internal actors with `session_memory_pressure`.
Existing actors and supervisor-driven crash recovery remain admitted. Pending
model calls, compaction, tool work, commits, and retry timers prevent retirement.
A completed eviction batch must reduce observed charge before another batch.
If allocator retention prevents a reduction, scanning stops and admission remains
closed until measurements permit progress. The controller never forces GC or
kills active actors to meet a budget.

Unreadable or unlimited cgroups use `:salix_agent, :session_memory_budget_bytes`, default **4 GiB** (tests: 8 GiB).
This measures BEAM memory, not RSS or container limits. Invalid explicit budgets or sampler failures close new admission until valid samples return.
Existing actors remain available. No Prometheus read is involved.

The `salix_session_residency_` gauges `pressure`, `resident`, `stalled`, and `observed_at_seconds` report admission, actor count, reclamation stalls, and sample freshness.
For example, `salix_session_residency_stalled == 1` identifies stalled reclamation. Telemetry failure cannot change residency decisions.

Eviction preserves durable Session data. The existing kernel and ownership fence govern accepted work and commits.
No durable lifecycle state or domain entity is added.
