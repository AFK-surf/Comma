import VerifiedKernel.ByteDigest
import VerifiedKernel.Provider.Content
import Std.Data.HashMap.Basic

namespace VerifiedKernel.Provider.Messages
open Data

def context (text : Term) : KernelM Term := do
  return obj [("role", b "user"), ("content", ← cat [b "<system>\n", text, b "\n</system>"])]

@[inline] def callField (c : Term) (key : String) : Term := coalesce [get c key, c.get (a key)]
def callId (m : Term) : Term := coalesce [field m "tool_call_id", field m "tool_use_id"]
def openaiRole (m : Term) : Term :=
  match field m "role" with | .atom name => b name | value => value
def reasoningFields : List String := ["reasoning_content", "reasoning", "reasoning_details", "thought", "thoughts", "thought_signature", "thought_signatures"]

/-! ## Runtime messages after the leading context run

For Chat and Responses, a runtime message after the leading context run
reaches the model as a runtime-authored `get_runtime_message` call and its
result: the structured runtime message. So does every other system-authored
message there (history summaries), as type `system_reminder`. The tool is not
in the catalog.

For Anthropic, a runtime-authored message there is a mid-conversation
`system` message. A runtime message that carries external content (`untrusted`)
is user text instead: a system message would give that content operator
authority. Placement turns keep each system message after a user turn and
before an assistant turn. Only the outbound copy changes; the transcript keeps
the original message. -/

def runtimeToolName : String := "get_runtime_message"

def runtimeFields : List String := ["runtime_message_id", "type", "source_tool_call_id", "wait_id",
  "reason", "timeout_seconds", "deadline_ms", "elapsed_ms", "overdue_ms", "source", "tool_call_id",
  "tool_call_ids", "failed_tool_calls", "pending_external_callback_tool_calls", "failed_llm_call", "summary",
  "content", "source_refs"]

-- A stable provider-safe ID keeps the request prefix cacheable across rounds.
-- It uses the runtime message ID first: a request-time delta and its later
-- stored copy must render the same call.
def runtimeCallId (m : Term) : KernelM Term := do
  let identity := coalesce [field m "runtime_message_id", field m "id", field m "source_message_id"]
  let key ← encode (if identity == nil then m else identity)
  let digest := ByteDigest.base64Url (ByteDigest.sha256Bytes (bytes key)).toList
  return .binary ("rtm_".toUTF8 ++ ⟨(digest.take 16).toArray⟩)

-- An IFC source marker (`[src:…]` and a newline) moves to `ref`; JSON content is decoded.
def runtimeContent (content : Term) : KernelM (List (String × Term)) := do
  let content ← str content
  let raw := bytes content
  let (ref, body) := Id.run do
    if raw.size < 6 || raw.extract 0 5 != "[src:".toUTF8 then return (nil, raw)
    for index in [5:raw.size] do
      if raw[index]! == 93 then
        if index + 1 < raw.size && raw[index + 1]! == 10 then
          return (Term.binary (raw.extract 1 index), raw.extract (index + 2) raw.size)
        return (nil, raw)
      if raw[index]! == 10 then return (nil, raw)
    return (nil, raw)
  let body := Term.binary body
  let value := match decode body with
    | some (.map xs) => Term.map xs
    | some (.list xs) => Term.list xs
    | _ => body
  return (if ref == nil then [] else [("ref", ref)]) ++ [("content", value)]

def runtimePayload (m : Term) : KernelM Term := do
  let jsonFields := ["tool_call_ids", "failed_tool_calls", "pending_external_callback_tool_calls", "failed_llm_call", "source_refs"]
  let mut out : List (String × Term) := []
  for key in runtimeFields do
    let v := if key == "content" then Content.runtimeBody m else field m key
    if v == nil then continue
    if jsonFields.contains key then
      if v != empty && v != list [] then out := out ++ [(key, v)]
    else if key == "content" then
      if v != b "" then out := out ++ (← runtimeContent v)
    else
      let v ← match v with | .integer _ => pure v | _ => str v
      if v != b "" then out := out ++ [(key, v)]
  return obj out

def reminderType : String := "system_reminder"

