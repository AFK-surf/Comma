import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.Settlement
import VerifiedKernel.Session.Command
import VerifiedKernel.Session.Request
import VerifiedKernel.Session.Query.Round
import VerifiedKernel.Session.Replies
import VerifiedKernel.AgentLoop.ToolSideEffects
import VerifiedKernel.AgentLoop.CallEnvelope
import VerifiedKernel.AgentLoop.TerminalReply

/-! # Loop host data

The agent loop asks its host for transcript data at three points: the record
of a provider response (`build_record`), the events of a tool batch
(`store_results`), and the operations of a tool call (`run_tools`). These
queries build that data, so a host answers each effect with one query and its
own I/O facts: the trace ids, the tool results, and the model metadata.

The loop itself does not call these queries. Its proofs treat the answers as
host data, with the same admission checks as before. -/

namespace VerifiedKernel.Session.LoopHost
open Data
open RoundQuery (valueOf atomFirst textKey atomKey)

/-- Elixir `left || right`. -/
private def orElse (left right : Term) : Term := left.default right

private def seconds : KernelM Term := do
  return i (integerValue (← observe (a "time")) / 1000)

private def compact (pairs : List (Term × Term)) : Term :=
  .map (pairs.filter (fun pair => pair.2 != nil))

/-! ## Tool-result events (`Round.tool_events/3`) -/

/-- `ExecutionTiming.from_tool/1`: the observed interval of one tool result. -/
def executionTiming (result : Term) : Term :=
  let status := atomFirst result "status"
  let terminal := [b "completed", b "success", b "error", b "failed", b "cancelled", b "canceled"].contains status
  match atomFirst result "started_at", atomFirst result "duration_ms" with
  | .integer started, .integer duration =>
    if started ≥ 1000000000000 && duration ≥ 0 then
      .map [(b "version", i 1), (b "started_at_ms", i started), (b "observed_at_ms", i (started + duration)),
        (b "duration_ms", i duration), (b "completed_at_ms", if terminal then i (started + duration) else nil)]
    else nil
  | _, _ => nil

/-- `Round.tool_result_event/4`: the transcript event of one tool result. -/
def toolResultEvent (sessionId trace result id : Term) : KernelM Term := do
  let content := atomFirst result "content"
  let output := atomFirst result "output"
  let timing := executionTiming result
  let stamp (key : String) : Term := if timing == nil then nil else timing.get (b key)
  return .map [(b "type", b "tool_result"), (b "session_id", sessionId), (b "message_id", id),
    (b "tool_call_id", atomFirst result "id"), (b "tool_name", atomFirst result "name"),
    (b "content", content), (b "error", orElse (atomFirst result "error") (a "false")),
    (b "status", atomFirst result "status"), (b "duration_ms", atomFirst result "duration_ms"),
    (b "input", atomFirst result "input"), (b "output", if output == content then nil else output),
    (b "error_class", atomFirst result "error_class"), (b "error_message", atomFirst result "error_message"),
    (b "guidance_reason", atomFirst result "guidance_reason"),
    (b "diagnostic_visibility", atomFirst result "diagnostic_visibility"),
    (b "public_summary", atomFirst result "public_summary"), (b "repair_outcome", atomFirst result "repair_outcome"),
    (b "visible_reply_origin", atomFirst result "visible_reply_origin"),
    (b "turn_id", atomFirst trace "turn_id"), (b "round_id", atomFirst trace "round_id"),
    (b "request_id", atomFirst trace "request_id"), (b "trace_id", atomFirst trace "trace_id"),
    (b "execution_timing", timing), (b "started_at", stamp "started_at_ms"),
    (b "completed_at", stamp "completed_at_ms"), (b "ifc", atomFirst result "ifc"),
    (b "created_at", ← seconds)]

private def eventMessageId (event : Term) : Term :=
  let id := textKey event "message_id"
  if id.isInteger then id else
    let id := atomKey event "message_id"
    if id.isInteger then id else nil

private def waitSetEvent (event : Term) : Bool :=
  textKey event "type" == b "wait_set" || atomKey event "type" == b "wait_set"

