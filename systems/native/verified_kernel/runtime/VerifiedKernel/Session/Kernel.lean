import VerifiedKernel.Session.Metadata
import VerifiedKernel.Session.Activity
import VerifiedKernel.Session.Progress
import VerifiedKernel.Session.Async
import VerifiedKernel.Session.Queue
import VerifiedKernel.Session.Replies
import VerifiedKernel.Session.Transcript
import VerifiedKernel.Session.Fact
import VerifiedKernel.Session.History
import VerifiedKernel.Schema

namespace VerifiedKernel.Session
open Data

def inner (state event : Term) : KernelM Term := do
  let kind := event.get (b "type")
  if kind == b "async_tool_call_progress" then progressStep state event
  else if kind == b "async_tool_call_started" then asyncStart state event
  else if kind == b "async_tool_call_completed" then asyncTerminal state event (b "completed")
  else if kind == b "async_tool_call_failed" then asyncTerminal state event (b "failed")
  else if kind == b "async_tool_call_cancelled" then asyncTerminal state event (b "cancelled")
  else if kind == b "capability_request_sync" then capabilitySync state event
  else if kind == b "status" then statusTransition state event
  else if kind == b "activity_status" then activityTransition state event
  else if kind == b "session_created" then metadataCreated state event
  else if kind == b "conversation_source_advance" then conversationSourceAdvance state event
  else if kind == b "miniskills_selected" then write state [("miniskills", event.get (b "selection"))]
  else if kind == b "session_system_prompt" then metadataPrompt state event
  else if kind == b "session_update" then metadataUpdate state event
  else if kind == b "compaction_failure" then compactionFailure state event
  else if kind == b "compaction_recovery" then compactionRecovery state event
  else if kind == b "queue_append" then queueAppend state event
  else if kind == b "queue_ack" then queueAck state event
  else if kind == b "queue_consume" && event.has (b "queue_id") then queueConsume state event
  else if kind == b "visible_reply_repair" then replyRepair state event
  else if kind == b "visible_reply_intent" then replyIntent state event
  else if kind == b "visible_reply_committed" || kind == b "visible_reply_aborted" then retireIntent state event
  else if kind == b "visible_reply_activation_started" && event.has (b "scope") then activationStarted state (event.get (b "scope"))
  else if kind == b "visible_reply_activation_finished" && event.has (b "response_identity") then activationFinished state (event.get (b "response_identity"))
  else if kind == b "provider_reply_obligation_resolved" && event.has (b "obligation_key") then obligationResolve state (event.get (b "obligation_key"))
  else if kind == b "provider_card_obligation_added" && event.has (b "conversation_id") && event.has (b "limit") then
    obligationCard state (event.get (b "conversation_id")) (event.get (b "limit"))
  else if kind == b "ack" then sessionAck state event
  else if kind == b "wait_set" then write state [("wait", ← Data.event event "wait")]
  else if kind == b "wait_clear" then waitClear state event
  else if kind == b "tool_result" then transcriptToolResult state event
  else if kind == b "assistant" then transcriptAssistant state event
  else if kind == b "session_log_message" then transcriptLog state event
  else if kind == b "transcript_seed" then transcriptSeed state event
  else if kind == b "runtime_message" then transcriptRuntime state event
  else if kind == b "delivery" then transcriptDelivery state event
  else if kind == b "session_event" then sessionEvent state event
  else if kind == b "session_microcompact" then microcompact state event
  else if kind == b "compaction" then historyCompaction state event false
  else if kind == b "provider_compaction" then historyCompaction state event true
  else if kind == b "session_compact_result" then compactResult state event
  else if kind == b "archive_advance" then archiveAdvance state event
  else if kind == b "tool_result_stored" then storedResult state event
  else if kind == b "session_stamp" then sessionStamp state event
  else if kind == b "bump_hwm" then bumpHwmEvent state event
  else pure state

