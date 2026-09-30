import VerifiedKernel.Provider.Response
import VerifiedKernel.Provider.Usage

namespace VerifiedKernel.Provider.Stream
open Data

def dataPayload (line : ByteArray) : Option ByteArray :=
  let line := trim line
  if line.extract 0 5 == "data:".toUTF8 then
    let raw := line.extract 5 line.size
    match String.fromUTF8? raw with
    | some text => some ((String.ofList (text.toList.dropWhile whitespace)).toUTF8)
    | none => some raw
  else none

def event (line : ByteArray) : Option Term := do
  let payload ← dataPayload line
  let value ← Json.decode payload
  if value.isMap then some value else none

def splitLines (raw : ByteArray) : List ByteArray × ByteArray := Id.run do
  let mut start := 0
  let mut lines := []
  for idx in [:raw.size] do
    if raw[idx]! == 10 then
      lines := raw.extract start idx :: lines
      start := idx + 1
  return (lines.reverse, raw.extract start raw.size)

def events (raw : ByteArray) : List Term :=
  let (lines, rest) := splitLines raw
  (lines ++ [rest]).filterMap event

private def keys (index item call : Term) : List Term :=
  [("output", index), ("item", item), ("call", call)].filterMap fun (kind, value) =>
    if (kind == "output" && (match value with | .integer n => n ≥ 0 | _ => false)) || nonempty value then
      some (.tuple [a kind, value]) else none

private def eventKeys (ev : Term) : List Term := keys (get ev "output_index") (get ev "item_id") (get ev "call_id")
private def resolvedKey (st : Term) (ks : List Term) : Term :=
  (ks.find? (field st "tool_names").has).getD (ks.headD nil)

private def emitTool (st ev fragment : Term) : List Term :=
  let ks := eventKeys ev
  let key := resolvedKey st ks
  if key == nil || !nonempty fragment || (items (field st "rejected")).contains key then [] else
    let name := coalesce (ks.map (field st "tool_names").get)
    [.tuple [a "tool", host [("index", coalesce [get ev "output_index", get ev "item_id", get ev "call_id", i 0]),
      ("id", get ev "call_id"), ("name", name), ("fragment", fragment)]]]

private def reject (st key : Term) : Term :=
  let rejected := items (field st "rejected")
  st.put (a "partial") nil |>.put (a "rejected") (list (if rejected.contains key then rejected else key :: rejected))

private def discard (st : Term) : Term :=
  let p := field st "partial"
  if p == nil then st else reject st (field p "key")

private def identity (ev : Term) : List Term :=
  ["output_index", "item_id", "call_id", "sequence_number"].map (get ev ·)

private def reconcile (st ev : Term) : Term × List Term :=
  let p := field st "partial"
  if p == nil then (st, emitTool st ev (get ev "delta")) else
  let decoded := (items (field p "decoded")).reverse.foldl (fun acc v => acc ++ bytes v) ByteArray.empty
  let fragment := get ev "delta"
  if identity (field p "event") == identity ev && field p "pending" == b "" && fragment.isBinary &&
      (bytes fragment).extract 0 decoded.size == decoded then
    let next := st.put (a "partial") nil
    (next, emitTool next ev (.binary ((bytes fragment).extract decoded.size (bytes fragment).size)))
  else (reject st (field p "key"), [])

private def delta (kind : String) (text : Term) : List Term :=
  if nonempty text then [.tuple [a kind, text]] else []

