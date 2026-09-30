import VerifiedKernel.Session.Settlement

namespace VerifiedKernel.Session.Restart
open Data
open RoundQuery (valueOf)

private def request (name : String) (args context : Term) : Term :=
  .tuple [a "perform", .tuple [b name, args], context]

private def done (result : Term) : Term := .tuple [a "return", result]
private def getList (ctx : Term) (key : String) : List Term := wrap (ctx.get (b key))
private def addItems (ctx : Term) (key : String) (items : List Term) : Term :=
  ctx.put (b key) (list (getList ctx key ++ items))
private def direct (record : Term) : Bool :=
  [b "direct_poll", a "direct_poll"].contains (valueOf record "completion_owner")
private def callback (record : Term) : Bool :=
  [b "external_callback", a "external_callback"].contains (valueOf record "completion_mode")
private def callId (record : Term) : Term :=
  (record.get (b "tool_call_id")).default (record.get (a "tool_call_id"))

private def restartResult (id name : Term) : Term :=
  .map [(a "id", id), (a "name", name),
    (a "content", b "tool call did not complete (recovered after interruption)"),
    (a "error", a "true"), (a "status", b "error"), (a "error_class", b "runtime_restarted"),
    (a "error_message", b "tool call did not complete (recovered after interruption)"),
    (a "diagnostic_visibility", b "model_only"), (a "events", list [])]

private def failureReason (record : Term) : String :=
  if callback record then "capability_request_inactive" else "runtime_restarted"

private def failRunning (ctx record : Term) : Term := Id.run do
  let result := restartResult (callId record) (record.get (b "tool_name"))
  let result := if callback record then
    let message := b "external capability request expired or is no longer pending"
    result.put (a "error_class") (b (failureReason record))
      |>.put (a "error_message") message |>.put (a "content") message
    else result
  let ctx := addItems ctx "failed" [record]
  let ctx := if direct record then ctx else addItems ctx "policy_results" [result]
  return request "encode_failed" (.tuple [record, result, Term.bool (direct record)])
    (ctx.put (b "phase") (b "failed_encoded"))

private def queue (sid identity payload now : Term) : Term :=
  .map [(b "type", b "queue_append"), (b "session_id", sid), (b "kind", b "runtime_message"),
    (b "wake", a "true"), (b "dedupe_key", identity), (b "created_at", now),
    (b "payload", payload.put (b "runtime_message_id") identity)]

private def joinIds (values : List Term) : KernelM ByteArray := do
  let values ← values.mapM (fun value => do
    let .binary raw ← stringChars value | fail "badarg"
    pure raw)
  let mut output := ByteArray.empty
  let mut first := true
  for value in values do
    if !first then output := output.push 44
    output := output ++ value
    first := false
  return output

private def inherit (payload : Term) (sources : List Term) : Term := Id.run do
  let ids := RoundQuery.normalizeIds (list (sources.flatMap (fun source => wrap (valueOf source "trusted_origin_source_message_ids"))))
  let originsOf := fun source => match valueOf source "trusted_origins" with
    | .list (x :: xs) => (x :: xs).filter Term.isMap
    | _ => (wrap (valueOf source "trusted_origin")).filter Term.isMap
  let origins := uniq (sources.flatMap originsOf)
  if ids.isEmpty || origins.isEmpty then return payload
  let origin := ((sources.reverse.map (fun source => valueOf source "trusted_origin")).find? Term.truthy).getD nil
  let payload := payload.put (b "trusted_origins") (list origins)
    |>.put (b "trusted_origin_source_message_ids") (list ids)
  return if origin.isMap then payload.put (b "trusted_origin") origin else payload

