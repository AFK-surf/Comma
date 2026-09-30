import VerifiedKernelProofs.Session.WorkDriverQuery
import VerifiedKernelProofs.Session.WorkDriverRawAdmission
import VerifiedKernelProofs.Session.WorkLogAdmission
import VerifiedKernelProofs.Session.WorkDriverFencedBatch

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

def logWriteContinuation : Term := .tuple [b "durable_fence", b "log_written"]

theorem issue_log_write (context : Context) (batch : List Term) :
    issue context (Command.writeInput (list batch) false) =
      issueWrite context logWriteContinuation batch nil := rfl

theorem log_write_unchanged {context : Context} {entry checkpoint result continuation : Term}
    {batch journal rest : List Term}
    (call : Command.start context.candidate.working (.tuple [a "log", entry, checkpoint]) journal =
      .ok (result, rest))
    (started : InputStart result batch false) :
    issueWrite context continuation batch nil = preparedWrite context continuation batch nil := by
  have noClock : batch.any needsTimestamp = false := List.any_eq_false.mpr (by
    intro event member
    simp [timestamp_fixed_no_clock (log_timestamp_fixed call started event member)])
  simp only [issueWrite, noClock, Bool.false_eq_true, ↓reduceIte]

theorem log_issue_terminal {context : Context} {entry checkpoint result : Term} {journal rest : List Term}
    (call : Command.start context.candidate.working (.tuple [a "log", entry, checkpoint]) journal =
      .ok (result, rest)) : QueryTerminal (issue context result) := by
  rcases log_start call with invalidRole | invalidInput | ⟨batch, started, _, _⟩
  · rw [invalidRole]
    simp [QueryTerminal, Command.finish, issue, a]
  · rw [invalidInput]
    simp [QueryTerminal, Command.finish, issue, a]
  · have fixed := log_write_unchanged (continuation := logWriteContinuation) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_log_write, fixed]
      simp [QueryTerminal, preparedWrite, a]
    · rw [workspaceStart]
      simp [QueryTerminal, Command.perform, issue, a]

theorem log_query_observation_resource {context : Context} {entry checkpoint saved request : Term}
    {observations : List Term}
    (h : query context (a "start") (.tuple [a "log", entry, checkpoint]) observations =
      (some saved, .tuple [a "observe", request])) :
    saved = queryCursor context (a "start") (.tuple [a "log", entry, checkpoint]) observations := by
  rw [query_eq] at h
  split at h
  · rename_i result rest call
    split at h
    · have terminal := log_issue_terminal (context := context) (entry := entry)
        (checkpoint := checkpoint) call
      exact (terminal.2 request (congrArg Prod.snd h)).elim
    · have impossible := congrArg Prod.fst h
      cases impossible
  · exact (Option.some.inj (congrArg Prod.fst h)).symm
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem log_observations_reflect {context : Context} {entry checkpoint : Term} {observations : List Term}
    {final : Output}
    (trace : ObservationTrace (query context (a "start") (.tuple [a "log", entry, checkpoint]) observations) final) :
    QueryTrace (query context (a "start") (.tuple [a "log", entry, checkpoint]) observations) final := by
  generalize origin : query context (a "start") (.tuple [a "log", entry, checkpoint]) observations = output at trace
  induction trace generalizing observations with
  | done output => exact .done output
  | @resume saved request observation final tail ih =>
    have captured := log_query_observation_resource origin
    subst saved
    apply QueryTrace.resume
    apply ih
    exact (query_resume_captured _ _ _ _ _).symm

theorem log_trace_actual {context : Context} {entry checkpoint : Term} {observations : List Term}
    {final : Output}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "log", entry, checkpoint], list observations])) final)
    (terminal : QueryTerminal final) :
    ∃ journal result rest,
      Command.start context.candidate.working (.tuple [a "log", entry, checkpoint]) journal =
        .ok (result, rest) ∧ settled rest = true ∧ final = issue context result := by
  rw [start_captured] at trace
  exact query_trace_call (log_observations_reflect trace) terminal

