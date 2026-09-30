import VerifiedKernel.Session.Request
import VerifiedKernel.Session.Attachments
import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.Activity
import VerifiedKernel.Session.Query.Compaction
import VerifiedKernel.Session.Query.State
import VerifiedKernel.Session.Query.Reply
import VerifiedKernel.Provider.Error
import VerifiedKernel.Inspect
import VerifiedKernel.Json
import VerifiedKernel.Encoding

/-! # Compaction host data

Compaction has two phases of I/O: a model call that summarizes the live
context, and a fenced commit of the result. Everything else is decided here:
when a session must compact, which window a request may summarize, the request
itself, how the model answer is read, and which events the commit writes.

A host runs one compaction as follows:

1. `compaction_prepare {mode, facts}` returns `{:done, result, events}`,
   `{:fail, plan, reason}`, or `{:summarize, plan}`.
2. For `:summarize`, `compaction_request {plan, config, prompt}` returns
   `:skip`, `{:summary, messages}`, or `{:provider, messages}`. The host sends
   the messages to its model.
3. `compaction_outcome {plan, raw}` reads the model answer. It returns
   `{:result, result, events}` for an outcome that commits only its result, or
   `{:commit, outcome}` for an outcome that needs the fence.
4. `compaction_commit {plan, outcome, prompt}`, asked of the state at commit
   time, checks the fence and returns `{:ok, events, result, archive?}`.

`config` is the host's projection of its model configuration: `protocol`,
`provider`, `model`, `base_url`, `max_tokens`, `context_tokens`,
`compaction_strategy`, `context_compaction_strategy`, and `compaction`. -/

namespace VerifiedKernel.Session.CompactionHost
open Data

/-! ## Constants (Willow `activation.go` and `context.go`) -/

def defaultWindow : Int := 128000
/-- The smallest plausible model window: the pre-filter floor. -/
def minWindow : Int := 4096
def reasonMaxBytes : Nat := 2048
def truncationSuffix : String := "...[truncated]"

/-- Willow's compaction instruction, verbatim. -/
def instruction : String :=
  "Summarize the conversation so far. Preserve key facts, decisions, " ++
  "file paths, tool results, and any state needed to continue working. " ++
  "Output only the summary, wrapped in a single " ++
  "<compaction-summary>...</compaction-summary> block. Do not call any " ++
  "tools; respond with the tagged summary text only."

private def seconds : KernelM Term := do
  return i (integerValue (← observe (a "time")) / 1000)

private def text (value : Term) : KernelM String := do
  match ← stringChars value with
  | .binary raw => return String.fromUTF8! raw
  | _ => return ""

/-! ## Result reasons (`Compaction.reason_string/1`) -/

/-- The longest valid UTF-8 prefix of the first `max` bytes. -/
private def utf8Prefix (raw : ByteArray) (max : Nat) : ByteArray :=
  let rec go : Nat → ByteArray
    | 0 => ByteArray.empty
    | n + 1 => let part := raw.extract 0 (n + 1)
      if part.validateUTF8 then part else go n
  go (Nat.min raw.size max)

def truncateReason (raw : ByteArray) : ByteArray :=
  if raw.size ≤ reasonMaxBytes then raw
  else utf8Prefix raw (reasonMaxBytes - truncationSuffix.utf8ByteSize) ++ truncationSuffix.toUTF8

/-- A reason as result text: text as is, an atom by its name, and any other
term as `inspect(limit: 20)`. -/
def reasonText (reason : Term) : ByteArray :=
  match reason with
  | .binary raw => truncateReason (if raw.validateUTF8 then raw else (Inspect.render reason 50 reasonMaxBytes).toUTF8)
  | .atom name => truncateReason name.toUTF8
  | other => truncateReason (Inspect.render other 20 reasonMaxBytes).toUTF8

/-- `%{"status" => status}` with the reason when there is one. -/
def result (status : String) (reason : Term := nil) : Term :=
  if reason == nil then .map [(b "status", b status)]
  else .map [(b "reason", .binary (reasonText reason)), (b "status", b status)]

