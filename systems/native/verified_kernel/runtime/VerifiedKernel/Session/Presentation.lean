import VerifiedKernel.Session.Query.Repair
import VerifiedKernel.Session.FailureOutcome
import VerifiedKernel.Grapheme
import VerifiedKernel.AgentLoop.Policy

namespace VerifiedKernel.Session.Presentation
open Data
open ReplyQuery (policyValue nonNegInt)
open RepairQuery (stringValue presentString pendingResult failureResult)

private def set (data : Term) (key : String) (item : Term) : Term :=
  data.put (if data.has (b key) then b key else a key) item

private def drop (data : Term) (keys : List String) : KernelM Term :=
  keys.foldlM (fun data key => do remove (← remove data (a key)) (b key)) data

private def flushText (run : ByteArray) (limit : Nat) : ByteArray × Nat :=
  let text := (String.fromUTF8? run).getD ""
  let kept := Grapheme.takeString text limit
  (kept.toUTF8, Grapheme.countString kept)

private def takeMixed (raw : ByteArray) : Nat → Nat → Nat → ByteArray → ByteArray → ByteArray
  | 0, _, limit, run, result => result ++ (flushText run limit).1
  | fuel + 1, offset, limit, run, result =>
    if offset ≥ raw.size then result ++ (flushText run limit).1 else
      let first := (raw.data[offset]?.getD 0).toNat
      let width := if first < 128 then 1 else if first < 224 then 2 else if first < 240 then 3 else 4
      let chunk := raw.extract offset (offset + width)
      if chunk.size == width && (String.fromUTF8? chunk).isSome then
        takeMixed raw fuel (offset + width) limit (run ++ chunk) result
      else
        let (kept, count) := flushText run limit
        let result := result ++ kept
        if count ≥ limit then result else
          takeMixed raw fuel (offset + 1) (limit - count - 1) ByteArray.empty (result.push (raw.data[offset]?.getD 0))

private def summary (value : Term) : Term :=
  match RepairQuery.presentString value with
  | .binary raw =>
    match String.fromUTF8? raw with
    | some text => b (Grapheme.takeString text 512)
    | none => .binary (takeMixed raw raw.size 0 512 ByteArray.empty ByteArray.empty)
  | _ => nil

def required (phase : Term) : Bool :=
  match phase with | .tuple [.atom "repair_required", _] => true | _ => false

def modelOnly (result : Term) : KernelM Bool := do
  return result.isMap && (← stringValue result "diagnostic_visibility") == b "model_only"

def repairOrigin (result : Term) : KernelM Bool := do
  return result.isMap && (← stringValue result "visible_reply_origin") == b "repair"

def userReportable (result : Term) : KernelM Bool := do
  return result.isMap && (← stringValue result "diagnostic_visibility") == b "user_reportable" &&
    RepairQuery.presentString (policyValue result "public_summary") != nil

def privateResult (result : Term) : KernelM Bool := do
  return (← modelOnly result) || ((← repairOrigin result) && !(← userReportable result))

def label (result : Term) : KernelM Term := do
  let visibility ← stringValue result "diagnostic_visibility"
  let publicSummary := summary (policyValue result "public_summary")
  if visibility == b "user_reportable" && publicSummary != nil then
    return set (set result "diagnostic_visibility" (b "user_reportable")) "public_summary" publicSummary
  let visibility := if ← failureResult result then b "model_only" else b "none"
  drop (set result "diagnostic_visibility" visibility) ["public_summary"]

private def repairBudget : KernelM Term := do
  let configured ← observe (.tuple [a "config", a "salix_agent", a "visible_reply_repair_budget", i 2])
  return if configured.isInteger && integerValue configured > 0 then configured else i 2

private def failedTransition (attempts : Term) : KernelM Term := do
  let next ← add attempts (i 1)
  let budget ← repairBudget
  return .tuple [if ← atMost budget next then a "exhausted" else a "required", next]

