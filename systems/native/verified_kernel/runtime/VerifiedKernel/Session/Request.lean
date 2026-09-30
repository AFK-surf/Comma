import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.Query.Compaction
import VerifiedKernel.Session.Query.Round
import VerifiedKernel.Session.Query.Provenance
import VerifiedKernel.Session.RequestPage
import VerifiedKernel.Provider.Request
import VerifiedKernel.Session.TurnReminders

namespace VerifiedKernel.Session.Request
open Data
open RoundQuery (valueOf)
open StateQuery (decisionRequired)

private def source_reply_delivery_instruction : Term := b TurnReminders.deliveryInstruction
private def terminal_reply_reminder : Term := b TurnReminders.terminalReply
private def turn_outcome_reminder : Term := b TurnReminders.turnOutcome
private def delivery_rule : Term := b TurnReminders.deliveryRule
private def onboardingReminder : Term := b TurnReminders.onboarding

private def summary (content : Term) : Term :=
  .map [(a "role", b "summary"), (a "content", content)]

private def cat (parts : List Term) : KernelM Term := do
  let bytes ← parts.mapM (fun part => do
    let .binary bytes ← stringChars part | fail "badarg"
    pure bytes)
  return .binary (bytes.foldl (· ++ ·) ByteArray.empty)

private def json (value : Term) : KernelM Term := do
  let some bytes ← Json.encode value | fail "badarg"
  return .binary bytes

/-- A user message whose internal origin asks for it (`show_conversation`)
shows its conversation in front of the text: `[conversation <id>] `. The
header is built for each request; the stored text does not change. -/
private def conversationHeader (message : Term) : KernelM Term := do
  let origin := valueOf message "trusted_origin"
  if !origin.isMap || origin.get (b "show_conversation") != a "true" then return message
  if origin.get (b "provider") != b "internal" then return message
  let .binary conversation := origin.get (b "conversation_id") | return message
  let .binary content := valueOf message "content" | return message
  let header := "[conversation ".toUTF8 ++ conversation ++ "] ".toUTF8
  -- A request annotates each message more than once, and a source marker can
  -- come first, so any earlier header counts.
  let present := (List.range (content.size + 1 - header.size)).any (fun start =>
    content.extract start (start + header.size) == header)
  if content.size ≥ header.size && present then return message
  return message.put (if message.has (a "content") then a "content" else b "content")
    (.binary (header ++ content))

def annotate (message : Term) : KernelM Term := do
  if !message.isMap then return message
  let role ← ProvenanceQuery.text (valueOf message "role")
  let message ← if role == b "user" then conversationHeader message else pure message
  let origin := valueOf message "trusted_origin"
  let label := if origin.has (b "ifc") then origin.get (b "ifc") else origin.get (a "ifc")
  let marker := if role == b "user" && origin.isMap && label.isMap then "src:q-"
    else if role == b "runtime" && (valueOf message "ifc").isMap then "src:a-" else ""
  if marker == "" then return message
  let .binary ref ← ProvenanceQuery.prefixedRef marker (valueOf message "id") | return message
  let .binary content := valueOf message "content" | return message
  let header := "[".toUTF8 ++ ref ++ "]".toUTF8
  if content.extract 0 header.size == header then return message
  return message.put (if message.has (a "content") then a "content" else b "content")
    (.binary (header ++ "\n".toUTF8 ++ content))

def modelMessages (delta : Term) : KernelM Term := do
  if delta == nil then return list []
  let messages ← asList (delta.get (a "messages"))
  return list (← messages.mapM (fun payload => do
    let payload ← stringify payload
    let value := Term.map [(a "role", b "runtime"), (a "kind", b "runtime_message"),
      (a "runtime_message_id", payload.get (b "runtime_message_id")),
      (a "type", (payload.get (b "runtime_message_type")).default (payload.get (b "type"))),
      (a "summary", payload.get (b "summary")), (a "content_kind", payload.get (b "content_kind")),
      (a "content", (payload.get (b "content")).default (payload.get (b "summary"))),
      (a "source_refs", (payload.get (b "source_refs")).default empty)]
    return .map ((← entries value).filter (fun pair => pair.2 != nil))))

def prepend (messages prompt : Term) : KernelM Term := do
  let messages ← asList messages
  return list (if prompt.isBinary && prompt != b "" then summary prompt :: messages else messages)