/-- The `session_compact_result` event that answers a compaction request with
a source message id. -/
def resultEvents (sessionId result source : Term) : KernelM (List Term) := do
  match source with
  | .binary raw =>
    if raw.isEmpty then return []
    let reason := result.get (b "reason")
    let base := [(b "type", b "session_compact_result"), (b "session_id", sessionId),
      (b "source_message_id", source), (b "status", result.get (b "status")), (b "created_at", ← seconds)]
    return [.map (if reason == nil then base else base ++ [(b "reason", reason)])]
  | _ => return []

/-! ## Model configuration -/

private def downcase (raw : ByteArray) : ByteArray :=
  ⟨raw.data.map (fun byte => if 65 ≤ byte && byte ≤ 90 then byte + 32 else byte)⟩

/-- A strategy name as `summary`, `openai_responses`, or `nil`. -/
def normalizeStrategy (value : Term) : Term :=
  let name := match value with
    | .binary raw => some (downcase (trim raw))
    | .atom atom => some (downcase atom.toUTF8)
    | _ => none
  match name.map (fun raw => String.fromUTF8? raw) with
  | some (some name) =>
    if ["summary", "salix", "local_summary"].contains name then b "summary"
    else if ["openai", "openai_responses", "responses_compact", "openai_context_compaction"].contains name then
      b "openai_responses"
    else nil
  | _ => nil

/-- The first candidate that names a strategy, or `nil`. A host passes its
explicit choices in precedence order. -/
def chosenStrategy (candidates : Term) : Term :=
  match candidates with
  | .list values => (values.map normalizeStrategy).foldr (fun value rest => value.default rest) nil
  | value => normalizeStrategy value

/-- The strategy the model configuration names, or `nil`. -/
def configStrategy (config : Term) : Term :=
  let direct := normalizeStrategy (config.get (b "compaction_strategy"))
  let context := normalizeStrategy (config.get (b "context_compaction_strategy"))
  let nested := config.get (b "compaction")
  -- `Map.get(config, "strategy", Map.get(config, :strategy))`: a present
  -- text key wins, even when its value is `nil`.
  let fromNested := if nested.isMap then
      normalizeStrategy (if nested.has (b "strategy") then nested.get (b "strategy") else nested.get (a "strategy"))
    else normalizeStrategy nested
  direct.default (context.default fromNested)

/-- The context window a trigger is measured against: a positive
`context_tokens`, else Willow's 128000. -/
def window (config : Term) : Term :=
  match config.get (b "context_tokens") with
  | .integer n => if n > 0 then i n else i defaultWindow
  | _ => i defaultWindow

/-- The configuration a compaction failure is keyed to: a SHA-256 over the
fields that change the summarizing call. A new configuration retries at once. -/
def fingerprint (config windowTokens : Term) : KernelM Term := do
  let strategy := (configStrategy config).default (b "summary")
  let pairs := [("base_url", config.get (b "base_url")), ("compaction_strategy", strategy),
    ("context_tokens", windowTokens), ("max_tokens", config.get (b "max_tokens")),
    ("model", config.get (b "model")), ("protocol", config.get (b "protocol")),
    ("provider", config.get (b "provider"))]
  let some json ← Json.encode (list (pairs.map (fun pair => list [b pair.1, pair.2])))
    | fail "invalid_compaction_config"
  return .binary (hex (← digest json))

/-- The model configuration in compaction facts: `config`, or the provider
`protocol` and `cfg` that a host passes to `round_request`. A `cfg` may carry
the context window as `context_tokens`. -/
def configOf (facts : Term) : Term :=
  let config := facts.get (b "config")
  if config.isMap then config else
  let cfg := facts.get (b "cfg")
  if !cfg.isMap then nil else
  let pick := fun (key : String) => (cfg.get (a key)).default (cfg.get (b key))
  .map [(b "protocol", facts.get (b "protocol")), (b "model", pick "model"),
    (b "base_url", pick "base_url"), (b "max_tokens", pick "max_tokens"),
    (b "context_tokens", pick "context_tokens")]

