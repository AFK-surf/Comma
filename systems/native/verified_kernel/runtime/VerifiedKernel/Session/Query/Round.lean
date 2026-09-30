import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Query.StateCore
import VerifiedKernel.Session.Query.Reply

/-! Queries ported from SalixAgent.Round, InternalSessionActor, SessionToolExecution, TerminalReply, and AgentControl. See the README query catalog. -/

namespace VerifiedKernel.Session.RoundQuery
open Data

/-! ## Field readers

The source modules read a field in four different ways and each distinction is
observable, so each reader is named after the Elixir function it mirrors. -/

/-- `Map.get(map, :key, Map.get(map, "key"))`: a present atom key answers even
with `nil` or `false`. `TerminalReply.value/2` and `ToolCallProvenance.value/2`. -/
@[inline] def valueOf (value : Term) (key : String) : Term :=
  if value.isMap then
    (if value.has (a key) then value.get (a key) else value.get (b key))
  else nil

/-- `Map.get(map, :key) || Map.get(map, "key")`: atom key under Elixir truthiness.
`Round.current_turn_source/2` and `PhaseTelemetry.field/2`. -/
@[inline] def atomFirst (value : Term) (key : String) : Term :=
  (value.get (a key)).default (value.get (b key))

/-- `map["key"]` through Access: the string key only. -/
@[inline] def textKey (value : Term) (key : String) : Term :=
  if value.isMap then value.get (b key) else nil

/-- `map[:key]` through Access: the atom key only. -/
@[inline] def atomKey (value : Term) (key : String) : Term :=
  if value.isMap then value.get (a key) else nil

/-- `ToolCallProvenance.present?/1`: a binary whose trim is not empty. -/
def presentId (value : Term) : Bool :=
  match value with | .binary raw => !(trim raw).isEmpty | _ => false

/-- `ToolCallProvenance.normalize_ids/1`. -/
def normalizeIds (value : Term) : List Term :=
  uniq ((wrap value).filter presentId)

private def anyM (f : Term → KernelM Bool) : List Term → KernelM Bool
  | [] => pure false
  | x :: xs => do if ← f x then pure true else anyM f xs

private def allM (f : Term → KernelM Bool) : List Term → KernelM Bool
  | [] => pure true
  | x :: xs => do if ← f x then allM f xs else pure false

private def lastAckOf (state : Term) : KernelM Term := do
  return (← field state "last_ack_message_id").default (i 0)

/-! ## `SalixAgent.Round` -/

/-- `Round.fresh_wakeable_input?/2`: a committed wakeable message at or past the
request's own next-id snapshot. Reads run through `Access`, so only atom keys. -/
def freshWakeableInput (state snapshot : Term) : KernelM Term := do
  let messages ← field state "messages"
  return Term.bool (← StateQuery.enumAny messages (fun message => do
    let id := (← access message (a "id")).default (i 0)
    if !(← atMost snapshot id) then return false
    let role ← access message (a "role")
    if !(role == b "user" || role == b "runtime") then return false
    return (← access message (a "no_wake")) != a "true"))

/-- `ToolCallProvenance.origins/1` over one message envelope. -/
def messageOriginList (message : Term) : List Term :=
  match valueOf message "trusted_origins" with
  | .list (x :: xs) => (x :: xs).filter Term.isMap
  | _ => (wrap (valueOf message "trusted_origin")).filter Term.isMap

/-- `ToolCallProvenance.triage_origin?/1`. -/
def triageOrigin (origin : Term) : Bool := origin.has (b "triage_delegation")

/-- `ToolCallProvenance.message_origins/2`. -/
def messageOrigins (message : Term) (sources : List Term) : List Term :=
  let member := fun (value : Term) => sources.any (· == value)
  match valueOf message "role" with
  | .binary raw =>
    if raw == "user".toUTF8 then
      (if member (valueOf message "source_message_id")
        then (wrap (valueOf message "trusted_origin")).filter Term.isMap else [])
    else if raw == "runtime".toUTF8 then
      let inherited := normalizeIds (valueOf message "trusted_origin_source_message_ids")
      if inherited.any member then
        (messageOriginList message).filter (fun origin =>
          let sourceId := textKey origin "source_message_id"
          if presentId sourceId then inherited.any (· == sourceId) && member sourceId
          else !triageOrigin origin)
      else []
    else []
  | _ => []

