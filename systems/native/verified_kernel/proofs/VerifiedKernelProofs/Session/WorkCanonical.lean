import VerifiedKernelProofs.Session.AppendOnly.Core
import VerifiedKernel.Session.Command

namespace VerifiedKernel.Session.WorkConservation
open Data

def BinaryKeys : Term → Prop
  | .map fields => fields.all (fun pair => pair.1.isBinary) = true
  | _ => True

theorem stringChars_binary {value result : Term} {j r : List Term}
    (h : stringChars value j = .ok (result, r)) : result.isBinary = true := by
  unfold stringChars at h
  repeat' first
    | (have same := pure_ok h; subst result; rfl)
    | (exact (fail_ok h).elim)
    | split at h
    | dsimp only at h
  rename_i value values
  cases chars : charData (.list values) <;> simp only [chars] at h
  · exact (fail_ok h).elim
  · have same := pure_ok h
    subst result
    rfl

theorem put_binary_keys {s key value t : Term} {j r : List Term}
    (before : BinaryKeys s) (binary : key.isBinary = true)
    (h : put s key value j = .ok (t, r)) : BinaryKeys t := by
  rw [put_ok h]
  cases s with
  | map fields =>
    simp only [Term.put, BinaryKeys, List.all_cons, binary, Bool.true_and]
    apply List.all_eq_true.mpr
    intro pair member
    exact List.all_eq_true.mp before pair (List.mem_filter.mp member).1
  | _ => simp only [Term.put, BinaryKeys, List.all_cons, binary, List.all_nil, Bool.and_self]

theorem foldlM_property {property : Term → Prop} {f : Term → Term → KernelM Term}
    (correct : ∀ s x t j r, property s → f s x j = .ok (t, r) → property t)
    {xs : List Term} {s t : Term} {j r : List Term}
    (before : property s) (h : xs.foldlM f s j = .ok (t, r)) : property t := by
  induction xs generalizing s j with
  | nil => rw [pure_ok h]; exact before
  | cons x xs ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨next, _, step, h⟩ := bind_ok h
    exact ih (correct s x next _ _ before step) h

/-- Normalization produces binary map keys without assuming anything about payload values. -/
theorem stringifyFuel_keys {fuel : Nat} {value result : Term} {j r : List Term}
    (h : stringifyFuel fuel value j = .ok (result, r)) : BinaryKeys result := by
  cases fuel with
  | zero => exact (fail_ok h).elim
  | succ fuel =>
    cases value <;> unfold stringifyFuel at h
    all_goals first
      | (rw [pure_ok h]; trivial)
      | (obtain ⟨_, _, _, h⟩ := bind_ok h; rw [pure_ok h]; trivial)
      | (obtain ⟨_, _, _, h⟩ := bind_ok h; exact (fail_ok h).elim)
      | skip
    obtain ⟨items, folded, _⟩ := enumFold_ok h
    apply foldlM_property _ (show BinaryKeys empty from rfl) folded
    intro s pair t j r before step
    split at step
    · obtain ⟨key, _, keyRead, step⟩ := bind_ok step
      obtain ⟨_, _, _, step⟩ := bind_ok step
      exact put_binary_keys before (stringChars_binary keyRead) step
    · exact (fail_ok step).elim

theorem stringify_keys {value result : Term} {j r : List Term}
    (h : stringify value j = .ok (result, r)) : BinaryKeys result := by
  unfold stringify at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  exact stringifyFuel_keys h

theorem shallowStringify_binary_keys {raw event : Term} {j r : List Term}
    (keys : BinaryKeys raw) (h : shallowStringify raw j = .ok (event, r)) : event = raw := by
  unfold shallowStringify at h
  obtain ⟨fields, _, read, h⟩ := bind_ok h
  unfold entries at read
  split at read
  · have same := pure_ok read
    subst fields
    simp only [BinaryKeys] at keys
    rw [keys] at h
    exact pure_ok h
  · exact (fail_ok read).elim

theorem binary_keys_put (s value : Term) (key : String) (keys : BinaryKeys s) :
    BinaryKeys (s.put (b key) value) := by
  cases s with
  | map fields =>
    simp only [Term.put, BinaryKeys, List.all_cons, b, Term.text, Term.isBinary, Bool.true_and]
    exact List.all_eq_true.mpr (fun pair member =>
      List.all_eq_true.mp keys pair (List.mem_filter.mp member).1)
  | _ => rfl

theorem timestampLifecycle_binary_keys {event : Term} (now : Int) (keys : BinaryKeys event) :
    BinaryKeys (Command.timestampLifecycle event now) := by
  unfold Command.timestampLifecycle
  split
  · exact binary_keys_put _ _ _ keys
  · exact keys

theorem inputEvents_binary_keys {entry : Term} {events j r : List Term}
    (h : Command.inputEvents entry j = .ok (events, r)) :
    ∀ event ∈ events, BinaryKeys event := by
  unfold Command.inputEvents at h
  obtain ⟨raw, before, _, h⟩ := bind_ok h
  obtain ⟨converted, _, convertedRead, h⟩ := bind_ok h
  obtain ⟨time, _, _, h⟩ := bind_ok h
  have mapKeys : ∀ (items : List Term) (output journal rest : List Term),
      items.mapM stringify journal = .ok (output, rest) →
      ∀ event ∈ output, BinaryKeys event := by
    intro items
    induction items with
    | nil =>
      intro output journal rest h
      have same := pure_ok h
      subst output
      simp
    | cons head items ih =>
      intro output journal rest h
      rw [List.mapM_cons] at h
      obtain ⟨first, _, converted, h⟩ := bind_ok h
      obtain ⟨tail, _, folded, h⟩ := bind_ok h
      have same := pure_ok h
      subst output
      intro event member
      rcases List.mem_cons.mp member with same | member
      · subst event; exact stringify_keys converted
      · exact ih _ _ _ folded event member
  rw [pure_ok h]
  intro event member
  obtain ⟨original, originalMember, same⟩ := List.mem_map.mp member
  subst event
  exact timestampLifecycle_binary_keys _ (mapKeys raw converted before _ convertedRead original originalMember)

/-- A canonical event addressed to this Session cannot take the target-skip branch. -/
theorem prepareTrusted_canonical_not_skipped {s raw next : Term} {j r : List Term}
    (keys : BinaryKeys raw) (target : raw.get (b "session_id") = s.get (a "session_id"))
    (h : prepareTrusted s raw j = .ok ((next, none), r)) : False := by
  unfold prepareTrusted at h
  simp only [bind_ok_iff, ite_ok_iff, fail_ok_iff, false_and, and_false, exists_false, false_or,
    or_false, pure_ok_iff, Prod.mk.injEq, reduceCtorEq, and_true] at h
  obtain ⟨_, _, event, _, read, mismatch, _⟩ := h
  have same := shallowStringify_binary_keys keys read
  subst event
  rw [target] at mismatch
  generalize s.get (a "session_id") = session at mismatch
  cases session <;> simp [Term.isBinary, Term.numericEq, Term.numericEqFuel, Term.depth,
    Term.number] at mismatch
  rename_i bytes
  have reflexive : (Term.binary bytes == Term.binary bytes) = true := by
    change (bytes.data == bytes.data) = true
    exact beq_self_eq_true _
  simp [reflexive] at mismatch

end VerifiedKernel.Session.WorkConservation
