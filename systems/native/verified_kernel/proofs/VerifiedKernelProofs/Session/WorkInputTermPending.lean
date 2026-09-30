import VerifiedKernelProofs.Session.WorkPendingInput
import VerifiedKernelProofs.Session.WorkInputTermAdmission

namespace VerifiedKernel.Session.WorkConservation.ValueSemantics
open Data
set_option Elab.async false

theorem input_command_term_preserves {s entry born result source : Term} {j r : List Term}
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
        (∀ sealed item, Represented s sealed item → Represented t sealed item) ∧
        ∃ item, MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
          ∀ sealed, Represented t sealed item := by
  rcases input_command_term_creates_work sourceValue ready h with duplicate | saturated | invalid |
    ⟨batch, event, now, first, last, started, generated, creates⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (Or.inl invalid))
  · rcases input_start h with duplicate | saturated | invalid | ⟨selected, start, canonical, allowed⟩
    · exact Or.inl duplicate
    · exact Or.inr (Or.inl saturated)
    · exact Or.inr (Or.inr (Or.inl invalid))
    · have same := inputStart_unique start started
      subst selected
      refine Or.inr (Or.inr (Or.inr ⟨batch, event, now, first, last, started, generated, ?_⟩))
      intro t execution
      obtain ⟨valid, _, item, fields, canonicalItem, present⟩ := creates t execution
      exact ⟨valid, fun _ _ represented =>
        resident_input_preserves execution ready canonical (List.all_eq_true.mp allowed) represented,
        item, fields, canonicalItem, fun sealed => concrete_representation (present sealed)⟩

theorem started_term_input_work {state inputEntry born result next source : Term}
    {batch j r : List Term}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = source)
    (ready : QueueReady state)
    (input : Command.input state (.tuple [inputEntry, born]) j = .ok (result, r))
    (started : InputStart result batch)
    (applied : ResidentBatch state batch next) :
    QueueReady next ∧ (∀ sealed old, Represented state sealed old → Represented next sealed old) ∧
      ∃ event now first last item,
        Command.inputEvent (state.get (a "session_id")) source
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainTermInputFact event source item ∧ CanonicalQueueItem item ∧ ∀ sealed, Represented next sealed item := by
  rcases input_command_term_preserves sourceValue ready input with duplicate | saturated | invalid |
    ⟨planned, event, now, first, last, planStart, generated, candidate⟩
  · rw [duplicate] at started
    simp [InputStart, Command.duplicateInput, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [saturated] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · rw [invalid] at started
    simp [InputStart, Command.finish, Command.writeInput, Command.perform, a, b, list, Term.text] at started
  · have same := input_start_unique planStart started
    subst planned
    obtain ⟨nextReady, kept, item, fields, shape, present⟩ := candidate next applied
    exact ⟨nextReady, kept, event, now, first, last, item, generated, fields, shape, present⟩

end VerifiedKernel.Session.WorkConservation.ValueSemantics

namespace VerifiedKernel.Session.PendingRevision
open Data WorkConservation
set_option Elab.async false

theorem input_term_write_preserves {cursor final : Cursor} {inputEntry born result hwm source : Term}
    {batch j r : List Term}
    (sourceValue : RoundQuery.atomFirst inputEntry "source_message_id" = source)
    (ready : QueueReady cursor.working)
    (input : Command.input cursor.working (.tuple [inputEntry, born]) j = .ok (result, r))
    (started : InputStart result batch)
    (execution : Execution (resident (some cursor.pack) (a "write") (.tuple [list batch, hwm])) final) :
    final.baseline = cursor.baseline ∧ final.etag = cursor.etag ∧ final.events = cursor.events ++ batch ∧
      QueueReady final.working ∧ final.working.get (a "storage_format") = cursor.working.get (a "storage_format") ∧
      (∀ sealed old, ValueSemantics.Represented cursor.working sealed old → ValueSemantics.Represented final.working sealed old) ∧
      ∃ event now first last item,
        Command.inputEvent (cursor.working.get (a "session_id")) source
          (RoundQuery.atomFirst inputEntry "payload") now first = .ok (event, last) ∧
        MainTermInputFact event source item ∧ CanonicalQueueItem item ∧
        ∀ sealed, ValueSemantics.Represented final.working sealed item := by
  obtain ⟨_, _, baselineEq, etagEq, eventsEq, _, applied⟩ := write_executes execution
  obtain ⟨middle, inputBatch, hwmBatch⟩ := resident_batch_append applied
  obtain ⟨middleReady, oldKept, event, now, first, last, item, generated, fields, shape, present⟩ :=
    ValueSemantics.started_term_input_work sourceValue ready input started inputBatch
  obtain ⟨keys, metadata⟩ := hwm_metadata hwm
  obtain ⟨finalReady, _, kept⟩ := ValueSemantics.metadata_work hwmBatch keys metadata middleReady
  exact ⟨baselineEq, etagEq, eventsEq, finalReady, resident_batch_format applied,
    fun sealed old represented => kept sealed old (oldKept sealed old represented),
    event, now, first, last, item, generated, fields, shape, fun sealed => kept sealed item (present sealed)⟩

end VerifiedKernel.Session.PendingRevision
