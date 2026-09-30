import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkLedgerOrigins
import VerifiedKernelProofs.Session.WorkSemanticExecution

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem new_identity_not_same {before after : Term} {source : ByteArray}
    (absent : IdentityAbsent (before.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (after.get (a "input_dedupe")) (.binary source)) : after ≠ before := by
  intro same
  subst after
  unfold IdentityPresent at present
  unfold IdentityAbsent at absent
  rw [absent] at present
  contradiction

theorem queue_append_identity_origin {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (call : queueAppend state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ payload keys before middle after,
      stringify ((event.get (b "payload")).default empty) before = .ok (payload, middle) ∧
      queueKeys event payload (event.get (b "kind")) middle = .ok (keys, after) ∧ .binary source ∈ keys := by
  classical
  apply Classical.byContradiction
  intro missing
  have gone := queueAppend_ledger_absent absent (by
    intro payload keys before middle after normalized read inserted included
    cases same : (inserted == .binary source) with
    | false => rfl
    | true =>
      have equal := beq_binary_right same
      subst inserted
      exact (missing ⟨payload, keys, before, middle, after, normalized, read, included⟩).elim) call
  unfold IdentityAbsent at gone
  unfold IdentityPresent at present
  rw [gone] at present
  contradiction

/-- A newly inserted queue identity has the same reducer's full payload fact, not just a ledger entry. -/
theorem queue_append_new_identity_fact {state event next : Term} {source : ByteArray} {journal rest : List Term}
    (ready : QueueReady state) (call : queueAppend state event journal = .ok (next, rest))
    (absent : IdentityAbsent (state.get (a "input_dedupe")) (.binary source))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    ∃ item payload keys before middle after,
      stringify ((event.get (b "payload")).default empty) before = .ok (payload, middle) ∧
      queueKeys event payload (event.get (b "kind")) middle = .ok (keys, after) ∧ .binary source ∈ keys ∧
      item.get (b "payload") = payload ∧ CanonicalQueueItem item ∧
      ∀ sealed, ValueSemantics.Represented next sealed item := by
  obtain ⟨_, id, _, nextId, positive, _⟩ := ready.1
  rcases queueAppend_allocates nextId call with same | ⟨item, items, payload, j₁, j₂, j₃, j₄,
      normalized, _, allocated, queue, _⟩
  · exact (new_identity_not_same absent present same).elim
  · obtain ⟨actualPayload, keys, before, middle, after, actualNormalized, keyRead, included⟩ :=
      queue_append_identity_origin call absent present
    have same := stringify_same_results normalized actualNormalized
    subst actualPayload
    exact ⟨item, payload, keys, before, middle, after, actualNormalized, keyRead, included,
      allocated.2.2, allocated_canonical allocated positive,
      fun sealed => Or.inl ⟨items ++ [item], item, queue, List.mem_append_right _ (by simp),
        ValueSemantics.SameWork.refl item⟩⟩

end VerifiedKernel.Session.WorkConservation
