import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Query.StateCore
import VerifiedKernel.Session.Query.State

/-! Queries ported from SalixAgent.Compaction, ContextProviders, Waits, TurnOutcome, and SessionHistory. See the README query catalog. -/

namespace VerifiedKernel.Session.CompactionQuery
open Data
open VerifiedKernel.Session.StateQuery

/-! ### Shared message readers

`Compaction` reads its transcript with `Map.get/2` rather than `Access`, so the
atom key wins and a struct-shaped value still reads. `message_role/1` funnels the
result through `to_string/1`, which turns `nil` into `""`. -/

/-- `Map.get(map, :key) || Map.get(map, "key")`. -/
@[inline] def both (value : Term) (key : String) : Term :=
  (value.get (a key)).default (value.get (b key))

/-- `Compaction.message_role/1`. -/
def messageRole (message : Term) : KernelM Term := stringChars (both message "role")

/-- `Compaction.message_id/1`. -/
def compactionMessageId (message : Term) : Term := (both message "id").default (i 0)

/-- `Compaction.tool_call_id/1`. -/
def toolCallId (call : Term) : Term := both call "id"

/-- `Compaction.tool_result_call_id/1`, including the legacy `tool_use_id` fallback. -/
def toolResultCallId (message : Term) : Term :=
  (both message "tool_call_id").default (both message "tool_use_id")

/-- `Compaction.int_value/1`: integers pass, complete decimal text parses, and
everything else — floats included — is zero. -/
def intValue (value : Term) : Term :=
  match value with
  | .integer n => i n
  | .binary _ => i (integerValue value)
  | _ => i 0

/-- The list a value enumerates when `Enum` is given a plain list, else `[]`. -/
def listItems (value : Term) : List Term :=
  match value with | .list xs => xs | _ => []

/-! ### `Compaction.live_messages/1` -/

/-- `Compaction.historical_project_knowledge?/1`. -/
def historicalProjectKnowledge (message : Term) : KernelM Bool := do
  if (← messageRole message) != b "runtime" then return false
  return (← pick message "type") == b "project_knowledge"

/-- The atom-keyed fields `model_message/1` copies out of a runtime message, in order. -/
def runtimeModelFields : List String :=
  ["id", "role", "kind", "runtime_message_id", "ifc", "type", "source_tool_call_id",
   "result_seq", "wait_id", "reason", "timeout_seconds", "deadline_ms", "source",
   "tool_call_id", "tool_call_ids", "failed_tool_calls",
   "pending_external_callback_tool_calls", "failed_llm_call", "diagnostic_visibility",
   "public_summary", "visible_reply_origin", "summary", "content_kind", "content",
   "source_refs"]

/-- `Compaction.model_message/1` for a message whose atom `:role` is `"runtime"`:
the fixed projection, with `role` and `kind` literal and every `nil` dropped. -/
def runtimeModelMessage (message : Term) : KernelM Term := do
  let read (name : String) : KernelM Term :=
    if name == "role" then pure (b "runtime")
    else if name == "kind" then pure (b "runtime_message")
    else access message (a name)
  let pairs ← runtimeModelFields.mapM (fun name => do return (a name, ← read name))
  return .map (pairs.filter (fun pair => pair.2 != nil))

/-- `Compaction.model_message/1`: the runtime projection, else
`ContextProviders.strip_llm_private_metadata/1`. -/
def modelMessage (message : Term) : KernelM Term := do
  if message.isMap && message.get (a "role") == b "runtime" then
    return ← runtimeModelMessage message
  match message with
  | .map entries =>
    -- One pass for the four keys; a message without them stays as it is.
    let private? := fun (key : Term) => key == a "accepted_input" || key == b "accepted_input" ||
      key == a "do_not_send_to_llm" || key == b "do_not_send_to_llm"
    if entries.any (fun (key, _) => private? key) then
      return .map (entries.filter (fun (key, _) => !private? key))
    return message
  | _ => return message

/-- `Compaction.live_messages/1`: the masked window after the watermark, without
runtime events and historical project knowledge, projected for the model. -/
def liveMessages (state : Term) : KernelM Term := do
  let watermark := (← field state "compacted_through").default (i 0)
  let masked ← asList (← maskedMessages state)
  let kept ← masked.filterM (fun message => do
    greater ((message.get (a "id")).default (i 0)) watermark)
  let kept ← kept.filterM (fun message => do return (← messageRole message) != b "event")
  let kept ← kept.filterM (fun message => do return !(← historicalProjectKnowledge message))
  return list (← kept.mapM modelMessage)

