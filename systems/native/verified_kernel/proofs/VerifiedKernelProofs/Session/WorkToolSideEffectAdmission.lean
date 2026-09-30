import VerifiedKernelProofs.Session.WorkEventKeyAdmission

namespace VerifiedKernel.Session.WorkConservation
open Data
open VerifiedKernel.AgentLoop
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem type_key_conversion {key : Term} {journal rest : List Term}
    (call : stringChars key journal = .ok (b "type", rest)) : ToolSideEffects.typeKey key = true := by
  unfold stringChars at call
  unfold ToolSideEffects.typeKey stringChars
  repeat' first
    | (have same := pure_ok call; rw [← same]; rfl)
    | exact (fail_ok call).elim
    | split at call
  rename_i value values
  cases chars : charData (.list values) <;> simp only [chars] at call ⊢
  · exact (fail_ok call).elim
  · have same := pure_ok call
    rw [← same]
    rfl

theorem checked_entry_kind {key kind : Term}
    (checked : ToolSideEffects.entry (.tuple [key, kind]) = a "ok")
    {journal rest : List Term} (converted : stringChars key journal = .ok (b "type", rest)) :
    OrdinaryKind kind := by
  have typed := type_key_conversion converted
  unfold ToolSideEffects.entry at checked
  simp only [typed, Bool.and_true] at checked
  split at checked
  · cases checked
  · rename_i allowed
    unfold ToolSideEffects.forbidden at allowed
    simp only [List.contains_cons, List.contains_nil, Bool.or_false, Bool.or_eq_true,
      not_or] at allowed
    refine ⟨?_, ?_, ?_, ?_⟩ <;> intro same <;> subst kind <;> simp +decide [b, Term.text] at allowed

theorem checked_entry_loop {items : List Term} {journal rest : List Term}
    (call : enumListLoop (fun _ item =>
      let result := ToolSideEffects.entry item
      pure (result == a "ok", result)) items (a "ok") journal = .ok (a "ok", rest)) :
    ∀ item ∈ items, ToolSideEffects.entry item = a "ok" := by
  induction items generalizing journal with
  | nil => intro item member; cases member
  | cons item items ih =>
    simp only [enumListLoop, Bind.bind, StateT.bind, Except.bind, Pure.pure, StateT.pure,
      Except.pure] at call
    split at call
    · rename_i good
      have same := atom_beq_true good
      rw [same] at call
      intro selected member
      rcases List.mem_cons.mp member with rfl | member
      · exact same
      · exact ih call selected member
    · rename_i bad
      have same := (Prod.mk.inj (Except.ok.inj call)).1
      rw [same] at bad
      exact (bad (atom_beq_self _)).elim

theorem enumUntil_actual_items {α : Type} {value : Term} {initial final : α}
    {step : α → Term → KernelM (Bool × α)} {journal rest : List Term}
    (call : enumUntil value initial step journal = .ok (final, rest)) :
    ∃ items, enumeratedItems value = some items ∧
      enumListLoop step items initial journal = .ok (final, rest) := by
  cases value <;> simp only [enumUntil, enumeratedItems] at call ⊢
  case list items => exact ⟨items, rfl, call⟩
  case map entries =>
    split at call
    · rename_i plain
      simp only [plain, ↓reduceIte]
      exact ⟨_, rfl, call⟩
    · rename_i structured
      simp only [structured, Bool.false_eq_true, ↓reduceIte]
      split at call
      · rename_i mapSet
        simp only [mapSet, ↓reduceIte]
        generalize source : (Term.map entries).get (a "map") = members at call ⊢
        cases members <;> simp only at call ⊢
        case map members => exact ⟨_, rfl, call⟩
        all_goals simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
          MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at call
      · simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
          MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at call
  all_goals simp [Bind.bind, StateT.bind, Except.bind, fail, throw, throwThe,
    MonadExceptOf.throw, StateT.lift, Functor.map, Except.map] at call

