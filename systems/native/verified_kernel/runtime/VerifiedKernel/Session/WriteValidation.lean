import VerifiedKernel.Session.History
import VerifiedKernel.Session.Replies
import VerifiedKernel.Encoding
import VerifiedKernel.Session.Ops

/-! # Write validation

Every Session write passes `validate_events` before it applies. The command
driver asks its host `{:validate_write, events}`; a host answers with this
query. The storage commit paths use the same query.

The rules are the ones `SalixAgent.InternalSession.State.validate_events/1`
applied: the first failing event returns `{:error, reason}`, and the reasons
keep their names. -/

namespace VerifiedKernel.Session.WriteValidation
open Data

private def err (reason : Term) : Term := .tuple [a "error", reason]
private def ok : Term := a "ok"

/-- `missing_text?/1`: blank text or `nil`. Any other value is present. -/
private def missingText (value : Term) : Bool :=
  match value with
  | .binary raw => (trim raw).isEmpty
  | .atom "nil" => true
  | _ => false

/-- `Elixir left || right`. -/
private def orElse (left right : Term) : Term := left.default right

private def identities (values : List Term) : List Term :=
  (values.filter (fun value => !missingText value)).eraseDups

private def isString (value : Term) (set : List String) : Bool :=
  set.any (fun name => value == b name)

private def isText (value : Term) (set : List String) : Bool :=
  set.any (fun name => value == b name || value == a name)

private def positive (value : Term) : Bool :=
  match value with | .integer n => n > 0 | _ => false

private def presentValidString (value : Term) : Bool :=
  match value with
  | .binary raw => raw.validateUTF8 && !(trim raw).isEmpty
  | _ => false

/-! ## Queue appends -/

private def validateQueueAppend (event : Term) : KernelM Term := do
  if !event.has (b "kind") then fail "function_clause"
  let kind := event.get (b "kind")
  if !isString kind ["user_message", "runtime_message"] then
    return err (.tuple [a "invalid_queue_kind", kind])
  let payload := orElse (event.get (b "payload")) (.map [])
  -- The Elixir rule read fields of the payload, so a payload that is not a
  -- map raised. It still does.
  if !payload.isMap then fail "badarg"
  let payload ← stringify payload
  let base := [event.get (b "dedupe_key"), event.get (b "source_message_id"), payload.get (b "source_message_id")]
  if kind == b "user_message" then
    if (identities base).isEmpty then return err (a "user_message_identity_required")
    let role := orElse (payload.get (b "role")) (b "user")
    if !isString role ["user", "summary"] then return err (a "user_message_role_invalid")
    if role == b "summary" && event.get (b "wake") != a "false" then
      return err (a "summary_message_must_be_no_wake")
    return ok
  if (identities (base ++ [payload.get (b "runtime_message_id")])).isEmpty then
    return err (a "runtime_message_identity_required")
  return ok

/-! ## Runtime messages -/

private def runtimeIdentity (event : Term) : Bool :=
  !(identities [event.get (b "dedupe_key"), event.get (b "source_message_id"),
    event.get (b "runtime_message_id")]).isEmpty

/-! ## Transcript seeds -/

private def seedToolCallId (entry : Term) : Term :=
  orElse (entry.get (b "tool_call_id")) (orElse (entry.get (b "tool_use_id")) (entry.get (b "call_id")))

private def seedHasToolCalls (entry : Term) : Bool :=
  match entry.get (b "tool_calls") with
  | .list calls => !calls.isEmpty
  | .atom "nil" => false
  | _ => true

private def validSeedToolCalls (calls : Term) : Bool :=
  match calls with
  | .atom "nil" => true
  | .list calls => calls.all (fun call =>
      call.isMap && call.has (b "id") && call.has (b "name") && call.has (b "args") &&
        !missingText (call.get (b "id")) && !missingText (call.get (b "name")) && (call.get (b "args")).isMap)
  | _ => false

private def validateSeedEntry (entry : Term) : Term :=
  if !entry.isMap || !entry.has (b "role") then err (a "invalid_transcript_seed_entry") else
  let role := entry.get (b "role")
  let content := if role == b "runtime" then orElse (entry.get (b "content")) (entry.get (b "summary"))
    else entry.get (b "content")
  let contentMissing := if role == b "assistant" then missingText content && !seedHasToolCalls entry
    else missingText content
  if !isString role ["user", "assistant", "runtime", "summary", "tool"] then
    err (.tuple [a "invalid_transcript_seed_role", role])
  else if (identities [entry.get (b "dedupe_key"), entry.get (b "source_message_id"),
      entry.get (b "runtime_message_id"), seedToolCallId entry]).isEmpty then
    err (a "transcript_seed_stable_identity_required")
  else if role == b "tool" && missingText (seedToolCallId entry) then
    err (a "transcript_seed_tool_call_id_required")
  else if contentMissing then err (a "transcript_seed_content_required")
  else if role == b "assistant" && !validSeedToolCalls (entry.get (b "tool_calls")) then
    err (a "transcript_seed_invalid_tool_calls")
  else if role != b "assistant" && seedHasToolCalls entry then
    err (a "transcript_seed_tool_calls_only_supported_on_assistant")
  else ok

