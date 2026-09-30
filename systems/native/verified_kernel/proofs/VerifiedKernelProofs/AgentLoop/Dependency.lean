import VerifiedKernel.AgentLoop.Dependency
import VerifiedKernelProofs.AgentLoop.Trace

namespace VerifiedKernel.AgentLoop.Dependency

def transition (state : State) (event : Event) : State × List Command :=
  let result := step state event
  (result.1, [result.2])

def trace (state : State) (events : List Event) : State × List Command :=
  runTrace transition state events

def admitted (command : Command) : Nat := if command = .ignore then 0 else 1

def admissions : List Command → Nat
  | [] => 0
  | command :: rest => admitted command + admissions rest

def budget : State → Nat
  | .running _ => 1
  | _ => 0

theorem stale_ignored (token : List UInt8) (event : Event) (stale : token ≠ event.token) :
    step (.running token) event = (.running token, .ignore) := by
  simp [step, stale]

theorem acceptance_requires_current (state : State) (event : Event)
    (accepted : (step state event).2 ≠ .ignore) :
    state = .running event.token ∧
      (event.kind = "result" ∨ event.kind = "timeout" ∨ event.kind = "down") := by
  cases state with
  | running token =>
    by_cases same : token = event.token <;>
      by_cases result : event.kind = "result" <;>
      by_cases timeout : event.kind = "timeout" <;>
      by_cases down : event.kind = "down" <;> simp_all [step]
  | retained token | retired => simp [step] at accepted

theorem step_budget (state : State) (event : Event) :
    admitted (step state event).2 + budget (step state event).1 ≤ budget state := by
  cases state with
  | running token =>
    by_cases same : token = event.token <;>
      by_cases result : event.kind = "result" <;>
      by_cases timeout : event.kind = "timeout" <;>
      by_cases down : event.kind = "down" <;> simp_all [step, admitted, budget]
  | retained token | retired => simp [step, admitted, budget]

theorem trace_budget (state : State) (events : List Event) :
    admissions (trace state events).2 + budget (trace state events).1 ≤ budget state := by
  induction events generalizing state with
  | nil => simp [trace, runTrace, admissions]
  | cons event rest ih =>
    have current := step_budget state event
    have later := ih (step state event).1
    simp only [trace, runTrace, transition, List.singleton_append,
      admissions] at *
    omega

/-- Arbitrary finite events include duplicate results and all result/timeout/
    down permutations. No fairness or external-effect idempotency is assumed. -/
theorem at_most_once (token : List UInt8) (events : List Event) :
    admissions (trace (.running token) events).2 ≤ 1 := by
  have bounded := trace_budget (.running token) events
  simp only [budget] at bounded
  omega

end VerifiedKernel.AgentLoop.Dependency