def prepare (state rawEvent : Term) : KernelM (Term × Option Term) := do
  if !Schema.admissible state true || !Schema.admissible rawEvent then
    fail "schema" [b "Session accepts pure ETF data, the State envelope, and MapSet data only"]
  if state.get (a "__struct__") != a "Elixir.SalixAgent.InternalSession.State" || !rawEvent.isMap then
    fail "function_clause"
  let event ← shallowStringify rawEvent
  let target := event.get (b "session_id")
  if target.isBinary && state.has (a "session_id") && !target.numericEq (state.get (a "session_id")) then return (state, none)
  let next ← inner state event
  return (next, some event)

/-- `prepare` for a resident state: the state was checked against the schema
once when it was admitted and every reducer preserves the schema, so only the
event is checked here. -/
def prepareTrusted (state rawEvent : Term) : KernelM (Term × Option Term) := do
  if !Schema.admissible rawEvent then
    fail "schema" [b "Session accepts pure ETF data, the State envelope, and MapSet data only"]
  if state.get (a "__struct__") != a "Elixir.SalixAgent.InternalSession.State" || !rawEvent.isMap then
    fail "function_clause"
  let event ← shallowStringify rawEvent
  let target := event.get (b "session_id")
  if target.isBinary && state.has (a "session_id") && !target.numericEq (state.get (a "session_id")) then return (state, none)
  let next ← inner state event
  return (next, some event)

private def raised (reason : Term) : Term := .tuple [a "raised", reason]

private def schemaError : Term :=
  raised (.tuple [a "schema", list [b "continuations and observations must contain Session data"]])

def activityView (state : Term) : Term :=
  let fields := ["status", "activity_status", "activity_status_updated_at", "wait",
    "next_message_id", "last_ack_message_id", "storage_format", "llm_failure_streak",
    "runaway_unsettled_streak", "repeated_tool_result_streak", "input_round_streak", "visible_reply_repair",
    "runtime_failure_reply", "messages"]
  let format := state.get (a "storage_format")
  let fields := if format.isInteger && integerValue format ≥ 2 then fields else "events" :: fields
  .map (fields.filterMap (fun name =>
    if state.has (a name) then some (a name, state.get (a name)) else none))

/-- The reduced state stays resident in the kernel while the activity
classification waits for configuration; only the two activity-owned fields
travel back through the view. -/
private def restoreActivity (resident view : Term) : Term :=
  let next := resident.put (a "activity_status") (view.get (a "activity_status"))
  let next := if view.has (a "activity_status_updated_at") then
      next.put (a "activity_status_updated_at") (view.get (a "activity_status_updated_at"))
    else next
  .tuple [a "done", next]

/-- An activity continuation: the resident reduced state, the activity views of
the previous and reduced states, the timestamp fields of the event, and the
observations recorded so far. -/
private def activityToken (resident state next event : Term) (observations : List Term) : Term :=
  .tuple [a "activity", resident, state, next, event, list observations]

def runActivity (state next event : Term) (observations : List Term) : Term :=
  match afterEvent state next event observations with
  | .ok (next, []) => .tuple [a "done", next]
  | .ok (_, _ :: _) => raised (.tuple [a "invalid_observation", list []])
  | .error (.observe request) =>
    .tuple [a "observe", request, activityToken next
      (activityView state) (activityView next)
      (select event ["created_at", "updated_at", "activity_status_updated_at", "status_updated_at"])
      observations]
  | .error (.raised reason) => raised reason

def run (state event : Term) (observations : List Term := []) : Term :=
  if !Schema.admissible (list observations) then schemaError else
  match prepare state event observations with
  | .ok ((next, none), []) => .tuple [a "done", next]
  | .ok ((_, none), _ :: _) => raised (.tuple [a "invalid_observation", list []])
  | .ok ((next, some normalized), rest) => runActivity state next normalized rest
  | .error (.observe request) =>
    .tuple [a "observe", request, .tuple [a "reduce", state, event, list observations]]
  | .error (.raised reason) => raised reason

