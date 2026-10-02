import VerifiedKernel.Session.Activity
import VerifiedKernel.Encoding

namespace VerifiedKernel.Session
open Data

def bumpFailure (state hwm : Term) (terminal : Bool) : KernelM Term := do
  if !hwm.isInteger then return .map [(b "count", i 0), (b "hwm", nil)]
  let previous := state.get (a "llm_failure_streak")
  let count ← if previous.has (b "count") && previous.get (b "hwm") == hwm then
    add (previous.get (b "count")) (i 1) else pure (i 1)
  return .map [(b "count", count), (b "hwm", hwm), (b "terminal", Term.bool terminal)]

/-- Count unsettled rounds within the current activation. -/
def runawayStreak (state fact : Term) : KernelM Term := do
  if fact.get (b "kind") == b "runaway_unsettled_round" then
    return .map [(b "count", ← add (← unsettledCount state) (i 1))]
  else if fact.get (b "kind") == b "runaway_guard_reset" then
    return .map [(b "count", i 0)]
  else field state "runaway_unsettled_streak"

def markRetry (items fact : Term) : KernelM Term := do
  let payload := fact.get (b "event")
  if fact.get (b "kind") == b "provider_activation_retry" && payload.has (b "queue_id") then
    return list (← enumMap items (fun item => do
      let id := i (integerValue (← alias item (b "queue_id") (a "queue_id")))
      if id.numericEq (payload.get (b "queue_id")) then put item (b "activation_retry_consumed") (a "true") else pure item))
  else pure items

def egressKey (group conversation sources : Term) : KernelM Term := do
  let bytes ← deterministic (.tuple [i 1, group, conversation, sources])
  let hash ← digest bytes
  return .binary ("visible-reply-egress:".toUTF8 ++ (ByteDigest.base64Url hash.toList).toByteArray)

def putEgress (state event : Term) : KernelM Term := do
  let payload := event.get (b "event")
  if event.get (b "kind") == b "visible_reply_egress" && event.get (b "source") == b "script_host" &&
      event.get (b "method") == b "im_api.internal.send_message" && payload.isMap then
    let key ← Data.event payload "ownership_key"
    let group ← Data.event payload "agent_group_id"
    let conversation ← Data.event payload "conversation_id"
    let sources ← Data.event payload "source_message_ids"
    let valid ← if group.isBinary && conversation.isBinary && sources.isList then egressKey group conversation sources else pure (a "false")
    if key.isBinary && key == valid then put ((← field state "visible_reply_egress_facts").default empty) key payload
    else pure ((← field state "visible_reply_egress_facts").default empty)
  else pure ((← field state "visible_reply_egress_facts").default empty)

def sessionEvent (state event : Term) : KernelM Term := do
  let selected := select event ["event_id", "kind", "source", "method", "event", "stale", "created_at"] true
  let seq ← add ((← field state "last_seq").default (i 0)) (i 1)
  let fact := selected.put (b "seq") seq
  let streak ← if (← Data.event fact "kind") == b "llm_call_failed" then do
    let hwm ← failureHwm fact
    let streak ← bumpFailure state hwm (failureTerminal fact)
    let payload := fact.get (b "event")
    let streak := if payload.get (b "error_class") == b "billing_unavailable" then
        streak.put (b "billing_reason") (payload.get (b "reason")) else streak
    let retry := payload.get (b "retry_at_ms")
    pure (if retry.isInteger then streak.put (b "retry_at_ms") retry else streak)
    else pure nil
  let runaway ← runawayStreak state fact
  let history ← append ((← field state "events").default (list [])) (list [fact])
  let queue ← markRetry (← field state "input_queue") fact
  let egress ← putEgress state event
  let kind ← Data.event fact "kind"
  let state ← if kind == b "context_overflow_recovery_requested" then
    write state [("context_overflow_recovery", fact.get (b "event"))]
    else pure state
  -- A settlement that ends the turn marks its ACK, so the transcript tail does
  -- not continue by itself. Only new input or a new result starts the loop again.
  let terminalAck ← if kind == b "terminal_reply_delivered" || kind == b "channel_onboarding_settled" ||
      kind == b "runtime_failure_reply_settled" || kind == b "runtime_failure_disposed" ||
      kind == b "runtime_runaway_retired" then
    Data.event (← Data.event fact "event") "settled_ack_hwm" else field state "terminal_reply_ack_hwm"
  let previousAttempt ← field state "runtime_failure_reply"
  let failedHwm ← failureHwm fact
  let attempt ← if kind == b "runtime_failure_reply_attempted" || kind == b "runtime_failure_reply_settled" then
      Data.event fact "event"
    else if previousAttempt.get (b "failure_reason") == b "model" &&
        (previousAttempt.get (b "notification_outcome")).isBinary then
      pure (if kind == b "provider_activation_retry" then previousAttempt.put (b "resume_requested") (a "true")
        else if kind == b "llm_call_failed" then previousAttempt.put (b "notification_hwm") failedHwm
          |>.put (b "resume_requested") (a "false")
        else previousAttempt)
    else pure previousAttempt
  let timestamp ← Data.event event "created_at"
  let activity ← if timestamp.truthy then pure timestamp else field state "last_activity_at"
  write state [("events", history), ("last_seq", seq), ("llm_failure_streak", streak), ("input_queue", queue),
    ("runaway_unsettled_streak", runaway), ("visible_reply_egress_facts", egress),
    ("terminal_reply_ack_hwm", terminalAck), ("runtime_failure_reply", attempt), ("last_activity_at", activity)]

end VerifiedKernel.Session