private def validateSeed (event : Term) : KernelM Term := do
  match event.get (b "entries") with
  | .list [] => return err (a "transcript_seed_entries_required")
  | .list entries =>
    for entry in entries do
      let result := validateSeedEntry (← stringify entry)
      if result != ok then return result
    return ok
  | _ => return err (a "transcript_seed_entries_required")

/-! ## Stored tool results -/

private def validateStoredResult (event : Term) : KernelM Term := do
  let json := event.get (b "result_json")
  let sha := event.get (b "result_sha256")
  if !validId (event.get (b "session_id")) "ses1" then return err (a "invalid_session_id")
  if !validId (event.get (b "result_ref")) "trf1" then return err (a "invalid_tool_result_ref")
  if !presentValidString (event.get (b "tool_call_id")) then return err (a "invalid_tool_result_tool_call_id")
  if !presentValidString (event.get (b "tool_name")) then return err (a "invalid_tool_result_tool_name")
  let .binary raw := json | return err (a "invalid_tool_result_json")
  let some text := String.fromUTF8? raw | return err (a "invalid_tool_result_json")
  if event.get (b "result_bytes") != i raw.size then return err (a "invalid_tool_result_bytes")
  if event.get (b "result_chars") != i (Grapheme.countString text) then
    return err (a "invalid_tool_result_chars")
  let validSha ← match sha with
    | .binary shaBytes => do
      if shaBytes.size != 64 then pure false
      else pure (shaBytes == hex (← digest raw))
    | _ => pure false
  if !validSha then return err (a "invalid_tool_result_sha256")
  if !presentValidString (event.get (b "status")) then return err (a "invalid_tool_result_status")
  if !(event.get (b "is_error")).isBoolean then return err (a "invalid_tool_result_error_flag")
  match event.get (b "stored_at_ms") with
  | .integer n => if n ≥ 0 then return ok else return err (a "invalid_tool_result_timestamp")
  | _ => return err (a "invalid_tool_result_timestamp")

/-! ## Waits -/

/-- `Waits.validate/1`: a positive integer deadline when present, and a text
or absent wait id. -/
private def validateWait (wait : Term) : KernelM Term := do
  if !wait.isMap then return err (a "invalid_wait")
  let wait ← stringify wait
  if wait.has (b "deadline_ms") && !positive (wait.get (b "deadline_ms")) then return err (a "invalid_wait")
  let id := wait.get (b "wait_id")
  if id.isBinary || id == nil then return ok
  return err (a "invalid_wait")

/-! ## Obligations -/

private def lowerHex (raw : ByteArray) : Bool :=
  raw.toList.all (fun byte => let n := byte.toNat; (48 ≤ n && n ≤ 57) || (97 ≤ n && n ≤ 102))

/-- `ProviderReplyObligation.valid_key?/1`: 64 lowercase hex characters. -/
def validObligationKey (key : Term) : Bool :=
  match key with
  | .binary raw => raw.size == 64 && lowerHex raw
  | _ => false

private def standalone : List String :=
  ["tool_disclosure_revision", "skill_projection_revision", "runtime_context_version", "migration_notice_version"]

private def failureReplyProviders : List String :=
  ["telegram", "internal", "slack", "feishu", "imessage", "wechat", "signal"]

/-! ## One event -/

