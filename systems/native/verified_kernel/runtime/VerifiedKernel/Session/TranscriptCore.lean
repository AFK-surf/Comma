import VerifiedKernel.Session.Activity
import VerifiedKernel.Session.Queue

namespace VerifiedKernel.Session
open Data

def contentBytes (value : Term) : KernelM Term := do
  if value == nil then return i 0
  if let .binary bytes := value then return i bytes.size
  match ← Json.encode value with
  | some bytes => return i bytes.size
  | none => return i (Inspect.render value 20 4096).utf8ByteSize

def toolCallBytes (value : Term) : KernelM Term := do
  match value with
  | .list (_ :: _) =>
    match ← Json.encode value with
    | some bytes => return i bytes.size
    | none => return i 0
  | _ => return i 0

def providerBytes (value : Term) : KernelM Term := do
  if value.has (b "items") then contentBytes (value.get (b "items"))
  else if value.has (a "items") then contentBytes (value.get (a "items"))
  else pure (i 0)

def messageBytes (message : Term) : KernelM Term := do
  let content ← contentBytes (← access message (a "content"))
  let calls ← toolCallBytes (← access message (a "tool_calls"))
  let attachments ← contentBytes (← alias message (a "trusted_attachment_refs") (b "trusted_attachment_refs"))
  let provider ← contentBytes (← alias message (a "provider_meta") (b "provider_meta"))
  add (← add (← add content calls) attachments) provider

def recomputeBytes (state : Term) : KernelM Term := do
  let summary ← field state "summary"
  let summaryBytes ← if summary.truthy then do
    let .binary bytes ← stringChars summary | fail "badarg"
    pure (i bytes.size)
    else pure (i 0)
  let provider ← providerBytes (← field state "provider_compaction")
  let compacted := (← field state "compacted_through").default (i 0)
  enumFold (← field state "messages") (← add summaryBytes provider) (fun acc message => do
    if ← greater ((← access message (a "id")).default (i 0)) compacted then add acc (← messageBytes message)
    else pure acc)

def contextBytes (state : Term) : KernelM Term := do
  let count ← field state "live_context_bytes"
  if count.isInteger then pure count else recomputeBytes state

def appendFields (state event message : Term) : KernelM Term := do
  let seq ← add ((← field state "last_seq").default (i 0)) (i 1)
  let stamped := message.put (a "seq") seq
  let messages ← append (← field state "messages") (list [stamped])
  let context ← contextBytes state
  let added ← messageBytes stamped
  let timestamp ← Data.event event "created_at"
  let activity ← if timestamp.truthy then pure timestamp else field state "last_activity_at"
  write state [("messages", messages), ("last_seq", seq), ("live_context_bytes", ← add context added), ("last_activity_at", activity)]

def bumpHwm (state hwm : Term) : KernelM Term := do
  if hwm.isInteger && integerValue hwm ≥ 0 then
    write state [("next_message_id", ← maximum ((← field state "next_message_id").default (i 1)) (← add hwm (i 1)))]
  else pure state

/-- `bump_hwm`: `State.bump_hwm/2` with the event's `hwm`. -/
def bumpHwmEvent (state event : Term) : KernelM Term := do
  bumpHwm state (← Data.event event "hwm")

def appendMessage (state event message : Term) : KernelM Term := do
  bumpHwm (← appendFields state event message) (← Data.event event "message_id")

def traceFields (event : Term) (names : List String) : KernelM Term :=
  names.foldlM (fun acc name => do put acc (a name) (← Data.event event name)) empty

def messageTrace (event : Term) : KernelM Term :=
  traceFields event ["execution_timing", "model", "input_tokens", "output_tokens", "cache_read_input_tokens",
    "cache_write_input_tokens", "request_summary_sequence", "request_compacted_through", "request_input_through",
    "turn_id", "round_id", "request_id", "trace_id"]

def toolTrace (event : Term) : KernelM Term :=
  traceFields event ["execution_timing", "tool_name", "status", "duration_ms", "input", "output", "error_class",
    "error_message", "guidance_reason", "diagnostic_visibility", "public_summary", "repair_outcome", "visible_reply_origin",
    "turn_id", "round_id", "request_id", "trace_id", "started_at", "completed_at"]

def putIfc (message event : Term) : KernelM Term := do
  let ifc ← Data.event event "ifc"
  match ifc with
  | .map (_ :: _) => put message (a "ifc") ifc
  | _ => pure message

def migrationVersion (version : Term) : Term :=
  if version.isInteger then i (max (integerValue version) 0)
  else match version with
  | .binary bytes => i (max (integerValue (.binary (trim bytes))) 0)
  | _ => i 0

def providerStates (value : Term) : KernelM Term := do
  if !value.isMap then return empty
  let states ← stringify value
  let legacy := states.get (b "runtime_context")
  let migrated ← if !states.has (b "migration_notice") && legacy.has (b "version") then do
    let next ← remove states (b "runtime_context")
    pure (next.put (b "migration_notice") (.map [(b "version", migrationVersion (legacy.get (b "version")))]))
    else pure states
  return .map ((← entries migrated).filter (fun pair =>
    match pair.2 with | .map (_ :: _) => true | _ => false))

def privateMetadata (value : Term) : KernelM Term := do
  if !value.isMap then return empty
  let normalized ← shallowStringify value
  let providers ← providerStates (normalized.get (b "context_provider_states"))
  let updated := normalized.put (b "context_provider_states") providers
  return .map ((← entries updated).filter (fun pair =>
    pair.2 != nil && !(pair.1 == b "context_provider_states" && pair.2 == empty)))

end VerifiedKernel.Session
