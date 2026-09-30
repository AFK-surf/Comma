import VerifiedKernelProofs.Session.WorkDriverFencedBatch
import VerifiedKernelProofs.Session.WorkDriverRawMetadata

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

theorem raw_fence_prepared {cursor : PendingRevision.Cursor} {observations : List Term}
    {continuation key state : Term}
    (trace : ObservationTrace
      (resident (writeFenced cursor continuation).1 (a "fence_start") (.tuple [key, list observations]))
      (some (fencingCursor (.pending cursor) continuation
        (RevisionFence.prepared cursor key state)), .tuple [a "prepared"])) :
    RevisionFence.Preparation cursor key
      (RevisionFence.resident (some cursor.pack) (a "start") (.tuple [key, list observations])) state := by
  simp only [writeFenced] at trace
  rw [fence_start_captured] at trace
  exact fence_preparation_reflect
    (fence_preparation_observations_reflect (context := .pending cursor)
      (continuation := continuation) (cursor := cursor) (key := key)
      (observations := observations) trace)

theorem raw_fence_stamped {cursor : PendingRevision.Cursor}
    {continuation key before after token reasons activity revision flush epoch node : Term}
    (trace : BatchTrace
      (resident (some (fencingCursor (.pending cursor) continuation
        (RevisionFence.prepared cursor key before))) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node]))
      (some (fencingCursor (.pending cursor) continuation (stampedFence cursor key after)),
        .tuple [a "stamped"])) :
    RevisionFence.MetadataExecution cursor key
      (RevisionFence.resident (some (RevisionFence.prepared cursor key before)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) after := by
  have typed := metadata_trace_reflect (trace := trace) (by
    simp only [fencingCursor]
    rw [stamp_captured]
    exact metadata_next_valid (.pending cursor) continuation cursor key before
      (RevisionFence.metadataEvents token reasons activity revision flush epoch node))
  simp only [fencingCursor] at typed
  rw [stamp_captured] at typed
  exact fence_metadata_reflect typed

/-- The public fence loop commits the preserved work under its issued key, bytes, and expected ETag. -/
theorem issued_write_preserves {cursor : PendingRevision.Cursor}
    {continuation key preparedState stamped token reasons activity revision flush epoch node
      saved requestedKey requestedBytes requestedBase result confirmed : Term}
    {observations : List Term} {durable : ArchivePublication.HotSnapshots}
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (preparation : ObservationTrace
      (resident (writeFenced cursor continuation).1 (a "fence_start") (.tuple [key, list observations]))
      (some (fencingCursor (.pending cursor) continuation
        (RevisionFence.prepared cursor key preparedState)), .tuple [a "prepared"]))
    (metadata : BatchTrace
      (resident (some (fencingCursor (.pending cursor) continuation
        (RevisionFence.prepared cursor key preparedState))) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node]))
      (some (fencingCursor (.pending cursor) continuation (stampedFence cursor key stamped)),
        .tuple [a "stamped"]))
    (encoded : resident (some (fencingCursor (.pending cursor) continuation
      (stampedFence cursor key stamped))) (a "encode") nil =
        (some saved, .tuple [a "cas", requestedKey, requestedBytes, requestedBase]))
    (primitive : ArchivePublication.SnapshotCASMeaning
      (.tuple [a "cas", requestedKey, requestedBytes, requestedBase]) result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some confirmed, .tuple [a "committed"])) :
    ∃ etag snapshot bytes,
      confirmed = .tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed stamped etag).pack, continuation] ∧
      (.tuple [a "cas", requestedKey, requestedBytes, requestedBase] : Term) =
        .tuple [a "cas", key, .binary bytes, cursor.etag] ∧
      durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented cursor.working sealed item →
        ValueSemantics.Represented snapshot sealed item := by
  obtain ⟨journal, rest, preparationCall⟩ := RevisionFence.start_prepares (raw_fence_prepared preparation)
  obtain ⟨normalized, same, preparedFormat, preparedReady, _⟩ :=
    prepareWrite_modern format (Or.inr rfl) ready preparationCall
  have equal : preparedState = normalized := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst normalized
  obtain ⟨stampedReady, stampedFormat, kept⟩ := ValueSemantics.metadata_work
    (RevisionFence.metadata_executes (raw_fence_stamped metadata))
    (fun event member => (RevisionFence.metadata_admitted token reasons activity revision flush epoch node event member).1)
    (fun event member => (RevisionFence.metadata_admitted token reasons activity revision flush epoch node event member).2)
    preparedReady
  obtain ⟨etag, snapshot, bytes, confirmedEq, persisted, _, issued, stored⟩ := issued_confirmation encoded primitive resumed
  refine ⟨etag, snapshot, bytes, confirmedEq, issued, stored, (persistable_preserves stampedReady persisted).1,
    (persistable_queue_frame persisted).2.2.2.2.trans (stampedFormat.trans preparedFormat), ?_⟩
  intro sealed item represented
  exact ValueSemantics.work_fields_preserves (persistable_work_fields persisted)
    (kept sealed item (ValueSemantics.prepareWrite_preserves ready format preparationCall represented))

end VerifiedKernel.Session.CommandDriver
