import VerifiedKernel.Provider.Common

namespace VerifiedKernel.Session.Attachments
open Data Provider

@[inline] def putField (m : Term) (key : String) (v : Term) : Term :=
  m.put (if m.has (a key) || !m.has (b key) then a key else b key) v

@[inline] def dropField (m : Term) (key : String) : Term :=
  removeKey (removeKey m (a key)) (b key)

def deviceImage (block : Term) : Bool :=
  let ref := get block "file_ref"
  get block "type" == b "image" &&
    nonempty (get ref "device_id") && nonempty (get ref "environment_id") &&
    get ref "environment_id" != b "vfs" && nonempty (get ref "path")

def path (block : Term) : Term :=
  let direct := get block "path"
  let ref := get block "file_ref"
  if direct.isBinary then direct
  else if get ref "environment_id" == b "vfs" || deviceImage block then get ref "path" else nil

def refKey (block : Term) : Term :=
  if member (get block "type") ["image", "file"] && nonempty (path block) then
    if deviceImage block then
      .tuple [get block "type", path block, get (get block "file_ref") "device_id", get (get block "file_ref") "environment_id"]
    else .tuple [get block "type", path block]
  else nil

def nativeRef (block : Term) : Bool :=
  if get block "type" == b "image" then get (get block "file_ref") "environment_id" == b "vfs" || deviceImage block
  else get block "type" == b "file" && (path block).isBinary

def direct (content : Term) : Option (List Term) := do
  if !(bytes content)[0]?.any (· == 91) then none else
  let .list blocks ← decode content | none
  return blocks

def canonical (content : Term) : Option (List Term × Term) := do
  let record ← decode content
  let result := get record "result"
  let id := get record "tool_call_id"
  let name := get record "tool_name"
  if !nonempty id || !nonempty name || get record "status" != b "completed" ||
    get result "id" != id || get result "name" != name || get result "status" != b "completed" ||
    record.has (b "result_page") || ![nil, a "false"].contains (get record "error") ||
    ![nil, a "false"].contains (get result "error") then none else
  return (← direct (get result "content"), name)

-- A file directly in /artifacts named `mcp-…`, with no further segment.
def mcpImage (block : Term) : Bool :=
  let ref := get block "file_ref"
  let path := (String.fromUTF8? (bytes (get ref "path"))).getD ""
  get block "type" == b "image" && get ref "environment_id" == b "vfs" &&
    path.startsWith "/artifacts/mcp-" && !((path.drop 15).contains '/')

def toolSource (name : Term) (blocks : List Term) : Term :=
  if member name ["im_api.feishu.fetch_message_resource", "im_api.slack.fetch_file"] then a "provider_attachment"
  else if name == b "env.computer_use" && !blocks.isEmpty && blocks.all deviceImage then a "image_read"
  -- A workspace image the tool itself wrote: a file read, or a LAN body
  -- (camera snapshot) that device.lan_request stored.
  else if member name ["fs.read_file", "device.lan_request"] && blocks.all (fun v => get v "type" == b "image") then
    a "image_read"
  -- An MCP tool's image part, which the host stored under a fresh
  -- `/artifacts/mcp-<uuid>` name (`SalixAgent.Tools.MCP`). The host wraps a
  -- server's own text, so only a result stored before that can still name a
  -- block; it reaches no device and no workspace file outside these names.
  -- `/artifacts` is not reserved: such a result could name an `mcp-` file
  -- written there under a name it already knew.
  else if ((String.fromUTF8? (bytes name)).getD "").startsWith "mcp." && !blocks.isEmpty &&
      blocks.all mcpImage then
    a "image_read"
  else nil

-- The leading IFC source marker (`[src:…]` and a newline) of a runtime
-- message's content, as `Provider.Messages.runtimeContent` reads it, or empty.
def sourceMarker (raw : ByteArray) : ByteArray := Id.run do
  if raw.size < 6 || raw.extract 0 5 != "[src:".toUTF8 then return ByteArray.empty
  for index in [5:raw.size] do
    if raw[index]! == 93 then
      if index + 1 < raw.size && raw[index + 1]! == 10 then return raw.extract 0 (index + 2)
      return ByteArray.empty
    if raw[index]! == 10 then return ByteArray.empty
  return ByteArray.empty

/-- The text block that keeps a completion notice's facts when its stored
result replaces the notice's content: the model must still see which call
completed, and the IFC marker that lets it cite the result. -/
def completionNotice (m id name : Term) : KernelM Term := do
  let notice ← encode (obj [("type", b "tool_call_completed"), ("tool_call_id", id),
    ("tool_name", name), ("status", b "completed"),
    ("note", b "tool call completed after returning early; its result is attached below")])
  let marker := sourceMarker (bytes (Provider.field m "content"))
  return obj [("type", b "text"), ("text", .binary (marker ++ bytes notice))]

