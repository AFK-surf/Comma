import VerifiedKernelProofs.Session.WorkInputBatch

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option maxHeartbeats 1000000
set_option Elab.async false

theorem deliveryAdmission_outcomes {s source payload limit result : Term} {j r : List Term}
    (h : RoundQuery.deliveryAdmission s (.tuple [source, payload, limit]) j = .ok (result, r)) :
    result = a "duplicate" ∨ result = a "saturated" ∨ result = a "accept" := by
  unfold RoundQuery.deliveryAdmission at h
  repeat' first
    | (rw [pure_ok h]; simp)
    | (obtain ⟨_, _, _, h⟩ := bind_ok h)
    | split at h
    | dsimp only at h

theorem deliveryAdmission_accept_fresh {s payload limit : Term} {source : ByteArray} {j r : List Term}
    (h : RoundQuery.deliveryAdmission s (.tuple [.binary source, payload, limit]) j = .ok (a "accept", r)) :
    IdentityAbsent (s.get (a "input_dedupe")) (.binary source) := by
  unfold RoundQuery.deliveryAdmission at h
  obtain ⟨duplicate, _, duplicateRead, h⟩ := bind_ok h
  unfold RoundQuery.duplicateDelivery at duplicateRead
  simp only [show (Term.binary source == nil) = false from rfl, Bool.false_eq_true, ↓reduceIte] at duplicateRead
  obtain ⟨ledger, _, ledgerRead, duplicateRead⟩ := bind_ok duplicateRead
  have ledgerEq := field_value ledgerRead
  subst ledger
  obtain ⟨present, _, presentRead, duplicateRead⟩ := bind_ok duplicateRead
  have duplicateEq := pure_ok duplicateRead
  subst duplicate
  cases present with
  | false => exact (setMember_value presentRead).symm
  | true =>
    have impossible := pure_ok h
    simp [a] at impossible