/-- `Round.current_turn_trusted_origins/2`. -/
def currentTurnTrustedOrigins (state args : Term) : KernelM Term := do
  let .list (first :: rest) := args | return list []
  let sources := first :: rest
  let messages := wrap (atomFirst state "messages")
  let lastAck := (atomFirst state "last_ack_message_id").default (i 0)
  let collected ← messages.foldlM (fun acc message => do
    let id := (atomFirst message "id").default (i 0)
    if id.isInteger && (← greater id lastAck) then return acc ++ messageOrigins message sources
    return acc) []
  return list (uniq collected)

/-- `Round.current_turn_source/2`: the last wakeable human source of this
activation, else the last declared id, with the origin that carries it. -/
def currentTurnSource (state args : Term) : KernelM Term := do
  let .list (first :: rest) := args | return .tuple [nil, nil]
  let sources := first :: rest
  let messages := wrap ((atomKey state "messages").default ((textKey state "messages").default (list [])))
  let lastAck := (atomFirst state "last_ack_message_id").default (i 0)
  let wakeable ← messages.filterM (fun message => do
    let id := (atomFirst message "id").default (i 0)
    if (atomFirst message "role") != b "user" then return false
    if !id.isInteger then return false
    if !(← greater id lastAck) then return false
    if (atomFirst message "no_wake") == a "true" then return false
    if !sources.any (· == atomFirst message "source_message_id") then return false
    StateQuery.humanSourceOrigin (atomFirst message "trusted_origin"))
  let chosen := match wakeable.getLast? with
    | some message => atomFirst message "source_message_id"
    | none => nil
  let sourceId := chosen.default (sources.getLast?.getD nil)
  let origins ← currentTurnTrustedOrigins state (list [sourceId])
  return .tuple [sourceId, (← asList origins).head?.getD nil]

/-- `ToolCallProvenance.current_source_ids/1`: the activation's declared ids plus
the ones inherited by its runtime continuations. -/
def currentSourceIds (state : Term) : KernelM Term := do
  let lastAck := (valueOf state "last_ack_message_id").default (i 0)
  let messages := wrap (valueOf state "messages")
  let continuation ← messages.foldlM (fun acc message => do
    let id := valueOf message "id"
    if id.isInteger && (← greater id lastAck) && valueOf message "role" == b "runtime" &&
        !(messageOriginList message).isEmpty then
      return acc ++ normalizeIds (valueOf message "trusted_origin_source_message_ids")
    return acc) []
  let declared ← asList (← ReplyQuery.currentSourceMessageIds state)
  return list (uniq (declared ++ continuation))

/-- `Round.resolve_async_result_for_request/4`: the live window's record for one
result sequence, or `nil` when only the archive still holds it. -/
def asyncResultBySeq (state args : Term) : KernelM Term := do
  if !args.isInteger then fail "function_clause"
  enumFind ((← field state "async_results").default (list [])) (fun record =>
    return textKey record "seq" == args)

/-! ## `SalixAgent.PhaseTelemetry` -/

/-- `PhaseTelemetry.earliest_delivered_at_ms/2`: the arrival stamp of the oldest
wakeable input the runtime has not begun answering.

A `no_wake` delivery commits durably but schedules no round: it is context
staged for whichever ordinary input activates next, not work the runtime owes
an answer to. Its arrival therefore has no processing entry to wait for, and
reporting one would charge `delivery_wait` for the entire gap until the next
unrelated input happened to arrive. Such a message is skipped here for the
same reason `currentTurnSource` skips it. -/
def earliestDeliveredAt (state args : Term) : KernelM Term := do
  if !args.isList then return nil
  let sources ← asList args
  let messages := wrap (atomFirst state "messages")
  let assistantIds := (messages.filter (fun message => atomFirst message "role" == b "assistant")).map
    (fun message => (atomFirst message "id").default (i 0))
  let stamps ← messages.filterMapM (fun message => do
    let id := (atomFirst message "id").default (i 0)
    if !sources.any (· == atomFirst message "source_message_id") then return none
    if (atomFirst message "no_wake") == a "true" then return none
    if !(atomFirst message "delivered_at_ms").isInteger then return none
    if ← anyM (fun other => greater other id) assistantIds then return none
    return some (atomFirst message "delivered_at_ms"))
  match stamps with
  | [] => return nil
  | first :: rest => rest.foldlM minimum first