theorem log_initial_write {context : Context} {entry checkpoint saved : Term}
    {observations batch : List Term}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "log", entry, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list batch])) :
    ∃ journal result rest,
      Command.start context.candidate.working (.tuple [a "log", entry, checkpoint]) journal =
        .ok (result, rest) ∧ InputStart result batch false ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        logWriteContinuation, list batch, nil] := by
  have terminal : QueryTerminal (some saved, .tuple [a "validate_write", list batch]) := by
    simp [QueryTerminal, a]
  obtain ⟨journal, result, rest, call, _, issued⟩ := log_trace_actual trace terminal
  have actual := issued.symm
  rcases log_start call with invalidRole | invalidInput | ⟨original, started, _, _⟩
  · rw [invalidRole] at actual
    simp [Command.finish, issue, a] at actual
  · rw [invalidInput] at actual
    simp [Command.finish, issue, a] at actual
  · have fixed := log_write_unchanged (continuation := logWriteContinuation) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_log_write, fixed] at actual
      simp only [preparedWrite, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
        List.cons.injEq, and_true, true_and, list, Term.list.injEq] at actual
      obtain ⟨savedEq, batchEq⟩ := actual
      subst batch
      exact ⟨journal, result, rest, call, Or.inl direct, savedEq.symm⟩
    · rw [workspaceStart] at actual
      simp [Command.perform, issue, a] at actual

theorem log_initial_workspace {context : Context} {args checkpoint saved request : Term}
    {observations : List Term}
    (trace : ObservationTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "log", args, checkpoint], list observations]))
      (some saved, .tuple [a "effect", request])) :
    ∃ journal result rest batch operation metadata workspace billing,
      Command.start context.candidate.working (.tuple [a "log", args, checkpoint]) journal = .ok (result, rest) ∧
      InputStart result batch false ∧
      request = .tuple [a "workspace", operation, metadata, workspace, billing] ∧
      saved = .tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list batch, Term.bool false], request] := by
  have terminal : QueryTerminal (some saved, .tuple [a "effect", request]) := by
    simp [QueryTerminal, a]
  obtain ⟨journal, result, rest, call, _, issued⟩ := log_trace_actual trace terminal
  have actual := issued.symm
  rcases log_start call with saturated | invalidInput | ⟨batch, started, _, _⟩
  · rw [saturated] at actual
    simp [Command.finish, issue, a] at actual
  · rw [invalidInput] at actual
    simp [Command.finish, issue, a] at actual
  · have fixed := log_write_unchanged (continuation := logWriteContinuation) call started
    rcases started with direct | ⟨operation, metadata, workspace, billing, workspaceStart⟩
    · rw [direct, issue_log_write, fixed] at actual
      simp [preparedWrite, a] at actual
    · rw [workspaceStart] at actual
      change (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list batch, Term.bool false],
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
theorem log_workspace_write {context : Context} {args checkpoint initial saved operation metadata workspace billing : Term}
    {journal rest original batch : List Term} {response : DurableConfirmation.Result}
    (input : Command.start context.candidate.working (.tuple [a "log", args, checkpoint]) journal = .ok (initial, rest))
    (started : InputStart initial original false)
    (trace : ObservationTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list original, Term.bool false],
        .tuple [a "workspace", operation, metadata, workspace, billing]]))
        (a "effect_result") response.wire)
      (some saved, .tuple [a "validate_write", list batch])) :
    response = .ok ∧ batch = original ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        logWriteContinuation, list original, nil] := by
  have fixed := log_write_unchanged (continuation := logWriteContinuation) input started
  cases response with
  | ok =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace
    change ObservationTrace (issue context (Command.writeInput (list original) false)) _ at trace
    rw [issue_log_write, fixed] at trace
    have actual := (trace.fixed (by simp [preparedWrite, a])).symm
    simp only [preparedWrite, Prod.mk.injEq, Option.some.injEq, Term.tuple.injEq,
      List.cons.injEq, and_true, true_and, list, Term.list.injEq] at actual
    exact ⟨rfl, actual.2.symm, actual.1.symm⟩
  | error reason =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace
    change ObservationTrace (issue context (Command.finish (.tuple [a "error", reason]))) _ at trace
    have issued := trace.fixed (by simp [Command.finish, issue, a])
    simp [Command.finish, issue, a] at issued

inductive LogAdmissionTrace (context : Context) (args checkpoint : Term) (observations : List Term) :
    Output → Prop where
  | direct {final : Output}
      (trace : ObservationTrace
        (resident (some context.pack) (a "start")
          (.tuple [.tuple [a "log", args, checkpoint], list observations])) final) :
      LogAdmissionTrace context args checkpoint observations final
  | workspace {saved request : Term} {response : DurableConfirmation.Result} {final : Output}
      (head : ObservationTrace
        (resident (some context.pack) (a "start")
          (.tuple [.tuple [a "log", args, checkpoint], list observations]))
        (some saved, .tuple [a "effect", request]))
      (tail : ObservationTrace (resident (some saved) (a "effect_result") response.wire) final) :
      LogAdmissionTrace context args checkpoint observations final