/-! ## The live window -/

/-- `Compaction.drop_unfinished_activation_suffix/2`: the messages before the
earliest boundary that must reach a model round verbatim. -/
def dropUnfinished (state : Term) (messages : List Term) : KernelM (List Term) := do
  let start ← CompactionQuery.unfinishedActivationStartId state (list messages)
  if start == nil then return messages
  let rec keep : List Term → KernelM (List Term)
    | [] => pure []
    | message :: rest => do
      if ← greater start (CompactionQuery.compactionMessageId message) then
        return message :: (← keep rest)
      return []
  keep messages

private def sanitize (state : Term) (messages : List Term) : KernelM (List Term) := do
  asList (← Presentation.sanitizeContext messages (← ReplyQuery.phase state))

/-- The window a commit fences on: the whole live window, sanitized. -/
def fencedLive (state : Term) : KernelM (List Term) := do
  sanitize state (← asList (← CompactionQuery.liveMessages state))

/-- The window a compaction may summarize: the live window without the
unfinished activation suffix, sanitized. -/
def compactableLive (state : Term) : KernelM (List Term) := do
  sanitize state (← dropUnfinished state (← asList (← CompactionQuery.liveMessages state)))

private def lastId (state : Term) (live : List Term) : KernelM Term := do
  let ids := live.map (fun message => message.get (a "id"))
  match ids with
  | [] => field state "compacted_through"
  | first :: rest => rest.foldlM maximum first

/-! ## The trigger -/

/-- `ContextOverflow.pending?/1`: one compaction recovery per rejected
transcript watermark, while the watermark and the compaction generation are
unchanged. -/
def overflowPending (state : Term) : KernelM Bool := do
  let marker ← field state "context_overflow_recovery"
  if !marker.isMap || !(marker.has (b "transcript_hwm") && marker.has (b "summary_sequence") &&
      marker.has (b "compacted_through")) then return false
  if ← terminalFailure state then return false
  if ← StateQuery.failuresExhausted state then return false
  let hwm ← sub ((← field state "next_message_id").default (i 0)) (i 1)
  return Term.numericEq (marker.get (b "transcript_hwm")) hwm &&
    Term.numericEq (marker.get (b "summary_sequence")) (← field state "summary_sequence") &&
    Term.numericEq (marker.get (b "compacted_through")) (← field state "compacted_through")

private def shouldCompact (state threshold windowTokens model : Term) : KernelM Bool := do
  return (← StateQuery.shouldCompact state (.tuple [threshold, windowTokens, model])).truthy

/-- Whether an automatic compaction must run before the next round: a pending
overflow recovery, or observed prompt tokens over 0.9 of the window. -/
def required (state facts : Term) : KernelM Bool := do
  if ← overflowPending state then return true
  let config := configOf facts
  let windowTokens := (facts.get (b "context_tokens")).default (window config)
  let model := (facts.get (b "model")).default (config.get (b "model"))
  shouldCompact state (facts.get (b "threshold")) windowTokens model

/-! ## Prepare -/

private def plan (state : Term) (mode : Term) (live : List Term) (last : Term) (auto : Bool)
    (fingerprint strategy source : Term) : KernelM Term := do
  return .map [(b "mode", mode), (b "auto", Term.bool auto), (b "last_id", last),
    (b "basis", ← CompactionQuery.snapshot state (.tuple [list live, last])),
    (b "covered_seq", ← StateQuery.coveredSeq state last),
    (b "summary_sequence", ← add ((← field state "summary_sequence").default (i 0)) (i 1)),
    (b "fingerprint", fingerprint), (b "strategy", strategy), (b "source_message_id", source),
    (b "summary", ← field state "summary"), (b "live", list live)]