/-! ## `SalixAgent.InternalSessionActor` -/

/-- `InternalSessionActor.input_queue_full?/2` and
`SessionToolExecution.internal_runtime_message_envelope/3` read this length. -/
def inputQueueLength (state : Term) : KernelM Term := do
  return i (Int.ofNat (← StateQuery.properList ((← field state "input_queue").default (list []))).length)

/-- `InternalSessionActor.duplicate_delivery?/2`. -/
def duplicateDelivery (state args : Term) : KernelM Term := do
  if args == nil then return Term.bool false
  return Term.bool (← setMember (← field state "input_dedupe") args)

/-- Admit the complete delivery batch. A committed duplicate still succeeds at capacity. -/
def deliveryAdmission (state args : Term) : KernelM Term := do
  let .tuple [source, payload, limit] := args | fail "function_clause"
  if (← duplicateDelivery state source).truthy then return a "duplicate"
  if source.isMap || source.isList then
    let normalized ← stringify source
    if normalized != source && (← duplicateDelivery state normalized).truthy then
      return a "duplicate"
  let pre := wrap (((payload.get (a "pre_deliveries")).default (payload.get (b "pre_deliveries"))).default (list []))
  let events := wrap (if payload.has (a "events") then payload.get (a "events")
    else (payload.get (b "events")).default (list []))
  let incoming := 1 + pre.length + (events.filter (fun event =>
    event.isMap && (event.get (a "type")).default (event.get (b "type")) == b "queue_append")).length
  if ← greater (← add (← inputQueueLength state) (i (Int.ofNat incoming))) limit then
    return a "saturated"
  if (← ReplyQuery.admissionFull state (.tuple [payload, limit])).truthy then
    return a "saturated"
  return a "accept"

/-- `InternalSessionActor.wait_expired?/1`: a due deadline on the current wait. -/
def waitExpired (state : Term) : KernelM Term := do
  let wait ← field state "wait"
  if !wait.isMap then return Term.bool false
  let deadline := integerValue ((textKey wait "deadline_ms").default (atomKey wait "deadline_ms"))
  if deadline ≤ 0 then return Term.bool false
  let now ← observe (a "time")
  return Term.bool (deadline ≤ integerValue now)

/-- `InternalSessionActor.terminal_async_status?/1`. -/
def terminalAsyncStatus (status : Term) : Bool :=
  status == b "completed" || status == b "failed" || status == b "cancelled"

/-- `InternalSessionActor.completion_target/2`: whether this exact call is still
running, already settled, or unknown to the session. -/
def completionTarget (state args : Term) : KernelM Term := do
  let calls ← field state "async_tool_calls"
  let calls := if calls.isMap then calls else empty
  let call := calls.get args
  if call.isMap then
    let status := call.get (b "status")
    if call.has (b "status") then
      return (if terminalAsyncStatus status then a "already_resolved" else .tuple [a "running", call])
    return .tuple [a "running", call]
  if call != nil then return a "unknown"
  match ← resolveResult state args with
  | .tuple [.atom "ok", _] => return a "already_resolved"
  | .tuple [.atom "archived", _] => return a "already_resolved"
  | _ => return a "unknown"

/-! ## `SalixAgent.TerminalReply`

The source scope is the request-local projection of the one Telegram (or Slack
welcome) request this activation answers. It fails closed: unknown carriers and
a second human request answer `nil`. -/

/-- `SalixAgent.IFC.ChannelOnboarding.origin?/1`. -/
def channelOnboardingOrigin (origin : Term) : KernelM Bool := do
  if textKey origin "provider" != b "slack" then return false
  let context := textKey origin "provider_context"
  if !context.isMap then return false
  if textKey context "event_type" != b "member_joined_channel" then return false
  let connect := textKey context "connect_id"
  let channel := textKey context "channel_id"
  let event := textKey context "event_id"
  if !(connect.isBinary && connect != b "") then return false
  if !(channel.isBinary && channel != b "") then return false
  if !(event.isBinary && event != b "") then return false
  let .binary connect := connect | return false
  let .binary channel := channel | return false
  let .binary event := event | return false
  let expected := "im_provider:slack:".toUTF8 ++ connect ++ ":channel_joined:".toUTF8 ++ channel ++
    ":".toUTF8 ++ event
  return textKey origin "source_message_id" == .binary expected