-- A system-authored message keeps its trimmed text as the runtime content.
def asReminder (m : Term) : KernelM Term := do
  let m := (removeKey (removeKey m (a "role")) (a "content")).put (b "role") (b "runtime")
    |>.put (b "content") (← Content.systemText m)
  return if field m "type" == nil then m.put (b "type") (b reminderType) else m

-- Identical reminders would share a content-derived ID. A repeat takes the
-- next free suffix; earlier calls keep theirs, so the cached prefix holds.
def claimId (seen : Std.HashSet ByteArray) (id : ByteArray) : ByteArray × Std.HashSet ByteArray := Id.run do
  let mut candidate := id
  for n in [2:seen.size + 3] do
    if !seen.contains candidate then break
    candidate := id ++ s!"_{n}".toUTF8
  return (candidate, seen.insert candidate)

/-- The synthetic call and result for one runtime message. `trailing` keeps
system-authored messages out of the cached Anthropic prefix. -/
def runtimeCall (m id : Term) (reminder : Bool := false) : KernelM (List Term) := do
  let rid := field m "runtime_message_id"
  let args := if rid.isBinary && rid != b "" then obj [("runtime_message_id", rid)] else empty
  let trailing := Term.bool reminder
  return [obj [("role", b "assistant"), ("content", b ""), ("runtime_trailing", trailing),
      -- Thinking-mode Chat Completions requires a string on synthetic calls too.
      ("provider_meta", obj [("chat_message_extra", obj [("reasoning_content", b "")])]),
      ("tool_calls", list [obj [("id", id), ("name", b runtimeToolName), ("args", args)]])],
    obj [("role", b "tool"), ("tool_call_id", id), ("runtime_trailing", trailing),
      ("content", ← encode (← runtimePayload m))]]

/-- Opens the conversation when a request has no turn of its own (only
context, as right after compaction): providers need a user message. -/
def placeholderTurn : String := "[No new user message.]"

/-- The user turn that opens a conversation, or precedes an Anthropic system
message that would otherwise follow an assistant turn. -/
def placeholderUser : Term := obj [("role", b "user"), ("content", b placeholderTurn)]

/-- The assistant turn between an Anthropic system message and a following
user turn: a system message must precede an assistant turn. -/
def systemReply : Term := obj [("role", b "assistant"), ("content", b "[Noted.]")]

/-- A runtime message whose content comes from outside the runtime: a tool
result, retrieved knowledge, provider context, or labelled source content. -/
def untrusted (m : Term) : Bool :=
  openaiRole m == b "runtime" &&
    (member (field m "type") ["tool_call_completed", "tool_call_failed", "tool_call_handoff", "project_knowledge"] ||
      field m "content_kind" == b "model_context" || (field m "ifc").isMap)

/-- An Anthropic system message: a system-authored message that is not `untrusted`. -/
def systemMessage (m : Term) : Bool :=
  member (openaiRole m) ["system", "summary", "runtime"] && !untrusted m

/-- A message that Anthropic sends in a user turn. -/
def userTurn (m : Term) : Bool :=
  member (openaiRole m) ["user", "tool"] || untrusted m

def conversationTurn (m : Term) : KernelM Bool := do
  let role := openaiRole m
  if member role ["user", "tool", "provider_context"] then return true
  if role != b "assistant" then return false
  return !(items (field m "tool_calls")).isEmpty || !missing (← str (coalesce [field m "content", b ""]))