/-- One compaction's admission. `mode` is `:compact` (explicit) or
`:maybe_compact` (automatic). `facts` holds `config` (or `config_error`),
`threshold`, `context_tokens`, `model`, `strategy`, `overflow_recovery`, and
`source_message_id`. An automatic compaction that passes the pre-filter
without `config` or `config_error` answers `:needs_config`: the host reads
its model configuration only then, so idle checks read no control plane. -/
def prepare (state args : Term) : KernelM Term := do
  let .tuple [mode, facts] := args | fail "function_clause"
  let explicit := mode == a "compact"
  let source := facts.get (b "source_message_id")
  let strategy := chosenStrategy (facts.get (b "strategy"))
  let sid ← field state "session_id"
  let done (reason : Term) : KernelM Term := do
    let outcome := result "noop" reason
    return .tuple [a "done", outcome, list (← resultEvents sid outcome source)]
  let live ← compactableLive state
  let last ← lastId state live
  let admitted ← CompactionQuery.admission state (.tuple [Term.bool explicit, last])
  if admitted != a "ok" then return ← done admitted
  if explicit then
    return .tuple [a "summarize", ← plan state mode live last false nil strategy source]
  let recovery := (facts.get (b "overflow_recovery")).truthy
  let threshold := facts.get (b "threshold")
  let prefilterWindow := (facts.get (b "context_tokens")).default (i minWindow)
  let prefilter := (← overflowPending state) ||
    (← shouldCompact state threshold prefilterWindow (facts.get (b "model")))
  if !recovery && !prefilter then return ← done (a "below_prefilter")
  let config := configOf facts
  if !config.isMap && !facts.has (b "config_error") then return a "needs_config"
  if !config.isMap then
    return .tuple [a "fail", ← plan state mode live last true nil strategy source,
      .tuple [a "session_config", facts.get (b "config_error")]]
  let windowTokens := (facts.get (b "context_tokens")).default (window config)
  let model := (facts.get (b "model")).default (config.get (b "model"))
  let fingerprint ← fingerprint config windowTokens
  if !recovery && !(← shouldCompact state threshold windowTokens model) then
    return ← done (a "below_context_window")
  let block ← CompactionQuery.autoCompactionBlockResult state
    (.tuple [fingerprint, last, ← seconds])
  if block.get (b "reason") == b "compaction_recovery_active" then
    return ← done (a "compaction_recovery_active")
  if block.get (b "reason") == b "compaction_backoff" then
    return ← done (.tuple [a "compaction_backoff", block.get (b "next_retry_at")])
  return .tuple [a "summarize", ← plan state mode live last true fingerprint strategy source]

/-! ## The request (Willow `Compact`) -/

/-- `Compaction.provider_output_ids/1`: call ids answered inside provider items. -/
private def providerOutputIds (messages : List Term) : List Term :=
  messages.flatMap (fun message =>
    let providerMeta := (CompactionQuery.both message "provider_meta").default (.map [])
    let items := CompactionQuery.listItems
      ((providerMeta.get (b "responses_items")).default (providerMeta.get (a "responses_items")))
    items.filterMap (fun item =>
      let kind := (item.get (b "type")).default (item.get (a "type"))
      let id := (item.get (b "call_id")).default (item.get (a "call_id"))
      if kind == b "function_call_output" && id != nil && id != b "" then some id else none))

/-- `Compaction.put_existing_key/4`. -/
private def putExisting (map : Term) (key : String) (value : Term) : Term :=
  if map.has (a key) then map.put (a key) value
  else if map.has (b key) then map.put (b key) value
  else map.put (a key) value

private def incompleteCall (ids : List Term) (item : Term) : Bool :=
  if item.has (b "type") && item.has (b "call_id") && item.get (b "type") == b "function_call" then
    !ids.contains (item.get (b "call_id"))
  else if item.has (a "type") && item.has (a "call_id") && item.get (a "type") == b "function_call" then
    !ids.contains (item.get (a "call_id"))
  else false

