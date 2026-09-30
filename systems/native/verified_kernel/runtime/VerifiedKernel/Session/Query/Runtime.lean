import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Query.StateCore
import VerifiedKernel.Session.Query.State

/-! Queries ported from SalixAgent.InternalAgentRuntime and the other runtime consumers of the session. See the README query catalog. -/

namespace VerifiedKernel.Session.RuntimeQuery
open Data
open VerifiedKernel.Session.StateQuery

/-! ### Shared readers -/

/-- `session_value/2`: the string key, then the atom key. -/
private def sessionValue (state : Term) (name : String) : Term :=
  (state.get (b name)).default (state.get (a name))

/-- `msg_value/2`: `Map.get(msg, :key) || Map.get(msg, "key")` — no Access, so a struct reads too. -/
private def msgValue (message : Term) (name : String) : Term :=
  (message.get (a name)).default (message.get (b name))

/-- `Integer.parse/1` semantics: a leading sign, then the longest digit run. -/
private def prefixInteger (value : Term) : Int :=
  match value with
  | .integer n => n
  | .floatBits _ => integerValue value
  | .binary raw =>
    match String.fromUTF8? raw with
    | some text =>
      let chars := text.toList
      let (negative, rest) := match chars with
        | '-' :: tail => (true, tail)
        | '+' :: tail => (false, tail)
        | _ => (false, chars)
      let digits := rest.takeWhile (fun c => c ≥ '0' && c ≤ '9')
      if digits.isEmpty then 0
      else
        let magnitude : Nat := digits.foldl (fun n c => n * 10 + c.toNat - 48) 0
        if negative then -(Int.ofNat magnitude) else Int.ofNat magnitude
    | none => 0
  | _ => 0

/-- `to_string_or_empty/1`: `nil` is the empty string, a binary passes through. -/
private def stringOrEmpty (value : Term) : KernelM Term :=
  if value == nil then return b "" else stringChars value

/-- `Enum.join/2` over the text parts. -/
-- A part that is not a binary contributes no bytes but still takes a
-- separator. One left fold over a uniquely owned accumulator keeps the join
-- linear in the total size, where a right-recursive `head ++ rest` copied the
-- whole tail once per part.
private def joinText (separator : String) (parts : List Term) : ByteArray :=
  let sep := separator.toUTF8
  (parts.foldl (fun (acc, first) part =>
    let raw := match part with | .binary raw => raw | _ => ByteArray.empty
    (if first then acc ++ raw else acc ++ sep ++ raw, false)) (ByteArray.empty, true)).1

/-! ### `SalixAgent.InternalAgentRuntime` -/

/-- `session_json/2`: the listing projection, `nil` values dropped.

`compact/1` and `put_optional/3` both drop only `nil`, so `hidden: false`
survives while an unset watermark leaves the map entirely. -/
def sessionJson (state agentId : Term) : KernelM Term := do
  let lastId ← maximum (← sub ((← field state "next_message_id").default (i 1)) (i 1)) (i 0)
  let created := (← field state "created_at").default (i 0)
  let entries : List (Term × Term) :=
    [(b "session_id", ← field state "session_id"),
     (b "agent_id", agentId),
     (b "runtime_kind", b "internal"),
     (b "name", (← field state "name").default (b "Untitled")),
     (b "hidden", Term.bool ((← field state "hidden") == a "true")),
     (b "status", ← stringChars (← field state "status")),
     (b "activity_status", ← stringChars (← activity state)),
     (b "activity_status_updated_at", ← field state "activity_status_updated_at"),
     (b "activity_revision",
       (← field state "activity_revision").default (← field state "storage_revision")),
     (b "created_at", created),
     (b "last_activity_at", (← field state "last_activity_at").default created),
     (b "message_count", ← totalMessageCount state),
     (b "archived_through", (← field state "archived_through").default (i 0)),
     (b "last_ack_message_id", ← field state "last_ack_message_id"),
     (b "last_message_id", lastId),
     (b "compacted_through", (← field state "compacted_through").default (i 0)),
     (b "summary_sequence", (← field state "summary_sequence").default (i 0)),
     (b "fork_request_id", ← field state "fork_request_id"),
     (b "issue", ← activityIssue state),
     (b "source_agent_id", ← field state "source_agent_id"),
     (b "source_session_id", ← field state "source_session_id"),
     (b "source_schedule_id", ← field state "source_schedule_id"),
     (b "conversation_sources", ← field state "conversation_sources"),
     (b "compaction_failure", ← field state "compaction_failure")]
  return .map (entries.filter (fun pair => pair.2 != nil))