private def finalPlan (state ctx : Term) : KernelM Term := do
  let sid ← field state "session_id"
  let .binary sidBytes := sid | fail "badarg"
  let active := (← field state "status") == a "active"
  let idle := Term.map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")]
  let now := i (integerValue (← observe (a "time")) / 1000)
  let missing := getList ctx "missing_events" ++ getList ctx "external_events"
  let repair := missing ++ (if !missing.isEmpty && active then [idle] else [])
  -- The runtime notification already owns a durable unknown/delivered receipt.
  -- Repair its missing tool result, but do not turn that repair into new model work.
  let notificationIds := (getList ctx "restarted").filterMap (fun call =>
    if ((call.get (a "source_call")).get (b "runtime_failure_reply")).isMap then some (call.get (a "id")) else none)
  let restarted := (getList ctx "restarted").filter (fun call => !notificationIds.contains (call.get (a "id")))
  let failedRefs := restarted.map (fun call => Term.map
    [(b "tool_call_id", call.get (a "id")), (b "reason", b "runtime_restarted")])
  let restartedIds ← joinIds (restarted.map (·.get (a "id")))
  let missingNotice := if restarted.isEmpty then [] else [queue sid
    (.binary ("runtime-recovered:missing-tool-results:".toUTF8 ++ sidBytes ++ ":".toUTF8 ++ restartedIds))
    (.map [(b "type", b "runtime_recovered"),
      (b "summary", b "agent session recovered after interruption; some tool calls did not complete"),
      (b "content", b "agent session recovered after interruption; listed tool calls were completed with failure results and were not automatically retried"),
      (b "diagnostic_visibility", b "model_only"), (b "failed_tool_calls", list failedRefs),
      (b "source_refs", .map [(b "failed_tool_calls", list failedRefs)])]) now]
  let external := getList ctx "external"
  let pendingRefs := external.map (fun call => Term.map [(b "tool_call_id", call.get (a "id")),
    (b "tool_name", call.get (a "name")), (b "reason", b "external_callback_pending")])
  let externalIds ← joinIds (← sorted (external.map (·.get (a "id"))))
  let externalNotice := if !active || external.isEmpty then [] else [queue sid
    (.binary ("runtime-recovered:external-callback-missing:".toUTF8 ++ sidBytes ++ ":".toUTF8 ++ externalIds))
    (.map [(b "type", b "runtime_recovered"),
      (b "summary", b "agent session recovered after restart; external callback tool calls are still pending"),
      (b "content", b "agent session recovered after interruption; listed external callback tool calls are still waiting for external completion"),
      (b "pending_external_callback_tool_calls", list pendingRefs),
      (b "source_refs", .map [(b "pending_external_callback_tool_calls", list pendingRefs)])]) now]
  let running := (getList ctx "failed").filter (fun record => !direct record)
  let pending := (getList ctx "pending").filter (fun record => !direct record)
  let asyncEvents : List Term ← if running.isEmpty && (pending.isEmpty || !active) then pure [] else do
    let refs := fun (records : List Term) reason => records.map (fun record => Term.map
      [(b "tool_call_id", callId record), (b "tool_name", record.get (b "tool_name")),
        (b "reason", b (if reason == "runtime_restarted" then failureReason record else reason))])
    let failed := list (refs running "runtime_restarted")
    let external := list (refs pending "external_callback_pending")
    let summary := if running.isEmpty then "agent session recovered after restart; external callback tool calls are still pending"
      else if pending.isEmpty then "agent session recovered after restart; some async tool calls failed"
      else "agent session recovered after restart; some async tool calls failed and external callback tool calls are still pending"
    let content := if running.isEmpty then "agent session recovered after restart; listed external callback tool calls are still waiting for external completion"
      else if pending.isEmpty then "agent session recovered after restart; listed async tool calls failed and were not automatically retried"
      else "agent session recovered after restart; listed async tool calls failed and were not automatically retried; listed external callback tool calls are still waiting for external completion"
    let payload := Term.map [(b "type", b "runtime_recovered"), (b "summary", b summary), (b "content", b content),
      (b "failed_tool_calls", failed), (b "pending_external_callback_tool_calls", external),
      (b "source_refs", .map [(b "failed_tool_calls", failed), (b "pending_external_callback_tool_calls", external)])]
    let payload := if running.isEmpty then payload else payload.put (b "diagnostic_visibility") (b "model_only")
    let ids := fun (records : List Term) => sorted ((records.map callId).filter (· != nil))
    let identity := "runtime-recovered:async:".toUTF8 ++ sidBytes ++ ":failed:".toUTF8 ++ (← joinIds (← ids running)) ++
      ":pending:".toUTF8 ++ (← joinIds (← ids pending))
    pure ((if active && missing.isEmpty then [idle] else []) ++ [queue sid (.binary identity) (inherit payload (running ++ pending)) now])
  let scan := ctx.get (b "scan")
  let llmEvents : List Term ← if !active || !pending.isEmpty || (scan.get (b "visible_reply_intent?")).truthy ||
      !(wrap (scan.get (b "missing_calls"))).isEmpty ||
      !((wrap (scan.get (b "running_async"))).filter (fun record => !direct record)).isEmpty then pure [] else do
    if ctx.get (b "recovery") == a "resume_stable_input" || scan.get (b "last_message_role") == b "tool" then pure [idle]
    else do
      let last := (scan.get (b "last_message_id")).default (ctx.get (b "next_id"))
      let identity := "runtime-recovered:llm:".toUTF8 ++ sidBytes ++ ":message-".toUTF8 ++ (← joinIds [last])
      pure [idle, queue sid (.binary identity) (.map [(b "type", b "runtime_recovered"),
        (b "summary", b "agent session recovered after an in-flight LLM call failed"),
        (b "content", b "agent session recovered after restart; the in-flight LLM call failed and was not automatically retried"),
        (b "diagnostic_visibility", b "user_reportable"),
        (b "public_summary", b "The previous response was interrupted. Please try again."),
        (b "failed_llm_call", .map [(b "reason", b "runtime_restarted")]),
        (b "source_refs", .map [(b "failed_llm_call", .map [(b "reason", b "runtime_restarted")])])]) now]
  let recoveredIdle := if active && ((ctx.get (b "agent_recovered")).truthy ||
      (ctx.get (b "capability_unavailable")).truthy) &&
    !(repair ++ asyncEvents).any (fun event => event.get (b "type") == b "status" && event.get (b "status") == b "idle") then [idle] else []
  let events := repair ++ missingNotice ++ externalNotice ++ getList ctx "recovered_events" ++ recoveredIdle ++
    getList ctx "failure_events" ++ getList ctx "capability_events" ++ asyncEvents ++ llmEvents
  let nextId := ctx.get (b "next_id")
  let events := events.map (fun event =>
    if event.get (b "type") == b "tool_result" && notificationIds.contains (event.get (b "tool_call_id")) then
      event.put (b "no_wake") (a "true") else event)
  let results := (getList ctx "policy_results").filter (fun result => !notificationIds.contains (valueOf result "id"))
  let events ← Presentation.recoveredCompletion state
    (.tuple [list events, list results, i (max 0 (integerValue nextId - 1))])
  return done (.tuple [events, nextId])