def runtimeSource (m : Term) : KernelM (Option (List Term × Term)) := do
  -- The notification names a stored result. Its content cannot authorize a VFS read.
  let id := Provider.field m "source_tool_call_id"
  let seq := Provider.field m "result_seq"
  if Provider.field m "role" != b "runtime" || Provider.field m "type" != b "tool_call_completed" ||
    !nonempty id || !seq.isInteger || integerValue seq ≤ 0 then return none
  let .tuple [.atom "ok", record] ← observe (.tuple [a "request_result", seq]) | return none
  let result := get record "result"
  let name := get record "tool_name"
  if get record "seq" != seq || get record "tool_call_id" != id ||
    get record "status" != b "completed" || get record "error" == a "true" ||
    !result.isMap || get result "id" != id || !nonempty name ||
    get result "name" != name || get result "status" != b "completed" ||
    get result "error" == a "true" then return none
  let resolved := if name == b "tool_call.get_result" then canonical (get result "content")
    else (direct (get result "content")).map (fun blocks => (blocks, name))
  let some (blocks, innerName) := resolved | return none
  let notice ← completionNotice m id name
  return some (notice :: blocks, innerName)

def structuredBlock (block : Term) : Bool :=
  let type := get block "type"
  (type == b "dynamic_ui" && (nonempty (get block "ui_ref") || nonempty (get block "path"))) ||
  (type == b "conversation_ref" && nonempty (get block "conversation_id"))

def commandHint : ByteArray :=
  "IFC: command input; use this ref as request when acting on it.\n".toUTF8

def conversationPrefix (raw : ByteArray) : ByteArray := Id.run do
  if raw.size < 16 || raw.extract 0 14 != "[conversation ".toUTF8 then return ByteArray.empty
  for index in [14:raw.size] do
    if raw[index]! == 93 then
      if index + 1 < raw.size && raw[index + 1]! == 32 then
        return raw.extract 0 (index + 2)
      return ByteArray.empty
    if raw[index]! == 10 then return ByteArray.empty
  return ByteArray.empty

-- Leading annotations `Session.Request.annotate` prepends to a user message
-- (`[src:…]\n`, optional IFC command hint, optional `[conversation …] `).
def userPrefix (raw : ByteArray) : ByteArray × ByteArray := Id.run do
  let mut pos : Nat := 0
  let marker := sourceMarker raw
  if marker.size > 0 then
    pos := marker.size
    if pos + commandHint.size ≤ raw.size &&
        raw.extract pos (pos + commandHint.size) == commandHint then
      pos := pos + commandHint.size
  let rest := raw.extract pos raw.size
  let conv := conversationPrefix rest
  if conv.size > 0 then
    pos := pos + conv.size
  return (raw.extract 0 pos, raw.extract pos raw.size)

def prependPrefix (prefixBytes : ByteArray) (blocks : List Term) : List Term :=
  if prefixBytes.size == 0 then blocks
  else match blocks with
    | first :: rest =>
      if member (get first "type") ["text", "input_text", "output_text"] &&
          (get first "text").isBinary then
        (first.put (b "text") (.binary (prefixBytes ++ bytes (get first "text")))) :: rest
      else
        let trimmed :=
          if prefixBytes[prefixBytes.size - 1]? == some 10 then
            prefixBytes.extract 0 (prefixBytes.size - 1)
          else prefixBytes
        obj [("type", b "text"), ("text", .binary trimmed)] :: blocks
    | [] => []

def trustedInternalAgentOrigin (m : Term) : Bool :=
  let origin := Provider.field m "trusted_origin"
  origin.isMap &&
    Provider.field origin "provider" == b "internal" &&
    Provider.field origin "source_actor_type" == b "agent"

def source (m : Term) : KernelM Term := do
  -- Trust user attachments only through out-of-band refs, and tool attachments through journal provenance.
  let content := Provider.field m "content"
  if !m.isMap || !content.isBinary then return a "error"
  let role := Provider.field m "role"
  let name ← if role == b "tool" then str (Provider.field m "tool_name") else pure nil
  let mut source := nil
  let mut blocks := []
  let mut prefixBytes := ByteArray.empty
  let (userPfx, userBody) :=
    if role == b "user" then userPrefix (bytes content) else (ByteArray.empty, bytes content)
  let directInput := if role == b "user" then .binary userBody else content
  if let some directBlocks := direct directInput then
    blocks := directBlocks
    if role == b "user" then
      prefixBytes := userPfx
      let refs := items (Provider.field m "trusted_attachment_refs")
      let native := blocks.filter nativeRef
      if !refs.isEmpty && native.all (fun v => refKey v != nil && refs.any (fun ref => refKey ref == refKey v)) then
        source := a "user_attachment"
      else if native.isEmpty && trustedInternalAgentOrigin m && blocks.any structuredBlock then
        source := a "user_attachment"
    else if role == b "tool" then source := toolSource name (blocks.filter nativeRef)
    else if role == b "runtime" && Provider.field m "native_content_trusted" == a "true" then source := a "provider_attachment"
  else if role == b "tool" && name == b "tool_call.get_result" then
    if let some (resolved, name) := canonical content then
      blocks := resolved
      source := toolSource name (blocks.filter nativeRef)
  else if let some (resolved, name) ← runtimeSource m then
    blocks := resolved
    source := toolSource name (blocks.filter nativeRef)
  let userStructured := source == a "user_attachment" && blocks.any structuredBlock
  let safe := blocks.all (fun block =>
    (member (get block "type") ["text", "input_text", "output_text"] && block.has (b "text")) ||
    refKey block != nil ||
    (source == a "user_attachment" && structuredBlock block))
  if source == nil || (!(blocks.any nativeRef) && !userStructured) || !safe then return a "error"
  let finalBlocks := if prefixBytes.size > 0 then prependPrefix prefixBytes blocks else blocks
  return .tuple [a "ok", list finalBlocks, source]