/-- `runActivity` over a resident state: answered-ahead observations may remain. -/
def runActivityTrusted (state next event : Term) (observations : List Term) : Term :=
  match afterEvent state next event observations with
  | .ok (next, rest) =>
    if settled rest then .tuple [a "done", next]
    else raised (.tuple [a "invalid_observation", list []])
  | .error (.observe request) =>
    .tuple [a "observe", request, activityToken next
      (activityView state) (activityView next)
      (select event ["created_at", "updated_at", "activity_status_updated_at", "status_updated_at"])
      observations]
  | .error (.raised reason) => raised reason

/-- `run` over a resident state (see `prepareTrusted`). -/
def runTrusted (state event : Term) (observations : List Term := []) : Term :=
  if !Schema.admissible (list observations) then schemaError else
  match prepareTrusted state event observations with
  | .ok ((next, none), rest) =>
    if settled rest then .tuple [a "done", next]
    else raised (.tuple [a "invalid_observation", list []])
  | .ok ((next, some normalized), rest) => runActivityTrusted state next normalized rest
  | .error (.observe request) =>
    .tuple [a "observe", request, .tuple [a "reduce", state, event, list observations]]
  | .error (.raised reason) => raised reason

def resume (token observation : Term) : Term :=
  if !Schema.admissible observation then schemaError else
  match token with
  | .tuple [.atom "reduce", state, event, .list observations] =>
    run state event (observations ++ [observation])
  | .tuple [.atom "activity", resident, state, next, event, .list observations] =>
    if Schema.admissible state && Schema.admissible next &&
        Schema.admissible event && Schema.admissible (list observations) then
      let observations := observations ++ [observation]
      match afterEvent state next event observations with
      | .ok (view, []) => restoreActivity resident view
      | .ok (_, _ :: _) => raised (.tuple [a "invalid_observation", list []])
      | .error (.observe request) =>
        .tuple [a "observe", request, activityToken resident state next event observations]
      | .error (.raised reason) => raised reason
    else schemaError
  | _ => raised (.tuple [a "invalid_observation", list []])

/-- `resume` over a resident state: the token's states came from the kernel,
so only the observation is checked. -/
def resumeTrusted (token observation : Term) : Term :=
  if !Schema.admissible observation then schemaError else
  match token with
  | .tuple [.atom "reduce", state, event, .list observations] =>
    runTrusted state event (observations ++ [observation])
  | .tuple [.atom "activity", resident, state, next, event, .list observations] =>
    let observations := observations ++ [observation]
    match afterEvent state next event observations with
    | .ok (view, rest) =>
      if settled rest then restoreActivity resident view
      else raised (.tuple [a "invalid_observation", list []])
    | .error (.observe request) =>
      .tuple [a "observe", request, activityToken resident state next event observations]
    | .error (.raised reason) => raised reason
  | _ => raised (.tuple [a "invalid_observation", list []])

/-! ### Resident state

The host never receives the Session state inside a response or a
continuation. `detach` removes the state from a `run` or `resume` result
and `attach` restores it into a continuation before `resume`. -/

/-- Splits the state that must stay resident out of a kernel response. -/
def detach : Term → Option Term × Term
  | .tuple [.atom "done", next] => (some next, .tuple [a "done"])
  | .tuple [.atom "observe", request, .tuple [.atom "reduce", state, event, observations]] =>
    (some state, .tuple [a "observe", request, .tuple [a "reduce", event, observations]])
  | .tuple [.atom "observe", request, .tuple [.atom "activity", next, state, view, event, observations]] =>
    (some next, .tuple [a "observe", request, .tuple [a "activity", state, view, event, observations]])
  | .tuple [.atom "observe", request, .tuple [.atom "op", kind, state, name, args, observations]] =>
    (some state, .tuple [a "observe", request, .tuple [a "op", kind, name, args, observations]])
  | other => (none, other)

/-- Restores the resident state into a host continuation. -/
def attach (resident : Term) : Term → Term
  | .tuple [.atom "reduce", event, observations] => .tuple [a "reduce", resident, event, observations]
  | .tuple [.atom "activity", state, view, event, observations] =>
    .tuple [a "activity", resident, state, view, event, observations]
  | .tuple [.atom "op", kind, name, args, observations] =>
    .tuple [a "op", kind, resident, name, args, observations]
  | other => other

end VerifiedKernel.Session
