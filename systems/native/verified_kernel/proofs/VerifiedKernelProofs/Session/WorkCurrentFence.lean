import VerifiedKernelProofs.Session.WorkEncodedPreservation
import VerifiedKernelProofs.Session.WorkStorageAddress
import VerifiedKernelProofs.Session.WorkPhysicalTransport

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- A landed candidate preserves work in the current object even when the caller receives no reply. -/
theorem candidate_current_facts {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {sealed observations : List Term} {before after : HotStore}
    {key preparedState stamped token reasons activity revision flush epoch node saved request result : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (preparation : Preparation cursor key
      (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution cursor key
      (resident (some (prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (cas : HotCAS before request result after) :
    key = StorageAddress.key owner session ∧ ∃ etag snapshot bytes,
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧ after.current key etag snapshot ∧
      PhysicalHistory framing objects owner session snapshot sealed ∧
      (∀ item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented snapshot sealed item) ∧
      ∀ item, PhysicalIdentityFact objects cursor.working (.work item) → PhysicalIdentityFact objects snapshot (.work item) := by
  obtain ⟨snapshot, bytes, rest, persisted, encoding, requestEq, snapshotHistory, catalogEq, kept⟩ :=
    encoded_preserves_work history preparation metadata encoded
  obtain ⟨stampedHistory, _⟩ := candidate_encoded_history history preparation metadata encoded
  obtain ⟨_, _, started⟩ := encode_capture encoded
  obtain ⟨_, preparedCall⟩ := StorageCommit.start_capture started
  have addressed := StorageAddress.agreed_key stampedHistory.invariant.owned stampedHistory.invariant.identified
    (StorageCommit.prepared_address preparedCall)
  have applied : HotCAS before (.tuple [a "cas", key, .binary bytes, cursor.etag]) result after := by
    rwa [requestEq] at cas
  obtain ⟨etag, stored⟩ := applied.current_candidate encoding
  refine ⟨addressed, etag, snapshot, bytes, encoding, requestEq, stored, snapshotHistory, kept, ?_⟩
  apply physical_work_transport (fun _ _ stored => stored)
    (snapshotHistory.invariant.owned.trans history.invariant.owned.symm)
    (snapshotHistory.invariant.identified.trans history.invariant.identified.symm)
  · intro value member
    simpa only [catalogEq] using member
  · exact fun item present => identity_fact_physical snapshotHistory.invariant.images
      (kept item (ValueSemantics.live_represents present))

end VerifiedKernel.Session.RevisionFence
