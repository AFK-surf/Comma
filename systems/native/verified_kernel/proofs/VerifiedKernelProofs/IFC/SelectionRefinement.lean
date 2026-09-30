import VerifiedKernelProofs.IFC.WireSemantics

namespace VerifiedKernel.IFC.SelectionRefinement
open Data Identity

private def collect (acc : List Term × List Term) (value : Term) : List Term × List Term :=
  if contains acc.1 (f value "ref") then acc else (f value "ref" :: acc.1, value :: acc.2)

private theorem collect_preserves (xs acc : List Term) :
    let result := xs.foldl collect (acc.map (fun x => f x "ref"), acc)
    result.1 = result.2.map (fun x => f x "ref") ∧
    (∀ x ∈ result.2, x ∈ acc ∨ x ∈ xs) ∧
    (∀ x, x ∈ acc ∨ x ∈ xs → ∃ y ∈ result.2, key (f y "ref") = key (f x "ref")) := by
  induction xs generalizing acc with
  | nil =>
    exact ⟨rfl, by simp, by intro x hx; exact ⟨x, by simpa using hx, rfl⟩⟩
  | cons x xs ih =>
    simp only [List.foldl_cons, collect]
    split
    · rename_i seen
      obtain ⟨shape, subset, covers⟩ := ih acc
      refine ⟨shape, ?_, ?_⟩
      · intro y hy; rcases subset y hy with h | h
        · exact Or.inl h
        · exact Or.inr (by simp [h])
      · intro y hy
        rcases hy with old | new
        · exact covers y (Or.inl old)
        · rcases List.mem_cons.mp new with same | later
          · subst y
            obtain ⟨ref, href, equal⟩ := ReaderRefinement.contains_witness seen
            obtain ⟨z, hz, rfl⟩ := List.mem_map.mp href
            obtain ⟨out, present, same⟩ := covers z (Or.inl hz)
            exact ⟨out, present, same.trans equal⟩
          · exact covers y (Or.inr later)
    · obtain ⟨shape, subset, covers⟩ := ih (x :: acc)
      refine ⟨shape, ?_, ?_⟩
      · intro y hy; rcases subset y hy with h | h
        · rcases List.mem_cons.mp h with same | old
          · exact Or.inr (by simp [same])
          · exact Or.inl old
        · exact Or.inr (by simp [h])
      · intro y hy
        rcases hy with old | new
        · exact covers y (Or.inl (by simp [old]))
        · rcases List.mem_cons.mp new with same | later
          · exact covers y (Or.inl (by simp [same]))
          · exact covers y (Or.inr later)

theorem dedupe_subset (present : x ∈ dedupe xs) : x ∈ xs := by
  have h := (collect_preserves xs []).2.1 x
  exact (h (List.mem_reverse.mp present)).resolve_left (by simp)

theorem dedupe_covers (present : x ∈ xs) :
    ∃ y ∈ dedupe xs, key (f y "ref") = key (f x "ref") := by
  obtain ⟨y, member, equal⟩ := (collect_preserves xs []).2.2 x (Or.inr present)
  exact ⟨y, List.mem_reverse.mpr member, equal⟩

def Coherent (xs : List Term) : Prop :=
  ∀ x ∈ xs, ∀ y ∈ xs, key (f x "ref") = key (f y "ref") → x = y

theorem dedupe_members (coherent : Coherent xs) : x ∈ dedupe xs ↔ x ∈ xs := by
  constructor
  · exact dedupe_subset
  · intro member
    obtain ⟨y, present, same⟩ := dedupe_covers member
    have equal := coherent y (dedupe_subset present) x member same
    exact equal ▸ present

theorem unique_coherent (unique : DecisionContract.UniqueRefs xs)
    (valid : ∀ x ∈ xs, (f x "ref").isBinary = true) : Coherent xs := by
  induction xs with
  | nil => simp [Coherent]
  | cons x xs ih =>
    obtain ⟨head, tail⟩ := List.pairwise_cons.mp unique
    have coherent := ih tail (fun y hy => valid y (by simp [hy]))
    intro y hy z hz equal
    rcases List.mem_cons.mp hy with hy | hy <;> rcases List.mem_cons.mp hz with hz | hz
    · exact hy.trans hz.symm
    · subst y
      have yes := beq_of_key_eq (binary_key_valid (valid x (by simp)))
        (binary_key_valid (valid z (by simp [hz]))) equal
      rw [head z hz] at yes
      contradiction
    · subst z
      have yes := beq_of_key_eq (binary_key_valid (valid x (by simp)))
        (binary_key_valid (valid y (by simp [hy]))) equal.symm
      rw [head y hy] at yes
      contradiction
    · exact coherent y hy z hz equal