def turnReminder (state messages enabled : Term) : KernelM Term := do
  if enabled.truthy && (← decisionRequired state) then
    return list ((← asList messages) ++ [summary turn_outcome_reminder])
  return messages

def deliveryReminder (state messages origin _available : Term) : KernelM Term := do
  let conversation := origin.get (b "conversation_id")
  if origin.get (b "provider") != b "internal" || origin.get (b "source_actor_type") != b "user" ||
    origin.get (b "conversation_kind") != b "user_chat" || !conversation.isBinary || conversation == b "" ||
    !(← decisionRequired state) then return messages
  let content ← cat [source_reply_delivery_instruction,
    b " Use call with tool=im_api.internal.send_message, params.connect_id=internal and params.conversation_id=",
    conversation, b "; content uses the operation schema. Follow current disclosure and authorization. Do not send this Comma answer to an earlier external chat."]
  return list ((← asList messages) ++ [summary content])

def terminalReminder (state messages router : Term) : KernelM Term := do
  if !router.truthy then return messages
  let scope ← RoundQuery.sourceScope state
  let onboarding := scope.isMap && (← RoundQuery.channelOnboardingOrigin (scope.get (b "trusted_origin")))
  if onboarding then return list ((← asList messages) ++ [summary onboardingReminder])
  if (← RoundQuery.reminderActive state).truthy then
    return list ((← asList messages) ++ [summary terminal_reply_reminder])
  return messages

def obligationReminder (state messages : Term) : KernelM Term := do
  let count ← ReplyQuery.pendingObligationCount state
  if count == i 0 then return messages
  let targets := (← asList (← ReplyQuery.pendingObligations state)).take 20
  let lines ← targets.mapM (fun target => do
    let target := Term.map ((← entries target).filter (fun pair =>
      ["provider", "kind", "conversation_id", "connect_id", "channel", "thread_ts"].any (fun key => pair.1 == b key)))
    cat [b "- ", ← json target])
  let omitted := integerValue count - Int.ofNat targets.length
  let remainder ← if omitted > 0 then
    cat [b "\n- ", i omitted, b " additional target(s) remain in durable runtime state."] else pure (b "")
  let content ← cat ([b "Unresolved external obligations (", count, b " total). Review these targets before end_turn; resolving one target never resolves another. A target without kind is an advisory reply reminder, not a requirement to reply. If no reply is needed or delivery cannot progress, explicitly use end_turn with the appropriate outcome and reason. Ending the turn retires ordinary reply reminders without claiming successful delivery. A kind=task_card target needs one successful im_api.slack.post_task_card call with that exact conversation_id; its connect_id, channel, and thread_ts are the suggested source thread when present. Failed, guidance, or async-running calls do not count.\n"] ++
    lines.intersperse (b "\n") ++ [remainder])
  return list ((← asList messages) ++ [summary content])

-- The stored catalog avoids repeating rule text. A short transient reminder
-- still changes a message-boundary cache prefix when encoded as a user message.
def turnReminderCatalog : KernelM Term := pure (b TurnReminders.catalog)

-- A stored prompt that still lacks the catalog (the session started before
-- it existed and `ReplyQuery.promptSnapshot` has not migrated it yet, or the
-- configured prompt never carries one) keeps the full per-request reminders.
private def catalogPresent (prompt : Term) : Bool := TurnReminders.catalogPresent prompt

-- A human message in a Comma user chat, the source the opening and plain-text
-- delivery rules address.
private def commaUserChat (origin : Term) : Bool :=
  let conversation := origin.get (b "conversation_id")
  origin.get (b "provider") == b "internal" && origin.get (b "source_actor_type") == b "user" &&
    origin.get (b "conversation_kind") == b "user_chat" && conversation.isBinary && conversation != b ""

-- Unacked waking user input that no assistant response follows yet: the first
-- request after a new message, not a tool continuation or a retry after the
-- model has already responded.
private def unansweredUserInput (state : Term) : KernelM Bool := do
  let lastAck := (StateQuery.dual state "last_ack_message_id").default (i 0)
  let messages ← enumMap ((StateQuery.dual state "messages").default (list [])) pure
  let unanswered := messages.reverse.takeWhile (fun message => StateQuery.dual message "role" != b "assistant")
  unanswered.anyM fun message => do
    if StateQuery.dual message "role" != b "user" || StateQuery.dual message "no_wake" == a "true" then
      return false
    greater ((StateQuery.dual message "id").default (i 0)) lastAck

