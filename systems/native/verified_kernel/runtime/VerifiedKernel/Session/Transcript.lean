import VerifiedKernel.Session.TranscriptCore
import VerifiedKernel.Session.Scope
import VerifiedKernel.Session.Replies

namespace VerifiedKernel.Session
open Data

def transcriptToolResult (state event : Term) : KernelM Term := do
  let base ← traceFields event ["message_id", "tool_call_id", "content", "repair_outcome", "created_at"]
  let base := (base.put (a "id") (base.get (a "message_id"))).put (a "role") (b "tool")
  let base ← remove base (a "message_id")
  let message ← putIfc (present (← merge base (← toolTrace event))) event
  let appended ← appendMessage state event message
  let tool ← Data.event event "tool_name"
  let input ← Data.event event "input"
  let status ← Data.event event "status"
  let errorClass ← Data.event event "error_class"
  let errorMessage ← Data.event event "error_message"
  let content ← Data.event event "content"
  let output ← Data.event event "output"
  noteResult appended tool input status errorClass errorMessage (businessOutput content output)

def transcriptAssistant (state event : Term) : KernelM Term := do
  let privateFields ← privateMetadata (← Data.event event "do_not_send_to_llm")
  let id ← Data.event event "message_id"
  let content ← Data.event event "content"
  let calls := (← Data.event event "tool_calls").default (list [])
  let created ← Data.event event "created_at"
  let base := Term.map [(a "id", id), (a "role", b "assistant"), (a "content", content), (a "tool_calls", calls), (a "created_at", created)]
  let traced ← merge base (← messageTrace event)
  let withPrivate := if privateFields == empty then traced else traced.put (a "do_not_send_to_llm") privateFields
  let withProvider ← truthyPut withPrivate (a "provider_meta") (← Data.event event "provider_meta")
  let withPhase ← truthyPut withProvider (a "visible_reply_phase") (← Data.event event "visible_reply_phase")
  let appended ← appendMessage state event (← putIfc withPhase event)
  -- One model round on the current input; fresh input and an advancing ACK clear it.
  let count := streakCount (← field appended "input_round_streak")
  write appended [("input_round_streak", .map [(b "count", ← add count (i 1))])]

def transcriptLog (state event : Term) : KernelM Term := do
  let source ← Data.event event "source_message_id"
  let dedupeKey ← Data.event event "dedupe_key"
  let keys := [source, dedupeKey].filter (!missing ·)
  let dedupe ← field state "input_dedupe"
  if ← dedupeHit dedupe keys then return state
  let supplied ← Data.event event "message_id"
  let id ← if supplied.truthy then pure supplied else pure ((← field state "next_message_id").default (i 1))
  let content ← Data.event event "content"
  let created ← Data.event event "created_at"
  let base := Term.map [(a "id", id), (a "role", b "event"), (a "content", content), (a "source_message_id", source),
    (a "dedupe_key", dedupeKey), (a "created_at", created)]
  let message := present (← merge base (← messageTrace event))
  let appended ← appendFields state event message
  let updated ← write appended [("input_dedupe", ← addDedupe dedupe keys)]
  bumpHwm updated id

def seedToolId (entry : Term) : KernelM Term := aliases entry [b "tool_call_id", b "tool_use_id", b "call_id"]

def seedKeys (entry : Term) : KernelM (List Term) := do
  let keys := [← Data.event entry "dedupe_key", ← Data.event entry "source_message_id", ← Data.event entry "runtime_message_id", ← seedToolId entry]
  return uniq (keys.filter (!missing ·))

def seedRole (role entry : Term) : KernelM Term := do
  if role == b "runtime" then
    let runtimeId ← aliases entry [b "runtime_message_id", b "source_message_id", b "dedupe_key"]
    let kind := (← Data.event entry "type").default (b "eval_seed")
    let summary ← alias entry (b "summary") (b "content")
    let source ← Data.event entry "source"
    let refs := (← Data.event entry "source_refs").default empty
    return .map [(a "kind", b "runtime_message"), (a "runtime_message_id", runtimeId), (a "type", kind),
      (a "summary", summary), (a "source", source), (a "source_refs", refs)]
  else if role == b "assistant" then
    let model ← Data.event entry "model"
    let calls := (← Data.event entry "tool_calls").default (list [])
    let providerMetadata ← Data.event entry "provider_meta"
    merge (.map [(a "model", model), (a "tool_calls", calls), (a "provider_meta", providerMetadata)]) (← messageTrace entry)
  else if role == b "tool" then
    let tool ← seedToolId entry
    merge (.map [(a "tool_call_id", tool)]) (← toolTrace entry)
  else pure empty

