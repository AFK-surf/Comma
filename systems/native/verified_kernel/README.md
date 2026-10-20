# Lean verified kernel

This package owns the Session event reducers, their activity bookkeeping, IFC authorization, and AgentLoop control decisions.
Elixir calls Lean through one ETF NIF. Elixir executes processes, effects, and the Actor loop.

## Source layout

`runtime/VerifiedKernel/` contains executable Lean modules. `runtime/VerifiedKernel.lean` imports the NIF dispatch entry point.
`proofs/VerifiedKernelProofs/` contains theorems, specification models, and proof-only traces and ghost state.
`lakefile.toml` selects every module under `runtime/` and `proofs/` with Lake globs. There is no aggregate import list to update.
Both trees keep the `VerifiedKernel` declaration namespaces. Proof module imports use the `VerifiedKernelProofs` prefix.
Proofs import runtime modules. Runtime modules do not import proofs.
`SalixAgent.IFC.Help` embeds `proofs/VerifiedKernelProofs/IFC/Model.lean` as tool documentation during Elixir compilation.
Elixir does not execute this specification model.

`lake build VerifiedKernel.Native` builds the runtime entry point. The NIF links only its executable import closure.
`lake build` builds every runtime and proof module. `scripts/check.sh` also runs the axiom audit, native tests, and shared-library checks.

`scripts/audit-axioms.lean` is the axiom audit. It imports every module from the `runtime/` and `proofs/` source trees.
It checks the transitive axioms of every declaration in those modules, including private and generated declarations.
A declaration passes only if it uses no axioms other than `propext`, `Classical.choice`, and `Quot.sound`.
Thus the audit rejects `sorry` and `admit` (`sorryAx`), the auxiliary axiom that `native_decide` adds, and each `axiom` declaration.
The audit does not replay declarations through the kernel. It does not check `@[extern]` or `@[implemented_by]` code against the Lean definitions.

CI runs `scripts/check-proofs.sh` for the complete proof target and axiom audit.
A push to `main` always runs it. A pull request runs it when its diff touches the kernel, the toolchain setup action, or the Systems CI workflow.
A build cache hit never skips the proof target or the axiom audit.

### AgentLoop domain

The `agent_loop` domain has eight stateless operations: `activation`, `call_envelope`, `dependency_step`,
`retry_admission`, `retry_failure`, `terminal_owner`, `terminal_reply_admission`, and `completion_wake`.
`call_envelope` decodes the model's `call` envelope into one operation, its params, the IFC declaration,
and the reply intent, or returns the guidance for a malformed envelope.
`terminal_reply_admission` admits one tool call against the scope from the `terminal_reply_context`
query. `completion_wake` decides whether a settling background result wakes the session, continues it,
or permits a speculative model call. It holds the notification's wake while a sibling settlement in the
same Actor is due. Direct-poll completions never activate. It rewrites the event before the
`queue_append` reducer. These two have runtime tests, not proofs.
The other payloads contain phase atoms, booleans, nonnegative attempt counts, and binary or nil owner identities.
Retry admission also accepts the actor's explicit `invalid` owner status and ignores that retry.
Dependency identities are binary ETF encodings of BEAM references, not nested terms that Lean decodes.
The adapter accepts references only at this named boundary and keeps the actual reference in the actor.

### Agent loop

The session query `loop_step` (`runtime/VerifiedKernel/Session/Loop.lean`) is the agent loop:
`(session, machine, event) -> (machine', [effect])`. The host runs effects and returns the next event.
The host does not select a branch.

| Events | Effects |
| --- | --- |
| `model_response`, `model_failure`, `guard_notice`, `commit_results`, `activate`, `wait_timeout` | `commit`, `build_record`, `run_tools`, `store_results`, `commit_planned_results` |
| `record`, `tools_done`, `results_stored`, `fact`, `continue` | `fact`, `write`, `materialize`, `set_timer`, `cancel_timer`, `notify`, `stop` |

A step is one transaction. It emits at most one `commit`, and only `notify` effects come before it.
The host runs the step as the commit builder. A storage conflict re-runs the step on the fresh session.
When the fresh session takes a different branch, the host continues with that step's effects.
A record carries the message id it was built at. The kernel requests a new record if the session moved.

The loop owns stale-response steering, model failure and context-overflow recovery, final output,
`end_turn` classification, tool turns, result settlement, continuation, guard parking, and the runtime
failure notice. It also owns the activation decision: the Router check, the provider-wait yield, the
wait extension, and the wait and retry timers. The tool turn advances the proven `AgentLoop.Round`
machine, so the intent commits before tools run and results commit before the round continues.
The host keeps provider formatting, tool contexts, tool execution, the workspace commit, and the
result projection.
The host supplies facts it alone observes: the canonical Router session, busy delegates, and the
completion owners of the Actor's in-flight background calls.
The Conversation owner chooses delivery targets and `no_wake`.
Lean owns identity comparison, event admission, and command selection. There is no general opaque-object transport.
An event out of order fails the step with `loop_order`. A tool turn that the proven round machine rejects fails with `round_order`.
The loop commits some events that the host builds: tool-turn intent and admission events, final-output
leading and assistant events, and tool-result events. If one of these events is not a map, or has the
type `queue_ack`, `queue_consume`, `archive_advance`, or `session_stamp`, the step fails with
`invalid_host_event`. The check reads each map key that converts to `type`.

The runtime `AgentLoop.Round`, `AgentLoop.Dependency`, and `AgentLoop.Policy` modules contain executable functions.
Their matching proof modules contain the theorems and trace models.
The dispatch proof module proves terminal owner equality and accepted-pair uniqueness.
The AgentLoop proofs cover arbitrary finite traces, phase-qualified commits, at-most-once commands and dependency admission, policy precedence, and retry budgets.
These claims assume truthful commit observations and faithful reference encoding.
They do not prove storage commits, BEAM identity allocation, external-effect idempotency, or scheduling progress.

### Agent loop proofs

`proofs/VerifiedKernelProofs/Loop/` proves properties of `loop_step` itself, not only of the abstract `Round` machine.
`Loop.stepWith` takes the query oracle as a parameter, and `Loop.step` is `stepWith queryAsk`.
`Source.lean` lists every place where the loop emits a commit, a `run_tools` dispatch, or an activation `write`.
`Shape.lean` proves `step_shape` for any oracle: notifications, at most one commit, then exactly one blocking effect.
It also proves that each commit, dispatch, and write comes from a listed source (`step_commit_source`, `step_dispatch_source`, `step_write_source`).

| Property | Main theorems | Result |
| --- | --- | --- |
| A. No false completion | `DischargeFrame.project_discharge_source`, `Discharge.loop_chain_discharge_justified`, `failed_send_keeps_turn_open` | Only `ack` and `provider_reply_obligation_resolved` events move the ACK or remove an obligation. Each such event in a loop commit has a named `Justified` reason. `Settlement.terminal` settles nothing for a non-terminal send result. The reasons listed below can still settle. |
| B. Recorded, non-duplicated dispatch | `Dispatch.dispatch_after_durable_intent`, `notice_after_durable_record`, `speculative_dispatch`, `dispatch_at_most_once`, `round_refines`, `dispatch_once_per_round` | Over the host model in `Host.lean`, each non-speculative dispatch follows a durable commit of its record, and dispatch is at most once for each `aid`. The only exception is a speculative dispatch whose durable fence failed. |
| C. Bounded work | `WaitBudget.wait_extension_budget`, `ActivationChain.activation_chain_bounded`, `RequestBound.requests_le_grants`, `TerminalTail.local_settlement_stops_continuation`, `TerminalTail.failureAck_final`, `RoundBudget.failureAck_keeps_rounds`, `RequestBound.requests_not_bounded` | Wait extensions stay within the ceiling. An activation chain is linear in outside writes. On the host model, each model request needs a granted activation, so requests do not exceed grants. A local settlement or a runaway retirement stops continuation unless a Task card fences its ACK. A retryable failure does not ACK a source that no failure notice reached. The loop's failure ACK keeps the stored round count. The bound on model requests for each credit is false on the host model, because the model leaves some host answers free. `Budget.lean` lists the host contracts that a proof needs. |
| D. Accepted work | `HostEvents.host_events_raw_ordinary`, `WorkEmbedding.loop_commit_ordinary`, `loop_write_ordinary`, `activation_write_staged`, `loop_commit_run` | Every loop commit and yield write is a `RawOrdinaryBatch`. A loop commit extends a `NativeProductRun`, so `NativeProductRun.refinement` applies. |

These theorems are conditional. Their hypotheses state these external assumptions:

- The host applies a commit to the state that the step read, and runs later effects only after the commit succeeds (H1).
- The host returns the loop machine unchanged (`LoopChain`). The wait-timeout commit uses the event that the machine carries.
- Host answers match their requests (H2). A built record has an integer `base ≤ aid` and carries the assistant event for its calls.
- The kernel does not check an `ack` or an obligation resolution that the host builds in a record or in tool results. `Justified.host` names this trust.
- On the model-failure path, the ACK watermark `id_snapshot - 1` is the view of the model request (H3).
- The host dispatches speculatively only read-only calls (H4).

