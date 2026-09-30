import VerifiedKernelProofs.Session.WorkConfirmedStorage
import VerifiedKernelProofs.Session.WorkBatchExecution

namespace VerifiedKernel.Session.WorkConservation.ValueSemantics
open Data CommandExecution DurableConfirmation ArchivePublication
set_option Elab.async false

theorem started_input_work {state inputEntry born result next : Term} {source : ByteArray}
    {batch j r : List Term}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady state)
    (input : Command.input state (.tuple [inputEntry, born]) j = .ok (result, r))
    (started : InputStart result batch)
    (applied : ResidentBatch state batch next) :
    QueueReady next ∧ (∀ sealed old, Represented state sealed old → Represented next sealed old) ∧
      ∃ event now first last item,
        Command.inputEvent (state.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧ ∀ sealed, Represented next sealed item := by
  rcases input_command_preserves sourceValue ready input with duplicate | saturated | invalid |
    ⟨planned, event, now, first, last, planStart, generated, candidate⟩
  · rw [duplicate] at started
    simp [InputStart, Command.duplicateInput, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [saturated] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [invalid] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · have same := input_start_unique planStart started
    subst planned
    obtain ⟨nextReady, kept, item, fields, shape, present⟩ := candidate next applied
    exact ⟨nextReady, kept, event, now, first, last, item, generated, fields, shape, present⟩

theorem metadata_work {state next : Term} {events : List Term}
    (applied : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event)
    (ready : QueueReady state) :
    QueueReady next ∧ next.get (a "storage_format") = state.get (a "storage_format") ∧
      ∀ sealed item, Represented state sealed item → Represented next sealed item := by
  obtain ⟨queue, records, _⟩ := commit_metadata_batch_frames applied canonical metadata
  exact ⟨queue_frame_ready queue ready, queue.2.2.2.2,
    fun _ _ represented => execution_preserves
      (fun _ present => concrete_representation_frame_extends queue.1 records present)
      (fun _ present => record_survives records present) represented⟩

/-- Metadata before preparation includes the actual HWM update. Metadata after preparation includes commit stamps. -/
theorem native_candidate_preserves
    {state updated prepared stamped key base cursor request result restored etag : Term}
    {beforeMetadata afterMetadata j r : List Term} {durable : HotSnapshots}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (beforeExecution : BatchExecution.Execution
      (BatchExecution.resident (some state) (a "start") (list beforeMetadata)) updated)
    (beforeKeys : ∀ event ∈ beforeMetadata, BinaryKeys event)
    (beforeOnly : ∀ event ∈ beforeMetadata, CommitMetadata event)
    (prepare : Lifecycle.prepareWrite updated j = .ok (.tuple [a "ok", prepared], r))
    (afterExecution : BatchExecution.Execution
      (BatchExecution.resident (some prepared) (a "start") (list afterMetadata)) stamped)
    (afterKeys : ∀ event ∈ afterMetadata, BinaryKeys event)
    (afterOnly : ∀ event ∈ afterMetadata, CommitMetadata event)
    (requested : StorageCommit.resident (some stamped) (a "start") (.tuple [key, base]) = (some cursor, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : StorageCommit.resident (some cursor) (a "resume") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ ∃ snapshot,
      durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, Represented state sealed item → Represented snapshot sealed item := by
  obtain ⟨updatedReady, updatedFormat, beforeKept⟩ :=
    metadata_work (BatchExecution.start_executes_batch beforeExecution) beforeKeys beforeOnly ready
  have currentFormat := updatedFormat.trans format
  obtain ⟨normalized, same, preparedFormat, preparedReady, _⟩ :=
    prepareWrite_modern currentFormat (Or.inr rfl) updatedReady prepare
  have equal : prepared = normalized := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst normalized
  obtain ⟨stampedReady, stampedFormat, afterKept⟩ :=
    metadata_work (BatchExecution.start_executes_batch afterExecution) afterKeys afterOnly preparedReady
  obtain ⟨restoredEq, snapshot, bytes, persisted, _, _, committed⟩ :=
    StorageCommit.confirmed_candidate requested primitive resumed
  refine ⟨restoredEq, snapshot, committed, (persistable_preserves stampedReady persisted).1,
    (persistable_queue_frame persisted).2.2.2.2.trans (stampedFormat.trans preparedFormat), ?_⟩
  intro sealed item represented
  exact work_fields_preserves (persistable_work_fields persisted)
    (afterKept sealed item (prepareWrite_preserves updatedReady currentFormat prepare
      (beforeKept sealed item represented)))

/-- The complete input and candidate pipeline uses native batch executions, including pre-prepare HWM bookkeeping. -/
theorem native_input_durable_snapshot
    {state inputEntry born commandResult final next updated prepared stamped key base cursor request result restored etag : Term}
    {source : ByteArray} {batch beforeMetadata afterMetadata : List Term}
    {effects : List (Term × Result)} {j r prepareJournal prepareRest : List Term} {durable : HotSnapshots}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (input : Command.input state (.tuple [inputEntry, born]) j = .ok (commandResult, r))
    (trace : Trace commandResult effects final)
    (confirmed : final = Command.finish (.tuple [a "ok", a "committed"]) ∨
      ∃ notified, final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified"))
    (started : InputStart commandResult batch)
    (execution : BatchExecution.Execution
      (BatchExecution.resident (some state) (a "start") (list batch)) next)
    (beforeExecution : BatchExecution.Execution
      (BatchExecution.resident (some next) (a "start") (list beforeMetadata)) updated)
    (beforeKeys : ∀ event ∈ beforeMetadata, BinaryKeys event)
    (beforeOnly : ∀ event ∈ beforeMetadata, CommitMetadata event)
    (prepare : Lifecycle.prepareWrite updated prepareJournal = .ok (.tuple [a "ok", prepared], prepareRest))
    (afterExecution : BatchExecution.Execution
      (BatchExecution.resident (some prepared) (a "start") (list afterMetadata)) stamped)
    (afterKeys : ∀ event ∈ afterMetadata, BinaryKeys event)
    (afterOnly : ∀ event ∈ afterMetadata, CommitMetadata event)
    (requested : StorageCommit.resident (some stamped) (a "start") (.tuple [key, base]) = (some cursor, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : StorageCommit.resident (some cursor) (a "resume") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧
      (∃ before after, effects = before ++
        [(.tuple [a "write", list batch, list []], Result.ok), (a "durable_fence", Result.ok)] ++ after) ∧
      ∃ snapshot event now first last item,
        durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
        Command.inputEvent (state.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        (∀ sealed, Represented snapshot sealed item) ∧
        (∀ sealed old, Represented state sealed old → Represented snapshot sealed old) := by
  have applied := BatchExecution.start_executes_batch execution
  obtain ⟨nextReady, oldKept, event, now, first, last, item, generated, fields, shape, present⟩ :=
    started_input_work sourceValue ready input started applied
  obtain ⟨planned, _, _, _, _, planStart, fenced, _⟩ :=
    confirmed_input_snapshot sourceValue ready format input trace confirmed
  have same := input_start_unique planStart started
  subst planned
  obtain ⟨restoredEq, snapshot, committed, snapshotReady, snapshotFormat, kept⟩ :=
    native_candidate_preserves nextReady ((resident_batch_format applied).trans format)
      beforeExecution beforeKeys beforeOnly prepare afterExecution afterKeys afterOnly requested primitive resumed
  exact ⟨restoredEq, fenced, snapshot, event, now, first, last, item, committed,
    snapshotReady, snapshotFormat, generated, fields, shape,
    fun sealed => kept sealed item (present sealed),
    fun sealed old represented => kept sealed old (oldKept sealed old represented)⟩

end VerifiedKernel.Session.WorkConservation.ValueSemantics
