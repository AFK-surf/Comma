import VerifiedKernelProofs.Session.WorkRawOrdinary

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem shallowStringify_keys {raw normalized : Term} {journal rest : List Term}
    (call : shallowStringify raw journal = .ok (normalized, rest)) : BinaryKeys normalized := by
  unfold shallowStringify at call
  obtain ⟨fields, afterRead, read, call⟩ := bind_ok call
  split at call
  · rename_i binary
    rw [pure_ok call]
    unfold entries at read
    split at read
    · have same := pure_ok read
      subst fields
      exact binary
    · exact (fail_ok read).elim
  · obtain ⟨items, folded, _⟩ := enumFold_ok call
    apply foldlM_property _ (show BinaryKeys empty from rfl) folded
    intro state pair next first last before step
    split at step
    · obtain ⟨key, _, converted, step⟩ := bind_ok step
      exact put_binary_keys before (stringChars_binary converted) step
    · exact (fail_ok step).elim

theorem foldlM_property_members {property : Term → Prop} {f : Term → Term → KernelM Term}
    {items : List Term} {state next : Term} {journal rest : List Term}
    (before : property state)
    (correct : ∀ item ∈ items, ∀ state next journal rest, property state →
      f state item journal = .ok (next, rest) → property next)
    (call : items.foldlM f state journal = .ok (next, rest)) : property next := by
  induction items generalizing state journal with
  | nil => rw [pure_ok call]; exact before
  | cons item items ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨middle, _, step, tail⟩ := bind_ok call
    exact ih (correct item List.mem_cons_self _ _ _ _ before step)
      (fun item member => correct item (List.mem_cons_of_mem _ member)) tail

/-- The host checks all type-key aliases, not a preferred key or one map ordering.
These are type comparisons only; no work-preservation predicate occurs here. -/
def EventTypeKeysChecked (raw : Term) : Prop :=
  (BinaryKeys raw → OrdinaryKind (raw.get (b "type"))) ∧
  ∀ items, enumeratedItems raw = some items → ∀ key value,
    .tuple [key, value] ∈ items → ∀ journal rest,
      stringChars key journal = .ok (b "type", rest) → OrdinaryKind value

theorem get_put_converted_other (state value converted : Term)
    (binary : converted.isBinary = true) (different : converted ≠ b "type") :
    (state.put converted value).get (b "type") = state.get (b "type") := by
  have reverse : (b "type" == converted) = false := by
    apply Bool.eq_false_iff.mpr
    intro same
    exact different (binary_term_beq rfl binary same).symm
  cases state with
  | map fields =>
    simp only [Term.put, Term.get, List.find?_cons, binary_ne_false different]
    rw [find?_filter_of_imp]
    intro pair matched
    have same := binary_beq_true matched
    simp only [same, reverse, Bool.not_false]
  | _ => simp [Term.put, Term.get, binary_ne_false different]

theorem checked_keys_raw_ordinary {raw : Term} (checked : EventTypeKeysChecked raw) : RawOrdinary raw := by
  intro normalized journal rest call
  unfold shallowStringify at call
  obtain ⟨fields, afterRead, read, call⟩ := bind_ok call
  split at call
  · rename_i binary
    rw [pure_ok call]
    apply checked.1
    unfold entries at read
    split at read
    · have same := pure_ok read
      subst fields
      exact binary
    · exact (fail_ok read).elim
  · obtain ⟨items, enumeration, folded⟩ := enumFold_actual_items call
    apply foldlM_property_members (property := fun state => OrdinaryKind (state.get (b "type")))
      (by simp +decide [OrdinaryKind, empty, Term.get, b, Term.text]) _ folded
    intro item member state next first last before step
    split at step
    · rename_i rawPair key value
      obtain ⟨converted, _, convertedKey, stored⟩ := bind_ok step
      rw [put_ok stored]
      by_cases same : converted = b "type"
      · subst converted
        rw [get_put_binary_same]
        apply checked.2 items enumeration key value
        · exact member
        · exact convertedKey
      · rw [get_put_converted_other _ _ _ (stringChars_binary convertedKey) same]
        exact before
    · exact (fail_ok step).elim

end VerifiedKernel.Session.WorkConservation