private def acceptable (result : Term) : KernelM Bool := do
  if ← pendingResult result then return false
  if (← stringValue result "repair_outcome") == b "contained_scheduled_task_failure" then return true
  if ← userReportable result then return true
  return !(← modelOnly result) && !(← failureResult result)

def transition (phase : Term) (results : List Term) : KernelM Term := do
  if phase == a "clean" then
    let privateResults ← results.mapM privateResult
    return if privateResults.any id then .tuple [a "required", i 0] else a "none"
  let .tuple [.atom "repair_required", attempts] := phase | fail "function_clause"
  if (← results.mapM pendingResult).any id then return .tuple [a "required", attempts]
  if !results.isEmpty && (← results.mapM acceptable).all id then return a "completed"
  failedTransition attempts

def transitionEvents (transition sessionId hwm : Term) : KernelM (List Term) := do
  if transition == a "none" then return []
  let now := i (integerValue (← observe (a "time")) / 1000)
  let base := Term.map [(b "type", b "visible_reply_repair"), (b "session_id", sessionId), (b "created_at", now)]
  if transition == a "completed" then
    return [base.put (b "status") (b "completed") |>.put (b "completed_at_hwm") hwm]
  let .tuple [kind, attempts] := transition | fail "function_clause"
  let event := base.put (b "attempts") attempts |>.put (b "diagnostic_hwm") hwm
  if kind == a "required" then return [event.put (b "status") (b "required")]
  if kind != a "exhausted" then fail "function_clause"
  let publicSummary := b "I couldn't complete that reply safely. Please try again."
  let .binary sessionBytes ← stringChars sessionId | fail "badarg"
  let .binary hwmBytes ← stringChars hwm | fail "badarg"
  return [event.put (b "status") (b "exhausted") |>.put (b "public_summary") publicSummary,
    .map [(b "type", b "session_event"), (b "session_id", sessionId),
      (b "event_id", .binary ("visible-reply-repair-exhausted:".toUTF8 ++ sessionBytes ++ ":".toUTF8 ++ hwmBytes)),
      (b "kind", b "visible_reply_repair_exhausted"), (b "source", b "internal_runtime"),
      (b "event", .map [(b "issue", b "visible_reply_repair_exhausted"), (b "message", publicSummary)]),
      (b "created_at", now)],
    .map [(b "type", b "ack"), (b "session_id", sessionId), (b "last_ack_message_id", hwm)],
    .map [(b "type", b "status"), (b "session_id", sessionId), (b "status", b "idle")]]

private def preserveRequired (facts sessionId attempts diagnostic : Term) : KernelM (List Term) := do
  let hwm ← maximum (← maximum (facts.get (b "next_hwm")) (facts.get (b "repair_diagnostic_hwm"))) (nonNegInt diagnostic)
  let events ← transitionEvents (.tuple [a "required", attempts]) sessionId hwm
  let revision ← add (facts.get (b "repair_revision")) (i 1)
  return events.map (fun event => event.put (b "revision") revision)

def asyncCompletion (state args : Term) : KernelM Term := do
  let .tuple [events, result, diagnostic] := args | fail "function_clause"
  let events ← asList events
  let withoutNotification := events.filter (fun event =>
    !(event.get (b "type") == b "queue_append" && event.get (b "kind") == b "runtime_message"))
  let facts ← RepairQuery.asyncCompletionFacts state result
  if (facts.get (b "exhausted?")).truthy then return list withoutNotification
  let sessionId ← field state "session_id"
  let phase := facts.get (b "phase")
  let hwm := facts.get (b "next_hwm")
  match phase, facts.get (b "scheduled") with
  | .tuple [.atom "repair_required", attempts], .tuple [.atom "scheduled", outcome] =>
    if outcome == a "completed" then
      return list (withoutNotification ++
        [.map [(b "type", b "wait_clear"), (b "session_id", sessionId)]] ++
        (← transitionEvents (a "completed") sessionId hwm) ++
        [.map [(b "type", b "ack"), (b "session_id", sessionId), (b "last_ack_message_id", hwm)],
         .map [(b "type", b "status"), (b "session_id", sessionId), (b "status", b "idle")]])
    return list ((if outcome == a "pending" then withoutNotification else events) ++
      (← preserveRequired facts sessionId attempts diagnostic))
  | .atom "clean", _ =>
    return list (events ++ (← transitionEvents (← transition phase [← label result]) sessionId hwm))
  | .tuple [.atom "repair_required", attempts], .atom "not_scheduled" =>
    let decision ← transition phase [← label result]
    let extra ← if decision == a "completed" then
      transitionEvents decision sessionId (← maximum hwm (nonNegInt diagnostic))
      else preserveRequired facts sessionId attempts diagnostic
    return list (events ++ extra)
  | _, _ => fail "function_clause"

