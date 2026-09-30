import VerifiedKernelProofs.IFC.Transfer
import VerifiedKernelProofs.AgentLoop.Dispatch
import VerifiedKernelProofs.Provider.Dispatch
import VerifiedKernelProofs.Session.WorkArchiveProjection

namespace VerifiedKernel.Session.WorkConservation
open Data
namespace ArchiveProjection
set_option maxHeartbeats 1000000
set_option Elab.async false

def atomFields (fields : List (String × Term)) : Term :=
  .map (fields.map (fun pair => (a pair.1, pair.2)))

theorem atomFields_plain {fields : List (String × Term)}
    (plain : ∀ pair ∈ fields, pair.1 ≠ "__struct__") :
    (atomFields fields).has (a "__struct__") = false := by
  simp only [atomFields, Term.has, List.any_map, Function.comp_def]
  apply List.any_eq_false.mpr
  intro pair member
  intro hit
  exact plain pair member (by simpa only [atom_beq, beq_iff_eq] using hit)

theorem enumFold_atom_fields {α : Type} {fields : List (String × Term)} {initial final : α}
    {step : α → Term → KernelM α} {j r : List Term}
    (plain : ∀ pair ∈ fields, pair.1 ≠ "__struct__")
    (h : enumFold (atomFields fields) initial step j = .ok (final, r)) :
    (fields.map (fun pair => Term.tuple [a pair.1, pair.2])).foldlM step initial j = .ok (final, r) := by
  have notStruct := atomFields_plain plain
  simp only [atomFields] at notStruct
  have same : enumFold (atomFields fields) initial step j =
      enumFold (.list (fields.map (fun pair => Term.tuple [a pair.1, pair.2]))) initial step j := by
    simp only [atomFields, enumFold, enumUntil, notStruct, Bool.not_false,
      ↓reduceIte, List.map_map, Function.comp_def]
  rw [same] at h
  obtain ⟨items, folded, enumerated⟩ := enumFold_ok h
  rw [enumerated _ rfl] at folded
  exact folded

theorem atom_string_name {name : String} {value : Term} {j r : List Term}
    (notNil : name ≠ "nil") (h : stringChars (a name) j = .ok (value, r)) : value = b name := by
  have converted : stringChars (a name) = pure (b name) := by simp [stringChars, a, notNil]
  rw [converted] at h
  exact pure_ok h

theorem atom_string_fold_frame {fields : List (String × Term)} {key : String} {s t : Term}
    {fuel : Nat} {j r : List Term}
    (different : ∀ pair ∈ fields, pair.1 ≠ key ∧ pair.1 ≠ "nil")
    (h : (fields.map (fun pair => Term.tuple [a pair.1, pair.2])).foldlM
      (stringifyFieldStep fuel) s j = .ok (t, r)) : t.get (b key) = s.get (b key) := by
  induction fields generalizing s j with
  | nil => rw [pure_ok h]
  | cons pair fields ih =>
    simp only [List.map_cons, List.foldlM_cons] at h
    obtain ⟨next, _, head, tail⟩ := bind_ok h
    unfold stringifyFieldStep at head
    obtain ⟨name, _, nameRead, head⟩ := bind_ok head
    have nameEq := atom_string_name (different pair List.mem_cons_self).2 nameRead
    subst name
    obtain ⟨value, _, _, head⟩ := bind_ok head
    have nextEq := put_ok head
    subst next
    rw [ih (fun field member => different field (List.mem_cons_of_mem _ member)) tail]
    exact get_put_binary_other _ _ (different pair List.mem_cons_self).1

