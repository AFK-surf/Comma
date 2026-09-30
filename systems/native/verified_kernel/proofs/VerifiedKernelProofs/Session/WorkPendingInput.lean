import VerifiedKernelProofs.Session.WorkPendingRevision
import VerifiedKernelProofs.Session.WorkNativeCandidate

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation
set_option Elab.async false

theorem hwm_metadata (hwm : Term) :
    (∀ event ∈ hwmEvents hwm, BinaryKeys event) ∧
      (∀ event ∈ hwmEvents hwm, CommitMetadata event) := by
  unfold hwmEvents
  split
  · constructor
    · intro event member
      simp only [List.mem_singleton] at member
      subst event
      simp [BinaryKeys, b, Term.text, Term.isBinary]
    · intro event member
      simp only [List.mem_singleton] at member
      subst event
      right
      rfl
  · simp

/-- A successful pending input write derives its new fact and preserves older work, including the HWM step. -/
theorem input_write_preserves {cursor final : Cursor} {inputEntry born result hwm : Term}
    {source : ByteArray} {batch j r : List Term}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady cursor.working)
    (input : Command.input cursor.working (.tuple [inputEntry, born]) j = .ok (result, r))
    (started : InputStart result batch)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) final) :
    final.baseline = cursor.baseline ∧ final.etag = cursor.etag ∧ final.events = cursor.events ++ batch ∧
      QueueReady final.working ∧ final.working.get (a "storage_format") = cursor.working.get (a "storage_format") ∧
      (∀ sealed old, ValueSemantics.Represented cursor.working sealed old → ValueSemantics.Represented final.working sealed old) ∧
      ∃ event now first last item,
        Command.inputEvent (cursor.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        ∀ sealed, ValueSemantics.Represented final.working sealed item := by
  obtain ⟨_, _, baselineEq, etagEq, eventsEq, _, applied⟩ := write_executes execution
  obtain ⟨middle, inputBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨middleReady, oldKept, event, now, first, last, item, generated, fields, shape, present⟩ :=
    ValueSemantics.started_input_work sourceValue ready input started inputBatch
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  obtain ⟨finalReady, _, kept⟩ := ValueSemantics.metadata_work hwmBatch keys metadata middleReady
  exact ⟨baselineEq, etagEq, eventsEq, finalReady, resident_batch_format applied,
    fun sealed old represented => kept sealed old (oldKept sealed old represented),
    event, now, first, last, item, generated, fields, shape, fun sealed => kept sealed item (present sealed)⟩

/-- The staged input's captured baseline revision and working facts reach the actual CAS candidate.
The remaining host obligation connects the fence result to the command continuation. -/
theorem input_write_durable
    {cursor staged : Cursor} {inputEntry born commandResult final hwm prepared stamped key storageCursor request result etag : Term}
    {source : ByteArray} {batch metadata j r prepareJournal prepareRest : List Term}
    {effects : List (Term × DurableConfirmation.Result)} {durable : ArchivePublication.HotSnapshots}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = .binary source)
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (input : Command.input cursor.working (.tuple [inputEntry, born]) j = .ok (commandResult, r))
    (trace : CommandExecution.Trace commandResult effects final)
    (confirmed : final = Command.finish (.tuple [a "ok", a "committed"]) ∨
      ∃ notified, final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified"))
    (started : InputStart commandResult batch)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) staged)
    (prepare : Lifecycle.prepareWrite staged.working prepareJournal = .ok (.tuple [a "ok", prepared], prepareRest))
    (metadataExecution : BatchExecution.Execution
      (BatchExecution.resident (some prepared) (a "start") (list metadata)) stamped)
    (metadataKeys : ∀ event ∈ metadata, BinaryKeys event)
    (metadataOnly : ∀ event ∈ metadata, CommitMetadata event)
    (requested : StorageCommit.resident (some stamped) (a "start") (.tuple [key, cursor.etag]) = (some storageCursor, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : StorageCommit.resident (some storageCursor) (a "resume") result = (some stamped, .tuple [a "ok", etag])) :
    staged.baseline = cursor.baseline ∧ staged.etag = cursor.etag ∧
      (∃ before after, effects = before ++
        [(.tuple [a "write", list batch, list []], DurableConfirmation.Result.ok),
          (a "durable_fence", DurableConfirmation.Result.ok)] ++ after) ∧
      ∃ snapshot event now first last item,
        durable key etag snapshot ∧ QueueReady snapshot ∧
        Command.inputEvent (cursor.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        (∀ sealed, ValueSemantics.Represented snapshot sealed item) ∧
        (∀ sealed old, ValueSemantics.Represented cursor.working sealed old → ValueSemantics.Represented snapshot sealed old) := by
  obtain ⟨baselineEq, etagEq, _, stagedReady, stagedFormat, oldKept,
    event, now, first, last, item, generated, fields, shape, present⟩ :=
    input_write_preserves sourceValue ready input started execution
  obtain ⟨planned, _, _, _, _, planStart, fenced, _⟩ :=
    ValueSemantics.confirmed_input_snapshot sourceValue ready format input trace confirmed
  have same := input_start_unique planStart started
  subst planned
  obtain ⟨_, snapshot, committed, snapshotReady, _, kept⟩ :=
    ValueSemantics.native_candidate_preserves (beforeMetadata := []) stagedReady (stagedFormat.trans format)
      (BatchExecution.Execution.done _) (by simp) (by simp) prepare metadataExecution metadataKeys metadataOnly
      requested primitive resumed
  exact ⟨baselineEq, etagEq, fenced, snapshot, event, now, first, last, item,
    committed, snapshotReady, generated, fields, shape, fun sealed => kept sealed item (present sealed),
    fun sealed old represented => kept sealed old (oldKept sealed old represented)⟩

end VerifiedKernel.Session.PendingRevision