The host builds its answers with the `LoopHost` queries.
Production uses `loop_record` for `build_record` and `tool_batch_events` for `store_results`.
For `run_tools` it uses `notice_reply_scope`, `call_envelopes`, and `terminal_reply_admission`.
The session driver builds each round with `round_request`, which reads the round with `round_view`.
The standalone `systems/kernel_agent` uses the same queries.
The proofs still treat these answers as host data under H2 and `Justified.host`.
Runtime tests cover the queries. No theorem covers them.

Compaction has its own host queries (`Session.CompactionHost`).
The kernel decides when a session compacts, the window a request summarizes, the request, how the model answer reads, and the commit events.
Production and `systems/kernel_agent` use the same queries. The host projects its model configuration, runs the model call, and commits the events.
Runtime tests cover the queries. No theorem covers them.

Other host decisions are kernel queries too: crash repair (`Session.RepairHost`), the activation entry (`activation_plan`), write validation (`Session.WriteValidation`), and the activity revision of a fence (`Session.FenceStamp`).
A host answers each with I/O and the facts that it owns.
`session_step` (`Session.Drive`) sequences all of them and `loop_step` for one session, so a host only performs its effects.
The production session actor (`SalixAgent.InternalSessionActor`) and the standalone `systems/kernel_agent` both run on it.
The driver decides recovery, crash repair, the activation, the overlapped activation that starts the model call beside its fence, compaction, model rounds, and the failure of a model call.
The actor keeps a waiting driver with its model call or summary, and continues it when the dependency answers.
The restart, activation, command-driver, and revision-fence proofs do not call these queries, and treat their answers as host data.
Runtime tests cover the queries. No theorem covers them.

These reasons can clear a reply obligation or advance the ACK without a visible reply:

| Reason | Contract |
| --- | --- |
| Runaway retirement | `docs/agent-runtime.md` guards: a fenced commit abandons replies and ACKs its transcript. The retirement closes the turn (`terminal_reply_ack_hwm`). |
| Local disposition | `docs/agent-runtime.md`: failures without a safe notification path retire locally. The disposition closes the turn. |
| Model failure without a destination | `llmFailureAck`: only a final failure with no pending send ACKs. A retryable failure keeps the source for retries or one notice. |
| `end_turn` without a reply | `docs/tools-integrations.md#ownership-and-failure`: a plain reply target is advisory. Only Task cards fence the ACK. |
| Exhausted repair | The repair budget is bounded. The session records `visible_reply_repair_exhausted`. |
| Provider-wait yield | `docs/agent-runtime.md`: a Router wait yields to queued human input. |
| Onboarding after a failed send or an exhausted guard | Channel welcomes are optional. |
| Failure notice with an unknown outcome | No blind retry of an ambiguous send. |
| Host-built `finish_tool_batch` ACKs | The kernel query computes them. The host relays them (`Justified.host`). |

`runtime_failure_disposed` and `runtime_runaway_retired` set `terminal_reply_ack_hwm`, so the tool-result tail waits for new input or a new result.

`StoredObligations.kernel_session_blocking_agree` proves that `obligationBlocking` and `blockingObligationCount` agree on every `KernelSession` state.
Such a state is created, forked, or loaded from a snapshot without a binary-keyed obligation field, followed by any batch.
A snapshot persisted from a `KernelSession` state satisfies the load condition (`snapshot_absent`).
The `open` and `admit` entry points install a host map without normalization. Their state reaches the loop only after persist and load.

A speculative dispatch can repeat. If the durable fence of a speculative intent fails, its read-only calls already ran and `next_message_id` did not advance.
A later round can dispatch at the same `aid`. The calls are read-only, so the repeat is accepted.

The host model gates each model request on a granted activation. This narrows the host runs that A, B, and D quantify over, but their proofs do not use the gate.
Theorem names in this section are qualified by file, not by Lean namespace.
B covers the loop's `run_tools` effects and keys them by `aid`. A later model decision can send the same provider calls again under a new `aid`.
The host model counts the loop's planned-result commits and the lost-call commit of the session driver (`{:model_lost, facts}`) as environment writes. A does not cover the lost-call commit.
These proofs do not show that the Elixir host implements the model, that external effects run exactly once, or that the loop makes progress.

### Provider domain

`Provider.Dispatch` owns the agent-loop wire projection for Anthropic Messages, OpenAI Chat, and OpenAI Responses.
It encodes requests and headers, restores protocol history, places cache breakpoints, classifies errors, and normalizes usage.
`Provider.Stream` consumes network chunks and returns ordered callback data. Partial Responses arguments can arrive before a complete SSE line.
It preserves split Unicode characters, verifies the final prefix, and suppresses further fragments for a rejected partial tool event.
`Provider.Complete` reconstructs the final response and rejects malformed Responses tool arguments before any sibling call can execute.

The ETF NIF carries the provider domain. Its resident-value entry point keeps stream state without exporting it per chunk.
`new` starts one request-local stream, `feed` returns callback data, and `finish` returns the final result and trailing callbacks.
`raw` reads an error body for transport decompression. No provider state is persisted or added to the Session snapshot.
Stateless operations serve request, response, usage, and test projections through `invoke`.
Chat history assigns deterministic suffixes to repeated tool-call IDs only in the outbound copy.
It reserves original IDs, including later calls, and rewrites each invocation's tool-result and reasoning-detail references together. Signed payload bytes and stored history stay unchanged.
This projection also precedes vision annotations and missing-result repair.
Elixir keeps credential lookup, HTTP and compression I/O, callback execution, process cancellation, and timer execution.
It uses Req and the stream watchdog. It does not parse or reassemble agent-loop provider responses.

The `VerifiedKernelProofs.Provider.Dispatch` module proves two properties of the runtime retry function.
It allows no transport retry after successful stream data or after the attempt budget ends.
The axiom audit includes both proofs and the stateless and resident dispatch functions.

`VerifiedKernelProofs.Provider.RequestPrefix` proves request prefix stability for `Provider.Request.body`.
Let `H` be a closed history (`ClosedHistory`). It has a user or tool message, and its results match its calls (`Matched`).
Each tool result answers the newest waiting call with an equivalent id, and no call waits at the end.
`Matched.answeredEq` gives every call a later result with an equal id.
`Matched.of_distinct` shows that an answered history with distinct call ids is matched.
A request for `H ++ X`, for any `X`, has the same head as the request for `H` alone, and its messages start with the messages of that request.
The head is the system text and tools for Anthropic, the instructions and tools for Responses, and the tools for Chat.
Each projection decides a message from the earlier messages only, so a later message does not change an earlier one:
- Chat sends `reasoning_content` on each assistant message, with an empty string when the message has none.
- Every projection reads the role as `openaiRole`, so an atom role and a text role project the same.
- Responses marks a call with a provider-unsafe name, and each later output for its id, as a historical record (`historicalTools`).
- Chat gives a call whose provider id an earlier call uses the first free `id__n` suffix, and binds a result to the newest waiting call of its id (`uniqueChatCallIds`).
- Chat sends the images of tool results after the last result of their batch (`chatLoop_released`), not before the next message.
- Anthropic sends a runtime-authored message after the leading run as a mid-conversation `system` message, and a runtime message with external content (`untrusted`) as user text.
  The `[No new user message.]` turn precedes a `system` message that does not follow a user turn. The `[Noted.]` assistant turn precedes a user turn that follows a `system` message.
  Both depend only on earlier messages.
Anthropic messages are compared without cache markers, and one text block is equal to its text.
`Provider.Stateless` proves that the projection reads no host answer, so two runs agree on all journals.

`VerifiedKernelProofs.RequestPrefix.EndToEnd` connects this theorem to `Session.Request.dispatch`.
`consecutive_requests_share_prefix` compares a dispatch for state `s` with a later dispatch for state `s'`.
Both bodies start with the projection of one durable history `D`.
`D` is the stored prompt and the Session context of `s`, with attachments inlined.
The theorem has these conditions:
- The states agree on the compaction prefix, the live-window fields, and the stored prompt (`SameWindow`).
- The transcript of `s'` extends the transcript of `s` (`TranscriptExtends`). `TranscriptRuns.extends` gives this for completed `runTrusted` events other than `archive_advance`.
- Attachment inlining reads the messages of `s` the same way at the watermark of `s'` (`AckFrame`). An unchanged watermark is sufficient.
- The host gives the same answer to the same request in both dispatches (`HostAnswers`, `PrefetchSound`).
`D` must be a closed history (`ClosedHistory`).
The messages after `D` need no condition: the context that `s'` adds and the delta messages.
`VerifiedKernelProofs.RequestPrefix.Events` removes the state conditions for runs of events.
`runs_share_prefix` requires only that `s'` follows `s` by completed `runTrusted` events whose types are not in `prefixEventTypes`.
This closed list has five event types:
- `session_system_prompt` writes the stored prompt.
- `compaction` and `provider_compaction` write the compaction prefix and watermark.
- `ack` writes the watermark that attachment inlining reads.
- `archive_advance` removes a transcript prefix.
Every other reducer keeps the stored prompt, the compaction fields, and the acknowledgment watermark (`inner_prefix_kept`), and appends to the transcript.
`Keeps` proves that the request builder leaves an answered-ahead journal unchanged.
The theorem is about the body before UTF-8 scrubbing and JSON encoding. It does not cover the provider cache itself.
Other provider definitions have termination checks and runtime tests, not functional correctness proofs.
These proofs do not establish provider compliance, callback delivery, network progress, or a fixed runtime bound.
Site-proxy translation and media APIs are separate from this agent-loop boundary.