/-- `TerminalReply.human_request?/1`. -/
def humanRequest (message : Term) : KernelM Bool := do
  if valueOf message "no_wake" == a "true" then return false
  StateQuery.humanSourceOrigin (valueOf message "trusted_origin")

/-- `TerminalReply.trusted_context?/1`: context carriers that add no new request. -/
def trustedContext (message : Term) : Bool :=
  let origin := valueOf message "trusted_origin"
  let source := valueOf message "source_message_id"
  let provider := textKey origin "provider"
  let actor := textKey origin "source_actor_type"
  let internalActor := actor == b "agent" || actor == b "system" || actor == b "provider_system"
  let carrierActor := internalActor || actor == b "user" || actor == b "provider_user"
  origin.isMap && source.isBinary && source != b "" &&
    (if origin.has (b "source_message_id") then origin.get (b "source_message_id") == source
     else true) &&
    ((provider == b "internal" && internalActor) ||
      (valueOf message "no_wake" == a "true" && provider != nil && provider != b "" &&
        carrierActor))

/-- The unacked `user` messages `source_scope/1` and `append_reminder/3` read. -/
private def currentUserMessages (state : Term) : KernelM (List Term) := do
  let lastAck ← lastAckOf state
  (← StateQuery.properList ((← field state "messages").default (list []))).filterM (fun message => do
    if valueOf message "role" != b "user" then return false
    greater (valueOf message "id") lastAck)

/-- Explicit source-bound reply operations. Routing comes only from trusted ingress,
not from a tool name heuristic. Telegram and channel welcome retain their legacy
bindings for in-flight calls; other providers use these exact target records. -/
def replyTargets (origin : Term) : KernelM Term := do
  let provider := textKey origin "provider"
  let destination := textKey origin "provider_context"
  let actor := textKey origin "source_actor_type"
  if provider == b "internal" then
    let conversation := textKey origin "conversation_id"
    if actor != b "user" || textKey origin "conversation_kind" != b "user_chat" ||
      !conversation.isBinary || conversation == b "" then return list []
    return list [.map [(b "tool", b "im_api.internal.send_message"),
      (b "params", .map [(b "connect_id", b "internal"), (b "conversation_id", conversation)])]]
  if actor != b "provider_user" || !destination.isMap then return list []
  let connect := textKey destination "connect_id"
  if !connect.isBinary || connect == b "" then return list []
  let route := Term.map [(b "connect_id", connect)]
  let (tools, route) ← if provider == b "slack" then do
      if ← channelOnboardingOrigin origin then pure ([], route) else do
        let channel := textKey destination "channel_id"
        let thread := (textKey destination "thread_ts").default (textKey destination "message_ts")
        if !channel.isBinary || channel == b "" || !thread.isBinary || thread == b "" then
          pure ([], route)
        else pure (["im_api.slack.reply_message"],
          route.put (b "channel") channel |>.put (b "thread_ts") thread)
    else if provider == b "feishu" then do
      let message := textKey destination "message_id"
      if !message.isBinary || message == b "" then pure ([], route)
      else pure (["im_api.feishu.reply_text", "im_api.feishu.reply_file"],
        route.put (b "message_id") message)
    else if provider == b "imessage" then do
      let chat := textKey destination "chat_id"
      if !chat.isBinary || chat == b "" then pure ([], route)
      else pure (["im_api.imessage.send_message", "im_api.imessage.send_image"],
        route.put (b "chat_id") chat)
    else if provider == b "wechat" then
      pure (["im_api.wechat.reply_text", "im_api.wechat.reply_image", "im_api.wechat.reply_file"], route)
    else if provider == b "signal" then do
      let chat := textKey destination "chat_id"
      if !chat.isBinary || chat == b "" then pure ([], route)
      else pure (["im_api.signal.send_message"], route.put (b "chat_id") chat)
    else pure ([], route)
  return list (tools.map (fun tool => Term.map [(b "tool", b tool), (b "params", route)]))

