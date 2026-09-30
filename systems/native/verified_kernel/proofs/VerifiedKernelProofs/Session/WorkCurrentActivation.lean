import VerifiedKernelProofs.Session.WorkCurrentSubmission
import VerifiedKernelProofs.Session.WorkActivationReturn

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem activation_current_facts {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {hwm prompt active checkpoint saved continuation result : Term}
    {observations events sealed : List Term} {staged : PendingRevision.Cursor} {before after : HotStore}
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced staged continuation))
    (fence : WriteSubmission staged continuation)
    (cas : HotCAS before (.tuple [a "cas", fence.requestedKey, fence.requestedBytes, fence.requestedBase]) result after) :
    fence.key = StorageAddress.key owner session ∧ ∃ etag snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      (.tuple [a "cas", fence.requestedKey, fence.requestedBytes, fence.requestedBase] : Term) =
        .tuple [a "cas", fence.key, .binary bytes, context.candidate.etag] ∧
      after.current fence.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      ∀ item, PhysicalIdentityFact objects context.candidate.working (.work item) →
        PhysicalIdentityFact objects snapshot (.work item) := by
  obtain ⟨stagedHistory, stagedKept⟩ := activation_raw_write_physical history admission write
  obtain ⟨_, _, etagEq, _⟩ := activation_raw_write_preserves history.invariant.history.invariant.ready admission write
  obtain ⟨addressed, etag, snapshot, bytes, encoded, issued, stored, snapshotHistory, kept⟩ :=
    fence.current_facts stagedHistory cas
  rw [etagEq] at issued
  exact ⟨addressed, etag, snapshot, bytes, encoded, issued, stored, snapshotHistory,
    fun item present => kept item (stagedKept item present)⟩

theorem activation_return_current_facts {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {context : Context} {hwm prompt active checkpoint saved continuation returned savedReturn returnedCheckpoint : Term}
    {observations events sealed : List Term} {staged : PendingRevision.Cursor} {before after : HotStore}
    (history : PhysicalHistory framing objects owner session context.candidate.working sealed)
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "activate", .tuple [list [], hwm, prompt, active], checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced staged continuation))
    (fence : WriteEpisode staged continuation)
    (cas : HotCAS before (.tuple [a "cas", fence.requestedKey, fence.requestedBytes, fence.requestedBase]) fence.result after)
    (completion : AdmissionTrace (resident (some fence.confirmed) (a "next") nil)
      (some savedReturn, .tuple [a "return", returned, returnedCheckpoint])) :
    returned = a "ok" ∧ returnedCheckpoint = nil ∧ fence.key = StorageAddress.key owner session ∧
    ∃ etag snapshot bytes,
      savedReturn = (Revision.Cursor.committed fence.stamped etag).pack ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      after.current fence.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      ∀ item, PhysicalIdentityFact objects context.candidate.working (.work item) →
        PhysicalIdentityFact objects snapshot (.work item) := by
  let trace : ActivationCommitTrace context hwm prompt active checkpoint after.current :=
    { observations, events, writeCursor := saved, staged, continuation, admission, write, fence := fence.with_cas cas }
  obtain ⟨etag, snapshot, bytes, addressed, confirmed, _, encoded, stored, snapshotHistory, kept⟩ :=
    trace.physical_history history
  obtain ⟨⟨details, capturedCheckpoint, capturedActive, continuationEq⟩, _⟩ :=
    activation_raw_write_preserves history.invariant.history.invariant.ready admission write
  change fence.confirmed = .tuple [a "session_command_driver_confirmed",
    (Revision.Cursor.committed fence.stamped etag).pack, continuation] at confirmed
  simp only [confirmed, continuationEq] at completion
  obtain ⟨savedEq, resultEq, checkpointEq⟩ := activation_return_captured completion
  exact ⟨resultEq, checkpointEq, addressed, etag, snapshot, bytes, savedEq, encoded, stored, snapshotHistory, kept⟩

end VerifiedKernel.Session.CommandDriver