theorem input_source_commit {s entry born result : Term} {source : ByteArray} {j r : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (h : Command.input s (.tuple [entry, born]) j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    ∃ earlier event now first middle last,
      IdentityAbsent (s.get (a "input_dedupe")) (.binary source) ∧
      Command.inputEvent (s.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, middle) ∧
      (∀ current ∈ earlier, BinaryKeys current) ∧
      Command.commitInput s entry (earlier ++ [event]) true last = .ok (result, r) := by
  unfold Command.input at h
  obtain ⟨limit, _, _, h⟩ := bind_ok h
  obtain ⟨admission, _, admitted, h⟩ := bind_ok h
  change RoundQuery.deliveryAdmission s (.tuple [RoundQuery.atomFirst entry "source_message_id",
    RoundQuery.atomFirst entry "payload", limit]) _ = .ok (admission, _) at admitted
  rw [sourceValue] at admitted
  rcases deliveryAdmission_outcomes admitted with duplicate | saturated | accepted
  · rw [duplicate] at h
    exact Or.inl (pure_ok h)
  · rw [saturated] at h
    exact Or.inr (Or.inl (pure_ok h))
  · rw [accepted] at admitted h
    have fresh := deliveryAdmission_accept_fresh admitted
    obtain ⟨session, _, sessionRead, h⟩ := bind_ok h
    have sessionEq := field_value sessionRead
    obtain ⟨time, _, _, h⟩ := bind_ok h
    obtain ⟨attrs, _, attrsRead, h⟩ := bind_ok h
    obtain ⟨event, middle, eventRead, h⟩ := bind_ok h
    change Command.inputEvent session (RoundQuery.atomFirst entry "source_message_id")
      (RoundQuery.atomFirst entry "payload") _ _ = .ok (event, middle) at eventRead
    rw [sourceValue, sessionEq] at eventRead
    refine Or.inr (Or.inr ⟨_, event, _, _, middle, _, fresh, eventRead, ?_, h⟩)
    intro current member
    rcases List.mem_append.mp member with created | pre
    · split at created
      · have same : current = Command.timestampLifecycle
            ((attrs.put (b "type") (b "session_created")).put (b "session_id") session)
            (integerValue (i (integerValue time / 1000))) := by
          simpa using created
        rw [same]
        exact timestampLifecycle_binary_keys _
          (binary_keys_put _ _ _ (binary_keys_put _ _ _ (initialAttrs_binary_keys attrsRead)))
      · simp at created
    · obtain ⟨payload, _, same⟩ := List.mem_map.mp pre
      subst current
      exact preInputEvent_binary_keys _ _

theorem commit_input_main_start {s entry result event : Term} {trailing j r : List Term}
    {notifyInput : Bool}
    (trailingKeys : ∀ current ∈ trailing, BinaryKeys current)
    (h : Command.commitInput s entry (trailing ++ [event]) notifyInput j = .ok (result, r)) :
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ earlier selected before after,
      InputStart result (selected ++ [event]) notifyInput ∧
      (∀ current ∈ earlier, BinaryKeys current) ∧
      (∀ current ∈ earlier, Command.inputEventAllowed current = true) ∧
      (∀ current ∈ selected, current ∈ earlier) ∧
      Command.inputIdentitiesDistinct (earlier ++ [event]) before = .ok (true, after) := by
  unfold Command.commitInput at h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨_, _, _, h⟩ := bind_ok h
  obtain ⟨events, checkBefore, read, h⟩ := bind_ok h
  split at h
  · exact Or.inl (pure_ok h)
  · rename_i allowed
    have admitted : (events ++ (trailing ++ [event])).all Command.inputEventAllowed = true := by
      simpa using allowed
    obtain ⟨distinct, checkAfter, checked, h⟩ := bind_ok h
    cases distinct with
    | false => exact Or.inl (pure_ok h)
    | true =>
      let workspace := fun current : Term => [b "vfs_write", b "vfs_delete", b "vfs_copy"].contains (current.get (b "type"))
      let selected := events.filter (fun current => !workspace current) ++ trailing
      have canonical : ∀ current ∈ events ++ trailing, BinaryKeys current := by
        intro current member
        rcases List.mem_append.mp member with embedded | generated
        · exact inputEvents_binary_keys read current embedded
        · exact trailingKeys current generated
      have prefixAllowed : ∀ current ∈ events ++ trailing, Command.inputEventAllowed current = true := by
        intro current member
        apply List.all_eq_true.mp admitted current
        rw [← List.append_assoc]
        exact List.mem_append_left _ member
      have subset : ∀ current ∈ selected, current ∈ events ++ trailing := by
        intro current member
        rcases List.mem_append.mp member with embedded | generated
        · exact List.mem_append_left _ (List.mem_filter.mp embedded).1
        · exact List.mem_append_right _ generated
      refine Or.inr ⟨events ++ trailing, selected, checkBefore, checkAfter, ?_, canonical, prefixAllowed, subset, ?_⟩
      · simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
        unfold selected
        rw [List.append_assoc]
        split at h
        · exact Or.inl (pure_ok h)
        · repeat' first
            | (exact (fail_ok h).elim)
            | (have same := pure_ok h; exact Or.inr ⟨_, _, _, _, same⟩)
            | split at h
            | (obtain ⟨_, _, _, h⟩ := bind_ok h)
            | dsimp only at h
      · simpa only [List.append_assoc] using checked

theorem input_command_creates_work {s entry born result : Term} {source : ByteArray} {j r : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (ready : QueueReady s)
    (h : Command.input s (.tuple [entry, born]) j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch event now first last,
      InputStart result batch ∧
      Command.inputEvent (s.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      ∀ t, ResidentBatch s batch t → QueueReady t ∧
        (∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item) ∧
        ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
          ∀ sealed, ConcreteRepresented t sealed item := by
  rcases input_source_commit sourceValue h with duplicate | saturated |
    ⟨trailing, event, now, first, middle, last, fresh, generated, canonical, committed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · rcases commit_input_main_start canonical committed with invalid |
      ⟨earlier, selected, checkBefore, checkAfter, start, keys, allowed, subset, checked⟩
    · exact Or.inr (Or.inr (Or.inl invalid))
    · exact Or.inr (Or.inr (Or.inr ⟨selected ++ [event], event, now, first, middle, start, generated,
        fun _ execution => checked_resident_input_creates generated checked keys allowed subset ready fresh execution⟩))

end VerifiedKernel.Session.WorkConservation