/-- `TerminalReply.source_scope/1`. -/
def sourceScope (state : Term) : KernelM Term := do
  let messages ← currentUserMessages state
  let requests ← messages.filterM humanRequest
  let context ← messages.filterM (fun message => return !(← humanRequest message))
  let [request] := requests | return nil
  let origin := valueOf request "trusted_origin"
  if !origin.isMap then return nil
  let legacy := origin.get (b "source_actor_type") == b "provider_user" &&
    (textKey origin "provider" == b "telegram" || (← channelOnboardingOrigin origin))
  if !(legacy || (← replyTargets origin) != list []) then
    return nil
  let source := valueOf request "source_message_id"
  if !(source.isBinary && source != b "") then return nil
  if textKey origin "source_message_id" != source then return nil
  if !(context.all trustedContext) then return nil
  let sources := list (uniq (messages.map (fun message => valueOf message "source_message_id")))
  if (← ReplyQuery.currentSourceMessageIds state) != sources then return nil
  return .map [(b "source_message_id", source), (b "context_source_message_ids", ← currentSourceIds state),
    (b "trusted_origin", origin)]

/-- `TerminalReply.append_reminder/3`: an unanswered Telegram human request. -/
def reminderActive (state : Term) : KernelM Term := do
  let scope ← sourceScope state
  if scope.isMap && (← replyTargets (scope.get (b "trusted_origin"))) != list [] then return a "true"
  let lastAck ← lastAckOf state
  return Term.bool (← StateQuery.enumAny ((← field state "messages").default (list []))
    (fun message => do
      let origin := (valueOf message "trusted_origin").default empty
      if valueOf message "role" != b "user" then return false
      if valueOf message "no_wake" == a "true" then return false
      if !(← greater (valueOf message "id") lastAck) then return false
      return textKey origin "provider" == b "telegram" &&
        textKey origin "source_actor_type" == b "provider_user"))

/-- `TerminalReply.matches?/2`: the binding still owns this exact activation. -/
def bindingMatches (state args : Term) : KernelM Term := do
  if !args.isMap then return Term.bool false
  let scope ← sourceScope state
  if (← field state "agent_id") != textKey args "agent_id" then return Term.bool false
  if (← field state "session_id") != textKey args "session_id" then return Term.bool false
  if (← field state "last_ack_message_id") != textKey args "last_ack_message_id" then
    return Term.bool false
  if !scope.isMap then return Term.bool false
  if scope.get (b "source_message_id") != textKey args "source_message_id" then
    return Term.bool false
  let origin := scope.get (b "trusted_origin")
  if textKey args "trusted_origin" != origin then return Term.bool false
  let targets ← replyTargets origin
  if targets != list [] then
    if textKey args "kind" != textKey origin "provider" ||
      !(← asList targets).contains (textKey args "reply_target") then return Term.bool false
  else
    let destination := textKey origin "provider_context"
    if !destination.isMap then return Term.bool false
    let kind := if (← channelOnboardingOrigin origin) then b "channel_onboarding" else b "telegram"
    if textKey args "kind" != kind || textKey args "connect_id" != textKey destination "connect_id" then
      return Term.bool false
    let chat := (textKey destination "chat_id").default (textKey destination "channel_id")
    if chat == nil || textKey args "chat_id" != (← stringChars chat) ||
      textKey args "message_thread_id" != (← stringChars ((textKey destination "message_thread_id").default (b ""))) then
      return Term.bool false
  if !(textKey args "context_source_message_ids").isList then return Term.bool false
  let current ← sorted (← asList (← currentSourceIds state))
  if current != (← sorted (← asList (textKey args "context_source_message_ids"))) then
    return Term.bool false
  let assistantId := textKey args "assistant_id"
  let toolCallId := textKey args "tool_call_id"
  return Term.bool (← allM (fun message => do
    if ← atMost (valueOf message "id") assistantId then return true
    return valueOf message "role" == b "tool" && valueOf message "tool_call_id" == toolCallId)
    (← StateQuery.properList ((← field state "messages").default (list []))))

/-- `TerminalReply.running?/1`: a process-local background call still running. -/
def replyRunning (state : Term) : KernelM Term := do
  let calls ← field state "async_tool_calls"
  let calls := if calls.isMap then calls else empty
  return Term.bool ((← entries calls).any (fun pair => pair.2.get (b "status") == b "running"))

/-- The transcript id of the welcome's own source message, from
`TerminalReply.settle_onboarding/3`; `nil` when the window no longer holds it. -/
def onboardingSourceMessageId (state args : Term) : KernelM Term := do
  let found ← enumFind ((← field state "messages").default (list [])) (fun message =>
    return valueOf message "source_message_id" == args)
  if !found.isMap then return nil
  return valueOf found "id"

