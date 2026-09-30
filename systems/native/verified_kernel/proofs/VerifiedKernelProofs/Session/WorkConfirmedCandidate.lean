import VerifiedKernelProofs.Session.WorkCommandTrace
import VerifiedKernelProofs.Session.WorkSemanticPipeline
import VerifiedKernelProofs.Session.WorkCommitMetadata

namespace VerifiedKernel.Session.WorkConservation
open Data CommandExecution DurableConfirmation
set_option Elab.async false
namespace ValueSemantics

theorem confirmed_input_snapshot {s entry born result final : Term} {source : ByteArray} {j r : List Term}
    {effects : List (Term × Result)}
    (sourceValue : RoundQuery.atomFirst entry "source_message_id" = .binary source)
    (ready : QueueReady s) (format : s.get (a "storage_format") = i 3)
    (input : Command.input s (.tuple [entry, born]) j = .ok (result, r))
    (trace : Trace result effects final)
    (confirmed : final = Command.finish (.tuple [a "ok", a "committed"]) ∨
      ∃ notified, final = Command.perform (.tuple [a "notify", b "input_accepted", notified]) (b "input_notified")) :
    ∃ batch event now first last,
      InputStart result batch ∧
      (∃ before after, effects = before ++
        [(.tuple [a "write", list batch, list []], Result.ok), (a "durable_fence", Result.ok)] ++ after) ∧
      Command.inputEvent (s.get (a "session_id")) (.binary source)
        (RoundQuery.atomFirst entry "payload") now first = .ok (event, last) ∧
      ∀ t prepared stamped bytes before after metadata,
        ResidentBatch s batch t →
        Lifecycle.prepareWrite t before = .ok (.tuple [a "ok", prepared], after) →
        ResidentBatch prepared metadata stamped →
        (∀ event ∈ metadata, BinaryKeys event) →
        (∀ event ∈ metadata, CommitMetadata event) →
        SessionDomain.dispatch (some stamped) (.tuple [i 1, a "session", i 1, a "persist", nil]) =
          (some stamped, .tuple [i 1, a "ok", .binary bytes]) →
        ∃ snapshot, ETF.encode (.tuple [a "comma_internal_session", i 3, snapshot]) = .ok bytes ∧
          QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
          (∀ sealed item, Represented s sealed item → Represented snapshot sealed item) ∧
          ∃ item, MainInputFact event source item ∧ CanonicalQueueItem item ∧
            ∀ sealed, Represented snapshot sealed item := by
  rcases input_command_preserves sourceValue ready input with duplicate | saturated | invalid |
    ⟨batch, event, now, first, last, started, generated, applies⟩
  · rw [duplicate] at trace
    rcases duplicate_trace trace with ⟨_, finalRead⟩ | ⟨_, finalRead⟩ | ⟨reason, _, finalRead⟩
    all_goals rw [finalRead] at confirmed
    all_goals simp [Command.duplicateInput, Command.perform, Command.finish, a, b, Term.text] at confirmed
  · rw [saturated] at trace
    rw [(return_trace trace).2] at confirmed
    simp [Command.perform, Command.finish, a] at confirmed
  · rw [invalid] at trace
    rw [(return_trace trace).2] at confirmed
    simp [Command.perform, Command.finish, a] at confirmed
  · have matching : final = Command.perform (.tuple [a "notify", b "input_accepted", list batch]) (b "input_notified") ∨
        final = Command.finish (.tuple [a "ok", a "committed"]) := by
      rcases confirmed with committed | ⟨notified, notification⟩
      · exact Or.inr committed
      · obtain ⟨same, _⟩ := input_start_trace_notification started trace notification
        exact Or.inl (by rw [← same]; exact notification)
    refine ⟨batch, event, now, first, last, started,
      input_start_trace_write_fence started trace matching, generated, ?_⟩
    intro t prepared stamped bytes before after metadata execution prepare stamping canonicalMetadata admittedMetadata persist
    obtain ⟨nextReady, kept, item, fields, canonical, present⟩ := applies t execution
    have nextFormat := (resident_batch_format execution).trans format
    obtain ⟨next, same, preparedFormat, preparedReady, _⟩ :=
      prepareWrite_modern nextFormat (Or.inr rfl) nextReady prepare
    have equal : prepared = next := by
      simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using same
    subst next
    obtain ⟨queue, records, _⟩ := commit_metadata_batch_frames stamping canonicalMetadata admittedMetadata
    have stampedReady := queue_frame_ready queue preparedReady
    have stampedFormat := queue.2.2.2.2.trans preparedFormat
    obtain ⟨snapshot, rest, persisted, encoded⟩ := persist_dispatch_snapshot persist
    have snapshotReady := (persistable_preserves stampedReady persisted).1
    have snapshotFormat := (persistable_queue_frame persisted).2.2.2.2.trans stampedFormat
    have preserves : ∀ sealed work, Represented t sealed work → Represented snapshot sealed work := by
      intro sealed work represented
      exact work_fields_preserves (persistable_work_fields persisted)
        (execution_preserves
          (fun _ present => concrete_representation_frame_extends queue.1 records present)
          (fun _ present => record_survives records present)
          (prepareWrite_preserves nextReady nextFormat prepare represented))
    exact ⟨snapshot, encoded, snapshotReady, snapshotFormat,
      fun sealed work represented => preserves sealed work (kept sealed work represented),
      item, fields, canonical, fun sealed => preserves sealed item (present sealed)⟩

end ValueSemantics
end VerifiedKernel.Session.WorkConservation
