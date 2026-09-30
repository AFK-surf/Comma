import VerifiedKernelProofs.Session.WorkLedgerOrigins
import VerifiedKernel.Session.Lifecycle
import VerifiedKernelProofs.Session.WorkLifecycle

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxRecDepth 4096
set_option maxHeartbeats 1000000

theorem normalize_dedupe_members {before after key : Term} {journal rest : List Term}
    (modern : before.get (a "__struct__") = a "Elixir.MapSet")
    (call : Lifecycle.normalizeDedupe before journal = .ok (after, rest)) :
    IdentityPresent after key ↔ IdentityPresent before key := by
  unfold Lifecycle.normalizeDedupe at call
  simp only [modern, show (a "Elixir.MapSet" == a "Elixir.MapSet") = true from rfl, ↓reduceIte] at call
  cases captured : before.get (a "map") <;> simp only [captured] at call
  all_goals try (obtain ⟨_, _, failed, _⟩ := bind_ok call; exact (fail_ok failed).elim)
  case map pairs =>
    rw [pure_ok call]
    unfold IdentityPresent
    rw [captured]
    change ((pairs.map (fun pair => (pair.1, list []))).any (fun pair => pair.1 == key) = true) ↔
      (pairs.any (fun pair => pair.1 == key) = true)
    simp only [List.any_map]
    rfl

def queueIdentityStep (acc : List Term) (item : Term) : KernelM (List Term) := do
  return acc ++ (← Lifecycle.queueDedupeKeys item)

theorem queue_identity_fold_origin {queue initial keys : List Term} {key : Term} {journal rest : List Term}
    (call : queue.foldlM queueIdentityStep initial journal = .ok (keys, rest)) (member : key ∈ keys) :
    key ∈ initial ∨ ∃ item ∈ queue, ∃ itemKeys before after,
      Lifecycle.queueDedupeKeys item before = .ok (itemKeys, after) ∧ key ∈ itemKeys := by
  induction queue generalizing initial journal with
  | nil => rw [pure_ok call] at member; exact Or.inl member
  | cons item queue ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    rcases ih tail with previous | ⟨found, included, itemKeys, before, after, read, member⟩
    · unfold queueIdentityStep at head
      obtain ⟨itemKeys, _, read, head⟩ := bind_ok head
      rw [pure_ok head] at previous
      rcases List.mem_append.mp previous with original | added
      · exact Or.inl original
      · exact Or.inr ⟨item, List.mem_cons_self, itemKeys, _, _, read, added⟩
    · exact Or.inr ⟨found, List.mem_cons_of_mem _ included, itemKeys, before, after, read, member⟩

def restoreIdentityStep (members key : Term) : KernelM Term :=
  if missing key then pure members else put members key (list [])

theorem restore_identity_fold_absent {keys : List Term} {before after key : Term} {journal rest : List Term}
    (absent : before.has key = false) (different : ∀ inserted ∈ keys, (inserted == key) = false)
    (call : keys.foldlM restoreIdentityStep before journal = .ok (after, rest)) : after.has key = false := by
  induction keys generalizing before journal with
  | nil => rw [pure_ok call]; exact absent
  | cons inserted keys ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    apply ih ?_ (fun value member => different value (List.mem_cons_of_mem _ member)) tail
    unfold restoreIdentityStep at head
    split at head
    · rw [pure_ok head]; exact absent
    · rw [put_ok head]
      exact put_preserves_absence absent (different _ List.mem_cons_self)

theorem restore_identity_fold_origin {keys : List Term} {before after key : Term} {journal rest : List Term}
    (call : keys.foldlM restoreIdentityStep before journal = .ok (after, rest)) (present : after.has key = true) :
    before.has key = true ∨ ∃ inserted ∈ keys, (inserted == key) = true := by
  exact identity_origin_of_absence
    (before := .map [(a "map", before)]) (after := .map [(a "map", after)])
    (fun absent different => restore_identity_fold_absent absent different call) present

/-- Reload adds ledger keys only from the previous ledger or the pending queue that it actually reads. -/
theorem preserve_dedupe_origin {state ledger : Term} {source : ByteArray} {journal rest : List Term}
    (call : Lifecycle.preserveDedupe state journal = .ok (ledger, rest))
    (present : IdentityPresent ledger (.binary source)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) ∨
      ∃ item ∈ wrap (state.get (a "input_queue")), ∃ keys before after,
        Lifecycle.queueDedupeKeys item before = .ok (keys, after) ∧ .binary source ∈ keys := by
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
    change members.has (.binary source) = true at present
    rcases restore_identity_fold_origin restored present with original | ⟨inserted, included, same⟩
    · left
      unfold IdentityPresent
      rw [captured]
      obtain ⟨pair, included, same⟩ := List.any_eq_true.mp original
      exact List.any_eq_true.mpr ⟨pair, (List.mem_filter.mp included).1, same⟩
    · have equal := beq_binary_right same
      subst inserted
      exact Or.inr ((queue_identity_fold_origin collected included).resolve_left (by simp))

theorem normalize_ledger_origin {state next : Term} {source : ByteArray} {journal rest : List Term}
    (modern : (state.get (a "input_dedupe")).get (a "__struct__") = a "Elixir.MapSet")
    (call : Lifecycle.normalize state journal = .ok (next, rest))
    (present : IdentityPresent (next.get (a "input_dedupe")) (.binary source)) :
    IdentityPresent (state.get (a "input_dedupe")) (.binary source) ∨
      ∃ item ∈ wrap (next.get (a "input_queue")), ∃ keys before after,
        Lifecycle.queueDedupeKeys item before = .ok (keys, after) ∧ .binary source ∈ keys := by
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
  rcases preserve_dedupe_origin preserved present with original | queued
  · rw [carried] at original
    exact Or.inl ((normalize_dedupe_members modern ledgerRead).mp original)
  · rw [queueFrame]
    exact Or.inr queued

end VerifiedKernel.Session.WorkConservation