/-- `compact_result_for/2`: the explicit field first, the format-1 fact scan second. -/
def compactResultFor (state sourceId : Term) : KernelM Term := do
  let results := (← field state "compact_results").default empty
  if !results.isMap then fail "badmap" [results]
  let direct := results.get sourceId
  if direct.truthy then return direct
  enumFind ((← field state "events").default (list [])) (fun fact => do
    if msgValue fact "kind" != b "session_compact_result" then return false
    return msgValue fact "source_message_id" == sourceId)

/-- `emergency_compact_result/2`: the recorded redaction watermark, the pre-format-2
transcript head, or `nil` when a format-2 session recorded no result. -/
def emergencyCompactThroughId (state : Term) : KernelM Term := do
  let found ← enumFind ((← field state "redactions").default (list []))
    (fun entry => return (← access entry (b "kind")) == b "non_model_messages_over_bytes_through")
  let through := found.get (b "through_id")
  if found.isMap && through.isInteger then return through
  let format ← field state "storage_format"
  if format.isInteger && integerValue format ≥ 2 then return nil
  maximum (← sub ((← field state "next_message_id").default (i 1)) (i 1)) (i 0)

/-- `session_trace_lineage/4`'s parent pointer: only a same-agent fork has a lineage. -/
def lineageSourceSessionId (state : Term) : KernelM Term := do
  let source ← field state "source_agent_id"
  if source == nil || source == b "" || source == (← field state "agent_id") then
    return ← field state "source_session_id"
  return nil

/-! ### `SalixAgent.Titles` -/

/-- `Titles.message_role/1`. -/
private def messageRole (message : Term) : KernelM Term := do
  stringChars ((← aliases message [a "role", b "role"]).default (b ""))

/-- `Titles.has_assistant?/1`. -/
def titleHasAssistant (state : Term) : KernelM Bool := do
  enumAny (← field state "messages") (fun message => do
    return (← messageRole message) == b "assistant")

/-- `Titles.normalize_content/1`: willow's text-part flattening. -/
def normalizeContent (content : Term) : KernelM Term := do
  match content with
  | .binary raw => return .binary (trim raw)
  | .list blocks =>
    let parts ← blocks.mapM (fun block => do
      if block.get (b "type") == b "text" && block.has (b "text") then
        stringChars (block.get (b "text"))
      else if block.get (a "type") == b "text" && block.has (a "text") then
        stringChars (block.get (a "text"))
      else if block.isBinary then pure block
      else pure (b ""))
    return .binary (trim (joinText "\n" (parts.filter (fun part => part != b ""))))
  | _ => return b ""

/-- `Titles.first_user_content/1` before the 2000-character truncation. -/
def titleSourceContent (state : Term) : KernelM Term := do
  let found ← enumFind (← field state "messages") (fun message => do
    return (← messageRole message) == b "user")
  if found == nil then return b ""
  normalizeContent (← aliases found [a "content", b "content"])

/-! ### `SalixAgent.RuntimeFiles` -/

/-- `RuntimeFiles.value/2`: the string key, then the atom key, on a `nil` miss. -/
private def recoveryValue (value : Term) (name : String) : Term :=
  let found := value.get (b name)
  if found == nil then value.get (a name) else found

/-- `RuntimeFiles.latest_recovery/1`: the recorded recovery, the trailing format-1
fact, or the failure record once its summary landed. -/
def latestCompactionRecovery (state : Term) : KernelM Term := do
  let direct := state.get (a "last_compaction_recovery")
  let recovery ← if direct.truthy then pure direct else
    enumFind (list (wrap (← field state "events")).reverse) (fun fact => do
      return recoveryValue fact "kind" == b "compaction_recovery")
  if recovery.isMap then return recovery
  let failure ← field state "compaction_failure"
  if !failure.isMap then return nil
  if (← access failure (b "recovery_summary_written")) != a "true" then return nil
  let createdAt ← alias failure (b "created_at") (b "failed_at")
  merge failure (.map
    [(b "kind", b "compaction_recovery"),
     (b "compacted_through", ← field state "compacted_through"),
     (b "summary_sequence", ← field state "summary_sequence"),
     (b "created_at", createdAt)])

