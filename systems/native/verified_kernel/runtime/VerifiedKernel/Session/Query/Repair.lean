import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Async
import VerifiedKernel.Session.Activity
import VerifiedKernel.Session.Query.StateCore
import VerifiedKernel.Session.Query.Reply

/-! Queries ported from SalixAgent.Repair, VisibleReplyReconciliation, VisibleReplyPolicy, VisibleReplyScope, and ProviderReplyObligation. See the README query catalog. -/

namespace VerifiedKernel.Session.RepairQuery
open Data
open VerifiedKernel.Session.ReplyQuery (policyValue nonNegInt)

/-! ## `SalixAgent.Repair`

`Repair.plan_session/2` reads the transcript through the `Access` protocol
(`m[:role]`), so only the atom key answers there. The scheduled-Task branch of
`VisibleReplyPolicy` reads the same messages through its own `value/2`, which
tries the string key first. Both readers appear below and the difference is
observable, so neither may stand in for the other. -/

/-- `Repair.decode_args/1`: a binary decodes as JSON, a map passes, anything
else is the empty map. -/
def decodeArgs (args : Term) : Term :=
  match args with
  | .binary raw =>
    match Json.decode raw with
    | some decoded => if decoded.isMap then decoded else empty
    | none => empty
  | _ => if args.isMap then args else empty

/-- `Repair.unwrap_call_envelope/2`. Only the exact binary `"call"` unwraps. -/
def unwrapCallEnvelope (name args : Term) : Term × Term :=
  if name == b "call" then
    let args := decodeArgs args
    let tool := (args.get (b "tool")).default (args.get (a "tool"))
    let params :=
      if args.has (b "params") then args.get (b "params")
      else if args.has (a "params") then args.get (a "params")
      else empty
    (tool.default (b "call"), decodeArgs params)
  else (name, decodeArgs args)

/-- `Repair.normalize_tool_call/1`. The non-map clause keeps no `:source_call`,
exactly as the Elixir fallback does. -/
def normalizeToolCall (call : Term) : Term :=
  if !call.isMap then .map [(a "id", nil), (a "name", nil), (a "args", empty)]
  else
    let args := ((call.get (b "args")).default (call.get (a "args"))).default empty
    let (name, args) := unwrapCallEnvelope ((call.get (b "name")).default (call.get (a "name"))) args
    .map [(a "id", (call.get (b "id")).default (call.get (a "id"))),
      (a "name", name), (a "args", args), (a "source_call", call)]

/-- `Repair.tool_result_call_id/1`. -/
def toolResultCallId (message : Term) : KernelM Term :=
  aliases message [a "tool_call_id", b "tool_call_id", a "tool_use_id", b "tool_use_id"]

/-- `Repair.answered_tool_ids/1`. -/
def answeredIds (messages : Term) : KernelM (List Term) :=
  enumFold messages [] (fun acc message => do
    if (← access message (a "role")) != b "tool" then return acc
    let id ← toolResultCallId message
    return if id == nil then acc else acc ++ [id])

/-- `Repair.async_tool_ids/1`. The generator pattern `{_id, %{} = info}` skips a
non-map value instead of raising. -/
def asyncAnsweredIds (calls : Term) : KernelM (List Term) := do
  if !calls.isMap then return []
  (← entries calls).foldlM (fun acc pair => do
    if !pair.2.isMap then return acc
    let id := (pair.2.get (b "tool_call_id")).default (pair.2.get (a "tool_call_id"))
    return if id == nil then acc else acc ++ [id]) []

/-- `Repair.running_async_tool_calls/1`, including its shallow `stringify/1`. -/
def runningAsyncCalls (calls : Term) : KernelM (List Term) := do
  if !calls.isMap then return []
  let running := ((← entries calls).map Prod.snd).filter (fun record =>
    record.get (b "completion_mode") == b "external_callback" ||
      record.get (b "status") == b "running" || record.get (b "status") == a "running" ||
      record.get (a "status") == b "running" || record.get (a "status") == a "running")
  running.mapM shallowStringify

/-- `Repair.last_message_role/1`. -/
def lastMessageRole (messages : Term) : KernelM Term := do
  match (wrap messages).getLast? with
  | some message => if message.isMap then alias message (a "role") (b "role") else return nil
  | none => return nil

/-- `Repair.last_message_id/1`. -/
def lastMessageId (messages : Term) : KernelM Term := do
  let ids ← (wrap messages).mapM (fun message => alias message (a "id") (b "id"))
  match ids.filter Term.isInteger with
  | [] => return nil
  | first :: rest => return i (rest.foldl (fun acc value => max acc (integerValue value))
      (integerValue first))

/-- Everything `Repair.plan_session/2` reads out of the transcript before it
consults the workspace and the capability store: the tool calls that still owe
a result, the running async records, and the tail of the transcript. -/
def repairScan (state : Term) : KernelM Term := do
  let messages := (state.get (a "messages")).default (list [])
  let answered ← answeredIds messages
  let asyncAnswered ← asyncAnsweredIds ((state.get (a "async_tool_calls")).default empty)
  let calls ← enumFold messages [] (fun acc message => do
    if (← access message (a "role")) != b "assistant" then return acc
    return acc ++ (← asList ((← access message (a "tool_calls")).default (list []))))
  let normalized := calls.map normalizeToolCall
  let kept := normalized.filter (fun call =>
    let id := call.get (a "id")
    id != nil && !(answered.any (· == id)) && !(asyncAnswered.any (· == id)))
  let missing := kept.foldl (fun acc call =>
    if acc.any (fun seen => seen.get (a "id") == call.get (a "id")) then acc else acc ++ [call]) []
  return .map [
    (b "missing_calls", list missing),
    (b "running_async", list (← runningAsyncCalls ((state.get (a "async_tool_calls")).default empty))),
    (b "last_message_role", ← lastMessageRole messages),
    (b "last_message_id", ← lastMessageId messages),
    (b "visible_reply_intent?", Term.bool (state.get (a "visible_reply_intent")).isMap)]