/-- Replace system-authored messages after the leading context run with
synthetic calls. A runtime message that arrives while
a tool batch still waits for results follows that batch, so every call keeps
its results adjacent. Blank system-authored messages are dropped. Without a
conversation turn, a placeholder user turn follows the leading context.
Responses (`reminders := false`) converts only runtime messages. -/
def syntheticRuntime (messages : List Term) (reminders : Bool := true) (system : Bool := false) :
    KernelM (List Term) := do
  let leading := messages.takeWhile (fun m => member (openaiRole m) ["system", "summary", "runtime"])
  let rest := messages.drop leading.length
  let mut out := leading.reverse
  let mut queued : List Term := []
  let mut pending : List Term := []
  let mut seen : Std.HashSet ByteArray := {}
  let mut turn := false
  let mut calls := false
  for m in rest do
    let role := openaiRole m
    -- Anthropic: a system message follows a user turn and precedes an assistant turn.
    -- An assistant message without text or calls sends nothing.
    let shown := out.dropWhile fun x => openaiRole x == b "assistant" &&
      (items (field x "tool_calls")).isEmpty && missing (field x "content")
    -- The loop has sent a message after the leading run.
    let opened := turn || calls
    let after := opened && systemMessage (shown.headD nil)
    if member role ["system", "summary", "runtime"] && (reminders || role == b "runtime") then
      let reminder := role != b "runtime"
      if reminder && (← Content.systemText m) == b "" then continue
      if system then
        calls := true
        if pending.isEmpty then
          if systemMessage m && !(opened && (userTurn (shown.headD nil) || after)) then
            out := m :: placeholderUser :: out
            turn := true
          else if untrusted m && after then out := m :: systemReply :: out
          else out := m :: out
        else if untrusted m && systemMessage (queued.headD nil) then queued := m :: systemReply :: queued
        else queued := m :: queued
        continue
      let m ← if reminder then asReminder m else pure m
      let (id, next) := claimId seen (bytes (← runtimeCallId m))
      seen := next
      let pair := (← runtimeCall m (.binary id) reminder).reverse
      calls := true
      if pending.isEmpty then out := pair ++ out else queued := pair ++ queued
      continue
    if system && member role ["user", "tool"] && after then out := systemReply :: out
    if ← conversationTurn m then turn := true
    if role == b "tool" then
      out := m :: out
      pending := pending.filter (· != callId m)
      if pending.isEmpty then
        out := queued ++ out
        queued := []
    else if role == b "assistant" then
      out := m :: (queued ++ out)
      queued := []
      pending := (items (field m "tool_calls")).map (callField · "id")
    else if pending.isEmpty then
      out := m :: (queued ++ out)
      queued := []
    else out := m :: out
  let result := (queued ++ out).reverse
  if turn || !reminders then return result
  let hasContext := (← leading.mapM Content.systemText).any (· != b "")
  if !hasContext && !calls then return result
  let placeholder := obj [("role", b "user"), ("content", b placeholderTurn)]
  return leading ++ placeholder :: result.drop leading.length

def thinking (blocks : List Term) : List Term := blocks.filter (fun v => v.isMap && member (get v "type") ["thinking", "redacted_thinking"])

-- Every projection reads the role as `openaiRole`, the role that pairs calls with results.
def anthropicMessage (m model : Term) : KernelM (List (Bool × Term)) := do
  let role := openaiRole m
  if member role ["system", "summary", "runtime"] then
    let text ← Content.systemText m
    if text == b "" then return []
    if untrusted m then return [(false, obj [("role", b "user"), ("content", text)])]
    return [(role != b "runtime", obj [("role", b "system"), ("content", text)])]
  if role == b "user" then
    return [(false, obj [("role", role), ("content", ← Content.inputTime m (← Content.convert "anthropic" m))])]
  let trailing := field m "runtime_trailing" == Term.bool true
  if role == b "tool" then
    return [(trailing, obj [("role", b "user"), ("content", list [obj [("type", b "tool_result"),
      ("tool_use_id", callId m), ("content", ← Content.convert "anthropic" m)]])])]
  if role != b "assistant" then return []
  let text ← str (coalesce [field m "content", b ""])
  let textBlocks := if missing text then [] else [obj [("type", b "text"), ("text", text)]]
  let calls := (items (field m "tool_calls")).map fun c =>
    obj [("type", b "tool_use"), ("id", callField c "id"), ("name", callField c "name"), ("input", coalesce [callField c "args", empty])]
  if textBlocks.isEmpty && calls.isEmpty then return []
  let metadata := field m "provider_meta"
  let recorded := coalesce [get metadata "anthropic_thinking_model", metadata.get (a "anthropic_thinking_model")]
  let blocks := if recorded.isBinary && model.isBinary && recorded != model then [] else
    thinking (wrap (coalesce [get metadata "anthropic_thinking", metadata.get (a "anthropic_thinking")]))
  return [(trailing, obj [("role", role), ("content", list (blocks ++ textBlocks ++ calls))])]

