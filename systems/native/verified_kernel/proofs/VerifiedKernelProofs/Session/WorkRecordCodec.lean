import VerifiedKernelProofs.Session.WorkArchiveFields
import VerifiedKernelProofs.Session.WorkHistoryReachability

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem nodup_subset_same_length_perm {α : Type} {left right : List α}
    (unique : left.Nodup) (included : left ⊆ right) (length : left.length = right.length) :
    left.Perm right := by
  induction left generalizing right with
  | nil =>
    have empty : right = [] := List.length_eq_zero_iff.mp length.symm
    subst right
    exact List.Perm.nil
  | cons head tail ih =>
    obtain ⟨before, after, rfl, _⟩ := List.eq_append_cons_of_mem (included List.mem_cons_self)
    have tailIncluded : tail ⊆ before ++ after := by
      intro value member
      have found := included (List.mem_cons_of_mem _ member)
      rcases List.mem_append.mp found with prior | following
      · exact List.mem_append_left _ prior
      · rcases List.mem_cons.mp following with equal | later
        · exact ((List.nodup_cons.mp unique).1 (equal ▸ member)).elim
        · exact List.mem_append_right _ later
    have tailLength : tail.length = (before ++ after).length := by
      simp only [List.length_cons, List.length_append] at length ⊢
      omega
    exact ((ih (List.nodup_cons.mp unique).2 tailIncluded tailLength).cons head).trans List.perm_middle.symm

theorem map_has_atom {fields : List (Term × Term)} {name : String} :
    (Term.map fields).has (a name) = true ↔ a name ∈ fields.map Prod.fst := by
  simp only [Term.has, List.any_eq_true, List.mem_map]
  constructor
  · rintro ⟨pair, member, equal⟩
    exact ⟨pair, member, atom_beq_true equal⟩
  · rintro ⟨pair, member, equal⟩
    exact ⟨pair, member, by rw [equal]; simp [atom_beq]⟩

namespace ValueSemantics

theorem Equivalent.map_entries {fields : List (Term × Term)} {right : Term}
    (same : Equivalent (.map fields) right) :
    ∃ other, right = .map other ∧ fields.length = other.length := by
  have observed := same.shape
  cases right with
  | map other => exact ⟨other, rfl, (Shape.map.inj observed).1⟩
  | _ => cases observed

theorem Equivalent.wellFormed {left right : Term} (same : Equivalent left right)
    (well : RecordShape.WellFormed left) : RecordShape.WellFormed right := by
  obtain ⟨fields, rfl, safe, unique⟩ := well
  obtain ⟨other, rfl, length⟩ := same.map_entries
  let original := fields.map (fun pair => (a pair.1, pair.2))
  have originalSafe : ∀ pair ∈ original, ∃ name, pair.1 = a name ∧ RecordShape.SafeName name := by
    intro pair member
    obtain ⟨source, sourceMember, rfl⟩ := List.mem_map.mp member
    exact ⟨source.1, rfl, safe source sourceMember⟩
  have keysUnique : (original.map Prod.fst).Nodup := by
    change (fields.map (fun pair => (a pair.1, pair.2)) |>.map Prod.fst).Nodup
    rw [List.map_map]
    apply List.pairwise_map.mpr
    apply unique.imp
    intro first last different equal
    exact different (Term.atom.inj equal)
  have keysIncluded : original.map Prod.fst ⊆ other.map Prod.fst := by
    intro key member
    obtain ⟨pair, pairMember, rfl⟩ := List.mem_map.mp member
    obtain ⟨name, keyEq, _⟩ := originalSafe pair pairMember
    rw [keyEq]
    apply map_has_atom.mp
    rw [← same.has (a name)]
    apply map_has_atom.mpr
    exact List.mem_map.mpr ⟨pair, pairMember, keyEq⟩
  have keysPerm := nodup_subset_same_length_perm keysUnique keysIncluded
    (by simpa only [original, List.length_map] using length)
  apply RecordShape.map_literal
  · intro pair member
    have old := keysPerm.symm.subset (List.mem_map.mpr ⟨pair, member, rfl⟩)
    obtain ⟨source, sourceMember, sameKey⟩ := List.mem_map.mp old
    obtain ⟨name, keyEq, good⟩ := originalSafe source sourceMember
    exact ⟨name, sameKey.symm.trans keyEq, good⟩
  · exact List.pairwise_map.mp (keysUnique.perm keysPerm)

theorem Recorded.wellFormed {item record : Term} (recorded : Recorded item record) :
    RecordShape.WellFormed record := by
  obtain ⟨_, _, _, fields, codec⟩ := recorded
  exact codec.wellFormed fields.2.1

theorem Equivalent.tuple_value {items : List Term} {right : Term}
    (same : Equivalent (.tuple items) right) : ∃ values, right = .tuple values := by
  have observed := same.shape
  cases right with
  | tuple values => exact ⟨values, rfl⟩
  | _ => cases observed

/-- Actual archive projection retains complete work after semantic codec round trips. -/
theorem archiveWindow_recorded_input_fact {s ceiling item record : Term} {records j r : List Term}
    (inv : SeqSorted s) (present : ContainsRecord s record) (recorded : Recorded item record)
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records, Equivalent (queueWorkProjection item)
      ((projected.get (a "data")).get (b "accepted_input")) := by
  have fact := recorded.input_fact
  obtain ⟨values, actual⟩ := fact.tuple_value
  obtain ⟨before, after, equal, plain, beforeDifferent, afterDifferent⟩ :=
    ArchiveProjection.record_shape_field recorded.wellFormed actual (by intro impossible; cases impossible)
  rw [equal] at present fact
  obtain ⟨projected, member, field⟩ := ArchiveProjection.archiveWindow_tuple_field inv present plain
    (by decide) (by decide) beforeDifferent afterDifferent h
  refine ⟨projected, member, ?_⟩
  rw [field]
  exact fact

theorem reachable_archiveWindow_recorded_input_fact {s ceiling item record : Term} {records j r : List Term}
    (reachable : HistoryReachable s) (present : ContainsRecord s record) (recorded : Recorded item record)
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records, Equivalent (queueWorkProjection item)
      ((projected.get (a "data")).get (b "accepted_input")) :=
  archiveWindow_recorded_input_fact reachable.sequence.1 present recorded h

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
