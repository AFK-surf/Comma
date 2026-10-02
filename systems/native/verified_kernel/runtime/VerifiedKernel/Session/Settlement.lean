import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.Command
import VerifiedKernel.Session.Query.Round
import VerifiedKernel.Session.Query.Materialize

namespace VerifiedKernel.Session.Settlement
open Data
open RoundQuery (valueOf)
open Command (project)

def ready (state : Term) : KernelM Bool := do
  return integerValue (← ReplyQuery.blockingObligationCount state) == 0 &&
    !(← StateQuery.pendingVisibleReply state) &&
    (← StateQuery.materialize state 100) == .tuple [list [], a "false", i 0]

private def successful (result : Term) : Bool :=
  valueOf result "error" != a "true" &&
    ![b "async_running", b "running", b "failed", b "error", b "guidance"].contains (valueOf result "status")

-- A pre-contract binding cannot settle or ACK accepted work. Its tool result
-- remains on the ordinary result path; do not infer the new fence from old data.
private def validBinding (binding : Term) : Bool :=
  let sources := binding.get (b "context_source_message_ids")
  let source := binding.get (b "source_message_id")
  let id := binding.get (b "assistant_id")
  let ack := binding.get (b "last_ack_message_id")
  let call := binding.get (b "tool_call_id")
  sources.isList && (wrap sources).contains source && source.isBinary && source != b "" &&
    id.isInteger && ack.isInteger && integerValue id > integerValue ack &&
    call.isBinary && call != b "" && [b "done", b "blocked"].contains (binding.get (b "outcome"))

def withoutWake (events : List Term) (id : Term) : List Term :=
  events.filter (fun event => !(event.get (b "type") == b "queue_append" &&
    (event.get (b "payload")).get (b "source_tool_call_id") == id))

def settled (events : List Term) : Bool :=
  events.any (fun event => [b "terminal_reply_delivered", b "channel_onboarding_settled", b "runtime_failure_reply_settled"].contains
    (event.get (b "kind")))

private def completedRepair (sid : Term) : Term :=
  .map [(b "type", b "visible_reply_repair"), (b "session_id", sid), (b "status", b "completed")]

