import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.Query.Round

namespace VerifiedKernel.Session.ScheduledPresentation
open Data
open ReplyQuery (policyValue)

private def absent : Term := a "not_scheduled_task_failure"

private def set (data : Term) (key : String) (item : Term) : Term :=
  data.put (if data.has (b key) then b key else a key) item

private def identity (origin : Term) : KernelM Term := do
  if !origin.isMap then return absent
  let schedule := policyValue origin "task_schedule"
  let conversation := RepairQuery.presentString (policyValue origin "conversation_id")
  let scheduleId := if schedule.isMap then RepairQuery.presentString (policyValue schedule "schedule_id") else nil
  let scheduledFor := if schedule.isMap then policyValue schedule "scheduled_for" else nil
  if policyValue origin "provider" != b "internal" || policyValue origin "conversation_kind" != b "agent_task" ||
      policyValue origin "source_actor_type" != b "system" || !conversation.isBinary ||
      !scheduleId.isBinary || !scheduledFor.isInteger then return absent
  let .binary scheduleBytes := scheduleId | fail "badarg"
  let .binary timeBytes ← stringChars scheduledFor | fail "badarg"
  return .tuple [a "ok", conversation, .binary ("scheduled-task-safe-failure:".toUTF8 ++ scheduleBytes ++ ":".toUTF8 ++ timeBytes)]

private def params (call : Term) : Term :=
  let args := policyValue call "args"
  if policyValue call "name" == b "call" && args.isMap then (policyValue args "params").default empty
  else args.default empty

private def callIdentity (call : Term) : Term :=
  if !call.isMap then nil else
    (RepairQuery.presentString (policyValue (params call) "request_id")).default
      (RepairQuery.presentString (policyValue call "id"))

private def makeCall (origin call restricted : Term) : KernelM Term := do
  let .tuple [.atom "ok", conversation, requestId] ← identity origin | return absent
  let call := call.default (.map [(a "id", requestId), (a "name", b "call"),
    (a "args", .map [(b "tool", b "im_api.internal.send_message")])])
  let summary := b "This scheduled run could not be completed because a required integration was unavailable. The result was recorded only in this Task; the Router must handle any requested external reporting."
  let params := Term.map [(b "connect_id", b "internal"), (b "conversation_id", conversation),
    (b "content", list [.map [(b "type", b "text"), (b "text", summary)]]), (b "request_id", requestId)]
  let params := if restricted.truthy then params.put (b "delivery_filter")
    (.map [(b "participant_ids", list [])]) else params
  let args := policyValue call "args"
  let call := if policyValue call "name" == b "call" && args.isMap then
    set call "args" (set args "params" params) else set call "args" params
  return .tuple [a "ok", call]

private def makeCalls (origins : List Term) (restricted : Term) : KernelM (List Term) :=
  origins.foldlM (fun calls origin => do
    match ← makeCall origin nil restricted with
    | .tuple [.atom "ok", call] =>
      return if calls.any (fun previous => callIdentity previous == callIdentity call) then calls else calls ++ [call]
    | _ => return calls) []

private def origins (context : Term) : List Term :=
  let many := policyValue context "trusted_origins"
  let many := if many.isList then wrap many else []
  let one := policyValue context "trusted_origin"
  if one.isMap then uniq (many ++ [one]) else many

private def sanitizeCall (call context restricted : Term) : KernelM Term := do
  if !call.isMap || !context.isMap || !Presentation.required (policyValue context "visible_reply_phase") then return absent
  if (← ReplyQuery.targetTool call) != b "im_api.internal.send_message" then return absent
  let found ← (origins context).foldlM (fun found origin => do
    if found != nil then return found
    match ← identity origin with
    | .tuple [.atom "ok", _, requestId] => return if requestId == callIdentity call then origin else nil
    | _ => return nil) nil
  let .tuple [.atom "ok", conversation, _] ← identity found | return absent
  if policyValue (params call) "conversation_id" != conversation then return absent
  makeCall found call restricted

private def sanitizeCalls (calls : List Term) (context restricted : Term) : KernelM Term := do
  if calls.isEmpty then return absent
  let candidates ← calls.mapM (fun call => sanitizeCall call context restricted)
  let sanitized := candidates.filterMap (fun value =>
    match value with | .tuple [.atom "ok", call] => some call | _ => none)
  if sanitized.length != calls.length then return absent
  let ids := sanitized.map callIdentity
  if !(ids.all Term.isBinary) || (uniq ids).length != ids.length then return absent
  return .tuple [a "ok", list sanitized]

private def retryCalls (calls : List Term) (origins : List Term) (restricted : Term) : KernelM Term := do
  let [call] := calls | return absent
  if !call.isMap || (← ReplyQuery.targetTool call) != b "im_api.internal.send_message" then return absent
  let conversation := RepairQuery.presentString (policyValue (params call) "conversation_id")
  if !conversation.isBinary then return absent
  let matching ← origins.foldlM (fun matching origin => do
    match ← identity origin with
    | .tuple [.atom "ok", target, _] => return if target == conversation then matching ++ [origin] else matching
    | _ => return matching) []
  let calls ← makeCalls matching restricted
  return if calls.isEmpty then absent else .tuple [a "ok", list calls]

def policy (args : Term) : KernelM Term := do
  match args with
  | .tuple [.atom "call", origin, call, restricted] => makeCall origin call restricted
  | .tuple [.atom "sanitize", call, context, restricted] => sanitizeCall call context restricted
  | .tuple [.atom "sanitize_calls", calls, context, restricted] => sanitizeCalls (← asList calls) context restricted
  | .tuple [.atom "call_id?", id] => return Term.bool (RepairQuery.scheduledCallId id)
  | .tuple [.atom "mark_result", result] =>
    let outcome ← if ← RepairQuery.pendingResult result then pure (b "scheduled_task_failure_pending")
      else if ← RepairQuery.failureResult result then pure (b "scheduled_task_failure_failed")
      else pure (b "contained_scheduled_task_failure")
    return set result "repair_outcome" outcome
  | _ => fail "function_clause"

private def responsePlan (state args : Term) : KernelM Term := do
  let .tuple [kind, calls, terminal, sources, restricted] := args | fail "function_clause"
  if !Presentation.required (← ReplyQuery.phase state) then return a "keep"
  let origins ← asList (← RoundQuery.currentTurnTrustedOrigins state sources)
  if origins.isEmpty then return a "keep"
  let scheduled ← makeCalls origins restricted
  if !scheduled.isEmpty && (kind == a "final" || (kind == a "assistant" && terminal.truthy)) then
    return .tuple [a "replace_calls", list scheduled]
  if kind == a "assistant" then
    match ← retryCalls (← asList calls) origins restricted with
    | .tuple [.atom "ok", calls] => return .tuple [a "replace_calls", calls]
    | _ => return a "keep"
  return a "keep"

def table : OpTable := [("scheduled_presentation", fun _ args => policy args),
  ("prepare_response", responsePlan)]
end VerifiedKernel.Session.ScheduledPresentation