### Session archive domain

The resident `session_archive` domain has `start` and `resume` operations.
`ArchivePublication` captures the actual Session archive window, selects segments, validates landed records, and constructs the final advance event.
The cursor stays resident. Each storage call transfers only one segment, not the remaining window or earlier observations.
The host executes read, create-once, and codec requests. It commits the kernel's final event through the Session CAS path.
The cursor is a transient Session projection, not another owner or storage format.
`WorkArchivePublication`, `WorkArchiveObjects`, `WorkArchivePersistence`, and `WorkArchiveFence` connect capture, object creation and adoption, removal, metadata, native pending writes, and positive CAS to stored object facts.
These proofs assume explicit storage and codec primitive contracts.
The sealer reads one revision for publication and CAS. A conflict restarts publication from a new revision.
External command/prerequisite binding is an assumption.

### Session commit domain

The resident `session_commit` domain captures one candidate at `start` and emits its exact CAS request.
The continuation keeps that Session in the kernel until `resume`. It does not encode the snapshot again.
A positive CAS response returns the captured Session and committed ETag. An unresolved write fails closed.
The host compresses the bytes, executes the CAS, and returns its result to the continuation.
This transient Session projection adds no durable identity or storage format.

### Session batch domain

The resident `session_batch` domain captures an event list and applies it in order.
Each reducer must finish before the continuation advances to the next event.
Clock and configuration observations resume the captured reducer. They cannot replace the remaining events.
The host returns a Session handle only after the complete batch succeeds.
A telemetry failure cannot change the batch result.
`WorkBatchExecution.start_executes_batch` derives the resident batch relation from finite native execution.
Input commands fix missing or invalid lifecycle timestamps before they expose a write batch.
`WorkInputTimestamp.input_timestamp_batch_unchanged` proves that later timestamp preparation cannot change that batch, even with a different clock value.
UTF-8 repair precedes input admission at the host boundary.

### Pending revision domain

The resident `session_pending` domain owns the pending revision fields.
Each write keeps the baseline and ETag, appends its events, and applies the optional HWM update after that batch.
The `session_revision` domain holds snapshot absence, a committed Session/ETag pair, or the pending cursor.
The host Revision keeps read-only projections. Fence and rollback read the native cursor and its constructor.
The `session_read` continuation creates the hot-object key and keeps it through the storage response and load callbacks.
Keys use the lowercase SHA-256 Session-ID component from `SalixStore.Keys` and `SalixStore.Crypto`.
This hash is an address, not an authenticity check. The native reader owns key construction.
It checks the loaded owner and Session before it initializes the native Revision with the observed ETag.
The host supplies storage and codec results, clock values, and configuration observations.
Invalid Session IDs fail before storage I/O. Scope mismatches cannot return a Revision.
Even an empty write produces a pending cursor. Rollback restores the captured baseline and ETag.
A failed write returns no partial pending revision. Older handles stay valid.
The owner can pass a frozen continuation to its persistence task without changing its baseline or candidate.
`WorkPendingRevision.history_refines` derives the complete reducer history from finite native writes and proves baseline and ETag retention.

### Revision fence domain

The resident `session_fence` domain captures a pending revision and its baseline ETag.
It runs write preparation and fixed commit metadata events before it encodes the CAS candidate.
The host supplies metadata values, not replacement Session states or reducer events.
The captured owner and Session determine the snapshot address. A wrong host-supplied key could otherwise overwrite another Session's object.
Both the native fence and snapshot commit reject an address mismatch before they issue a CAS request.
`StorageAddress` owns this check and the key formula. The read continuation uses the same formula.
Successful CAS settlement returns the captured candidate and committed ETag in a native committed revision. Earlier phases cannot confirm a commit.
`Revision.confirmed_revision` binds that returned cursor to the exact encoded candidate, baseline ETag, and durable snapshot fact.
`WorkRevisionFence.input_durable` derives complete input facts and earlier-work preservation through these actual native phases.
The Store uses this path for versioned commits, including frozen pending revisions in persistence tasks.
Unversioned commits use their separate storage continuation.
The local command-result proofs below cover finite successful episodes.

### Command driver domain

The resident `session_command_driver` domain drives input, activation, log, and recovery commands from a native Revision.
The `conversation_input` command adds ordered Conversation source admission to the same driver.
It validates the source generation and position before ordinary input admission.
It adds the frontier event to the input batch before any write, including after workspace effects.
Scans and already admitted inputs advance the frontier without adding queued work.
`WorkConservation.conversation_input_atomic_frontier` proves this batch shape for every successful command evaluation.
`stage_conversation` keeps that same batch and returns `staged`, a working-state result without durable acknowledgment.
The owner continues activation on that revision and fences both before acknowledging source admission.
`WorkConservation.staged_frontier_write` proves that staging keeps the exact input/frontier batch.
The theorems cover command planning. Runtime tests cover CAS failure, lost replies, retries, and Session rotation.

The driver captures the actual command's events and continuation. Write validation cannot replace that batch.
It keeps the HWM and fixes missing lifecycle timestamps before write validation.
The host repairs command-argument UTF-8 before planning, including activation's leading events and system prompt.
The driver resumes a successful write only after its native batch completes.
It carries the fence continuation through the shared preparation, metadata, encoding, and CAS path.
A successful CAS returns a confirmed command cursor. Its `next` operation resumes the captured continuation against the committed candidate.
`WorkCommandDriver.input_confirmation_durable` connects the actual input batch and native CAS to that cursor, its complete input fact, and earlier-work preservation.
The host cannot supply a successful write or fence observation to this path.
A failed fence restores the captured baseline before the command returns its error.
A clean duplicate uses the native committed constructor and the owner and epoch checks without another CAS.
Authorization, entropy, workspace, notification, and draft cleanup are external observations, with request-specific result types.
A monitor failure does not undo a committed input.
Asynchronous activation passes its original native command cursor through the persistence task and resumes directly from the returned cursor.
Fresh revisions have no CAS base and cannot use the clean-confirmation path.
Creation claims the Session birth authority before work-index insertion. A creation conflict fails without replay against a different baseline.
Recovery keeps the observed revision through its captured write and CAS before draft cleanup.

The `Work*` modules under `proofs/VerifiedKernelProofs/Session/` compose these local results. The main ones:

- `WorkDriverConfirmation.InputCommitTrace.confirms_same_input` composes the finite native input stages through notification and the committed return.
  It derives the original command call, complete batch execution, and exact continuations instead of accepting independent application-stage premises.
  It requires a binary source, `QueueReady`, format 3, and the stated storage and codec primitives.
- `WorkPendingMaterialize` connects a materialization plan to the native pending write, its HWM update, and the snapshot CAS.
  `Revision.plan_preserves` covers every changed native plan for all four plan modes. `Revision.plan_unchanged_captured` proves that an unchanged plan returns the exact original revision.
- `WorkActivationReturn.ActivationCommitTrace.return_has_durable_work` connects activation's writes, CAS, cleanup callbacks, and public return, for both active activation and the inactive post-compaction path.
- `WorkNonRetiring` covers every modern native reducer except queue ACK, selective consume, and archive removal.
  Those three removals need the separate materialization and publication proofs.
- The identity modules (`WorkLedger*`, `WorkIdentity*`, `WorkFork*`, `WorkArchiveIdentity`, `WorkArchiveLineage`, `WorkPhysical*`) trace each ledger identity to an actual input writer, queue item, or archive record, and preserve that support through batches, materialization, normalization, codec changes, archive reduction, fork, and reload.
  Archive projection witnesses do not assert full equality between hot records and their normalized archive data.
- `WorkKernelHistory` and `WorkPhysicalHistory` derive queue, format, ledger, catalog, watermark, and history invariants from actual creation, fork, batch, materialization, archive, persistence, and reload calls.
- `WorkCurrentStorage` models one current object per key, not a set of all historical snapshots.
  Its atomic successful CAS requires the expected revision or confirmed absence and leaves other keys unchanged.
  Its read observation binds bytes and ETag to the same object. It does not prove application-level work preservation by itself.
- `WorkCurrentVersion` states the storage-token contract: at one key, the same token identifies the same bytes.
  Tokens may repeat for identical bytes. The proof does not require global token freshness or a monotone ETag counter.
  Under that contract, the successful CAS matches the bytes captured by the read, even with intervening writers.