private def terminalEvents (sid hwm kind details : Term) : List Term :=
  [.map [(b "type", b "session_event"), (b "session_id", sid), (b "kind", kind),
     (b "event", details.put (b "settled_ack_hwm") hwm)],
   .map [(b "type", b "wait_clear"), (b "session_id", sid)],
   .map [(b "type", b "ack"), (b "session_id", sid), (b "last_ack_message_id", hwm)],
   .map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")]]

/-- A stopped activation can finish without a provider destination. Only the
materialized transcript is acknowledged; queued inputs and accepted calls stay
owned by their existing lifecycles. No notification attempt is fabricated. -/
def guardLocalSettlement (state : Term) : KernelM Term := do
  if ← RoundQuery.runawayRetirementPending state then return nil
  if !(← RoundQuery.guardDispositionPending state) then return nil
  let hasTarget := (← RoundQuery.guardDispositionBinding state (← field state "next_message_id")).isMap
  if hasTarget && ((← RoundQuery.failureReason state) != b "guard" ||
      (← RoundQuery.guardCleanupTargets state).isList) then return nil
  let hwm ← sub (← field state "next_message_id") (i 1)
  let details := Term.map [(b "failure_reason", ← RoundQuery.failureReason state),
    (b "context_source_message_ids", ← RoundQuery.currentSourceIds state),
    (b "notification_outcome", b "unavailable"),
    (b "notification_reason", b (if hasTarget then "foreign_work_prevents_safe_notification" else "no_destination")),
    (b "outcome", b "blocked")]
  return list (terminalEvents (← field state "session_id") hwm (b "runtime_failure_disposed") details)

def terminal (state record result : Term) (events : List Term) : KernelM Term := do
  let binding := valueOf record "terminal_reply"
  let onboarding := binding.isMap && binding.get (b "kind") == b "channel_onboarding"
  let terminal := successful result || (onboarding &&
    [b "guidance", b "error", b "failed", b "completed"].contains (valueOf result "status"))
  if !(validBinding binding && terminal && (← RoundQuery.bindingMatches state binding).truthy) then return nil
  let sid ← field state "session_id"
  let events := withoutWake events (binding.get (b "tool_call_id")) ++
    (if onboarding then [completedRepair sid] else [])
  let next ← project state events
  if !((← RoundQuery.bindingMatches next binding).truthy && (← ReplyQuery.phase next) == a "clean" &&
    (← ready next) && !(← RoundQuery.replyRunning next).truthy) then return nil
  let hwm ← sub (← field next "next_message_id") (i 1)
  let details := binding.put (b "outcome")
    (if onboarding && !successful result then b "blocked" else binding.get (b "outcome"))
  return list (events ++ terminalEvents sid hwm
    (if onboarding then b "channel_onboarding_settled" else b "terminal_reply_delivered") details)

def onboarding (state : Term) (results events : List Term) (router : Bool) : KernelM Term := do
  let scope ← RoundQuery.sourceScope state
  if !scope.isMap || !(← RoundQuery.channelOnboardingOrigin (scope.get (b "trusted_origin"))) || !router then return nil
  let source ← RoundQuery.onboardingSourceMessageId state (scope.get (b "source_message_id"))
  if !source.isInteger then return nil
  let next ← project state events
  let nextId ← field next "next_message_id"
  let exhausted := (← StateQuery.modelGuardExhausted next) ||
    integerValue nextId - integerValue source ≥ 24 ||
    (← RoundQuery.onboardingSendCompleted next (← field state "last_ack_message_id")).truthy ||
    results.any (fun result => [b "im_api.slack.post_channel_message", b "im_api.slack.post_message"].contains (valueOf result "name") &&
      ![b "running", b "async_running"].contains (valueOf result "status"))
  if !exhausted || (← RoundQuery.sourceScope next) != scope || !(← ready next) ||
    (← RoundQuery.replyRunning next).truthy then return nil
  let sid ← field state "session_id"
  let details := Term.map [(b "source_message_id", scope.get (b "source_message_id")),
    (b "context_source_message_ids", scope.get (b "context_source_message_ids")), (b "outcome", b "blocked")]
  return list (events ++ [completedRepair sid] ++
    terminalEvents sid (← sub nextId (i 1)) (b "channel_onboarding_settled") details)

/-- Reserve the only runtime failure notification for a stopped activation. The projection survives transcript compaction; it is not authority
for any other destination or for a second provider dispatch. -/
private def guardPrepare (state binding : Term) : KernelM Term := do
  if !(← RoundQuery.guardDispositionPending state) then return nil
  if !validBinding binding || binding.get (b "outcome") != b "blocked" then return nil
  let expected ← RoundQuery.guardDispositionBinding state (binding.get (b "assistant_id"))
  if !expected.isMap || binding.get (b "kind") != expected.get (b "kind") then return nil
  if binding.get (b "assistant_id") != (← field state "next_message_id") then return nil
  if !(← RoundQuery.bindingMatches state binding).truthy then return nil
  let billing ← billingFailureReason state
  return .map [(b "type", b "session_event"), (b "session_id", ← field state "session_id"),
    (b "kind", b "runtime_failure_reply_attempted"), (b "source", b "internal_runtime"),
    (b "event", if (← RoundQuery.failureReason state) == b "model" then (binding.put (b "failure_reason") (b "model")).put (b "billing_reason") billing else binding)]

/-- Restart owns cancellation of the committed attempt's orphaned local work.
The caller excludes live dispatch owners first. Callback records remain present
until their capability request has synchronized its terminal state. -/
def guardCleanupEvents (state args : Term) : KernelM Term := do
  let .tuple [result, now] := args | fail "function_clause"
  let attempt ← field state "runtime_failure_reply"
  if !attempt.isMap || !now.isInteger then return nil
  if attempt.get (b "failure_reason") == b "model" then
    let id := attempt.get (b "tool_call_id")
    let .tuple [.atom "ok", record] ← resolveResult state id | return list []
    if valueOf record "status" != b "running" then return list []
    let known := result != nil && valueOf result "id" == id && valueOf result "status" == b "completed" && successful result
    return list [.map [(b "type", b (if known then "async_tool_call_completed" else "async_tool_call_failed")),
      (b "session_id", ← field state "session_id"), (b "tool_call_id", id),
      (b "result", result), (b "error_class", b "runtime_failure_notification_unknown"), (b "completed_at", now)]]
  let targets ← RoundQuery.guardCleanupTargets state
  if !targets.isList then return nil
  let sid ← field state "session_id"
  let events := (wrap targets).map (fun id =>
    if result != nil && valueOf result "id" == id && valueOf result "status" == b "completed" && successful result then
      Term.map [(b "type", b "async_tool_call_completed"), (b "session_id", sid),
        (b "tool_call_id", id), (b "result", result), (b "completed_at", now)]
    else Term.map [(b "type", b "async_tool_call_cancelled"), (b "session_id", sid),
      (b "tool_call_id", id), (b "cancelled_at", now),
      (b "cancel_reason", b "Runtime guard ended this local execution; external completion and cleanup remain unconfirmed.")])
  return list events

/-- Complete a committed runtime failure attempt without retrying its send.
The host supplies the actual terminal result, or nil only after excluding its
live dependency. New input is never acknowledged by this failure receipt. -/
def guardSettlement (state result : Term) (events : List Term) : KernelM Term := do
  let binding ← field state "runtime_failure_reply"
  if !validBinding binding || binding.get (b "agent_id") != (← field state "agent_id") ||
      binding.get (b "session_id") != (← field state "session_id") then return nil
  if (binding.get (b "notification_outcome")).isBinary then return nil
  let model := binding.get (b "failure_reason") == b "model"
  let callId := binding.get (b "tool_call_id")
  if result != nil && valueOf result "id" != callId then return nil
  if result != nil && [b "running", b "async_running"].contains (valueOf result "status") then return nil
  let next ← project state events
  let workRemains := (← RoundQuery.replyRunning next).truthy ||
    integerValue (← ReplyQuery.blockingObligationCount next) > 0 || (← StateQuery.pendingVisibleReply next)
  if !model && workRemains then return nil
  let aid := binding.get (b "assistant_id")
  if integerValue (← field next "last_ack_message_id") ≥ integerValue aid then return list events
  let messages ← StateQuery.properList ((← field next "messages").default (list []))
  let laterInputs := messages.filter (fun message =>
    integerValue (valueOf message "id") > integerValue aid &&
      [b "user", b "runtime", b "assistant"].contains (valueOf message "role"))
  let tail := integerValue (← field next "next_message_id") - 1
  -- A compacted later input is no longer provably this attempt's tool tail.
  let tail := if integerValue (← field next "compacted_through") > integerValue aid then integerValue aid else tail
  let hwm := i (laterInputs.foldl (fun high message => min high (integerValue (valueOf message "id") - 1)) tail)
  if integerValue hwm < integerValue aid then return nil
  let notification := if result != nil && valueOf result "status" == b "completed" && successful result then b "delivered"
    else if result != nil && valueOf result "status" == b "guidance" then b "refused" else b "unknown"
  let sid ← field state "session_id"
  let details := binding.put (b "notification_outcome") notification
    |>.put (b "notification_hwm") hwm
    |>.put (b "outcome") (if notification == b "unknown" then b "failure_unknown" else b "blocked")
    |>.put (b "public_summary") (b "This request could not be completed. Any unconfirmed external effects still require cleanup.")
  let repair := .map [(b "type", b "visible_reply_repair"), (b "session_id", sid),
    (b "status", b "exhausted"), (b "diagnostic_hwm", hwm)]
  if model then
    let receipt := Term.map [(b "type", b "session_event"), (b "session_id", sid),
      (b "kind", b "runtime_failure_reply_settled"), (b "event", details)]
    -- Only this notification's own completed auto-wait can clear here.
    let ownWait := if ← waitExact next callId then
      [Term.map [(b "type", b "wait_clear"), (b "session_id", sid), (b "tool_call_id", callId)]] else []
    if workRemains then return list (withoutWake events callId ++ ownWait ++ [receipt,
      .map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")]])
    return list (withoutWake events callId ++ terminalEvents sid hwm (b "runtime_failure_reply_settled") details)
  return list (events ++ [repair] ++ terminalEvents sid hwm (b "runtime_failure_reply_settled") details)

def batch (state args : Term) : KernelM Term := do
  let .tuple [events, results, track, unsettled, reset, router] := args | fail "function_clause"
  let events ← asList events
  let results ← asList results
  let guard := if track.truthy then
    [if results.all (fun result => result.get (a "status") == b "guidance") then unsettled else reset] else []
  let events := events ++ guard
  let next ← project state events
  let parked := (!guard.isEmpty && (← StateQuery.runawayExhausted next)) || (← StateQuery.repeatedExhausted next) ||
    (← StateQuery.roundBudgetExhausted next)
  let sid ← field state "session_id"
  let events := events ++ (if parked then [.map [(b "type", b "status"),
    (b "session_id", sid), (b "status", b "idle")]] else [])
  let events ← match results with
    | [result] => do
      let terminalEvents ← terminal state result result events
      if terminalEvents != nil then pure terminalEvents
      else pure ((← guardSettlement state result events).default (list events))
    | _ => pure (list events)
  let events ← asList events
  if settled events then return list events
  return (← onboarding state results events router.truthy).default (list events)

/-- End the current runaway activation as failed, not delivered. Abandon its
reply work before ACK so even blocking cards cannot fence later input. Accepted
async operations and queued deliveries retain their own identities and lifecycle. -/
def retireRunaway (state : Term) : KernelM Term := do
  if !(← RoundQuery.runawayRetirementPending state) then return nil
  let sid ← field state "session_id"
  let obligations ← ReplyQuery.pendingObligations state
  let retire := (← entries (obligationMap state)).map (fun target => Term.map
    [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", sid),
     (b "obligation_key", target.1), (b "outcome", b "blocked")])
  let intent ← field state "visible_reply_intent"
  let abort := if intent.isMap then [Term.map
    [(b "type", b "visible_reply_aborted"), (b "session_id", sid),
     (b "idempotency_key", obligationValue intent "idempotency_key")]] else []
  let repair := if (← field state "visible_reply_repair").isMap then [Term.map
    [(b "type", b "visible_reply_repair"), (b "session_id", sid), (b "status", b "aborted")]] else []
  let details := Term.map [(b "outcome", b "blocked"), (b "reason", b "runaway_unsettled_rounds"),
    (b "abandoned_reply_obligations", obligations),
    (b "source_message_ids", ← RoundQuery.currentSourceIds state),
    (b "consecutive_unsettled_rounds", ← unsettledCount state)]
  return list (retire ++ abort ++ repair ++ terminalEvents sid
    (← sub (← field state "next_message_id") (i 1)) (b "runtime_runaway_retired") details)

/-- `TerminalReply.context/4`: the terminal-reply scope for one dispatch.
`args` carries the activation's role, trusted origin and source ids, the
assistant message id, the round's call count, and `router_authority`: the
host's fact that this session is the agent's canonical Router session. -/
def replyContext (state args : Term) : KernelM Term := do
  let key := fun (k : String) => RoundQuery.textKey args k
  let text := fun (v : Term) => if v == nil then pure (b "") else stringChars v
  let origin := key "trusted_origin"
  let router := key "role" == b "router" && key "router_authority" == a "true"
  let scope ← RoundQuery.sourceScope state
  let targets ← RoundQuery.replyTargets (scope.get (b "trusted_origin"))
  let sameScope := scope.isMap && scope.get (b "source_message_id") == key "source_message_id" &&
    scope.get (b "context_source_message_ids") == key "source_message_ids" &&
    scope.get (b "trusted_origin") == origin
  let settle := key "call_count" == i 1 && sameScope && (← ready state) &&
    !(← RoundQuery.replyRunning state).truthy
  let common := [(b "agent_id", key "agent_id"), (b "session_id", ← field state "session_id"),
    (b "context_source_message_ids", key "source_message_ids"),
    (b "source_message_id", key "source_message_id"), (b "trusted_origin", origin),
    (b "assistant_id", key "assistant_id"),
    (b "last_ack_message_id", ← field state "last_ack_message_id")]
  if targets != list [] && origin.isMap && router then
    return .map ([(b "kind", RoundQuery.textKey origin "provider"), (b "targets", targets),
      (b "eligible", Term.bool settle)] ++ common)
  -- Telegram and the channel welcome keep their legacy destination binding.
  if !router then return nil
  let onboarding ← RoundQuery.channelOnboardingOrigin origin
  if !(RoundQuery.textKey origin "provider" == b "telegram" || onboarding) then return nil
  if RoundQuery.textKey origin "source_actor_type" != b "provider_user" then return nil
  let destination := RoundQuery.textKey origin "provider_context"
  if !(destination.isMap && destination.has (b "connect_id")) then return nil
  let chat := (destination.get (b "chat_id")).default (destination.get (b "channel_id"))
  if chat == nil then return nil
  return .map ([(b "kind", b (if onboarding then "channel_onboarding" else "telegram")),
    (b "connect_id", destination.get (b "connect_id")), (b "chat_id", ← stringChars chat),
    (b "message_thread_id", ← text (destination.get (b "message_thread_id"))),
    (b "reply_to_message_id", ← text (destination.get (b "message_id"))),
    (b "eligible", Term.bool (settle &&
      RoundQuery.textKey origin "source_message_id" == key "source_message_id"))] ++ common)

def table : OpTable :=
  [("runaway_retirement", fun state _ => retireRunaway state),
   ("guard_failure_local_settlement", fun state _ => guardLocalSettlement state),
   ("guard_failure_prepare", guardPrepare),
   ("guard_failure_cleanup_targets", fun state _ => RoundQuery.guardCleanupTargets state),
   ("guard_failure_cleanup_events", guardCleanupEvents),
   ("guard_failure_settlement", fun state args => do
     let .tuple [result, events] := args | fail "function_clause"
     guardSettlement state result (← asList events)),
   ("onboarding_authority_required?", fun state _ => do
     let scope ← RoundQuery.sourceScope state
     return Term.bool (scope.isMap && (← RoundQuery.channelOnboardingOrigin (scope.get (b "trusted_origin"))))),
   ("settle_tool_batch", batch),
   ("terminal_settlement", fun state args => do
     let .tuple [record, result, events] := args | fail "function_clause"
     let events ← asList events
     let terminalEvents ← terminal state record result events
     if terminalEvents != nil then pure terminalEvents else guardSettlement state result events),
   ("onboarding_settlement", fun state args => do
     let .tuple [results, events, router] := args | fail "function_clause"
     onboarding state (← asList results) (← asList events) router.truthy),
   ("onboarding_async_settlement", fun state args => do
     let .tuple [pending, result, events, router] := args | fail "function_clause"
     let scope ← RoundQuery.sourceScope state
     if !scope.isMap || valueOf pending "trusted_origin_source_message_ids" != scope.get (b "context_source_message_ids") then return nil
     onboarding state [result] (withoutWake (← asList events) (valueOf pending "tool_call_id")) router.truthy),
   ("settlement_ready?", fun state _ => return Term.bool (← ready state)),
   ("settlement_completed?", fun _ events => return Term.bool (settled (← asList events))),
   ("terminal_reply_context", replyContext)]

end VerifiedKernel.Session.Settlement