def adjacentAnthropic (tagged : List (Bool × Term)) : List (Bool × Term) := Id.run do
  let mut out := []
  let mut held := []
  let mut pending : List Term := []
  for item in tagged do
    let m := item.2
    let blocks := items (get m "content")
    let first := blocks.headD nil
    let isResult := get first "type" == b "tool_result"
    let id := if isResult then get first "tool_use_id" else nil
    if id != nil && pending.contains id then
      out := item :: out
      pending := pending.filter (· != id)
    else if !pending.isEmpty && !isResult && get m "role" != b "assistant" then
      held := item :: held
    else
      out := item :: (held ++ out)
      held := []
      pending := if get m "role" == b "assistant" then
        blocks.filterMap (fun c => if get c "type" == b "tool_use" && c.has (b "id") then some (get c "id") else none)
        else []
  return (held ++ out).reverse

def anthropicParts (messages : List Term) (model : Term) : KernelM Term := do
  let messages ← syntheticRuntime messages true true
  let leading := messages.takeWhile (fun m => member (openaiRole m) ["system", "summary", "runtime"])
  let rest := messages.drop leading.length
  let texts := (← leading.mapM Content.systemText).filter (· != b "")
  let system ← if texts.isEmpty then pure nil else join texts "\n\n"
  let tagged := adjacentAnthropic ((← rest.mapM (anthropicMessage · model)).flatten)
  let trailing := (tagged.reverse.takeWhile Prod.fst).length
  return .tuple [system, list (tagged.map Prod.snd), i trailing]

def chatMessage (m model : Term) : KernelM (List Term) := do
  let role := openaiRole m
  if member role ["system", "summary", "runtime"] then
    let text ← Content.systemText m
    if text == b "" then return [] else return [← context text]
  if role == b "user" then
    return [obj [("role", role), ("content", ← Content.inputTime m (← Content.convert "chat" m))]]
  if role != b "assistant" then return []
  let calls ← (items (field m "tool_calls")).mapM fun c => do
    return obj [("id", callField c "id"), ("type", b "function"), ("function",
      obj [("name", callField c "name"), ("arguments", ← encode (coalesce [callField c "args", empty]))])]
  let mModel := field m "model"
  let metadata := field m "provider_meta"
  let extra := if mModel.isBinary && model.isBinary && mModel != model then empty else
    select (coalesce [get metadata "chat_message_extra", metadata.get (a "chat_message_extra")]) reasoningFields true
  let base := obj [("role", role), ("content", ← str (coalesce [field m "content", b ""]))]
  return [mergeMaps (if calls.isEmpty then base else base.put (b "tool_calls") (list calls)) extra]

-- Valid provider IDs are binary. Keep legacy/non-binary equality intact without
-- changing Term's global hashing contract; those uncommon keys share a bucket.
-- Keys compare in both directions, so the maps see an equivalence relation.
-- This is `==` on every term with unique map keys.
structure CallKey where
  value : Term

instance : BEq CallKey where
  beq x y := x.value == y.value && y.value == x.value

instance : Hashable CallKey where
  hash key := match key.value with | .binary raw => hash raw | _ => 0

abbrev CallMap (α : Type) := Std.HashMap CallKey α

def chatTool (m : Term) (names : CallMap Term) : KernelM (Term × List Term) := do
  let content ← str (coalesce [field m "content", b ""])
  let id := callId m
  let mut summary := content
  let mut vision := []
  if field m "native_content_trusted" == a "true" && (bytes content)[0]?.getD 0 == 91 then
    if let some (.list blocks) := decode content then
      let converted := (← blocks.mapM (Content.block "chat")).flatten
      let images := converted.filter (fun x => get x "type" == b "image_url")
      let text ← join ((converted.filter (fun x => get x "type" == b "text")).map (get · "text")) "\n"
      if !images.isEmpty then
        summary := if missing text then b "[Image tool result]" else text
        let name := names.getD ⟨id⟩ nil
        let name := if name.isBinary && !missing name then name else b "tool"
        let header ← cat [b "<tool-result-vision tool=\"", name, b "\" call_id=\"", id,
          b "\">This is system-generated context from the ", name,
          b " tool result, not a new user request. Use the image below to answer the prior user request.</tool-result-vision>"]
        vision := [obj [("role", b "user"), ("content", list (obj [("type", b "text"), ("text", header)] :: images))]]
      else if !blocks.isEmpty && blocks.all (Content.knownBlock false) then summary := text
  return (obj [("role", b "tool"), ("tool_call_id", id), ("content", summary)], vision)