/-! ## Provider reply obligations (`ProviderReplyObligation`) -/

private def taskCreate : Term := b "im_api.internal.task.create"
private def cardOperation : Term := b "im_api.slack.post_task_card"
private def slackVisible : List Term := [b "im_api.slack.post_message", b "im_api.slack.reply_message",
  b "im_api.slack.post_channel_message", b "im_api.slack.upload_file", cardOperation,
  b "im_api.slack.bind_thread_to_task"]

/-- `ProviderReplyObligation.value/2`: the string key, else the atom key. -/
private def ov (value : Term) (key : String) : Term :=
  if value.isMap then orElse (value.get (b key)) (value.get (a key)) else nil

private def successfulTerminal (result : Term) : Bool :=
  ov result "error" != a "true" && ov result "status" == b "completed" &&
    [nil, b ""].contains (ov result "guidance_reason")

private def decodeParams (params : Term) : KernelM Term := do
  if params.isMap then return ← stringify params
  match params with
  | .binary raw =>
    match Json.decode raw with
    | some decoded => return if decoded.isMap then decoded else nil
    | none => return nil
  | _ => return nil

/-- `operation_and_params/2`: the recorded call first, then the result. -/
private def operationAndParams (result fallback : Term) : KernelM (Term × Term) := do
  for candidate in [fallback, ov fallback "call", result] do
    if candidate.isMap then
      let operation := orElse (ov candidate "name") (orElse (ov candidate "tool_name") (b ""))
      let params ← decodeParams (orElse (ov candidate "input") (ov candidate "args"))
      if operation != b "" && params.isMap then
        return (← stringChars operation, params)
  return (b "", empty)

private def decodedContent (result : Term) : Term :=
  match ov result "content" with
  | .binary raw => (Json.decode raw).getD nil
  | _ => nil

/-- The card target that `TaskCard` authored after an authorized dispatch. -/
private def automaticCardTarget (result : Term) : Term :=
  let content := decodedContent result
  let id := textKey content "conversation_id"
  let card := textKey content "task_card"
  let target := textKey card "target"
  if content.isMap && textKey content "created" == a "true" && id != nil && card.isMap &&
      [b "queued", b "delivered"].contains (textKey card "status") && target.isMap &&
      textKey target "conversation_id" == id then target
  else nil

private def resolved (sessionId key : Term) : Term :=
  .map [(b "type", b "provider_reply_obligation_resolved"), (b "session_id", sessionId), (b "obligation_key", key)]

private def replyResolutions (sessionId operation params : Term) : KernelM (List Term) := do
  if !slackVisible.contains operation then return []
  let target ← normalizeObligation (.map [(b "provider", b "slack"), (b "connect_id", ov params "connect_id"),
    (b "channel", ov params "channel"), (b "thread_ts", ov params "thread_ts")])
  return if target.isMap then [resolved sessionId (target.get (b "key"))] else []

private def cardResolutions (sessionId operation params : Term) : KernelM (List Term) := do
  if operation != cardOperation then return []
  let target ← normalizeObligation (.map [(b "provider", b "slack"), (b "kind", b "task_card"),
    (b "conversation_id", ov params "conversation_id")])
  return if target.isMap then [resolved sessionId (target.get (b "key"))] else []

/-- `ProviderReplyObligation.resolution_events/3`. -/
def resolutionEvents (sessionId result fallback : Term) : KernelM (List Term) := do
  if !result.isMap || !successfulTerminal result then return []
  let (operation, params) ← operationAndParams result fallback
  if operation == b "" then return []
  let automatic ← if operation == taskCreate then
      let target := automaticCardTarget result
      if target.isMap then
        pure ((← replyResolutions sessionId cardOperation target) ++ (← cardResolutions sessionId cardOperation target))
      else pure []
    else pure []
  return (← replyResolutions sessionId operation params) ++ (← cardResolutions sessionId operation params) ++ automatic

