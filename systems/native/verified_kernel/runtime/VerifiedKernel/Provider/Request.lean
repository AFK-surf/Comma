import VerifiedKernel.Provider.Messages

namespace VerifiedKernel.Provider.Request
open Data

def config (overrides apiKey authToken : Term) : KernelM Term := do
  let listValue := fun key => let v := get overrides key; if v.isList then v else nil
  let objectValue := fun key => do
    let v := get overrides key
    if !v.isMap then pure nil else do
      let pairs ← (← entries v).mapM fun (k, v) => do return (← str k, v)
      pure (.map pairs)
  let reasoning := get overrides "reasoning"
  let effort := get overrides "reasoning_effort"
  let cacheKey := get overrides "prompt_cache_key"
  return host [("protocol", coalesce [get overrides "protocol", b ""]),
    ("model", coalesce [get overrides "model", b ""]), ("api_key", apiKey), ("auth_token", authToken),
    ("base_url", coalesce [get overrides "base_url", b ""]), ("max_tokens", get overrides "max_tokens"),
    ("prompt_caching", Term.bool (get overrides "prompt_caching" != a "false")), ("store", get overrides "store"),
    ("include", listValue "include"), ("context_management", listValue "context_management"),
    ("reasoning", if reasoning.isMap then reasoning else if nonempty effort then obj [("effort", effort)] else nil),
    ("thinking", ← objectValue "thinking"), ("response_format", ← objectValue "response_format"),
    ("prompt_cache_key", if nonempty cacheKey then cacheKey else nil),
    ("default_headers", coalesce [get overrides "default_headers", empty])]

private def mark (v : Term) : Term := if v.isMap then v.put (b "cache_control") (obj [("type", b "ephemeral")]) else v
private def markLast (xs : List Term) : List Term := (xs.reverse.modifyHead mark).reverse

def cache (system tools messages enabled trailing : Term) : Term := Id.run do
  if enabled == a "false" then return .tuple [system, tools, messages]
  let mut system := system
  let mut tools := tools
  if nonempty system then system := list [mark (obj [("type", b "text"), ("text", system)])]
  else if !(items tools).isEmpty then tools := list (markLast (items tools))
  let msgs := items messages
  let durable := Int.ofNat msgs.length - (match trailing with | .integer n => max n 0 | _ => 0)
  let mut marks := 0
  let mut distance := 0
  let mut output := []
  for (m, idx) in msgs.zipIdx |>.reverse do
    let content := get m "content"
    distance := distance + if content.isList then (items content).length else 1
    let markable := nonempty content || !(items content).isEmpty
    if marks < 3 && Int.ofNat idx < durable && markable && (marks == 0 || distance ≥ 15) then
      let blocks := if content.isBinary then [mark (obj [("type", b "text"), ("text", content)])]
        else markLast (items content)
      output := m.put (b "content") (list blocks) :: output
      marks := marks + 1
      distance := 0
    else output := m :: output
  return .tuple [system, tools, list output]

