import VerifiedKernelProofs.Session.WorkActivationConfirmation

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def ActivationCompletionQuery (args : Term) : Prop :=
  (∃ details checkpoint active,
    args = .tuple [.tuple [b "activation_written", details, checkpoint, active], a "ok"]) ∨
  ∃ response, args = .tuple [b "activated", response]

def ActivationCompletionResult (result : Term) : Prop :=
  result = Command.finish (a "ok") ∨
    ∃ scope, result = Command.perform (.tuple [a "draft_clear", scope]) (b "activated")

theorem activated_completion {state details result : Term} {journal rest : List Term}
    (call : Command.activated state details journal = .ok (result, rest)) : ActivationCompletionResult result := by
  unfold Command.activated at call
  repeat' first
    | (rw [pure_ok call]; exact Or.inl rfl)
    | (rw [pure_ok call]; exact Or.inr ⟨_, rfl⟩)
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem activation_completion_call {context : Context} {args result : Term} {journal rest : List Term}
    (allowed : ActivationCompletionQuery args)
    (call : queryCall context (a "resume") args journal = .ok (result, rest)) :
    ActivationCompletionResult result := by
  rcases allowed with ⟨details, checkpoint, active, rfl⟩ | ⟨response, rfl⟩
  · apply activated_completion
    simpa +decide [queryCall, Command.resume, Command.resumeCommitted, b, Term.text] using call
  · have same : result = Command.finish (a "ok") := by
      exact pure_ok call
    exact Or.inl same

inductive ActivationCompletionOutput (context : Context) : Output → Prop where
  | querying (args request : Term) (observations : List Term) (allowed : ActivationCompletionQuery args) :
      ActivationCompletionOutput context
        (some (queryCursor context (a "resume") args observations), .tuple [a "observe", request])
  | effect (scope : Term) : ActivationCompletionOutput context
      (some (.tuple [a "session_command_driver_effect", context.pack, b "activated", .tuple [a "draft_clear", scope]]),
        .tuple [a "effect", .tuple [a "draft_clear", scope]])
  | returned : ActivationCompletionOutput context (some context.pack, .tuple [a "return", a "ok", nil])
  | failed (response : Term) : ActivationCompletionOutput context (none, response)

theorem activation_completion_query (context : Context) (args : Term) (observations : List Term)
    (allowed : ActivationCompletionQuery args) :
    ActivationCompletionOutput context (query context (a "resume") args observations) := by
  rw [query_eq]
  split
  · rename_i result rest call
    split
    · rcases activation_completion_call allowed call with rfl | ⟨scope, rfl⟩
      · exact .returned
      · exact .effect scope
    · exact .failed _
  · exact .querying _ _ _ allowed
  · exact .failed _

theorem activation_completion_observe {context : Context} {saved request response : Term}
    (valid : ActivationCompletionOutput context (some saved, .tuple [a "observe", request])) :
    ActivationCompletionOutput context (resident (some saved) (a "resume") response) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | querying args issued observations allowed =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured, query_resume_captured]
    exact activation_completion_query _ _ _ allowed
  | effect => simp [a] at same
  | returned => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem activation_completion_effect {context : Context} {saved request response : Term}
    (valid : ActivationCompletionOutput context (some saved, .tuple [a "effect", request])) :
    ActivationCompletionOutput context (resident (some saved) (a "effect_result") response) := by
  generalize same : (some saved, Term.tuple [a "effect", request]) = output at valid
  cases valid with
  | effect scope =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured]
    cases allowed : effectResultValid (.tuple [a "draft_clear", scope]) response with
    | true =>
      rw [effect_captured _ _ _ _ allowed]
      exact activation_completion_query _ _ _ (Or.inr ⟨response, rfl⟩)
    | false =>
      rw [effect_rejected _ _ _ _ allowed]
      exact .failed _
  | querying => simp [a] at same
  | returned => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem activation_completion_preserved {context : Context} {initial final : Output}
    (trace : AdmissionTrace initial final) (valid : ActivationCompletionOutput context initial) :
    ActivationCompletionOutput context final := by
  induction trace with
  | done => exact valid
  | observe tail ih => exact ih (activation_completion_observe valid)
  | effect tail ih => exact ih (activation_completion_effect valid)

theorem activation_next_captured (state etag details checkpoint active : Term) :
    resident (some (.tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack,
      .tuple [b "activation_written", details, checkpoint, active]])) (a "next") nil =
      query (.committed state etag) (a "resume")
        (.tuple [.tuple [b "activation_written", details, checkpoint, active], a "ok"]) [] := rfl

/-- Draft cleanup and observation callbacks cannot replace the committed revision before the activation return. -/
theorem activation_return_captured {state etag details checkpoint active saved result returnedCheckpoint : Term}
    (trace : AdmissionTrace
      (resident (some (.tuple [a "session_command_driver_confirmed", (Revision.Cursor.committed state etag).pack,
        .tuple [b "activation_written", details, checkpoint, active]])) (a "next") nil)
      (some saved, .tuple [a "return", result, returnedCheckpoint])) :
    saved = (Revision.Cursor.committed state etag).pack ∧ result = a "ok" ∧ returnedCheckpoint = nil := by
  rw [activation_next_captured] at trace
  have valid := activation_completion_preserved trace
    (activation_completion_query _ _ [] (Or.inl ⟨details, checkpoint, active, rfl⟩))
  generalize same : (some saved, Term.tuple [a "return", result, returnedCheckpoint]) = output at valid
  cases valid with
  | returned =>
    simpa only [Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq, List.cons.injEq, and_true, true_and, and_assoc] using same
  | querying => simp [a] at same
  | effect => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem ActivationCommitTrace.return_has_durable_work {context : Context} {hwm prompt active checkpoint : Term}
    {durable : ArchivePublication.HotSnapshots}
    (trace : ActivationCommitTrace context hwm prompt active checkpoint durable)
    (ready : QueueReady context.candidate.working)
    (format : context.candidate.working.get (a "storage_format") = i 3)
    {saved result returnedCheckpoint : Term}
    (completion : AdmissionTrace (resident (some trace.fence.confirmed) (a "next") nil)
      (some saved, .tuple [a "return", result, returnedCheckpoint])) :
    result = a "ok" ∧ returnedCheckpoint = nil ∧
    ∃ etag snapshot,
      saved = (Revision.Cursor.committed trace.fence.stamped etag).pack ∧
      durable trace.fence.key etag snapshot ∧ QueueReady snapshot ∧ snapshot.get (a "storage_format") = i 3 ∧
      ∀ sealed item, ValueSemantics.Represented context.candidate.working sealed item →
        ValueSemantics.Represented snapshot sealed item := by
  obtain ⟨_, _, etag, snapshot, _, details, capturedCheckpoint, capturedActive,
    continuationEq, confirmedEq, _, stored, snapshotReady, snapshotFormat, kept⟩ :=
    trace.confirms_preserved_work ready format
  simp only [confirmedEq, continuationEq] at completion
  obtain ⟨savedEq, resultEq, checkpointEq⟩ := activation_return_captured completion
  exact ⟨resultEq, checkpointEq, etag, snapshot, savedEq, stored, snapshotReady, snapshotFormat, kept⟩

end VerifiedKernel.Session.CommandDriver
