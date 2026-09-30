import VerifiedKernelProofs.Session.WorkPhysicalInput
import VerifiedKernelProofs.Session.WorkPhysicalPreservation

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem input_write_physical_preserves {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor final : Cursor} {args result hwm : Term} {batch journal rest sealed : List Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (input : Command.input cursor.working args journal = .ok (result, rest)) (started : InputStart result batch)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) final) :
    ∀ item, PhysicalIdentityFact objects cursor.working (.work item) → PhysicalIdentityFact objects final.working (.work item) := by
  obtain ⟨_, _, _, _, _, _, applied⟩ := write_executes execution
  obtain ⟨middle, inputBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨canonical, allowed⟩ := started_input_admitted input started
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  exact fun item present => (history.admitted inputBatch canonical allowed).metadata_physical hwmBatch keys metadata item
    (history.admitted_physical inputBatch canonical allowed item present)

end VerifiedKernel.Session.PendingRevision

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem InputCommitTrace.physical_preserves {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {entry born checkpoint snapshot : Term} {sealed : List Term} {durable : HotSnapshots}
    (trace : InputCommitTrace context entry born checkpoint durable)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (persisted : Lifecycle.persistable trace.stamped [] = .ok (snapshot, [])) :
    ∀ item, PhysicalIdentityFact objects context.candidate.working (.work item) →
      PhysicalIdentityFact objects snapshot (.work item) := by
  obtain ⟨stagedHistory, stampedHistory, _⟩ := trace.physical_history history
  obtain ⟨journal, result, rest, input, started, write⟩ :=
    input_raw_admission_applied (input_admission_reflect trace.admission) trace.write
  have pendingWrite := Revision.execution_pending write
  rw [Revision.write_captured] at pendingWrite
  obtain ⟨prepareJournal, prepareRest, prepared⟩ :=
    RevisionFence.start_prepares (input_raw_fence_prepared trace.preparation)
  have preparedHistory := stagedHistory.prepare prepared
  have metadataKept := preparedHistory.metadata_physical
    (RevisionFence.metadata_executes (input_raw_fence_stamped trace.metadata))
    (fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
      trace.flush trace.epoch trace.node event member).1)
    (fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
      trace.flush trace.epoch trace.node event member).2)
  exact fun item present => stampedHistory.persist_physical persisted item
    (metadataKept item (stagedHistory.prepare_physical prepared item
      (PendingRevision.input_write_physical_preserves history input started pendingWrite item present)))

end VerifiedKernel.Session.CommandDriver
