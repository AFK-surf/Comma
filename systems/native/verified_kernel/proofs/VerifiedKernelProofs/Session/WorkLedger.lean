import VerifiedKernelProofs.Session.WorkIdentities
import VerifiedKernelProofs.Session.WorkDeterminism

namespace VerifiedKernel.Session.WorkConservation
open Data

def IdentityAbsent (ledger key : Term) : Prop := (ledger.get (a "map")).has key = false

theorem put_preserves_absence {s inserted value key : Term}
    (absent : s.has key = false) (different : (inserted == key) = false) :
    (s.put inserted value).has key = false := by
  cases s with
  | map entries =>
    simp only [Term.put, Term.has, List.any_cons, different, Bool.false_or]
    apply List.any_eq_false.mpr
    intro pair member
    exact List.any_eq_false.mp absent pair (List.mem_filter.mp member).1
  | _ => simp only [Term.put, Term.has, List.any_cons, different, List.any_nil, Bool.or_self]

theorem setMember_value {ledger key : Term} {value : Bool} {j r : List Term}
    (h : setMember ledger key j = .ok (value, r)) : value = (ledger.get (a "map")).has key := by
  unfold setMember at h
  split at h
  · rename_i absent
    have result := pure_ok h
    cases ledger <;> simp [Term.truthy, Term.get, Term.has] at absent ⊢
    exact result
  · dsimp only at h
    split at h
    · exact pure_ok h
    · exact (fail_ok h).elim

theorem setPut_preserves_absence {ledger key inserted next : Term} {j r : List Term}
    (absent : IdentityAbsent ledger key) (different : (inserted == key) = false)
    (h : setPut ledger inserted j = .ok (next, r)) : IdentityAbsent next key := by
  unfold setPut at h
  split at h
  · rw [pure_ok h]
    simp only [IdentityAbsent]
    change (Term.map [(inserted, list [])]).has key = false
    simp only [Term.has, List.any_cons, different, List.any_nil, Bool.or_self]
  · dsimp only at h
    split at h
    · rw [pure_ok h]
      unfold IdentityAbsent
      rw [get_put_same]
      exact put_preserves_absence absent different
    · exact (fail_ok h).elim

theorem addDedupe_preserves_absence {ledger key next : Term} {keys j r : List Term}
    (absent : IdentityAbsent ledger key) (different : ∀ inserted ∈ keys, (inserted == key) = false)
    (h : addDedupe ledger keys j = .ok (next, r)) : IdentityAbsent next key := by
  unfold addDedupe at h
  induction keys generalizing ledger j with
  | nil => rw [pure_ok h]; exact absent
  | cons inserted keys ih =>
    rw [List.foldlM_cons] at h
    obtain ⟨middle, _, first, h⟩ := bind_ok h
    exact ih (setPut_preserves_absence absent (different _ List.mem_cons_self) first)
      (fun value member => different value (List.mem_cons_of_mem _ member)) h

theorem dedupeHit_absent {ledger : Term} {keys j r : List Term} {hit : Bool}
    (absent : ∀ key ∈ keys, IdentityAbsent ledger key)
    (h : dedupeHit ledger keys j = .ok (hit, r)) : hit = false := by
  induction keys generalizing j with
  | nil => exact pure_ok h
  | cons key keys ih =>
    unfold dedupeHit at h
    obtain ⟨found, _, read, h⟩ := bind_ok h
    have missing : found = false := (setMember_value read).trans (absent _ List.mem_cons_self)
    subst found
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    exact ih (fun key member => absent key (List.mem_cons_of_mem _ member)) h

end VerifiedKernel.Session.WorkConservation