/-- Both log admission paths retain the initial command batch and continuation. -/
theorem log_admission_write {context : Context} {args checkpoint saved : Term}
    {observations batch : List Term}
    (trace : LogAdmissionTrace context args checkpoint observations
      (some saved, .tuple [a "validate_write", list batch])) :
    ∃ journal result rest,
      Command.start context.candidate.working (.tuple [a "log", args, checkpoint]) journal = .ok (result, rest) ∧
      InputStart result batch false ∧
      saved = .tuple [a "session_command_driver_write", context.pack,
        logWriteContinuation, list batch, nil] := by
  cases trace with
  | direct trace => exact log_initial_write trace
  | workspace head tail =>
    obtain ⟨journal, result, rest, original, operation, metadata, workspace, billing,
      call, started, requestEq, savedEq⟩ := log_initial_workspace head
    rw [savedEq, requestEq] at tail
    obtain ⟨_, batchEq, finalEq⟩ := log_workspace_write call started tail
    subst batch
    exact ⟨journal, result, rest, call, started, finalEq⟩


theorem log_workspace_admission_observations {context : Context}
    {args checkpoint initial operation metadata workspace billing : Term} {journal rest original : List Term}
    {response : DurableConfirmation.Result} {final : Output}
    (input : Command.start context.candidate.working (.tuple [a "log", args, checkpoint]) journal = .ok (initial, rest))
    (started : InputStart initial original false)
    (trace : AdmissionTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list original, Term.bool false],
        .tuple [a "workspace", operation, metadata, workspace, billing]]))
        (a "effect_result") response.wire) final) :
    ObservationTrace
      (resident (some (.tuple [a "session_command_driver_effect", context.pack,
        .tuple [b "input_workspace", list original, Term.bool false],
        .tuple [a "workspace", operation, metadata, workspace, billing]]))
        (a "effect_result") response.wire) final := by
  have fixed := log_write_unchanged (continuation := logWriteContinuation) input started
  cases response with
  | ok =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace ⊢
    change AdmissionTrace (issue context (Command.writeInput (list original) false)) final at trace
    change ObservationTrace (issue context (Command.writeInput (list original) false)) final
    rw [issue_log_write, fixed] at trace ⊢
    rw [trace.fixed (by simp [preparedWrite, a])]
    exact .done _
  | error reason =>
    rw [effect_captured _ _ _ _ (by rfl)] at trace ⊢
    change AdmissionTrace (issue context (Command.finish (.tuple [a "error", reason]))) final at trace
    change ObservationTrace (issue context (Command.finish (.tuple [a "error", reason]))) final
    rw [trace.fixed (by simp [Command.finish, issue, a])]
    exact .done _

/-- The actual initial command admits at most one workspace effect before its write. -/
theorem log_admission_reflect {context : Context} {args checkpoint saved : Term}
    {observations events : List Term}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "log", args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events])) :
    LogAdmissionTrace context args checkpoint observations (some saved, .tuple [a "validate_write", list events]) := by
  rcases trace.first_effect with direct | ⟨effect, request, response, head, tail⟩
  · exact .direct direct
  · obtain ⟨journal, result, rest, original, operation, metadata, workspace, billing,
      call, started, requestEq, savedEq⟩ := log_initial_workspace head
    rw [savedEq, requestEq] at tail
    obtain ⟨response, rfl⟩ := workspace_admission_result tail
    apply LogAdmissionTrace.workspace (response := response) head
    rw [savedEq, requestEq]
    exact log_workspace_admission_observations call started tail


theorem log_raw_admission_applied {context : Context} {entry checkpoint saved after : Term}
    {observations events : List Term} {final : PendingRevision.Cursor}
    (admission : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [a "log", entry, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events]))
    (write : BatchTrace (resident (some saved) (a "write_result") (a "ok")) (writeFenced final after)) :
    after = b "log_written" ∧ ∃ journal result rest,
      Command.start context.candidate.working (.tuple [a "log", entry, checkpoint]) journal =
        .ok (result, rest) ∧ InputStart result events false ∧
      PendingRevision.Execution
        (PendingRevision.resident (some context.candidate.pack) (a "write") (.tuple [list events, nil])) final := by
  obtain ⟨journal, result, rest, call, started, savedEq⟩ :=
    log_admission_write (log_admission_reflect admission)
  rw [savedEq, write_captured] at write
  have valid := fenced_batch_start_valid context (b "log_written") events nil
  have afterEq := fenced_batch_continuation (fenced_batch_output_preserved write valid)
  subst after
  have execution := Revision.execution_pending (fenced_batch_reflect (fenced_batch_trace_reflect valid write))
  rw [Revision.write_captured] at execution
  exact ⟨rfl, journal, result, rest, call, started, execution⟩

end VerifiedKernel.Session.CommandDriver