private def line (protocol : String) (st : Term) (raw : ByteArray) : Term × List Term := Id.run do
  let some ev := event raw | return (discard st, [])
  if protocol == "chat" then
    let d := get ((items (get ev "choices")).headD nil) "delta"
    let text := delta "text" (get d "content")
    let calls := (items (get d "tool_calls")).filterMap fun c =>
      let f := get c "function"
      let name := get f "name"
      let fragment := coalesce [get f "arguments", b ""]
      if c.isMap && (name != nil || fragment != b "") then
        some (.tuple [a "tool", host [("index", coalesce [get c "index", i 0]), ("id", get c "id"), ("name", name), ("fragment", fragment)]]) else none
    let reasoning := if nonempty (get d "reasoning_content") then get d "reasoning_content" else get d "reasoning"
    return (st, text ++ calls ++ delta "private_reasoning" reasoning)
  let type := get ev "type"
  if protocol == "anthropic" then
    let d := get ev "delta"
    let idx := get ev "index"
    if type == b "content_block_start" && get (get ev "content_block") "type" == b "tool_use" then
      return (st.put (a "tool_names") ((field st "tool_names").put idx (get (get ev "content_block") "name")), [])
    if type != b "content_block_delta" then return (st, [])
    if get d "type" == b "text_delta" then return (st, [.tuple [a "text", get d "text"]])
    if get d "type" == b "thinking_delta" then return (st, delta "private_reasoning" (get d "thinking"))
    if get d "type" == b "input_json_delta" then
      return (st, [.tuple [a "tool", host [("index", idx), ("id", nil), ("name", (field st "tool_names").get idx),
        ("fragment", coalesce [get d "partial_json", b ""])]]])
    return (st, [])
  if type == b "response.output_text.delta" && nonempty (get ev "delta") then return (st, delta "text" (get ev "delta"))
  if type == b "response.reasoning_summary_text.delta" && nonempty (get ev "delta") then return (st, delta "public_summary" (get ev "delta"))
  if type == b "response.output_item.added" && get (get ev "item") "type" == b "function_call" then
    let item := get ev "item"
    let name := get item "name"
    if !nonempty name then return (st, [])
    let names := (keys (get ev "output_index") (get item "id") (get item "call_id")).foldl
      (fun acc k => acc.put k name) (field st "tool_names")
    return (st.put (a "tool_names") names, [])
  if type == b "response.function_call_arguments.delta" then return reconcile st ev
  return (discard st, [])

private def skipWS (raw : ByteArray) (start : Nat) : Nat := Id.run do
  let mut pos := start
  for _ in [start:raw.size] do
    if [32, 9, 10, 13].contains raw[pos]!.toNat then pos := pos + 1 else break
  return pos

private def partialMetadata (raw : ByteArray) : Option (Term × Nat) := Id.run do
  for pos in [:raw.size] do
    if raw.extract pos (pos + 7) != "\"delta\"".toUTF8 then continue
    let colon := skipWS raw (pos + 7)
    if raw[colon]?.getD 0 != 58 then continue
    let quote := skipWS raw (colon + 1)
    if raw[quote]?.getD 0 != 34 then continue
    if let some ev := Json.decode (raw.extract 0 quote ++ "\"\"}".toUTF8) then
      if get ev "type" == b "response.function_call_arguments.delta" && get ev "delta" == b "" &&
          !(eventKeys ev).isEmpty then return some (ev, quote + 1)
  return none

-- The parser consumes each available byte once. A partial UTF-8 character stays private.
private def scanString (raw : ByteArray) (start : Nat) (mode : Term) : Option (Term × ByteArray × Nat × Bool) := Id.run do
  let mut mode := mode
  let mut out := ByteArray.empty
  let mut pos := start
  for idx in [start:raw.size] do
    if mode == a "done" then return some (mode, out, pos, true)
    let byte := raw[idx]!
    pos := idx + 1
    match mode with
    | .atom "plain" =>
      if byte == 34 then return some (a "done", out, pos, true)
      else if byte == 92 then mode := a "escape"
      else if byte < 32 then return none
      else out := out.push byte
    | .atom "escape" =>
      if byte == 117 then mode := .tuple [a "unicode", i 0, i 0, i 0]
      else
        let decoded := [(34, 34), (92, 92), (47, 47), (98, 8), (102, 12), (110, 10), (114, 13), (116, 9)].find? (·.1 == byte.toNat)
        let some (_, value) := decoded | return none
        out := out.push (UInt8.ofNat value)
        mode := a "plain"
    | .tuple [.atom "unicode", .integer high, .integer count, .integer value] =>
      let some digit := JsonSyntax.hex (Char.ofNat byte.toNat) | return none
      let value := value * 16 + Int.ofNat digit
      if count != 3 then mode := .tuple [a "unicode", i high, i (count + 1), i value]
      else if high != 0 then
        if value < 0xDC00 || value > 0xDFFF then return none
        out := out ++ (String.singleton (Char.ofNat (0x10000 + (high.toNat - 0xD800) * 0x400 + value.toNat - 0xDC00))).toUTF8
        mode := a "plain"
      else if value ≥ 0xD800 && value ≤ 0xDBFF then mode := .tuple [a "surrogate_backslash", i value]
      else if value ≥ 0xDC00 && value ≤ 0xDFFF then return none
      else
        out := out ++ (String.singleton (Char.ofNat value.toNat)).toUTF8
        mode := a "plain"
    | .tuple [.atom "surrogate_backslash", high] =>
      if byte != 92 then return none
      mode := .tuple [a "surrogate_u", high]
    | .tuple [.atom "surrogate_u", high] =>
      if byte != 117 then return none
      mode := .tuple [a "unicode", high, i 0, i 0]
    | _ => return none
  return some (mode, out, pos, mode == a "done")

