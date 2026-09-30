import VerifiedKernel.Provider.Stream
import VerifiedKernel.Order

namespace VerifiedKernel.Provider.Complete
open Data

def response (protocol : String) (resp model : Term) (compact := false) : KernelM Term := do
  if protocol == "anthropic" then
    if !resp.has (b "content") then return ← Error.state (b "anthropic") (b "failed") resp
    return Usage.attach (← Response.anthropic resp model) (Usage.anthropic (get resp "usage")) (coalesce [get resp "model", model])
  if (get resp "error").isMap then
    return ← Error.state (b (if protocol == "chat" then "openai_chat" else "openai_responses")) (b "failed") resp
  if protocol == "chat" then return Usage.attach (← Response.chat resp) (Usage.chat resp) model
  let err ← Response.responsesState resp
  if err != nil then return err
  let usage := Usage.responses (get resp "usage")
  let model := coalesce [get resp "model", model]
  if compact then return .tuple [a "ok", list (wrap (get resp "output")), obj [("usage", coalesce [usage, obj [("usage_reported", a "false")]]), ("model", model)]]
  return Usage.attach (← Response.responsesOutput (coalesce [get resp "output", list []])) usage model

-- HTTP completion alone does not establish completion of the model response.
private def chatCompletion (raw : ByteArray) (events : List Term) : Term := Id.run do
  let choices := events.flatMap (fun ev => items (get ev "choices"))
  if choices.any (fun c => get c "finish_reason" == b "length") then
    return Error.permanent "openai_chat" "output_token_limit"
  let (lines, rest) := Stream.splitLines raw
  let payloads := (lines ++ [rest]).filterMap Stream.dataPayload
  let invalid := payloads.any fun payload =>
    payload != "[DONE]".toUTF8 && !(match Json.decode payload with | some v => v.isMap | none => false)
  let done := payloads.contains "[DONE]".toUTF8 ||
    choices.any (fun c => member (get c "finish_reason") ["stop", "tool_calls", "function_call", "content_filter"])
  if invalid || !done then return Error.transport (b "openai_chat") (b "incomplete_stream")
  return nil

private def chatStream (events : List Term) (model : Term) : KernelM Term := do
  let deltas := (events.map (fun ev => get ((items (get ev "choices")).headD nil) "delta")).filter Term.isMap
  let text ← join ((deltas.map (get · "content")).filter Term.isBinary)
  let mut calls := empty
  for fragment in deltas.flatMap (fun v => items (get v "tool_calls")) do
    let idx := coalesce [get fragment "index", i 0]
    let f := get fragment "function"
    let old := calls.get idx
    calls := calls.put idx (host [("id", coalesce [field old "id", get fragment "id"]),
      ("name", coalesce [field old "name", get f "name"]),
      ("args_json", ← cat [coalesce [field old "args_json", b ""], coalesce [get f "arguments", b ""]])])
  let ordered ← sortedKeys ((← entries calls).map Prod.fst)
  let mut projectedCalls := []
  for idx in ordered do
    let c := calls.get idx
    let some value := Response.args (field c "args_json") | return Error.permanent "openai_chat" "invalid_tool_arguments"
    projectedCalls := host [("id", field c "id"), ("name", field c "name"), ("args", value)] :: projectedCalls
  let usage := (events.find? (fun v => ["usage", "usageMetadata", "usage_metadata"].any (fun key => (get v key).isMap))).getD nil
  return Usage.attach (result text projectedCalls.reverse (← Response.chatDeltaMetadata deltas)) (Usage.chat usage) model

