import VerifiedKernelProofs.Session.WorkRecordFields

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace RecordShape
set_option Elab.async false
set_option maxHeartbeats 1000000

def atomFields (fields : List (String × Term)) : Term :=
  .map (fields.map (fun pair => (a pair.1, pair.2)))

def SafeName (name : String) : Prop := name ≠ "__struct__" ∧ name ≠ "nil"

def WellFormed (record : Term) : Prop :=
  ∃ fields : List (String × Term), record = atomFields fields ∧
    (∀ pair ∈ fields, SafeName pair.1) ∧ fields.Pairwise (fun left right => left.1 ≠ right.1)

theorem literal {fields : List (String × Term)}
    (safe : ∀ pair ∈ fields, SafeName pair.1)
    (unique : fields.Pairwise (fun left right => left.1 ≠ right.1)) :
    WellFormed (atomFields fields) := ⟨fields, rfl, safe, unique⟩

theorem map_literal {fields : List (Term × Term)}
    (safe : ∀ pair ∈ fields, ∃ name, pair.1 = a name ∧ SafeName name)
    (unique : fields.Pairwise (fun left right => left.1 ≠ right.1)) : WellFormed (.map fields) := by
  let name (key : Term) := match key with | .atom text => text | _ => ""
  let convert (pair : Term × Term) := (name pair.1, pair.2)
  refine ⟨fields.map convert, ?_, ?_, ?_⟩
  · unfold atomFields
    congr 1
    rw [List.map_map]
    symm
    apply (List.map_congr_left (g := id) ?_).trans (List.map_id _)
    intro pair member
    obtain ⟨key, equal, _⟩ := safe pair member
    simp [convert, name, equal, a]
    exact Prod.ext (by simpa [a] using equal.symm) rfl
  · intro pair member
    obtain ⟨original, sourceMember, rfl⟩ := List.mem_map.mp member
    obtain ⟨key, equal, good⟩ := safe original sourceMember
    simpa [convert, name, equal, a] using good
  · apply List.pairwise_map.mpr
    apply unique.imp_of_mem
    intro left right leftMember rightMember different equal
    obtain ⟨leftName, leftKey, _⟩ := safe left leftMember
    obtain ⟨rightName, rightKey, _⟩ := safe right rightMember
    apply different
    simp only [convert, name, leftKey, rightKey, a] at equal
    rw [leftKey, rightKey, equal]

theorem put_atom_fields (fields : List (String × Term)) (name : String) (value : Term) :
    (atomFields fields).put (a name) value =
      atomFields ((name, value) :: fields.filter (fun pair => pair.1 != name)) := by
  simp [atomFields, Term.put, List.filter_map, Function.comp_def, bne, atom_beq]

theorem WellFormed.put {record : Term} {name : String} (shape : WellFormed record)
    (safeName : SafeName name) (value : Term) : WellFormed (record.put (a name) value) := by
  obtain ⟨fields, rfl, safe, unique⟩ := shape
  rw [put_atom_fields]
  apply literal
  · intro pair member
    rcases List.mem_cons.mp member with same | old
    · cases same; exact safeName
    · exact safe pair (List.mem_filter.mp old).1
  · apply List.pairwise_cons.mpr
    refine ⟨?_, unique.filter _⟩
    intro pair member
    have different : pair.1 ≠ name := by simpa using (List.mem_filter.mp member).2
    exact Ne.symm different

theorem WellFormed.present {record : Term} (shape : WellFormed record) :
    WellFormed (present record) := by
  obtain ⟨fields, rfl, safe, unique⟩ := shape
  have same : Data.present (atomFields fields) = atomFields (fields.filter (fun pair => pair.2 != nil)) := by
    simp [Data.present, atomFields, List.filter_map, Function.comp_def]
  rw [same]
  exact literal (fun pair member => safe pair (List.mem_filter.mp member).1) (unique.filter _)

theorem merge_shape {base fields result : Term} {names : List String} {j r : List Term}
    (shape : WellFormed base) (keys : KeysIn fields names)
    (safe : ∀ name ∈ names, SafeName name)
    (h : merge base fields j = .ok (result, r)) : WellFormed result := by
  obtain ⟨fields, rfl, keys⟩ := keys
  unfold merge at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨readFields, _, read, h⟩ := bind_ok h
  have same := pure_ok read
  subst readFields
  have aux : ∀ (fields : List (Term × Term)) (base result : Term) (j r : List Term),
      WellFormed base →
      (∀ key value, (key, value) ∈ fields → ∃ name ∈ names, key = a name) →
      (fields.foldlM (fun acc pair => put acc pair.1 pair.2) base : KernelM Term) j = .ok (result, r) →
      WellFormed result := by
    intro fields
    induction fields with
    | nil =>
      intro base result j r shape _ h
      rw [pure_ok h]
      exact shape
    | cons pair fields ih =>
      intro base result j r shape keys h
      rw [List.foldlM_cons] at h
      obtain ⟨next, nextJournal, written, h⟩ := bind_ok h
      have same := put_ok written
      subst next
      obtain ⟨name, member, key⟩ := keys pair.1 pair.2 List.mem_cons_self
      apply ih _ result nextJournal r ?_ (fun k v member => keys k v (List.mem_cons_of_mem _ member)) h
      rw [key]
      exact shape.put (safe name member) pair.2
  exact aux fields base result _ _ shape keys h

end RecordShape

syntax "record_shape" : tactic
macro_rules
  | `(tactic| record_shape) => `(tactic|
      repeat' first
        | assumption
        | apply RecordShape.WellFormed.put (safeName := by simp +decide [RecordShape.SafeName])
        | apply RecordShape.WellFormed.present
        | (apply RecordShape.merge_shape
            (keys := trace_fields_keys (by assumption))
            (safe := by simp +decide [RecordShape.SafeName]) (h := by assumption))
        | (apply RecordShape.map_literal <;> simp +decide [RecordShape.SafeName, a, List.pairwise_cons])
        | split)

end VerifiedKernel.Session.WorkConservation