/-- `settle_onboarding/3`'s committed-send test: a terminal Slack post result
inside this activation. -/
def onboardingSendCompleted (state args : Term) : KernelM Term := do
  return Term.bool (← StateQuery.enumAny ((← field state "messages").default (list []))
    (fun message => do
      if !(← greater (valueOf message "id") args) then return false
      if valueOf message "role" != b "tool" then return false
      if ![b "im_api.slack.post_channel_message", b "im_api.slack.post_message"].contains (valueOf message "tool_name") then return false
      let status := valueOf message "status"
      return status != b "running" && status != b "async_running"))

/-- Only calls owned by the same human request may be cancelled by its guard.
A foreign running call remains owned by its existing lifecycle. -/
def guardCleanupTargets (state : Term) : KernelM Term := do
  let attempt ← field state "runtime_failure_reply"
  let scope ← if attempt.isMap then pure attempt else sourceScope state
  if !scope.isMap then return nil
  let calls := (← field state "async_tool_calls").default empty
  let running := (← entries calls).filter (fun pair => pair.2.get (b "status") == b "running")
  let source := scope.get (b "source_message_id")
  let context := wrap (scope.get (b "context_source_message_ids"))
  if !(running.all (fun pair =>
      let record := pair.2
      let origin := record.get (b "trusted_origin")
      let ids := normalizeIds (record.get (b "trusted_origin_source_message_ids"))
      origin == scope.get (b "trusted_origin") && ids.contains source &&
        ids.all (fun id => context.contains id))) then return nil
  return list (running.map Prod.fst)

/-- A failure disposition identifies the existing source; only the host's
ordinary terminal context can authorize a provider send. -/
def guardDispositionBinding (state assistantId : Term) : KernelM Term := do
  let scope ← sourceScope state
  if !scope.isMap then return nil
  let origin := scope.get (b "trusted_origin")
  let targets ← asList (← replyTargets origin)
  if let target :: _ := targets then
    let binding := Term.map [(b "kind", textKey origin "provider"), (b "reply_target", target),
      (b "agent_id", ← field state "agent_id"), (b "session_id", ← field state "session_id"),
      (b "source_message_id", scope.get (b "source_message_id")),
      (b "context_source_message_ids", scope.get (b "context_source_message_ids")),
      (b "trusted_origin", origin), (b "assistant_id", assistantId),
      (b "last_ack_message_id", ← field state "last_ack_message_id")]
    if !(← bindingMatches state binding).truthy then return nil
    return binding
  let destination := origin.get (b "provider_context")
  if origin.get (b "provider") != b "telegram" || !destination.isMap ||
      !destination.has (b "connect_id") then return nil
  let chat := (destination.get (b "chat_id")).default (destination.get (b "channel_id"))
  if chat == nil then return nil
  let binding := Term.map [(b "kind", b "telegram"),
    (b "agent_id", ← field state "agent_id"), (b "session_id", ← field state "session_id"),
    (b "source_message_id", scope.get (b "source_message_id")),
    (b "context_source_message_ids", scope.get (b "context_source_message_ids")),
    (b "trusted_origin", origin), (b "connect_id", destination.get (b "connect_id")),
    (b "chat_id", ← stringChars chat),
    (b "message_thread_id", ← stringChars ((destination.get (b "message_thread_id")).default (b ""))),
    (b "assistant_id", assistantId), (b "last_ack_message_id", ← field state "last_ack_message_id")]
  if !(← bindingMatches state binding).truthy then return nil
  return binding

/-- Model stopping and notification delivery are separate from accepted tool
work. The existing guard cancellation policy applies only to runaway loops. -/
def failureReason (state : Term) : KernelM Term := do
  if (← terminalFailure state) || (← StateQuery.failuresExhausted state) then return b "model"
  if ← StateQuery.modelGuardExhausted state then return b "guard"
  return nil

/-- Runaway termination is runtime-owned, regardless of source/send authority.
Only the materialized transcript is retired; queued deliveries remain separate. -/
def runawayRetirementPending (state : Term) : KernelM Bool := do
  return (← StateQuery.runawayExhausted state) &&
    integerValue (← field state "next_message_id") - 1 > integerValue (← field state "last_ack_message_id")