/-- `Compaction.drop_incomplete_tool_requests/1`: an assistant keeps only the
tool calls whose results are in the request. -/
def dropIncomplete (messages : List Term) : KernelM (List Term) := do
  let tools ← messages.filterM (fun message => do
    return (← CompactionQuery.messageRole message) == b "tool")
  let ids := (tools.map CompactionQuery.toolResultCallId).filter (· != nil) ++ providerOutputIds messages
  messages.mapM (fun message => do
    if (← CompactionQuery.messageRole message) != b "assistant" then return message
    let message := match CompactionQuery.both message "tool_calls" with
      | .list calls => putExisting message "tool_calls"
          (list (calls.filter (fun call => ids.contains (CompactionQuery.toolCallId call))))
      | _ => message
    let providerMeta := CompactionQuery.both message "provider_meta"
    if !providerMeta.isMap then return message
    match (providerMeta.get (b "responses_items")).default (providerMeta.get (a "responses_items")) with
    | .list items =>
      let providerMeta := putExisting providerMeta "responses_items" (list (items.filter (fun item => !incompleteCall ids item)))
      return putExisting message "provider_meta" providerMeta
    | _ => return message)

/-- The request that summarizes the compactable context: the prompt snapshot
first, attachments inlined, unanswered tool calls dropped. A summary request
ends with the instruction. A context of fewer than two messages, or without a
user turn, is `:skip`.

With `{plan, config, prompt}` the answer carries the message list. With
`{plan, config, prompt, protocol, cfg, tools}` a summary request is encoded
for the provider, as `round_request` encodes a round. -/
def request (state args : Term) : KernelM Term := do
  let (plan, config, prompt, wire) ← match args with
    | .tuple [plan, config, prompt] => pure (plan, config, prompt, none)
    | .tuple [plan, config, prompt, protocol, cfg, tools] => pure (plan, config, prompt, some (protocol, cfg, tools))
    | _ => fail "function_clause"
  -- `config` is a model configuration, or compaction facts that carry one.
  let strategy := (plan.get (b "strategy")).default
    ((configStrategy ((configOf config).default config)).default (b "summary"))
  let base ← dropUnfinished state (← asList (← Request.context state))
  if base.length < 2 || !base.any (fun message => message.get (a "role") == b "user") then
    return a "skip"
  let messages ← asList (← Request.prepend (list base) prompt)
  let messages ← Attachments.inline messages nil false
  let messages ← dropIncomplete messages
  if strategy == b "openai_responses" then return .tuple [a "provider", list messages]
  let messages := messages ++ [.map [(a "role", b "user"), (a "content", b instruction)]]
  match wire with
  | some (.binary protocol, cfg, tools) =>
    return .tuple [a "summary", ← Provider.Request.encodedBody (String.fromUTF8! protocol) cfg messages
      (← asList tools) "complete"]
  | _ => return .tuple [a "summary", list messages]

/-! ## The outcome -/

private def findBytes (raw pattern : ByteArray) : Option Nat :=
  let limit := raw.size + 1 - pattern.size
  let rec go : Nat → Nat → Option Nat
    | 0, _ => none
    | fuel + 1, start =>
      if start + pattern.size > raw.size then none
      else if raw.extract start (start + pattern.size) == pattern then some start
      else go fuel (start + 1)
  go limit 0

/-- Willow `extractCompactionSummary`: the trimmed body of the first
`<compaction-summary>` block, or `nil`. -/
def extractSummary (textValue : Term) : Term :=
  match textValue with
  | .binary raw =>
    let opening := "<compaction-summary>".toUTF8
    let closing := "</compaction-summary>".toUTF8
    match findBytes raw opening with
    | none => nil
    | some start =>
      let rest := raw.extract (start + opening.size) raw.size
      match findBytes rest closing with
      | none => nil
      | some stop =>
        let body := trim (rest.extract 0 stop)
        if body.isEmpty then nil else .binary body
  | _ => nil

