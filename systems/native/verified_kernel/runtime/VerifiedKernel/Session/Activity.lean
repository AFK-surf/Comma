import VerifiedKernel.Order

namespace VerifiedKernel.Session
open Data

def failureHwm (fact : Term) : KernelM Term := do
  let payload := fact.get (b "event")
  if !payload.isMap then return nil
  let value ← alias payload (b "transcript_hwm") (a "transcript_hwm")
  return if value == nil then nil else i (integerValue value)

def failureTerminal (fact : Term) : Bool :=
  let payload := fact.get (b "event")
  if !payload.isMap then false
  else if payload.has (b "retryable") then payload.get (b "retryable") == a "false"
  else payload.get (a "retryable") == a "false"

def highWatermark (state : Term) : KernelM Term := do
  sub ((← field state "next_message_id").default (i 1)) (i 1)

def failureCount (state : Term) : KernelM Term := do
  let hwm ← highWatermark state
  let format := state.get (a "storage_format")
  if format.isInteger && integerValue format ≥ 2 then
    let streak ← field state "llm_failure_streak"
    let count := streak.get (b "count")
    return if count.isInteger && streak.get (b "hwm") == hwm then count else i 0
  else
    let facts := (wrap (← field state "events")).reverse
    enumUntil (list facts) (i 0) (fun count fact => do
      if fact.get (b "kind") == b "llm_call_failed" && (← failureHwm fact).numericEq hwm then
        return (true, ← add count (i 1))
      return (false, count))

def terminalFailure (state : Term) : KernelM Bool := do
  let format := state.get (a "storage_format")
  if format.isInteger && integerValue format ≥ 2 then
    let streak ← field state "llm_failure_streak"
    if streak.get (b "terminal") == a "true" && streak.has (b "hwm") then
      return (streak.get (b "hwm")).numericEq (← highWatermark state)
    return false
  else
    let hwm ← highWatermark state
    let fact := (wrap (← field state "events")).getLast?.getD nil
    if fact.get (b "kind") == b "llm_call_failed" && (← failureHwm fact).numericEq hwm then
      return failureTerminal fact
    return false

/-- A settled model-stop notice parks only the notified input. A wakeable
continuation or the existing per-input retry budget may resume its work. -/
def modelNotificationParked (state : Term) : KernelM Bool := do
  let attempt ← field state "runtime_failure_reply"
  if attempt.get (b "failure_reason") != b "model" ||
      !(attempt.get (b "notification_outcome")).isBinary ||
      attempt.get (b "resume_requested") == a "true" then return false
  let hwm := attempt.get (b "notification_hwm")
  if !hwm.isInteger then return false
  let messages := wrap ((← field state "messages").default (list []))
  return !(messages.any (fun message =>
    let get := fun key => (message.get (a key)).default (message.get (b key))
    integerValue (get "id") > integerValue hwm && get "no_wake" != a "true" &&
      [b "user", b "runtime", b "assistant"].contains (get "role")))

def repairExhausted (state : Term) : KernelM Bool := do
  let repair := state.get (a "visible_reply_repair")
  if repair.isMap then return (← alias repair (b "status") (a "status")) == b "exhausted"
  return false

def streakCount (value : Term) : Term :=
  let count := value.get (b "count")
  if count.isInteger && integerValue count > 0 then count else i 0

def unsettledCount (state : Term) (fieldName : String := "runaway_unsettled_streak") : KernelM Term := do
  let ack := (← field state "last_ack_message_id").default (i 0)
  let hwm ← highWatermark state
  if ← less ack hwm then return streakCount (← field state fieldName)
  return i 0

def retryScheduled (state : Term) : KernelM Bool := do
  let hwm ← highWatermark state
  let modern ← atMost (i 2) (← field state "storage_format")
  let retry : Term ← if modern then field state "llm_failure_streak"
    else do
      let facts ← asList ((← field state "events").default (list []))
      let fact := facts.getLast?.getD nil
      let payload := fact.get (b "event")
      if fact.get (b "kind") == b "llm_call_failed" && payload.isMap then
        pure (Term.map [(b "hwm", payload.get (b "transcript_hwm")), (b "retry_at_ms", payload.get (b "retry_at_ms"))])
      else pure nil
  return retry.get (b "hwm") == hwm && (retry.get (b "retry_at_ms")).isInteger

def configuration (name : String) (fallback : Int) : KernelM Term :=
  observe (.tuple [a "config", a "salix_agent", a name, i fallback])

def activity (state : Term) : KernelM Term := do
  if state.get (a "status") == a "active" then
    let current := state.get (a "activity_status")
    return if ["thinking", "execution", "messaging"].any (fun name => current == a name) then current else a "thinking"
  if state.get (a "status") == a "idle" && (state.get (a "wait")).isMap then return a "waiting"
  let cap ← configuration "llm_failure_activation_cap" 3
  if cap.isInteger && integerValue cap > 0 then
    if ← atMost cap (← failureCount state) then return a "failed"
  if (← terminalFailure state) || (← modelNotificationParked state) then return a "failed"
  if ← repairExhausted state then return a "failed"
  let cap ← configuration "runaway_unsettled_round_cap" 2
  if cap.isInteger && integerValue cap > 0 then
    if ← atMost cap (← unsettledCount state) then return a "failed"
  let cap ← configuration "repeated_tool_result_cap" 5
  let exhausted ← if cap.isInteger && integerValue cap > 0 then
    atMost cap (← unsettledCount state "repeated_tool_result_streak") else pure false
  if exhausted then return a "failed"
  -- Read lazily, like the caps above: an earlier guard settles the answer.
  let cap ← configuration "input_round_cap" 120
  let exhausted ← if cap.isInteger && integerValue cap > 0 then
    atMost cap (← unsettledCount state "input_round_streak") else pure false
  let retry ← retryScheduled state
  return if exhausted then a "failed" else if retry then a "waiting" else a "paused"

def afterEvent (previous next event : Term) : KernelM Term := do
  let derived ← write next [("activity_status", ← activity next)]
  let before ← activity previous
  let after ← activity derived
  if before == after then return derived
  let timestamp ← aliases event [b "created_at", b "updated_at", b "activity_status_updated_at", b "status_updated_at"]
  if timestamp.isInteger then write derived [("activity_status_updated_at", timestamp)] else pure derived

end VerifiedKernel.Session
