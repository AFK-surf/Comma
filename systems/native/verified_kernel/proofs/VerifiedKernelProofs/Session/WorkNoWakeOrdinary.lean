import VerifiedKernelProofs.Session.WorkEventKeyAdmission
import VerifiedKernelProofs.Proof.NativeProducerTactic

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

private def shallowStep (acc pair : Term) : KernelM Term := do
  let .tuple [key, item] := pair | fail "function_clause"
  put acc (← stringChars key) item

private theorem put_type_frame {left right key value : Term}
    (same : left.get (b "type") = right.get (b "type"))
    (binary : key.isBinary = true) :
    (left.put key value).get (b "type") = (right.put key value).get (b "type") := by
  by_cases isType : key = b "type"
  · subst key
    rw [get_put_binary_same, get_put_binary_same]
  · rw [get_put_converted_other _ _ _ binary isType,
      get_put_converted_other _ _ _ binary isType, same]

private theorem restore_no_wake_fields {fields : List (Term × Term)}
    {left right output : Term} {journal rest : List Term}
    (leftMap : left.isMap = true) (rightMap : right.isMap = true)
    (same : left.get (b "type") = right.get (b "type"))
    (call : ((fields.filter (fun p => p.1 != b "no_wake")).map
      (fun p => Term.tuple [p.1, p.2])).foldlM shallowStep right journal = .ok (output, rest)) :
    ∃ original, (fields.map (fun p => Term.tuple [p.1, p.2])).foldlM shallowStep left journal =
      .ok (original, rest) ∧ original.get (b "type") = output.get (b "type") := by
  induction fields generalizing left right journal with
  | nil =>
    have eq := pure_ok_iff.mp call
    cases eq
    exact ⟨left, rfl, same⟩
  | cons pair fields ih =>
    by_cases removed : pair.1 == b "no_wake"
    · have key := binary_beq_true removed
      rcases pair with ⟨key', value⟩
      dsimp only at key
      subst key'
      simp only [List.filter_cons, show (b "no_wake" != b "no_wake") = false from rfl,
        Bool.false_eq_true, ↓reduceIte] at call
      have frame : (left.put (b "no_wake") value).get (b "type") = right.get (b "type") := by
        rw [get_put_converted_other _ _ _ rfl (by simp +decide [b, Term.text]), same]
      obtain ⟨original, folded, result⟩ := ih (by cases left <;> rfl) rightMap frame call
      refine ⟨original, ?_, result⟩
      simpa only [List.map_cons, List.foldlM_cons, shallowStep, stringChars, put, b, Term.text,
        leftMap, ↓reduceIte,
        Bind.bind, StateT.bind, Pure.pure, StateT.pure, Except.pure, Except.bind] using folded
    · have kept : (pair.1 != b "no_wake") = true := by simp [bne, removed]
      simp only [List.filter_cons, kept, ↓reduceIte, List.map_cons, List.foldlM_cons] at call
      obtain ⟨middle, next, step, tail⟩ := bind_ok call
      obtain ⟨converted, afterKey, convert, stored⟩ := bind_ok step
      simp only [put, rightMap, ↓reduceIte] at stored
      have storedEq := pure_ok_iff.mp stored
      cases storedEq
      have frame := put_type_frame (value := pair.2) same (stringChars_binary convert)
      obtain ⟨original, folded, result⟩ := ih (by cases left <;> rfl)
        (by cases right <;> rfl) frame tail
      refine ⟨original, ?_, result⟩
      simp only [List.map_cons, List.foldlM_cons]
      apply bind_ok_iff.mpr
      refine ⟨left.put converted pair.2, _, ?_, folded⟩
      exact bind_ok_iff.mpr ⟨converted, _, convert, by simp [put, leftMap,
        Pure.pure, StateT.pure, Except.pure]⟩

private theorem no_wake_has_atom (raw value : Term) (name : String) :
    (raw.put (b "no_wake") value).has (a name) = raw.has (a name) := by
  cases raw with
  | map fields =>
    simp only [Term.put, Term.has, List.any_cons, show (b "no_wake" == a name) = false from rfl,
      Bool.false_or, List.any_filter]
    congr 1
    funext pair
    by_cases matched : pair.1 == a name
    · have same := atom_beq_true matched
      simp [same, b, a, Term.text, BEq.beq]
    · simp [matched]
  | _ => rfl

private theorem no_wake_binary_iff (fields : List (Term × Term)) (value : Term) :
    BinaryKeys ((Term.map fields).put (b "no_wake") value) ↔ BinaryKeys (.map fields) := by
  constructor
  · intro after
    simp only [Term.put, BinaryKeys, List.all_cons, show (b "no_wake").isBinary = true from rfl,
      Bool.true_and] at after
    apply List.all_eq_true.mpr
    intro pair member
    by_cases removed : pair.1 == b "no_wake"
    · rw [binary_beq_true removed]
      rfl
    · exact List.all_eq_true.mp after pair (List.mem_filter.mpr ⟨member, by simp [removed]⟩)
  · intro before
    exact binary_keys_put _ _ _ before

private theorem fold_enum (step : Term → Term → KernelM Term) (items : List Term)
    (initial : Term) (journal : List Term) :
    enumFold (list items) initial step journal = items.foldlM step initial journal := by
  exact (native_decl% "VerifiedKernel.Data.enumListLoop_foldlM") step items initial journal