theorem coherent_cons (coherent : Coherent xs) (member : x ∈ xs) : Coherent (x :: xs) := by
  intro y hy z hz equal
  apply coherent y _ z _ equal
  · rcases List.mem_cons.mp hy with same | present
    · exact same ▸ member
    · exact present
  · rcases List.mem_cons.mp hz with same | present
    · exact same ▸ member
    · exact present

theorem selected_subset (h : DecisionContract.SelectedRefs xs refs selected) :
    ∀ x ∈ selected, x ∈ xs := by
  induction h with
  | nil => simp
  | cons present _ _ ih => simpa using And.intro present ih

theorem selected_keys (h : DecisionContract.SelectedRefs xs refs selected) :
    selected.map (fun x => key (f x "ref")) = refs.map key := by
  induction h with
  | nil => rfl
  | cons _ equal _ ih => simp only [List.map_cons, key_eq equal, ih]

theorem selected_members (coherent : Coherent xs)
    (h : DecisionContract.SelectedRefs xs refs selected) :
    x ∈ selected ↔ x ∈ xs ∧ key (f x "ref") ∈ refs.map key := by
  constructor
  · intro member
    refine ⟨selected_subset h x member, ?_⟩
    rw [← selected_keys h]
    exact List.mem_map.mpr ⟨x, member, rfl⟩
  · rintro ⟨present, member⟩
    rw [← selected_keys h] at member
    obtain ⟨y, hy, equal⟩ := List.mem_map.mp member
    exact coherent y (selected_subset h y hy) x present equal ▸ hy

local instance : System.Domain := WireSemantics.domain

theorem resolves (coherent : Coherent xs) (present : request ∈ xs)
    (h : DecisionContract.Resolves rawEffect request xs sources) :
    System.Resolves (xs.map WireSemantics.item) (WireSemantics.effect rawEffect).sources
      (sources.map WireSemantics.item) := by
  rcases h with ⟨context, rfl⟩ | ⟨explicitH, selected, selectedH, rfl⟩
  · simp only [WireSemantics.effect, context, ↓reduceIte, System.Resolves]
    intro item
    constructor
    · intro hi
      obtain ⟨raw, hr, rfl⟩ := List.mem_map.mp hi
      have member := (dedupe_members (coherent_cons coherent present)).mp hr
      rcases List.mem_cons.mp member with same | member
      · exact List.mem_map.mpr ⟨request, present, congrArg WireSemantics.item same.symm⟩
      · exact List.mem_map.mpr ⟨raw, member, rfl⟩
    · intro hi
      obtain ⟨raw, hr, rfl⟩ := List.mem_map.mp hi
      exact List.mem_map.mpr ⟨raw,
        (dedupe_members (coherent_cons coherent present)).mpr (by simp [hr]), rfl⟩
  · have selectedCoherent : Coherent selected := fun x hx y hy he =>
      coherent x (selected_subset selectedH x hx) y (selected_subset selectedH y hy) he
    simp only [WireSemantics.effect, explicitH, Bool.false_eq_true, ↓reduceIte, System.Resolves]
    constructor
    · intro ref member
      rw [← selected_keys selectedH] at member
      obtain ⟨raw, hr, rfl⟩ := List.mem_map.mp member
      exact ⟨WireSemantics.item raw, List.mem_map.mpr ⟨raw, selected_subset selectedH raw hr, rfl⟩, rfl⟩
    · intro decoded
      constructor
      · intro hd
        obtain ⟨raw, hr, rfl⟩ := List.mem_map.mp hd
        obtain ⟨inItems, inRefs⟩ := (selected_members coherent selectedH).mp (dedupe_subset hr)
        exact ⟨List.mem_map.mpr ⟨raw, inItems, rfl⟩, inRefs⟩
      · rintro ⟨hd, inRefs⟩
        obtain ⟨raw, hr, rfl⟩ := List.mem_map.mp hd
        have member := (selected_members coherent selectedH).mpr ⟨hr, inRefs⟩
        exact List.mem_map.mpr ⟨raw, (dedupe_members selectedCoherent).mpr member, rfl⟩

end VerifiedKernel.IFC.SelectionRefinement