def adjacentChat (chat : List Term) : KernelM (List Term) := do
  -- Provider IDs can recur in later rounds. Bind each result to the most recent
  -- preceding invocation of that ID, not to the first result in the transcript.
  -- Runtime context and calls with other IDs do not end an invocation's scope.
  let mut owners : CallMap Nat := {}
  -- Index by transcript position directly; a Term map would linearly scan all rounds.
  let mut results : Array (CallMap Term) := Array.replicate chat.length {}
  let mut unclaimed : Std.HashSet Nat := {}
  for (m, index) in chat.zipIdx do
    if get m "role" == b "assistant" then
      for c in items (get m "tool_calls") do
        owners := owners.insert ⟨get c "id"⟩ index
    else if get m "role" == b "tool" && m.has (b "tool_call_id") then
      let id := get m "tool_call_id"
      if let some owner := owners.get? ⟨id⟩ then
        if !(results[owner]!).contains ⟨id⟩ then
          results := results.modify owner (fun entries => entries.insert ⟨id⟩ m)
      else unclaimed := unclaimed.insert index
  let mut out := []
  for (m, index) in chat.zipIdx do
    let calls := items (get m "tool_calls")
    if get m "role" == b "assistant" && !calls.isEmpty then
      out := m :: out
      for c in calls do
        let id := get c "id"
        let value := coalesce [results[index]!.getD ⟨id⟩ nil, obj [("role", b "tool"), ("tool_call_id", id), ("content", b "{\"status\":\"no_result_recorded\"}")]]
        out := value :: out
    else if get m "role" == b "tool" && m.has (b "tool_call_id") then
      let id := get m "tool_call_id"
      if unclaimed.contains index then
        out := (← context (← cat [b "<unclaimed-tool-result call_id=\"", id, b "\">\n", get m "content", b "\n</unclaimed-tool-result>"])) :: out
    else out := m :: out
  -- Thinking-mode providers want `reasoning_content` on every assistant message,
  -- and DeepSeek rejects a null one with HTTP 400. An empty value for an assistant
  -- without one keeps each message independent of later messages, so a longer
  -- history keeps the earlier request as a prefix.
  return out.reverse.map fun m =>
    if get m "role" == b "assistant" && !m.has (b "reasoning_content") then m.put (b "reasoning_content") (b "") else m

def putField (m : Term) (key : String) (value : Term) : Term :=
  (removeKey m (a key)).put (b key) value

-- Only the outbound copy changes: persisted IDs still identify runtime calls.
-- Each message depends only on the messages before it, so a later message never
-- renames an earlier call and the cached prefix holds.

/-- The wire ids of the chat calls so far. -/
structure WireIds where
  /-- Every wire id of a call. -/
  issued : Std.HashSet CallKey := {}
  /-- The wire ids of the calls of each provider id that wait for a result, newest first. -/
  waiting : CallMap (List Term) := {}
  /-- The newest wire id of each provider id. -/
  latest : CallMap Term := {}
  /-- The next suffix to try. -/
  suffix : Nat := 2

/-- The first `id__n`, from `n` on, that no call uses. The candidates differ and outnumber the
issued ids, so the fuel does not run out. -/
def freeWireId (issued : Std.HashSet CallKey) (id : Term) : Nat → Nat → KernelM (Term × Nat)
  | _, 0 => fail "invalid_term"
  | n, fuel + 1 => do
    let wireId ← cat [id, b "__", b (toString n)]
    if issued.contains ⟨wireId⟩ then freeWireId issued id (n + 1) fuel else pure (wireId, n + 1)

/-- The wire id of one call. A provider id that a call already uses takes a free suffix. -/
def wireCall (ids : WireIds) (c : Term) : KernelM (WireIds × Term) := do
  let id := callField c "id"
  let (wireId, suffix) ← if ids.issued.contains ⟨id⟩ then
      freeWireId ids.issued id ids.suffix (ids.issued.size + 1) else pure (id, ids.suffix)
  return (WireIds.mk (ids.issued.insert ⟨wireId⟩)
    (ids.waiting.insert ⟨id⟩ (wireId :: ids.waiting.getD ⟨id⟩ [])) (ids.latest.insert ⟨id⟩ wireId) suffix, wireId)

