import VerifiedKernelProofs.Session.WorkInputTermDomain

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000

theorem input_term_source_commit {s entry born result source : Term} {j r : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source)
    (h : Command.input s (.tuple [entry, born]) j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    ∃ earlier event now first middle last limit admissionBefore admissionAfter,
      RoundQuery.deliveryAdmission s (.tuple [source, RoundQuery.atomFirst entry "payload", limit])
        admissionBefore = .ok (a "accept", admissionAfter) ∧
      Command.inputEvent (s.get (a "session_id")) source
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
    obtain ⟨session, _, sessionRead, h⟩ := bind_ok h
    have sessionEq := field_value sessionRead
    obtain ⟨time, _, _, h⟩ := bind_ok h
    obtain ⟨attrs, _, attrsRead, h⟩ := bind_ok h
    obtain ⟨event, middle, eventRead, h⟩ := bind_ok h
    change Command.inputEvent session (RoundQuery.atomFirst entry "source_message_id")
      (RoundQuery.atomFirst entry "payload") _ _ = .ok (event, middle) at eventRead
    rw [sourceValue, sessionEq] at eventRead
    refine Or.inr (Or.inr ⟨_, event, _, _, middle, _, limit, _, _, admitted, eventRead, ?_, h⟩)
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

theorem input_command_term_creates_work {s entry born result source : Term} {j r : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = source)
    (ready : QueueReady s)
    (h : Command.input s (.tuple [entry, born]) j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch event now first last,
      InputStart result batch ∧
      Command.inputEvent (s.get (a "session_id")) source
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      ∀ t, ResidentBatch s batch t → QueueReady t ∧
        (∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented t sealed item) ∧
        ∃ item, MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
          ∀ sealed, ConcreteRepresented t sealed item := by
  rcases input_term_source_commit sourceValue h with duplicate | saturated |
    ⟨trailing, event, now, first, middle, last, limit, admissionBefore, admissionAfter,
      admitted, generated, canonical, committed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · rcases commit_input_main_start canonical committed with invalid |
      ⟨earlier, selected, checkBefore, checkAfter, start, keys, allowed, subset, checked⟩
    · exact Or.inr (Or.inr (Or.inl invalid))
    · refine Or.inr (Or.inr (Or.inr
        ⟨selected ++ [event], event, now, first, middle, start, generated, ?_⟩))
      intro t execution
      exact checked_resident_term_input_creates (resident_input_batch_nonnull generated execution)
        admitted generated checked keys allowed subset ready execution

end VerifiedKernel.Session.WorkConservation
