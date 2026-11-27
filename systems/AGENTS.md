# Systems agent instructions

These rules apply to `systems/`, releases, rollouts, migrations, and providers. The root `AGENTS.md` also applies.

## Time and timers

Application code reads time and arms timers through `SystemsClock` ([deterministic runtime](../docs/testing.md#deterministic-runtime), `lint/rules`). Never add to the baseline or the rule's ignores.

## Salix

For Salix conversations, participants, messages, or delivery, use [`../docs/README.md`](../docs/README.md) to find the contract.
Mutate only through `ConversationServer -> ConversationActor`.
Participant mutation is separate from message append. Participants are delivery targets, not senders.
Never persist the in-memory `participant_count` aggregate.

For a modeled protocol, follow [`../tla/AGENTS.md`](../tla/AGENTS.md). Salix properties and code mapping: [`../tla/salix/README.md`](../tla/salix/README.md).

## Release convergence and migrations

Rollouts and provider migrations may interrupt service between phases. Preserve central product facts and persistent user data (Group disks: [Cloud VM data policy](#cloud-vm-data-policy)).
After cutover, restore service within the documented release or provider budget, or return a bounded, actionable error for a failed dependency.
Do not add a rolling-window reader, dual write, fallback, adapter, shadow state, or extra rollout only for intermediate availability.
Transform durable facts once, rebuild only owner-approved disposable state, or fail closed until the completed release reconciles the path.

Graceful rolling updates are the default. Staging scale-to-zero or deployment-wide shutdown requires a human issue comment under the [policy](../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).
The issue title and body must say `HUMAN APPROVAL REQUIRED - AGENTS MUST NOT APPROVE`.
Agents must never approve, impersonate a human approver, or bypass this through direct cluster commands. Mixed-version unavailability alone is no reason for shutdown.

An incompatible schema cutover may use the existing `exclusive` release mode only with that human approval.
The changed release contract must name the surviving durable facts, the exact disposable scope,
the post-cutover convergence condition and budget, and whether recovery is pre-cutover rollback or post-cutover forward repair.
Do not add compatibility state only to make an old binary a post-cutover rollback target.
Backups and restore evidence are required only for durable data the cutover can alter, not for an owner-approved rebuild of disposable projections.

Resolve destructive scope with a bounded read before execution. Never infer that a cache, VM disk, workload volume, credential store, or projection is disposable. The owning product decision must name it.
Preserve unrelated data, use only approved mainline artifacts, and report required re-enrollment or reauthentication in the convergence result.

## Cloud VM data policy

Cloudflare Group VMs are volatile Agent execution environments. Their disks, local repositories, dependencies, harness state, native history, credentials, and output not yet in Salix are disposable.
Archive and restore are best effort: restore from available archives through the existing bounded recovery path. If it fails, reset the exact VM and rebuild or reinstall local state. Do not add a local-file preservation gate or repeat failed recovery to delay a reset.
Their loss needs no further human approval and does not block a release.
A destructive reset must not restore old pending execution as current work. Report any required login or interrupted work.
Salix-owned Sessions, Messages, accepted queues, credentials, and execution records keep their own storage and ownership rules.
A discarded VM does not prove that an input was never sent or that an external side effect failed.
Fence old commands and confirm the exact target stopped before you replace it.
This policy does not apply to user Devices or persistent Agent VMM Hosts.

## Runtime, providers, and tests

- Separate manager connectivity, command authority, and child process lifetime.
  Manager loss, upgrade, or an older version alone does not authorize stopping independent children or invalidating their durable identity.
  Reject unsupported operations locally. Keep explicit revocation and stale-target fencing, without turning them into unrelated health gates.
- Bound requests, pages, concurrency, and recovery work, not total workload or appliance count. Existing constants and TLA bounds are not product capacity decisions.
  Appliance resource budgets are shared, not per-appliance CPU/memory reservations or fixed percentage partitions.
- A file-descriptor identity check may protect one operation from path replacement. Do not promote inode, ctime, transport epoch,
  or executable version to durable business identity without a concrete failure, owner, and behavior-changing consumer.
- Billing catalogs use stable product-owned plan/package keys and provider lookup keys. Provider ids such as Stripe `price_*`/`cus_*` are synchronized mappings, not product identity.
- Never sync providers from migrations. Migrations may seed local catalogs. Explicit release/ops tasks converge external objects with dry-run, retries, and drift failure.
- Remove property tests fully covered by Lean only after you identify the executable theorem and confirm the same property and input domain.
  An abstract or similarly named theorem is insufficient. Keep codec, FFI, host-fact resolution, compaction, transport, and other runtime tests outside that proof boundary.

## Agent event archive

Everything the agent loop receives or sends must attempt encrypted archival at the owning seam.
No boundary may skip the attempt because the archive is disabled (as it ships) or a call site is inconvenient.
Durable arrival is best effort, within the detectability limits below.
The closed I/O surface is six boundaries: inbound delivery, provider request, provider response (streamed deltas included),
tool calls dispatched (withheld ones too), tool results on every settlement path, and visible-reply egress.
Design: [`../docs/observability.md`](../docs/observability.md).

Emit at the seam, not the call site. Provider traffic archives inside `SalixAgent.LLM`'s dispatch funnel,
tool traffic inside `SalixAgent.Tools`, and external-runtime traffic inside `SalixAgent.AgentActor.SessionCommand`.
A new dispatch or settlement path needs its emitter in the same change. Each of the three async settlement paths needs its own.

The seam covers a dispatch but cannot name it. A provider call site must pass identity explicitly as the last argument of
`SalixAgent.LLM.complete/4`, `complete_stream/5`, and `compact_context/4`.
`llm_opts` is no substitute: it is per-template provider config and names no agent, session, or round.
Nor is the billing context: it uses `salix_`-prefixed keys, has no session or round id, and its `agent_id` is the BridgeForTeams record id.
An unattributed dispatch archives with four empty header columns onto the shared stream `agent::inbox`.
There, a completeness check cannot bound a gap to a session, and the per-tenant `ALTER TABLE ... DELETE` matches nothing.
A new dispatch path passes its identity in the same change. Exercise it in a behavior test that checks its archived identity.

Archiving is observational and must never change a business result.
It may not raise, exit, block the loop, or alter control flow, for any payload shape or storage backend state.

Every item consumes a per-stream `seq` in the adapter before sealing. That makes only a drop between two landed items reportable.
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

Test archival through the owning seam and inspect captured or stored events. Cover dispatch identity, settlement, and archive failure isolation.
Do not infer archival coverage from source strings or AST call placement.

## Platform telemetry

Telemetry holds aggregate facts with no content. It does not replace the archive, and a metric never carries archive content.
Follow [`apps/systems_observability/GUIDE.md`](apps/systems_observability/GUIDE.md) and the shared bounds in [`../docs/observability.md`](../docs/observability.md).

Metric labels and trace attributes must be finite and normalized.
Never include tenant, org, user, agent, session, request, trace, or VM identifiers. Never include raw paths, URLs, queries, commands,
prompts, completions, tool arguments or results, secrets, or exception text.
Keep `workload`, `component`, and `surface` as independent facts.