def recoveredCompletion (state args : Term) : KernelM Term := do
  let .tuple [events, results, hwm] := args | fail "function_clause"
  let events ← asList events
  if ← repairExhausted state then
    return list (events.filter (fun event =>
      !(event.get (b "type") == b "queue_append" && event.get (b "kind") == b "runtime_message")))
  let results ← (← asList results).mapM label
  let first :: _ := results | return list events
  let phase ← ReplyQuery.phase state
  if required phase then
    return ← asyncCompletion state (.tuple [list events, first, hwm])
  return list (events ++ (← transitionEvents (← transition phase results) (← field state "session_id") hwm))

private def legacyFailure (message : Term) : KernelM Bool := do
  let .binary kind ← stringValue message "type" | fail "badarg"
  return (← stringValue message "role") == b "runtime" &&
    ((kind.size ≥ 7 && kind.extract (kind.size - 7) kind.size == "_failed".toUTF8) ||
      ![nil, list []].contains (policyValue message "failed_tool_calls") ||
      policyValue message "failed_llm_call" != nil)

-- The conditions below read fields only while the answer is open, like the
-- short-circuit `&&` and `||` of `VisibleReplyPolicy`. A `(← _)` inside `&&`
-- would read every field of every message.
private def privateDiagnostic (message : Term) : KernelM Bool := do
  if !message.isMap then return false
  if ![b "tool", b "runtime"].contains (← stringValue message "role") then return false
  if ← userReportable message then return false
  if ← repairOrigin message then return true
  if ← modelOnly message then return true
  if ← failureResult message then return true
  legacyFailure message

private def sensitiveFields : List String := ["source_refs", "reason", "failed_tool_calls",
  "pending_external_callback_tool_calls", "failed_llm_call", "input", "output", "error_class",
  "error_message", "guidance_reason", "repair_outcome", "provider_meta"]

private def sanitizePublic (message : Term) : KernelM Term := do
  if !message.isMap || ![b "tool", b "runtime"].contains (← stringValue message "role") ||
      !(← userReportable message) then return message
  let publicSummary := summary (policyValue message "public_summary")
  let some content ← Json.encode (.map [(b "status", b "error"), (b "public_summary", publicSummary)])
    | fail "invalid_term"
  drop (set (set message "content" (.binary content)) "summary" publicSummary) sensitiveFields

/-- The content that replaces a private diagnostic after repair. It keeps the
result state and the closed facts of `FailureOutcome`, never diagnostic text.
A failure must not read as a success. -/
private def retainedContent (message : Term) : KernelM Term := do
  if ← pendingResult message then return b "{\"status\":\"running\"}"
  -- `label` marks only failures `model_only`. A private message without a
  -- failure mark or with a structural `completed` status is a success, for
  -- example a send made during repair.
  let status ← stringValue message "status"
  let failed := (← failureResult message) || (← legacyFailure message) ||
    ((← modelOnly message) && status != b "completed")
  if !failed then return b "{\"status\":\"completed\"}"
  let guidance := status == b "guidance"
  let kind := if (← stringValue message "role") == b "runtime" then policyValue message "type" else nil
  let record := FailureOutcome.record (policyValue message "error_class")
    (policyValue message "guidance_reason") kind guidance
  let some content ← Json.encode record | fail "invalid_term"
  return .binary content