/-- `ProviderReplyObligation.card_obligation_events/3`: the candidate card
obligation of a successful Task creation. -/
def cardObligationEvents (sessionId result fallback : Term) : KernelM (List Term) := do
  if !result.isMap || !successfulTerminal result then return []
  let (operation, params) ← operationAndParams result fallback
  if operation != taskCreate || ov params "triage_delegation_ref" != nil then return []
  if (automaticCardTarget result).isMap then return []
  let content := decodedContent result
  let conversation := match textKey content "conversation_id" with
    | .binary raw => .binary (trim raw)
    | _ => b ""
  if conversation == b "" then return []
  let limit ← observe (.tuple [a "config", a "salix_agent", a "session_input_queue_limit", i 1000])
  return [.map [(b "type", b "provider_card_obligation_added"), (b "session_id", sessionId),
    (b "conversation_id", conversation), (b "limit", limit)]]

/-- `{:ok, events, hwm}` or the side-effect validation error. `pending`
carries the presentation `checkpoint`, and `label` when the results still need
their visible-reply labels (`VisibleReplyPolicy.label_results/1`). -/
def toolBatchEvents (state args : Term) : KernelM Term := do
  let .tuple [pending, results, trace] := args | fail "function_clause"
  let results ← if RoundQuery.textKey pending "label" == a "true" then
      Presentation.policy (.tuple [a "label_results", results])
    else pure results
  let sessionId ← field state "session_id"
  let first ← field state "next_message_id"
  let mut id := integerValue first
  let mut hwm := id - 1
  let mut wait := false
  let mut events : List Term := []
  for result in ← asList results do
    let event ← toolResultEvent sessionId trace result (i id)
    hwm := max hwm id
    id := id + 1
    let mut extra : List Term := []
    for sideEvent in wrap (orElse (atomFirst result "events") (list [])) do
      let explicit := eventMessageId sideEvent
      if explicit == nil then
        let checked := VerifiedKernel.AgentLoop.ToolSideEffects.events (list [sideEvent])
        if checked != a "ok" then return checked
      else hwm := max hwm (integerValue explicit)
      extra := extra ++ [sideEvent]
    wait := wait || extra.any waitSetEvent
    let obligations := (← resolutionEvents sessionId result nil) ++ (← cardObligationEvents sessionId result nil)
    events := events ++ [event] ++ extra ++ obligations
  Presentation.finishToolBatch state
    (.tuple [list events, i hwm, Term.bool wait, RoundQuery.textKey pending "checkpoint", results])

/-- `{resolutions, card obligations}` of one settled result, for an async
completion whose durable call record names the operation. -/
def resultObligationEvents (state args : Term) : KernelM Term := do
  let .tuple [result, fallback] := args | fail "function_clause"
  let sessionId ← field state "session_id"
  return .tuple [list (← resolutionEvents sessionId result fallback),
    list (← cardObligationEvents sessionId result fallback)]

/-! ## Records (`Round.build_record/2`) -/

/-- Keys in Erlang term order, as `Jason.encode!/1` writes a map of at most 32
keys. A larger map keeps its order. -/
partial def jasonOrder (value : Term) : KernelM Term := do
  match value with
  | .map pairs =>
    let pairs ← pairs.mapM (fun (k, v) => do return (k, ← jasonOrder v))
    if pairs.length > 32 then return .map pairs
    let keys ← sorted (pairs.map Prod.fst)
    return .map (keys.filterMap (fun k => (pairs.find? (·.1 == k))))
  | .list items => return .list (← items.mapM jasonOrder)
  | other => return other

/-- `Jason.encode!/1`. -/
def jason (value : Term) : KernelM Term := do
  let some bytes ← Json.encode (← jasonOrder value) | fail "invalid_term"
  return .binary bytes

/-- `Round.int_value/1`. -/
private def intValue : Term → Term
  | .integer n => i n
  | .floatBits bits =>
    match (Term.floatBits bits).number with
    | some (value, denominator) =>
      let magnitude := Int.ofNat (value.natAbs / denominator)
      i (if value < 0 then -magnitude else magnitude)
    | none => nil
  | .binary raw =>
    let chars := (String.fromUTF8? raw).getD "" |>.toList
    let (negative, rest) := match chars with
      | '-' :: rest => (true, rest)
      | '+' :: rest => (false, rest)
      | rest => (false, rest)
    let digits := rest.takeWhile Char.isDigit
    if digits.isEmpty then nil else
      let n := Int.ofNat (String.ofList digits).toNat!
      i (if negative then -n else n)
  | _ => nil