private def anthropicStream (events : List Term) (model : Term) : KernelM Term := do
  let mut blocks := empty
  let mut order := []
  let mut stop := nil
  let mut usage := nil
  let mut responseModel := nil
  for ev in events do
    let type := get ev "type"
    if type == b "error" then
      let err := if (get ev "error").isMap then get ev "error" else ev
      let status := obj [("invalid_request_error", i 400), ("authentication_error", i 401), ("billing_error", i 400),
        ("permission_error", i 403), ("not_found_error", i 404), ("request_too_large", i 413),
        ("rate_limit_error", i 429), ("timeout_error", i 408), ("api_error", i 500), ("overloaded_error", i 529)]
      return ← Error.http (b "anthropic") (coalesce [status.get (get err "type"), i 500]) (← encode err)
    if type == b "content_block_start" then
      let idx := get ev "index"
      let block := get ev "content_block"
      let type := get block "type"
      let seed := if type == b "text" then obj [("type", type), ("text", coalesce [get block "text", b ""])]
        else if type == b "tool_use" then obj [("type", type), ("id", get block "id"), ("name", get block "name"), ("_json", b "")]
        else if type == b "thinking" then obj [("type", type), ("thinking", coalesce [get block "thinking", b ""]), ("signature", coalesce [get block "signature", b ""])]
        else if type == b "redacted_thinking" then obj [("type", type), ("data", coalesce [get block "data", b ""])]
        else obj [("type", type)]
      blocks := blocks.put idx seed
      order := idx :: order
    else if type == b "content_block_delta" then
      let idx := get ev "index"
      let d := get ev "delta"
      let type := get d "type"
      if !blocks.has idx then continue
      let (source, target) := if type == b "text_delta" then ("text", "text")
        else if type == b "input_json_delta" then ("partial_json", "_json")
        else if type == b "thinking_delta" then ("thinking", "thinking")
        else if type == b "signature_delta" then ("signature", "signature") else ("", "")
      let fragment := get d source
      if source == "" || !fragment.isBinary then continue
      let old := blocks.get idx
      let value ← if target == "signature" then pure fragment else cat [coalesce [get old target, b ""], fragment]
      blocks := blocks.put idx (old.put (b target) value)
    else if type == b "message_delta" then
      stop := coalesce [get (get ev "delta") "stop_reason", stop]
      if (get ev "usage").isMap then usage := mergeMaps (coalesce [usage, empty]) (get ev "usage")
    else if type == b "message_start" then
      let m := get ev "message"
      responseModel := coalesce [get m "model", responseModel]
      if (get m "usage").isMap then usage := mergeMaps (coalesce [usage, empty]) (get m "usage")
  let mut content := []
  for idx in order.reverse do
    let block := blocks.get idx
    if get block "type" == b "tool_use" then
      let json := get block "_json"
      let decoded := if json == nil || json == b "" then some empty else decode json
      let value := decoded.getD nil
      if !value.isMap then
        let detail ← cat [b "streamed tool_use ", b (Inspect.render (get block "name")), b " arguments did not complete: ", ← encode json]
        return ← Error.state (b "anthropic") (b "incomplete") detail
      content := (removeKey block (b "_json")).put (b "input") value :: content
    else content := block :: content
  let resp := obj [("content", list content.reverse), ("stop_reason", stop), ("usage", usage), ("model", responseModel)]
  return Usage.attach (← Response.anthropic resp model) (Usage.anthropic usage) responseModel

private def itemKey (item : Term) : Term :=
  coalesce [get item "item_id", get item "id", get item "output_index", get item "call_id",
    i (match item with | .map xs => xs.length | _ => 0)]

private def reconstruct (events : List Term) : KernelM Term := do
  let text ← join ((events.filter (fun v => get v "type" == b "response.output_text.delta")).map (fun ev => coalesce [get ev "delta", b ""]))
  let messages := events.filterMap fun ev =>
    let item := get ev "item"
    if get ev "type" == b "response.output_item.done" && get item "type" == b "message" then some item else none
  let textItems := if messages.isEmpty && text != b "" then
    [obj [("type", b "message"), ("content", list [obj [("type", b "output_text"), ("text", text)]])]] else []
  let mut calls := empty
  for ev in events do
    let item := get ev "item"
    let type := get ev "type"
    if member type ["response.output_item.added", "response.output_item.done"] && get item "type" == b "function_call" then
      let key := itemKey item
      let old := calls.get key
      let mut next := obj [("call_id", coalesce [get item "call_id", get item "id"]), ("name", get item "name"), ("arguments", coalesce [get item "arguments", b ""])]
      if old.isMap then
        next := obj (["call_id", "name", "arguments"].map fun k =>
          let v := get next k
          (k, if (k == "arguments" && (v == nil || v == b "")) || !v.truthy then get old k else v))
      calls := calls.put key next
    else if type == b "response.function_call_arguments.delta" then
      let key := itemKey ev
      let old := calls.get key
      let next := (if old.isMap then old else empty).put (b "call_id") (coalesce [get old "call_id", get ev "call_id"])
      calls := calls.put key (next.put (b "arguments") (← cat [coalesce [get old "arguments", b ""], coalesce [get ev "delta", b ""]]))
  let ordered ← sortedKeys ((← entries calls).map Prod.fst)
  let projectedCalls := ordered.map fun key =>
    let c := calls.get key
    c.put (b "type") (b "function_call") |>.put (b "arguments") (coalesce [get c "arguments", b ""])
  return list (messages ++ textItems ++ projectedCalls)

def stream (protocol : String) (raw : ByteArray) (model : Term) : KernelM Term := do
  let events := Stream.events raw
  if protocol == "anthropic" then return ← anthropicStream events model
  if events.isEmpty then
    if let some resp := Json.decode raw then return ← response protocol resp model
    if protocol == "chat" then return Error.transport (b "openai_chat") (b "incomplete_stream")
    return Error.transport (b "openai_responses") (a "invalid_response_body")
  let streamError := events.find? (fun ev => get ev "type" == b "error" || (get ev "error").isMap)
  if let some error := streamError then
    return ← Error.state (b (if protocol == "chat" then "openai_chat" else "openai_responses")) (b "failed") error
  if protocol == "chat" then
    let completion := chatCompletion raw events
    if completion != nil then return completion
    return ← chatStream events model
  let terminal := (events.find? (fun v => member (get v "type") ["response.completed", "response.incomplete", "response.failed"] && (get v "response").isMap)).getD nil
  let resp := coalesce [get terminal "response", empty]
  let output ← if !(items (get resp "output")).isEmpty then pure (get resp "output") else reconstruct events
  return ← response "responses" (resp.put (b "output") output) model

end VerifiedKernel.Provider.Complete