private def partialLine (st : Term) (line : ByteArray) : Term × List Term := Id.run do
  if field st "tool_callback" != a "true" then return (st, [])
  let old := field st "partial"
  let bad := if old == nil then st else discard st
  if line.extract 0 5 != "data:".toUTF8 then return (bad, [])
  let raw := line.extract (skipWS line 5) line.size
  if raw.size > 320 * 1024 then return (bad, [])
  let mut p := old
  if p == nil then
    let some (ev, start) := partialMetadata raw | return (st, [])
    let key := resolvedKey st (eventKeys ev)
    if key == nil || (items (field st "rejected")).contains key then return (st, [])
    p := host [("event", ev), ("key", key), ("offset", i start), ("mode", a "plain"), ("pending", b ""), ("decoded", list [])]
  let start := (Usage.int (field p "offset")).toNat
  if raw.size < start then return (bad, [])
  let some (mode, decoded, offset, complete) := scanString raw start (field p "mode") | return (bad, [])
  let candidate := bytes (field p "pending") ++ decoded
  let valid := (String.fromUTF8? candidate).isSome
  if complete && !valid then return (bad, [])
  let output := if valid then candidate else ByteArray.empty
  let pending := if valid then ByteArray.empty else candidate
  p := p.put (a "mode") mode |>.put (a "offset") (i offset) |>.put (a "pending") (.binary pending)
  if !output.isEmpty then p := p.put (a "decoded") (list (.binary output :: items (field p "decoded")))
  return (st.put (a "partial") p, emitTool st (field p "event") (.binary output))

def new (protocol model callback : Term) : Term := host [("protocol", protocol), ("model", model), ("tool_callback", callback),
  ("raw", list []), ("buffer", b ""), ("tool_names", empty), ("partial", nil), ("rejected", list [])]

def feed (st : Term) (chunk : ByteArray) (success : Bool) : Term × Term := Id.run do
  let raw := list (.binary chunk :: items (field st "raw"))
  if !success then return (st.put (a "raw") raw, list [])
  let protocol := String.fromUTF8! (bytes (field st "protocol"))
  let (lines, rest) := splitLines (bytes (field st "buffer") ++ chunk)
  let mut state := st
  let mut output := []
  for item in lines do
    let (next, actions) := line protocol state item
    state := next
    output := actions.reverse ++ output
  if protocol == "responses" then
    let (next, actions) := partialLine state rest
    state := next
    output := actions.reverse ++ output
  return (state.put (a "raw") raw |>.put (a "buffer") (.binary rest), list output.reverse)

def rawBody (st : Term) : ByteArray :=
  (items (field st "raw")).reverse.foldl (fun acc v => acc ++ bytes v) ByteArray.empty

def finalActions (st : Term) : Term :=
  if field st "protocol" == b "anthropic" then list (line "anthropic" st (bytes (field st "buffer"))).2 else list []

end VerifiedKernel.Provider.Stream
