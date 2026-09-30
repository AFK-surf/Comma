import VerifiedKernel.Session.Query.State

namespace VerifiedKernel.Session.Recovery
open Data

def outcome (action : String) (checkpoint : Term := nil) (stage : Term := nil)
    (reason : Term := nil) : Term :=
  .map [(a "action", a action), (a "checkpoint", checkpoint),
    (a "stage", stage), (a "reason", reason)]

def observeSession (state checkpoint : Term) : KernelM Term := do
  if ← StateQuery.pendingVisibleReply state then return outcome "continue" (b "append")
  if checkpoint == b "append" then
    if (← field state "status") == a "idle" && (← StateQuery.workReasons state) == list [] then
      return outcome "settled"
    if (← field state "status") == a "active" then return outcome "continue" checkpoint
  if [b "append", b "authorization"].contains checkpoint && (← StateQuery.hasPendingStableInput state) then
    return outcome "continue" (b "authorization")
  return outcome "continue"

def failure (checkpoint stage reason : Term) : Term :=
  match reason with
  | .tuple [.atom "visible_reply_authorization_retry", reason] =>
    outcome "retry" (b "authorization") (a "authorization") reason
  | .tuple [.atom "visible_reply_pre_llm_error", innerStage, innerReason] =>
    failure checkpoint innerStage innerReason
  | _ => if checkpoint == nil then outcome "error" nil stage reason
    else outcome "retry" checkpoint stage reason
termination_by sizeOf reason

def roundFailure (checkpoint reason : Term) : Term :=
  match reason with
  | .tuple [.atom "visible_reply_authorization_retry", reason] =>
    outcome "retry" (b "authorization") (a "authorization") reason
  | .tuple [.atom "visible_reply_append_retry", reason] =>
    outcome "retry" (b "append") (a "append") reason
  | _ => failure checkpoint (a "round_pre_llm") reason

def policy (args : Term) : KernelM Term := do
  match args with
  | .tuple [.atom "failure", checkpoint, stage, reason] => return failure checkpoint stage reason
  | .tuple [.atom "round_failure", checkpoint, reason] => return roundFailure checkpoint reason
  | .tuple [.atom "handoff", pending, reason] =>
    match reason with
    | .tuple [.atom "visible_reply_authorization_retry", reason] =>
      return outcome "retry" (b "authorization") (a "llm_handoff") reason
    | .tuple [.atom "visible_reply_append_retry", reason] =>
      return outcome "retry" (b "append") (a "llm_handoff") reason
    | _ =>
      return if (pending.get (a "visible_reply_scope")).isMap then
        outcome "retry" (b "append") (a "llm_handoff") (.tuple [a "completion_readback", reason])
      else outcome "continue"
  | .tuple [.atom "disposition", checkpoint] =>
    return if checkpoint == nil then a "interrupted" else a "resume_stable_input"
  | _ => fail "function_clause"

def table : OpTable :=
  [("reconcile", observeSession), ("recovery_policy", fun _ args => policy args)]

end VerifiedKernel.Session.Recovery