- `WorkStorageAddress` binds the CAS address and base to the captured Session and revision. The host key is not a proof assumption.
- `WorkReadInput` derives its starting invariants and baseline ETag from the native read, and preserves all old physical work facts in the actual CAS snapshot.
- `WorkCurrentFence` and `WorkCurrentArchive` connect landed candidates and archive publications to the current object without a caller-reply premise.

These local theorems cover finite successful episodes. The aggregate below composes current snapshot lineage and permitted Lean command episodes.
External prerequisites follow explicit assumptions.

### Lean-only refinement

The proof boundary is Lean. External code is an assumption, not a source-verification target.
This includes Elixir/Erlang application code, standard libraries, C, BEAM/FFI, codecs, and storage.
Theorems state the external contracts they need as explicit hypotheses:
faithful call arguments, resource identity, response association, storage observations, and public confirmation reporting.
Lean state transitions and their work-preservation results are proof obligations, not external assumptions.
The proof does not inspect external source code or certify that external implementations satisfy these contracts.
It does not claim a complete Actor-to-product refinement. The open composition is [issue #1799](https://github.com/AFK-surf/Comma/issues/1799).

`WorkLeanBoundary.NativeProductRun.refinement` combines the two product safety properties over one finite storage history.
`InputOccurrence.conserved` connects each declared input to a Lean submission and landed CAS, then derives its generated record and current backing.
`ResidentReachable.conservation` preserves every physical fact from every earlier world, including inputs without acceptance labels.
`NativeProductRun.conditional_safety` derives backing for all declared acceptance and confirmation labels and composes their protocol simulation.
External contracts supply operation correspondence, not `ObserverBacked` or a work-preservation conclusion.

The domain starts with empty modern storage and uses the permitted `ResidentStep` constructors.
It includes creation, fork/clone, reads, admitted writes, the four plan modes, archive extension, restart, and committed cursors.
Landed input preservation does not require a CAS reply. Stale revisions are subject to the per-key token contract.
Arbitrary legacy, imported, or corrupt initial snapshots need an additional initialization proof.
Arbitrary overwrites, deletion, and writers outside this domain are not covered.
Ordinary writes require `RawOrdinaryBatch`. The specialized activation path requires empty leading events, not arbitrary injected batches.

The external history contract covers every relevant landed write, including lost replies, and preserves resource and request/response association.
Each declared input supplies its scope key, source, and payload as Lean receives them through `atomFirst`.
This is not a claim about raw request bytes before external processing.
`InputOccurrence` identifies a compatible edge of the world history, not a unique external invocation or invocation count.
The input-generation time and observation journals are existential Lean witnesses, not verified external clock or log values.
The report contract `reports = labels` preserves order and multiplicity by assumption. It does not prove external delivery or exactly-once execution.

`FactProtocol` maps registered facts into `WorkProtocol` as a coarse safety encoding.
Its acceptance and confirmation projections do not reproduce physical queue, materialization, or archive locations.
The declared input list has a conservation result over the same storage history, not an automatic insertion into the reported label sequence.
The theorems cover finite-prefix safety. They do not establish liveness, external-effect rollback, or successful user-task completion.

## Build and test

The NIF initializes the executable dispatcher, not the proof library.
`scripts/build.sh` and `mix compile` build the dispatcher and its executable dependencies, not the proof library.
`scripts/check.sh` builds all runtime and proof modules before the axiom audit and native checks.

Use Linux or macOS, the pinned Lean toolchain, OTP 29, and Elixir 1.20.
Install CMake 3.24+, a C/C++20 compiler, pkg-config, libuv headers, and OpenSSL development packages.
The first build downloads pinned Lean runtime and mimalloc sources.
It does not build the Lean compiler.

On macOS, install Xcode Command Line Tools and the native dependencies:

```sh
xcode-select --install
brew install cmake pkg-config libuv openssl@3 elixir
```

From this directory, install Lean and run the package checks on either platform:

```sh
bash scripts/install-toolchain.sh lean-toolchain
export PATH="${ELAN_HOME:-$HOME/.elan}/bin:$PATH"
bash scripts/check.sh
```

The checks compile the NIF, audit proofs, run ExUnit, and inspect native dependencies and exports.
Homebrew supplies the local macOS BEAM toolchain. Check that it meets the versions above.
CI pins OTP 29.0.2 and Elixir 1.20.1.

Use Docker for the Linux runtime-only check. It runs the NIF that
`scripts/check-runtime.sh` built on a Linux host, in an image without Lean:

```sh
bash scripts/check-runtime.sh
docker build -t verified-kernel-runtime -f test/runtime.Dockerfile .
docker run --rm verified-kernel-runtime
```

Load your shell profile first if it supplies toolchain paths.
For asdf installations, include the shims directory in `PATH`.
Run one package build at a time.

`mix compile` builds the NIF and links its `priv` directory into the application.
The production image, development container, and Systems CI install Lean at build time.

From the systems directory, run the Session regressions:

```sh
SALIX_TEST_DB=salix_lean_kernel_test mix test apps/salix_agent/test/session_kernel*_test.exs
```

`systems/kernel_agent` is an agent runtime whose only dependency is this application.
Its tests run the kernel without `salix_agent`. Its README lists the host logic that the kernel does not own yet.
The kernel CI job runs them.

## Activation latency reproduction

The synthetic fixture represents a large Router session: about 4,000 messages,
600 result references, and 16 MB of session state. It contains no staging content.

The opt-in tests assert a 500 ms activation budget. Use them to compare performance before and after a change. Default test runs exclude `activation_latency`.

Run the kernel-only reproduction from this directory:

```sh
mix test test/activation_latency_test.exs --include activation_latency
```

It reports materialization, projected event application, commit replay, normalization,
and snapshot encoding. This is a lower bound, not the complete actor activation.

The dense snapshot benchmark measures encoding cost on a snapshot with many nested
metadata maps. It reports encoding samples without a hardware-specific assertion.

```sh
mix test test/snapshot_encoding_test.exs --include activation_latency
```

Run the actual actor reproduction from `systems`:

```sh
export SALIX_TEST_DB_PORT=55471 COMMA_TEST_DB_PORT=55471 \
BILLING_TEST_DB_PORT=55471 BRIDGE_TEST_DB_PORT=55471 \
ALERT_ROUTER_TEST_DB_PORT=55471
MIX_ENV=test mix ecto.create --quiet
MIX_ENV=test mix ecto.migrate --quiet
mix test apps/salix_agent/test/activation_latency_test.exs --include activation_latency
```

Start a disposable local PostgreSQL server on that port first. Test setup resets test tables.
Do not point this command at a shared database. The actor test uses fake S3, IFC off,
and an immediate model response. It measures the runtime activation phase after admission
has loaded the resident revision. It excludes cold loading, admission, and model latency.
No cloud access is required. Host speed affects timings. A local pass does not establish
the staging latency budget.

## Round kernel profile

The round profile measures the kernel calls of complete Session rounds. Each input runs
one tool round and one final round through the actor. The report groups the calls by
kernel operation. It gives the call time, the isolated replay time, and the ETF sizes.
Use the isolated replay total to compare kernel CPU time.

Run it from `systems` with the database settings of the actor reproduction:

```sh
ROUND_KERNEL_PROFILE_MESSAGES=1000 ROUND_KERNEL_PROFILE_INPUTS=5 \
mix test apps/salix_agent/test/round_kernel_profile_test.exs --include activation_latency
```

The module documentation lists the CSV output and the hot-loop settings for a stack
sampler. Compare results from the same host only. Run the profile several times and
compare the medians.

## Interface

The NIF has two kernel functions. `SalixVerifiedKernel.Native.invoke_etf/1` takes and returns ETF binaries.
`SalixVerifiedKernel.Native.session/2` takes a resident Session state reference (or `nil`) and an ETF request, and returns `{reference | nil, response}`.
The shared request is `{1, domain, 1, operation, payload}`.
The response is `{1, :ok, result}` or `{1, :error, domain, binary_code}`.

The Session state is resident in the Lean heap. It crosses the boundary as data only in `open` (host to kernel) and `export` (kernel to host).
Every transition and every observation passes the state by reference.
References derived from one admitted state form a lineage that shares Lean objects. The NIF serializes calls and releases on one lineage with a lock, so the objects keep single-threaded reference counts.
Calls on different lineages run in parallel on the dirty schedulers.

```elixir
state = %SalixAgent.InternalSession.State{
  status: :active,
  activity_status: :thinking,
  async_tool_calls: %{"a" => %{"status" => "running"}}
}
event = %{"type" => "async_tool_call_progress", "tool_call_id" => "a"}
handle = SalixVerifiedKernel.Session.open(state)
{:observe_time, token} = SalixVerifiedKernel.Session.step(handle, event)
{:done, handle} = SalixVerifiedKernel.Session.step(token, {:observed_time, 123})
next = SalixVerifiedKernel.Session.export(handle)
```

`SalixVerifiedKernel.Session.step/2` also accepts a state map for one transition and returns the next state as data.
`SalixAgent.InternalSession.apply_events/2` steps every event by reference and returns the next handle. Nothing is exported.
A handle is immutable: each step returns a new handle, and an old handle stays valid.

Session wire operations are `:open` with the state, `:step` with `{event, prelude}`, `:resume` with `{token, {:ok, observation}}`,
`:lifecycle` and `:query` with `{name, args, prelude}`, `:get` with a field, `:new`, `:load`, `:persist`, and `:export`.
The prelude is the list of answered-ahead observations described under "Observations and continuation data".
The facade decodes with `[:safe, :used]` and checks full consumption.
Protocol atoms must exist in the facade before Lean returns them.
There is no dynamic module/function dispatch.

New domains add Lean dispatch cases and domain-specific data schemas.
They use the same C entry point, ETF codec, and runtime.
Do not add domain decisions, field access, or callbacks to C.

### Terminal emulator

`runtime/VerifiedKernel/Terminal.lean` is a VT100 emulator with common xterm extensions.
Outbound SSH sessions use it for `ssh.screen`. It is not a kernel domain.
`SalixVerifiedKernel.Terminal` wraps five NIF functions: `terminal_new/2`, `terminal_feed/2`, `terminal_resize/3`, `terminal_snapshot/1`, and `terminal_app_cursor/1`.
The terminal state is resident in the Lean heap, in a NIF resource with a lock.
`feed` runs on a dirty CPU scheduler and returns the replies owed to the remote side, such as a cursor position report.
`snapshot` returns an ETF map with binary keys `lines`, `cursor`, `title`, and `alternate_screen`.
The Lean module lists the supported sequences and its bounds.
A sequence or UTF-8 character split across `feed` calls stays in the parser state.
C holds only the resource and the calls. The emulator decisions stay in Lean.

`feed` has fast paths that skip the byte state machine `step`.
`proofs/VerifiedKernelProofs/Terminal/` proves that the fast paths are exact.
`feed_eq_foldl` states that `feed t bytes = bytes.data.foldl step t` for every state `t` that satisfies `Good`.
`Host.good` proves `Good` for every state that `exportNew`, `exportFeed`, and `exportResize` produce, so `host_feed_eq_foldl` holds without a hypothesis.
The proofs relate the two paths only. They do not prove that `step` implements a VT100 correctly.
`apps/salix_agent/test/ssh_terminal_test.exs` tests that behavior.

## Session surface

The kernel owns immutable Session values. Elixir holds `SalixAgent.InternalSession.t()`, an opaque handle.
The Actor and storage CAS select the current committed revision. Old handles stay valid but cannot establish commit authority.
Field queries return data, but cannot mutate resident state. Prefer complete decisions and consumer projections over host rules assembled from getters.
The surface has three parts. Everything else in `salix_agent` is derived from these calls.

Lifecycle, where the state crosses as data once at each end:

| Operation | Payload | Result |
| --- | --- | --- |
| `new` | `{agent_id, session_id, attrs}` | handle of a normalized fresh session |
| `open` | state map | handle, exactly as given (tests, imports, migrations) |
| `load` | snapshot ETF bytes | handle of the normalized stored state, or `invalid_snapshot` |
| `admit` | snapshot ETF bytes | handle of the stored state exactly as written (repair tools), or `invalid_snapshot` |
| `persist` | none | snapshot ETF bytes of the persistable state |
| `prepare_write` | none | handle after normalization and the format-3 migration |
| `fork` | `{session_id, attrs}` | handle of the fork, or `fork_cutoff_below_compaction` |
| `export` | none | the state as data, for tests and one-off tools only |

Commands: `step` with one event and `resume` with an observation.
Host bookkeeping is an event too. `session_stamp` writes `agent_id`, `runtime_epoch`, `runtime_node`,
`activity_revision`, `storage_revision`, `flush_id`, `work_index_token`, and `work_index_reasons`.
`bump_hwm` raises `next_message_id` past a materialized high-water mark.

Queries: `query` with `{name, args}` returns data derived from the state.
`get` reads one field. Prefer derived queries for large transcript fields.
A query that needs configuration or the clock asks through the same observation continuation as an event.
The query modules live under `runtime/VerifiedKernel/Session/Query/`, one per Elixir domain. Most queries are not proved.
`WorkConservation.materialize_batch_has_records` proves coverage of queue retirement by generated records in the materialization query.
`WorkConservation.materialized_input_fields` connects planned retirement to concrete records after successful canonical batch application.
It checks delivery and runtime identity and content fields against their generated events.

### Query catalog

Each query is `(state, args) → value`. `args` is `nil` unless a shape is listed.
Values use plain data: `true`/`false`, `nil`, integers, binaries, lists, maps, and tagged tuples.
The Lean name is the Elixir name without `?`. The wire name is the Elixir name.

| Query | Args | Value | Source |
| --- | --- | --- | --- |
| `derived_state` | | `:active`, `:queued`, `:waiting`, `:paused` | `State.derived_state/1` |
| `waiting?` | | boolean | `State.waiting?/1` |
| `llm_retry_at_ms` | | integer or `nil` | `State.llm_retry_at_ms/1` |
| `recovery_wait` | | map or `nil` | `State.recovery_wait/1` |
| `activity_status` | | activity atom | `State.activity_status/1` |
| `activity_issue` | | binary or `nil` | `State.activity_issue/1` |
| `monitored_activity_signature` | | `:stopped`, `:active`, `{:error, binary}` | `State.monitored_activity_signature/1` |
| `context_byte_size` | | integer | `State.context_byte_size/1` |
| `estimated_tokens` | | integer | `State.estimated_tokens/1` |
| `observed_prompt_tokens` | | integer | `State.observed_prompt_tokens/1` |
| `work_reasons` | | list of binaries | `State.work_reasons/1` |
| `has_unacked_wakeable_input?` | | boolean | `State.has_unacked_wakeable_input?/1` |
| `unacked_queue_items` | | list of maps | `State.unacked_queue_items/1` |
| `materialize_pending_input_events` | limit or `nil` | `{events, wake?, hwm}` | `State.materialize_pending_input_events/2` |
| `yieldable_provider_wait?` | | boolean | `State.yieldable_provider_wait?/1` |
| `wait_identity` | | `{:ok, id}`, `{:error, :invalid_wait}`, `nil` when no wait | `Waits.identity/1` on `wait` |
| `active_human_source_ids` | | sorted list of binaries | private `active_human_source_ids/1` |
| `provider_wait_yield_events` | `%{wait_identity, next_message_id, last_ack_message_id, active_human_source_ids}` of the expected state | list of events | `State.provider_wait_yield_events/2` |
| `needs_transcript_continuation?` | | boolean | `State.needs_transcript_continuation?/1` |
| `visible_reply_repair_required?` | | boolean | `State.visible_reply_repair_required?/1` |
| `visible_reply_repair_exhausted?` | | boolean | `State.visible_reply_repair_exhausted?/1` |
| `pending_visible_reply?` | | boolean | `State.pending_visible_reply?/1` |
| `current_activation_key` | list of source ids or `nil` | sorted list of binaries | `State.current_activation_key/2` |
| `consecutive_unsettled_rounds` | | integer | `State.consecutive_unsettled_rounds/1` |
| `runaway_unsettled_rounds_exhausted?` | | boolean | `State.runaway_unsettled_rounds_exhausted?/1` |
| `consecutive_repeated_tool_results` | | integer | `State.consecutive_repeated_tool_results/1` |
| `repeated_tool_results_exhausted?` | | boolean | `State.repeated_tool_results_exhausted?/1` |
| `repeated_tool_result_tool` | | binary or `nil` | `State.repeated_tool_result_tool/1` |
| `rounds_since_fresh_input` | | integer | `State.rounds_since_fresh_input/1` |
| `input_round_budget_exhausted?` | | boolean | `State.input_round_budget_exhausted?/1` |
| `consecutive_llm_failures` | | integer | `State.consecutive_llm_failures/1` |
| `llm_failures_exhausted?` | | boolean | `State.llm_failures_exhausted?/1` |
| `llm_failure_terminal?` | | boolean | `State.llm_failure_terminal?/1` |
| `has_unprocessed_stable_work?` | | boolean | `State.has_unprocessed_stable_work?/1` |
| `has_pending_stable_input?` | | boolean | `State.has_pending_stable_input?/1` |
| `lookup_async_call` | ref binary | `{:ok, record}`, `{:archived, seq}`, `:not_found` | `State.lookup_async_call/2` |
| `covered_seq` | compacted_through integer | integer | `State.covered_seq/2` |
| `total_message_count` | | integer | `State.total_message_count/1` |
| `human_source_origin?` | origin | boolean | `State.human_source_origin?/1` |
| `pending_assistant_id` | | integer or `nil` | `TurnOutcome.pending_assistant_id/1` |
| `decision_required?` | | boolean | `TurnOutcome.decision_required?/1` |
| `consecutive_timeouts` | | integer | `Waits.consecutive_timeouts/1` on `messages` |
| `visible_reply_phase` | | `:clean` or `{:repair_required, attempts}` | `VisibleReplyPolicy.phase/1` |
| `visible_reply_guard` | | `:clean`, `{:repair_required, a, r, h}`, `{:repair_exhausted, a, r, h}` | `VisibleReplyPolicy.guard/1` |
| `derive_visible_reply_scope` | list of source ids | `{:ok, scope}` or `:none` | `VisibleReplyScope.derive/2` |
| `current_source_message_ids` | | list of binaries | `VisibleReplyScope.current_source_message_ids/1` |
| `valid_activation_scope?` | scope | boolean | `VisibleReplyScope.valid_activation_scope?/1` |
| `scopes_equivalent?` | `{left, right}` | boolean | `VisibleReplyScope.equivalent?/2` |
| `pending_obligations` | | list of targets | `ProviderReplyObligation.pending/1` |
| `pending_obligation_count` | | integer | `ProviderReplyObligation.pending_count/1` |
| `blocking_obligation_count` | | integer | `ProviderReplyObligation.blocking_count/1` |
| `obligation_admission_full?` | `{payload, limit}` | boolean | `ProviderReplyObligation.admission_full?/3` |
| `normalize_obligation` | raw target | target map or `nil` | `ProviderReplyObligation.normalize/1` |
| `obligation_key` | target | binary | `ProviderReplyObligation.key/1` |
| `should_compact?` | `{threshold or nil, context_tokens or nil, model or nil}` | boolean | `Compaction.should_compact?/2` |
| `prepare_prompt_snapshot` | configured prompt or `nil` | `{events, effective_prompt}` | `Round.prepare_prompt_snapshot/2` |
| `provider_states` | | map | `ContextProviders.provider_states/1` |
| `fork_inline_result_seqs` | attrs | sorted list of integers | `State.fork_inline_result_seqs/2` |
| `session_json` | agent id | string-keyed listing map, `nil` values dropped | `InternalAgentRuntime.session_json/2` |
| `compact_result_for` | source message id | compact-result map or `nil` | `InternalAgentRuntime.compact_result_for/2` |
| `lineage_source_session_id` | | parent session id, or `nil` for a cross-agent fork | `InternalAgentRuntime.session_trace_lineage/4` |
| `title_has_assistant?` | | boolean | `Titles.has_assistant?/1` |
| `title_source_content` | | binary (first user message, blocks flattened, untruncated) | `Titles.first_user_content/1` |
| `latest_compaction_recovery` | | recovery map or `nil` | `RuntimeFiles.latest_recovery/1` |
| `internal_session_billing_entries` | `{model, provider_type}` | list of billing entry maps | `Billing.internal_session_billing_entries/3` |
| `input_dedupe_member?` | source id | boolean | `MeetingRuntime.event_committed?/3` |
| `session_snapshot_id` | | binary (`storage_revision`, else `"seq:<last_seq>"`) | `MemoryConsultationRuntime.snapshot_id/1` |
| `fresh_wakeable_input?` | id snapshot integer | boolean | `Round.fresh_wakeable_input?/2` |
| `current_source_ids` | | list of binaries | `ToolCallProvenance.current_source_ids/1` |
| `current_turn_trusted_origins` | list of source ids | list of origin maps | `Round.current_turn_trusted_origins/2` |
| `current_turn_source` | list of source ids | `{source_message_id, trusted_origin}` | `Round.current_turn_source/2` |
| `async_result_by_seq` | seq integer | result record or `nil` | `Round.resolve_async_result_for_request/4` |
| `earliest_delivered_at_ms` | list of source ids | integer or `nil` | `PhaseTelemetry.earliest_delivered_at_ms/2` |
| `input_queue_length` | | integer | `InternalSessionActor.input_queue_full?/2` |
| `duplicate_delivery?` | source id binary or `nil` | boolean | `InternalSessionActor.duplicate_delivery?/2` |
| `wait_expired?` | | boolean (reads `observed_time`) | Expiry projection. Actor event selection uses `wait_timeout_event`. |
| `completion_target` | tool_call_id binary | `{:running, call}`, `:already_resolved`, `:unknown` | `InternalSessionActor.completion_target/2` |
| `terminal_reply_source_scope` | | scope map or `nil` | `TerminalReply.source_scope/1` |
| `terminal_reply_targets` | | exact source reply target records | `TerminalReply.context/4` |
| `terminal_reply_context` | role, trusted origin, source ids, assistant id, call count, `router_authority` | scope map or `nil` | `TerminalReply.context/4` |
| `terminal_reply_matches?` | binding map | boolean | `TerminalReply.matches?/2` |
| `terminal_reply_running?` | | boolean | `TerminalReply.running?/1` |
| `onboarding_source_message_id` | source id binary | integer or `nil` | `TerminalReply.settle_onboarding/3` |
| `onboarding_send_completed?` | last_ack integer | boolean | `TerminalReply.settle_onboarding/3` |
| `compaction_live_messages` | | list of messages | `Compaction.live_messages/1`: the live window, with each project knowledge block kept only where its content first appears |
| `request_live_messages` | | list of messages | `Compaction.live_messages/1` for the provider request context |
| `request_conversation_tail` | non-negative integer limit | list of messages | the newest `limit` user and assistant messages with text from `request_live_messages`. Tool and runtime messages are left out |
| `compaction_context_prefix` | | list of zero or one message | the prefix of `Compaction.context/1` |
| `provider_compaction_items` | | list of items or `nil` | `Compaction.provider_compaction_items/1` |
| `unfinished_activation_start_id` | list of messages | integer or `nil` | `Compaction.unfinished_activation_start_id/2` |
| `auto_compaction_block_result` | `{fingerprint, last_id, now}` | `nil`, or a string-keyed map with `"reason"` (`"compaction_recovery_active"` or `"compaction_backoff"` with `"next_retry_at"`) | `Compaction.auto_compaction_block_result/3` |
| `async_result_record` | seq integer | record map or `nil` | window lookup in `Compaction.resolve_async_result_for_request/3` |
| `adopted_llm_context?` | | boolean | `ContextProviders.adopted_llm_context?/1` |
| `latest_user_input_message` | | message or `nil` | the session read in `TimeContext.prepare/3` |
| `repair_scan` | | string-keyed map: `"missing_calls"` (list of `%{id, name, args, source_call}`), `"running_async"` (records), `"last_message_role"`, `"last_message_id"`, `"visible_reply_intent?"` | the transcript scan of `Repair.plan_session/2` |
| `terminal_results_from_backup` | | list of `{tool_call_id, call, expected_seq}` | `SessionFormat1BackupPrune.terminal_results_from_backup/1` |
| `ifc_context` | `{source_message_id, source_message_ids, trusted_origin}` | wire context map (`items`, `input_refs`, `requester`, `source_scope`, `consumed_refs`, `request`) | `IFC.Context.build/2` |
| `ifc_organization_scopes` | `{source_message_ids, kind}` | list of scope maps | `IFC.Context.organization_scopes/3` |
| `project_knowledge_question` | | `{:ok, question, activation_ids}` or `:none` | `ProjectKnowledgeContext.fresh_question/1` |
| `project_knowledge_activation_boundary` | | integer | the `next_message_id` resolution in `ProjectKnowledgeContext.activation_id/2` |
| `project_knowledge_committed?` | runtime message id | boolean | `ProjectKnowledgeContext.already_committed?/2` |
| `visible_reply_async_completion_facts` | tool result map | string-keyed map: `"exhausted?"`, `"phase"` (`:clean` or `{:repair_required, n}`), `"scheduled"` (`:not_scheduled` or `{:scheduled, :completed \| :pending \| :failed}`), `"next_hwm"`, `"repair_revision"`, `"repair_diagnostic_hwm"` | the state reads of `VisibleReplyPolicy.async_completion_events/4` |

Queries read these `:salix_agent` configuration keys: `llm_failure_activation_cap`, `runaway_unsettled_round_cap`,
`repeated_tool_result_cap`, `input_round_cap`, and `compaction_threshold`. `should_compact?` uses its `threshold` argument before the configuration.

### Profiling the resident kernel

`profile/Main.lean` is a `lake` executable that decodes a stored snapshot and times the schema check, encoder,
reducers, and lifecycle steps in-process, without the BEAM. Build the SHA-256 extern it links first:

```sh
cc -O2 -c profile/sha256.c -I"$(lean --print-prefix)/include" -o profile/sha256.o
lake build profile && .lake/build/bin/profile path/to/snapshot.etf
```

The snapshot is the plain ETF `SalixAgent.InternalSession.persist/1` returns (or its `{:comma_internal_session, 3, state}` envelope).

Run `lake env lean --run scripts/bench-tool-history.lean` to compare Chat Completions projection time for distinct and reused tool-call IDs.
These are interpreter microbenchmarks, not native NIF or end-to-end latency.

## IFC domain

The `:ifc` domain owns authorization, label operations, membership evaluation,
request validation, receipt checks, and compaction labels.
`SalixIFC` keeps public structs, input constructors, and the durable string codec.
The facade sends `{1, :ifc, 1, operation, arguments_tuple}` through the same NIF.
IFC does not request observations. Its caller supplies time in `Facts.now`.

The schema permits explicit IFC records and canonical MapSets, not custom protocols.
Malformed authorization input returns `{:deny, %SalixIFC.Reason{clause: :invalid_input}}`.
Unknown membership never supplies permission. A separate affirmative clause can still allow a source.

The IFC proofs cover permission conjunction, sealed declassification, read permission
for each declassification clause, unknown rejection, request integrity, consumed refs,
and validation failure through the complete decision pipeline.
Lattice laws and compaction restriction have property tests, not complete Lean proofs.
The independent `IFC.System` module proves semantic label laws, authorization properties,
and consent/receipt invariants over arbitrary finite traces.
`IFC.SystemRefinement` proves the executed clause selector's branch conditions.
`IFC.FullRefinement` proves admission soundness for the complete `decideChecked` pipeline against `IFC.DecisionContract`.
`IFC.SemanticRefinement` proves concrete reader, identity, label, policy, receipt, and source-selection correspondence to independent system authorization.
`IFC.Transfer` controls receipt consumption. `IFC.TransferSystem` connects completed claims and checked admission to a reachable dispatch.
`IFC.CheckedExecution` proves payload and final low-state equality for evolving result stores, including reactive scheduling from the current low view.
These proofs do not impose cumulative model labels or prove the codec, resolver, database, timing, or external delivery.
See the [IFC contract and proof boundaries](../../../docs/verification.md).

## Session commands and projections

`InternalSession.Command.run/6` drives complete input, activation, and recovery operations.
The command protocol uses the query transport. It adds no NIF entry point or dynamic callback dispatch.

| Query | Arguments | Result |
| --- | --- | --- |
| `command` | `{operation, input, checkpoint}` | `{:perform, request, continuation}` or `{:return, result, checkpoint}` |
| `resume_command` | `{continuation, observation}` | The next external request or terminal result |
| `activation_next` / `activation_fast` | External routing fact, when requested | The next activation action |
| `materialization_plan` | Control prefix and requested mode | Events, high-water mark, and next action |
| `reconcile` / `recovery_policy` | Opaque recovery checkpoint and observations | Continue, retry, settle, or fail |
| `prepare_response` | Provider response facts and external restriction | Keep the response or replace its calls |
| `output_preparation` / `output_committed` | Validated terminal intent or commit observations | Provider result, external actions, and next round action |
| `finish_output` / `finish_tool_batch` | Provider observations | Complete commit batch and post-commit instructions |
| `async_completion_events` / `recovered_completion_events` | Tool observations and candidate events | Completion batch with repair and notification rules |
| `tool_continuation` | Independent runtime observations and opaque checkpoint | AgentLoop's next action |
| `provider_context` | None | Compaction prefix and live messages, with runtime-page sizing, source annotations, and public-summary projection |
| `provider_dispatch` | Delta, trusted origin, disclosure, protocol, config, tools, mode | Final provider JSON from the resident Session, with external attachment observations |
| `provider_request_part` | Named projection and its data | Shared prompt, activation-message, or source-annotation projection |
| `settle_tool_batch` | Events, tool results, guidance candidates, tracking flag, and Router authority | Complete settlement batch |
| `terminal_settlement` / `onboarding_settlement` / `onboarding_async_settlement` | Tool results, candidate events, and external authority where required | Terminal acknowledgment and idle events |
| `round_view` / `round_request` | None, or the round's role, Router fact, notice flag, nonce, and request arguments | Activation sources, current source, and visible-reply presentation, or the provider request with its round facts |
| `loop_record` | A `build_record` spec and the host's trace, model, label, role, and source facts | The record, and a tool turn's terminal-reply scope |
| `tool_batch_events` / `result_obligation_events` | Tool results, checkpoint, and trace ids, or one result and its call record | The batch's events and high-water mark, or one result's obligation events |
| `call_envelopes` / `notice_reply_scope` | A `run_tools` effect's calls and whether the LLM tool envelope is on, or a notice's assistant id | Each call through the envelope, or the notice's scope |
| `restart_plan` / `resume_restart` | Live dependency ids and recovery mode, then continuation and observation | Closed external request or complete recovery batch |
| `guard_recovery` | Live dependency ids. Reads `{:archived_record, seq}` and `{:staged_result, attempt}` through the query reader | The settlement batch of a committed runtime failure reply, or a runaway or local guard settlement |
| `capability_observation` | A `capability` request's record. Reads `{:reconcile_capability, id, result}` through the query reader | `{observation, reason}`: the observation for `resume_restart`, and the failure reason when reconciliation exhausted its retry budget |
| `restart_encode` | An `encode_missing` or `encode_external` request of `restart_plan` | The request's result events |
| `session_repair` | `%{"live" => tool_call_ids, "checkpoint" => recovery}`. Reads as `session_step` does | `{:ok, events, next_message_id}`: the crash repair that `session_step` runs, for a host outside a processing entry (`Repair.plan_session/2`), or `{:error, reason}` |
| `session_step` | `{machine, event, nil}`. Reads `{:held, key}`, `:clock`, `:nonce`, crash-repair reads, `{:restart, request, guard_events}`, and the request reads of `round_request` through the query reader | `{machine, effect}`: the next effect of a whole session (recovery, repair, activation, compaction, model rounds, and the agent loop). The machine's `"held"` map holds the held values that the step changed. `SalixVerifiedKernel.SessionStep` keeps them on the host |
| `activation_plan` | `{prompt, compaction_facts}` | Whether the session compacts first, the `activate` arguments, and whether the activation must land before the model call |
| `activation_facts` / `round_facts` | None, or `{config, snapshot \| :current, guard}` | The wait-extension ceiling, or the facts of a round |
| `validate_events` | A write's events | `:ok` or `{:error, reason}` |
| `activity_revision` | The next activity signature and a fresh revision | The activity revision of the write |
| `wait_timeout_event` | Timer identity and source, or no arguments for expiry reconciliation | Timeout queue event or `nil` |
| `llm_retry_metadata` | Classified failure metadata and acknowledged high-water mark | Metadata with an eligible retry deadline |
| `compaction_admission` / `compaction_failure_events` | Request coordinates or classified failure facts | Admission result or failure and recovery batch |
| `compaction_snapshot` | `{request_messages, last_id}` | Request coordinates and covered view |
| `check_compaction_snapshot` | `{snapshot, current_messages, last_id}` | Admission or stale-view error |
| `compaction_required?` / `context_overflow_pending?` | Model configuration facts, or none | Whether automatic compaction must run before the next round |
| `compaction_prepare` | Mode and facts: model configuration or its error, overrides, strategy candidates, overflow recovery, and source id | A settled result and its events, a failure to commit, or a plan |
| `compaction_request` | Plan, model configuration, and prompt, with an optional protocol, config, and tools | `:skip`, or the summary or provider-compaction request |
| `compaction_outcome` / `compaction_commit` | Plan and model answer, then plan, outcome, and refreshed prompt | A result with its events or an outcome that needs the fence, then the commit batch or a stale-view error |
| `compaction_result_events` / `context_overflow_failure` / `compaction_window` | Status, reason, and source id; a reason; a model configuration | A result and its events; the overflow failure metadata; the context window |
| `archive_window_records` / `archive_window` | None | Ordered records, with sequence-gap rejection for the window |
| `archive_match_prefix` | `{landed_records, captured_prefix}` | Exact decoded-fact match or divergence/stale-window error, using trusted ETF encoding observations |

Commands accept `input`, `log`, `activate`, and `recover`.
Their closed I/O requests cover captured writes, durability fences, workspace writes, authority checks, entropy, notifications, and draft cleanup.
The host never chooses a continuation from Session fields.
Restart planning requests capability ownership, staged results, and tool-specific result encodings from the host.
The host answers the capability request with `capability_observation` and the missing and external-callback encodings with `restart_encode` (`Session.RepairHost`).
It encodes recovered and failed background-tool results and envelope guidance itself, with the code that its live completion paths share.
Settlement queries own terminal binding checks, onboarding completion, guidance budgets, acknowledgments, and idle transitions.
The host supplies current Router authority, process liveness, and timer delivery. The provider domain supplies agent-loop provider error classifications.
Lean selects wait timeout events, activation retries, and compaction failure backoff or recovery.
After a staged write, the driver resumes against its working revision and must cross the durable fence before confirmation.
A failed fence restores the baseline and cannot trigger a success notification or draft cleanup.

Lean owns authorization reuse and presentation identity selection.
An opaque Actor checkpoint keeps a successful authorization across a failed CAS.
An Actor restart drops that checkpoint and requires fresh authorization.
The combined activation CAS includes materialization, presentation installation, prompt initialization, and active status.
No command state or authorization checkpoint enters a durable snapshot.

Presentation operations own public-summary projection, repair transitions, scheduled fallback selection, and live and recovered completion batches.
The request projection shows a user-reportable failure by its public summary and a model-only diagnostic behind a `[private diagnostic]` header. Every other message is shown as committed. Repair does not change earlier messages.
One output plan selects settlement, provider rejection, repair continuation, and exhaustion. The host does not select a finalizer from repair phase.
External tool adapters keep callable-tool and provider-schema validation.
Tool-result encodings and telemetry observations are host responsibilities.
Request projection reuses IFC reference generation for source annotations.
Later result reads preserve earlier reader pages. History reduction uses the compaction boundary.
Lean fits runtime reader pages and checks attachment provenance and activation scope before it requests external data.
An inbound attachment is never model input. Lean asks the host for it as a workspace file, whatever type the sender declared, and the host answers with a note that gives its name and VFS path.
Only a tool read asks for image bytes. The host refuses that read unless the agent template accepts image input.
Attachment reads use `{:request_batch, requests}` observations. The host returns one result per request, in the same order.
One batch reads authoritative result records. After validation, another batch reads approved attachments.
Normal resident dispatch returns final provider JSON, not intermediate message lists.
Providers with `request_config/1` receive that encoded body. List-based providers use the explicit `neutral` projection from the same query.
Elixir keeps tool-result publication sizing, live authority, image reads and preprocessing, stored-result reads, and network I/O.
Transient activation facts enter only the request. The response acceptance path decides whether to persist them.
Host-only exception and process values in error observations become bounded diagnostic text. They do not widen the Session schema.

Most of these operations have runtime tests, not functional correctness theorems.
The command-confirmation and materialization exceptions are listed in the [verification contract](../../../docs/verification.md#accepted-work-and-durable-confirmation).
Lean checks termination of their pure definitions. The axiom audit includes executable command and policy dispatch.
This does not prove external-call termination, fixed latency, or Actor retry progress.

## Pure-data schema

Session accepts integers, finite floats, atoms, binaries, bitstrings, tuples, lists, and maps.
Improper lists can travel as data, but list operations can reject them.
Map keys keep exact integer/float and atom/binary distinctions.
Binary content need not be UTF-8.

Only the root State envelope and canonical MapSet data records can carry struct tags.
A MapSet record has exactly `__struct__` and `map` fields. Each membership marker is `[]`.
Other structs are rejected, including those in unused nested values.
The codec rejects PIDs, ports, references, functions, compressed ETF, and unsupported tags.
It accepts UTF-8 and Latin-1 atoms and both string/list encodings.

No custom Access, Enumerable, String.Chars, Inspect, or Jason protocol runs.
Lean defines the supported field access, traversal, text conversion, JSON, and fallback display operations.
Unsupported data operations raise `ArgumentError` with the `invalid Session data:` prefix.
Arithmetic, missing-field, and malformed-list failures keep their explicit exception categories.

The wire parser permits 64 nested term levels, including the envelope.
Encoding permits 72 levels for response and continuation envelopes.
There is no package-specific byte-size or integer-magnitude limit.
Inputs must fit the caller's request, storage, and memory limits.
This is an internal BEAM-generated ETF interface, not a general untrusted deserialization service.

## Observations and continuation data

The caller supplies only clock and configuration observations.
The host answers the clock and the known configuration keys ahead of each call with `{:ok_for, key, value}` entries.
`key` is the exact request, or `{:config, app, name}` for a configuration request with any fallback.
These entries are consulted for every matching request and never consumed, so a replay reads the same answers.
A request with no answered-ahead entry follows the continuation protocol below.
A resident state is checked against the schema once, when it is admitted (`open`, `load`). Reduction trusts it afterwards.
The adapter does not provide a candidate state or an admission decision.

Clock continuations keep the event inputs and reference the resident state before the event.
Activity continuations reference the resident reduced state and carry activity input fields, timestamp fields, and recorded configuration values as data.
Configuration resumes do not repeat the event reducer or decode the full history.

A token holds one resident state reference and otherwise only data. It has no pointers, closures, or host callback names.
`Session.detach` removes the state from a kernel response and `Session.attach` restores it before `resume`. The `attach_detach_*` theorems state that the pair is lossless.
Tokens are private to one synchronous invocation, not persisted or authenticated.
Do not resume a reducer observation token against a newer state.
Command continuations advance with the working revision after staging and the committed revision after a successful fence.
Actors, timers, storage CAS, and network calls are outside the kernel.
Kernel command plans construct input and presentation events. Host adapters encode provider observations.

## Proofs and trust

The reducer theorems refer to the functions used by runtime dispatch.
They cover terminal progress and settlement preservation, terminal start rejection, blocked ACK preservation, stale compaction, and invalid-state rejection.
Observation laws cover empty and recorded journals.

`WorkConservation`, `WorkFrames`, and `DurableConfirmation` prove executable materialization, queue preservation, and input-confirmation properties.
`WorkProtocol` states a conditional transaction model. It does not prove the full projection from concrete host states.
`WorkRefinement` connects the planner to actual record insertion and field preservation through a complete applied batch.
See [accepted work and durable confirmation](../../../docs/verification.md#accepted-work-and-durable-confirmation) for its host assumptions and runtime conformance limits.

`Session/AppendOnly.lean` and `Session/AppendOnly/*.lean` prove that the transcript only grows.
`inner_extends`, `prepare_extends`, `run_done_extends`, and `runTrusted_done_extends` state that every event except `archive_advance` keeps the `messages` list as a prefix of the next one.
Compaction events (`compaction`, `provider_compaction`, `session_compact_result`, `compaction_failure`, `compaction_recovery`) are included: they move watermarks and summaries and never rewrite messages.
`archiveAdvance_suffix` covers the excluded archive event: for a transcript of plain messages with nondecreasing integer `seq` stamps, `archive_advance` keeps a suffix, and every removed message has `seq` at or below the event's `archived_through`.
The `messages` field must already be a list.
`Session/AppendOnly/Seq*.lean` and `Session/AppendOnly/Sorted.lean` prove that the `seq` stamps stay sorted.
`SeqSorted` says that `messages` is a list, `last_seq` defaults to an integer, every message carries an integer `seq` at most `last_seq`, and the stamps are nondecreasing along the list.
`inner_seq`, `prepare_seq`, and `run_done_seq` state that every event, including `archive_advance`, preserves `SeqSorted`. `seq_sorted_empty` establishes it for the empty transcript.
`archiveAdvance_prefix` combines the two results: from any state that satisfies `SeqSorted`, `archive_advance` on plain messages removes exactly a prefix, with no ordering hypothesis left to the caller.
The proofs follow the runtime dispatch code rather than a separate model.

This is not a proof of every Session property.
Codec behavior, text compatibility, snapshot projection, C ownership, and compiled execution also need runtime tests.
Lean's compiler, runtime, native standard library, C wrapper, OpenSSL's SHA-256, and BEAM are trusted.
No theorem here proves storage durability, Actor scheduling, external effects, or complete user-task success.

## Native stack safety

The NIF shares BEAM's process and runs on bounded dirty-scheduler stacks.
Termination proofs do not establish a native stack bound. Do not increase the
scheduler stack to compensate for traversal depth proportional to list width.
Use loops or accumulators for byte scans and wide-list folds.

JSON parsing admits at most 64 value levels (the root counts as one). This bounds
syntax conversion and destruction before native recursion can exhaust a scheduler
stack. Tool arguments are rejected when decoding fails. Reference pruning
distinguishes malformed JSON from a resource rejection: the latter aborts the
projection rather than silently deleting potentially referenced results. An
over-depth stored message needs repair. It does not justify discarding result
references.

The stack review is a bounded code audit, not a proof that arbitrary native code cannot crash.
Run `test/native_stack_test.exs` with the default native scheduler stack, not an increased `+sssdcpu` setting.

## Static runtime

The shared NIF statically contains Lean `libInit.a`, `libStd.a`, runtime, allocator, and libuv objects.
It uses Lean's built-in bignum implementation, not a GMP runtime dependency.
The runtime and allocator use PIC. Linux uses global-dynamic TLS. macOS uses native Mach-O thread-local storage.
The installed Linux `libleanrt.a` uses local-exec TLS and cannot be loaded as this NIF.
Both platforms export only `nif_init` and use the `verified_kernel.so` filename that BEAM expects.
Linux uses an ELF version script. macOS uses a Mach-O export list and resolves NIF API symbols from BEAM.
The runtime requires no Lean installation or Lean dynamic library.
Resident Session states live in NIF resources. C marks each stored Lean object multi-threaded, so scheduler threads share it safely, and releases it when the BEAM collects the resource.
The application bundles third-party license notices in `priv/licenses`.

Operating-system C/C++ libraries stay dynamic. OpenSSL `libcrypto` supplies SHA-256 through the `salix_verified_kernel_sha256` extern. The kernel does not implement cryptographic hashing itself.
`scripts/check.sh` checks shared dependencies and exports.
Upgrade by restarting the node. Runtime unloading and hot replacement are unsupported.
Dirty CPU scheduling does not isolate native crashes or force cancellation.
