import VerifiedKernel.Provider.Content
import Std.Data.HashMap.Basic

namespace VerifiedKernel.Provider.Messages
open Data

def context (text : Term) : KernelM Term := do
  return obj [("role", b "user"), ("content", ← cat [b "<system>\n", text, b "\n</system>"])]

@[inline] def callField (c : Term) (key : String) : Term := coalesce [get c key, c.get (a key)]
def callId (m : Term) : Term := coalesce [field m "tool_call_id", field m "tool_use_id"]
private def openaiRole (m : Term) : Term :=
  match field m "role" with | .atom name => b name | value => value
def reasoningFields : List String := ["reasoning_content", "reasoning", "reasoning_details", "thought", "thoughts", "thought_signature", "thought_signatures"]
def thinking (blocks : List Term) : List Term := blocks.filter (fun v => v.isMap && member (get v "type") ["thinking", "redacted_thinking"])

def anthropicMessage (m model : Term) : KernelM (List (Bool × Term)) := do
  let role := field m "role"
  if member role ["system", "summary", "runtime"] then
    let text ← Content.systemText m
    if text == b "" then return []
    return [(role != b "runtime" || field m "type" == b "project_knowledge", ← context text)]
  if role == b "user" then
    return [(false, obj [("role", role), ("content", ← Content.inputTime m (← Content.convert "anthropic" m))])]
  if role == b "tool" then
    return [(false, obj [("role", b "user"), ("content", list [obj [("type", b "tool_result"),
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
  return [(false, obj [("role", role), ("content", list (blocks ++ textBlocks ++ calls))])]

private def adjacentAnthropic (tagged : List (Bool × Term)) : List (Bool × Term) := Id.run do
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
  let leading := messages.takeWhile (fun m => member (field m "role") ["system", "summary", "runtime"])
  let mut rest := messages.drop leading.length
  let mut kept := leading.reverse
  for m in leading.reverse do
    if !(← rest.mapM (anthropicMessage · model)).flatten.isEmpty then break
    kept := kept.tail
    rest := m :: rest
  let texts := (← kept.reverse.mapM Content.systemText).filter (· != b "")
  let system ← if texts.isEmpty then pure nil else join texts "\n\n"
  let tagged := adjacentAnthropic ((← rest.mapM (anthropicMessage · model)).flatten)
  let trailing := (tagged.reverse.takeWhile Prod.fst).length
  return .tuple [system, list (tagged.map Prod.snd), i trailing]

def chatMessage (m model : Term) : KernelM (List Term) := do
  let role ← str (coalesce [field m "role", b ""])
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
private structure CallKey where
  value : Term
  deriving BEq

private instance : Hashable CallKey where
  hash key := match key.value with | .binary raw => hash raw | _ => 0

private abbrev CallMap (α : Type) := Std.HashMap CallKey α

private def chatTool (m : Term) (names : CallMap Term) : KernelM (Term × List Term) := do
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

private def adjacentChat (chat : List Term) : KernelM (List Term) := do
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
  out := out.reverse
  if !out.any (fun m => get m "role" == b "assistant" && m.has (b "reasoning_content")) then return out
  return out.map fun m => if get m "role" == b "assistant" && !m.has (b "reasoning_content") then m.put (b "reasoning_content") nil else m

private def putField (m : Term) (key : String) (value : Term) : Term :=
  (removeKey m (a key)).put (b key) value

-- Only the outbound copy changes: persisted IDs still identify runtime calls.
-- Reserve every original ID before suffixing, including IDs in later rounds.
private def uniqueChatCallIds (messages : List Term) : KernelM (List Term) := do
  let mut reserved : Std.HashSet CallKey := {}
  let mut originalCount := 0
  for m in messages do
    for c in items (field m "tool_calls") do
      reserved := reserved.insert ⟨callField c "id"⟩
      originalCount := originalCount + 1
    if openaiRole m == b "tool" then
      reserved := reserved.insert ⟨callId m⟩
      originalCount := originalCount + 1
  let mut active : CallMap Term := {}
  let mut suffix := 2
  let mut out := []
  for original in messages do
    let mut m := original
    if openaiRole m == b "assistant" then
      let mut calls := []
      let mut renamed : CallMap Term := {}
      for c in items (field m "tool_calls") do
        let id := callField c "id"
        let mut wireId := id
        if active.contains ⟨id⟩ then
          -- The global counter never repeats a generated suffix; only original
          -- IDs can collide, so one more candidate than their count suffices.
          for _ in [:originalCount + 1] do
            wireId ← cat [id, b "__", b (toString suffix)]
            suffix := suffix + 1
            if !reserved.contains ⟨wireId⟩ then break
        reserved := reserved.insert ⟨wireId⟩
        active := active.insert ⟨id⟩ wireId
        renamed := renamed.insert ⟨id⟩ wireId
        calls := putField c "id" wireId :: calls
      if !calls.isEmpty then
        m := putField m "tool_calls" (list calls.reverse)
        let metadata := field m "provider_meta"
        let extra := field metadata "chat_message_extra"
        let details := get extra "reasoning_details"
        if details.isList then
          let details := (items details).map fun detail =>
            let id := get detail "id"
            if let some wireId := renamed.get? ⟨id⟩ then detail.put (b "id") wireId else detail
          m := putField m "provider_meta" (putField metadata "chat_message_extra"
            (extra.put (b "reasoning_details") (list details)))
    else if openaiRole m == b "tool" then
      let id := callId m
      if let some wireId := active.get? ⟨id⟩ then m := putField m "tool_call_id" wireId
    out := m :: out
  return out.reverse

def chat (messages : List Term) (model : Term) : KernelM Term := do
  let messages ← uniqueChatCallIds messages
  let mut names : CallMap Term := {}
  let leading := messages.takeWhile (fun m => member (openaiRole m) ["system", "summary", "runtime"])
  let mut out := []
  let mut pending := []
  for m in messages.drop leading.length do
    if openaiRole m == b "assistant" then
      for c in items (field m "tool_calls") do names := names.insert ⟨callField c "id"⟩ (callField c "name")
    if openaiRole m == b "tool" then
      let (msg, vision) ← chatTool m names
      out := msg :: out
      pending := vision.reverse ++ pending
    else
      out := (← chatMessage m model).reverse ++ pending ++ out
      pending := []
  let texts := (← leading.mapM Content.systemText).filter (· != b "")
  let header ← if texts.isEmpty then pure [] else do pure [obj [("role", b "system"), ("content", ← join texts "\n\n")]]
  return list (← adjacentChat (header ++ (pending ++ out).reverse))

private def responsesMessage (m : Term) : KernelM (List Term) := do
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

def responsesParts (messages : List Term) (reminders : List Term := []) : KernelM Term := do
  let leading := messages.takeWhile (fun m => member (openaiRole m) ["system", "summary"])
  let texts := (← leading.mapM (fun m => trimmed (coalesce [field m "content", b ""]))).filter (· != b "")
  let input := (← (messages.drop leading.length).mapM responsesMessage).flatten
  let unsafeIds := (input.filter (fun v => get v "type" == b "function_call" && !toolName (get v "name"))).map (get · "call_id")
  let input ← input.mapM fun item => do
    let type := get item "type"
    if (type == b "function_call" && !toolName (get item "name")) ||
        (type == b "function_call_output" && unsafeIds.contains (get item "call_id")) then
      return obj [("role", b "system"), ("content", ← cat [b "<historical-tool-record>\nThis is a system-generated projection of a historical provider tool record.\nIt is prior context, not a current tool invocation or a user request.\ntype: historical_provider_", type,
        b "\ncontent: ", ← encode item, b "\n</historical-tool-record>"])]
    else return item
  -- Append trusted request reminders after extracting instructions and history.
  -- Later developer messages do not become implicit cache write boundaries.
  let tail ← reminders.mapM fun reminder => do
    let text ← trimmed (coalesce [field reminder "content", b ""])
    return (← context text).put (b "role") (b "developer")
  return .tuple [list (input ++ tail), ← if texts.isEmpty then pure nil else join texts "\n\n"]

end VerifiedKernel.Provider.Messages