/-- `Round.normalize_usage/1`. -/
private def normalizeUsage (usage : Term) : Term :=
  if !usage.isMap then empty else
  let pick (keys : List Term) : Term := keys.foldl (fun found key => orElse found (usage.get key)) nil
  .map [(b "prompt_tokens", intValue (pick [b "prompt_tokens", a "prompt_tokens", b "input_tokens", a "input_tokens"])),
    (b "completion_tokens", intValue (pick [b "completion_tokens", a "completion_tokens", b "output_tokens", a "output_tokens"])),
    (b "cache_read_input_tokens", intValue (pick [b "cache_read_input_tokens", a "cache_read_input_tokens"])),
    (b "cache_write_input_tokens", intValue (pick [b "cache_write_input_tokens", a "cache_write_input_tokens"]))]

/-- `trace_meta["key"] || trace_meta[:key]`. -/
private def metaField (value : Term) (key : String) : Term :=
  if value.isMap then orElse (value.get (b key)) (value.get (a key)) else nil

private def normalizeCall (call : Term) : Term :=
  .map [(b "id", atomFirst call "id"), (b "name", atomFirst call "name"),
    (b "args", orElse (atomFirst call "args") empty)]

/-- `Round.assistant_event/8` with the request generation, adopted provider
states and provider meta of `assistant_commit_events/6`. -/
private def assistantEvent (state spec facts id calls providerMeta : Term) : KernelM Term := do
  let traceMeta := RoundQuery.textKey spec "trace_meta"
  let trace := RoundQuery.textKey facts "trace"
  let usage := normalizeUsage (metaField traceMeta "usage")
  let phase ← Presentation.policy (.tuple [a "event_phase", RoundQuery.textKey spec "vphase"])
  let llmError := metaField traceMeta "llm_error"
  let base := compact [(b "type", b "assistant"), (b "session_id", ← field state "session_id"),
    (b "message_id", id), (b "content", RoundQuery.textKey spec "content"),
    (b "tool_calls", list ((wrap calls).map normalizeCall)),
    (b "model", orElse (metaField traceMeta "model") (RoundQuery.textKey facts "model")),
    (b "input_tokens", usage.get (b "prompt_tokens")), (b "output_tokens", usage.get (b "completion_tokens")),
    (b "cache_read_input_tokens", usage.get (b "cache_read_input_tokens")),
    (b "cache_write_input_tokens", usage.get (b "cache_write_input_tokens")),
    (b "turn_id", atomFirst trace "turn_id"), (b "round_id", atomFirst trace "round_id"),
    (b "request_id", atomFirst trace "request_id"), (b "trace_id", atomFirst trace "trace_id"),
    (b "visible_reply_phase", phase), (b "created_at", ← seconds),
    (b "execution_timing", atomKey trace "execution_timing"),
    (b "provider_meta", if llmError.isMap then .map [(b "llm_error", llmError)] else nil)]
  let event := ((base.put (b "request_summary_sequence") (atomFirst trace "request_summary_sequence")).put
    (b "request_compacted_through") (atomFirst trace "request_compacted_through")).put
    (b "request_input_through") (atomFirst trace "request_input_through")
  let states := RoundQuery.textKey facts "provider_states"
  let event := match states with
    | .map (_ :: _) => event.put (b "do_not_send_to_llm") (.map [(b "context_provider_states", states)])
    | _ => event
  return if providerMeta.truthy then event.put (b "provider_meta") providerMeta else event