/-- The selected field reaches its binary archive key through the actual recursive normalizer. -/
theorem stringify_atom_field {before after : List (String × Term)} {key : String} {raw value : Term}
    {j r : List Term}
    (plain : ∀ pair ∈ before ++ (key, raw) :: after, pair.1 ≠ "__struct__")
    (notNil : key ≠ "nil")
    (different : ∀ pair ∈ after, pair.1 ≠ key ∧ pair.1 ≠ "nil")
    (h : stringify (atomFields (before ++ (key, raw) :: after)) j = .ok (value, r)) :
    ∃ converted fuel first last, stringifyFuel fuel raw first = .ok (converted, last) ∧
      value.get (b key) = converted := by
  unfold stringify at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  generalize fuelRead : _ + 1 + _ = fuel at h
  cases fuel with
  | zero => exact (fail_ok h).elim
  | succ fuel =>
    unfold stringifyFuel at h
    change enumFold _ empty (stringifyFieldStep fuel) _ = _ at h
    have folded := enumFold_atom_fields plain h
    rw [List.map_append, List.foldlM_append] at folded
    obtain ⟨prefixState, _, _, folded⟩ := bind_ok folded
    simp only [List.map_cons, List.foldlM_cons] at folded
    obtain ⟨next, _, head, tail⟩ := bind_ok folded
    unfold stringifyFieldStep at head
    obtain ⟨name, _, nameRead, head⟩ := bind_ok head
    have nameEq := atom_string_name notNil nameRead
    subst name
    obtain ⟨converted, last, normalized, head⟩ := bind_ok head
    have nextEq := put_ok head
    subst next
    exact ⟨converted, fuel, _, last, normalized,
      (atom_string_fold_frame different tail).trans (get_put_binary_same _ _ key)⟩

theorem remove_atom_sequence {fields : List (String × Term)} {result : Term} {j r : List Term}
    (h : remove (atomFields fields) (a "seq") j = .ok (result, r)) :
    result = atomFields (fields.filter (fun pair => pair.1 != "seq")) := by
  have same := pure_ok h
  simpa only [atomFields, List.filter_map, Function.comp_def, bne, atom_beq] using same

theorem remove_binary_sequence {fields : List (String × Term)} {result : Term} {j r : List Term}
    (h : remove (atomFields fields) (b "seq") j = .ok (result, r)) : result = atomFields fields := by
  have same := pure_ok h
  have separated (pair : String × Term) : (a pair.1 != b "seq") = true := rfl
  have kept : fields.filter (fun _ => true) = fields := List.filter_eq_self.mpr (by intros; rfl)
  simpa [atomFields, List.filter_map, Function.comp_def, separated, kept] using same

theorem projected_atom_field {before after : List (String × Term)} {key : String} {raw projected : Term}
    (plain : ∀ pair ∈ before ++ (key, raw) :: after, pair.1 ≠ "__struct__")
    (notSeq : key ≠ "seq") (notNil : key ≠ "nil")
    (different : ∀ pair ∈ after, pair.1 ≠ key ∧ pair.1 ≠ "nil")
    (h : MessageRecord (atomFields (before ++ (key, raw) :: after)) projected) :
    ∃ converted fuel first last, stringifyFuel fuel raw first = .ok (converted, last) ∧
      (projected.get (a "data")).get (b key) = converted := by
  obtain ⟨withoutAtom, withoutBinary, payload, first, second, third, last,
    removedAtom, removedBinary, normalized, projectedRead⟩ := h
  have withoutAtomEq := remove_atom_sequence removedAtom
  subst withoutAtom
  have withoutBinaryEq := remove_binary_sequence removedBinary
  subst withoutBinary
  have selected : ((before ++ (key, raw) :: after).filter (fun pair => pair.1 != "seq")) =
      before.filter (fun pair => pair.1 != "seq") ++
        (key, raw) :: after.filter (fun pair => pair.1 != "seq") := by
    simp [List.filter_append, notSeq]
  rw [selected] at normalized
  obtain ⟨converted, fuel, first, last, conversion, field⟩ := stringify_atom_field
    (fun pair member => plain pair (by
      rw [← selected] at member
      exact (List.mem_filter.mp member).1)) notNil
    (fun pair member => different pair (List.mem_filter.mp member).1) normalized
  refine ⟨converted, fuel, first, last, conversion, ?_⟩
  rw [projectedRead]
  simpa +decide [Term.get, a] using field

