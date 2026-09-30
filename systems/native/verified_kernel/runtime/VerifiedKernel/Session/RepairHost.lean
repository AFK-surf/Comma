import VerifiedKernel.Session.Settlement
import VerifiedKernel.Session.Async
import VerifiedKernel.Json

/-! # Crash repair host data

Restart repair runs before a recovered session takes new work. These queries
make its decisions, so a host answers each one with I/O only:

- `guard_recovery` settles a committed runtime failure reply. It reads an
  archived async record (`{:archived_record, seq}`) and a staged workspace
  result (`{:staged_result, attempt}`) through the query reader.
- `capability_observation` classifies one capability request for the
  `capability` request of `restart_plan`. It reads the reconciled request
  (`{:reconcile_capability, id, result}`) through the query reader.

Both reading queries also ask the reader for `:clock`, the time in
milliseconds after their reads. The prelude time of a query is taken before
the reader's I/O, and a retry or cleanup time must follow it.
- `restart_encode` builds the events of the `encode_missing` and
  `encode_external` requests of `restart_plan`.

The restart protocol itself does not call these queries. Its proofs treat the
answers as host data. -/

namespace VerifiedKernel.Session.RepairHost
open Data
open RoundQuery (valueOf terminalAsyncStatus)

private def callId (record : Term) : Term :=
  (record.get (b "tool_call_id")).default (record.get (a "tool_call_id"))

/-- `Repair.execution_result/1`: the result of a terminal async record. -/
def executionResult (record : Term) : KernelM Term := do
  let status := record.get (b "status")
  let result ← put ((record.get (b "result")).default empty) (b "status") status
  let result := result.put (b "error") (Term.bool (status != b "completed"))
  let keep := fun (acc : Term) (key : String) =>
    if acc.has (b key) then acc else acc.put (b key) (record.get (b key))
  return keep (keep result "error_class") "error_message"

/-- `SessionToolExecution.callback_handoff_result?/1`: the result hands the
call to an external callback. -/
def callbackHandoff (result : Term) : Bool :=
  if !result.isMap then false else
  let status := (result.get (b "status")).default (result.get (a "status"))
  let events := match (result.get (a "events")).default (result.get (b "events")) with
    | .list xs => xs
    | _ => []
  status == b "async_running" &&
    events.any (fun event => event.isMap && event.get (b "type") == b "async_tool_call_started")

/-- The host time after the reader's I/O (`:clock`). -/
private def clock : KernelM Int := return integerValue (← observe (a "clock"))

/-! ## Runtime failure reply recovery -/

/-- The terminal result of the failure reply call: its terminal async record,
else its staged result unless that result is a callback handoff. -/
private def failureReplyResult (state attempt : Term) : KernelM Term := do
  let id := attempt.get (b "tool_call_id")
  let record ← match ← resolveResult state id with
    | .tuple [.atom "ok", record] => pure record
    | .tuple [.atom "archived", seq] => observe (.tuple [a "archived_record", seq])
    | _ => pure nil
  if record.isMap && terminalAsyncStatus (record.get (b "status")) then
    return (← executionResult record).put (b "id") id
  match ← observe (.tuple [a "staged_result", attempt]) with
  | .tuple [.atom "ok", result] => if callbackHandoff result then return nil else put result (a "id") id
  | _ => return nil

/-- A persisted runtime failure send consumed its budget before network I/O.
Restart settles a known receipt or an unknown outcome, but never resends.
Args: the tool call ids that a live process still owns. -/
def guardRecovery (state live : Term) : KernelM Term := do
  let attempt ← field state "runtime_failure_reply"
  if attempt.isMap && (attempt.get (b "notification_outcome")).isBinary then return list []
  let id := attempt.get (b "tool_call_id")
  if attempt.isMap && id.isBinary then
    if (wrap live).contains id then return list []
    let result ← failureReplyResult state attempt
    let now := i (← clock)
    let cleanup := (← Settlement.guardCleanupEvents state (.tuple [result, now])).default (list [])
    return (← Settlement.guardSettlement state result (← asList cleanup)).default (list [])
  let retired ← Settlement.retireRunaway state
  if retired.truthy then return retired
  return (← Settlement.guardLocalSettlement state).default (list [])

/-! ## Capability requests -/

/-- `CapabilityRequestStore.execution_fields/1`. -/
def executionFields (request : Term) : Term :=
  let settlement := request.get (b "settlement_deadline_ms")
  let expires := request.get (b "expires_at")
  let deadline :=
    if !(request.get (b "result")).isMap && settlement.isInteger then settlement
    else if expires.isInteger then i (integerValue expires * 1000) else i 1
  .map [(b "capability_request_id", request.get (b "request_id")), (b "capability_deadline_ms", deadline)]

private def syncEvent (sid record fields : Term) : KernelM Term :=
  merge fields (.map [(b "type", b "capability_request_sync"), (b "session_id", sid),
    (b "tool_call_id", callId record)])

private def unavailableText : Term := b "The external request result could not be confirmed. Please try again."

