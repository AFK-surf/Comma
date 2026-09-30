# Systems agent instructions

## Salix TLA+ specs

Follow the repository-wide 5,000-line system-core policy in
[`../tla/README.md`](../tla/README.md). The current Salix properties and code
mapping are in [`../tla/salix/README.md`](../tla/salix/README.md).
Update those retained abstractions in the same change when their semantics
change; explain unchanged mappings in the PR. Do not add a feature-level model
for every handshake, callback, recovery sweep or lifecycle. Keep implementation
regressions and explicit protocol assumptions even where formal coverage was
retired. Old source anchors outside the current roster are historical only.
Run `make tla`; retain the expected lease and RPC counterexamples rather than
claiming stronger exclusivity or delivery semantics than the code provides.

## Agent event archive

Everything the agent loop receives or sends must attempt encrypted archival at
the owning seam; no boundary may skip the attempt because the archive is
disabled or because one call site is inconvenient. Durable arrival remains
best-effort and follows the failure and detectability limits below. The closed
I/O surface is six boundaries: inbound delivery, provider request, provider
response (streamed deltas included), tool calls dispatched (withheld ones too),
tool results on every settlement path, and visible-reply egress.
Design: [`../docs/observability.md`](../docs/observability.md).

Emit at the **seam, not the call site**. Provider traffic archives inside
`SalixAgent.LLM`'s dispatch funnel, tool traffic inside `SalixAgent.Tools`, and
external-runtime traffic inside `SalixAgent.AgentActor.SessionCommand` — so a
call site that does not exist yet is still covered. Emitting per call site is
how the first version silently missed compaction — which ships the whole
conversation and is the last place that history exists. Adding a dispatch or
settlement path means adding its emitter in the same change; async settlement
has three separate paths and each needs its own.

An **external-runtime agent runs its loop off-node**, so boundaries 2 and 3
happen where nothing here observes them. What is archived for those agents is
what crossed the boundary with us: deliveries in, committed events out, and
tool traffic, which reaches the same `SalixAgent.Tools` seam an internal round
does. A contiguous `verify` report for such a session says nothing about
provider traffic, because none was ever expected.

**The seam covers a dispatch; it cannot NAME one.** A provider call site must
pass identity explicitly — `SalixAgent.LLM.complete/4`, `complete_stream/5` and
`compact_context/4` all take it as a last argument. `llm_opts` is not a
substitute: it is the template's provider config, resolved per TEMPLATE, and it
names no agent, session or round. Neither is the billing context: it uses the
`salix_`-prefixed identity keys, carries no session or round id under any name,
and its one plain `agent_id` is BridgeForTeams' own record id. An unattributed
dispatch still archives, but with four empty header columns onto the shared
stream `agent::inbox`, where a completeness check cannot bound a gap to a
session and the per-tenant `ALTER TABLE ... DELETE` matches nothing. Adding a
dispatch path means passing its identity in the same change.
Exercise that dispatch and check its archived identity in a behavior test.

Never extract from a payload at an emitter call site. Arguments evaluate in the
caller, outside every guard, so `call["tool_name"]` on a keyword list raises and
fails the turn. Pass raw containers; extract inside `SalixAgent.EventArchive.Emit`.

Archiving is observational and must never change a business result. It may not
raise, exit, block the loop, or alter control flow, whatever the payload shape
or the storage backend's state. It also may not be skipped because the archive
ships disabled — the structure has to hold before anyone turns it on.

Every item consumes a per-stream `seq` in the adapter before sealing. That is
necessary for detectability but NOT sufficient, and the difference is the whole
of the guarantee: a drop BRACKETED BY TWO ITEMS THAT LANDED is reportable,
because there is a later row to bound the hole. A drop at the end of a run is
not — a run whose last stored item is seq 1 and whose seq 2 was dropped queries
identically to a run that ended at seq 1. Tail loss, loss before the query
window, and a whole run lost are all invisible; the limits are enumerated in
`SalixAnalytics.EventArchive.Completeness`, and none of them may be described
as "every drop leaves a gap" or "silent loss is impossible".

The counters do not close that hole either, and must not be described as if
they did. `[…, :dropped]` fires on a full buffer and `[…, :lost]` on a failed
write — both from a live node that noticed. Neither covers the two cases that
matter most here: `reserve/1` emits nothing and nothing later notices an
unredeemed reservation, and a node that dies takes its ETS buffer with it, so
no process survives to count what was in it. Some tail loss has NO live signal
at all.

Never add a path that discards an item without consuming its `seq`, and where a
process can die before the emitter runs at all, reserve the position up front
(`EventArchive.reserve/1` — `Process.exit(pid, :kill)` is untrappable, so this
is not hypothetical). Reserving records the hole's POSITION; it does not by
itself make the hole reportable.

Payloads are sealed in the calling process, never in a queue or worker: the
buffer, a mailbox, and a crash dump hold ciphertext only. Plaintext headers
stay bounded and credential-scrubbed — they are a key-free index, and they are
what a tenant purge and a completeness check both run on.

Test archival through the owning seam and inspect captured or stored events.
Cover dispatch identity, settlement, and archive failure isolation.
Do not infer archival coverage from source strings or AST call placement.

## Platform telemetry

Telemetry is the archive's opposite: aggregate facts with no content. Neither
substitutes for the other, and a metric never carries what the archive carries.

Before changing a user-critical path, external call, background loop, queue, or
state machine, read
[`apps/systems_observability/GUIDE.md`](apps/systems_observability/GUIDE.md).
Review whether the change adds observable latency, failure, retry, backlog,
freshness, saturation, or a material state transition.

When a metric is warranted, define it directly in the owning domain's
`metrics/0`, emit its event at the narrowest owner boundary, and document the
specific operational question beside its metric definition or checked-in dashboard/rule consumer.
Keep executable PromQL with that consumer, not in a duplicate handwritten catalog.
Follow the shared bounds in [`../docs/observability.md`](../docs/observability.md).
Reuse the single `systems_observability` reporter, OTel SDK, trace-only
Collector, and `/metrics` endpoint. Do not add another reporter, exporter,
Collector, metrics endpoint, dynamic registry, or application mirror of an
external GKE/GMP descriptor.

Metric labels and trace attributes must be finite and normalized. Never include
tenant, org, user, agent, session, request, trace, or VM identifiers; raw paths,
URLs, queries, commands, prompts, completions, tool arguments/results, secrets,
or exception text. Keep `workload`, `component`, and `surface` as independent
facts.

Telemetry is observational. Never put synchronous telemetry coordination on a
request path, and never change business retry, pagination, scheduling, state,
persistence, or return contracts to improve a signal. Telemetry handler,
reporter, Collector, or exporter failure must not change a business result.

Tests should protect real behavior and collection boundaries: event-to-scrape,
bounded hostile input, context propagation, or failure isolation. Do not add
tests that merely restate a metric struct, mock, manifest string, or third-party
descriptor.