private def next (state ctx : Term) : KernelM Term := do
  match getList ctx "missing" with
  | call :: rest =>
    return request "capability" (.map [(b "tool_call_id", call.get (a "id")),
      (b "tool_name", call.get (a "name")), (b "input", call.get (a "args")),
      (b "status", b "running"), (b "completion_mode", b "external_callback")])
      (ctx.put (b "missing") (list rest) |>.put (b "current") call |>.put (b "phase") (b "missing_pending"))
  | [] => pure ()
  match getList ctx "external_todo" with
  | call :: rest =>
    return request "encode_external" (.tuple [call, ctx.get (b "next_id"), call.get (b "capability_record")])
      (ctx.put (b "external_todo") (list rest) |>.put (b "phase") (b "external_encoded"))
  | [] => pure ()
  match getList ctx "running" with
  | record :: rest =>
    let ctx := ctx.put (b "running") (list rest) |>.put (b "current") record |>.put (b "phase") (b "running_pending")
    return request "capability" record ctx
  | [] => finalPlan state ctx

def start (state args : Term) : KernelM Term := do
  let .tuple [live, recovery] := args | fail "function_clause"
  let scan ← RepairQuery.repairScan state
  let ctx := Term.map [(b "scan", scan), (b "missing", scan.get (b "missing_calls")),
    (b "running", list ((wrap (scan.get (b "running_async"))).filter (fun record =>
      callback record || !((wrap live).contains (callId record))))), (b "live", live), (b "recovery", recovery),
    (b "next_id", (← field state "next_message_id").default (i 1)), (b "policy_results", list [])]
  next state ctx