/-- `ContextProviders.activation_commit_events/3`: the activation's runtime
messages at consecutive ids from `first`. -/
private def activationEvents (state facts : Term) (first : Int) : KernelM (List Term) := do
  let sessionId ← field state "session_id"
  let now ← seconds
  let mut id := first
  let mut events := []
  for payload in wrap (RoundQuery.textKey facts "leading") do
    let created := orElse (RoundQuery.textKey payload "created_at") now
    let event := (((((← stringify payload).put (b "type") (b "runtime_message")).put (b "session_id") sessionId).put
      (b "from_context_provider") (a "true")).put (b "message_id") (i id)).put (b "no_wake") (a "true")
    events := events ++ [event.put (b "created_at") created]
    id := id + 1
  return events

/-- `Round.scheduled_task_failure_provider_meta/2`: replaced calls adopt the
canonical function calls, and a dropped call records that it did not settle. -/
private def replacedCallsMeta (providerMeta calls : Term) : KernelM Term := do
  let items := RoundQuery.textKey providerMeta "responses_items"
  let .list (first :: rest) := items | return providerMeta
  let items := first :: rest
  let calls := wrap calls
  let canonical ← calls.mapM (fun call => do
    return (atomKey call "id", Term.map [(b "type", b "function_call"), (b "call_id", atomKey call "id"),
      (b "name", atomKey call "name"), (b "arguments", ← jason (atomKey call "args"))]))
  let originals := (items.filter (fun item => RoundQuery.textKey item "type" == b "function_call")).map
    (fun item => RoundQuery.textKey item "call_id")
  let notSettled ← jason (.map [(b "status", b "not_settled"), (b "reason", b "repair_required")])
  let mut out := []
  for item in items do
    let id := RoundQuery.textKey item "call_id"
    let kind := RoundQuery.textKey item "type"
    if kind == b "function_call" then
      match canonical.find? (·.1 == id) with
      | some (_, adopted) => out := out ++ [← merge item adopted]
      | none => out := out ++ [item, .map [(b "type", b "function_call_output"), (b "call_id", id),
          (b "output", notSettled)]]
    else if kind == b "function_call_output" then
      if !originals.contains id then out := out ++ [item]
    else out := out ++ [item]
  let missing := (canonical.filter (fun (id, _) => !originals.contains id)).map Prod.snd
  return providerMeta.put (b "responses_items") (list (out ++ missing))

/-- `Round.complete_terminal_provider_context/3`: the settled `end_turn` call
gets its output item. -/
private def terminalProviderMeta (providerMeta call result : Term) : KernelM Term := do
  let items := RoundQuery.textKey providerMeta "responses_items"
  if !items.isList then return providerMeta
  let callId ← stringChars (orElse (atomFirst call "id") (b ""))
  let output := Term.map [(b "type", b "function_call_output"), (b "call_id", callId),
    (b "output", ← jason result)]
  let items := (wrap items).flatMap (fun item =>
    if item.isMap && RoundQuery.textKey item "type" == b "function_call" &&
        RoundQuery.textKey item "call_id" == callId then [item, output] else [item])
  return providerMeta.put (b "responses_items") (list items)

/-- `ActivityEvent.tool_calls_phase/1`: messaging when every call sends. A
call name counts after trimming, as `ActivityEvent.present/1` reads it. -/
private def activityPhase (calls : Term) : KernelM Term := do
  let send := b "im_api.internal.send_message"
  let reply (call : Term) : KernelM Bool := do
    let name := match atomFirst call "name" with
      | .binary raw => .binary (trim raw)
      | _ => nil
    if name == send then return true
    if name != b "call" then return false
    let tool := atomFirst (orElse (atomFirst call "args") empty) "tool"
    return (← stringChars (orElse tool (b ""))) == send
  let replies ← (wrap calls).mapM reply
  return if replies.all id then b "messaging" else b "execution"

/-- The terminal-reply scope of this round (`TerminalReply.context/4`), from
the round's role, Router fact and source ids. -/
def roundScope (state facts aid count : Term) : KernelM Term := do
  let sources := RoundQuery.textKey facts "source_ids"
  let .tuple [source, origin] ← RoundQuery.currentTurnSource state (list (wrap sources)) | fail "function_clause"
  let role := RoundQuery.textKey facts "role"
  Settlement.replyContext state (.map [(b "role", role),
    (b "router_authority", Term.bool (role == b "router" && (RoundQuery.textKey facts "canonical_router").truthy)),
    (b "agent_id", ← field state "agent_id"), (b "trusted_origin", origin), (b "source_message_id", source),
    (b "source_message_ids", list (wrap sources)), (b "assistant_id", aid), (b "call_count", count)])

