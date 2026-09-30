import VerifiedKernelProofs.Session.WorkIdentityInvariant
import VerifiedKernelProofs.Session.WorkReloadLedger

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem normalize_ledger_supported {state next : Term} {journal rest sealed : List Term}
    (ready : QueueReady state)
    (modern : (state.get (a "input_dedupe")).get (a "__struct__") = a "Elixir.MapSet")
    (supported : LedgerSupported state sealed)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) : LedgerSupported next sealed := by
  intro source present
  rcases normalize_ledger_origin modern call present with old | ⟨item, included, keys, before, after, read, member⟩
  · obtain ⟨event, fact, origin, represented⟩ := supported source old
    exact ⟨event, fact, origin, identity_fact_preserves
      (fun _ work => ValueSemantics.normalize_preserves ready call work)
      (fun _ stored => ValueSemantics.normalize_records ready call stored) represented⟩
  · have nextReady := (normalize_work ready call).1
    obtain ⟨⟨queue, _, queueRead, _, _, canonical, _, _⟩, _⟩ := nextReady
    rw [queueRead] at included
    change item ∈ queue at included
    exact ⟨item, .work item, .restoredQueue read member (canonical item included),
      Or.inl ⟨queue, item, queueRead, included, ValueSemantics.SameWork.refl _⟩⟩

theorem fork_basis_ledger_supported {state ledger : Term} {messages journal rest sealed : List Term}
    (read : state.get (a "messages") = list messages)
    (ledgerRead : state.get (a "input_dedupe") = ledger)
    (call : Fork.forkDedupe messages journal = .ok (ledger, rest)) : LedgerSupported state sealed := by
  intro source present
  rw [ledgerRead] at present
  obtain ⟨record, included, field, allowed, identity⟩ := fork_dedupe_origin call present
  exact ⟨record, .record record, .forkedRecord allowed identity,
    identity_record_present ⟨messages, read, included⟩ sealed⟩

theorem normalize_empty_ledger {state next : Term} {journal rest : List Term}
    (ready : QueueReady state) (queue : state.get (a "input_queue") = list [])
    (ledger : state.get (a "input_dedupe") = Lifecycle.emptySet)
    (call : Lifecycle.normalize state journal = .ok (next, rest)) :
    ∀ source, IdentityAbsent (next.get (a "input_dedupe")) (.binary source) := by
  obtain ⟨_, ⟨original, kept, before, after, permutation⟩, _⟩ := normalize_work ready call
  have originalEmpty : original = [] := Term.list.inj (before.symm.trans queue)
  subst original
  have keptEmpty : kept = [] := List.Perm.eq_nil permutation
  subst kept
  intro source
  rcases identity_present_or_absent (next.get (a "input_dedupe")) (.binary source) with present | absent
  · have modern : (state.get (a "input_dedupe")).get (a "__struct__") = a "Elixir.MapSet" := by rw [ledger]; rfl
    rcases normalize_ledger_origin modern call present with old | ⟨item, included, _⟩
    · rw [ledger] at old
      cases old
    · rw [after] at included
      cases included
  · exact absent

theorem create_empty_ledger {state args next : Term} {journal rest : List Term}
    (call : Lifecycle.create state args journal = .ok (next, rest)) :
    ∀ source, IdentityAbsent (next.get (a "input_dedupe")) (.binary source) := by
  unfold Lifecycle.create at call
  split at call
  · repeat
      fail_if_success (head_is call [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (next, rest) at call)
      obtain ⟨_, _, _, call⟩ := bind_ok call
    exact normalize_empty_ledger (build_ready rfl rfl rfl)
      ((build_get (key := "input_queue") rfl).trans rfl)
      ((build_get (key := "input_dedupe") rfl).trans rfl) call
  · exact (fail_ok call).elim

theorem create_ledger_supported {state args next : Term} {journal rest sealed : List Term}
    (call : Lifecycle.create state args journal = .ok (next, rest)) : LedgerSupported next sealed := by
  intro source present
  have absent := create_empty_ledger call source
  unfold IdentityAbsent at absent
  unfold IdentityPresent at present
  rw [absent] at present
  contradiction

end VerifiedKernel.Session.WorkConservation