def guardDispositionPending (state : Term) : KernelM Bool := do
  if ← runawayRetirementPending state then return true
  if (← field state "runtime_failure_reply").isMap then return false
  let reason ← failureReason state
  if reason == nil then return false
  if (← guardDispositionBinding state (← field state "next_message_id")).isMap &&
      (reason != b "guard" || (← guardCleanupTargets state).isList) then return true
  return integerValue (← ReplyQuery.blockingObligationCount state) == 0 &&
    !(← StateQuery.pendingVisibleReply state) &&
    integerValue (← field state "next_message_id") - 1 > integerValue (← field state "last_ack_message_id")

/-- Model failure can finish an already-notified source only after its accepted
work settles. Otherwise retain its identity for retries or one notification: a
source without a destination is acknowledged only when the failure is final and
no send is pending. -/
def llmFailureAck (state : Term) : KernelM Bool := do
  let attempt ← field state "runtime_failure_reply"
  if (attempt.get (b "notification_outcome")).isBinary then
    return !(← replyRunning state).truthy &&
      integerValue (← ReplyQuery.blockingObligationCount state) == 0 && !(← StateQuery.pendingVisibleReply state)
  if (← guardDispositionBinding state (← field state "next_message_id")).isMap then return false
  if (← failureReason state) == nil then return false
  return !(← StateQuery.pendingVisibleReply state)

/-! ### Registry -/

/-- New human inputs needing optional miniskill preparation. The owner commits the result. -/
def miniskillInputs (state : Term) : KernelM Term := do
  let saved := valueOf state "miniskills"
  let through := (saved.get (b "through")).default (i 0)
  let ack := (valueOf state "last_ack_message_id").default (i 0)
  let messages := wrap (valueOf state "messages")
  let mut recent : List Term := []
  let mut inputs : List Term := []
  for message in messages do
    let id := valueOf message "id"
    let role := valueOf message "role"
    let origin := valueOf message "trusted_origin"
    if id.isInteger && (← greater id through) && (← greater id ack) &&
        role == b "user" && valueOf message "no_wake" != a "true" &&
        [b "user", b "provider_user"].contains (origin.get (b "source_actor_type")) &&
        (← StateQuery.humanSourceOrigin origin) then
      let input := Term.map (["id", "source_message_id", "content", "trusted_origin"].map
        fun key => (b key, valueOf message key))
      inputs := input.put (b "recent_messages") (list recent.reverse) :: inputs
    if [b "user", b "assistant"].contains role then
      recent := (Term.map [(b "role", role), (b "content", valueOf message "content")] :: recent).take 6
  return list inputs.reverse

def table : OpTable :=
  [("miniskill_inputs", fun state _ => miniskillInputs state)] ++
  [("guard_disposition_binding", guardDispositionBinding),
   ("runtime_failure_reason", fun state _ => failureReason state),
   ("llm_failure_ack?", fun state _ => return Term.bool (← llmFailureAck state)),
   ("guard_disposition_pending?", fun state _ => return Term.bool (← guardDispositionPending state)),
   ("fresh_wakeable_input?", freshWakeableInput),
   ("current_source_ids", fun state _ => currentSourceIds state),
   ("current_turn_trusted_origins", currentTurnTrustedOrigins),
   ("current_turn_source", currentTurnSource),
   ("async_result_by_seq", asyncResultBySeq),
   ("earliest_delivered_at_ms", earliestDeliveredAt),
   ("input_queue_length", fun state _ => inputQueueLength state),
   ("duplicate_delivery?", duplicateDelivery),
   ("wait_expired?", fun state _ => waitExpired state),
   ("completion_target", completionTarget),
   ("terminal_reply_source_scope", fun state _ => sourceScope state),
   ("terminal_reply_targets", fun state _ => do
     let scope ← sourceScope state
     replyTargets (scope.get (b "trusted_origin"))),
   ("terminal_reply_reminder_active?", fun state _ => reminderActive state),
   ("terminal_reply_matches?", bindingMatches),
   ("terminal_reply_running?", fun state _ => replyRunning state),
   ("onboarding_source_message_id", onboardingSourceMessageId),
   ("onboarding_send_completed?", onboardingSendCompleted)]

end VerifiedKernel.Session.RoundQuery