/-- `Compaction.request_live_messages/1`: `live_messages/1` with the current
activation's project knowledge still in place. A knowledge block is retrieved
for the activation that asked the question, so it is hidden once a later user
input (one that wakes the session) starts a new activation, and the compaction
summary never sees it. Until then it stays exactly where it was committed:
re-rendering it at the tail of every round moved it each time and broke the
provider's cached prefix at its old position, and a later round that retrieves
the same facts again is a duplicate, so only the first block with a given
content renders. -/
def requestLiveMessages (state : Term) : KernelM Term := do
  -- `ProjectKnowledgeContext.prepare/3` also asks this of a bare message map,
  -- so the state fields are read with defaults rather than fetched.
  let watermark := (state.get (a "compacted_through")).default (i 0)
  let masked ← if (state.get (a "redactions")).truthy then asList (← maskedMessages state)
    else pure (listItems ((state.get (a "messages")).default (list [])))
  let kept ← masked.filterM (fun message => do
    greater ((message.get (a "id")).default (i 0)) watermark)
  let kept ← kept.filterM (fun message => do return (← messageRole message) != b "event")
  let boundary ← kept.foldlM (fun latest message => do
    if (← messageRole message) != b "user" then return latest
    if (← pick message "no_wake") == a "true" then return latest
    maximum (compactionMessageId message) latest) (i 0)
  let mut seen : List Term := []
  let mut current : List Term := []
  for message in kept do
    if ← historicalProjectKnowledge message then
      if !(← greater (compactionMessageId message) boundary) then continue
      let content ← pick message "content"
      if seen.contains content then continue
      seen := content :: seen
    current := message :: current
  return list (← current.reverse.mapM modelMessage)

/-! ### `Compaction.context/1` prefix -/

/-- `Compaction.provider_compaction_items/1`: the string-keyed shape is tried
whole before the atom-keyed one, as the two function clauses do. -/
def providerCompactionItems (state : Term) : KernelM Term := do
  let compaction ← field state "provider_compaction"
  if !compaction.isMap then return nil
  let byText := if compaction.get (b "protocol") == b "responses" then
    compaction.get (b "items") else nil
  match byText with
  | .list (_ :: _) => return byText
  | _ =>
    let byAtom := if compaction.get (a "protocol") == b "responses" then
      compaction.get (a "items") else nil
    match byAtom with
    | .list (_ :: _) => return byAtom
    | _ => return nil

/-- The summary or provider prefix `Compaction.context/1` puts in front of the
live window. -/
def contextPrefix (state : Term) : KernelM Term := do
  let items ← providerCompactionItems state
  if items.truthy then
    return list [.map [(a "id", i 0), (a "role", b "provider_context"), (a "content", b ""),
      (a "provider_meta", .map [(b "responses_items", items)])]]
  let summary ← field state "summary"
  if summary.truthy then
    return list [.map [(a "id", i 0), (a "role", b "summary"), (a "content", summary)]]
  return list []

/-! ### `Compaction.unfinished_activation_start_id/2`

The argument is the already-projected message list; the state supplies the
acknowledgement watermark, the human-source rule, and the continuation gate. -/

/-- `Compaction.fresh_user_input_start_id/2`. -/
def freshUserInputStartId (state : Term) (messages : List Term) : KernelM Term := do
  let assistants ← messages.filterM (fun message => do
    return (← messageRole message) == b "assistant")
  let observed ← assistants.foldlM (fun through message => do
    let boundary ← pick message "request_input_through"
    if boundary.isInteger && integerValue boundary ≥ 0 then maximum boundary through
    else pure through) ((← field state "last_ack_message_id").default (i 0))
  let found ← findFirst (fun message => do
    if (← messageRole message) != b "user" then return false
    if !(← greater (compactionMessageId message) observed) then return false
    return (← pick message "no_wake") != a "true") messages
  if found == nil then return nil
  return compactionMessageId found

/-- `Compaction.human_source_activation_start_id/2`. -/
def humanSourceActivationStartId (state : Term) (messages : List Term) : KernelM Term := do
  let lastAck := (← field state "last_ack_message_id").default (i 0)
  let found ← findFirst (fun message => do
    if (← messageRole message) != b "user" then return false
    if !(← greater (compactionMessageId message) lastAck) then return false
    if both message "no_wake" == a "true" then return false
    humanSourceOrigin (both message "trusted_origin")) messages
  if found == nil then return nil
  return compactionMessageId found

