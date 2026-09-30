import VerifiedKernelProofs.Session.WorkDriverQuery

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def inputWriteContinuation (batch : List Term) : Term :=
  .tuple [b "durable_fence", .tuple [b "input_written", list batch]]

theorem issue_input_write (context : Context) (batch : List Term) :
    issue context (Command.writeInput (list batch)) =
      issueWrite context (inputWriteContinuation batch) batch nil := rfl

theorem input_issue_terminal {context : Context} {args result : Term} {journal rest : List Term}
    (call : Command.input context.candidate.working args journal = .ok (result, rest)) :
    QueryTerminal (issue context result) := by
  rcases input_start call with duplicate | saturated | invalidInput | ⟨batch, started, _, _⟩
  · rw [duplicate]
    simp [QueryTerminal, Command.duplicateInput, Command.perform, issue, a]
  · rw [saturated]
    simp [QueryTerminal, Command.finish, issue, a]
  · rw [invalidInput]
    simp [QueryTerminal, Command.finish, issue, a]
  · have fixed := input_write_unchanged (continuation := inputWriteContinuation batch) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_input_write, fixed]
      simp [QueryTerminal, preparedWrite, a]
    · rw [workspaceStart]
      simp [QueryTerminal, Command.perform, issue, a]

theorem input_query_observation_resource {context : Context} {args checkpoint saved request : Term}
    {observations : List Term}
    (h : query context (a "start") (.tuple [a "input", args, checkpoint]) observations =
      (some saved, .tuple [a "observe", request])) :
    saved = queryCursor context (a "start") (.tuple [a "input", args, checkpoint]) observations := by
  rw [query_eq] at h
  split at h
  · rename_i result rest call
    split at h
    · have terminal := input_issue_terminal (context := context) (args := args) call
      exact (terminal.2 request (congrArg Prod.snd h)).elim
    · have impossible := congrArg Prod.fst h
      cases impossible
  · exact (Option.some.inj (congrArg Prod.fst h)).symm
  · have impossible := congrArg Prod.fst h
    cases impossible

/-- Any finite raw observation loop for input is a captured query trace, not an independent phase assumption. -/
theorem input_observations_reflect {context : Context} {args checkpoint : Term} {observations : List Term}
    {final : Output}
    (trace : ObservationTrace (query context (a "start") (.tuple [a "input", args, checkpoint]) observations) final) :
    QueryTrace (query context (a "start") (.tuple [a "input", args, checkpoint]) observations) final := by
  generalize origin : query context (a "start") (.tuple [a "input", args, checkpoint]) observations = output at trace
  induction trace generalizing observations with
  | done output => exact .done output
  | @resume saved request observation final tail ih =>
    have captured := input_query_observation_resource origin
    subst saved
    apply QueryTrace.resume
    apply ih
    exact (query_resume_captured _ _ _ _ _).symm

theorem input_trace_actual {context : Context} {args checkpoint : Term} {observations : List Term}
    {final : Output}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", args, checkpoint], list observations])) final)
    (terminal : QueryTerminal final) :
    ∃ journal result rest,
      Command.input context.candidate.working args journal = .ok (result, rest) ∧
      settled rest = true ∧ final = issue context result := by
  rw [start_captured] at trace
  have trace := input_observations_reflect trace
  obtain ⟨journal, result, rest, call, complete, issued⟩ := query_trace_call trace terminal
  exact ⟨journal, result, rest, call, complete, issued⟩

/-- A directly issued input write comes from this initial command and retains its exact fence continuation. -/
theorem input_initial_write {context : Context} {args checkpoint saved : Term}
    {observations batch : List Term}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list batch])) :
    ∃ journal result rest,
      Command.input context.candidate.working args journal = .ok (result, rest) ∧
      InputStart result batch ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        inputWriteContinuation batch, list batch, nil] := by
  have terminal : QueryTerminal (some saved, .tuple [a "validate_write", list batch]) := by
    simp [QueryTerminal, a]
  obtain ⟨journal, result, rest, call, _, issued⟩ := input_trace_actual trace terminal
  have actual := issued.symm
  rcases input_start call with duplicate | saturated | invalidInput | ⟨original, started, _, _⟩
  · rw [duplicate] at actual
    simp [Command.duplicateInput, Command.perform, issue, a] at actual
  · rw [saturated] at actual
    simp [Command.finish, issue, a] at actual
  · rw [invalidInput] at actual
    simp [Command.finish, issue, a] at actual
  · have fixed := input_write_unchanged (continuation := inputWriteContinuation original) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_input_write, fixed] at actual
      simp only [preparedWrite, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
        List.cons.injEq, and_true, true_and, list, Term.list.injEq] at actual
      obtain ⟨savedEq, batchEq⟩ := actual
      subst batch
      exact ⟨journal, result, rest, call, Or.inl direct, savedEq.symm⟩
    · rw [workspaceStart] at actual
      simp [Command.perform, issue, a] at actual

