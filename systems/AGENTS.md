# Systems agent instructions

## Time and timers

Application code reads time and arms timers through `SystemsClock`. See [`../docs/testing.md#deterministic-runtime`](../docs/testing.md#deterministic-runtime) and the rules in `lint/rules`.
Never add to the baseline or the rule's ignores.

## Salix TLA+ specs

Current Salix properties and code mapping are in [`../tla/salix/README.md`](../tla/salix/README.md).

## Cloudflare Group VMs

Follow the root [Cloud VM data policy](../AGENTS.md#cloud-vm-data-policy).
Do not add a local-file preservation gate or repeat failed recovery to delay a reset.

## Agent event archive

Everything the agent loop receives or sends must attempt encrypted archival at the owning seam.
No boundary may skip the attempt because the archive is disabled or a call site is inconvenient.
Durable arrival is best effort, within the detectability limits below.
The closed I/O surface is six boundaries: inbound delivery, provider request, provider response (streamed deltas included),
tool calls dispatched (withheld ones too), tool results on every settlement path, and visible-reply egress.
Design: [`../docs/observability.md`](../docs/observability.md).

Emit at the seam, not the call site. Provider traffic archives inside `SalixAgent.LLM`'s dispatch funnel,
tool traffic inside `SalixAgent.Tools`, and external-runtime traffic inside `SalixAgent.AgentActor.SessionCommand`.
A new dispatch or settlement path needs its emitter in the same change. Async settlement has three separate paths, and each needs its own.

The seam covers a dispatch but cannot name it. A provider call site must pass identity explicitly as the last argument of
`SalixAgent.LLM.complete/4`, `complete_stream/5`, and `compact_context/4`.
`llm_opts` is not a substitute: it is per-template provider config and names no agent, session, or round.
The billing context is not a substitute either: it uses `salix_`-prefixed keys, has no session or round id, and its `agent_id` is the BridgeForTeams record id.
An unattributed dispatch archives with four empty header columns onto the shared stream `agent::inbox`.
There, a completeness check cannot bound a gap to a session, and the per-tenant `ALTER TABLE ... DELETE` matches nothing.
A new dispatch path must pass its identity in the same change. Exercise it and check its archived identity in a behavior test.

Archiving is observational and must never change a business result.
It may not raise, exit, block the loop, or alter control flow, for any payload shape or storage backend state.
It may not be skipped because the archive ships disabled.

Every item consumes a per-stream `seq` in the adapter before sealing. That makes a drop between two landed items reportable, and nothing more.
Tail loss, loss before the query window, and loss of a whole run are invisible.
`SalixAnalytics.EventArchive.Completeness` lists the limits. Never describe the archive as "every drop leaves a gap" or "silent loss is impossible".

The counters do not close that hole. `[…, :dropped]` fires on a full buffer and `[…, :lost]` on a failed write, both from a live node.
`reserve/1` emits nothing, and nothing notices an unredeemed reservation. A node that dies loses its ETS buffer uncounted.
Some tail loss has no live signal.

Never add a path that discards an item without consuming its `seq`.
Where a process can die before the emitter runs (for example `Process.exit(pid, :kill)`), reserve the position first with `EventArchive.reserve/1`.
A reservation records the hole's position. It does not by itself make the hole reportable.

Seal payloads in the calling process, never in a queue or worker. The buffer, mailboxes, and crash dumps hold ciphertext only.
Plaintext headers stay bounded and credential-scrubbed. They are the key-free index that tenant purge and completeness checks use.

Test archival through the owning seam and inspect captured or stored events.
Cover dispatch identity, settlement, and archive failure isolation.
Do not infer archival coverage from source strings or AST call placement.

## Platform telemetry

Telemetry holds aggregate facts with no content. It does not replace the archive, and a metric never carries archive content.
Follow [`apps/systems_observability/GUIDE.md`](apps/systems_observability/GUIDE.md) and the shared bounds in [`../docs/observability.md`](../docs/observability.md).

Metric labels and trace attributes must be finite and normalized.
Never include tenant, org, user, agent, session, request, trace, or VM identifiers. Never include raw paths, URLs, queries, commands,
prompts, completions, tool arguments or results, secrets, or exception text.
Keep `workload`, `component`, and `surface` as independent facts.