/-- Binary identities and text content are unchanged, not merely linked to an arbitrary projection. -/
theorem projected_binary_field {before after : List (String × Term)} {key : String}
    {raw : ByteArray} {projected : Term}
    (plain : ∀ pair ∈ before ++ (key, Term.binary raw) :: after, pair.1 ≠ "__struct__")
    (notSeq : key ≠ "seq") (notNil : key ≠ "nil")
    (different : ∀ pair ∈ after, pair.1 ≠ key ∧ pair.1 ≠ "nil")
    (h : MessageRecord (atomFields (before ++ (key, Term.binary raw) :: after)) projected) :
    (projected.get (a "data")).get (b key) = .binary raw := by
  obtain ⟨converted, _, _, _, normalized, field⟩ := projected_atom_field plain notSeq notNil different h
  exact field.trans (stringifyFuel_binary_value normalized)

theorem atom_field_lookup {before after : List (String × Term)} {key : String} {value : Term}
    (different : ∀ pair ∈ before, pair.1 ≠ key) :
    (atomFields (before ++ (key, value) :: after)).get (a key) = value := by
  have absent : before.find? (fun pair => pair.1 == key) = none := by
    apply List.find?_eq_none.mpr
    intro pair member
    simpa using different pair member
  simp [atomFields, Term.get, List.find?_map, List.find?_append, Function.comp_def,
    atom_beq, absent]

/-- Tuples are opaque to archive key normalization, including the complete accepted input. -/
theorem stringifyFuel_tuple_value {fuel : Nat} {items : List Term} {value : Term} {j r : List Term}
    (h : stringifyFuel fuel (.tuple items) j = .ok (value, r)) : value = .tuple items := by
  cases fuel with
  | zero => exact (fail_ok h).elim
  | succ fuel => exact pure_ok h

theorem archiveWindow_tuple_field {s ceiling : Term} {records j r : List Term}
    {before after : List (String × Term)} {key : String} {items : List Term}
    (inv : SeqSorted s)
    (present : ContainsRecord s (atomFields (before ++ (key, Term.tuple items) :: after)))
    (plain : ∀ pair ∈ before ++ (key, Term.tuple items) :: after, pair.1 ≠ "__struct__")
    (notSeq : key ≠ "seq") (notNil : key ≠ "nil")
    (beforeDifferent : ∀ pair ∈ before, pair.1 ≠ key)
    (afterDifferent : ∀ pair ∈ after, pair.1 ≠ key ∧ pair.1 ≠ "nil")
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records,
      (projected.get (a "data")).get (b key) =
        (atomFields (before ++ (key, Term.tuple items) :: after)).get (a key) := by
  obtain ⟨messages, read, member⟩ := present
  obtain ⟨projected, member, projection⟩ := archiveWindow_messages inv read member h
  obtain ⟨converted, _, _, _, normalized, field⟩ :=
    projected_atom_field plain notSeq notNil afterDifferent projection
  exact ⟨projected, member, (field.trans (stringifyFuel_tuple_value normalized)).trans
    (atom_field_lookup beforeDifferent).symm⟩

theorem archiveWindow_input_fact {s ceiling item : Term} {records j r : List Term}
    {before after : List (String × Term)} {items : List Term}
    (inv : SeqSorted s)
    (present : ContainsRecord s (atomFields (before ++ ("accepted_input", Term.tuple items) :: after)))
    (recorded : ValueSemantics.Recorded item
      (atomFields (before ++ ("accepted_input", Term.tuple items) :: after)))
    (plain : ∀ pair ∈ before ++ ("accepted_input", Term.tuple items) :: after, pair.1 ≠ "__struct__")
    (beforeDifferent : ∀ pair ∈ before, pair.1 ≠ "accepted_input")
    (afterDifferent : ∀ pair ∈ after, pair.1 ≠ "accepted_input" ∧ pair.1 ≠ "nil")
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records, ValueSemantics.Equivalent (queueWorkProjection item)
      ((projected.get (a "data")).get (b "accepted_input")) := by
  obtain ⟨projected, member, field⟩ := archiveWindow_tuple_field inv present plain
    (by decide) (by decide) beforeDifferent afterDifferent h
  refine ⟨projected, member, ?_⟩
  rw [field]
  exact recorded.input_fact

