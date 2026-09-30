import VerifiedKernelProofs.Session.WorkActivationAdmission

namespace VerifiedKernel.Session.CommandDriver
open Data WorkConservation
set_option Elab.async false

/-- Admission and its callbacks retain the original revision until the validated batch boundary. -/
inductive AdmissionFrontier (context : Context) : Output → Prop where
  | querying (operation args request : Term) (observations : List Term) :
      AdmissionFrontier context
        (some (queryCursor context operation args observations), .tuple [a "observe", request])
  | timestamp (continuation : Term) (events : List Term) (hwm : Term) :
      AdmissionFrontier context
        (some (.tuple [a "session_command_driver_write_time", context.pack, continuation, list events, hwm]),
          .tuple [a "observe", a "time"])
  | write (continuation : Term) (events : List Term) (hwm : Term) :
      AdmissionFrontier context (preparedWrite context continuation events hwm)
  | effect (request continuation : Term) :
      AdmissionFrontier context
        (some (.tuple [a "session_command_driver_effect", context.pack, continuation, request]),
          .tuple [a "effect", request])
  | returned (result checkpoint : Term) :
      AdmissionFrontier context (some context.pack, .tuple [a "return", result, checkpoint])
  | fence (continuation : Term) :
      AdmissionFrontier context
        (some (.tuple [a "session_command_driver_fence", context.pack, continuation]), .tuple [a "fence"])
  | failed (response : Term) : AdmissionFrontier context (none, response)

theorem frontier_issue_write (context : Context) (continuation : Term) (events : List Term) (hwm : Term) :
    AdmissionFrontier context (issueWrite context continuation events hwm) := by
  unfold issueWrite
  split
  · exact .timestamp _ _ _
  · exact .write _ _ _

theorem frontier_issue (context : Context) (result : Term) :
    AdmissionFrontier context (issue context result) := by
  unfold issue
  split
  · exact .returned _ _
  · exact frontier_issue_write _ _ _ _
  · exact frontier_issue_write _ _ _ _
  · exact frontier_issue_write _ _ _ _
  · exact .fence _
  · exact .effect _ _
  · exact .effect _ _
  · exact .effect _ _
  · exact .effect _ _
  · exact .effect _ _
  · exact .failed _

theorem frontier_query (context : Context) (operation args : Term) (observations : List Term) : AdmissionFrontier context (query context operation args observations) := by
  rw [query_eq]
  split
  · rename_i result rest call
    split
    · exact frontier_issue _ _
    · exact .failed _
  · exact .querying _ _ _ _
  · exact .failed _

theorem frontier_observe {context : Context} {saved request observation : Term}
    (valid : AdmissionFrontier context (some saved, .tuple [a "observe", request])) :
    AdmissionFrontier context (resident (some saved) (a "resume") observation) := by
  generalize same : (some saved, Term.tuple [a "observe", request]) = output at valid
  cases valid with
  | querying operation args _ observations =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured, query_resume_captured]
    exact frontier_query _ _ _ _
  | timestamp continuation events hwm =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured, activation_timestamp_response]
    split
    · exact .write _ _ _
    · exact .failed _
  | write => simp [preparedWrite, a] at same
  | effect => simp [a] at same
  | returned => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem frontier_effect {context : Context} {saved request response : Term}
    (valid : AdmissionFrontier context (some saved, .tuple [a "effect", request])) :
    AdmissionFrontier context (resident (some saved) (a "effect_result") response) := by
  generalize same : (some saved, Term.tuple [a "effect", request]) = output at valid
  cases valid with
  | effect issued continuation =>
    have captured := Option.some.inj (congrArg Prod.fst same)
    rw [captured]
    cases allowed : effectResultValid issued response with
    | true =>
      rw [effect_captured _ _ _ _ allowed]
      exact frontier_query _ _ _ _
    | false =>
      rw [effect_rejected _ _ _ _ allowed]
      exact .failed _
  | querying => simp [a] at same
  | timestamp => simp [a] at same
  | write => simp [preparedWrite, a] at same
  | returned => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem admission_frontier_preserved {context : Context} {initial final : Output}
    (trace : AdmissionTrace initial final) (valid : AdmissionFrontier context initial) :
    AdmissionFrontier context final := by
  induction trace with
  | done => exact valid
  | observe tail ih => exact ih (frontier_observe valid)
  | effect tail ih => exact ih (frontier_effect valid)

theorem public_admission_frontier {context : Context} {command args checkpoint : Term}
    {observations : List Term} {final : Output}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [command, args, checkpoint], list observations])) final) :
    AdmissionFrontier context final := by
  apply admission_frontier_preserved trace
  rw [start_captured]
  exact frontier_query _ _ _ _

/-- Returning before a write, including activation's no-write path, cannot replace the revision. -/
theorem public_admission_return_cursor {context : Context} {command args checkpoint saved result finalCheckpoint : Term}
    {observations : List Term}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [command, args, checkpoint], list observations]))
      (some saved, .tuple [a "return", result, finalCheckpoint])) : saved = context.pack := by
  have valid := public_admission_frontier trace
  generalize same : (some saved, Term.tuple [a "return", result, finalCheckpoint]) = output at valid
  cases valid with
  | returned => exact Option.some.inj (congrArg Prod.fst same)
  | querying => simp [a] at same
  | timestamp => simp [a] at same
  | write => simp [preparedWrite, a] at same
  | effect => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

theorem public_admission_write_cursor {context : Context} {command args checkpoint saved : Term}
    {observations events : List Term}
    (trace : AdmissionTrace
      (resident (some context.pack) (a "start")
        (.tuple [.tuple [command, args, checkpoint], list observations]))
      (some saved, .tuple [a "validate_write", list events])) :
    ∃ continuation hwm,
      saved = .tuple [a "session_command_driver_write", context.pack, continuation, list events, hwm] := by
  have valid := public_admission_frontier trace
  generalize same : (some saved, Term.tuple [a "validate_write", list events]) = output at valid
  cases valid with
  | write continuation written hwm =>
    have eventEq : events = written := by
      simpa only [preparedWrite, Term.tuple.injEq, List.cons.injEq, and_true, true_and, list, Term.list.injEq]
        using congrArg Prod.snd same
    subst written
    exact ⟨continuation, hwm, Option.some.inj (congrArg Prod.fst same)⟩
  | querying => simp [a] at same
  | timestamp => simp [a] at same
  | effect => simp [a] at same
  | returned => simp [a] at same
  | fence => simp [a] at same
  | failed => cases congrArg Prod.fst same

end VerifiedKernel.Session.CommandDriver
