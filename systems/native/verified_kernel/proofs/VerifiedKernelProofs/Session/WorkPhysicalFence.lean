import VerifiedKernelProofs.Session.WorkPhysicalIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096

theorem normalize_session_id {state next : Term} {journal rest : List Term}
    (identified : state.get (a "session_id") ≠ nil)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) :
    next.get (a "session_id") = state.get (a "session_id") := by
  have initial := fillDefaults_get (key := "session_id") identified
  unfold Lifecycle.normalize at call
  repeat
    fail_if_success (bind_head_is call [write]; change (write _ _ >>= _) _ = _ at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨normalized, _, written, call⟩ := bind_ok call
  have selected := (write_field_frame (key := "session_id") written rfl).trans initial
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, activityWrite, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, providerWrite, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  exact (write_field_frame call rfl).trans
    ((write_field_frame providerWrite rfl).trans ((write_field_frame activityWrite rfl).trans selected))

theorem prepare_write_session_id {state next : Term} {journal rest : List Term}
    (identified : state.get (a "session_id") ≠ nil) (format : state.get (a "storage_format") = i 3)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    next.get (a "session_id") = state.get (a "session_id") := by
  unfold Lifecycle.prepareWrite at call
  obtain ⟨normalized, _, normalizedRead, call⟩ := bind_ok call
  have normalizedFormat := normalize_format format normalizedRead
  obtain ⟨value, _, valueRead, call⟩ := bind_ok call
  have same := (field_value valueRead).trans normalizedFormat
  subst value
  simp only [show (i 3 == i 1) = false from rfl, show (i 3 == i 2 || i 3 == i 3) = true from rfl,
    Bool.false_eq_true, ↓reduceIte] at call
  obtain ⟨written, _, writeCall, call⟩ := bind_ok call
  have equal : next = written := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using pure_ok call
  subst written
  exact (write_field_frame writeCall rfl).trans (normalize_session_id identified normalizedRead)

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation ArchivePublication
set_option Elab.async false

theorem candidate_physical_ledger {cursor : PendingRevision.Cursor}
    {key preparedState stamped token reasons activity revision flush epoch node saved request result restored etag : Term}
    {observations sealed catalog : List Term} {watermark : Int} {durable : HotSnapshots} {objects : Objects}
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (owned : cursor.working.get (a "agent_id") ≠ nil) (identified : cursor.working.get (a "session_id") ≠ nil)
    (header : LedgerHeader cursor.working) (supported : LedgerSupported cursor.working sealed)
    (backed : SealedImagesBacked objects cursor.working sealed)
    (catalogRead : cursor.working.get (a "segment_catalog") = list catalog)
    (through : cursor.working.get (a "archived_through") = i watermark)
    (valid : ∀ value ∈ catalog, validSegment value = true)
    (preparation : Preparation cursor key
      (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution cursor key
      (resident (some (prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ ∃ snapshot,
      durable key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      LedgerHeader snapshot ∧ LedgerSupported snapshot sealed ∧ SealedImagesBacked objects snapshot sealed ∧
      ∀ source, IdentityPresent (snapshot.get (a "input_dedupe")) (.binary source) →
        PhysicalIdentitySupported objects snapshot source := by
  obtain ⟨journal, rest, preparationCall⟩ := start_prepares preparation
  obtain ⟨normalized, same, owner⟩ := prepareWrite_owner owned format (Or.inr rfl) preparationCall
  have equal : preparedState = normalized := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst normalized
  have session := prepare_write_session_id identified format preparationCall
  have preparedCatalog := (prepareWrite_archive_fields format catalogRead through valid preparationCall).1
  have execution := metadata_executes metadata
  have keys := fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1
  have admitted := fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2
  have stampedFrames := commit_metadata_batch_frames execution keys admitted
  have stampedOwner := stampedFrames.2.2
  have stampedArchive := metadata_batch_archive_frame execution keys admitted
  obtain ⟨next, same, preparedFormat, preparedReady, _⟩ :=
    prepareWrite_modern format (Or.inr rfl) ready preparationCall
  have equal : preparedState = next := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst next
  obtain ⟨restoredEq, actual, bytes, persisted, _, _, actualCommitted⟩ := confirmed_capture encoded primitive resumed
  have preparedSupport := (prepare_write_ledger_supported ready format header supported preparationCall).1
  have preparedHeader := (prepare_write_ledger_supported ready format header supported preparationCall).2
  have supportActual := persistable_ledger_supported
    (metadata_ledger_supported execution keys admitted preparedReady preparedFormat preparedSupport) persisted
  have actualOwner := (persistable_owner persisted).trans (stampedOwner.trans owner)
  have actualSession := (persistable_queue_frame persisted).2.2.2.1.trans (stampedArchive.2.2.trans session)
  have actualCatalog := (persistable_archive_fields persisted).1.trans (stampedArchive.1.trans preparedCatalog)
  have actualBacked : SealedImagesBacked objects actual sealed := by
    intro record member
    have stored := backed record member
    change RecordImageBacked objects _ _ _ record at stored ⊢
    rw [actualOwner, actualSession, actualCatalog]
    rwa [catalogRead] at stored
  exact ⟨restoredEq, actual, actualCommitted,
    (persistable_preserves (queue_frame_ready stampedFrames.1 preparedReady) persisted).1,
    (persistable_queue_frame persisted).2.2.2.2.trans (stampedFrames.1.2.2.2.2.trans preparedFormat),
    persistable_ledger_header (batch_ledger_header execution preparedHeader) persisted, supportActual, actualBacked,
    fun source present => identity_supported_physical actualBacked (supportActual source present)⟩

end VerifiedKernel.Session.RevisionFence
