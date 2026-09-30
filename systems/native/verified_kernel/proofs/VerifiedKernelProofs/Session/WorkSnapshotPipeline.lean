import VerifiedKernelProofs.Session.WorkSnapshot
import VerifiedKernelProofs.Session.WorkStorageFormat
import VerifiedKernelProofs.Session.WorkInputAdmissionActual
import VerifiedKernelProofs.Session.WorkResidentSafety

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

theorem prepared_snapshot_preserves {s prepared : Term} {bytes : ByteArray} {j r : List Term}
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (prepare : Lifecycle.prepareWrite s j = .ok (.tuple [a "ok", prepared], r))
    (persist : SessionDomain.dispatch (some prepared) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
      (some prepared, .tuple [i 1, a "ok", .binary bytes])) :
    ∃ snapshot, ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented snapshot sealed item := by
  obtain ⟨next, same, nextFormat, nextReady, preserved⟩ := prepareWrite_modern format (Or.inr rfl) ready prepare
  have equal : prepared = next := by simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
  subst next
  obtain ⟨snapshot, rest, persisted, encoded⟩ := persist_dispatch_snapshot persist
  obtain ⟨snapshotReady, kept⟩ := persistable_preserves nextReady persisted
  exact ⟨snapshot, encoded, snapshotReady, (persistable_queue_frame persisted).2.2.2.2.trans nextFormat,
    fun sealed item present => kept sealed item (preserved sealed item present)⟩

theorem materialize_snapshot_preserves {s t prepared : Term} {bytes : ByteArray}
    {events j r first last : List Term} {limit : Int} {wake : Bool} {hwm : Term}
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (planned : StateQuery.materialize s limit j = .ok (.tuple [list events, Term.bool wake, hwm], r))
    (execution : ResidentBatch s events t)
    (prepare : Lifecycle.prepareWrite t first = .ok (.tuple [a "ok", prepared], last))
    (persist : SessionDomain.dispatch (some prepared) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
      (some prepared, .tuple [i 1, a "ok", .binary bytes])) :
    ∃ snapshot, ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
      QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented snapshot sealed item := by
  obtain ⟨snapshot, encoded, valid, modern, kept⟩ := prepared_snapshot_preserves
    (materialize_resident_ready ready planned execution) ((resident_batch_format execution).trans format) prepare persist
  exact ⟨snapshot, encoded, valid, modern, fun sealed item present =>
    kept sealed item (materialize_resident_preserves ready.1 ready.2.1 planned execution sealed item present)⟩

theorem input_command_snapshot {s entry born result : Term} {source : ByteArray} {j r : List Term}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (h : Command.input s (.tuple [entry, born]) j = .ok (result, r)) :
    result = Command.duplicateInput ∨
    result = Command.finish (.tuple [a "error", a "saturated"]) ∨
    result = Command.finish (.tuple [a "error", a "invalid_delivery_events"]) ∨
    ∃ batch event now first last,
      InputStart result batch ∧
      Command.inputEvent (s.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      ∀ t prepared bytes before after,
        ResidentBatch s batch t →
        Lifecycle.prepareWrite t before = .ok (.tuple [a "ok", prepared], after) →
        SessionDomain.dispatch (some prepared) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
          (some prepared, .tuple [i 1, a "ok", .binary bytes]) →
        ∃ snapshot, ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
          QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
          (∀ sealed item, ConcreteRepresented s sealed item → ConcreteRepresented snapshot sealed item) ∧
          ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
            ∀ sealed, ConcreteRepresented snapshot sealed item := by
  rcases input_command_creates_work sourceValue ready h with duplicate | saturated | invalid |
    ⟨batch, event, now, first, last, start, generated, executed⟩
  · exact Or.inl duplicate
  · exact Or.inr (Or.inl saturated)
  · exact Or.inr (Or.inr (Or.inl invalid))
  · refine Or.inr (Or.inr (Or.inr ⟨batch, event, now, first, last, start, generated, ?_⟩))
    intro t prepared bytes before after execution prepare persist
    obtain ⟨valid, preserved, item, mainFact, canonical, present⟩ := executed t execution
    obtain ⟨snapshot, encoded, snapshotReady, snapshotFormat, kept⟩ := prepared_snapshot_preserves valid
      ((resident_batch_format execution).trans format) prepare persist
    exact ⟨snapshot, encoded, snapshotReady, snapshotFormat,
      fun sealed old represented => kept sealed old (preserved sealed old represented),
      item, mainFact, canonical, fun sealed => kept sealed item (present sealed)⟩

end VerifiedKernel.Session.WorkConservation