def body (protocol : String) (cfg : Term) (messages tools : List Term) (mode : String) (reminders : List Term := []) : KernelM Term := do
  let messages := if protocol == "responses" then messages else messages ++ reminders
  let model := cfg.get (a "model")
  let toolDefs ← tools.mapM (toolSpec protocol)
  let toolDefs := if tools.isEmpty then nil else list toolDefs
  if protocol == "anthropic" then
    let .tuple [system, msgs, trailing] ← Messages.anthropicParts messages model | fail "badarg"
    let .tuple [system, specs, msgs] := cache system toolDefs msgs (cfg.get (a "prompt_caching")) trailing | fail "badarg"
    let mut value := obj [("model", model), ("max_tokens", coalesce [cfg.get (a "max_tokens"), i 4096]), ("messages", msgs)]
    value := putOptional (putOptional (putOptional value "system" system) "tools" specs) "thinking" (cfg.get (a "thinking"))
    -- Preserve the existing streaming request contract. Only blocking calls send output_config.
    if mode == "stream" then return value.put (b "stream") (a "true")
    let reasoning := cfg.get (a "reasoning")
    let effort := coalesce [get reasoning "effort", reasoning.get (a "effort")]
    return if member effort ["low", "medium", "high", "xhigh", "max"] then
      value.put (b "output_config") (obj [("effort", effort)]) else value
  if protocol == "responses" then
    let .tuple [input, instructions] ← Messages.responsesParts messages reminders | fail "badarg"
    let mut value := putOptional (putOptional (obj [("model", model), ("input", input)]) "instructions" instructions) "tools" toolDefs
    if mode == "compact" then return value
    -- One stable key per session keeps every round of a conversation on the
    -- same provider-side prompt cache. Without it the Codex subscription proxy
    -- mints a fresh Session_id per request and the cached prefix is lost.
    for key in ["store", "include", "context_management", "reasoning", "prompt_cache_key"] do
      value := putOptional value key (cfg.get (a key))
    let format := cfg.get (a "response_format")
    if format != nil then value := value.put (b "text") (obj [("format", format)])
    value := putOptional value "max_output_tokens" (cfg.get (a "max_tokens"))
    return if mode == "stream" then value.put (b "stream") (a "true") else value
  let mut value := putOptional (obj [("model", model), ("messages", ← Messages.chat messages model)]) "tools" toolDefs
  value := putOptional value "prompt_cache_key" (cfg.get (a "prompt_cache_key"))
  value := putOptional value "response_format" (cfg.get (a "response_format"))
  let short := (((String.fromUTF8! (bytes model)).toLower.splitOn "/").getLast?.getD "").trimAscii.toString
  let cap := if ["gpt-5", "o1", "o3", "o4"].any (fun s => short.startsWith s) then "max_completion_tokens" else "max_tokens"
  value := putOptional value cap (cfg.get (a "max_tokens"))
  let thinking := cfg.get (a "thinking")
  if thinking.isMap then value := value.put (b "thinking") thinking
  let reasoning := cfg.get (a "reasoning")
  if nonempty (get reasoning "effort") then value := value.put (b "reasoning_effort") (get reasoning "effort")
  let modelName := (String.fromUTF8! (bytes model)).toLower
  if modelName.startsWith "qwen" || modelName.startsWith "qwq" then
    if mode != "stream" then value := value.put (b "enable_thinking") (a "false")
    else if get thinking "type" != b "disabled" && (thinking.isMap || reasoning.isMap) then value := value.put (b "enable_thinking") (a "true")
  if mode == "stream" then
    value := value.put (b "stream") (a "true") |>.put (b "stream_options") (obj [("include_usage", a "true")])
  return value

def endpoint (protocol : String) (cfg : Term) (mode : String) (extra : List Term := []) : KernelM Term := do
  let base := String.ofList ((String.fromUTF8! (bytes (cfg.get (a "base_url")))).toList.reverse.dropWhile (· == '/')).reverse
  let path := if protocol == "anthropic" then "/v1/messages" else if protocol == "responses" then
    (if mode == "compact" then "/responses/compact" else "/responses") else "/chat/completions"
  let mut headers := []
  if protocol == "anthropic" then
    if nonempty (cfg.get (a "auth_token")) then
      headers := [.tuple [b "authorization", ← cat [b "Bearer ", cfg.get (a "auth_token")]]]
    else headers := [.tuple [b "x-api-key", coalesce [cfg.get (a "api_key"), b ""]]]
    headers := headers ++ [.tuple [b "anthropic-version", b "2023-06-01"]]
  else headers := [.tuple [b "authorization", ← cat [b "Bearer ", cfg.get (a "api_key")]]]
  headers := headers ++ [.tuple [b "content-type", b "application/json"]]
  if protocol != "anthropic" || mode == "stream" then
    headers := headers ++ [.tuple [b "accept-encoding", b "identity"]]
  headers := headers ++ extra
  let defaults := cfg.get (a "default_headers")
  for (k, v) in (← entries defaults) do
    headers := headers ++ [.tuple [← str k, ← str v]]
  return .tuple [b (base ++ path), list headers]

def encodedBody (protocol : String) (cfg : Term) (messages tools : List Term) (mode : String) (reminders : List Term := []) : KernelM Term := do
  let messages := if protocol == "anthropic" then messages else messages.map scrub
  let tools := if protocol == "anthropic" then tools else tools.map scrub
  let reminders := if protocol == "anthropic" then reminders else reminders.map scrub
  encode (scrub (← body protocol cfg messages tools mode reminders))

end VerifiedKernel.Provider.Request
