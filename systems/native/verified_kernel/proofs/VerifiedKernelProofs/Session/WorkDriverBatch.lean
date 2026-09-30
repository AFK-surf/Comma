import VerifiedKernelProofs.Session.WorkDriverInput

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def inputFenceContinuation (events : List Term) : Term := .tuple [b "input_written", list events]

def inputFenced (cursor : PendingRevision.Cursor) (events : List Term) : Output :=
  (some (.tuple [a "session_command_driver_fence", cursor.pack, inputFenceContinuation events]),
    .tuple [a "fence"])

theorem input_write_completed (context : Context) (events : List Term) (cursor : PendingRevision.Cursor) :
    acceptWrite context (inputWriteContinuation events) (some cursor.pack, .tuple [a "done"]) =
      inputFenced cursor events := rfl

theorem pending_unpack_captured {saved : Term} {cursor : PendingRevision.Cursor}
    (h : PendingRevision.unpack saved = some cursor) : saved = cursor.pack := by
  unfold PendingRevision.unpack at h
  split at h
  · cases h
    rfl
  · cases h

theorem accept_input_done {context : Context} {events : List Term} {inner : Output}
    {final : PendingRevision.Cursor}
    (h : acceptWrite context (inputWriteContinuation events) inner = inputFenced final events) :
    inner = (some final.pack, .tuple [a "done"]) := by
  unfold acceptWrite at h
  split at h
  · rename_i saved
    split at h
    · rename_i cursor opened
      change inputFenced cursor events = inputFenced final events at h
      have packed : cursor.pack = final.pack := by
        simpa only [inputFenced, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
          List.cons.injEq, and_true, true_and] using h
      have same := PendingRevision.pack_injective packed
      subst cursor
      rw [pending_unpack_captured opened]
    · have impossible := congrArg Prod.fst h
      cases impossible
  · simp [inputFenced, a] at h
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem accept_input_batch {context : Context} {events : List Term} {inner : Output} {batch response : Term}
    (h : acceptWrite context (inputWriteContinuation events) inner =
      (some (.tuple [a "session_command_driver_batch", context.pack, inputWriteContinuation events, batch]), response)) :
    inner = (some batch, response) := by
  unfold acceptWrite at h
  split at h
  · split at h
    · rename_i cursor opened
      change inputFenced cursor events = _ at h
      simp [inputFenced, a] at h
    · have impossible := congrArg Prod.fst h
      cases impossible
  · simp only [Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq, List.cons.injEq,
      and_true, true_and] at h
    obtain ⟨rfl, rfl⟩ := h
    rfl
  · have impossible := congrArg Prod.fst h
    cases impossible

/-- Each step is an actual native batch run or resume, ending at the captured input fence. -/
inductive InputBatchTrace (context : Context) (events : List Term) : Output → PendingRevision.Cursor → Prop where
  | done (cursor : PendingRevision.Cursor) : InputBatchTrace context events (inputFenced cursor events) cursor
  | run {cursor : PendingRevision.Cursor} {state event : Term} {remaining observations : List Term}
      {final : PendingRevision.Cursor}
      (tail : InputBatchTrace context events
        (resident (some (.tuple [a "session_command_driver_batch", context.pack, inputWriteContinuation events,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: remaining)]]))
          (a "run") (list observations)) final) :
      InputBatchTrace context events
        (some (.tuple [a "session_command_driver_batch", context.pack, inputWriteContinuation events,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.pending state (event :: remaining)]]),
          .tuple [a "next"]) final
  | resume {cursor : PendingRevision.Cursor} {token request observation : Term} {remaining : List Term}
      {final : PendingRevision.Cursor}
      (tail : InputBatchTrace context events
        (resident (some (.tuple [a "session_command_driver_batch", context.pack, inputWriteContinuation events,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token remaining]]))
          (a "resume") observation) final) :
      InputBatchTrace context events
        (some (.tuple [a "session_command_driver_batch", context.pack, inputWriteContinuation events,
          .tuple [a "session_pending_batch", cursor.pack, BatchExecution.observing token remaining]]),
          .tuple [a "observe", request]) final

theorem input_batch_reflect {context : Context} {events : List Term} {inner : Output}
    {final : PendingRevision.Cursor}
    (trace : InputBatchTrace context events (acceptWrite context (inputWriteContinuation events) inner) final) :
    Revision.Execution inner final := by
  generalize origin : acceptWrite context (inputWriteContinuation events) inner = output at trace
  induction trace generalizing inner with
  | done cursor =>
    rw [accept_input_done origin]
    exact .done cursor
  | @run cursor state event remaining observations final tail ih =>
    rw [accept_input_batch origin]
    apply Revision.Execution.run (observations := observations)
    apply ih
    cases context <;> rfl
  | @resume cursor token request observation remaining final tail ih =>
    rw [accept_input_batch origin]
    apply Revision.Execution.resume (observation := observation)
    apply ih
    cases context <;> rfl

/-- The admitted command, native write, and fence continuation now share one execution history. -/
theorem input_admission_applied {context : Context} {args checkpoint saved : Term}
    {observations events : List Term} {final : PendingRevision.Cursor}
    (admission : InputAdmissionTrace context args checkpoint observations
      (some saved, .tuple [a "validate_write", list events]))
    (execution : InputBatchTrace context events (resident (some saved) (a "write_result") (a "ok")) final) :
    ∃ journal result rest,
      Command.input context.candidate.working args journal = .ok (result, rest) ∧
      InputStart result events ∧
      Revision.Execution (Revision.resident (some context.pack) (a "write") (.tuple [list events, nil])) final := by
  obtain ⟨journal, result, rest, call, started, captured⟩ := input_admission_write admission
  rw [captured, write_captured] at execution
  exact ⟨journal, result, rest, call, started, input_batch_reflect execution⟩

end VerifiedKernel.Session.CommandDriver