/-- One call of an assistant message, with the renamed ids and the calls so far (newest first). -/
def wireCallStep (r : WireIds × CallMap Term × List Term) (c : Term) :
    KernelM (WireIds × CallMap Term × List Term) := do
  let (ids, wireId) ← wireCall r.1 c
  return (ids, r.2.1.insert ⟨callField c "id"⟩ wireId, putField c "id" wireId :: r.2.2)

/-- An assistant message with its calls at their wire ids. Reasoning details follow the calls. -/
def withWireCalls (m : Term) (calls : List Term) (renamed : CallMap Term) : Term :=
  if calls.isEmpty then m else
  let m := putField m "tool_calls" (list calls)
  let metadata := field m "provider_meta"
  let extra := field metadata "chat_message_extra"
  let details := get extra "reasoning_details"
  if !details.isList then m else
  let details := (items details).map fun detail =>
    match renamed.get? ⟨get detail "id"⟩ with
    | some wireId => detail.put (b "id") wireId
    | none => detail
  putField m "provider_meta" (putField metadata "chat_message_extra"
    (extra.put (b "reasoning_details") (list details)))

/-- One message at its wire ids. A result answers the newest waiting call with its id. A repeated
result keeps the newest call of its id. Another result keeps its id unless a call uses it. -/
def wireMessage (ids : WireIds) (m : Term) : KernelM (WireIds × Term) := do
  if openaiRole m == b "assistant" then
    let (ids, renamed, calls) ← (items (field m "tool_calls")).foldlM wireCallStep (ids, {}, [])
    return (ids, withWireCalls m calls.reverse renamed)
  if openaiRole m != b "tool" then return (ids, m)
  let id := callId m
  match ids.waiting.getD ⟨id⟩ [] with
  | wireId :: rest =>
    return ({ ids with waiting := ids.waiting.insert ⟨id⟩ rest }, putField m "tool_call_id" wireId)
  | [] =>
    if let some wireId := ids.latest.get? ⟨id⟩ then return (ids, putField m "tool_call_id" wireId)
    if !ids.issued.contains ⟨id⟩ then return (ids, m)
    let (wireId, suffix) ← freeWireId ids.issued id ids.suffix (ids.issued.size + 1)
    return ({ ids with suffix := suffix }, putField m "tool_call_id" wireId)

/-- One message of `wireMessages`, with the output so far (newest first). -/
def wireStep (r : WireIds × List Term) (m : Term) : KernelM (WireIds × List Term) := do
  let (ids, m) ← wireMessage r.1 m
  return (ids, m :: r.2)

-- A fold, not recursion: a long history must not grow the native stack.
def wireMessages (ids : WireIds) (messages : List Term) : KernelM (WireIds × List Term) := do
  let (ids, out) ← messages.foldlM wireStep (ids, [])
  return (ids, out.reverse)

def uniqueChatCallIds (messages : List Term) : KernelM (List Term) :=
  return (← wireMessages {} messages).2

def chat (messages : List Term) (model : Term) : KernelM Term := do
  let messages ← uniqueChatCallIds (← syntheticRuntime messages)
  let mut names : CallMap Term := {}
  let leading := messages.takeWhile (fun m => member (openaiRole m) ["system", "summary", "runtime"])
  let mut out := []
  let mut pending := []
  -- The calls of the latest assistant message that have no result yet.
  let mut waiting : List Term := []
  for m in messages.drop leading.length do
    if openaiRole m == b "assistant" then
      for c in items (field m "tool_calls") do names := names.insert ⟨callField c "id"⟩ (callField c "name")
    if openaiRole m == b "tool" then
      let (msg, vision) ← chatTool m names
      out := msg :: out
      pending := vision.reverse ++ pending
      -- Images follow the last result of their batch. Releasing them there, not at the next
      -- message, keeps a later message from moving them.
      waiting := waiting.filter (· != callId m)
      if waiting.isEmpty then
        out := pending ++ out
        pending := []
    else
      out := (← chatMessage m model).reverse ++ pending ++ out
      pending := []
      if openaiRole m == b "assistant" then waiting := (items (field m "tool_calls")).map (callField · "id")
  let texts := (← leading.mapM Content.systemText).filter (· != b "")
  let header ← if texts.isEmpty then pure [] else do pure [obj [("role", b "system"), ("content", ← join texts "\n\n")]]
  return list (← adjacentChat (header ++ (pending ++ out).reverse))