/-- Redacted arguments of a call whose result was a private diagnostic. The
target tool name survives when it is a valid identifier. -/
private def redactedArgs (call : Term) : KernelM Term := do
  let args := policyValue call "args"
  let target := if (← stringValue call "name") == b "call" && args.isMap then
      FailureOutcome.token? (policyValue args "tool") 128 true else none
  return .map ((target.map (fun tool => (b "tool", b tool))).toList ++
    [(b "repair_context", b "redacted")])

private def sanitizeClean (message : Term) (ids : List Term) : KernelM Term := do
  if !message.isMap then return message
  if ← privateDiagnostic message then
    if (← stringValue message "guidance_reason") == b "information_flow" then return message
    return ← drop (set (set message "content" (← retainedContent message)) "diagnostic_visibility" (b "model_only"))
      (sensitiveFields ++ ["summary", "error", "public_summary"])
  let role ← stringValue message "role"
  if [b "tool", b "runtime"].contains role then
    if ← userReportable message then return ← sanitizePublic message
  if role != b "assistant" then return message
  let calls := policyValue message "tool_calls"
  let repair := (← stringValue message "visible_reply_phase") == b "repair"
  let hasPrivate ← if repair || !calls.isList then pure false
    else (← (← asList calls).mapM (fun call => return ids.contains (← stringValue call "id"))).any id |> pure
  if repair || hasPrivate then
    let message := set message "content" (b "")
    let message ← if calls.isList then do
      let redacted ← (← asList calls).mapM (fun call => do
        if ids.contains (← stringValue call "id") then return set call "args" (← redactedArgs call)
        return call)
      pure (set message "tool_calls" (list redacted))
      else pure message
    drop message ["provider_meta"]
  else pure message

/-- The tool call ids of private diagnostic tool results, newest first. -/
private def privateToolCallIds (messages : List Term) : KernelM (List Term) :=
  messages.foldlM (fun ids message => do
    if (← stringValue message "role") != b "tool" then return ids
    if !(← privateDiagnostic message) then return ids
    if (← stringValue message "guidance_reason") == b "information_flow" then return ids
    let id ← stringValue message "tool_call_id"
    return if id == b "" then ids else id :: ids) []

/-- `sanitizeContext messages phase` restricted to `selected`, a sublist of
`messages`: the private tool call ids still come from every message. -/
def sanitizeSelected (messages selected : List Term) (phase : Term) : KernelM Term := do
  if required phase then return list (← selected.mapM sanitizePublic)
  let ids ← privateToolCallIds messages
  return list (← selected.mapM (fun message => sanitizeClean message ids))

def sanitizeContext (messages : List Term) (phase : Term) : KernelM Term := do
  if required phase then return list (← messages.mapM sanitizePublic)
  let ids ← privateToolCallIds messages
  return list (← messages.mapM (fun message => sanitizeClean message ids))

private def stampOrigin (result phase : Term) : KernelM Term := do
  if !result.isMap || !required phase then return result
  let result := set result "visible_reply_origin" (b "repair")
  let events := policyValue result "events"
  if !events.isList then return result
  return set result "events" (list ((← asList events).map (fun event =>
    if event.isMap then event.put (b "visible_reply_origin") (b "repair") else event)))