/-! ## `SalixAgent.VisibleReplyPolicy` scheduled-Task failure containment -/

/-- `VisibleReplyPolicy.present_string/1`: the trimmed binary, or nil. -/
def presentString (value : Term) : Term :=
  match value with
  | .binary raw => let bytes := trim raw; if bytes.isEmpty then nil else .binary bytes
  | _ => nil

/-- `VisibleReplyPolicy.string_value/2`. -/
@[inline] def stringValue (value : Term) (key : String) : KernelM Term :=
  stringChars (policyValue value key)

private def scheduledPrefix : ByteArray := "scheduled-task-safe-failure:".toUTF8

/-- `VisibleReplyPolicy.scheduled_task_failure_call_id?/1`. -/
def scheduledCallId (value : Term) : Bool :=
  match value with
  | .binary raw =>
    raw.size ≥ scheduledPrefix.size && raw.extract 0 scheduledPrefix.size == scheduledPrefix
  | _ => false

/-- `VisibleReplyPolicy.pending_result?/1`. -/
def pendingResult (result : Term) : KernelM Bool := do
  let status ← stringValue result "status"
  return status == b "async_running" || status == b "running"

/-- `VisibleReplyPolicy.failure_result?/1`. -/
def failureResult (result : Term) : KernelM Bool := do
  if !result.isMap then return false
  if policyValue result "error" == a "true" then return true
  if presentString (policyValue result "error_class") != nil then return true
  let status ← stringValue result "status"
  return status == b "error" || status == b "guidance"

/-- `VisibleReplyPolicy.scheduled_task_failure_result_state/1`. -/
def resultState (result : Term) : KernelM Term := do
  if ← pendingResult result then return a "pending"
  let status ← stringValue result "status"
  if (← failureResult result) || status == b "cancelled" then return a "failed"
  if status == b "completed" then return a "completed"
  return a "failed"

/-- `VisibleReplyPolicy.scheduled_task_failure_message_state/2`. -/
def messageState (messages toolCallId : Term) : KernelM Term := do
  let found ← (wrap messages).reverse.foldlM (fun acc message => do
    if acc != nil then return acc
    if (← stringValue message "role") != b "tool" then return acc
    if policyValue message "tool_call_id" != toolCallId then return acc
    let outcome ← stringValue message "repair_outcome"
    if outcome == b "contained_scheduled_task_failure" then return a "completed"
    if outcome == b "scheduled_task_failure_failed" then return a "failed"
    return a "pending") nil
  return if found == nil then a "pending" else found

/-- `VisibleReplyPolicy.scheduled_task_failure_batch_ids/2`: the durable
assistant batch that minted this call id, newest first. -/
def batchIds (messages currentId : Term) : KernelM (List Term) := do
  let found ← (wrap messages).reverse.foldlM (fun acc message => do
    match acc with
    | some _ => return acc
    | none =>
      let calls := policyValue message "tool_calls"
      let ids ← if (← stringValue message "role") == b "assistant" && calls.isList then
          pure (uniq (((wrap calls).map (fun call => presentString (policyValue call "id"))).filter
            scheduledCallId))
        else pure []
      return if ids.any (· == currentId) then some ids else none) none
  return found.getD []

/-- `VisibleReplyPolicy.scheduled_task_failure_async_state/2`. -/
def scheduledState (state result : Term) : KernelM Term := do
  let currentId := presentString (policyValue result "id")
  if !scheduledCallId currentId then return a "not_scheduled"
  let messages := (state.get (a "messages")).default (list [])
  let ids ← batchIds messages currentId
  if ids.isEmpty then return a "not_scheduled"
  let states ← ids.mapM (fun id => do
    if id == currentId then resultState result
    else match ← resolveResult state id with
      | .tuple [.atom "ok", record] => resultState record
      | _ => messageState messages id)
  if states.any (· == a "failed") then return .tuple [a "scheduled", a "failed"]
  if states.all (· == a "completed") then return .tuple [a "scheduled", a "completed"]
  return .tuple [a "scheduled", a "pending"]

/-- Everything `VisibleReplyPolicy.async_completion_events/4` reads out of the
session: the repair guard, the scheduled-Task disposition of this result, and
the two high-water marks its event builders compose. The host keeps only the
clock and the event shapes. -/
def asyncCompletionFacts (state result : Term) : KernelM Term := do
  let nextMessageId := (state.get (a "next_message_id")).default (i 1)
  if !nextMessageId.isInteger then fail "badarith"
  let repair := state.get (a "visible_reply_repair")
  return .map [
    (b "exhausted?", Term.bool (← repairExhausted state)),
    (b "phase", ← ReplyQuery.phase state),
    (b "scheduled", ← scheduledState state result),
    (b "next_hwm", i (max (integerValue nextMessageId - 1) 0)),
    (b "repair_revision", nonNegInt (policyValue repair "revision")),
    (b "repair_diagnostic_hwm", nonNegInt (policyValue repair "diagnostic_hwm"))]

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("repair_scan", fun state _ => repairScan state),
   ("visible_reply_async_completion_facts", asyncCompletionFacts)]

end VerifiedKernel.Session.RepairQuery