def turnMarker (state messages _available origin router : Term) : KernelM Term := do
  let phase ← ReplyQuery.phase state
  let repair := Presentation.required phase
  let decision ← decisionRequired state
  let opening ← if commaUserChat origin && !repair then unansweredUserInput state else pure false
  let deliver := commaUserChat origin && decision
  let scope ← RoundQuery.sourceScope state
  let onboarding ← if router.truthy && scope.isMap then RoundQuery.channelOnboardingOrigin (scope.get (b "trusted_origin")) else pure false
  let finalReply := router.truthy && !onboarding && (← RoundQuery.reminderActive state).truthy
  let flags := [(opening, "opening=on"), (deliver, "deliver=on"), (!repair && decision, "decide=on"),
    (finalReply, "final_reply=on"), (onboarding, "onboarding=on"), (repair, "repair=on")]
  let active := flags.filterMap (fun pair => if pair.1 then some pair.2 else none)
  if active.isEmpty then return messages
  return list ((← asList messages) ++ [summary (b ("turn: " ++ " ".intercalate active))])

def platformReminder (disclosure : Term) : KernelM Term := do
  let tools ← asList (disclosure.get (b "tools"))
  let available := (tools.map (·.get (b "name"))).filter (fun name =>
    ["question.request", "permission.request", "location.request", "oauth.request_authorization"].any (fun tool => name == b tool))
  let question := if available.contains (b "question.request") then
    " When a question needs selectable answers in the current Telegram chat, call question.request with choices to send native inline buttons. These buttons are available now even if an earlier answer said otherwise; use help for the current parameters if needed. question.request requires locale even when an older successful call omitted it: include locale=zh-CN for Chinese dialogue or locale=en for English dialogue." else ""
  let location := if available.contains (b "location.request") then
    " location.request requires an explicit locale too. For city-level information such as weather, ask for the city with question.request or a text reply instead of requesting precise coordinates unnecessarily. location.request offers native Telegram location sharing and an optional exact-prompt city reply. Sending that prompt does not mean coordinates were obtained." else ""
  cat [b "Current-source interaction tools: ", ← json (list available),
    b ". This list overrides older tool descriptions and earlier assistant claims about availability.", b question, b location,
    b " For Telegram native interactions, infer locale from the current dialogue and pass it explicitly: zh-CN for Chinese or en for English. Do not use the Telegram client's language or translate the user's option text.  Never claim an unavailable popup, button, location or authorization request was sent. If the needed interaction is unavailable, ask a plain-text question through the current source reply path (for location, ask for a city). Telegram native question delivery ends the activation; the user's later response is a new input, not a running tool to poll."]

def platformPrompt (prompt disclosure origin : Term) : KernelM Term := do
  if [nil, b "internal"].contains (origin.get (b "provider")) then return prompt
  cat [prompt, b "\n\n", ← platformReminder disclosure]

-- A terminal reply consumes its own completion wake. Show the receipt from
-- that settlement instead of promising a notification that will never arrive.
-- The journal and earlier reader-page bodies stay unchanged.
private def terminalReplyReceipt (message call outcome : Term) : KernelM Term := do
  if ![b "running", b "async_running"].contains (valueOf message "status") then return message
  let content := valueOf message "content"
  let some placeholder := Provider.decode content | return message
  if valueOf placeholder "status" != b "running" ||
      valueOf placeholder "tool_call_id" != call then return message
  let receipt ← json (.map [(b "status", b "completed"),
    (b "tool_call_id", call), (b "tool_name", valueOf message "tool_name"),
    (b "outcome", outcome), (b "message", b "Reply delivered and turn completed.")])
  let message := Attachments.putField (Attachments.putField message "content" receipt) "status" (b "completed")
  return if valueOf message "output" == content then Attachments.putField message "output" receipt else message

