import VerifiedKernelProofs.Session.WorkPhysicalHistory

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- The encoded candidate has a physical history even if the storage reply is lost. -/
theorem candidate_encoded_history {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
    {cursor : PendingRevision.Cursor} {sealed observations : List Term}
    {key preparedState stamped token reasons activity revision flush epoch node saved request : Term}
    (history : PhysicalHistory framing objects owner session cursor.working sealed)
    (preparation : Preparation cursor key
      (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution cursor key
      (resident (some (prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request)) :
    PhysicalHistory framing objects owner session stamped sealed ∧ ∃ snapshot bytes rest,
      Lifecycle.persistable stamped [] = .ok (snapshot, rest) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧
      PhysicalHistory framing objects owner session snapshot sealed := by
  obtain ⟨journal, rest, preparedCall⟩ := start_prepares preparation
  have preparedHistory := history.prepare preparedCall
  have stampedHistory := preparedHistory.metadata (metadata_executes metadata)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2)
  obtain ⟨commit, _, started⟩ := encode_capture encoded
  obtain ⟨_, prepared⟩ := StorageCommit.start_capture started
  obtain ⟨snapshot, bytes, rest, persisted, encoding, requestEq, _⟩ := storage_commit_candidate prepared
  exact ⟨stampedHistory, snapshot, bytes, rest, persisted, encoding, requestEq, stampedHistory.persist persisted⟩

end VerifiedKernel.Session.RevisionFence
