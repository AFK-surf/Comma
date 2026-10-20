import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.Query.Compaction
import VerifiedKernel.Session.Query.Round
import VerifiedKernel.Session.Query.Provenance
import VerifiedKernel.Session.RequestPage
import VerifiedKernel.Provider.Request

namespace VerifiedKernel.Session.Request
open Data
open RoundQuery (valueOf)

def summary (content : Term) : Term :=
  .map [(a "role", b "summary"), (a "content", content)]

def cat (parts : List Term) : KernelM Term := do
  let bytes ← parts.mapM (fun part => do
    let .binary bytes ← stringChars part | fail "badarg"
    pure bytes)
  return .binary (bytes.foldl (· ++ ·) ByteArray.empty)

def json (value : Term) : KernelM Term := do
  let some bytes ← Json.encode value | fail "badarg"
  return .binary bytes

/-- A user message whose internal origin asks for it (`show_conversation`)
shows its conversation in front of the text: `[conversation <id>] `. The
header is built for each request; the stored text does not change. -/
def conversationHeader (message : Term) : KernelM Term := do
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

def context (state : Term) : KernelM Term := do
  let messages := (← asList (← CompactionQuery.contextPrefix state)) ++ (← asList (← CompactionQuery.requestLiveMessages state))
  let messages ← asList (← Presentation.sanitizeContext messages)
  return list (← messages.mapM fun message => RequestPage.fit annotate message >>= annotate)

/-- Whether a context message matches a `provider_context_where` selector:
`{:runtime_message_id, id}` compares the string-keyed value first, and
`{:tool_ids, ids}` selects tool results by message id, atom keys first. -/
def selects (selector message : Term) : Bool :=
  match selector with
  | .tuple [.atom "runtime_message_id", id] =>
    let value := message.get (b "runtime_message_id")
    (if value.truthy then value else message.get (a "runtime_message_id")) == id
  | .tuple [.atom "tool_ids", .list ids] =>
    Provider.field message "role" == b "tool" && ids.contains (Provider.field message "id")
  | _ => false

/-- The messages of `context` that `selector` selects, in order. Each step of
`context` maps one message to one message and keeps its role, id and runtime
message id, so the selection is taken before the per-message work. -/
def contextWhere (state selector : Term) : KernelM Term := do
  let messages := (← asList (← CompactionQuery.contextPrefix state)) ++ (← asList (← CompactionQuery.requestLiveMessages state))
  let selected ← asList (← Presentation.sanitizeContext (messages.filter (selects selector)))
  let projected ← selected.mapM fun message => RequestPage.fit annotate message >>= annotate
  return list (projected.filter (selects selector))

/-- The request is the stored prompt, the stored context and the activation
delta, which response acceptance stores. Nothing else enters it. -/
def build (_state args : Term) : KernelM (List Term) := do
  let .tuple [context, delta, prompt] := args | fail "function_clause"
  let delta ← Presentation.sanitizeContext (← asList (← modelMessages delta))
  asList (← prepend (list ((← asList context) ++ (← asList delta))) prompt)

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
  let .tuple [delta, protocol, cfg, tools, mode] := args | fail "function_clause"
  let .tuple [_, prompt] ← ReplyQuery.promptSnapshot state nil | fail "badarg"
  let messages ← build state (.tuple [← context state, delta, prompt])
  let messages ← Attachments.inline messages ((valueOf state "last_ack_message_id").default (i 0)) true prefetched
  if protocol == a "neutral" then return list messages
  let .binary name := protocol | fail "badarg"
  Provider.Request.encodedBody (String.fromUTF8! name) cfg messages (← asList tools) (String.fromUTF8! (Provider.bytes mode))

def part (_state args : Term) : KernelM Term := do
  match args with
  | .tuple [.atom "attachment_source", message] => Attachments.source message
  | .tuple [.atom "inline_attachments", .list messages, watermark, enabled] =>
    return list (← Attachments.inline messages watermark (enabled != a "false"))
  | .tuple [.atom "prepend", messages, prompt] => prepend messages prompt
  | .tuple [.atom "model_messages", delta] => modelMessages delta
  | .tuple [.atom "annotate_message", message] => annotate message
  | .tuple [.atom "annotate_messages", messages] =>
    if messages.isList then return list (← (← asList messages).mapM annotate) else pure messages
  | .tuple [.atom "platform_reminder", disclosure] => platformReminder disclosure
  | _ => fail "function_clause"

def table : OpTable := [("provider_request_part", part),
  ("provider_dispatch", fun state args => dispatch state args),
  ("provider_context", fun state _ => context state),
  ("provider_context_where", contextWhere)]

end VerifiedKernel.Session.Request
