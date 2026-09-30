import VerifiedKernelProofs.Session.WorkRestartResume

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

structure RestartObservation where
  request : Term
  result : Term

/-- The host resumes the exact continuation emitted by the preceding native
call. Callback results are not classified by this execution relation. -/
inductive RestartTrace (state : Term) : Term → Term → List RestartObservation → Prop where
  | done (output : Term) : RestartTrace state output output []
  | next {request context observation middle final : Term} {journal rest : List Term}
      {observations : List RestartObservation}
      (resumed : Restart.resume state (.tuple [context, observation]) journal = .ok (middle, rest))
      (tail : RestartTrace state middle final observations) :
      RestartTrace state (.tuple [a "perform", request, context]) final
        (⟨request, observation⟩ :: observations)

/-- This is an explicit producer obligation to be discharged by the host-source
certificates. It is not part of the trusted storage or FFI boundary. -/
def RestartObservationsOrdinary (observations : List RestartObservation) : Prop :=
  ∀ step ∈ observations, ∀ name args, step.request = .tuple [b name, args] →
    RestartCallbackEvents name step.result

theorem restart_perform_context {request context : Term}
    (safe : RestartOutputOrdinary (.tuple [a "perform", request, context])) :
    ∃ name args, request = .tuple [b name, args] ∧ RestartContextReady context ∧
      RestartPhaseFor name (context.get (b "phase")) := by
  generalize packed : Term.tuple [a "perform", request, context] = output at safe
  cases safe with
  | perform ready phase =>
    simp only [Term.tuple.injEq, List.cons.injEq, and_true, true_and] at packed
    obtain ⟨rfl, rfl⟩ := packed
    exact ⟨_, _, rfl, ready, phase⟩
  | finished batch => simp [a] at packed
  | failed reason => simp [a] at packed

theorem RestartTrace.ordinary {state initial final : Term} {observations : List RestartObservation}
    (trace : RestartTrace state initial final observations)
    (initialSafe : RestartOutputOrdinary initial)
    (producers : RestartObservationsOrdinary observations) : RestartOutputOrdinary final := by
  induction trace with
  | done => exact initialSafe
  | @next request context observation middle final journal rest observations resumed tail ih =>
    obtain ⟨name, args, requestShape, safe, phase⟩ := restart_perform_context initialSafe
    apply ih (restart_resume_ordinary safe phase
      (producers _ List.mem_cons_self name args requestShape) resumed)
    intro step member name args request
    exact producers step (List.mem_cons_of_mem _ member) name args request

theorem restart_complete_events_ordinary {state live recovery initial nextId : Term}
    {events journal rest : List Term} {observations : List RestartObservation}
    (started : Restart.start state (.tuple [live, recovery]) journal = .ok (initial, rest))
    (trace : RestartTrace state initial (.tuple [a "return", .tuple [list events, nextId]]) observations)
    (producers : RestartObservationsOrdinary observations) : RawOrdinaryBatch events := by
  have final := trace.ordinary (restart_start_ordinary started) producers
  generalize packed : Term.tuple [a "return", .tuple [list events, nextId]] = output at final
  cases final with
  | perform safe phase => simp [a] at packed
  | failed reason => simp [a, list] at packed
  | finished safe =>
    simp only [Term.tuple.injEq, List.cons.injEq, list, Term.list.injEq,
      and_true, true_and] at packed
    obtain ⟨rfl, rfl⟩ := packed
    exact safe

end VerifiedKernel.Session.WorkConservation