def seedMessage (event entry id : Term) : KernelM Term := do
  let role ← Data.event entry "role"
  let content ← if entry.get (b "role") == b "runtime" then alias entry (b "content") (b "summary") else Data.event entry "content"
  let source ← Data.event entry "source_message_id"
  let dedupe ← Data.event entry "dedupe_key"
  let created ← Data.event entry "created_at"
  let created ← if created.truthy then pure created else Data.event event "created_at"
  let base := Term.map [(a "id", id), (a "role", role), (a "content", content), (a "source_message_id", source),
    (a "dedupe_key", dedupe), (a "no_wake", a "true"), (a "created_at", created)]
  return present (← merge base (← seedRole role entry))

def transcriptSeed (state event : Term) : KernelM Term := do
  let input := (← Data.event event "entries").default (list [])
  let next := (← field state "next_message_id").default (i 1)
  let seen := (← field state "input_dedupe").default (.map [(a "__struct__", a "Elixir.MapSet"), (a "map", empty)])
  let seq := (← field state "last_seq").default (i 0)
  let initial : List Term × Term × Term × Bool × Term := ([], next, seen, false, seq)
  let (appended, nextId, dedupe, any, lastSeq) ← enumFold input initial (fun (messages, next, seen, any, seq) raw => do
    let entry ← stringify raw
    let keys ← seedKeys entry
    if ← dedupeHit seen keys then return (messages, next, seen, any, seq)
    let unstamped ← seedMessage event entry next
    let sequence ← add seq (i 1)
    let message := unstamped.put (a "seq") sequence
    return (message :: messages, ← add next (i 1), ← addDedupe seen keys, true, sequence))
  let messages ← append ((← field state "messages").default (list [])) (list appended.reverse)
  let created ← field state "created_at"
  let created ← if created.truthy then pure created else Data.event event "created_at"
  let timestamp ← if any then Data.event event "created_at" else pure nil
  let activity ← if timestamp.truthy then pure timestamp else field state "last_activity_at"
  let seeded ← write state [("created_at", created), ("last_activity_at", activity), ("messages", messages),
    ("next_message_id", ← maximum nextId ((← field state "next_message_id").default (i 1))), ("last_seq", lastSeq), ("input_dedupe", dedupe)]
  write seeded [("live_context_bytes", ← recomputeBytes seeded)]

def runtimeKeys (event : Term) : KernelM (List Term) := do
  let keys := [← Data.event event "dedupe_key", ← Data.event event "source_message_id", ← Data.event event "runtime_message_id"]
  return uniq (keys.filter (!missing ·))

