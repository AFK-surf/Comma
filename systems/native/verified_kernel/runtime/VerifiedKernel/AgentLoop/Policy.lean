import Std

namespace VerifiedKernel.AgentLoop.Policy

/-- Highest-priority enabled reason wins. Inputs are policy observations, not
    proofs that the external predicates supplying them are correct. -/
def continuation (park terminal contained exhausted async wait : Bool) : String :=
  if park then "park" else if terminal then "terminal_reply" else
  if contained then "contained_failure" else if exhausted then "repair_exhausted" else
  if async then "async_pause" else if wait then "wait" else "round_boundary"

def activation (llmPending compactionPending replyBackoff : Bool) : String :=
  if llmPending || compactionPending || replyBackoff then "pause" else "process"

def retryAdmission (retained : Bool) (attempts : Nat) : String :=
  if retained then "retained" else if attempts = 0 then "initial" else "ignore"

def retryFailure (attempts budget : Int) : String :=
  if attempts + 1 ≤ budget then "retry" else "exhausted"

end VerifiedKernel.AgentLoop.Policy