-- An inbound attachment is never model input, whatever its type. The host
-- announces a file by name and VFS path, so presenting an inbound image as one
-- puts a photo on the same route as a PDF: the agent reads it with a tool or it
-- does not reach the model at all. Nothing here decides whether the model can
-- accept an image; that is the template's `supports_images`, checked by the host
-- when a tool read asks for the bytes.
def announced (block : Term) : Term :=
  if get block "type" == b "image" then putField block "type" (b "file") else block

def readBatch (requests : List Term) : KernelM (List Term) := do
  if requests.isEmpty then return []
  let values ← asList (← observe (.tuple [a "request_batch", list requests]))
  if values.length != requests.length then fail "schema" [b "attachment batch result count mismatch"]
  else return values

-- Each source can request one authoritative result record, but never image bytes.
-- A request that `prefetched` answers takes that answer; the others are read here.
def sources (messages : List Term) (prefetched : List (Term × Term)) : KernelM (List Term) := do
  let lookup := fun request => (prefetched.find? (·.1 == request)).map Prod.snd
  let pending := messages.map (fun message => source message [])
  let requests := pending.filterMap fun result =>
    match result with
    | .error (.observe request) => if (lookup request).isSome then none else some request
    | _ => none
  let mut answers ← readBatch requests
  let mut values := []
  for (message, result) in messages.zip pending do
    match result with
    | .ok (value, _) => values := value :: values
    | .error (.raised reason) => throw (.raised reason)
    | .error (.observe request) =>
      let answer ← match lookup request with
        | some answer => pure answer
        | none => do
          let answer := answers.head!
          answers := answers.drop 1
          pure answer
      match source message [.tuple [a "ok", answer]] with
      | .ok (value, _) => values := value :: values
      | .error signal => throw signal
  return values.reverse

def candidate (enabled : Bool) (watermark message : Term) : Bool :=
  let id := Provider.field message "id"
  enabled && member (Provider.field message "role") ["user", "tool", "runtime"] &&
    (!watermark.isInteger || (id.isInteger && integerValue id > integerValue watermark))

/-- Reads, in one batch, the result records that `inline` would request for
`messages`, and pairs each request with its answer. A caller reads them before
it builds a request from these messages, so a resumed query does not build the
request twice. `inline` reads any request that this guess missed. -/
def prefetch (messages : List Term) (watermark : Term) : KernelM (List (Term × Term)) := do
  let requests := messages.filterMap fun message =>
    if !candidate true watermark message then none else
    match source message [] with
    | .error (.observe request) => some request
    | _ => none
  let requests := requests.foldl (fun acc request => if acc.contains request then acc else acc ++ [request]) []
  return requests.zip (← readBatch requests)

def inline (messages : List Term) (watermark : Term) (enabled : Bool := true)
    (prefetched : List (Term × Term) := []) : KernelM (List Term) := do
  let candidates := messages.map fun message =>
    if candidate enabled watermark message then message else nil
  let sources ← sources candidates prefetched
  let blocks := sources.map fun source =>
    match source with
    | .tuple [.atom "ok", .list blocks, .atom "user_attachment"] => blocks.map announced
    | .tuple [.atom "ok", .list blocks, _] => blocks
    | _ => []
  let requests := blocks.flatten.filterMap fun block =>
    if nativeRef block then some (.tuple [a "request_image", block]) else none
  let mut answers ← readBatch requests
  let mut projectedMessages := []
  for ((message, source), blocks) in (messages.zip sources).zip blocks do
    let mut projected := message
    if let .tuple [.atom "ok", _, _] := source then
      let mut resolved := []
      for block in blocks do
        let values ← if nativeRef block then do
          let values ← asList answers.head!
          answers := answers.drop 1
          pure values
          else pure [block]
        resolved := values.reverse ++ resolved
      projected := putField projected "content" (← encode (list resolved.reverse))
      projected := projected.put (if message.has (a "role") then a "native_content_trusted" else b "native_content_trusted") (a "true")
      if Provider.field message "role" == b "runtime" then projected := putField projected "role" (b "user")
    if member (Provider.field message "role") ["user", "tool", "runtime"] then
      projected := dropField projected "result_seq"
    projectedMessages := projected :: projectedMessages
  return projectedMessages.reverse

end VerifiedKernel.Session.Attachments
