import VerifiedKernelProofs.Session.WorkActivationConfirmation
import VerifiedKernelProofs.Session.WorkPhysicalActivation
import VerifiedKernelProofs.Session.WorkStorageAddress

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem WriteCommitTrace.physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {continuation : Term} {sealed : List Term} {durable : HotSnapshots}
    (trace : WriteCommitTrace cursor continuation durable)
    (history : PhysicalHistory framing objects owner session cursor.working sealed) :
    ∃ etag snapshot bytes,
      trace.key = StorageAddress.key owner session ∧
      trace.confirmed = .tuple [a "session_command_driver_confirmed",
        (Revision.Cursor.committed trace.stamped etag).pack, continuation] ∧
      (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase] : Term) =
        .tuple [a "cas", trace.key, .binary bytes, cursor.etag] ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      durable trace.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      ∀ item, PhysicalIdentityFact objects cursor.working (.work item) → PhysicalIdentityFact objects snapshot (.work item) := by
  obtain ⟨journal, rest, prepared⟩ := RevisionFence.start_prepares (raw_fence_prepared trace.preparation)
  have preparedHistory := history.prepare prepared
  have metadata := RevisionFence.metadata_executes (raw_fence_stamped trace.metadata)
  have keys := fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
    trace.flush trace.epoch trace.node event member).1
  have kinds := fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
    trace.flush trace.epoch trace.node event member).2
  have stampedHistory := preparedHistory.metadata metadata keys kinds
  obtain ⟨etag, snapshot, bytes, confirmed, persisted, encoded, issued, stored⟩ :=
    issued_confirmation trace.encoded trace.primitive trace.resumed
  have encodeCall := trace.encoded
  unfold fencingCursor at encodeCall
  rw [encode_captured] at encodeCall
  obtain ⟨_, inner, _⟩ := accept_fence_cas_capture encodeCall
  obtain ⟨_, _, started⟩ := RevisionFence.encode_capture inner
  obtain ⟨_, preparedCall⟩ := StorageCommit.start_capture started
  have addressed := StorageAddress.agreed_key stampedHistory.invariant.owned stampedHistory.invariant.identified
    (StorageCommit.prepared_address preparedCall)
  exact ⟨etag, snapshot, bytes, addressed, confirmed, issued, encoded, stored, stampedHistory.persist persisted,
    fun item present => stampedHistory.persist_physical persisted item
      (preparedHistory.metadata_physical metadata keys kinds item (history.prepare_physical prepared item present))⟩

theorem activation_raw_write_physical {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {hwm prompt active checkpoint saved after : Term}
    {observations events sealed : List Term} {final : PendingRevision.Cursor}
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced final after)) :
    PhysicalHistory framing objects owner session final.working sealed ∧
      ∀ item, PhysicalIdentityFact objects context.candidate.working (.work item) →
        PhysicalIdentityFact objects final.working (.work item) := by
  obtain ⟨continuation, capturedHwm, savedEq, batch, fenced⟩ := activation_admission_captured admission
  obtain ⟨details, capturedCheckpoint, capturedActive, rfl⟩ := activation_post_write_shape fenced
  rw [savedEq, write_captured] at write
  have valid := fenced_batch_start_valid context
    (.tuple [b "activation_written", details, capturedCheckpoint, capturedActive]) events capturedHwm
  have afterEq := fenced_batch_continuation (fenced_batch_output_preserved write valid)
  subst after
  have execution := Revision.execution_pending (fenced_batch_reflect (fenced_batch_trace_reflect valid write))
  rw [Revision.write_captured] at execution
  exact PendingRevision.activation_write_physical history batch execution

theorem ActivationCommitTrace.physical_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {hwm prompt active checkpoint : Term} {sealed : List Term} {durable : HotSnapshots}
    (trace : ActivationCommitTrace context hwm prompt active checkpoint durable)
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed) :
    ∃ etag snapshot bytes,
      trace.fence.key = StorageAddress.key owner session ∧
      trace.fence.confirmed = .tuple [a "session_command_driver_confirmed",
        (Revision.Cursor.committed trace.fence.stamped etag).pack, trace.continuation] ∧
      (.tuple [a "cas", trace.fence.requestedKey, trace.fence.requestedBytes, trace.fence.requestedBase] : Term) =
        .tuple [a "cas", trace.fence.key, .binary bytes, trace.staged.etag] ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      durable trace.fence.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      ∀ item, PhysicalIdentityFact objects context.candidate.working (.work item) →
        PhysicalIdentityFact objects snapshot (.work item) := by
  obtain ⟨stagedHistory, stagedKept⟩ := activation_raw_write_physical history trace.admission trace.write
  obtain ⟨etag, snapshot, bytes, addressed, confirmed, issued, encoded, stored, snapshotHistory, kept⟩ :=
    trace.fence.physical_history stagedHistory
  exact ⟨etag, snapshot, bytes, addressed, confirmed, issued, encoded, stored, snapshotHistory,
    fun item present => kept item (stagedKept item present)⟩

end VerifiedKernel.Session.CommandDriver