/-- Actual archive-window output retains each selected binary field from the original message. -/
theorem archiveWindow_binary_field {s ceiling : Term} {records j r : List Term}
    {before after : List (String × Term)} {key : String} {raw : ByteArray}
    (inv : SeqSorted s)
    (present : ContainsRecord s (atomFields (before ++ (key, Term.binary raw) :: after)))
    (plain : ∀ pair ∈ before ++ (key, Term.binary raw) :: after, pair.1 ≠ "__struct__")
    (notSeq : key ≠ "seq") (notNil : key ≠ "nil")
    (beforeDifferent : ∀ pair ∈ before, pair.1 ≠ key)
    (afterDifferent : ∀ pair ∈ after, pair.1 ≠ key ∧ pair.1 ≠ "nil")
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records,
      (projected.get (a "data")).get (b key) =
        (atomFields (before ++ (key, Term.binary raw) :: after)).get (a key) := by
  obtain ⟨messages, read, member⟩ := present
  obtain ⟨projected, member, projection⟩ := archiveWindow_messages inv read member h
  exact ⟨projected, member, (projected_binary_field plain notSeq notNil afterDifferent projection).trans
    (atom_field_lookup beforeDifferent).symm⟩

theorem record_shape_field {record value : Term} {key : String}
    (shape : RecordShape.WellFormed record) (read : record.get (a key) = value)
    (nonNil : value ≠ nil) :
    ∃ before after : List (String × Term),
      record = atomFields (before ++ (key, value) :: after) ∧
      (∀ pair ∈ before ++ (key, value) :: after, pair.1 ≠ "__struct__") ∧
      (∀ pair ∈ before, pair.1 ≠ key) ∧
      (∀ pair ∈ after, pair.1 ≠ key ∧ pair.1 ≠ "nil") := by
  obtain ⟨fields, rfl, safe, unique⟩ := shape
  change (atomFields fields).get (a key) = value at read
  simp only [atomFields, Term.get, List.find?_map, Function.comp_def, atom_beq,
    Option.map_map] at read
  cases found : fields.find? (fun pair => pair.1 == key) with
  | none =>
    simp only [found, Option.map_none, Option.getD_none] at read
    exact (nonNil read.symm).elim
  | some pair =>
    have selected := List.find?_eq_some_iff_append.mp found
    have keyEq : pair.1 = key := by simpa using selected.1
    have valueEq : pair.2 = value := by simpa only [found, Option.map_some, Option.getD_some] using read
    have pairEq : pair = (key, value) := Prod.ext keyEq valueEq
    obtain ⟨before, after, partition, absent⟩ := selected.2
    rw [pairEq] at partition
    rw [partition] at safe unique ⊢
    refine ⟨before, after, rfl, fun pair member => (safe pair member).1, ?_, ?_⟩
    · intro pair member
      simpa using absent pair member
    · intro pair member
      have different := (List.pairwise_cons.mp (List.pairwise_append.mp unique).2.1).1 pair member
      exact ⟨Ne.symm different, (safe pair (List.mem_append_right _ (List.mem_cons_of_mem _ member))).2⟩

/-- Writer-derived record shape discharges the archive field-shape premises for queued work. -/
theorem archiveWindow_queued_input_fact {s ceiling item record : Term} {records j r : List Term}
    (inv : SeqSorted s) (present : ContainsRecord s record) (recorded : QueuedRecord item record)
    (h : StorageQuery.archiveWindow s j = .ok (.tuple [a "ok", list records, ceiling], r)) :
    ∃ projected ∈ records,
      (projected.get (a "data")).get (b "accepted_input") = StateQuery.acceptedInput item := by
  obtain ⟨before, after, equal, plain, beforeDifferent, afterDifferent⟩ :=
    record_shape_field recorded.2.1 recorded.1 (by intro impossible; cases impossible)
  rw [equal] at present recorded
  obtain ⟨projected, member, field⟩ := archiveWindow_tuple_field inv present plain
    (by decide) (by decide) beforeDifferent afterDifferent h
  exact ⟨projected, member, field.trans recorded.1⟩

end ArchiveProjection
end VerifiedKernel.Session.WorkConservation