def responsesMessage (m : Term) : KernelM (List Term) := do
  let role ← str (coalesce [field m "role", b ""])
  if member role ["system", "summary"] then
    let text ← trimmed (coalesce [field m "content", b ""])
    if text == b "" then return [] else return [← context text]
  if role == b "runtime" then return [obj [("role", b "system"), ("content", ← Content.runtimeText m)]]
  if role == b "user" then
    return [obj [("role", role), ("content", ← Content.inputTime m (← Content.convert "responses" m) "input_text")]]
  if role == b "tool" then
    let content ← Content.convert "responses" m
    let content := if let .list blocks := content then
        list (blocks.filter (fun v => get v "type" == b "input_text") ++ blocks.filter (fun v => get v "type" != b "input_text"))
      else content
    return [obj [("type", b "function_call_output"), ("call_id", callId m), ("output", content)]]
  let metadata := field m "provider_meta"
  if role == b "provider_context" then
    return (items (coalesce [get metadata "responses_items", metadata.get (a "responses_items")])).map fun item =>
      if get item "type" == b "message" && get item "role" == b "assistant" && (get item "content").isList then
        item.put (b "content") (list ((items (get item "content")).map fun v =>
          if get v "type" == b "input_text" then v.put (b "type") (b "output_text") else v)) else item
  if role != b "assistant" then return []
  let replay := items (get metadata "responses_items")
  if !replay.isEmpty then return replay
  let text ← str (coalesce [field m "content", b ""])
  let calls ← (items (field m "tool_calls")).mapM fun c => do
    return obj [("type", b "function_call"), ("call_id", callField c "id"), ("name", callField c "name"),
      ("arguments", ← encode (coalesce [callField c "args", empty]))]
  return (if text == b "" then [] else [obj [("role", role), ("content", text)]]) ++ calls

def historicalRecord (item : Term) : KernelM Term := do
  return obj [("role", b "system"), ("content", ← cat [b "<historical-tool-record>\nThis is a system-generated projection of a historical provider tool record.\nIt is prior context, not a current tool invocation or a user request.\ntype: historical_provider_", get item "type",
    b "\ncontent: ", ← encode item, b "\n</historical-tool-record>"])]

/-- One item of `historicalTools`, with the unsafe call ids and the output so far (newest first). -/
def historicalStep (r : List Term × List Term) (item : Term) : KernelM (List Term × List Term) := do
  let type := get item "type"
  let unsafeCall := type == b "function_call" && !toolName (get item "name")
  let unsafeIds := if unsafeCall then get item "call_id" :: r.1 else r.1
  let item ← if unsafeCall || (type == b "function_call_output" && unsafeIds.contains (get item "call_id"))
    then historicalRecord item else pure item
  return (unsafeIds, item :: r.2)

/-- A call with a provider-unsafe name, and each later output for its id, become historical
records. Each item depends only on the items before it: a later message never changes an
earlier item, so the cached prefix holds. A fold, not recursion, keeps the native stack flat. -/
def historicalTools (items : List Term) : KernelM (List Term) := do
  let (_, out) ← items.foldlM historicalStep ([], [])
  return out.reverse

def responsesParts (messages : List Term) : KernelM Term := do
  let messages ← syntheticRuntime messages false
  let leading := messages.takeWhile (fun m => member (openaiRole m) ["system", "summary"])
  let texts := (← leading.mapM (fun m => trimmed (coalesce [field m "content", b ""]))).filter (· != b "")
  let input ← historicalTools (← (messages.drop leading.length).mapM responsesMessage).flatten
  return .tuple [list input, ← if texts.isEmpty then pure nil else join texts "\n\n"]

end VerifiedKernel.Provider.Messages