private def resumeCapability (state ctx observation : Term) : KernelM Term := do
  let current := ctx.get (b "current")
  let kind := observation.get (b "state")
  let ctx := addItems ctx "capability_events" (wrap (observation.get (b "events")))
  if kind == b "settled" || terminal current then return ← next state ctx
  let record := (observation.get (b "record")).default current
  let ctx := ctx.put (b "current") record
  if kind == b "unavailable" then return ← next state (ctx.put (b "capability_unavailable") (a "true"))
  if kind == b "pending" then return ← next state (addItems ctx "pending" [record])
  if kind == b "terminal" || kind == b "unknown" then
    let result ← Presentation.label (observation.get (b "result"))
    let ctx := ctx.put (b "result") result
    return request "encode_recovered" (.tuple [record, result]) (ctx.put (b "phase") (b "recovered_encoded"))
  -- Absence is authoritative; a staged callback handoff cannot recreate a request.
  if callback record then return failRunning ctx record
  return request "staged_result" record (ctx.put (b "phase") (b "staged"))

def resume (state args : Term) : KernelM Term := do
  let .tuple [ctx, observation] := args | fail "function_clause"
  let phase := ctx.get (b "phase")
  let current := ctx.get (b "current")
  if phase == b "missing_pending" then
    if observation.get (b "state") == b "absent" then
      return request "guidance" current (ctx.put (b "phase") (b "guidance"))
    let record := observation.get (b "record")
    let call := current.put (b "capability_record") record
    -- Materialize the durable assistant dispatch before recovering its request result.
    let ctx := ctx.put (b "current") call |>.put (b "capability_observation") observation
    return request "encode_external" (.tuple [call, ctx.get (b "next_id"), record])
      (ctx.put (b "phase") (b "missing_capability_encoded"))
  if phase == b "missing_capability_encoded" then
    let ctx := (addItems ctx "external_events" (wrap observation)).put (b "next_id")
      (← add (ctx.get (b "next_id")) (i 1))
    let record := (ctx.get (b "capability_observation")).get (b "record")
    return ← resumeCapability state (ctx.put (b "current") record)
      (ctx.get (b "capability_observation"))
  if phase == b "guidance" then
    let (result, restarted) := match observation with
      | .tuple [.atom "ok", result] => (result, false)
      | .atom "not_recoverable" => (restartResult (current.get (a "id")) (current.get (a "name")), true)
      | _ => (nil, false)
    if result == nil then fail "invalid_observation"
    let result ← Presentation.label result
    let ctx := addItems ctx "policy_results" [result]
    let ctx := if restarted then addItems ctx "restarted" [current] else ctx
    return request "encode_missing" (.tuple [ctx.get (b "next_id"), result]) (ctx.put (b "phase") (b "missing_encoded"))
  if phase == b "missing_encoded" || phase == b "external_encoded" then
    let key := if phase == b "missing_encoded" then "missing_events" else "external_events"
    let events := if phase == b "missing_encoded" then [observation] else wrap observation
    return ← next state ((addItems ctx key events).put (b "next_id") (← add (ctx.get (b "next_id")) (i 1)))
  if phase == b "running_pending" then return ← resumeCapability state ctx observation
  if phase == b "staged" then
    match observation with
    | .tuple [.atom "ok", result] =>
      let result ← Presentation.label result
      let ctx := ctx.put (b "result") result
      return request "encode_recovered" (.tuple [current, result]) (ctx.put (b "phase") (b "recovered_encoded"))
    | .tuple [.atom "error", .atom "not_found"] =>
      return failRunning ctx current
    | .tuple [.atom "error", reason] =>
      return done (.tuple [a "error", .tuple [a "staged_async_result_read_failed", callId current, reason]])
    | _ => fail "invalid_observation"
  if phase == b "recovered_encoded" then
    let .tuple [events, handoff] := observation | fail "invalid_observation"
    if callback current && handoff.truthy then return failRunning ctx current
    let ctx := addItems ctx "recovered_events" (wrap events)
    let ctx := if direct current then ctx else ctx.put (b "agent_recovered") (a "true")
    let ctx := if direct current || handoff.truthy then ctx else addItems ctx "policy_results" [ctx.get (b "result")]
    return ← next state ctx
  if phase == b "failed_encoded" then return ← next state (addItems ctx "failure_events" (wrap observation))
  fail "invalid_observation"

def table : OpTable := [("restart_plan", start), ("resume_restart", resume)]
end VerifiedKernel.Session.Restart
