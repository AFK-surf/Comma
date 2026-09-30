import VerifiedKernel.Provider.Messages
import VerifiedKernel.Provider.Error

namespace VerifiedKernel.Provider.Response
open Data

def chatMetadata (m : Term) : Term :=
  let extra := select m Messages.reasoningFields true
  if extra == empty then empty else obj [("chat_message_extra", extra)]

def chatDeltaMetadata (deltas : List Term) : KernelM Term := do
  let mut extra := empty
  for key in Messages.reasoningFields do
    let values := (deltas.map (get · key)).filter (· != nil)
    if values.isEmpty then continue
    if key == "reasoning_details" then
      let arrays := values.filter Term.isList
      if arrays.isEmpty then continue
      let mut merged : List Term := []
      for incoming in (arrays.flatMap items).filter Term.isMap do
        let current := merged.headD nil
        let type := get incoming "type"
        if get current "type" == type && member type ["reasoning.text", "reasoning.summary"] then
          let k := if type == b "reasoning.text" then "text" else "summary"
          let fragment := fun m => let text := get m k; if text.isBinary then text else b ""
          let mut next := current.put (b k) (← cat [fragment current, fragment incoming])
          for name in (if k == "text" then ["signature", "format"] else ["format"]) do
            let old := get current name
            let new := get incoming name
            if !(old.isBinary && !missing old) && new.isBinary && !missing new then next := next.put (b name) new
          merged := next :: merged.tail
        else merged := incoming :: merged
      extra := extra.put (b key) (list merged.reverse)
    else if key == "thought_signature" then
      if let some value := (values.filter nonempty).getLast? then extra := extra.put (b key) value
    else
      let value ← if values.all Term.isBinary then join values else
        pure (if values.all Term.isList then list (values.flatMap items) else values.getLast!)
      extra := extra.put (b key) value
  return if extra == empty then empty else obj [("chat_message_extra", extra)]

def args (v : Term) : Option Term :=
  let decoded := if v.isMap then some v else if v == nil || v == b "" then some empty else decode v
  match decoded with | some m => if m.isMap then some m else none | none => none

def chat (resp : Term) : KernelM Term := do
  let choice := (items (get resp "choices")).headD nil
  let m := get choice "message"
  let text ← str (coalesce [get m "content", b ""])
  let mut calls := []
  for c in items (get m "tool_calls") do
    let f := get c "function"
    let some value := args (get f "arguments") | return Error.permanent "openai_chat" "invalid_tool_arguments"
    calls := host [("id", get c "id"), ("name", get f "name"), ("args", value)] :: calls
  return result text calls.reverse (chatMetadata m) (get choice "finish_reason" == b "tool_calls")

def anthropic (resp model : Term) : KernelM Term := do
  let content := items (get resp "content")
  let text ← join ((content.filter (fun v => get v "type" == b "text")).map (get · "text"))
  if get resp "stop_reason" == b "refusal" then
    let details := obj [("stop_reason", b "refusal"), ("stop_details", get resp "stop_details"), ("partial_text", text)]
    return .tuple [a "error", (Error.base (b "anthropic") (b "provider_refusal") (b "LLM provider declined to answer the request")).put (b "details") (Error.preview details)]
  let calls := (content.filter (fun v => get v "type" == b "tool_use")).map fun c =>
    host [("id", get c "id"), ("name", get c "name"), ("args", coalesce [get c "input", empty])]
  let blocks := Messages.thinking content
  let metadata := if blocks.isEmpty then empty else
    putOptional (obj [("anthropic_thinking", list blocks)]) "anthropic_thinking_model" (if nonempty model then model else nil)
  return result text calls metadata (get resp "stop_reason" == b "tool_use")

def responses (resp : Term) : KernelM Term := do
  let output := items (get resp "output")
  let blocks := (output.filter (fun v => get v "type" == b "message")).flatMap (fun v => items (get v "content"))
  let text ← join ((blocks.filter (fun v => member (get v "type") ["output_text", "text"])).map (get · "text"))
  let mut calls := []
  for c in output do
    if get c "type" == b "function_call" then
      let raw := get c "arguments"
      let decoded := if raw.isMap then some raw else decode raw
      let some value := decoded | return Error.permanent "openai_responses" "invalid_tool_arguments"
      if !value.isMap then return Error.permanent "openai_responses" "invalid_tool_arguments"
      calls := host [("id", get c "call_id"), ("name", get c "name"), ("args", value)] :: calls
  return result text calls.reverse

def responsesState (resp : Term) : KernelM Term := do
  let status := get resp "status"
  let details := coalesce [get resp "incomplete_details", get resp "error", resp]
  let err ← Error.state (b "openai_responses") status details
  let text := (String.fromUTF8! (bytes (Error.preview details))).toLower
  if status == b "incomplete" && !Error.overflow details && (text.contains "max_output" || text.contains "output token") then
    return if (items (get resp "output")).any (fun v => get v "type" == b "function_call") then
      Error.permanent "openai_responses" "output_token_limit" else nil
  return err

def responsesOutput (output : Term) : KernelM Term := do
  if output == list [] then return Error.transport (b "openai_responses") (a "empty_response_output")
  if !output.isList then return Error.transport (b "openai_responses") (a "invalid_response_output")
  let parsed ← responses (obj [("output", output)])
  match parsed with
  | .tuple [.atom "assistant", text, calls] => return .tuple [a "assistant", text, calls, obj [("responses_items", output)]]
  | .tuple [.atom "final", text] =>
    return if (items output).any (fun v => member (get v "type") ["compaction", "reasoning"]) then
      .tuple [a "final", text, obj [("responses_items", output)], empty] else parsed
  | _ => return parsed

end VerifiedKernel.Provider.Response