/-- The model answer as an outcome: `{:summary, text}`,
`{:provider_compaction, items}`, `:skip`, or `{:error, reason}`. -/
private def normalize (raw : Term) : Term :=
  match raw with
  | .atom "skip" => raw
  | .tuple [.atom "summary", .binary _] => raw
  | .tuple [.atom "summary_text", textValue] =>
    match extractSummary textValue with
    | .binary body => .tuple [a "summary",
        .binary ("<compacted-context>\n".toUTF8 ++ body ++ "\n</compacted-context>".toUTF8)]
    | _ => .tuple [a "error", a "missing_compaction_summary_tags"]
  | .tuple [.atom "provider_items", .list (item :: rest)] =>
    .tuple [a "provider_compaction", list (item :: rest)]
  | .tuple [.atom "provider_items", _] => .tuple [a "error", a "empty_provider_compaction"]
  | .tuple [.atom "error", _] => raw
  | other => .tuple [a "error", .tuple [a "invalid_compaction_result", other]]

/-- Read a model answer against its plan. A skip and an explicit failure
commit only their result; every other outcome needs the fence. -/
def outcome (state args : Term) : KernelM Term := do
  let .tuple [plan, raw] := args | fail "function_clause"
  let sid ← field state "session_id"
  let source := plan.get (b "source_message_id")
  let resolved := normalize raw
  let only (value : Term) : KernelM Term := do
    return .tuple [a "result", value, list (← resultEvents sid value source)]
  match resolved with
  | .atom "skip" => only (result "skipped" (a "not_enough_context"))
  | .tuple [.atom "error", reason] =>
    if (plan.get (b "auto")).truthy then return .tuple [a "commit", resolved]
    only (result "failed_soft" reason)
  | _ => return .tuple [a "commit", resolved]

/-! ## The commit -/

private def category (reason : Term) : KernelM Term := do
  match reason with
  | .map _ => stringChars ((reason.get (b "category")).default ((reason.get (a "category")).default (b "unknown")))
  | .tuple [.atom "session_config", _] => return b "session_config_error"
  | .atom "missing_compaction_summary_tags" => return b "invalid_compaction_summary"
  | _ => return b "compaction_error"

private def retryable (reason category : Term) : Bool :=
  match reason with
  | .map _ => ((reason.get (b "retryable")).default (reason.get (a "retryable"))) == a "true"
  | _ => category != b "invalid_compaction_summary"

/-- The recovery summary that stands in for a summary the model could not
write. It points the agent to the session recovery file. -/
def recoverySummary (sessionId last category reason : Term) : KernelM Term := do
  let detail := String.fromUTF8! (reasonText reason)
  return b ("<compacted-context>\n" ++
    s!"System recovery summary: automatic context compaction for internal session {← text sessionId} could not complete.\n" ++
    s!"Failure category: {← text category}.\n" ++
    s!"Failure detail: {detail}.\n" ++
    s!"The full raw transcript remains stored in this runtime session journal through message id {Inspect.render last}, but it could not be summarized automatically.\n" ++
    "To recover earlier details when needed, read /.runtime/compaction-recovery.md with fs.read_file. If the fs.read_file result is truncated, continue from its next_start_line.\n" ++
    "Continue from the newest live messages. If earlier details are needed and the runtime file is insufficient, state exactly what is missing instead of inventing recovered facts.\n" ++
    "</compacted-context>")

private def promptEvent (sid prompt : Term) : Term :=
  .map [(b "type", b "session_system_prompt"), (b "session_id", sid), (b "system_prompt", prompt)]

