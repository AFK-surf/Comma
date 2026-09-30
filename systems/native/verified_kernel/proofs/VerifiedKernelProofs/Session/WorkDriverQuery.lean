import VerifiedKernelProofs.Session.WorkCommandDriver

namespace VerifiedKernel.Session.CommandDriver
open Data
set_option Elab.async false

def queryCall (context : Context) (operation args : Term) (observations : List Term) :
    Except Signal (Term × List Term) :=
  match operation with
  | .atom "start" => Command.start context.candidate.working args observations
  | .atom "resume" => Command.resume context.candidate.working args observations
  | _ => .error (.raised (.tuple [a "invalid_observation", list []]))

def queryCursor (context : Context) (operation args : Term) (observations : List Term) : Term :=
  .tuple [a "session_command_driver_query", context.pack, operation, args, list observations]

theorem query_eq (context : Context) (operation args : Term) (observations : List Term) :
    query context operation args observations =
      match queryCall context operation args observations with
      | .ok (result, rest) => if settled rest then issue context result else invalid
      | .error (.observe request) =>
        (some (queryCursor context operation args observations), .tuple [a "observe", request])
      | .error (.raised reason) => (none, .tuple [a "raised", reason]) := rfl

theorem query_resume_captured (context : Context) (operation args observation : Term)
    (observations : List Term) :
    resident (some (queryCursor context operation args observations)) (a "resume") observation =
      query context operation args (observations ++ [observation]) := by
  cases context <;> rfl

/-- Only a query observation can extend this trace. Issued writes and effects end this phase. -/
inductive QueryTrace : Output → Output → Prop where
  | done (output : Output) : QueryTrace output output
  | resume {context : Context} {operation args request observation : Term}
      {observations : List Term} {final : Output}
      (tail : QueryTrace
        (resident (some (queryCursor context operation args observations)) (a "resume") observation) final) :
      QueryTrace (some (queryCursor context operation args observations), .tuple [a "observe", request]) final

def QueryTerminal (output : Output) : Prop :=
  output.1 ≠ none ∧ ∀ request, output.2 ≠ .tuple [a "observe", request]

/-- The host observation loop resumes the returned resource without inspecting its internal phase. -/
inductive ObservationTrace : Output → Output → Prop where
  | done (output : Output) : ObservationTrace output output
  | resume {saved request observation : Term} {final : Output}
      (tail : ObservationTrace (resident (some saved) (a "resume") observation) final) :
      ObservationTrace (some saved, .tuple [a "observe", request]) final

theorem ObservationTrace.fixed {initial final : Output} (trace : ObservationTrace initial final)
    (terminal : ∀ request, initial.2 ≠ .tuple [a "observe", request]) : final = initial := by
  cases trace with
  | done => rfl
  | resume => exact (terminal _ rfl).elim

theorem issue_not_query (context : Context) (result saved operation args request : Term)
    (observations : List Term) :
    issue context result ≠
      (some (.tuple [a "session_command_driver_query", saved, operation, args, list observations]),
        .tuple [a "observe", request]) := by
  intro h
  unfold issue at h
  split at h
  all_goals simp_all [issueWrite, preparedWrite, invalid, RevisionFence.invalid, a]
  all_goals split at h <;> simp_all

theorem query_observation_captured {context other : Context} {operation args mode payload request : Term}
    {observations captured : List Term}
    (h : query context operation args observations =
      (some (queryCursor other mode payload captured), .tuple [a "observe", request])) :
    context = other ∧ operation = mode ∧ args = payload ∧ observations = captured := by
  rw [query_eq] at h
  split at h
  · split at h
    · exact (issue_not_query _ _ _ _ _ _ _ h).elim
    · simp [invalid, RevisionFence.invalid] at h
  · have same := Option.some.inj (congrArg Prod.fst h)
    simp only [queryCursor, Term.tuple.injEq, List.cons.injEq, and_true, true_and, list,
      Term.list.injEq] at same
    obtain ⟨packed, modeEq, argsEq, observationsEq⟩ := same
    have contextEq : context = other := by
      have opened := congrArg Revision.unpack packed
      simpa only [Revision.unpack_pack, Option.some.injEq] using opened
    exact ⟨contextEq, modeEq, argsEq, observationsEq⟩
  · have impossible := congrArg Prod.fst h
    cases impossible

theorem query_terminal_call {context : Context} {operation args : Term} {observations : List Term}
    (terminal : QueryTerminal (query context operation args observations)) :
    ∃ result rest, queryCall context operation args observations = .ok (result, rest) ∧
      settled rest = true ∧ query context operation args observations = issue context result := by
  rw [query_eq] at terminal ⊢
  split at terminal
  · rename_i result rest call
    split at terminal
    · rename_i complete
      exact ⟨result, rest, call, complete, by simp only [complete, ↓reduceIte]⟩
    · exact (terminal.1 rfl).elim
  · exact (terminal.2 _ rfl).elim
  · exact (terminal.1 rfl).elim

/-- Finite native observation steps derive the actual command call and retain its original arguments. -/
theorem query_trace_call {context : Context} {operation args : Term} {observations : List Term}
    {final : Output}
    (trace : QueryTrace (query context operation args observations) final)
    (terminal : QueryTerminal final) :
    ∃ journal result rest, queryCall context operation args journal = .ok (result, rest) ∧
      settled rest = true ∧ final = issue context result := by
  generalize origin : query context operation args observations = output at trace
  induction trace generalizing context operation args observations with
  | done output =>
    subst output
    obtain ⟨result, rest, call, complete, issued⟩ := query_terminal_call terminal
    exact ⟨observations, result, rest, call, complete, issued⟩
  | @resume other mode payload request observation captured final tail ih =>
    obtain ⟨rfl, rfl, rfl, rfl⟩ := query_observation_captured origin
    exact ih terminal (query_resume_captured _ _ _ _ _).symm

end VerifiedKernel.Session.CommandDriver
