# Verification

Verification spans executable Lean kernels, retained TLA+ system protocols, and runtime boundary tests.
IFC is one domain, not the name of the whole verification surface.

## Session reduction

The Session kernel owns event reduction and activity bookkeeping.
Its proofs address append-only journal transitions and preservation for terminal,
blocked-acknowledgment, and stale-compaction cases under their stated hypotheses.
See the [Session proof sources](../systems/native/verified_kernel/proofs/VerifiedKernelProofs/Session/).
S3 commits, codecs, and scheduling remain outside these proofs. Keep their boundary regressions.

### Accepted work and durable confirmation

Accepted work means a durably accepted Session input, not a completed Task or a delivered reply.
Its identity and payload must remain queued, represented by a Session record, or retained in sealed storage.
A queue ACK confirms materialization. It does not discharge a business or reply obligation.
The proof does not use the dedupe ledger as a substitute for the work itself.

Delivery admits input records, birth metadata, `context` facts, and supported workspace operations.
Owner controls and unknown types fail closed before effects. `inputIdentitiesDistinct` checks every batch identity writer.
Distinct embedded appends remain supported.
`InputAdmission` proves rejection before effects. `WorkOwner` derives Agent ownership preservation from actual input and resident execution.
`WorkOwnerStorage` extends ownership preservation through write preparation, persistable projection, semantic codecs, and actual load/resume.
Actor/store regressions cover identity replacement, ownership corruption, and UTF-8 collisions, including nested MapSet/tuple data.
The host repairs Session input before synchronous and prepared admission. The proof input is this canonical value, not invalid pre-repair bytes.
Rejection returns `invalid_delivery_events` without reserving the source ID. Fake-S3 regressions check stored work and corrected retry.
PR #1734 covers fixes and local proofs. The owner deferred full refinement to [#1799](https://github.com/AFK-surf/Comma/issues/1799).
Product guarantees remain unchanged.

Executable proofs and transaction-model scopes:

| Source | Checked property |
| --- | --- |
| `Session/WorkConservation.lean` | The executable planner derives ACK/consume coverage and connects each retired item to its generated query-result event. |
| `Session/WorkRefinement.lean` | Each planned retirement has a final applied record with matching identity and content. |
| `Session/WorkFrames.lean` | Both compaction reducers and archive advancement preserve the complete pending queue, including its payloads. |
| `Session/WorkRetirement.lean` | Actual ACK and consume reducers produce exact ID filters over their normalized input queue. |
| `Session/WorkCommandTrace.lean` | New and duplicate input confirmations require a successful fence. New-input traces bind it to the same write batch. |
| `Session/WorkProtocol.lean` | `accepted_work_conserved` proves durable representation through every finite transaction-model trace, including failures and restart. |

`confirmation_has_durable_fact` connects the model's confirmation candidates to its committed snapshot.
Negative examples reject unfenced acceptance and acceptance without represented work.
Activation commit failure also returns an error and its checkpoint instead of a draft-retirement effect.
Notification-monitor failure does not undo a successful commit.

Model snapshots and notification lists are proof-only projections, not runtime state or gates.
Materialization uses the executable planner and encoder as transition premises, not an assumed conservation conclusion.
The planner theorem requires canonical queue items with strictly increasing queue IDs.
`WorkApplication`, `WorkPayload`, and `WorkRuntimePayload` prove record insertion and identity/content retention, including runtime content-or-summary fallback.
`WorkCommitMetadata` preserves work and ownership through commit bookkeeping.
`WorkBatch` excludes archive removal and legacy transcript rewriting from materialization.

