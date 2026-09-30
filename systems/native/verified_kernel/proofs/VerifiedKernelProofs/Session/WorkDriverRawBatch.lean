import VerifiedKernelProofs.Session.WorkDriverBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- The host follows public batch responses without inspecting native resource tags. -/
inductive BatchTrace : Output → Output → Prop where
  | done (output : Output) : BatchTrace output output
  | run {saved : Term} {observations : List Term} {final : Output}
      (tail : BatchTrace (resident (some saved) (a "run") (list observations)) final) :
      BatchTrace (some saved, .tuple [a "next"]) final
  | resume {saved request observation : Term} {final : Output}
      (tail : BatchTrace (resident (some saved) (a "resume") observation) final) :
      BatchTrace (some saved, .tuple [a "observe", request]) final

def inputBatchCursor (context : Context) (events : List Term)
    (cursor : PendingRevision.Cursor) (batch : Term) : Term :=
  .tuple [a "session_command_driver_batch", context.pack, inputWriteContinuation events,
    .tuple [a "session_pending_batch", cursor.pack, batch]]

inductive InputBatchOutput (context : Context) (events : List Term) : Output → Prop where
  | done (cursor : PendingRevision.Cursor) : InputBatchOutput context events (inputFenced cursor events)
  | run (cursor : PendingRevision.Cursor) (state event : Term) (remaining : List Term) :
      InputBatchOutput context events
        (some (inputBatchCursor context events cursor (BatchExecution.pending state (event :: remaining))),
          .tuple [a "next"])
  | resume (cursor : PendingRevision.Cursor) (token request : Term) (remaining : List Term) :
      InputBatchOutput context events
        (some (inputBatchCursor context events cursor (BatchExecution.observing token remaining)),
          .tuple [a "observe", request])
  | failed (response : Term) : InputBatchOutput context events (none, response)

theorem input_batch_next_valid (context : Context) (events : List Term)
    (cursor : PendingRevision.Cursor) (state : Term) (remaining : List Term) :
    InputBatchOutput context events
      (acceptWrite context (inputWriteContinuation events)
        (PendingRevision.accept cursor (BatchExecution.next state remaining))) := by
  cases remaining with
  | nil => exact .done { cursor with working := state }
  | cons event remaining => exact .run cursor state event remaining

theorem input_batch_accept_valid (context : Context) (events : List Term)
    (cursor : PendingRevision.Cursor) (remaining : List Term) (result : Term) :
    InputBatchOutput context events
      (acceptWrite context (inputWriteContinuation events)
        (PendingRevision.accept cursor (BatchExecution.accept remaining result))) := by
  unfold BatchExecution.accept
  split
  · exact input_batch_next_valid _ _ _ _ _
  · exact .resume cursor _ _ remaining
  · exact .failed _

theorem input_batch_run_captured (context : Context) (events : List Term)
    (cursor : PendingRevision.Cursor) (state event : Term) (remaining observations : List Term) :
    resident (some (inputBatchCursor context events cursor (BatchExecution.pending state (event :: remaining))))
      (a "run") (list observations) =
      acceptWrite context (inputWriteContinuation events)
        (PendingRevision.accept cursor (BatchExecution.accept remaining (runTrusted state event observations))) := by
  cases context <;> rfl

theorem input_batch_resume_captured (context : Context) (events : List Term)
    (cursor : PendingRevision.Cursor) (token observation : Term) (remaining : List Term) :
    resident (some (inputBatchCursor context events cursor (BatchExecution.observing token remaining)))
      (a "resume") observation =
      acceptWrite context (inputWriteContinuation events)
        (PendingRevision.accept cursor (BatchExecution.accept remaining (resumeTrusted token observation))) := by
  cases context <;> rfl

theorem input_batch_start_valid (context : Context) (events : List Term) :
    InputBatchOutput context events
      (acceptWrite context (inputWriteContinuation events)
        (Revision.resident (some context.pack) (a "write") (.tuple [list events, nil]))) := by
  rw [Revision.write_captured]
  change InputBatchOutput context events
    (acceptWrite context (inputWriteContinuation events) (PendingRevision.write context.candidate events nil))
  unfold PendingRevision.write
  split
  · exact input_batch_next_valid _ _ _ _ _
  · exact .failed _
  · exact .failed _

theorem input_batch_next_shape {context : Context} {events : List Term} {saved : Term}
    (valid : InputBatchOutput context events (some saved, .tuple [a "next"])) :
    ∃ cursor state event remaining,
      saved = inputBatchCursor context events cursor (BatchExecution.pending state (event :: remaining)) := by
  generalize same : (some saved, Term.tuple [a "next"]) = output at valid
  cases valid with
  | done => simp [inputFenced, a] at same
  | run cursor state event remaining => exact ⟨cursor, state, event, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | resume => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem input_batch_observation_shape {context : Context} {events : List Term} {saved request : Term}
    (valid : InputBatchOutput context events (some saved, .tuple [a "observe", request])) :
    ∃ cursor token remaining,
      saved = inputBatchCursor context events cursor (BatchExecution.observing token remaining) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | done => simp [inputFenced, a] at same
  | run => simp [a] at same
  | resume cursor token request remaining => exact ⟨cursor, token, remaining, Option.some.inj (congrArg Prod.fst same)⟩
  | failed => cases congrArg Prod.fst same

theorem input_batch_trace_reflect {context : Context} {events : List Term} {initial : Output}
    {final : PendingRevision.Cursor}
    (valid : InputBatchOutput context events initial)
    (trace : BatchTrace initial (inputFenced final events)) :
    InputBatchTrace context events initial final := by
  generalize ending : inputFenced final events = output at trace
  induction trace with
  | done output =>
    subst output
    exact .done final
  | @run saved observations output tail ih =>
    obtain ⟨cursor, state, event, remaining, rfl⟩ := input_batch_next_shape valid
    apply InputBatchTrace.run (observations := observations)
    apply ih
    · rw [input_batch_run_captured]
      exact input_batch_accept_valid _ _ _ _ _
    · exact ending
  | @resume saved request observation output tail ih =>
    obtain ⟨cursor, token, remaining, rfl⟩ := input_batch_observation_shape valid
    apply InputBatchTrace.resume (observation := observation)
    apply ih
    · rw [input_batch_resume_captured]
      exact input_batch_accept_valid _ _ _ _ _
    · exact ending

theorem input_raw_admission_applied {context : Context} {args checkpoint saved : Term}
    {observations events : List Term} {final : PendingRevision.Cursor}
    (admission : InputAdmissionTrace context args checkpoint observations
      (some saved, .tuple [a "validate_write", list events]))
    (execution : BatchTrace (resident (some saved) (a "write_result") (a "ok"))
      (inputFenced final events)) :
    ∃ journal result rest,
      Command.input context.candidate.working args journal = .ok (result, rest) ∧
      InputStart result events ∧
      Revision.Execution (Revision.resident (some context.pack) (a "write") (.tuple [list events, nil])) final := by
  obtain ⟨journal, result, rest, call, started, captured⟩ := input_admission_write admission
  rw [captured, write_captured] at execution
  have reflected := input_batch_trace_reflect (input_batch_start_valid context events) execution
  exact ⟨journal, result, rest, call, started, input_batch_reflect reflected⟩

end VerifiedKernel.Session.CommandDriver