theorem input_initial_workspace {context : Context} {args checkpoint saved request : Term}
    {observations : List Term}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "input", args, checkpoint], list observations]))
      (some saved, .tuple [a "effect", request])) :
    ∃ journal result rest batch operation metadata workspace billing,
      Command.input context.candidate.working args journal = .ok (result, rest) ∧
      InputStart result batch ∧
      request = .tuple [a "workspace", operation, metadata, workspace, billing] ∧
      saved = .tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list batch, Term.bool true], request] := by
  have terminal : QueryTerminal (some saved, .tuple [a "effect", request]) := by
    simp [QueryTerminal, a]
  obtain ⟨journal, result, rest, call, _, issued⟩ := input_trace_actual trace terminal
  have actual := issued.symm
  rcases input_start call with duplicate | saturated | invalidInput | ⟨batch, started, _, _⟩
  · rw [duplicate] at actual
    simp [Command.duplicateInput, Command.perform, issue, a] at actual
  · rw [saturated] at actual
    simp [Command.finish, issue, a] at actual
  · rw [invalidInput] at actual
    simp [Command.finish, issue, a] at actual
  · have fixed := input_write_unchanged (continuation := inputWriteContinuation batch) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_input_write, fixed] at actual
      simp [preparedWrite, a] at actual
    · rw [workspaceStart] at actual
      change (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list batch, Term.bool true],
        .tuple [a "workspace", operation, metadata, workspace, billing]]),
        Term.tuple [a "effect", .tuple [a "workspace", operation, metadata, workspace, billing]]) =
        (some saved, Term.tuple [a "effect", request]) at actual
      have requestEq : request = .tuple [a "workspace", operation, metadata, workspace, billing] := by
        simpa only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] using
          (congrArg Prod.snd actual).symm
      exact ⟨journal, result, rest, batch, operation, metadata, workspace, billing, call,
        Or.inr ⟨operation, metadata, workspace, billing, workspaceStart⟩, requestEq,
        by rw [requestEq]; exact (Option.some.inj (congrArg Prod.fst actual)).symm⟩

/-- Workspace failure cannot reach a write. Success retains the batch admitted by the initial input command. -/
theorem input_workspace_write {context : Context} {args initial saved operation metadata workspace billing : Term}
    {journal rest original batch : List Term} {response : DurableConfirmation.Result}
    (input : Command.input context.candidate.working args journal = .ok (initial, rest))
    (started : InputStart initial original)
    (trace : ObservationTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list original, Term.bool true],
        .tuple [a "workspace", operation, metadata, workspace, billing]]))
        (a "effect_result") response.wire)
      (some saved, .tuple [a "validate_write", list batch])) :
    response = .ok ∧ batch = original ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        inputWriteContinuation original, list original, nil] := by
  have fixed := input_write_unchanged (continuation := inputWriteContinuation original) input started
  cases response with
  | ok =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace
    change ObservationTrace (issue context (Command.writeInput (list original))) _ at trace
    rw [issue_input_write, fixed] at trace
    have actual := (trace.fixed (by simp [preparedWrite, a])).symm
    simp only [preparedWrite, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
      List.cons.injEq, and_true, true_and, list, Term.list.injEq] at actual
    exact ⟨rfl, actual.2.symm, actual.1.symm⟩
  | error reason =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace
    change ObservationTrace (issue context (Command.finish (.tuple [a "error", reason]))) _ at trace
    have issued := trace.fixed (by simp [Command.finish, issue, a])
    simp [Command.finish, issue, a] at issued

inductive InputAdmissionTrace (context : Context) (args checkpoint : Term) (observations : List Term) :
    Output → Prop where
  | direct {final : Output}
      (trace : ObservationTrace
        (resident (some context.pack) (a "start")
          (.tuple [.tuple [a "input", args, checkpoint], list observations])) final) :
      InputAdmissionTrace context args checkpoint observations final
  | workspace {saved request : Term} {response : DurableConfirmation.Result} {final : Output}
      (head : ObservationTrace
        (resident (some context.pack) (a "start")
          (.tuple [.tuple [a "input", args, checkpoint], list observations]))
        (some saved, .tuple [a "effect", request]))
      (tail : ObservationTrace (resident (some saved) (a "effect_result") response.wire) final) :
      InputAdmissionTrace context args checkpoint observations final

/-- Both admission paths derive the batch and continuation from the same initial native command. -/
theorem input_admission_write {context : Context} {args checkpoint saved : Term}
    {observations batch : List Term}
    (trace : InputAdmissionTrace context args checkpoint observations
      (some saved, .tuple [a "validate_write", list batch])) :
    ∃ journal result rest,
      Command.input context.candidate.working args journal = .ok (result, rest) ∧
      InputStart result batch ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        inputWriteContinuation batch, list batch, nil] := by
  cases trace with
  | direct trace => exact input_initial_write trace
  | workspace head tail =>
    obtain ⟨journal, result, rest, original, operation, metadata, workspace, billing,
      call, started, requestEq, savedEq⟩ := input_initial_workspace head
    rw [savedEq, requestEq] at tail
    obtain ⟨_, batchEq, finalEq⟩ := input_workspace_write call started tail
    subst batch
    exact ⟨journal, result, rest, call, started, finalEq⟩

end VerifiedKernel.Session.CommandDriver