private def terminalReplyReceipts (state : Term) (messages : List Term) : KernelM (List Term) := do
  let mut delivered : Std.HashMap (Int × ByteArray) Term := {}
  for fact in Provider.items (valueOf state "events") do
    if valueOf fact "kind" != b "terminal_reply_delivered" then continue
    let binding := valueOf fact "event"
    let .integer assistant := valueOf binding "assistant_id" | continue
    let .binary call := valueOf binding "tool_call_id" | continue
    let outcome := valueOf binding "outcome"
    if assistant ≤ 0 || call.isEmpty || ![b "done", b "blocked"].contains outcome then continue
    delivered := delivered.insert (assistant, call) outcome
  if delivered.isEmpty then return messages
  -- Calls may reuse a provider ID in later rounds. Match the last preceding
  -- invocation of that ID, as the provider tool-history projection does.
  let mut owners : Std.HashMap ByteArray Term := {}
  let mut projected := []
  for message in messages do
    let mut message := message
    if valueOf message "role" == b "assistant" then
      for invocation in Provider.items (valueOf message "tool_calls") do
        if let .binary call := valueOf invocation "id" then
          owners := owners.insert call (valueOf message "id")
    else if valueOf message "role" == b "tool" then
      if let .binary call := CompactionQuery.toolResultCallId message then
        if let some (.integer assistant) := owners.get? call then
          if let some outcome := delivered.get? (assistant, call) then
            message ← terminalReplyReceipt message (.binary call) outcome
    projected := message :: projected
  return projected.reverse

def context (state : Term) : KernelM Term := do
  let messages := (← asList (← CompactionQuery.contextPrefix state)) ++ (← asList (← CompactionQuery.requestLiveMessages state))
  let messages ← terminalReplyReceipts state messages
  let messages ← asList (← Presentation.sanitizeContext messages (← ReplyQuery.phase state))
  return list (← messages.mapM fun message => RequestPage.fit annotate message >>= annotate)

/-- Whether a context message matches a `provider_context_where` selector:
`{:runtime_message_id, id}` compares the string-keyed value first, and
`{:tool_ids, ids}` selects tool results by message id, atom keys first. -/
private def selects (selector message : Term) : Bool :=
  match selector with
  | .tuple [.atom "runtime_message_id", id] =>
    let value := message.get (b "runtime_message_id")
    (if value.truthy then value else message.get (a "runtime_message_id")) == id
  | .tuple [.atom "tool_ids", .list ids] =>
    Provider.field message "role" == b "tool" && ids.contains (Provider.field message "id")
  | _ => false

/-- The messages of `context` that `selector` selects, in order. Each step of
`context` maps one message to one message and keeps its role, id and runtime
message id, so the selection is taken before the per-message work; the facts
that span messages still come from all of them. -/
def contextWhere (state selector : Term) : KernelM Term := do
  let messages := (← asList (← CompactionQuery.contextPrefix state)) ++ (← asList (← CompactionQuery.requestLiveMessages state))
  -- Receipts change tool results, and private call ids redact assistant
  -- calls. A selection with neither needs no pass over the other messages.
  -- Both role keys must be absent or other binaries for a message to be
  -- neither; any other shape keeps both passes.
  let plainRole := fun (role : Term) => role == nil || (role.isBinary && role != b "tool" && role != b "assistant")
  let chosen := messages.filter (selects selector)
  let spans := chosen.any fun message =>
    !(plainRole (message.get (a "role")) && plainRole (message.get (b "role")))
  let messages ← if spans then terminalReplyReceipts state messages else pure messages
  let selected := if spans then messages.filter (selects selector) else chosen
  let selected ← asList (← Presentation.sanitizeSelected (if spans then messages else selected) selected
    (← ReplyQuery.phase state))
  let projected ← selected.mapM fun message => RequestPage.fit annotate message >>= annotate
  return list (projected.filter (selects selector))