/-- Adding notification metadata preserves the normalized event type, including key aliases. -/
theorem raw_ordinary_no_wake {raw : Term} (safe : RawOrdinary raw) (value : Term) :
    RawOrdinary (raw.put (b "no_wake") value) := by
  intro output journal rest call
  cases raw with
  | map fields =>
    by_cases binary : BinaryKeys (.map fields)
    · have after := (no_wake_binary_iff fields value).mpr binary
      rw [shallowStringify_binary_keys after call]
      rw [get_put_converted_other _ _ _ rfl (by simp +decide [b, Term.text])]
      apply safe (.map fields) journal journal
      simp only [shallowStringify, entries, Bind.bind, StateT.bind, Pure.pure, StateT.pure,
        Except.pure, Except.bind, show fields.all (fun p => p.1.isBinary) = true from binary,
        ↓reduceIte]
    · have after : ¬ BinaryKeys ((Term.map fields).put (b "no_wake") value) :=
        fun after => binary ((no_wake_binary_iff fields value).mp after)
      have oldShape : fields.all (fun p => p.1.isBinary) = false := Bool.eq_false_iff.mpr binary
      have newShape : (((b "no_wake", value) :: fields.filter (fun p => p.1 != b "no_wake")).all
          (fun p => p.1.isBinary)) = false := Bool.eq_false_iff.mpr after
      change shallowStringify (.map ((b "no_wake", value) :: fields.filter
        (fun p => p.1 != b "no_wake"))) journal = .ok (output, rest) at call
      simp only [shallowStringify, entries, Bind.bind, StateT.bind, Pure.pure, StateT.pure,
        Except.pure, Except.bind, newShape, Bool.false_eq_true, ↓reduceIte] at call
      change enumFold ((Term.map fields).put (b "no_wake") value) empty shallowStep journal =
        .ok (output, rest) at call
      by_cases plain : (Term.map fields).has (a "__struct__") = false
      · have newPlain : ((Term.map fields).put (b "no_wake") value).has (a "__struct__") = false := by
          rw [no_wake_has_atom, plain]
        have foldOld : ∀ initial journal, enumFold (.map fields) initial shallowStep journal =
            (fields.map (fun p => Term.tuple [p.1, p.2])).foldlM shallowStep initial journal := by
          intro initial journal
          simpa only [list, enumFold, enumUntil, plain, Bool.not_false, ↓reduceIte] using
            fold_enum shallowStep (fields.map (fun p => Term.tuple [p.1, p.2])) initial journal
        have foldNew : enumFold ((Term.map fields).put (b "no_wake") value) empty shallowStep journal =
            (((b "no_wake", value) :: fields.filter (fun p => p.1 != b "no_wake")).map
              (fun p => Term.tuple [p.1, p.2])).foldlM shallowStep empty journal := by
          simp only [Term.put] at newPlain
          simpa only [list, Term.put, enumFold, enumUntil, newPlain, Bool.not_false, ↓reduceIte, bne] using
            fold_enum shallowStep (((b "no_wake", value) :: fields.filter
              (fun p => p.1 != b "no_wake")).map (fun p => Term.tuple [p.1, p.2])) empty journal
        rw [foldNew] at call
        simp only [List.map_cons, List.foldlM_cons, shallowStep, stringChars, put, b, Term.text,
          empty, Term.isMap, ↓reduceIte,
          Bind.bind, StateT.bind, Pure.pure, StateT.pure, Except.pure, Except.bind] at call
        obtain ⟨original, folded, same⟩ := restore_no_wake_fields
          (left := empty) rfl rfl (by simp +decide [empty, Term.put, Term.get, b, Term.text]) call
        rw [← same]
        apply safe original journal rest
        simp only [shallowStringify, entries, Bind.bind, StateT.bind, Pure.pure, StateT.pure,
          Except.pure, Except.bind, oldShape, Bool.false_eq_true, ↓reduceIte]
        exact (foldOld empty journal).trans folded
      · have newStruct := no_wake_has_atom (.map fields) value "__struct__"
        have structGet := get_put_binary_atom (.map fields) value "no_wake" "__struct__"
        have mapGet := get_put_binary_atom (.map fields) value "no_wake" "map"
        simp only [Term.put] at newStruct structGet mapGet
        have identical : enumFold ((Term.map fields).put (b "no_wake") value) empty shallowStep journal =
            enumFold (.map fields) empty shallowStep journal := by
          simp only [Term.put, enumFold, enumUntil, newStruct, structGet, mapGet,
            Bool.not_eq_true', plain, Bool.true_eq_false, ↓reduceIte]
        rw [identical] at call
        apply safe output journal rest
        simp only [shallowStringify, entries, Bind.bind, StateT.bind, Pure.pure, StateT.pure,
          Except.pure, Except.bind, oldShape, Bool.false_eq_true, ↓reduceIte]
        exact call
  | _ =>
    have same := shallowStringify_binary_keys (raw := .map [(b "no_wake", value)]) rfl call
    rw [same]
    simp +decide [OrdinaryKind, Term.get, b, Term.text]

theorem raw_ordinary_no_wake_map {events : List Term} (safe : RawOrdinaryBatch events)
    (selected : Term → Bool) : RawOrdinaryBatch (events.map (fun event =>
      if selected event then event.put (b "no_wake") (a "true") else event)) := by
  intro event member
  obtain ⟨source, sourceMember, rfl⟩ := List.mem_map.mp member
  split
  · exact raw_ordinary_no_wake (safe source sourceMember) _
  · exact safe source sourceMember

end VerifiedKernel.Session.WorkConservation