/-- Commit an outcome against the state at commit time. The summarized view
must be unchanged since the plan; a stale view is an error. -/
def commit (state args : Term) : KernelM Term := do
  let .tuple [plan, resolved, prompt] := args | fail "function_clause"
  let sid ← field state "session_id"
  let last := plan.get (b "last_id")
  let source := plan.get (b "source_message_id")
  let check ← CompactionQuery.checkSnapshot state
    (.tuple [plan.get (b "basis"), list (← fencedLive state), last])
  if check != a "ok" then return check
  let finish (events : List Term) (value : Term) (archive : Bool) : KernelM Term := do
    return .tuple [a "ok", list (events ++ (← resultEvents sid value source)), value, Term.bool archive]
  let covered := plan.get (b "covered_seq")
  let sequence := plan.get (b "summary_sequence")
  match resolved with
  | .tuple [.atom "summary", summary] =>
    finish [promptEvent sid prompt, .map [(b "type", b "compaction"), (b "session_id", sid),
      (b "summary", summary), (b "compacted_through", last), (b "compacted_seq", covered),
      (b "summary_sequence", sequence)]] (result "compacted") true
  | .tuple [.atom "provider_compaction", items] =>
    finish [promptEvent sid prompt, .map [(b "type", b "provider_compaction"), (b "session_id", sid),
      (b "provider", b "openai"), (b "protocol", b "responses"), (b "strategy", b "openai_responses"),
      (b "items", items), (b "compacted_through", last), (b "compacted_seq", covered),
      (b "summary_sequence", sequence), (b "created_at", ← seconds)]] (result "compacted") true
  | .tuple [.atom "error", reason] =>
    let category ← category reason
    let events ← CompactionQuery.failureEvents state (.tuple [last, covered, category,
      Term.bool (retryable reason category), .binary (reasonText reason),
      (plan.get (b "fingerprint")).default (b "unresolved"),
      ← recoverySummary sid last category reason])
    finish (← asList events) (result "failed_soft" reason) false
  | _ => fail "function_clause"

/-! ## Results outside a compaction -/

/-- `{result, events}` of a request that settles without running: a noop or a
hard failure bound to its source message. -/
def settledResultEvents (state args : Term) : KernelM Term := do
  let .tuple [status, reason, source] := args | fail "function_clause"
  let value := result (← text status) reason
  return .tuple [value, list (← resultEvents (← field state "session_id") value source)]

/-- The model failure a context overflow ends with when compaction could not
make the request fit. -/
def overflowFailure (reason : Term) : Term :=
  (Provider.Error.base (b "runtime") (b "context_overflow")
    (b "Context remains too large after recovery. Reduce the current input, tool output, or fixed prompt.")).put
    (b "details") (Provider.Error.preview reason)

/-! ## Activation entry -/

/-- How a materialization that runs a round enters its activation. Args:
`{prompt, facts}`, where `facts` are the compaction facts of
`compaction_required?`. The answer holds:

- `compact`: the session compacts first, because compaction is due or a
  context overflow waits for recovery.
- `args`: the `activate` command arguments: no leading events, no input
  high-water mark, the prompt, and an active round.
- `sequential`: a pending guard disposition runs the activation before any
  model call, so the host cannot start the call beside the activation fence. -/
def activationPlan (state args : Term) : KernelM Term := do
  let .tuple [prompt, facts] := args | fail "function_clause"
  return .map [(b "compact", Term.bool (← required state facts)),
    (b "args", .tuple [list [], nil, prompt, a "true"]),
    (b "sequential", Term.bool (← RoundQuery.guardDispositionPending state))]

/-- Name → operation. -/
def table : OpTable :=
  [("compaction_required?", fun state facts => return Term.bool (← required state facts)),
   ("activation_plan", activationPlan),
   ("context_overflow_pending?", fun state _ => return Term.bool (← overflowPending state)),
   ("compaction_window", fun _ config => return window config),
   ("compaction_prepare", prepare),
   ("compaction_request", request),
   ("compaction_outcome", outcome),
   ("compaction_commit", commit),
   ("compaction_result_events", settledResultEvents),
   ("context_overflow_failure", fun _ reason => return overflowFailure reason)]

end VerifiedKernel.Session.CompactionHost