def policy (args : Term) : KernelM Term := do
  let .tuple [operation, args] := args | fail "function_clause"
  if operation == a "valid_response_identity?" then return Term.bool (validResponseIdentity args)
  if operation == a "valid_terminal_scope?" then
    let ids := args.get (b "source_message_ids")
    let conversation := args.get (b "conversation_id")
    let valid := match ids with
      | .list ids => !ids.isEmpty && ids.all (fun id => id.isBinary && id != b "") && uniq ids == ids
      | _ => false
    return Term.bool (args.isMap && conversation.isBinary && conversation != b "" && valid &&
      validResponseIdentity (args.get (b "response_identity")))
  if operation == a "event_phase" then return if required args then b "repair" else b "clean"
  if operation == a "terminal_guidance" then
    let .tuple [result, reason, phase] := args | fail "function_clause"
    let disclose := !required phase
    return result.put (a "content") reason |>.put (a "error") (a "false")
      |>.put (a "error_class") nil |>.put (a "status") (b "guidance")
      |>.put (a "diagnostic_visibility") (if disclose then b "user_reportable" else b "model_only")
      |>.put (a "public_summary") (if disclose then reason else nil)
  if operation == a "repair_budget" then return ← repairBudget
  if operation == a "target_tool" then return ← ReplyQuery.targetTool args
  if operation == a "label_results" then return list (← (← asList args).mapM label)
  if operation == a "stamp_result_origin" then
    let .tuple [result, phase] := args | fail "function_clause"
    return ← stampOrigin result phase
  if operation == a "inherit_result_origin" then
    let .tuple [result, source] := args | fail "function_clause"
    if ← repairOrigin source then return ← stampOrigin result (.tuple [a "repair_required", i 0])
    return result

  if operation == a "pending_origin_patch" then
    return if required args then .map [(a "visible_reply_origin", b "repair")] else empty
  if operation == a "sanitize_activity_calls" then
    let .tuple [calls, phase] := args | fail "function_clause"
    if !required phase then return calls
    return list ((← asList calls).map (fun call => call.put (a "args") empty |>.put (b "args") empty))
  if operation == a "append_repair_reminder" then
    let .tuple [messages, phase] := args | fail "function_clause"
    if !required phase then return messages
    let reminder := b "A private tool diagnostic requires repair. Keep private diagnostics private and do not quote or expose them. Use the currently disclosed tools as needed; calls execute normally and return their real results or receipts. A successful terminal tool result completes repair, while a pending or failed result keeps repair active. Plain text, blank output, and end_turn cannot settle it."
    return list ((← asList messages) ++ [.map [(a "role", b "summary"), (a "content", reminder)]])
  if operation == a "label_result" then return ← label args
  if operation == a "model_only_result?" then return Term.bool (← modelOnly args)
  if operation == a "user_reportable_result?" then return Term.bool (← userReportable args)
  if operation == a "private_result?" then return Term.bool (← privateResult args)
  if operation == a "repair_origin?" then return Term.bool (← repairOrigin args)
  if operation == a "repair_required?" then return Term.bool (required args)
  if operation == a "transition" then
    let .tuple [phase, results] := args | fail "function_clause"
    return ← transition phase (← asList results)
  if operation == a "no_tool_transition" then
    if args == a "clean" then return a "none"
    let .tuple [.atom "repair_required", attempts] := args | fail "function_clause"
    return ← failedTransition attempts
  if operation == a "transition_events" then
    let .tuple [decision, sessionId, hwm] := args | fail "function_clause"
    return list (← transitionEvents decision sessionId hwm)
  if operation == a "sanitize_context" then
    let .tuple [messages, phase] := args | fail "function_clause"
    return ← sanitizeContext (← asList messages) phase
  fail "function_clause"

def containedFailure (results : List Term) : KernelM Bool := do
  let outcomes ← (results.filter Term.isMap).mapM (fun result => stringValue result "repair_outcome")
  let scheduled := outcomes.filter (fun outcome => [b "contained_scheduled_task_failure",
    b "scheduled_task_failure_pending", b "scheduled_task_failure_failed"].contains outcome)
  return !scheduled.isEmpty && scheduled.all (· == b "contained_scheduled_task_failure")

private def outputPreparation (state args : Term) : KernelM Term := do
  let .tuple [phase, terminal] := args | fail "function_clause"
  let repair := required phase
  let count ← ReplyQuery.blockingObligationCount state
  let body := if terminal == nil then nil
    else if repair then .map [(b "status", b "not_settled"), (b "reason", b "repair_required")]
    else if integerValue count > 0 then .map [(b "status", b "not_settled"),
      (b "reason", b "provider_reply_required"), (b "pending_count", count)]
    else .map [(b "status", b "accepted"), (b "outcome", terminal)]
  return .tuple [body, list (if repair then [] else [a "draft_clear"])]

