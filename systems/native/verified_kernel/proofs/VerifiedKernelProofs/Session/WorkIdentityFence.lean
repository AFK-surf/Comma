import VerifiedKernelProofs.Session.WorkPlannedIdentity
import VerifiedKernelProofs.Session.WorkIdentityInitial
import VerifiedKernelProofs.Session.WorkRevisionFence

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem prepare_write_ledger_supported {state next : Term} {journal rest sealed : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (header : LedgerHeader state) (supported : LedgerSupported state sealed)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    LedgerSupported next sealed ∧ LedgerHeader next := by
  unfold Lifecycle.prepareWrite at call
  obtain ⟨normalized, _, normalizedRead, call⟩ := bind_ok call
  have normalizedSupport := normalize_ledger_supported ready header supported normalizedRead
  have normalizedHeader := normalize_ledger_header normalizedRead
  have normalizedFormat := normalize_format format normalizedRead
  obtain ⟨value, _, valueRead, call⟩ := bind_ok call
  have same := (field_value valueRead).trans normalizedFormat
  subst value
  have notLegacy : (i 3 == i 1) = false := rfl
  have modern : (i 3 == i 2 || i 3 == i 3) = true := rfl
  simp only [notLegacy, modern, Bool.false_eq_true, ↓reduceIte] at call
  obtain ⟨written, _, writeCall, call⟩ := bind_ok call
  have same := pure_ok call
  have same : next = written := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst written
  have ledger : LedgerFrame normalized next := write_field_frame writeCall rfl
  have fields : WorkFieldsPreserved normalized next :=
    ⟨write_field_frame writeCall rfl, write_field_frame writeCall rfl⟩
  refine ⟨?_, ?_⟩
  · intro source present
    rw [ledger] at present
    obtain ⟨event, fact, origin, represented⟩ := normalizedSupport source present
    exact ⟨event, fact, origin, identity_fact_work_fields fields represented⟩
  · unfold LedgerHeader
    rw [ledger]
    exact normalizedHeader

end VerifiedKernel.Session.WorkConservation

namespace VerifiedKernel.Session.RevisionFence
open Data WorkConservation
set_option Elab.async false

theorem candidate_ledger_supported {cursor : PendingRevision.Cursor}
    {key preparedState stamped token reasons activity revision flush epoch node saved request result restored etag : Term}
    {observations sealed : List Term} {durable : ArchivePublication.HotSnapshots}
    (ready : QueueReady cursor.working) (format : cursor.working.get (a "storage_format") = i 3)
    (header : LedgerHeader cursor.working) (supported : LedgerSupported cursor.working sealed)
    (preparation : Preparation cursor key
      (resident (some cursor.pack) (a "start") (.tuple [key, list observations])) preparedState)
    (metadata : MetadataExecution cursor key
      (resident (some (prepared cursor key preparedState)) (a "stamp")
        (.tuple [token, reasons, activity, revision, flush, epoch, node])) stamped)
    (encoded : resident (some (.tuple [a "session_fence_stamped", cursor.pack, key, stamped]))
      (a "encode") nil = (some saved, request))
    (primitive : ArchivePublication.SnapshotCASMeaning request result durable)
    (resumed : resident (some saved) (a "cas_result") result = (some restored, .tuple [a "ok", etag])) :
    restored = stamped ∧ ∃ snapshot,
      durable key etag snapshot ∧ LedgerSupported snapshot sealed ∧ LedgerHeader snapshot := by
  obtain ⟨journal, rest, preparationCall⟩ := start_prepares preparation
  obtain ⟨preparedSupport, preparedHeader⟩ :=
    prepare_write_ledger_supported ready format header supported preparationCall
  obtain ⟨normalized, same, preparedFormat, preparedReady, _⟩ :=
    prepareWrite_modern format (Or.inr rfl) ready preparationCall
  have equal : preparedState = normalized := by
    simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst normalized
  have execution := metadata_executes metadata
  have keys := fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).1
  have admitted := fun event member => (metadata_admitted token reasons activity revision flush epoch node event member).2
  have stampedSupport := metadata_ledger_supported execution keys admitted preparedReady preparedFormat preparedSupport
  have stampedHeader := batch_ledger_header execution preparedHeader
  obtain ⟨restoredEq, snapshot, bytes, persisted, _, _, committed⟩ := confirmed_capture encoded primitive resumed
  exact ⟨restoredEq, snapshot, committed, persistable_ledger_supported stampedSupport persisted,
    persistable_ledger_header stampedHeader persisted⟩

end VerifiedKernel.Session.RevisionFence