Materialization follows actual projection and resident run/resume, without assuming `AppliedBatch`.
Every generated event executes. Records retain the complete canonical `accepted_input`, not only identity/content fields.
Normalization retains complete items and derives ACK/consume membership from the original queue.
Actual load/resume preserves decoded queue/record work. Constructors establish queue invariants and format 3; reducers preserve them.
Identity proofs establish runtime non-collision and bind checks to reads. Ledger proofs cover all identity writers and input projection.
`WorkInputAdmissionActual` derives freshness and proves resident execution retains old work and creates the binary-source input.
`WorkNativeCandidate` connects native writes to durable input facts. `WorkReadInput` adds local read/revision/CAS binding, not global lineage.
`WorkAllocation` and `WorkReady` preserve canonical queue items, unique IDs, allocator/ACK bounds, and earlier work, including retry marking.
`WorkCompaction` preserves original queue and record fields under modern read-side redaction.
`WorkRepresentation` connects actual archive-prefix removal to the exact records that storage must seal.
`WorkHistoryReachability` derives sequence order through creation, reducers, preparation, and persist/load. Reload preserves integer history stamps.
`WorkArchiveProjection` covers live and removed messages in archive windows.
Record proofs derive valid unique writer keys and retain record shape and archive input facts through codecs.
Archive proofs connect every published catalog entry to stored objects, then connect pending writes and fenced CAS to physical input facts.
Semantic codecs ignore map order but retain field presence, list order, and scalar values. Persist/load preserves work under this contract.
`Recorded.input_fact` exposes the complete input tuple through semantic codecs, including payload metadata.
The theorem does not authorize arbitrary raw `queue_ack` or `queue_consume` events.

