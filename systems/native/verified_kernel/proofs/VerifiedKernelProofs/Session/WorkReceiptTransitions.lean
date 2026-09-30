import VerifiedKernelProofs.Session.WorkReceiptMaterialized
import VerifiedKernelProofs.Session.WorkReceiptFork
import VerifiedKernelProofs.Session.WorkArchiveIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem metadata_receipt_supported {state next : Term} {events sealed : List Term}
    (execution : ResidentBatch state events next)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (metadata : ∀ event ∈ events, CommitMetadata event)
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (supported : ReceiptSupported state sealed) : ReceiptSupported next sealed :=
  nonretiring_batch_receipt_supported execution ready format canonical
    (fun event member => commit_metadata_nonretiring (metadata event member)) supported

theorem materialize_framed_receipt_supported {state projected next : Term} {events journal rest sealed : List Term}
    {limit : Int} {wake : Bool} {hwm : Term} (ready : QueueReady state)
    (queueSame : projected.get (a "input_queue") = state.get (a "input_queue"))
    (ackSame : projected.get (a "queue_ack_id") = state.get (a "queue_ack_id"))
    (sessionSame : state.get (a "session_id") = projected.get (a "session_id"))
    (planned : StateQuery.materialize projected limit journal = .ok (.tuple [list events, Term.bool wake, hwm], rest))
    (execution : ResidentBatch state events next) (supported : ReceiptSupported state sealed) : ReceiptSupported next sealed := by
  have routed := materialize_routed planned
  rw [← sessionSame] at routed
  obtain ⟨reduced, _⟩ := resident_routed_reduces execution routed
  have ordinary := materialize_ordinary planned
  have work := materialize_framed_work ready queueSame ackSame sessionSame planned execution
  intro source present
  rcases reduced_batch_new_receipt_records reduced ordinary (materialize_no_append planned) present with
    old | ⟨event, _, record, origin, stored⟩
  · obtain ⟨originInput, fact, origin, represented⟩ := supported source old
    exact ⟨originInput, fact, origin, identity_fact_preserves (work.2 sealed)
      (fun _ stored => record_survives (resident_reduced_extends reduced ordinary) stored) represented⟩
  · exact ⟨event, .record record, origin, identity_record_present stored sealed⟩

theorem prepare_write_receipt_supported {state next : Term} {journal rest sealed : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (header : LedgerHeader state) (supported : ReceiptSupported state sealed)
    (call : Lifecycle.prepareWrite state journal = .ok (.tuple [a "ok", next], rest)) :
    ReceiptSupported next sealed ∧ LedgerHeader next := by
  unfold Lifecycle.prepareWrite at call
  obtain ⟨normalized, _, normalizedRead, call⟩ := bind_ok call
  have normalizedSupport := normalize_receipt_supported ready header supported normalizedRead
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

theorem archive_receipt_supported {state event next : Term} {live sealed dropped kept journal rest : List Term}
    (before : state.get (a "messages") = list live) (partition : live = dropped ++ kept)
    (after : next.get (a "messages") = list kept)
    (supported : ReceiptSupported state sealed)
    (call : archiveAdvance state event journal = .ok (next, rest)) : ReceiptSupported next (sealed ++ dropped) := by
  have ledger : LedgerFrame state next := by
    unfold archiveAdvance at call
    ledger_frame_walk call
  intro source present
  rw [ledger] at present
  obtain ⟨originInput, fact, origin, stored⟩ := supported source present
  exact ⟨originInput, fact, origin,
    identity_fact_archive (archive_preserves_queue call) before partition after stored⟩

end VerifiedKernel.Session.WorkConservation
