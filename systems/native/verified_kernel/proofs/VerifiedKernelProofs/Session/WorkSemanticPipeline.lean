import VerifiedKernelProofs.Session.WorkSemanticExecution

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem inputStart_unique {result : Term} {first last : List Term}
    (before : InputStart result first) (after : InputStart result last) : first = last := by
  rcases before with before | ⟨operation, metadata, workspace, billing, before⟩ <;>
    rcases after with after | ⟨operation', metadata', workspace', billing', after⟩
  all_goals rw [before] at after
  all_goals simp_all [Command.writeInput, Command.perform, a, b, list, Term.text]

namespace ValueSemantics

theorem input_command_preserves {s entry born result : Term} {source : ByteArray} {j r : List Term}
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
        (∀ sealed item, Represented s sealed item → Represented t sealed item) ∧
        ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
          ∀ sealed, Represented t sealed item := by
  rcases input_command_creates_work sourceValue ready h with duplicate | saturated | invalid |
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
      exact ⟨valid, fun _ _ represented => resident_input_preserves execution ready canonical (List.all_eq_true.mp allowed) represented,
        item, fields, canonicalItem, fun sealed => concrete_representation (present sealed)⟩

theorem persist_load_preserves {s snapshot decodedState loaded : Term} {bytes : ByteArray}
    {resident : Option Term} {rest : List Term}
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (persisted : Lifecycle.persistable s [] = .ok (snapshot, rest))
    (exported : SessionDomain.dispatch (some s) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
      (some s, .tuple [i 1, a "ok", .binary bytes]))
    (decoded : ETF.decode bytes = .ok (.tuple [a "comma_internal_session", i 3, decodedState]))
    (codec : Equivalent snapshot decodedState)
    (reload : ReloadTrace
      (SessionDomain.dispatch resident (.tuple [i 1, a "session", i 1, a "load", .binary bytes]))
      (some loaded, .tuple [i 1, a "ok", .tuple [a "done"]])) :
    ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      QueueReady loaded ∧ loaded.get (a "storage_format") = i 3 ∧
      ∀ sealed item, Represented s sealed item → Represented loaded sealed item := by
  obtain ⟨encodedState, after, actualPersisted, encoded⟩ := persist_dispatch_snapshot exported
  obtain ⟨same, _⟩ := Prod.mk.inj (Except.ok.inj (persisted.symm.trans actualPersisted))
  subst encodedState
  have snapshotReady := (persistable_preserves ready persisted).1
  have snapshotFormat := (persistable_queue_frame persisted).2.2.2.2.trans format
  have decodedReady := codec.ready snapshotReady
  have decodedFormat : decodedState.get (a "storage_format") = i 3 := by
    have field := codec.get (a "storage_format")
    rw [snapshotFormat] at field
    exact field.integer
  have loadedReady := load_trace_preserves decoded decodedReady decodedFormat reload
  refine ⟨encoded, loadedReady.1, loadedReady.2.1, ?_⟩
  intro sealed item represented
  exact load_preserves decoded decodedReady reload
    (codec.represents (work_fields_preserves (persistable_work_fields persisted) represented))

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
