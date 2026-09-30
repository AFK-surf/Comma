import VerifiedKernelProofs.Session.WorkStoredIdentity

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem WriteSubmission.current_identities {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {continuation result : Term} {sealed : List Term} {before after : HotStore}
    (trace : WriteSubmission cursor continuation)
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (cas : HotCAS before (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase]) result after) :
    trace.key = StorageAddress.key owner session ∧ ∃ etag snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      (.tuple [a "cas", trace.requestedKey, trace.requestedBytes, trace.requestedBase] : Term) =
        .tuple [a "cas", trace.key, .binary bytes, cursor.etag] ∧
      after.current trace.key etag snapshot ∧ PhysicalHistory framing objects owner session snapshot sealed ∧
      ∀ fact, PhysicalIdentityFact objects cursor.working fact → PhysicalIdentityFact objects snapshot fact := by
  have encoded := trace.encoded
  unfold fencingCursor at encoded
  rw [encode_captured] at encoded
  obtain ⟨saved, inner, _⟩ := accept_fence_cas_capture encoded
  have preparation := raw_fence_prepared trace.preparation
  have metadata := raw_fence_stamped trace.metadata
  obtain ⟨stampedHistory, snapshot, bytes, rest, persisted, encoding, issued, snapshotHistory⟩ :=
    RevisionFence.candidate_encoded_history history preparation metadata inner
  obtain ⟨_, _, started⟩ := RevisionFence.encode_capture inner
  obtain ⟨_, preparedCall⟩ := StorageCommit.start_capture started
  have addressed := StorageAddress.agreed_key stampedHistory.invariant.owned stampedHistory.invariant.identified
    (StorageCommit.prepared_address preparedCall)
  have applied : HotCAS before (.tuple [a "cas", trace.key, .binary bytes, cursor.etag]) result after := by
    rwa [issued] at cas
  obtain ⟨etag, stored⟩ := applied.current_candidate encoding
  obtain ⟨journal, remaining, prepared⟩ := RevisionFence.start_prepares preparation
  have preparedHistory := history.prepare prepared
  have execution := RevisionFence.metadata_executes metadata
  have keys := fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
    trace.flush trace.epoch trace.node event member).1
  have kinds := fun event member => (RevisionFence.metadata_admitted trace.token trace.reasons trace.activity trace.revision
    trace.flush trace.epoch trace.node event member).2
  refine ⟨addressed, etag, snapshot, bytes, encoding, issued, stored, snapshotHistory, ?_⟩
  intro fact present
  cases fact with
  | work item =>
    exact stampedHistory.persist_physical persisted item
      (preparedHistory.metadata_physical execution keys kinds item (history.prepare_physical prepared item present))
  | record reference =>
    exact stampedHistory.persist_records persisted reference
      (preparedHistory.metadata_records execution keys kinds reference (history.prepare_records prepared reference present))

end VerifiedKernel.Session.CommandDriver