`WorkDriverConfirmation` composes public-response loops through CAS, notification, and return.
`WorkLeanBoundary.NativeProductRun.refinement` composes input conservation, historical fact preservation, and confirmation safety over one permitted finite Lean history.
The domain starts with empty modern storage. Legacy/import initial states need another proof.
Ordinary batches require their event-kind contract; specialized activation requires empty leading events.
Its `WorkProtocol` embedding encodes fact safety, not physical queue locations or verified external invocation counts.
See the [complete boundary](../systems/native/verified_kernel/README.md#lean-only-refinement) for correspondence assumptions and exclusions.
Reload must restore the committed snapshot.
The owner set the proof boundary at Lean. External code is assumed, not inspected or modeled.
This includes Elixir/Erlang, standard libraries, C, BEAM/FFI, codecs, and storage.
Explicit hypotheses cover arguments, resource identity, request/response association, storage facts, prerequisite domains, and public reports.
Lean validation and transitions remain proof obligations. Assumptions cannot replace the two product conclusions.
The result is conditional, not external implementation verification. Product guarantees and independent boundary tests remain unchanged.

Speculative provider requests may precede persistence. Their output gates remain host responsibilities.
These theorems do not claim provider-call rollback, exactly-once external effects, scheduling progress, or successful user-task completion.
The retained `RpcDeliver`, `SessionEpochFence`, `SessionHotArchive`, and `ArchiveAppend` mappings remain unchanged.
Run the existing kernel axiom audit, native tests, Session regressions, and retained TLA+ suite.

## AgentLoop control

`loop_step` runs the agent loop. The host decides no branch.
`Round`, `Dependency`, and `Policy` proofs cover finite traces, at-most-once commands, dependency admission, policy precedence, retry budgets, and terminal ownership.
`Loop` proofs: a `loop_step` commit clears a reply obligation only for a named reason and keeps accepted work.
Non-speculative dispatch follows a durable record. Only a failed speculative fence repeats an `aid`.
Wait extensions are bounded. Activation chains are linear in outside writes.
They assume truthful commit observations, matching host answers, and faithful reference encoding.
They do not prove storage commits, BEAM identity allocation, idempotent effects, or progress.
The [kernel README](../systems/native/verified_kernel/README.md#agent-loop-proofs) lists proofs and findings.
Keep Actor tests of timeouts, crashes, retries, and terminal ownership.

## Shared executable kernel boundary

One static Lean NIF implements Session reduction, IFC authorization, and AgentLoop control.
The boundary covers 39 Session event reductions and seven AgentLoop controls and the loop.
The generic request is `{1, domain, 1, operation, payload}` through C `invoke_etf/1`.
Responses are `{1, :ok, result}` or `{1, :error, domain, binary_code}`.
The kernel owns immutable Session values and their decision rules.
The Actor and storage CAS select the current committed revision. Multiple handles can retain different revisions.
`session/2` passes state by reference. The host holds an opaque handle (`SalixAgent.InternalSession`) and cannot mutate its fields directly.
Existing field queries still return data to host consumers. An opaque handle alone does not establish a narrow semantic boundary.
Lifecycle operations (`new`, `load`, `normalize`, `prepare_write`, `fork`, `persist`) and the catalog projections run as kernel operations.
The kernel README lists the command and query surfaces. Consumer projections still return ordinary data for external adapters.
The state crosses as data only at the storage boundary (`load`, `persist`) and at `open` and `export`, which serve tests, imports, and one-off tools.
`open_envelope` admits a caller-assembled tool or runtime context. It takes only the state's named fields, so other runtime identities never reach the kernel.
Most queries are not proved. The materialization coverage proofs above are an exception.
The kernel is the only Session implementation. Host-only facts (canonical Router, busy delegates) arrive as arguments.

Session commands own input acceptance, reply activation, and legacy recovery across external requests.
The native driver retains the revision and continuation through writes and CAS, using external observations.
Lean owns authorization reuse, identity selection, event construction, and post-commit draft retirement.
Presentation operations also own diagnostic redaction, scheduled fallback selection, repair event batches, and tool-continuation policy.
Compaction decisions, snapshot admission, and archive-window projection are kernel queries.
Settlement queries select terminal acknowledgments, onboarding completion, guidance budgets, and idle transitions.
Restart planning uses a closed request and observation protocol for capability ownership, staged results, and tool-specific result encoding.
Lean also selects wait timeout events, activation retry deadlines, and compaction failure recovery batches.
The host owns timer delivery, live process observations, external authority, and durable commits.
Provider request projection executes in Lean. Later reads preserve earlier reader pages. Source annotations apply only to labelled inputs without changing stored records.
Resident Session dispatch encodes the final provider JSON without a host message-list round trip.
Lean owns attachment provenance, activation watermarks, and runtime-page envelope sizing.
The host retains external authority resolution, tool-result publication sizing, image reads and preprocessing, stored-result reads, and network I/O.
The provider domain owns agent-loop request encoding, response parsing, usage normalization, SSE state, error classification, and explicit stream retry decisions.
Shared `LLM.Error` constructors use that same classifier. Elixir formats arbitrary exception objects before the kernel boundary.
Anthropic Messages, OpenAI Chat, and Responses use the same host HTTP path. Stream state remains resident and returns only callback data.
The executable retry function proves no transport retry after successful stream data and no retry after the attempt budget ends.
Network observations, callback delivery, credential lookup, request timing, and dependency cancellation remain host assumptions.
Partial JSON, Unicode chunk splits, rejection, and protocol replay have NIF and local HTTP regressions. No protocol or native-stack bound is proved. NIF tests cover stack regressions.
Site-proxy chat translation and media APIs are separate paths outside the agent-loop provider domain.
Request projection tests cover the NIF boundary, ordering, redaction, source-reference stability, and bounded obligation rendering. They are not correctness proofs.
Boundary tests cover decisions, event batches, Unicode encoding, and failed or stale observations.
Host integration tests cover commits, retries, external authority, and presentation effects.
The host supplies configuration, time, entropy, and provider-specific views. External exception values become bounded diagnostic text, not Session structs.
Query results do not establish that a commit succeeded. Activation and legacy-recovery draft retirement follow the committed result.
Ordinary output preparation retains its existing pre-commit transient draft cleanup.
AgentLoop receives independent observations. Its continuation function owns their precedence.
These operations use the existing storage format, durable identities, and commit protocol.
Lean checks termination of pure command, presentation, settlement, restart, request, and provider definitions. The axiom audit includes their executable dispatch functions.
Except for the stated retry, materialization, command-confirmation, and loop properties, these definitions lack functional correctness proofs.
This does not prove a fixed execution-time bound, termination of external calls, or progress of the Actor's retry loop.

The wire accepts pure ETF data and the exact supported State and MapSet envelopes.
Reject arbitrary structs, PIDs, references, functions, and compressed ETF.
Do not add a custom protocol fallback.
Host decoding, schema admission, C ownership, compilation, and transport remain trusted or tested boundaries.

## IFC authorization contract

A tool request needs a consumed command from the same authority.
Data, forwarded text, and untrusted pages do not authorize a request.
Unknown authority is not affirmative permission.

Source admission distinguishes ordinary flow, in-place use, receipts, and instructions.
Ordinary flow requires `readersSubset(destination, source) = yes`.
Non-flow admission needs the policy's readable, unsealed source facts.
An explicit empty source list is empty. A context source selects the declared context.
The model does not track accumulated model knowledge as an implicit label set.
Resolve tenant, destination, membership, source, and current request facts at their host boundary.
Internal Task reports resolve placement for the Task's human readers, not only the assigned agent.
Stored placement facts and authenticated ingress placement take precedence over provider fallback.
For missing Slack Task-reader facts, read at most 20 named users per connection per resolution.
Cache positive and unknown observations for one minute in 4,096 node-local slots, scoped to the installation generation.
Cache collisions can cause extra reads. Expired entries do not authorize a transfer.
Provider failures, disabled installations, and readers beyond the lookup limit remain unknown.
This does not grant general command authority to an agent-authored Task message.

Receipt expiration is checked at authorization time.
The Lean continuation claims sequential receipts atomically at each claim boundary.
If a later claim fails, earlier receipts can remain spent without dispatch.
This is not an exactly-once external delivery or unconditional liveness guarantee.

The declared data dependencies must be honest for low-observable payload noninterference to apply.
A model proof does not establish that an LLM declared every dependency it used.
Public Slack channels have a company-wide audience, including relevant guest access.
BFT dashboard project members and Task Share readers are outside the current IFC model.
Do not infer deployed `off`, `audit`, or `enforce` mode from these documents.

## IFC proof scope

- `FullRefinement.decide_allow_sound` connects executable allow results to request, source, and evidence authorization.
- `decideChecked_sound` includes checked wire admission.
- `SemanticRefinement.decideChecked_system` connects the implementation to independent system semantics.
- CheckedExecution covers low-observable payload behavior under its declared-dependency assumptions.

The policy uses the shared Std-only `Model.lean` and embedded help through `@external_resource`.
The `ifc` help topic describes an existing capability. It is not another authorization engine.
A denial result points back at that topic through `help_tool` and `help_params`, except when the activation has no authenticated requester and no declaration can help.

Source rejections include ordered `source_failures`, with a ref, clause, and detail for each failed source.
Source resolution reports all unknown refs. Public-egress checks report all non-public sources. Source admission reports all restricted sources.
Each stage must pass before the next stage runs. Request and writer failures retain an empty source-failure list.

The top-level clause and ref identify the first failure. The guidance result includes the complete list and atom kinds for each source.

The agent must remove restricted information from its answer before retrying and declare only the sources the revised answer uses.
Removing refs alone does not authorize the original content. User-facing source names remain subject to the requester's read permission.
`FullRefinement.collectSources_ok` proves that collecting source failures preserves the previous successful admission results.

The kernel `check.sh` validates the Linux or macOS static link and audits axioms.
Do not admit `sorryAx` or native-evaluation shortcuts as proof evidence.
Sources and `check.sh`: [`systems/native/verified_kernel`](../systems/native/verified_kernel/).
Do not restore retired document copies as a second proof specification.

## What runtime tests still protect

Keep codec compatibility, malformed-wire rejection, C/ETF ownership, facade dispatch, resolver facts, and host authorization integration tests.
Keep runtime lattice, fact-change, and compaction properties.
Abstract label laws do not prove that a host transformation preserves those facts.

A redundant test requires an executable proof of its property and input domain, not a similarly named abstract theorem.
Do not replace runtime failure, concurrency, or provider tests with pure reduction proofs.

## TLA+ scope

The authoritative retained roster and commands are in [tla/README.md](../tla/README.md).
All `.tla` and `.cfg` files together must fit within 5,000 physical lines, including comments and blank lines.
Keep system ownership, fencing, accepted-work preservation, authorization, and financial integrity.
Feature behavior belongs in implementation regressions.

```sh
make tla
```

Expected counterexamples must remain violating.
Passing TLC proves the bounded abstraction under its fault and fairness assumptions.
It does not prove runtime conformance, deployment status, or end-to-end behavior.
Retired feature models and their historical passing runs are not current machine-checked evidence.
