import VerifiedKernelProofs.Session.AppendOnly.Core

namespace VerifiedKernel.Session.WorkConservation
open Data

set_option maxHeartbeats 2000000
set_option Elab.async false

theorem present_lookup (xs : List (Term × Term)) (key : Term) :
    (present (.map xs)).get key =
      ((xs.find? (fun pair => pair.2 != nil && pair.1 == key)).map Prod.snd).getD nil := by
  simp [present, Term.get, List.find?_filter, nil]

theorem atom_beq (left right : String) : (a left == a right) = (left == right) := rfl

theorem bne_nil_false {value : Term} (h : (value != nil) = false) : value = nil := by
  apply atom_beq_true
  cases hv : (value == nil)
  · simp [bne, hv] at h
  · exact hv

theorem present_put_other (v value : Term) {key name : String} (different : name ≠ key) :
    (present (v.put (a name) value)).get (a key) = (present v).get (a key) := by
  cases v with
  | map xs =>
    simp only [Term.put, present, List.filter_cons]
    split
    · simp only [Term.get, List.find?_cons, atom_beq_ne different]
      congr 2
      rw [List.filter_filter, List.find?_filter, List.find?_filter]
      congr 1
      funext entry
      by_cases hit : (entry.1 == a key) = true
      · have eq := atom_beq_true hit
        simp [eq, atom_beq_ne (Ne.symm different)]
      · simp [hit]
    · simp only [Term.get]
      congr 2
      rw [List.filter_filter, List.find?_filter, List.find?_filter]
      congr 1
      funext entry
      by_cases hit : (entry.1 == a key) = true
      · have eq := atom_beq_true hit
        simp [eq, atom_beq_ne (Ne.symm different)]
      · simp [hit]
  | _ =>
    simp only [Term.put, present, List.filter_cons, List.filter_nil]
    split <;> simp [Term.get, atom_beq_ne different]

def KeysIn (value : Term) (names : List String) : Prop :=
  ∃ entries, value = .map entries ∧ ∀ key field, (key, field) ∈ entries → ∃ name ∈ names, key = a name

theorem trace_fields_keys {event fields : Term} {names : List String} {j r : List Term}
    (h : traceFields event names j = .ok (fields, r)) : KeysIn fields names := by
  unfold traceFields at h
  suffices aux : ∀ (todo allowed : List String) (initial result : Term) (j r : List Term),
      KeysIn initial allowed →
      (todo.foldlM (fun acc name => do put acc (a name) (← Data.event event name)) initial : KernelM Term) j = .ok (result, r) →
      KeysIn result (allowed ++ todo) by
    simpa using aux names [] empty fields j r ⟨[], rfl, by simp⟩ h
  intro todo
  induction todo with
  | nil =>
    intro allowed initial result j r keys h
    obtain rfl := pure_ok h
    simpa using keys
  | cons name todo ih =>
    intro allowed initial result j r keys h
    rw [List.foldlM_cons] at h
    obtain ⟨next, j', hp, h⟩ := bind_ok h
    obtain ⟨field, _, _, hp⟩ := bind_ok hp
    obtain rfl := put_ok hp
    obtain ⟨entries, rfl, keys⟩ := keys
    have newKeys : KeysIn ((Term.map entries).put (a name) field) (allowed ++ [name]) := by
      refine ⟨_, rfl, ?_⟩
      intro key value member
      rcases List.mem_cons.mp member with same | old
      · cases same
        exact ⟨name, by simp, rfl⟩
      · obtain ⟨n, hn, eq⟩ := keys key value (List.mem_filter.mp old).1
        exact ⟨n, List.mem_append_left _ hn, eq⟩
    simpa [List.append_assoc] using ih (allowed ++ [name]) _ result j' r newKeys h

theorem merge_present_frame {base fields result : Term} {names : List String} {key : String}
    {j r : List Term} (keys : KeysIn fields names) (absent : key ∉ names)
    (h : merge base fields j = .ok (result, r)) :
    (present result).get (a key) = (present base).get (a key) := by
  obtain ⟨fields, rfl, keys⟩ := keys
  unfold merge at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨readFields, _, hf, h⟩ := bind_ok h
  have eq := pure_ok hf
  subst readFields
  have aux : ∀ (xs : List (Term × Term)) (base result : Term) (j r : List Term),
      (∀ k v, (k, v) ∈ xs → ∃ name ∈ names, k = a name) →
      (xs.foldlM (fun acc pair => put acc pair.1 pair.2) base : KernelM Term) j = .ok (result, r) →
      (present result).get (a key) = (present base).get (a key) := by
    intro xs
    induction xs with
    | nil =>
      intro base result j r _ h
      obtain rfl := pure_ok h
      rfl
    | cons pair xs ih =>
      intro base result j r keys h
      rw [List.foldlM_cons] at h
      obtain ⟨next, j', hp, h⟩ := bind_ok h
      obtain rfl := put_ok hp
      obtain ⟨name, member, same⟩ := keys pair.1 pair.2 (by simp)
      have different : name ≠ key := fun eq => absent (eq ▸ member)
      rw [ih _ result j' r (fun k v h => keys k v (List.mem_cons_of_mem _ h)) h, same,
        present_put_other _ _ different]
  exact aux fields base result _ _ keys h

end VerifiedKernel.Session.WorkConservation
