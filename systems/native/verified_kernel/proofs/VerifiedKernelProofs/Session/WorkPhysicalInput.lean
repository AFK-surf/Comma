import VerifiedKernelProofs.Session.WorkPhysicalEncoded
import VerifiedKernelProofs.Session.WorkDriverConfirmation

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem started_input_admitted {state args result : Term} {batch journal rest : List Term}
    (call : Command.input state args journal = .ok (result, rest)) (started : InputStart result batch) :
    (∀ event ∈ batch, BinaryKeys event) ∧ ∀ event ∈ batch, Command.inputEventAllowed event = true := by
  rcases input_start call with duplicate | saturated | invalidInput | ⟨planned, planStart, canonical, allowed⟩
  · rw [duplicate] at started
    simp [InputStart, Command.duplicateInput, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [saturated] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [invalidInput] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · have same := input_start_unique planStart started
    subst planned
    exact ⟨canonical, List.all_eq_true.mp allowed⟩

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem input_write_physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor final : Cursor} {args result hwm : Term} {batch journal rest sealed : List Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (input : Command.input cursor.working args journal = .ok (result, rest)) (started : InputStart result batch)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) final) :
    PhysicalHistory framing objects owner session final.working sealed := by
  obtain ⟨_, _, _, _, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, inputBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨canonical, allowed⟩ := started_input_admitted input started
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  exact (history.admitted inputBatch canonical allowed).metadata hwmBatch keys metadata

end VerifiedKernel.Session.PendingRevision

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem InputCommitTrace.physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {entry born checkpoint : Term} {sealed : List Term} {durable : HotSnapshots}
    (trace : InputCommitTrace context entry born checkpoint durable)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed) :
    PhysicalHistory framing objects owner session trace.staged.working sealed ∧
      PhysicalHistory framing objects owner session trace.stamped sealed ∧ ∃ etag snapshot bytes,
        trace.confirmed = .tuple [a "session_command_driver_confirmed",
          (Revision.Cursor.committed trace.stamped etag).pack, inputFenceContinuation trace.events] ∧
        Lifecycle.persistable trace.stamped [] = .ok (snapshot, []) ∧
        ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
        durable trace.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed := by
  obtain ⟨journal, result, rest, input, started, write⟩ :=
    input_raw_admission_applied (input_admission_reflect trace.admission) trace.write
  have pendingWrite := Revision.execution_pending write
  rw [Revision.write_captured] at pendingWrite
  have stagedHistory := PendingRevision.input_write_physical_history history input started pendingWrite
  obtain ⟨prepareJournal, prepareRest, prepared⟩ :=
    RevisionFence.start_prepares (input_raw_fence_prepared trace.preparation)
  have preparedHistory := stagedHistory.prepare prepared
  have stampedHistory := preparedHistory.metadata
    (RevisionFence.metadata_executes (input_raw_fence_stamped trace.metadata))
    (fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
      trace.flush trace.epoch trace.node event member).1)
    (fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
      trace.flush trace.epoch trace.node event member).2)
  obtain ⟨etag, snapshot, bytes, confirmed, persisted, encoded, _, stored⟩ :=
    issued_confirmation trace.encoded trace.primitive trace.resumed
  exact ⟨stagedHistory, stampedHistory, etag, snapshot, bytes, confirmed, persisted, encoded, stored,
    stampedHistory.persist persisted⟩

/-- The input fact and all older work reach the same physically backed, encoded snapshot. -/
theorem InputCommitTrace.physical_input {framing : CodecFraming} {objects : Objects} {owner session source : ByteArray}
    {context : Context} {entry born checkpoint : Term} {sealed : List Term} {durable : HotSnapshots}
    (trace : InputCommitTrace context entry born checkpoint durable)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source) :
    trace.staged.baseline = context.candidate.baseline ∧ trace.staged.etag = context.candidate.etag ∧
      ∃ etag snapshot bytes event now first last item,
        ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
        Lifecycle.persistable trace.stamped [] = .ok (snapshot, []) ∧
        durable trace.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
        Command.inputEvent (context.candidate.working.get (a "session_id")) (.binary source)
          (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
        MainInputFact event source item ∧ CanonicalQueueItem item ∧
        PhysicalIdentityFact objects snapshot (.work item) ∧
        (∀ old, ValueSemantics.Represented context.candidate.working sealed old →
          PhysicalIdentityFact objects snapshot (.work old)) ∧
        resident (some trace.confirmed) (a "next") nil = inputNotification trace.stamped etag trace.events ∧
        (∀ response : DurableConfirmation.Result,
          resident (inputNotification trace.stamped etag trace.events).1 (a "effect_result") response.wire =
            (some (Revision.Cursor.committed trace.stamped etag).pack,
              .tuple [a "return", .tuple [a "ok", a "committed"], nil])) := by
  obtain ⟨stagedHistory, _, etag, snapshot, bytes, confirmed, persisted, encoded, stored, snapshotHistory⟩ :=
    trace.physical_history history
  obtain ⟨journal, result, rest, input, started, write⟩ :=
    input_raw_admission_applied (input_admission_reflect trace.admission) trace.write
  have pendingWrite := Revision.execution_pending write
  rw [Revision.write_captured] at pendingWrite
  obtain ⟨baselineEq, etagEq, _, _, _, oldKept, event, now, first, last, item, generated, fact, canonical, present⟩ :=
    PendingRevision.input_write_preserves sourceValue history.invariant.history.invariant.ready input started pendingWrite
  obtain ⟨prepareJournal, prepareRest, prepared⟩ :=
    RevisionFence.start_prepares (input_raw_fence_prepared trace.preparation)
  have preparedHistory := stagedHistory.prepare prepared
  obtain ⟨_, _, metadataKept⟩ := ValueSemantics.metadata_work
    (RevisionFence.metadata_executes (input_raw_fence_stamped trace.metadata))
    (fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
      trace.flush trace.epoch trace.node event member).1)
    (fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
      trace.flush trace.epoch trace.node event member).2)
    preparedHistory.invariant.history.invariant.ready
  have kept : ∀ value, ValueSemantics.Represented trace.staged.working sealed value →
      PhysicalIdentityFact objects snapshot (.work value) := by
    intro value represented
    apply identity_fact_physical snapshotHistory.invariant.images
    exact ValueSemantics.work_fields_preserves (persistable_work_fields persisted)
      (metadataKept sealed value (ValueSemantics.prepareWrite_preserves stagedHistory.invariant.history.invariant.ready
        stagedHistory.invariant.history.invariant.format prepared represented))
  refine ⟨baselineEq, etagEq, etag, snapshot, bytes, event, now, first, last, item, encoded, persisted, stored,
    snapshotHistory, generated, fact, canonical, kept item (present sealed),
    fun old represented => kept old (oldKept sealed old represented), ?_, input_notification_returns _ _ _⟩
  rw [confirmed]
  exact input_notifies_captured _ _ _

end VerifiedKernel.Session.CommandDriver
