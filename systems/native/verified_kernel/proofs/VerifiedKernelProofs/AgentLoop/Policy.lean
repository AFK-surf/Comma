import VerifiedKernel.AgentLoop.Policy
import Std

namespace VerifiedKernel.AgentLoop.Policy

theorem continuation_park (terminal contained exhausted async wait : Bool) :
    continuation true terminal contained exhausted async wait = "park" := rfl

theorem continuation_terminal (contained exhausted async wait : Bool) :
    continuation false true contained exhausted async wait = "terminal_reply" := rfl

theorem continuation_boundary_iff (park terminal contained exhausted async wait : Bool) :
    continuation park terminal contained exhausted async wait = "round_boundary" ↔
      park = false ∧ terminal = false ∧ contained = false ∧ exhausted = false ∧
      async = false ∧ wait = false := by
  cases park <;> cases terminal <;> cases contained <;> cases exhausted <;>
    cases async <;> cases wait <;> simp [continuation]

theorem activation_process_iff (llmPending compactionPending replyBackoff : Bool) :
    activation llmPending compactionPending replyBackoff = "process" ↔
      llmPending = false ∧ compactionPending = false ∧ replyBackoff = false := by
  cases llmPending <;> cases compactionPending <;> cases replyBackoff <;> simp [activation]

theorem activation_inhibited (llmPending compactionPending replyBackoff : Bool)
    (pending : llmPending = true ∨ compactionPending = true ∨ replyBackoff = true) :
    activation llmPending compactionPending replyBackoff = "pause" := by
  rcases pending with pending | pending | pending <;> simp [activation, pending]

theorem retry_retained_priority (attempts : Nat) : retryAdmission true attempts = "retained" := rfl

theorem retry_initial_iff (retained : Bool) (attempts : Nat) :
    retryAdmission retained attempts = "initial" ↔ retained = false ∧ attempts = 0 := by
  cases retained <;> by_cases zero : attempts = 0 <;> simp [retryAdmission, zero]

theorem retry_late_ignored (attempts : Nat) (late : attempts ≠ 0) :
    retryAdmission false attempts = "ignore" := by simp [retryAdmission, late]

theorem retry_within_budget (attempts budget : Int) :
    retryFailure attempts budget = "retry" ↔ attempts + 1 ≤ budget := by
  by_cases within : attempts + 1 ≤ budget <;> simp [retryFailure, within]

theorem retry_exhausted (attempts budget : Int) (exhausted : ¬ attempts + 1 ≤ budget) :
    retryFailure attempts budget = "exhausted" := by simp [retryFailure, exhausted]

end VerifiedKernel.AgentLoop.Policy
