import VerifiedKernelProofs.Session.WorkToolSideEffectAdmission
import VerifiedKernel.Session.Loop

/-! # Host-built loop events

`Loop.hostEventsList` checks the events that the host builds and the loop
commits. An accepted list is a `RawOrdinaryBatch`: no event retires input,
advances the archive or stamps the session under any key that converts to
`type`. -/

namespace VerifiedKernel.Session.WorkConservation
open Data
open VerifiedKernel.AgentLoop
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem host_entry_kind {key kind : Term}
    (checked : Loop.hostEntry (.tuple [key, kind]) = a "ok")
    {journal rest : List Term} (converted : stringChars key journal = .ok (b "type", rest)) :
    OrdinaryKind kind := by
  have typed := type_key_conversion converted
  unfold Loop.hostEntry at checked
  simp only [typed, Bool.and_true] at checked
  split at checked
  · cases checked
  · rename_i allowed
    unfold Loop.hostForbidden at allowed
    simp only [List.contains_cons, List.contains_nil, Bool.or_false, Bool.or_eq_true,
      not_or] at allowed
    refine ⟨?_, ?_, ?_, ?_⟩ <;> intro same <;> subst kind <;> simp +decide [b, Term.text] at allowed

theorem host_entry_loop {items : List Term} {journal rest : List Term}
    (call : enumListLoop (fun _ item =>
      let result := Loop.hostEntry item
      pure (result == a "ok", result)) items (a "ok") journal = .ok (a "ok", rest)) :
    ∀ item ∈ items, Loop.hostEntry item = a "ok" := by
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

theorem host_event_enumeration {value : Term} (checked : Loop.hostEvent value = a "ok") :
    value.isMap = true ∧ ∃ items, enumeratedItems value = some items ∧
      ∀ item ∈ items, Loop.hostEntry item = a "ok" := by
  unfold Loop.hostEvent at checked
  split at checked
  · cases checked
  · rename_i isMap
    have map : value.isMap = true := by cases h : value.isMap <;> simp_all
    split at checked
    · rename_i result remaining executed
      subst result
      obtain ⟨items, enumerated, loop⟩ := enumUntil_actual_items executed
      exact ⟨map, items, enumerated, host_entry_loop loop⟩
    · cases checked

theorem host_event_type_keys_checked {value : Term} (checked : Loop.hostEvent value = a "ok") :
    EventTypeKeysChecked value := by
  obtain ⟨isMap, items, enumeration, entriesChecked⟩ := host_event_enumeration checked
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
      apply host_entry_kind (journal := []) (rest := [])
        (entriesChecked _ (List.mem_map_of_mem member))
      rw [same]
      rfl
  · intro other actual key kind member journal rest converted
    have same := Option.some.inj (enumeration.symm.trans actual)
    subst other
    exact host_entry_kind (entriesChecked _ member) converted

theorem host_event_raw_ordinary {value : Term} (checked : Loop.hostEvent value = a "ok") :
    RawOrdinary value := checked_keys_raw_ordinary (host_event_type_keys_checked checked)

/-- A host-built event list that `Loop.hostEventsList` accepts is a raw ordinary batch. -/
theorem host_events_raw_ordinary {events : List Term}
    (checked : Loop.hostEventsList events = a "ok") : RawOrdinaryBatch events := by
  induction events with
  | nil => intro value member; cases member
  | cons value values ih =>
    unfold Loop.hostEventsList at checked
    dsimp only at checked
    split at checked
    · rename_i accepted
      intro selected member
      rcases List.mem_cons.mp member with rfl | member
      · exact host_event_raw_ordinary (atom_beq_true accepted)
      · exact ih checked selected member
    · rename_i rejected
      rw [checked] at rejected
      exact (rejected (atom_beq_self _)).elim

end VerifiedKernel.Session.WorkConservation