private def build (state args : Term) : KernelM (List Term × List Term) := do
  let .tuple [context, delta, prompt, available, origin, disclosure, router] := args | fail "function_clause"
  let phase ← ReplyQuery.phase state
  let delta ← Presentation.sanitizeContext (← asList (← modelMessages delta)) phase
  let selected := valueOf state "miniskills"
  let sources ← asList (← RoundQuery.currentSourceIds state)
  let overlays := (Provider.items (selected.get (b "inputs"))).filter fun input =>
    sources.contains (input.get (b "source_message_id"))
  let overlays ← (overlays.flatMap fun input => Provider.items (input.get (b "skills"))).mapM fun skill => do
    let ref ← ProvenanceQuery.prefixedRef "src:k-" (skill.get (b "skill_id"))
    let content ← cat [b "[", ref, b "]\nSelected miniskill: ", skill.get (b "skill_id"),
      b "\nSupporting files: /.runtime/skills/", skill.get (b "skill_id"), b "/\n", skill.get (b "content")]
    return summary content
  let messages := list ((← asList context) ++ (← asList delta) ++ overlays)
  let prompt ← platformPrompt prompt disclosure origin
  let messages ← prepend messages prompt
  -- Only this kernel-owned tail becomes developer input in Responses.
  -- History summaries and runtime/user content keep their existing roles.
  let reminders ← obligationReminder state (list [])
  let reminders ← if catalogPresent prompt then
    turnMarker state reminders available origin router
  else do
    let reminders ← terminalReminder state reminders router
    let reminders ← turnReminder state reminders (Term.bool (!Presentation.required phase))
    let reminders ← deliveryReminder state reminders origin available
    Presentation.policy (.tuple [a "append_repair_reminder", .tuple [reminders, phase]])
  return (← asList messages, ← asList reminders)

/-- The stored-result reads of `dispatch`, read before the request is built.
A query that asks for them first resumes before the expensive build, not
after it. The guess reads the stored messages after the watermark; delta
messages name no stored result. It raises nothing: a malformed transcript
fails where the build reads it. -/
def prefetch (state : Term) : KernelM (List (Term × Term)) := do
  let watermark := (valueOf state "last_ack_message_id").default (i 0)
  let stored := match valueOf state "messages" with | .list messages => messages | _ => []
  let fresh := stored.filter fun message =>
    let id := Provider.field message "id"
    !watermark.isInteger || (id.isInteger && integerValue id > integerValue watermark)
  Attachments.prefetch fresh watermark

def dispatch (state args : Term) (prefetched : List (Term × Term) := []) : KernelM Term := do
  let .tuple [delta, available, origin, disclosure, router, protocol, cfg, tools, mode] := args | fail "function_clause"
  let .tuple [_, prompt] ← ReplyQuery.promptSnapshot state nil | fail "badarg"
  let (messages, reminders) ← build state (.tuple [← context state, delta, prompt, available, origin, disclosure, router])
  let messages ← Attachments.inline messages ((valueOf state "last_ack_message_id").default (i 0)) true prefetched
  if protocol == a "neutral" then return list (messages ++ reminders)
  let .binary name := protocol | fail "badarg"
  Provider.Request.encodedBody (String.fromUTF8! name) cfg messages (← asList tools) (String.fromUTF8! (Provider.bytes mode)) reminders

def part (state args : Term) : KernelM Term := do
  match args with
  | .tuple [.atom "attachment_source", message] => Attachments.source message
  | .tuple [.atom "inline_attachments", .list messages, watermark, enabled] =>
    return list (← Attachments.inline messages watermark (enabled != a "false"))
  | .tuple [.atom "catalog_present?", prompt] => pure (Term.bool (catalogPresent prompt))
  | .tuple [.atom "turn_reminder_catalog"] => turnReminderCatalog
  | .tuple [.atom "turn_marker", messages, available, origin, router] => turnMarker state messages available origin router
  | .tuple [.atom "prepend", messages, prompt] => prepend messages prompt
  | .tuple [.atom "model_messages", delta] => modelMessages delta
  | .tuple [.atom "annotate_message", message] => annotate message
  | .tuple [.atom "annotate_messages", messages] =>
    if messages.isList then return list (← (← asList messages).mapM annotate) else pure messages
  | .tuple [.atom "turn_reminder", messages, enabled] => turnReminder state messages enabled
  | .tuple [.atom "delivery_reminder", messages, origin, available] => deliveryReminder state messages origin available
  | .tuple [.atom "terminal_reminder", messages, router] => terminalReminder state messages router
  | .tuple [.atom "obligation_reminder", messages] => obligationReminder state messages
  | .tuple [.atom "platform_prompt", prompt, disclosure, origin] => platformPrompt prompt disclosure origin
  | .tuple [.atom "platform_reminder", disclosure] => platformReminder disclosure
  | _ => fail "function_clause"

def table : OpTable := [("provider_request_part", part),
  ("provider_dispatch", fun state args => dispatch state args),
  ("provider_context", fun state _ => context state),
  ("provider_context_where", contextWhere)]

end VerifiedKernel.Session.Request