/-- The record for a `build_record` spec. `facts` carries `leading` (the
activation's runtime payloads), `trace`, `model`, `provider_states`,
`ifc_label`, `role`, `canonical_router` and `source_ids`. A tool record comes
with its terminal-reply scope and no planned admission. -/
def loopRecord (state args : Term) : KernelM Term := do
  let .tuple [spec, facts] := args | fail "function_clause"
  let first := integerValue (← field state "next_message_id")
  let leading ← activationEvents state facts first
  let aid := i (first + leading.length)
  let calls := RoundQuery.textKey spec "calls"
  let providerMeta := RoundQuery.textKey spec "provider_meta"
  let providerMeta ← if (RoundQuery.textKey spec "replaced_calls").truthy then replacedCallsMeta providerMeta calls
    else pure providerMeta
  if RoundQuery.textKey spec "mode" == b "final" then
    let terminal := RoundQuery.textKey spec "terminal_call"
    let providerMeta ← if terminal.truthy then
        terminalProviderMeta providerMeta terminal (RoundQuery.textKey spec "terminal_result")
      else pure providerMeta
    let assistant ← assistantEvent state spec facts aid (list []) providerMeta
    return .map [(b "record", .map [(b "leading", list leading), (b "assistant", assistant), (b "aid", aid),
      (b "base", i first)])]
  let recorded := orElse (RoundQuery.textKey spec "record_calls") calls
  let assistant ← assistantEvent state spec facts aid recorded providerMeta
  let label := RoundQuery.textKey facts "ifc_label"
  let assistant := if label == nil then assistant else assistant.put (b "ifc") (.map [(b "label", label)])
  let activity := Term.map [(b "type", b "activity_status"), (b "session_id", ← field state "session_id"),
    (b "activity_status", ← activityPhase calls)]
  let scope ← roundScope state facts aid (i (wrap calls).length)
  return .map [(b "record", .map [(b "intent", list (leading ++ [assistant, activity])), (b "aid", aid),
    (b "base", i first), (b "admission", nil), (b "speculative", a "false")]), (b "scope", scope)]

/-- The runtime failure notice's scope: the stored source scope and the
current source ids, as the loop's `guardNotice` authorized it. -/
def noticeScope (state args : Term) : KernelM Term := do
  let .tuple [aid, role, router] := args | fail "function_clause"
  let scope ← RoundQuery.sourceScope state
  Settlement.replyContext state (.map [(b "role", role),
    (b "router_authority", Term.bool (role == b "router" && router.truthy)),
    (b "agent_id", ← field state "agent_id"), (b "trusted_origin", RoundQuery.textKey scope "trusted_origin"),
    (b "source_message_id", RoundQuery.textKey scope "source_message_id"),
    (b "source_message_ids", ← RoundQuery.currentSourceIds state), (b "assistant_id", aid), (b "call_count", i 1)])

/-! ## Call envelopes (`Tools.prepare_for_dispatch/2`) -/

private def envelopeMisuse : String :=
  "internal LLM sessions must call capability tools through the call envelope"

private def nameOf (call : Term) : Term := orElse (call.get (a "name")) (call.get (b "name"))
private def argsOf (call : Term) : Term := orElse (orElse (call.get (a "args")) (call.get (b "args"))) empty

private def text (value : Term) : KernelM Term := do
  if value == nil then return b ""
  stringChars value

/-- A call that already carries envelope guidance. -/
private def guidanceCall (call : Term) : Bool :=
  let args := argsOf call
  call.has (a "guidance_error") || call.has (b "guidance_error") ||
    (args.isMap && (args.has (b "_guidance_error") || args.has (a "_guidance_error")))

/-- The call turned into guidance: the host reports `reason` to the model
instead of running it. An enveloped runtime keeps the `call` pseudo-tool. -/
private def guide (call reason target : Term) (envelope : Bool) (kind : String) : KernelM Term := do
  let target ← if envelope then pure target else text (orElse target (nameOf call))
  let name := if envelope then b "call" else target
  let call : Term := match call with
    | .map xs => Term.map (xs.filter (fun pair => pair.1 != a "reply_intent"))
    | other => other
  return call.put (a "name") name |>.put (b "name") name |>.put (a "guidance_error") reason
    |>.put (a "guidance_tool") (← text target) |>.put (a "guidance_reason") (b kind)

/-- One call through the envelope: a direct call of a capability tool, or a
`call` that targets `wait_for`, becomes guidance; a `call` becomes its target
with the target's arguments, reply intent and IFC declaration. -/
private def envelopeCall (envelope : Bool) (call : Term) : KernelM Term := do
  let name ← text (nameOf call)
  let call ← if envelope then
      if name == b "call" || name == b "wait_for" then pure call
      else guide call (b envelopeMisuse) name true "envelope_misuse"
    else if name == b "call" then
      guide call (b "non-LLM runtimes must call tools by canonical name, not through the call envelope")
        (b "call") false "envelope_misuse"
    else pure call
  if nameOf call != b "call" || guidanceCall call then return call
  match ← VerifiedKernel.AgentLoop.CallEnvelope.decode (argsOf call) with
  | .tuple [.atom "ok", target, params, ifc, intent] =>
    if target == b "wait_for" then
      return ← guide call (b "wait_for is a direct internal session control; call wait_for directly instead of using the call envelope")
        (b "wait_for") envelope "envelope_misuse"
    let call := call.put (a "reply_intent") intent |>.put (a "name") target |>.put (b "name") target
      |>.put (a "args") params |>.put (b "args") params
    return if ifc.isMap then call.put (a "ifc") ifc else call
  | .tuple [.atom "error", reason, target] => guide call reason target envelope "envelope_misuse"
  | _ => fail "function_clause"

/-- `call_envelopes {calls, llm_tool_envelope}`: each call through the
envelope. The host then checks its catalog and disclosure, and admits each
call with `terminal_reply_admission`. -/
def callEnvelopes (_state args : Term) : KernelM Term := do
  let .tuple [calls, envelope] := args | fail "function_clause"
  return list (← (wrap calls).mapM (envelopeCall (envelope == a "true")))

/-! ## The round request -/

/-- What a model round reads before its request: `{:ok, view}` with the
activation's `source_ids`, the current turn's `source_message_id` and
`trusted_origin`, the visible-reply `scope`, `phase`, `guard` and `repair`,
and the `id_snapshot`. `{:error, reason}` when the visible-reply scope needs
authorization again. -/
def roundView (state : Term) : KernelM Term := do
  match ← Command.roundPresentation state with
  | .tuple [.atom "ok", scope, phase, guard, repair] =>
    let sources ← RoundQuery.currentSourceIds state
    let .tuple [source, origin] ← RoundQuery.currentTurnSource state sources | fail "function_clause"
    return .tuple [a "ok", .map [(b "source_ids", sources), (b "source_message_id", source),
      (b "trusted_origin", origin), (b "scope", scope), (b "phase", phase), (b "guard", guard),
      (b "repair", repair), (b "id_snapshot", ← field state "next_message_id")]]
  | other => return other

/-- The facts a round's loop entries carry, from the round configuration:
`role`, `canonical_router`, `restricted`, `guard_config`, and `nonce`. -/
def roundFacts (config sources snapshot guard phase : Term) : Term :=
  let key := RoundQuery.textKey config
  Term.map [(b "id_snapshot", snapshot), (b "guard", guard), (b "vphase", phase), (b "source_ids", sources),
    (b "restricted", Term.bool (key "restricted").truthy), (b "role", key "role"),
    (b "canonical_router", Term.bool (key "canonical_router").truthy),
    (b "guard_config", Term.bool (key "guard_config").truthy), (b "nonce", key "nonce")]

/-- The request generation of a round, captured before its request: the
summary sequence, the compaction boundary, and the last input id. The
record of the response carries it, so the compaction trigger reads usage of
this generation only. -/
def requestTrace (state : Term) : KernelM Term := do
  return Term.map [(b "request_summary_sequence", orElse (← field state "summary_sequence") (i 0)),
    (b "request_compacted_through", orElse (← field state "compacted_through") (i 0)),
    (b "request_input_through", ← sub (orElse (← field state "next_message_id") (i 1)) (i 1))]

/-- `round_facts {config, snapshot, guard}`: the facts of a loop entry outside
`round_request`, such as a failure before a request starts, with the request
generation of the current state (`trace`). `config` may add
`vphase` and `source_ids`; without them the phase is `:clean` and the sources
are the current ones. A `:current` snapshot is the next message id. -/
def roundFactsQuery (state args : Term) : KernelM Term := do
  let .tuple [config, snapshot, guard] := args | fail "function_clause"
  let key := RoundQuery.textKey config
  let sources ← if key "source_ids" == nil then RoundQuery.currentSourceIds state else pure (key "source_ids")
  let snapshot ← if snapshot == a "current" then field state "next_message_id" else pure snapshot
  return (roundFacts config sources snapshot guard (orElse (key "vphase") (a "clean"))).put (b "trace")
    (← requestTrace state)

/-- The facts of the loop's activation entry. The wait-extension ceiling is
`wait_for_extension_ceiling_seconds` from configuration, or the wait_for
maximum of 1,800 seconds. -/
def activationFacts : KernelM Term := do
  let configured ← observe (.tuple [a "config", a "salix_agent", a "wait_for_extension_ceiling_seconds", nil])
  let seconds := match configured with | .integer n => if n ≥ 0 then n else 1800 | _ => 1800
  return .map [(b "ceiling_ms", i (seconds * 1000))]

/-- One model round's entry. `config` carries the host's `role`,
`canonical_router`, `restricted`, `guard_config` and `nonce`, and the
request's `delta`, `disclosure`, `protocol`, `cfg`, `tools` and `mode`.
A pending guard disposition enters `{:guard_notice, facts}`. Otherwise the
answer is `{:ok, request, facts}`: the provider request and the round facts
that `{:model_response, response, facts}` carries. `facts["trace"]` holds the
request generation that `loop_record` records on the response. -/
def roundRequest (state config : Term) : KernelM Term := do
  let key := RoundQuery.textKey config
  let role := key "role"
  let router := (key "canonical_router").truthy
  let base := roundFacts config
  if ← RoundQuery.guardDispositionPending state then
    return .tuple [a "guard_notice",
      (base (← RoundQuery.currentSourceIds state) nil nil nil).put (b "trace") (← requestTrace state)]
  let prefetched ← Request.prefetch state
  match ← roundView state with
  | .tuple [.atom "ok", view] =>
    let request ← Request.dispatch state (.tuple [key "delta", Term.bool (key "available").truthy,
      view.get (b "trusted_origin"), key "disclosure", Term.bool (role == b "router" && router), key "protocol",
      key "cfg", orElse (key "tools") (list []), orElse (key "mode") (b "complete")]) prefetched
    let phase := orElse (view.get (b "phase")) (a "clean")
    let facts := base (view.get (b "source_ids")) (view.get (b "id_snapshot"))
      (orElse (view.get (b "guard")) phase) phase
    return .tuple [a "ok", request, facts.put (b "trace") (← requestTrace state)]
  | other => return other

def table : OpTable :=
  [("tool_batch_events", toolBatchEvents), ("result_obligation_events", resultObligationEvents),
   ("loop_record", loopRecord), ("notice_reply_scope", noticeScope),
   ("call_envelopes", callEnvelopes), ("round_view", fun state _ => roundView state),
   ("round_request", roundRequest), ("round_facts", roundFactsQuery),
   ("activation_facts", fun _ _ => activationFacts)]

end VerifiedKernel.Session.LoopHost
