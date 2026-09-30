import VerifiedKernelProofs.Session.WorkReceiptSeed
import VerifiedKernelProofs.Session.WorkReloadLedger

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

/-- Reload adds ledger keys only from the previous ledger or the pending queue that it actually reads. -/
theorem preserve_receipt_origin {state ledger : Term} {source : Term} {journal rest : List Term}
    (call : Lifecycle.preserveDedupe state journal = .ok (ledger, rest))
    (present : IdentityPresent ledger (source)) :
    IdentityPresent (state.get (a "input_dedupe")) (source) ∨
      ∃ item ∈ wrap (state.get (a "input_queue")), ∃ keys before after,
        Lifecycle.queueDedupeKeys item before = .ok (keys, after) ∧ ReceiptMatches source keys := by
  unfold Lifecycle.preserveDedupe at call
  obtain ⟨queue, _, queueRead, call⟩ := bind_ok call
  have queueEq := field_value queueRead
  subst queue
  obtain ⟨keys, _, collected, call⟩ := bind_ok call
  obtain ⟨previous, _, previousRead, call⟩ := bind_ok call
  have previousEq := field_value previousRead
  subst previous
  cases captured : (state.get (a "input_dedupe")).get (a "map") <;> simp only [captured] at call
  all_goals try exact (fail_ok call).elim
  case map pairs =>
    obtain ⟨members, _, restored, call⟩ := bind_ok call
    rw [pure_ok call] at present
    change members.has (source) = true at present
    rcases restore_identity_fold_origin restored present with original | ⟨inserted, included, same⟩
    · left
      unfold IdentityPresent
      rw [captured]
      obtain ⟨pair, included, same⟩ := List.any_eq_true.mp original
      exact List.any_eq_true.mpr ⟨pair, (List.mem_filter.mp included).1, same⟩
    · obtain ⟨item, member, keys, before, after, read, included⟩ :=
        (queue_identity_fold_origin collected included).resolve_left (by simp)
      exact Or.inr ⟨item, member, keys, before, after, read, inserted, included, same⟩

theorem normalize_receipt_origin {state next : Term} {source : Term} {journal rest : List Term}
    (modern : (state.get (a "input_dedupe")).get (a "__struct__") = a "Elixir.MapSet")
    (call : Lifecycle.normalize state journal = .ok (next, rest))
    (present : IdentityPresent (next.get (a "input_dedupe")) (source)) :
    IdentityPresent (state.get (a "input_dedupe")) (source) ∨
      ∃ item ∈ wrap (next.get (a "input_queue")), ∃ keys before after,
        Lifecycle.queueDedupeKeys item before = .ok (keys, after) ∧ ReceiptMatches source keys := by
  have ledgerNonempty : state.get (a "input_dedupe") ≠ nil := by
    intro absent
    rw [absent] at modern
    simp [nil, Term.get, a] at modern
  have defaultFrame := fillDefaults_get ledgerNonempty
  unfold Lifecycle.normalize at call
  repeat
    fail_if_success (bind_head_is call [Lifecycle.normalizeDedupe]; change (Lifecycle.normalizeDedupe _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨value, _, read, call⟩ := bind_ok call
    try (have same := field_value read; subst value)
  obtain ⟨normalizedLedger, _, ledgerRead, call⟩ := bind_ok call
  rw [defaultFrame] at ledgerRead
  repeat
    fail_if_success (bind_head_is call [write]; change (write _ _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨normalized, _, written, call⟩ := bind_ok call
  have ledgerWritten : normalized.get (a "input_dedupe") = normalizedLedger := by
    iterate 8 obtain ⟨_, written⟩ := write_cons written
    exact (write_field_frame written rfl).trans (get_put_same _ _ _)
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨active, _, activityWrite, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨providers, _, providerWrite, call⟩ := bind_ok call
  have carried : providers.get (a "input_dedupe") = normalizedLedger :=
    (write_field_frame providerWrite rfl).trans
      ((write_field_frame activityWrite rfl).trans ledgerWritten)
  obtain ⟨ledger, _, preserved, call⟩ := bind_ok call
  have resultLedger : next.get (a "input_dedupe") = ledger := by
    obtain ⟨_, tail⟩ := write_cons call
    rw [pure_ok tail]
    exact get_put_same _ _ _
  have queueFrame : next.get (a "input_queue") = providers.get (a "input_queue") :=
    write_field_frame call rfl
  rw [resultLedger] at present
  rcases preserve_receipt_origin preserved present with original | queued
  · rw [carried] at original
    exact Or.inl ((normalize_dedupe_members modern ledgerRead).mp original)
  · rw [queueFrame]
    exact Or.inr queued

end VerifiedKernel.Session.WorkConservation
