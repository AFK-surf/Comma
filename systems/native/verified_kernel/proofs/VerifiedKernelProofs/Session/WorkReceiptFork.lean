import VerifiedKernelProofs.Session.WorkReceiptInitial
import VerifiedKernelProofs.Session.WorkForkIdentity

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem normalize_fork_receipt_basis {entries : List (String × Term)} {messages journal rest before after sealed : List Term}
    {ledger next : Term}
    (queue : entries.reverse.find? (fun pair => pair.1 == "input_queue") = some ("input_queue", list []))
    (allocator : entries.reverse.find? (fun pair => pair.1 == "next_queue_id") = some ("next_queue_id", i 1))
    (ack : entries.reverse.find? (fun pair => pair.1 == "queue_ack_id") = some ("queue_ack_id", i 0))
    (records : entries.reverse.find? (fun pair => pair.1 == "messages") = some ("messages", list messages))
    (identities : entries.reverse.find? (fun pair => pair.1 == "input_dedupe") = some ("input_dedupe", ledger))
    (ledgerCall : Fork.forkDedupe messages before = .ok (ledger, after))
    (call : Lifecycle.normalize (Lifecycle.build entries) journal = .ok (next, rest)) : ReceiptSupported next sealed := by
  have ready : QueueReady (Lifecycle.build entries) :=
    ⟨queue_allocated_empty (build_value queue) (build_value allocator),
      ⟨[], 0, build_value queue, build_value ack, by simp⟩,
      by rw [build_value ack, build_value allocator]; decide⟩
  have modern : ((Lifecycle.build entries).get (a "input_dedupe")).get (a "__struct__") = a "Elixir.MapSet" := by
    rw [build_value identities]
    exact fork_dedupe_header ledgerCall
  exact normalize_receipt_supported ready modern
    (fork_basis_receipt_supported (build_value records) (build_value identities) ledgerCall) call

theorem rebuild_refs_receipt_supported {state next : Term} {journal rest sealed : List Term}
    (supported : ReceiptSupported state sealed) (call : rebuildRefs state journal = .ok (next, rest)) :
    ReceiptSupported next sealed := by
  unfold rebuildRefs at call
  repeat
    fail_if_success (head_is call [write]; change write _ _ _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  have ledger : LedgerFrame state next := write_field_frame call rfl
  have fields : WorkFieldsPreserved state next := ⟨write_field_frame call rfl, write_field_frame call rfl⟩
  intro source present
  rw [ledger] at present
  obtain ⟨originInput, fact, origin, represented⟩ := supported source present
  exact ⟨originInput, fact, origin, identity_fact_work_fields fields represented⟩

theorem fork_finish_receipt_supported {source session attrs next : Term} {copy : Bool}
    {messages facts results remapped clamped journal rest sealed : List Term}
    {lastSeq lastAck forkThrough nextId created : Term}
    (call : forkFinish source session attrs copy messages facts results remapped clamped
      lastSeq lastAck forkThrough nextId created journal = .ok (next, rest)) : ReceiptSupported next sealed := by
  cases copy <;> unfold forkFinish at call <;> simp only [Bool.false_eq_true, ↓reduceIte] at call
  all_goals repeat
    fail_if_success (bind_head_is call [Fork.forkDedupe]; change (Fork.forkDedupe _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  all_goals obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  all_goals repeat
    fail_if_success (bind_head_is call [Lifecycle.normalize]; change (Lifecycle.normalize _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  all_goals
    obtain ⟨child, _, normalized, call⟩ := bind_ok call
    exact rebuild_refs_receipt_supported (normalize_fork_receipt_basis rfl rfl rfl rfl rfl ledgerRead normalized) call

theorem current_fork_receipt_supported {source session attrs maxId next : Term} {journal rest sealed : List Term}
    (call : Fork.currentFork source session attrs maxId journal = .ok (next, rest)) : ReceiptSupported next sealed := by
  rw [current_fork_factor] at call
  unfold forkSelection at call
  repeat' first
    | exact fork_finish_receipt_supported call
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem modern_fork_receipt_supported {source args next : Term} {journal rest sealed : List Term}
    (format : source.get (a "storage_format") = i 3)
    (call : Fork.fork source args journal = .ok (.tuple [a "ok", next], rest)) : ReceiptSupported next sealed := by
  unfold Fork.fork at call
  split at call
  · obtain ⟨maxId, _, _, call⟩ := bind_ok call
    obtain ⟨stored, _, storedRead, call⟩ := bind_ok call
    have storedEq := (field_value storedRead).trans format
    subst stored
    simp only [show ((i 3).isInteger && decide (integerValue (i 3) ≥ 2)) = true from rfl, ↓reduceIte] at call
    obtain ⟨compacted, _, _, call⟩ := bind_ok call
    obtain ⟨below, _, _, call⟩ := bind_ok call
    rcases ite_ok_iff.mp call with ⟨_, rejected⟩ | ⟨_, accepted⟩
    · have impossible := pure_ok rejected
      simp [a] at impossible
    · obtain ⟨child, _, forked, returned⟩ := bind_ok accepted
      have same := pure_ok returned
      have equal : next = child := by simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
      rw [equal]
      exact current_fork_receipt_supported forked
  · exact (fail_ok call).elim

end VerifiedKernel.Session.WorkConservation
