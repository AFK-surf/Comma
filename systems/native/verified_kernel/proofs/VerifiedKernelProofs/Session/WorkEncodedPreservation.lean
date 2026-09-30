import VerifiedKernelProofs.Session.WorkPhysicalEncoded

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation ArchivePublication
set_option Elab.async false

/-- Work preservation belongs to the encoded candidate, before delivery of any CAS reply. -/
theorem encoded_preserves_work {framing : CodecFraming} {objects : Objects} {owner session : ByteArray}
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
    ∃ snapshot bytes rest,
      Lifecycle.persistable stamped [] = .ok (snapshot, rest) ∧
      ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      request = .tuple [a "cas", key, .binary bytes, cursor.etag] ∧
      PhysicalHistory framing objects owner session snapshot sealed ∧
      snapshot.get (a "segment_catalog") = cursor.working.get (a "segment_catalog") ∧
      ∀ item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented snapshot sealed item := by
  obtain ⟨_, snapshot, bytes, rest, persisted, encoding, requestEq, snapshotHistory⟩ :=
    candidate_encoded_history history preparation metadata encoded
  obtain ⟨journal, remaining, preparedCall⟩ := start_prepares preparation
  have preparedHistory := history.prepare preparedCall
  obtain ⟨_, _, kept⟩ := ValueSemantics.metadata_work (metadata_executes metadata)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2)
    preparedHistory.invariant.history.invariant.ready
  obtain ⟨catalog, watermark, read, through, valid⟩ := history.invariant.archive
  have preparedFields := prepareWrite_archive_fields history.invariant.history.invariant.format
    read through valid preparedCall
  have metadataFields := metadata_batch_archive_frame (metadata_executes metadata)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2)
  have catalogEq := (persistable_archive_fields persisted).1.trans
    (metadataFields.1.trans (preparedFields.1.trans read.symm))
  exact ⟨snapshot, bytes, rest, persisted, encoding, requestEq, snapshotHistory, catalogEq,
    fun item represented => ValueSemantics.work_fields_preserves (persistable_work_fields persisted)
      (kept sealed item (ValueSemantics.prepareWrite_preserves history.invariant.history.invariant.ready
        history.invariant.history.invariant.format preparedCall represented))⟩

end VerifiedKernel.Session.RevisionFence
