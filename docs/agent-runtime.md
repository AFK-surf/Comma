# Agent runtime

## Agent and Session

Agents own identity, configuration, and station binding.
Sessions own history and control state. Their actor commits by retained-revision CAS through `commit_revision`.
Startup, unretained writes, and unknown outcomes reload storage. CAS conflicts discard the resident revision.
Activation commits materialization, visible-reply installation, the prompt snapshot, and active status in one CAS.
Fence assistant intent before effects. Replayable reads may overlap that fence.
Conversation, Participant, and login have separate lifecycles.
Resolve configuration with the canonical Agent tenant, not a request-supplied owner.
Do not persist a live process or connector-run ID as the stable Agent identity.

Routers coordinate intent and delegate ordinary Worker Tasks.
Role instructions do not replace server tool authorization. See [Tools](tools-integrations.md) and [IFC](verification.md).
External Sessions are retired. Their stored history stays read-only
([Retired Sessions](architecture/DOMAIN_CONCEPTS.md#retired-sessions)).

## User dependency liveness

LLMs, compaction, tools, runtimes, and Connectors need bounded lanes, owner identities, deadlines, cancellation, and stale-result fences. They must not block core control or another tenant indefinitely.

Late results must not revive a cancelled owner or obsolete activation.
Core delivery staging uses a bounded RPC deadline and owner and Session fences.
Model requests have 600 s, including retries. Router round requests have 300 s.
A stream fails after 120 s without a first SSE event, or 30 s between events. `: keep-alive` comments are not events.
Go Connectors follow this contract. Salix owns liveness.

Unconditional progress excludes S3 and database availability.
Keep transient errors retryable. Do not classify a storage outage as poison input.
A bounded dependency error is a valid terminal outcome. An unbounded silent retry is not.

## Input, compaction, and continuation

Accepted pending input must survive owner restart and compaction.
Model calls and capacity backoff permit bounded input admission. Storage recovery still blocks it.
Slot release notifies one eligible owner. Watches use the global dependency limit, one per owner. Timers cover missed wakes and full watch sets.
Reports can batch at activation. Human requests keep separate scopes and order.
A late provider request or compactor must not drop fresh input.
Keep durable input identity separate from model context.
A summary does not authorize additional disclosure or tool requests.
Compaction preserves runtime label facts through the actual host transformation.
Manual and automatic compaction share durable continuation boundaries.
A normal state flush does not promise archive retry or completion. See [Storage](storage-search.md) for format 3 sealing and recovery.

A canonical Router in a generic `wait_for` can yield to a queued human request.
A running async tool does not own that slot. Its durable call record and source provenance survive the yield.
Yield does not cancel the tool or report the old result as a result of the new request.
Active rounds, `auto_wait`, reply repair, and blocking provider obligations keep their guards.
The yield commit rechecks the wait and transcript snapshot after current-source runtime input.
Yield does not guarantee progress during storage failure or interrupt a running model request.
Active Routers cannot yield. Queue pressure prompts delegation, not input reordering.
IM and Comma guards keep queued input and send authorization.

Queued input and accepted async operations survive. Nothing claims delivery or cancellation. Waits consume no rounds.
Guards stop at five identical results or `input_round_cap` (120). Without a safe notification path, model or guard failures retire locally. Guard wakes do not reset counters.

## Runtime control and observability

The host owns storage CAS, scheduling, cancellation, transport, external authority, entropy, writes, and presentation effects.
Lean selects each step from observations and returns external requests or terminal results. See [Verification](verification.md#shared-executable-kernel-boundary) for the full split.

Later result reads do not replace earlier reader-page bodies. This keeps page prefixes, but does not guarantee provider cache hits.
Inbound attachments become workspace-file path notes. Only tool reads by image-capable models request image bytes.
Projection cannot mutate the Session. Response acceptance owns those writes.
Request guidance grants no tool authority or delivery guarantee.

Restart planning reconciles durable capability requests with their Session executions.
Stored outcomes survive. Lookup retries are bounded. Tools never re-execute.
Direct-poll results do not wake the model. See [callback recovery](tools-integrations.md#capability-request-recovery).

No transport retry follows successful stream data.
Chat streams need `[DONE]` or a known finish reason. Otherwise they return retryable `incomplete_stream`.
`length` returns `output_token_limit` before argument validation. Completed invalid arguments are not retryable.
Status and alerts must expose terminal errors.

An archive failure cannot fail the Agent task.
See [Observability](observability.md) for loss and confidentiality limits.

### Request caching

A request is the stored prompt, stored context, and the delta that acceptance stores.
Turn rules, miniskill selections, and interaction-tool reminders are stored.
Chat and Responses send later runtime messages as `get_runtime_message` calls.
Anthropic gets runtime state as `system` messages and external content as user text.
Only kernel-built messages change role. Text and external tags cannot select it.
Compaction, prompt changes, acknowledged attachments, archive advances, and extended tool-result groups can prevent cache reuse.
Tests prove request structure only. Live cache hits, cost, and rule-following remain unverified.
Claude thinking requests set `block_binding` to `drop_block`. The `llm_input_transformations` warning lists drops.

### Working state and durable fences

`InternalSessionStore.write_revision/3` changes an owner-local working Revision without acknowledging storage.
`durable_fence/4` persists through snapshot CAS. Conflicts fail closed without replaying plans against another owner state.

Ambiguous CAS compares raw read-back with the retained upload bytes.
Four settlement attempts precede four read-only attempts. Exhaustion returns `commit_indeterminate` without replay authority. A foreign version means conflict.
`flush_id` is diagnostic, not proof of durable success.

Input acknowledgments, including duplicates, and later effects wait for the fence.
A working-state ledger hit cannot confirm durable acceptance.
Only a native CAS result or committed revision can resume the fence continuation. The host cannot fabricate success.
The first tool fence includes assistant intent and running-call recovery records.

After resolution and authorization, batches of at most four trusted replayable reads can start while persistence runs.
`Tools.replayable_read?/1` owns eligibility. HTTP, plugin, script, mixed, and larger batches dispatch only after intent persists.
Failed persistence cancels speculative dependencies and withholds results. No exactly-once external execution is promised.
The owner joins the fence before another mailbox entry can change the revision.

Provider output stays gated until the fence succeeds.
A completion queues without a wake while a batch sibling still runs. The last settlement wakes and materializes every queued result.
Speculation needs no due sibling settlement, a quiet mailbox, and no LLM, compaction, or reply-backoff hold.

Terminal results without workspace or skill events use the Session checkpoint as their receipt.
Mutations and callback setup keep workspace receipts. Recovery never repeats an interrupted effect automatically.
A failed fence keeps provider output gated, and settlement retry keeps the tool result.
The next activation uses the committed revision without repeating the completed tool.

### Delivery to first model request

A resident owner answers source-frontier queries from its committed revision. Cold sessions read storage.

`RoundConfigPrewarm` starts configuration after Agent classification for a nonresident Session.
Snapshots younger than `round_config_refresh_min_age_ms` (default 2 s) are reused. Older snapshots start one background refresh.
Committed configuration events invalidate the snapshot immediately. Changed runtime or catalog versions rebuild it.
Each activation resolves live provider credentials with the current Agent record. Failed resolution withholds dispatch.
Worker source grants bind per activation. A cached catalog never grants permission to dispatch a tool.

A fresh RPC head that names another owner fences the local ownership cell at its epoch before retry.
See the [TLA+ mapping](../tla/salix/README.md).
Wake returns placement errors. `queued` means the wake was sent, not that processing started.
A failed speculative activation CAS cancels the request and reloads storage.

## Condensed Workspace

With `condensed_workspace_enabled` on, internal Router and Worker Sessions keep the Group's [Condensed Workspace](architecture/DOMAIN_CONCEPTS.md) in context.
Provider state is the seen revision and `compacted_through`. New, compacted, or stale Sessions get the full list next round.
The latest writer gets its tool result instead. Delivery wakes no Session.
Warm Sessions adopt a flag change after a background configuration refresh. Disabling sends one notice.

After a response with tool calls, a parallel task asks `needs_update` and `off_track` about the list, the 16 newest conversation texts, and the tool calls. By owner decision, IFC does not filter it.
The next activation waits until 5 s after the start. A reminder asks to rethink on `off_track`, else to update on `needs_update`.
Failure or a refused budget sends nothing. A kind repeats only after a revision change or three checks.
Answers expire after 10 min or a restart.
The write check shares its [`decide` limits](../systems/apps/salix_agent/lib/salix_agent/decide/limits.ex). `:salix_agent, :condensed_workspace` sets cutoffs.