/-- The observation of one capability request for `resume_restart`, and the
failure reason when reconciliation exhausted its budget (else nil):
`{observation, reason}`. A reconciliation error retries after 5 seconds and
is exhausted 30 seconds after the first error. -/
def capabilityObservation (state record : Term) : KernelM Term := do
  let sid ← field state "session_id"
  let id := callId record
  let terminal := terminalAsyncStatus (record.get (b "status"))
  let result ← if terminal then executionResult record else pure nil
  match ← observe (.tuple [a "reconcile_capability", id, result]) with
  | .tuple [.atom "ok", .atom "not_found"] =>
    let events ← if record.get (b "completion_mode") == b "external_callback" ||
        (record.get (b "capability_retry_at_ms")).isInteger then
      pure [← syncEvent sid record (.map [(b "settled", a "true")])] else pure []
    return .tuple [.map [(b "state", b "absent"), (b "events", list events)], nil]
  | .tuple [.atom "ok", request] =>
    if !request.isMap then fail "function_clause"
    let settled := (request.get (b "result")).isMap
    let fields := (executionFields request).put (b "completion_mode") (b "external_callback")
    let sync ← syncEvent sid record (← merge fields (.map [(b "settled", Term.bool settled),
      (b "capability_retry_at_ms", if terminal && !settled then fields.get (b "capability_deadline_ms") else nil),
      (b "capability_sync_failed", a "false"), (b "capability_error_since_ms", nil)]))
    let kind := if terminal then "settled" else if settled then "terminal" else "pending"
    return .tuple [.map [(b "state", b kind), (b "record", ← merge record fields),
      (b "result", request.get (b "result")), (b "events", list [sync])], nil]
  | .tuple [.atom "error", reason] =>
    let now ← clock
    let since := (record.get (b "capability_error_since_ms")).default (i now)
    let exhausted := now - integerValue since ≥ 30000
    let fields := Term.map [(b "completion_mode", b "external_callback"), (b "capability_error_since_ms", since),
      (b "capability_retry_at_ms", i (now + 5000)), (b "capability_sync_failed", Term.bool exhausted)]
    let result := Term.map [(b "id", id), (b "name", record.get (b "tool_name")), (b "status", b "error"),
      (b "error", a "true"), (b "error_class", b "capability_request_unavailable"),
      (b "content", unavailableText), (b "public_summary", unavailableText),
      (b "error_message", b "Capability request reconciliation exceeded its retry budget"),
      (b "diagnostic_visibility", b "user_reportable")]
    return .tuple [.map [(b "state", b (if exhausted then "unknown" else "unavailable")),
      (b "record", ← merge record fields), (b "result", result),
      (b "events", list [← syncEvent sid record fields])], if exhausted then reason else nil]
  | _ => fail "invalid_observation"

/-! ## Restart encoders -/

/-- Erlang flat-map key order, so JSON text matches the host encoder. Maps
with more than 32 keys keep their order. -/
private def flatOrder : Nat → Term → KernelM Term
  | 0, _ => fail "invalid_term_depth"
  | fuel + 1, value => do
    match value with
    | .list xs => return .list (← xs.mapM (flatOrder fuel))
    | .map xs =>
      let xs ← xs.mapM (fun pair => return (pair.1, ← flatOrder fuel pair.2))
      if xs.length > 32 then return .map xs
      let keys ← sortedKeys (xs.map Prod.fst)
      return .map (keys.map (fun key => (key, (Term.map xs).get key)))
    | _ => return value

private def json (value : Term) : KernelM Term := do
  let some bytes ← Json.encode (← flatOrder (value.depth + 1) value) | fail "badarg"
  return .binary bytes

/-- `encode_missing {message_id, result}`: the tool result of a missing call. -/
private def encodeMissing (state args : Term) : KernelM Term := do
  let .tuple [messageId, result] := args | fail "function_clause"
  let get := fun (key : String) => (result.get (a key)).default (result.get (b key))
  let now := i (integerValue (← observe (a "time")) / 1000)
  let content := get "content"
  let output := get "output"
  return .map [(b "type", b "tool_result"), (b "session_id", ← field state "session_id"),
    (b "message_id", messageId), (b "tool_call_id", get "id"), (b "tool_name", get "name"),
    (b "content", content), (b "error", (get "error").default (a "false")), (b "status", get "status"),
    (b "duration_ms", get "duration_ms"), (b "input", get "input"),
    (b "output", if output == content then nil else output),
    (b "error_class", get "error_class"), (b "error_message", get "error_message"),
    (b "guidance_reason", get "guidance_reason"), (b "diagnostic_visibility", get "diagnostic_visibility"),
    (b "started_at", now), (b "completed_at", now), (b "created_at", now)]

/-- `encode_external {call, message_id, record}`: the dispatch of a call that
still waits for its external callback, and its running tool result. -/
private def encodeExternal (state args : Term) : KernelM Term := do
  let .tuple [call, messageId, record] := args | fail "function_clause"
  let sid ← field state "session_id"
  let id := call.get (a "id")
  let name := call.get (a "name")
  let content ← json (.map [(b "status", b "async_running"), (b "tool_call_id", id), (b "tool_name", name),
    (b "message", b "tool call recovered after interruption and is still waiting for external completion")])
  let started := Term.map [(b "type", b "async_tool_call_started"), (b "session_id", sid),
    (b "tool_call_id", id), (b "tool_name", name), (b "input", ← json ((call.get (a "args")).default empty)),
    (b "status", b "running"), (b "completion_mode", b "external_callback"),
    (b "started_at", i (integerValue (← observe (a "time"))))]
  let carried := select record ["capability_request_id", "capability_deadline_ms", "capability_retry_at_ms",
    "capability_error_since_ms", "capability_sync_failed"]
  return list [← merge started carried,
    .map [(b "type", b "tool_result"), (b "session_id", sid), (b "message_id", messageId),
      (b "tool_call_id", id), (b "content", content), (b "error", a "false")]]

def table : OpTable :=
  [("guard_recovery", guardRecovery),
   ("capability_observation", capabilityObservation),
   ("restart_encode", fun state args => do
     match args with
     | .tuple [.binary name, payload] =>
       if name == "encode_missing".toUTF8 then encodeMissing state payload
       else if name == "encode_external".toUTF8 then encodeExternal state payload
       else fail "function_clause"
     | _ => fail "function_clause")]

end VerifiedKernel.Session.RepairHost