def validateEvent (raw : Term) : KernelM Term := do
  if !raw.isMap then return err (a "invalid_event")
  let event ← shallowStringify raw
  if !event.has (b "type") then return ok
  let type := event.get (b "type")
  let has := fun (key : String) => event.has (b key)
  let get := fun (key : String) => event.get (b key)
  if type == b "queue_append" then return ← validateQueueAppend event
  if type == b "queue_consume" then
    return if positive (get "queue_id") then ok else err (a "invalid_queue_consume")
  if type == b "runtime_message" && get "from_queue" == a "true" then
    return if runtimeIdentity event then ok else err (a "runtime_message_identity_required")
  if type == b "transcript_seed" then return ← validateSeed event
  if type == b "runtime_message" && get "from_context_provider" == a "true" then
    if !runtimeIdentity event then return err (a "runtime_message_identity_required")
    if get "no_wake" != a "true" then return err (a "context_provider_runtime_message_must_be_no_wake")
    return ok
  if type == b "runtime_message" then return err (a "runtime_message_must_come_from_queue")
  if type == b "delivery" && get "from_queue" == a "true" then return ok
  if type == b "provider_reply_obligation_resolved" then
    return if validObligationKey (get "obligation_key") then ok
      else err (a "invalid_provider_reply_obligation_resolution")
  if type == b "provider_card_obligation_added" then
    let conversation := get "conversation_id"
    let valid := match conversation with
      | .binary raw => !raw.isEmpty && raw.size ≤ 128
      | _ => false
    return if valid && positive (get "limit") then ok else err (a "invalid_provider_card_obligation")
  if type == b "delivery" then return err (a "delivery_must_come_from_queue")
  if type == b "status" && has "status" then
    return if isText (get "status") ["idle", "active"] then ok
      else err (.tuple [a "invalid_internal_session_status", get "status"])
  if type == b "activity_status" && has "activity_status" then
    return if isText (get "activity_status") ["thinking", "execution", "messaging"] then ok
      else err (.tuple [a "invalid_internal_session_activity_status", get "activity_status"])
  if type == b "wait_set" then
    if has "wait" then return ← validateWait (get "wait")
    return err (a "invalid_wait")
  if type == b "capability_request_sync" then
    let id := get "tool_call_id"
    return if id.isBinary && id != b "" then ok else err (a "invalid_capability_request_sync")
  if type == b "session_event" &&
      isString (get "kind") ["runtime_failure_reply_attempted", "runtime_failure_reply_settled"] then
    let detail := get "event"
    let id := detail.get (b "tool_call_id")
    let valid := detail.isMap && detail.has (b "kind") && detail.has (b "tool_call_id") &&
      isString (detail.get (b "kind")) failureReplyProviders && id.isBinary && id != b ""
    return if valid then ok else err (a "invalid_runtime_failure_reply")
  if type == b "tool_result_stored" then return ← validateStoredResult event
  if type == b "visible_reply_repair" then
    return if has "status" && isString (get "status") ["required", "completed", "exhausted", "aborted"] then ok
      else err (a "invalid_visible_reply_repair_status")
  if type == b "visible_reply_activation_started" && has "scope" then
    return if validScope (get "scope") then ok else err (a "invalid_visible_reply_activation_scope")
  if type == b "visible_reply_activation_finished" && has "response_identity" then
    return if validResponseIdentity (get "response_identity") then ok
      else err (a "invalid_visible_reply_activation_identity")
  if isString type ["visible_reply_activation_started", "visible_reply_activation_finished"] then
    return err (a "invalid_visible_reply_activation_event")
  if type == b "visible_reply_intent" && has "assistant_message_id" && has "content" && has "scope" &&
      has "idempotency_key" then
    let key := get "idempotency_key"
    if positive (get "assistant_message_id") && (get "content").isBinary && (get "scope").isMap &&
        key.isBinary && key != b "" then return ok
  if isString type ["visible_reply_committed", "visible_reply_aborted"] && has "idempotency_key" then
    let key := get "idempotency_key"
    if key.isBinary && key != b "" then return ok
  if isString type ["visible_reply_intent", "visible_reply_committed", "visible_reply_aborted"] then
    return err (a "invalid_visible_reply_lifecycle_event")
  if type == b "session_microcompact" then
    let through := get "non_model_messages_over_bytes_through"
    let validThrough := match through with | .integer n => n ≥ 0 | _ => false
    if has "non_model_messages_over_bytes_through" && has "non_model_message_max_bytes" &&
        validThrough && positive (get "non_model_message_max_bytes") then return ok
    if has "non_model_messages_over_bytes_through" || has "non_model_message_max_bytes" then
      return err (a "invalid_emergency_compact_event")
    return ok
  if type == b "redact" then return err (a "redact_session_event_removed")
  if type == b "context_provider_state" then return err (a "context_provider_state_event_removed")
  if isString type standalone then return err (a "standalone_context_provider_event_removed")
  return ok

/-- `:ok`, or the first event's `{:error, reason}`. A value that is not a list
is `{:error, :invalid_events}`. -/
def validateEvents (events : Term) : KernelM Term := do
  let .list events := events | return err (a "invalid_events")
  for event in events do
    let result ← validateEvent event
    if result != ok then return result
  return ok

def table : OpTable := [("validate_events", fun _ events => validateEvents events)]

end VerifiedKernel.Session.WriteValidation