def runtimeAppend (state event : Term) : KernelM Term := do
  let keys ← runtimeKeys event
  let noWake := (← Data.event event "no_wake") == a "true"
  let id ← Data.event event "message_id"
  let runtimeId ← Data.event event "runtime_message_id"
  let runtimeType ← Data.event event "runtime_message_type"
  let dedupeKey ← Data.event event "dedupe_key"
  let source ← Data.event event "source_message_id"
  let summary ← Data.event event "summary"
  let content ← alias event (b "content") (b "summary")
  let provider := (← Data.event event "from_context_provider") == a "true"
  let contentKind ← if provider then Data.event event "content_kind" else pure nil
  let fields ← traceFields event ["source_tool_call_id", "wait_id", "reason", "timeout_seconds", "deadline_ms", "source",
    "elapsed_ms", "overdue_ms", "tool_call_id", "tool_call_ids", "failed_tool_calls", "pending_external_callback_tool_calls",
    "failed_llm_call", "diagnostic_visibility", "public_summary", "visible_reply_origin", "trusted_origin", "trusted_origins",
    "trusted_origin_source_message_ids"]
  let sourceRefs := (← Data.event event "source_refs").default empty
  let created ← Data.event event "created_at"
  let base := Term.map [(a "id", id), (a "role", b "runtime"), (a "kind", b "runtime_message"), (a "runtime_message_id", runtimeId),
    (a "type", runtimeType), (a "dedupe_key", dedupeKey), (a "source_message_id", source), (a "summary", summary),
    (a "content", content), (a "accepted_input", event.get (b "accepted_input")),
    (a "content_kind", contentKind), (a "source_refs", sourceRefs),
    (a "no_wake", if noWake then a "true" else nil), (a "created_at", created)]
  let message := present (← merge base fields)
  let kind ← Data.event event "runtime_message_type"
  let message ← if kind == b "tool_call_completed" || kind == b "tool_call_failed" then do
    let result ← resolveResult state ((← Data.event event "source_tool_call_id").default (b ""))
    let fallback := Term.map [(b "label", list [b "agent_private"])]
    let ifc := match result with
      | .tuple [.atom "ok", record] =>
        let label := (record.get (b "result")).get (b "ifc")
        if record.get (b "status") == b "completed" && label.isMap then label else fallback
      | _ => fallback
    pure (message.put (a "ifc") ifc)
    else pure message
  let refs := (← field state "async_result_refs").default empty
  let refKey ← alias event (b "tool_call_id") (b "source_tool_call_id")
  let ref ← get? refs refKey
  let message := if ref == nil then message else message.put (a "result_seq") ref
  let appended ← appendFields state event message
  let dedupe ← addDedupe (← field state "input_dedupe") keys
  let wait ← if noWake then field state "wait" else pure nil
  let updated ← write appended [("input_dedupe", dedupe), ("wait", wait)]
  resetFresh (← bumpHwm updated (← Data.event event "message_id")) message

def transcriptRuntime (state event : Term) : KernelM Term := do
  let provider := event.get (b "from_context_provider") == a "true"
  if !provider && event.get (b "from_queue") != a "true" then return state
  if (← runtimeKeys event).isEmpty then
    argumentError (if provider then "context provider runtime_message invalid: :runtime_message_identity_required"
      else "runtime_message requires runtime_message_id, source_message_id, or dedupe_key")
  if provider && (← Data.event event "no_wake") != a "true" then
    argumentError "context provider runtime_message invalid: :context_provider_runtime_message_must_be_no_wake"
  runtimeAppend state event

def deliveryDedupe (dedupe id : Term) : KernelM Term := if id == nil then pure dedupe else setPut dedupe id

def transcriptDelivery (state event : Term) : KernelM Term := do
  if event.get (b "from_queue") != a "true" then return state
  let source ← Data.event event "source_message_id"
  let dedupeKey ← Data.event event "dedupe_key"
  let noWake := (← Data.event event "no_wake") == a "true"
  let id ← Data.event event "message_id"
  let role := (← Data.event event "role").default (b "user")
  let content ← Data.event event "content"
  let attachments ← Data.event event "trusted_attachment_refs"
  let origin ← Data.event event "trusted_origin"
  let created ← Data.event event "created_at"
  let delivered ← Data.event event "delivered_at_ms"
  let inputTime ← Data.event event "input_time"
  let base := Term.map [(a "id", id), (a "role", role), (a "content", content),
    (a "accepted_input", event.get (b "accepted_input")), (a "trusted_attachment_refs", attachments),
    (a "trusted_origin", origin), (a "source_message_id", source), (a "dedupe_key", dedupeKey),
    (a "no_wake", if noWake then a "true" else nil), (a "created_at", created), (a "delivered_at_ms", delivered), (a "input_time", inputTime)]
  let message := present (← merge base (← messageTrace event))
  let appended ← appendFields state event message
  let context := event.get (b "billing_context")
  let billing ← match context with
    | .map (_ :: _) => pure context
    | _ => pure ((← field state "billing_context").default empty)
  let dedupe ← deliveryDedupe (← deliveryDedupe (← field state "input_dedupe") source) dedupeKey
  let wait ← if noWake then field state "wait" else pure nil
  let repair ← if noWake || message.get (a "role") != b "user" then field state "visible_reply_repair" else pure nil
  let updated ← write appended [("billing_context", billing), ("input_dedupe", dedupe), ("wait", wait), ("visible_reply_repair", repair)]
  let obligated ← addObligation updated (← Data.event event "provider_reply_obligation")
  resetFresh (← bumpHwm obligated (← Data.event event "message_id")) message

end VerifiedKernel.Session