private def finishOutput (state args : Term) : KernelM Term := do
  let .tuple [leading, assistant, hwm, phase, terminal, unsettled] := args | fail "function_clause"
  let sessionId ← field state "session_id"
  let idle := Term.map [(b "type", b "status"), (b "session_id", sessionId), (b "status", b "idle")]
  let base := (← asList leading) ++ [assistant]
  let result := fun events outcome effects onboarding => Term.tuple [a "ok", list events,
    list [.tuple [a "hwm", hwm]], .map [(a "outcome", outcome), (a "effects", list effects),
      (a "onboarding?", Term.bool onboarding)]]
  if !required phase then
    let rejected := terminal.truthy && integerValue (← ReplyQuery.blockingObligationCount state) > 0
    let settled := terminal.truthy && !rejected
    let settlement := if settled then .map [(b "type", b "ack"), (b "session_id", sessionId),
      (b "last_ack_message_id", hwm)] else unsettled
    return result (base ++ [settlement, idle]) (if settled then a "completed" else a "check_progress")
      (if rejected then [.tuple [a "report", a "provider_reply_obligation_rejection"]] else []) (!settled)
  let decision ← policy (.tuple [a "no_tool_transition", phase])
  let exhausted := match decision with | .tuple [.atom "exhausted", _] => true | _ => false
  let events := base ++ (← transitionEvents decision sessionId hwm) ++ (if exhausted then [] else [idle])
  let effects := if exhausted then [
      Term.tuple [a "report", b "repair_failed"], .tuple [a "activity", a "llm_failed"], .tuple [a "activity", a "idle"]] else []
  return result events (if exhausted then a "final" else a "round_boundary") effects false

private def outputCommitted (state args : Term) : KernelM Term := do
  let .tuple [plan, onboarding] := args | fail "function_clause"
  let outcome := plan.get (a "outcome")
  let outcome ← if onboarding.truthy then pure (a "completed")
    else if outcome == a "check_progress" then
      pure (if ← StateQuery.modelGuardExhausted state then a "park" else a "round_boundary")
    else pure outcome
  return .tuple [outcome, plan.get (a "effects")]

def finishToolBatch (state args : Term) : KernelM Term := do
  let .tuple [events, hwm, wait, checkpoint, results] := args | fail "function_clause"
  let results ← asList results
  let decision ← if checkpoint.truthy then pure checkpoint else transition (← ReplyQuery.phase state) results
  let sessionId ← field state "session_id"
  let events := (← asList events) ++ (← transitionEvents decision sessionId hwm)
  let idle := Term.map [(b "type", b "status"), (b "session_id", sessionId), (b "status", b "idle")]
  let extra ← if ← containedFailure results then pure [
      .map [(b "type", b "ack"), (b "session_id", sessionId), (b "last_ack_message_id", hwm)], idle]
    else pure (if wait.truthy then [idle] else [])
  return .tuple [a "ok", list (events ++ extra), hwm]

private def toolContinuation (_state args : Term) : KernelM Term := do
  let .tuple [park, terminal, async, wait, results, checkpoint] := args | fail "function_clause"
  let exhausted := match checkpoint with | .tuple [.atom "exhausted", _] => true | _ => false
  return a (VerifiedKernel.AgentLoop.Policy.continuation park.truthy terminal.truthy
    (← containedFailure (← asList results)) exhausted async.truthy wait.truthy)

def table : OpTable :=
  [("presentation_policy", fun _ args => policy args), ("async_completion_events", asyncCompletion),
   ("recovered_completion_events", recoveredCompletion),
   ("output_preparation", outputPreparation), ("output_committed", outputCommitted),
   ("finish_output", finishOutput), ("finish_tool_batch", finishToolBatch),
   ("tool_batch_checkpoint", fun state results => do transition (← ReplyQuery.phase state) (← asList results)),
   ("tool_continuation", toolContinuation)]

end VerifiedKernel.Session.Presentation
