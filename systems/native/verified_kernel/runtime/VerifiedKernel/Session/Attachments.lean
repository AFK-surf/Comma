import VerifiedKernel.Provider.Common

namespace VerifiedKernel.Session.Attachments
open Data Provider

@[inline] def putField (m : Term) (key : String) (v : Term) : Term :=
  m.put (if m.has (a key) || !m.has (b key) then a key else b key) v

@[inline] def dropField (m : Term) (key : String) : Term :=
  removeKey (removeKey m (a key)) (b key)

private def deviceImage (block : Term) : Bool :=
  let ref := get block "file_ref"
  get block "type" == b "image" &&
    nonempty (get ref "device_id") && nonempty (get ref "environment_id") &&
    get ref "environment_id" != b "vfs" && nonempty (get ref "path")

private def path (block : Term) : Term :=
  let direct := get block "path"
  let ref := get block "file_ref"
  if direct.isBinary then direct
  else if get ref "environment_id" == b "vfs" || deviceImage block then get ref "path" else nil

private def refKey (block : Term) : Term :=
  if member (get block "type") ["image", "file"] && nonempty (path block) then
    if deviceImage block then
      .tuple [get block "type", path block, get (get block "file_ref") "device_id", get (get block "file_ref") "environment_id"]
    else .tuple [get block "type", path block]
  else nil

private def nativeRef (block : Term) : Bool :=
  if get block "type" == b "image" then get (get block "file_ref") "environment_id" == b "vfs" || deviceImage block
  else get block "type" == b "file" && (path block).isBinary

private def direct (content : Term) : Option (List Term) := do
  if !(bytes content)[0]?.any (· == 91) then none else
  let .list blocks ← decode content | none
  return blocks

private def canonical (content : Term) : Option (List Term × Term) := do
  let record ← decode content
  let result := get record "result"
  let id := get record "tool_call_id"
  let name := get record "tool_name"
  if !nonempty id || !nonempty name || get record "status" != b "completed" ||
    get result "id" != id || get result "name" != name || get result "status" != b "completed" ||
    record.has (b "result_page") || ![nil, a "false"].contains (get record "error") ||
    ![nil, a "false"].contains (get result "error") then none else
  return (← direct (get result "content"), name)

private def toolSource (name : Term) (blocks : List Term) : Term :=
  if member name ["im_api.feishu.fetch_message_resource", "im_api.slack.fetch_file"] then a "provider_attachment"
  else if name == b "env.computer_use" && !blocks.isEmpty && blocks.all deviceImage then a "image_read"
  else if name == b "fs.read_file" && blocks.all (fun v => get v "type" == b "image") then a "image_read"
  else nil

private def runtimeSource (m : Term) : KernelM (Option (List Term × Term)) := do
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
  if name == b "tool_call.get_result" then return canonical (get result "content")
  return (direct (get result "content")).map (fun blocks => (blocks, name))

def source (m : Term) : KernelM Term := do
  -- Trust user attachments only through out-of-band refs, and tool attachments through journal provenance.
  let content := Provider.field m "content"
  if !m.isMap || !content.isBinary then return a "error"
  let role := Provider.field m "role"
  let name ← if role == b "tool" then str (Provider.field m "tool_name") else pure nil
  let mut source := nil
  let mut blocks := []
  if let some directBlocks := direct content then
    blocks := directBlocks
    if role == b "user" then
      let refs := items (Provider.field m "trusted_attachment_refs")
      let native := blocks.filter nativeRef
      if !refs.isEmpty && native.all (fun v => refKey v != nil && refs.any (fun ref => refKey ref == refKey v)) then
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
  let safe := blocks.all (fun block =>
    (member (get block "type") ["text", "input_text", "output_text"] && block.has (b "text")) ||
    refKey block != nil)
  if source == nil || !(blocks.any nativeRef) || !safe then return a "error"
  return .tuple [a "ok", list blocks, source]

-- An inbound attachment is never model input, whatever its type. The host
-- announces a file by name and VFS path, so presenting an inbound image as one
-- puts a photo on the same route as a PDF: the agent reads it with a tool or it
-- does not reach the model at all. Nothing here decides whether the model can
-- accept an image; that is the template's `supports_images`, checked by the host
-- when a tool read asks for the bytes.
private def announced (block : Term) : Term :=
  if get block "type" == b "image" then putField block "type" (b "file") else block

private def readBatch (requests : List Term) : KernelM (List Term) := do
  if requests.isEmpty then return []
  let values ← asList (← observe (.tuple [a "request_batch", list requests]))
  if values.length != requests.length then fail "schema" [b "attachment batch result count mismatch"]
  else return values

-- Each source can request one authoritative result record, but never image bytes.
-- A request that `prefetched` answers takes that answer; the others are read here.
private def sources (messages : List Term) (prefetched : List (Term × Term)) : KernelM (List Term) := do
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

private def candidate (enabled : Bool) (watermark message : Term) : Bool :=
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