/-! ### `SalixAgent.Billing` -/

private def usageTokens (message : Term) (first second : String) : Int :=
  prefixInteger ((msgValue message first).default (msgValue message second))

/-- `usage_cache_read_tokens/1`: the flat field, else the OpenAI prompt-token detail. -/
private def cacheReadTokens (message : Term) : KernelM Int := do
  let flat := msgValue message "cache_read_input_tokens"
  if flat.truthy then return prefixInteger flat
  let details ← access (message.default empty) (b "prompt_tokens_details")
  return prefixInteger (← access details (b "cached_tokens"))

/-- `Billing.internal_session_billing_entries/3` over `{model, provider_type}`. -/
def billingEntries (state args : Term) : KernelM Term := do
  let .tuple [model, providerType] := args | fail "function_clause"
  let sessionId := sessionValue state "session_id"
  let messages := wrap (sessionValue state "messages")
  let rows ← messages.mapM (fun message => do
    let input := usageTokens message "prompt_tokens" "input_tokens"
    let output := usageTokens message "completion_tokens" "output_tokens"
    if msgValue message "role" != b "assistant" || input + output ≤ 0 then return list []
    let declared := prefixInteger (msgValue message "total_tokens")
    let total := if declared > 0 then declared else input + output
    let steps := (wrap (msgValue message "tool_calls")).length
    return list [.map
      [(b "session_id", sessionId),
       (b "message_id", i (prefixInteger (msgValue message "id"))),
       (b "step_count", i (Int.ofNat steps)),
       (b "model", ← stringOrEmpty ((msgValue message "model").default model)),
       (b "provider_type", providerType),
       (b "call_kind", b "agent"),
       (b "input_tokens", i input),
       (b "output_tokens", i output),
       (b "total_tokens", i total),
       (b "cache_read_input_tokens", i (← cacheReadTokens message)),
       (b "cache_write_input_tokens",
         i (usageTokens message "cache_write_input_tokens" "cache_creation_input_tokens")),
       (b "cost_micros", i 0),
       (b "created_at", i (prefixInteger (msgValue message "created_at")))]])
  return list (rows.flatMap wrap)

/-! ### `SalixAgent.MeetingRuntime` -/

/-- `MeetingRuntime.event_committed?/3`: the durable source-id ledger. -/
def inputDedupeMember (state sourceId : Term) : KernelM Bool := do
  setMember (← field state "input_dedupe") sourceId

/-! ### `SalixAgent.MemoryConsultationRuntime` -/

/-- `MemoryConsultationRuntime.snapshot_id/1`. -/
def snapshotId (state : Term) : KernelM Term := do
  let revision ← field state "storage_revision"
  if revision.truthy then return revision
  let .binary seq ← stringChars ((← field state "last_seq").default (i 0)) | fail "badarg"
  return .binary ("seq:".toUTF8 ++ seq)

/-! ### Registry -/

private def query (f : Term → KernelM Term) : Op := fun state _ => f state
private def predicate (f : Term → KernelM Bool) : Op :=
  fun state _ => return Term.bool (← f state)

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("session_json", sessionJson),
   ("compact_result_for", compactResultFor),
   ("emergency_compact_through_id", query emergencyCompactThroughId),
   ("lineage_source_session_id", query lineageSourceSessionId),
   ("title_has_assistant?", predicate titleHasAssistant),
   ("title_source_content", query titleSourceContent),
   ("latest_compaction_recovery", query latestCompactionRecovery),
   ("internal_session_billing_entries", billingEntries),
   ("input_dedupe_member?", fun state args => return Term.bool (← inputDedupeMember state args)),
   ("session_snapshot_id", query snapshotId)]

end VerifiedKernel.Session.RuntimeQuery