/-- `Compaction.assistant_tool_call_ids/1`: native call ids plus `responses_items`
function calls, with blanks dropped. -/
def assistantToolCallIds (message : Term) : List Term :=
  let native := if message.has (a "tool_calls") then wrap (message.get (a "tool_calls"))
    else if message.has (b "tool_calls") then wrap (message.get (b "tool_calls"))
    else []
  let nativeIds := native.map toolCallId
  let providerMeta := both message "provider_meta"
  let items := if providerMeta.isMap then
    listItems ((providerMeta.get (a "responses_items")).default (providerMeta.get (b "responses_items")))
    else []
  let providerIds := ((items.filter Term.isMap).filter
    (fun item => both item "type" == b "function_call")).map (fun item => both item "call_id")
  (nativeIds ++ providerIds).filter (fun id => id != nil && id != b "")

/-- `Compaction.tool_continuation_start_id/2`. -/
def toolContinuationStartId (state : Term) (messages : List Term) : KernelM Term := do
  if !(← needsContinuation state) then return nil
  let (results, earlier) ← splitWhile (fun message => do
    return (← messageRole message) == b "tool") messages.reverse
  let resultIds := (results.map toolResultCallId).filter (fun id => id != nil && id != b "")
  let request ← findFirst (fun message => do
    if (← messageRole message) != b "assistant" then return false
    return (assistantToolCallIds message).any (fun id => resultIds.any (· == id))) earlier
  let chosen := if request != nil then request else results.getLast?.getD nil
  if chosen == nil then return nil
  return compactionMessageId chosen

/-- `Compaction.unfinished_activation_start_id/2`: the earliest boundary that must
stay verbatim in the live window, or `nil`. -/
def unfinishedActivationStartId (state args : Term) : KernelM Term := do
  let messages := wrap args
  let candidates := [← freshUserInputStartId state messages,
    ← humanSourceActivationStartId state messages, ← pendingAssistantId state,
    ← toolContinuationStartId state messages]
  match candidates.filter (· != nil) with
  | [] => return nil
  | first :: rest => rest.foldlM minimum first

/-! ### Automatic compaction backoff -/

/-- `Compaction.auto_compaction_block_result/3` on args
`{config_fingerprint, last_id, now}`: `nil`, or the reason map the caller turns
into a `noop` compact result. -/
def autoCompactionBlockResult (state args : Term) : KernelM Term := do
  let .tuple [fingerprint, lastId, now] := args | fail "function_clause"
  let failure ← field state "compaction_failure"
  if !failure.isMap then return nil
  if failure.get (b "config_fingerprint") != fingerprint then return nil
  if failure.get (b "recovery_summary_written") == a "true" &&
      (← atMost lastId (intValue (failure.get (b "live_context_watermark")))) then
    return .map [(b "reason", b "compaction_recovery_active")]
  if failure.get (b "retryable") == a "true" &&
      (← greater (intValue (failure.get (b "next_retry_at"))) now) then
    return .map [(b "reason", b "compaction_backoff"),
      (b "next_retry_at", failure.get (b "next_retry_at"))]
  return nil

/-! ### Async result window -/

/-- `Compaction.resolve_async_result_for_request/3`: the window record for `seq`,
or `nil` when only the archive still holds it. -/
def asyncResultRecord (state args : Term) : KernelM Term := do
  if !args.isInteger then fail "function_clause"
  let records := (← field state "async_results").default (list [])
  enumFind records (fun record => do return (← access record (b "seq")) == args)

/-! ### `SalixAgent.ContextProviders` -/

/-- `ContextProviders.adopted_message?/1`. -/
def adoptedMessage (messages : Term) : KernelM Bool := do
  match messages with
  | .list xs => return xs.any (fun message =>
      message.isMap && (let role := both message "role"
        role == b "assistant" || role == b "tool"))
  | _ => return false

/-- `ContextProviders.adopted_llm_context?/1` over a session state. -/
def adoptedLlmContext (state : Term) : KernelM Bool := do
  if ← adoptedMessage ((← field state "messages").default (list [])) then return true
  let compaction ← field state "provider_compaction"
  if compaction.isMap then
    if !(← entries compaction).isEmpty then return true
  match ← field state "summary" with
  | .binary raw => return !(trim raw).isEmpty
  | .atom "nil" => return false
  | _ => return true

/-- The newest `"user"` message, which is the only one `TimeContext.prepare/3`
reads out of the session. -/
def latestUserInputMessage (state : Term) : KernelM Term := do
  let messages ← asList ((← field state "messages").default (list []))
  findFirst (fun message => do return both message "role" == b "user") messages.reverse

/-! ### Registry -/

private def summarizedView (messages lastId : Term) : KernelM Term := do
  return list (← (← asList messages).filterM (fun message => do
    let id := both message "id"
    return id.isInteger && (← atMost id lastId)))