theorem event_enumeration_checked {value : Term} (checked : ToolSideEffects.event value = a "ok") :
    value.isMap = true ∧ ∃ items, enumeratedItems value = some items ∧
      ∀ item ∈ items, ToolSideEffects.entry item = a "ok" := by
  unfold ToolSideEffects.event at checked
  split at checked
  · cases checked
  · rename_i isMap
    have map : value.isMap = true := by cases h : value.isMap <;> simp_all
    split at checked
    · rename_i result remaining executed
      subst result
      obtain ⟨items, enumerated, loop⟩ := enumUntil_actual_items executed
      exact ⟨map, items, enumerated, checked_entry_loop loop⟩
    · cases checked

theorem binary_keys_no_struct {fields : List (Term × Term)} (binary : BinaryKeys (.map fields)) :
    (Term.map fields).has (a "__struct__") = false := by
  apply Bool.eq_false_iff.mpr
  intro present
  obtain ⟨pair, member, hit⟩ := List.any_eq_true.mp present
  have same := atom_beq_true hit
  have key := List.all_eq_true.mp binary pair member
  rw [same] at key
  cases key

theorem tool_event_type_keys_checked {value : Term} (checked : ToolSideEffects.event value = a "ok") :
    EventTypeKeysChecked value := by
  obtain ⟨isMap, items, enumeration, entriesChecked⟩ := event_enumeration_checked checked
  constructor
  · intro binary
    cases value <;> simp only [Term.isMap, Bool.false_eq_true] at isMap
    rename_i fields
    have plain := binary_keys_no_struct binary
    simp only [enumeratedItems, plain, Bool.not_false, ↓reduceIte] at enumeration
    have enumerated := Option.some.inj enumeration
    subst items
    unfold Term.get
    dsimp only
    cases found : fields.find? (fun pair => pair.1 == b "type") with
    | none => simp +decide [OrdinaryKind, b, Term.text]
    | some pair =>
      simp only [Option.map_some, Option.getD_some]
      have matched := List.find?_some found
      have same := binary_beq_true matched
      have member := List.mem_of_find?_eq_some found
      apply checked_entry_kind (journal := []) (rest := [])
        (entriesChecked _ (List.mem_map_of_mem member))
      rw [same]
      rfl
  · intro other actual key kind member journal rest converted
    have same := Option.some.inj (enumeration.symm.trans actual)
    subst other
    exact checked_entry_kind (entriesChecked _ member) converted

theorem tool_event_raw_ordinary {value : Term} (checked : ToolSideEffects.event value = a "ok") :
    RawOrdinary value := checked_keys_raw_ordinary (tool_event_type_keys_checked checked)

theorem tool_events_list_raw_ordinary {events : List Term}
    (checked : ToolSideEffects.eventsList events = a "ok") : RawOrdinaryBatch events := by
  induction events with
  | nil => intro value member; cases member
  | cons value values ih =>
    unfold ToolSideEffects.eventsList at checked
    dsimp only at checked
    split at checked
    · rename_i accepted
      intro selected member
      rcases List.mem_cons.mp member with rfl | member
      · exact tool_event_raw_ordinary (atom_beq_true accepted)
      · exact ih checked selected member
    · intro selected member
      have first := tool_event_raw_ordinary checked
      rename_i rejected
      rw [checked] at rejected
      exact (rejected (atom_beq_self _)).elim

theorem tool_events_raw_ordinary {events : List Term}
    (checked : AgentLoop.invoke (a "validate_tool_events") (list events) = .ok (a "ok")) :
    RawOrdinaryBatch events := by
  exact tool_events_list_raw_ordinary (Except.ok.inj checked)

theorem tool_events_checked_shape {value : Term} (checked : ToolSideEffects.events value = a "ok") :
    ∃ events, value = list events ∧ RawOrdinaryBatch events := by
  cases value <;> simp only [ToolSideEffects.events, ToolSideEffects.invalid] at checked
  case list events => exact ⟨events, rfl, tool_events_list_raw_ordinary checked⟩
  all_goals cases checked

end VerifiedKernel.Session.WorkConservation
