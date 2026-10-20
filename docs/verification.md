# Verification

IFC is one domain, not the name of the whole verification surface.
The [kernel README](../systems/native/verified_kernel/README.md) lists the proof sources, commands, and query surfaces.

## Session reduction

The Session proofs cover append-only journal transitions and preservation for terminal, blocked-acknowledgment, and stale-compaction cases under their stated hypotheses.
See the [Session proof sources](../systems/native/verified_kernel/proofs/VerifiedKernelProofs/Session/).
S3 commits, codecs, and scheduling are outside these proofs. Keep their boundary regressions.

### Accepted work and durable confirmation

Accepted work means a durably accepted Session input, not a completed Task or a delivered reply.
Its identity and payload must stay queued, represented by a Session record, or retained in sealed storage.
A queue ACK confirms materialization. It does not discharge a business or reply obligation.
The proof does not use the dedupe ledger as a substitute for the work.

Delivery admits input records, birth metadata, `context` facts, and supported workspace operations.
Owner controls and unknown types fail closed before effects. `inputIdentitiesDistinct` checks every batch identity writer.
The host repairs Session input UTF-8 before admission. The proof input is this canonical value.
Rejection returns `invalid_delivery_events` without reserving the source ID.
Full refinement is open in [#1799](https://github.com/AFK-surf/Comma/issues/1799).

Archive proofs connect published catalog entries, pending writes, and fenced CAS to physical input facts.
Semantic codecs ignore map order but keep field presence, list order, and scalar values.
Model snapshots and notification lists are proof-only projections, not runtime state or gates.
The theorem does not authorize arbitrary raw `queue_ack` or `queue_consume` events.

The domain starts with empty modern storage. Legacy and import initial states need another proof.
The owner set the proof boundary at Lean. External code is assumed, not modeled.
This includes Elixir and Erlang, standard libraries, C, BEAM and FFI, codecs, and storage.
Explicit hypotheses cover arguments, resource identity, request and response association, storage facts, and public reports.
The result is conditional. Product guarantees and independent boundary tests stay unchanged.
See the [complete boundary](../systems/native/verified_kernel/README.md#lean-only-refinement) for assumptions and exclusions.

These theorems do not claim provider-call rollback, exactly-once external effects, scheduling progress, or user-task completion.
Run the kernel axiom audit, native tests, Session regressions, and retained TLA+ suite.

## AgentLoop control

See [agent loop proofs](../systems/native/verified_kernel/README.md#agent-loop-proofs).

## Shared executable kernel boundary

The generic request is `{1, domain, 1, operation, payload}` through C `invoke_etf/1`.
Responses are `{1, :ok, result}` or `{1, :error, domain, binary_code}`.
The kernel is the only Session implementation. It owns immutable Session values and their decision rules.
The host holds an opaque handle (`SalixAgent.InternalSession`) and cannot mutate its fields. Host-only facts arrive as arguments.
The Actor and storage CAS select the current committed revision.
State crosses as data only at `load`, `persist`, `open`, and `export`.
`open_envelope` takes only the named fields of a tool or runtime context.

Lean owns presentation, compaction decisions, settlement, restart planning, wait timeouts, and activation retry deadlines.
Lean owns provider request projection, attachment provenance, and the Anthropic Messages, OpenAI Chat, and Responses encoding, parsing, SSE state, and retry decisions.
The host owns timer delivery, process observations, external authority, durable commits, image reads, stored-result reads, credentials, and network I/O.
Site-proxy chat translation and media APIs are outside the agent-loop provider domain.
Query results do not prove that a commit succeeded. Draft retirement follows the committed result.

Except for the retry, materialization, command-confirmation, and loop properties, these definitions lack functional correctness proofs.
Lean checks termination of pure definitions. This proves no execution-time bound, termination of external calls, or Actor retry progress.
Most queries are not proved. An opaque handle alone does not establish a narrow semantic boundary.
NIF and local HTTP regressions cover partial JSON, Unicode splits, rejection, protocol replay, and stack safety.

The wire accepts pure ETF data and the exact supported State and MapSet envelopes.
Reject arbitrary structs, PIDs, references, functions, and compressed ETF. Do not add a custom protocol fallback.
Host decoding, schema admission, C ownership, compilation, and transport are trusted or tested boundaries.

## IFC authorization contract

A tool request needs a consumed command from the same authority.
Data, forwarded text, and untrusted pages do not authorize a request.
Unknown authority is not permission.

Source admission distinguishes ordinary flow, in-place use, receipts, and instructions.
Ordinary flow requires `readersSubset(destination, source) = yes`.
Non-flow admission needs the policy's readable, unsealed source facts.
An explicit empty source list is empty. A context source selects the declared context.
The model does not track accumulated model knowledge as an implicit label set.
Resolve tenant, destination, membership, source, and request facts at their host boundary.

Internal Task reports resolve placement for the Task's human readers, not only the assigned agent.
Stored placement facts and authenticated ingress placement take precedence over provider fallback.
For missing Slack Task-reader facts, read at most 20 named users per connection per resolution.
Cache positive and unknown results for one minute in 4,096 node-local slots, scoped to the installation generation.
Expired entries do not authorize a transfer. Provider failures, disabled installations, and readers past the limit stay unknown.
This does not give general command authority to an agent-authored Task message.
[Task ownership](architecture/DOMAIN_CONCEPTS.md#loop-tasks) grants only the listed Task effects. IFC still checks sources and destinations.

Receipt expiration is checked at authorization time.
Lean claims sequential receipts atomically at each claim boundary. If a later claim fails, earlier receipts can stay spent without dispatch.
This is not exactly-once delivery or unconditional liveness.

Low-observable payload noninterference applies only when the declared data dependencies are honest.
A proof does not establish that an LLM declared every dependency it used.
Public Slack channels have a company-wide audience, including relevant guest access.
BFT dashboard project members and Task Share readers are outside the current IFC model.
Do not infer deployed `off`, `audit`, or `enforce` mode from these documents.

## IFC proof scope

The `ifc` help topic describes the existing policy. It is not another authorization engine.
A denial points to that topic through `help_tool` and `help_params`, unless the activation has no authenticated requester.

Resolution reports all unknown refs. Public-egress checks report all non-public sources. Admission reports all restricted sources.
Each stage must pass before the next runs. Request and writer failures keep an empty source-failure list.
The top-level clause and ref identify the first failure.

Before a retry, the agent must remove restricted information from its answer and declare only the sources the revised answer uses.
Removing refs alone does not authorize the original content. User-facing source names stay subject to the requester's read permission.

Do not accept `sorryAx` or native-evaluation shortcuts as proof evidence.

## What runtime tests still protect

Keep codec compatibility, malformed-wire rejection, C/ETF ownership, facade dispatch, resolver facts, and host authorization integration tests.
Keep runtime lattice, fact-change, and compaction properties.
Abstract label laws do not prove that a host transformation preserves those facts.
A redundant test needs an executable proof of its property and input domain, not a similarly named theorem.
Do not replace runtime failure, concurrency, or provider tests with pure reduction proofs.
