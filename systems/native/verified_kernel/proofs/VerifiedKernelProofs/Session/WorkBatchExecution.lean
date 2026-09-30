import VerifiedKernelProofs.Session.WorkResident
import VerifiedKernel.Session.BatchExecution

namespace VerifiedKernel.Session.BatchExecution
open Data WorkConservation
set_option Elab.async false

/-- A finite execution of the native batch requests. No constructor assumes batch application or work preservation. -/
inductive Execution : Output → Term → Prop where
  | done (state : Term) : Execution (some state, .tuple [a "done"]) state
  | run {state event final : Term} {events observations : List Term}
      (tail : Execution (resident (some (pending state (event :: events))) (a "run") (list observations)) final) :
      Execution (some (pending state (event :: events)), .tuple [a "next"]) final
  | resume {token request observation final : Term} {events : List Term}
      (tail : Execution (resident (some (observing token events)) (a "resume") observation) final) :
      Execution (some (observing token events), .tuple [a "observe", request]) final

def Meaning : Output → Term → Prop
  | (some state, .tuple [.atom "done"]), final => state = final
  | (some (.tuple [.atom "session_batch_next", state, .list events]), .tuple [.atom "next"]), final =>
    ResidentBatch state events final
  | (some (.tuple [.atom "session_batch_observe", token, .list events]), .tuple [.atom "observe", request]), final =>
    ∃ state, ResidentTrace (.tuple [a "observe", request, token]) (.tuple [a "done", state]) ∧
      ResidentBatch state events final
  | _, _ => False

theorem next_meaning {state final : Term} {events : List Term}
    (h : Meaning (next state events) final) : ResidentBatch state events final := by
  cases events with
  | nil =>
    change state = final at h
    subst final
    exact .nil state
  | cons => exact h

theorem accept_meaning {result final : Term} {events : List Term}
    (h : Meaning (accept events result) final) :
    ∃ state, ResidentTrace result (.tuple [a "done", state]) ∧ ResidentBatch state events final := by
  unfold accept at h
  split at h
  · rename_i state
    exact ⟨state, .done _, next_meaning h⟩
  · exact h
  · change False at h
    exact h.elim

theorem execution_meaning {output : Output} {final : Term} (execution : Execution output final) :
    Meaning output final := by
  induction execution with
  | done => rfl
  | run tail ih =>
    simp only [resident, pending, a, list] at ih
    obtain ⟨state, head, rest⟩ := accept_meaning ih
    exact ResidentBatch.cons head rest
  | resume tail ih =>
    simp only [resident, observing, a, list] at ih
    obtain ⟨state, head, rest⟩ := accept_meaning ih
    exact ⟨state, ResidentTrace.resume head, rest⟩

/-- Successful native batch execution derives the exact resident batch relation used by work-preservation proofs. -/
theorem start_executes_batch {state final : Term} {events : List Term}
    (execution : Execution (resident (some state) (a "start") (list events)) final) :
    ResidentBatch state events final := by
  exact next_meaning (execution_meaning execution)

end VerifiedKernel.Session.BatchExecution