/-- Capture the coordinates and exact provider view used by a compaction request. -/
def snapshot (state args : Term) : KernelM Term := do
  let .tuple [messages, lastId] := args | fail "function_clause"
  return .tuple [← field state "storage_format", ← field state "summary_sequence",
    ← field state "compacted_through", ← summarizedView messages lastId]

/-- Admit a completed request against the current coordinates and sanitized view. -/
def checkSnapshot (state args : Term) : KernelM Term := do
  let .tuple [.tuple [format, sequence, watermark, expected], messages, lastId] := args
    | fail "function_clause"
  let currentFormat ← field state "storage_format"
  let currentSequence ← field state "summary_sequence"
  let currentWatermark ← field state "compacted_through"
  if format == i 1 && (← atMost (i 2) currentFormat) then
    return .tuple [a "error", .tuple [a "stale_compaction_snapshot", .map [
      (a "expected_storage_format", i 1), (a "actual_storage_format", currentFormat)]]]
  if !Term.numericEq sequence currentSequence || !Term.numericEq watermark currentWatermark then
    return .tuple [a "error", .tuple [a "stale_compaction_snapshot", .map [
      (a "expected_summary_sequence", sequence), (a "actual_summary_sequence", currentSequence),
      (a "expected_compacted_through", watermark), (a "actual_compacted_through", currentWatermark)]]]
  let actual ← summarizedView messages lastId
  if Term.numericEq actual expected then return a "ok"
  return .tuple [a "stale_compaction_view", expected, actual]

private def query (f : Term → KernelM Term) : Op := fun state _ => f state
private def predicate (f : Term → KernelM Bool) : Op :=
  fun state _ => return Term.bool (← f state)

def admission (state args : Term) : KernelM Term := do
  let .tuple [explicit, lastId] := args | fail "function_clause"
  if explicit.truthy && (← StateQuery.repairRequired state) then return a "visible_reply_repair_required"
  if (← field state "status") == a "active" then return a "session_active"
  if ← atMost lastId (← field state "compacted_through") then return a "no_new_live_messages"
  return a "ok"

def failureEvents (state args : Term) : KernelM Term := do
  let .tuple [watermark, covered, category, retryable, reason, fingerprint, summary] := args
    | fail "function_clause"
  let sid ← field state "session_id"
  let previous ← field state "compaction_failure"
  let count := previous.get (b "attempts")
  let attempts := if previous.get (b "config_fingerprint") == fingerprint && count.isInteger then
    integerValue count + 1 else 1
  let recover := category == b "context_overflow" || !retryable.truthy || attempts ≥ 3
  let now := integerValue (← observe (a "time")) / 1000
  let failure := Term.map [(b "type", b "compaction_failure"), (b "session_id", sid),
    (b "category", category), (b "retryable", retryable), (b "reason", reason),
    (b "attempts", i attempts), (b "live_context_watermark", watermark),
    (b "config_fingerprint", fingerprint), (b "failed_at", i now), (b "recovery_summary_written", Term.bool recover)]
  let delay := ([30, 120, 300, 600] : List Int)[(max 0 (attempts - 1)).toNat]?.getD 600
  let failure := if retryable.truthy && !recover then failure.put (b "next_retry_at") (i (now + delay)) else failure
  if !recover then return list [failure]
  let sequence ← add (← field state "summary_sequence") (i 1)
  return list [
    .map [(b "type", b "compaction"), (b "session_id", sid), (b "summary", summary),
      (b "compacted_through", watermark), (b "compacted_seq", covered), (b "summary_sequence", sequence)],
    failure,
    .map [(b "type", b "compaction_recovery"), (b "session_id", sid), (b "kind", b "compaction_recovery"),
      (b "category", category), (b "reason", reason), (b "compacted_through", watermark),
      (b "summary_sequence", sequence), (b "created_at", i now)]]

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("compaction_live_messages", query liveMessages),
   ("request_live_messages", query requestLiveMessages),
   ("compaction_admission", admission),
   ("compaction_failure_events", failureEvents),
   ("compaction_snapshot", snapshot),
   ("check_compaction_snapshot", checkSnapshot),
   ("compaction_context_prefix", query contextPrefix),
   ("provider_compaction_items", query providerCompactionItems),
   ("unfinished_activation_start_id", unfinishedActivationStartId),
   ("auto_compaction_block_result", autoCompactionBlockResult),
   ("async_result_record", asyncResultRecord),
   ("adopted_llm_context?", predicate adoptedLlmContext),
   ("latest_user_input_message", query latestUserInputMessage)]

end VerifiedKernel.Session.CompactionQuery
