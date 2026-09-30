import VerifiedKernel.Provider.Common

namespace VerifiedKernel.Provider.Content
open Data

def runtimeBody (m : Term) : Term :=
  if field m "content_kind" == b "model_context" ||
      member (field m "type") ["tool_call_completed", "tool_call_failed", "tool_call_handoff", "project_knowledge"] ||
      field m "summary" == nil || field m "summary" == b "" then field m "content" else nil

def runtimeText (m : Term) : KernelM Term := do
  let fields := ["runtime_message_id", "type", "source_tool_call_id", "wait_id", "reason",
    "timeout_seconds", "deadline_ms", "elapsed_ms", "overdue_ms", "source", "tool_call_id",
    "tool_call_ids", "failed_tool_calls", "pending_external_callback_tool_calls", "failed_llm_call",
    "summary", "content", "source_refs"]
  let jsonFields := ["tool_call_ids", "failed_tool_calls", "pending_external_callback_tool_calls", "failed_llm_call", "source_refs"]
  let mut lines := [b "This is system-generated runtime state for the current Salix session.", b "It is not a user request."]
  for key in fields do
    let v := if key == "content" then runtimeBody m else field m key
    if v != nil && (if jsonFields.contains key then v != empty && v != list [] else v != b "") then
      let text ← if jsonFields.contains key then encode v else str v
      lines := lines ++ [← cat [b key, b ": ", text]]
  cat [b "<runtime-message>\n", ← join lines "\n", b "\n</runtime-message>"]

def systemText (m : Term) : KernelM Term :=
  if field m "role" == b "runtime" || field m "role" == a "runtime" then runtimeText m else trimmed (coalesce [field m "content", b ""])

def inputTime (m content : Term) (textType := "text") : KernelM Term := do
  let time := field m "input_time"
  if !time.isMap || time == empty then return content
  let text ← cat [b "Message time context (source metadata, not user text): ", ← encode time]
  if let .list blocks := content then return list (obj [("type", b textType), ("text", text)] :: blocks)
  cat [text, b "\n\n", content]

def imageUrl (block : Term) : Term :=
  let url := get block "image_url"
  if nonempty (get url "url") then get url "url"
  else if nonempty url then url
  else let url := get block "url"; if url.isBinary && !missing url then url else nil

def knownBlock (anthropic : Bool) (block : Term) : Bool :=
  let type := get block "type"
  if member type ["text", "input_text", "output_text"] then block.has (b "text")
  else if member type ["file", "input_file"] then true
  else if anthropic && type == b "image" && (get block "source").isMap then get block "source" != empty
  else member type ["image", "image_url", "input_image"] && imageUrl block != nil

def nativeBlocks (anthropic : Bool) (content : Term) : Option (List Term) := do
  if (bytes content)[0]?.getD 0 != 91 then none else do
    let .list blocks ← decode content | none
    if !blocks.isEmpty && blocks.all (knownBlock anthropic) then some blocks else none

def fileText (block : Term) : KernelM Term := do
  let path := coalesce [get block "path", get (get block "file_ref") "path", get block "filename", b "attachment"]
  let basename := b (((String.fromUTF8! (bytes path)).splitOn "/").filter (· != "") |>.getLast?.getD "")
  let name := coalesce [get block "file_name", get block "filename", get block "title", basename]
  cat [b "[Attached file is available in the agent workspace, not in this request: ", name,
    b " (VFS path: ", path, b "). Read it with fs.read_file, or stage it on a connected runner with env.copy and convert it with env.exec, before describing it.]"]

def block (protocol : String) (value : Term) : KernelM (List Term) := do
  let type := get value "type"
  let textType := if protocol == "responses" then "input_text" else "text"
  if member type ["text", "input_text", "output_text"] then
    return [obj [("type", b textType), ("text", ← str (get value "text"))]]
  if member type ["file", "input_file"] then
    return [obj [("type", b textType), ("text", ← fileText value)]]
  if !member type ["image", "image_url", "input_image"] then return []
  if protocol == "anthropic" && type == b "image" && (get value "source").isMap then
    return [obj [("type", b "image"), ("source", get value "source")]]
  let url := imageUrl value
  if url == nil then return []
  if protocol == "responses" then return [obj [("type", b "input_image"), ("image_url", url)]]
  if protocol == "chat" then return [obj [("type", b "image_url"), ("image_url", obj [("url", url)])]]
  let text := String.fromUTF8! (bytes url)
  let parts := (text.drop 5).toString.splitOn ","
  let source := if text.startsWith "data:" && parts.length ≥ 2 then
      obj [("type", b "base64"), ("media_type", b ((parts.head!.splitOn ";").head!)),
        ("data", b (String.intercalate "," parts.tail))]
    else obj [("type", b "url"), ("url", url)]
  return [obj [("type", b "image"), ("source", source)]]

def convert (protocol : String) (m : Term) : KernelM Term := do
  let content ← str (coalesce [field m "content", b ""])
  if field m "native_content_trusted" != a "true" then return content
  let some blocks := nativeBlocks (protocol == "anthropic") content | return content
  let converted := (← blocks.mapM (block protocol)).flatten
  if protocol == "chat" && !converted.any (fun v => get v "type" == b "image_url") then
    join (converted.map (get · "text")) "\n"
  else return list converted

end VerifiedKernel.Provider.Content
