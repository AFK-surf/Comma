import VerifiedKernel.Session.Query.Round
import VerifiedKernel.Session.Query.Repair
import VerifiedKernel.Session.Query.Materialize
import VerifiedKernel.Session.Recovery

namespace VerifiedKernel.Session.Command
open Data

def finish (result : Term) (checkpoint : Term := nil) : Term :=
  .tuple [a "return", result, checkpoint]

def perform (request continuation : Term) : Term :=
  let continuation := match request with
    | .tuple [.atom "write", _, _] => .tuple [b "durable_fence", continuation]
    | _ => continuation
  .tuple [a "perform", request, continuation]

private def value (data : Term) (name : String) : Term :=
  (data.get (a name)).default (data.get (b name))

def compact (pairs : List (String × Term)) : Term :=
  .map ((pairs.filter (fun pair => pair.2 != nil)).map (fun pair => (b pair.1, pair.2)))

def waitTimeout (state args : Term) : KernelM Term := do
  let wait ← field state "wait"
  if !wait.isMap then return nil
  let .tuple [.atom "ok", identity] ← StateQuery.waitIdentity wait | return nil
  match args with
  | .tuple [expected, _] => if expected != identity then return nil
  | _ => if !(← RoundQuery.waitExpired state).truthy then return nil
  let source := match args with | .tuple [_, source] => source | _ => nil
  let wait ← stringify wait
  let now := integerValue (← observe (a "time"))
  let deadline := wait.get (b "deadline_ms")
  let timeout := wait.get (b "timeout_seconds")
  let facts := compact ((["reason", "timeout_seconds", "deadline_ms", "source", "tool_call_id", "tool_call_ids"].map
    (fun name => (name, wait.get (b name)))) ++
    [("wait_id", identity),
     ("elapsed_ms", if deadline.isInteger && timeout.isInteger then
       i (max 0 (now - integerValue deadline + integerValue timeout * 1000)) else nil),
     ("overdue_ms", if deadline.isInteger then i (max 0 (now - integerValue deadline)) else nil)])
  let facts := Term.map ((← entries facts).filter (fun pair => pair.2 != b ""))
  let source ← if source.truthy then pure source else do
    let session ← stringChars (← field state "session_id")
    let .binary session := session | fail "badarg"
    let .binary identity := identity | fail "badarg"
    pure (.binary ("wait-timeout:".toUTF8 ++ session ++ ":".toUTF8 ++ identity))
  let payload := facts.put (b "type") (b "wait_expired")
    |>.put (b "summary") (b "wait timeout reached")
    |>.put (b "content") (b "wait timeout reached with no new input; if you still wait for a delegated Task or a running tool, call wait_for again and let its report wake you instead of reading the conversation")
    |>.put (b "source_refs") facts |>.put (b "runtime_message_id") source
  return .map [(b "type", b "queue_append"), (b "session_id", ← field state "session_id"),
    (b "kind", b "runtime_message"), (b "wake", a "true"), (b "dedupe_key", source),
    (b "created_at", i (now / 1000)), (b "payload", payload)]

private def llmRetry (state args : Term) : KernelM Term := do
  let .tuple [metadata, hwm] := args | fail "function_clause"
  if ((← field state "runtime_failure_reply").get (b "notification_outcome")).isBinary then return metadata
  let attempt := integerValue (← failureCount state) + 1
  let cap ← observe (.tuple [a "config", a "salix_agent", a "llm_failure_activation_cap", i 3])
  if metadata.get (b "retryable") != a "true" || !cap.isInteger || integerValue cap ≤ 0 ||
    attempt ≥ integerValue cap || integerValue (← field state "next_message_id") - 1 != integerValue hwm then return metadata
  let base ← observe (.tuple [a "config", a "salix_agent", a "llm_activation_retry_base_ms", i 5000])
  let base := if base.isInteger && integerValue base > 0 then min (integerValue base) 30000 else 5000
  let delay := min (base * 2 ^ (min (max (attempt - 1) 0) 10).toNat) 30000
  return metadata.put (b "retry_at_ms") (i (integerValue (← observe (a "time")) + delay))

private def optionalMap (data : Term) (name : String) : KernelM Term := do
  let item := value data name
  if item.isMap then stringify item else pure nil

def initialAttrs (payload : Term) : KernelM Term := do
  let attrs := compact ((["name", "hidden", "created_at", "platform", "source_session_id",
    "source_schedule_id"].map (fun name => (name, value payload name))) ++
    [("billing_context", ← optionalMap payload "billing_context"),
     ("task_origin", ← optionalMap payload "task_origin")])
  return attrs

private def attachment (item : Term) : Bool :=
  let accepted (key : String → Term) :=
    let path := item.get (key "path")
    let file := item.get (key "file_ref")
    (item.get (key "type") == b "file" && path.isBinary && path != b "") ||
    (item.get (key "type") == b "image" && file.get (key "environment_id") == b "vfs" &&
      (file.get (key "path")).isBinary && file.get (key "path") != b "")
  item.isMap && (accepted a || accepted b)

def inputEvent (sessionId source payload now : Term) : KernelM Term := do
  let refs ← ((wrap (value payload "trusted_attachment_refs")).filter attachment).mapM stringify
  let arrived := value payload "delivered_at_ms"
  let arrived := if arrived.isInteger && integerValue arrived > 0 then arrived else nil
  let body := compact [
    ("source_message_id", source), ("role", (value payload "role").default (b "user")),
    ("content", value payload "content"), ("created_at", value payload "created_at"),
    ("delivered_at_ms", arrived), ("input_time", value payload "input_time"),
    ("trusted_attachment_refs", if refs.isEmpty then nil else list refs),
    ("trusted_origin", ← optionalMap payload "trusted_origin"),
    ("billing_context", ← optionalMap payload "billing_context"),
    ("provider_reply_obligation", ← optionalMap payload "provider_reply_obligation")]
  return compact [("type", b "queue_append"), ("session_id", sessionId),
    ("kind", b "user_message"), ("dedupe_key", source),
    ("wake", Term.bool (payload.get (a "no_wake") != a "true" && payload.get (b "no_wake") != a "true")),
    ("created_at", (value payload "created_at").default now), ("payload", body)]

def preInputEvent (sessionId payload : Term) : Term :=
  compact [("type", b "queue_append"), ("session_id", sessionId), ("kind", b "user_message"),
    ("wake", a "false"), ("dedupe_key", value payload "source_message_id"),
    ("created_at", value payload "created_at"), ("payload", compact [
      ("source_message_id", value payload "source_message_id"),
      ("role", (value payload "role").default (b "user")),
      ("content", value payload "content"), ("created_at", value payload "created_at")])]

def writeInput (events : Term) (notifyInput : Bool := true) : Term :=
  perform (.tuple [a "write", events, list []])
    (if notifyInput then .tuple [b "input_written", events] else b "log_written")

def project (state : Term) (events : List Term) : KernelM Term :=
  events.foldlM (fun state event => do
    let (next, normalized) ← prepareTrusted state event
    match normalized with
    | some event => afterEvent state next event
    | none => pure next) state

def projected (state args : Term) : KernelM Term := do
  let .tuple [events, hwm, _, _] := args | fail "function_clause"
  let state ← project state (← asList events)
  if hwm.isInteger && integerValue hwm ≥ 0 then
    project state [.map [(b "type", b "bump_hwm"), (b "hwm", hwm)]]
  else pure state

/-- `projected` for a planner that reads the projection only through queries,
to choose its outcome. No query reads `async_result_refs`. A queue event at
the end of the batch changes the queue, the references and the activity
status, and pruning its references walks the whole transcript, so it applies
to the session without references; the events it follows see them as usual.
The batch that the plan commits applies every event to the real session. -/
def decisionProjected (state args : Term) : KernelM Term := do
  let .tuple [events, hwm, x, y] := args | fail "function_clause"
  let items ← asList events
  let queueEvent := fun (event : Term) =>
    event.get (b "type") == b "queue_ack" || event.get (b "type") == b "queue_consume"
  let tail := (items.reverse.takeWhile queueEvent).reverse
  if tail.isEmpty || !state.has (a "async_result_refs") then return ← projected state args
  let body := items.take (items.length - tail.length)
  let before ← project state body
  let before := if before.has (a "async_result_refs") then before.put (a "async_result_refs") empty else before
  projected before (.tuple [list tail, hwm, x, y])

def activationFast (state : Term) : KernelM Term := do
  if (← field state "status") == a "active" || (← StateQuery.pendingVisibleReply state) ||
      (← StateQuery.retryAt state).isInteger || (← repairExhausted state) ||
      (← RoundQuery.waitExpired state).truthy then return a "fallback"
  let waiting ← StateQuery.waiting state
  if waiting && (← field state "wait").get (b "source") != b "auto_wait" then return a "fallback"
  let queued ← StateQuery.hasUnackedWakeable state
  if waiting && !queued then return a "fallback"
  if !(queued || (← StateQuery.needsContinuation state) || (← StateQuery.hasUnprocessedStableWork state)) then
    return a "idle"
  let .tuple [events, wake, hwm] ← StateQuery.materialize state 100 | fail "function_clause"
  let next ← decisionProjected state (.tuple [events, hwm, nil, nil])
  if waiting && (← StateQuery.waiting next) then return a "fallback"
  if queued && (!(wake.truthy || (← StateQuery.hasUnprocessedStableWork next)) || (← repairExhausted next) ||
      (← StateQuery.modelGuardExhausted next)) then
    return a "fallback"
  return .tuple [a "activate", events, hwm]

private def activationNext (state router : Term) : KernelM Term := do
  if (← field state "status") == a "active" then
    return .tuple [a "error", .tuple [a "unrepaired_active_round",
      ← field state "agent_id", ← field state "session_id"]]
  if ← StateQuery.yieldableProviderWait state then
    if router == nil then return a "check_router"
    if router.truthy then return a "yield"
  if (← RoundQuery.waitExpired state).truthy then return a "expire"
  if ← StateQuery.hasUnackedWakeable state then return a "materialize"
  if ← repairExhausted state then return a "idle"
  if ← StateQuery.waiting state then return a "wait"
  let retryAt ← StateQuery.retryAt state
  if retryAt.isInteger then
    if ← atMost retryAt (← observe (a "time")) then return a "resume"
    return .tuple [a "retry", retryAt]
  if ← StateQuery.needsContinuation state then return a "resume"
  if ← StateQuery.hasUnprocessedStableWork state then return a "run"
  return a "idle"

/-- A parked model guard holds through the loop's own wakes: a background
completion or a wait timeout is materialized but runs no model round. A pending
guard failure reply still activates, because the activation commit dispatches
that reply instead of a model round and it must go out before any further
input is admitted. Otherwise the advanced queue ACK asks for one more
processing pass. Fresh input resets the guard before this check. -/
private def materializationOutcome (state next mode wake : Term) : KernelM Term := do
  if mode == a "run" then return a "run"
  if wake.truthy && (← repairExhausted next) then return a "idle"
  if wake.truthy && !(← StateQuery.modelGuardExhausted next) then return a "run"
  if wake.truthy && (← RoundQuery.guardDispositionPending next) then return a "run"
  if (← field next "queue_ack_id") != (← field state "queue_ack_id") then return a "continue"
  if ← StateQuery.waiting next then return a "wait"
  if ← StateQuery.hasUnprocessedStableWork next then return a "run"
  return a "idle"

def materializationPlan (state args : Term) : KernelM Term := do
  let .tuple [leading, mode] := args | fail "function_clause"
  let .tuple [events, wake, hwm] ← StateQuery.materialize (← project state (← asList leading)) 100
    | fail "function_clause"
  let events := list ((← asList leading) ++ (← asList events))
  let next ← decisionProjected state (.tuple [events, hwm, nil, nil])
  let outcome ← materializationOutcome state next mode wake
  return .tuple [events, hwm, outcome]

/-- Revision planning selects its control prefix inside the kernel. -/
def revisionPlan (state mode : Term) : KernelM Term := do
  if mode == a "fast" then activationFast state
  else if mode == a "expire" then
    let expired ← waitTimeout state nil
    materializationPlan state (.tuple [list (if expired == nil then [] else [expired]), a "until_wake"])
  else if mode == a "run" || mode == a "until_wake" then
    materializationPlan state (.tuple [list [], mode])
  else fail "invalid_observation"

private def directReady (state : Term) : KernelM Term := do
  let error := fun reason => Term.tuple [a "error", a reason]
  if ← repairExhausted state then return error "visible_reply_repair_exhausted"
  if !(← StateQuery.unackedItems state).isEmpty then return error "activation_required"
  let reasons ← asList (← StateQuery.workReasons state)
  if reasons.isEmpty then return a "ok"
  if reasons.contains (b "active_round") then return error "session_busy"
  if reasons.contains (b "wait_deadline") then return error "session_waiting"
  if reasons.all (fun reason => [b "process_local_background_tool_run", b "external_callback_tool_call"].contains reason) then
    return error "session_has_background_tool_work"
  return error "activation_required"

def roundPresentation (state : Term) : KernelM Term := do
  let error := fun reason => Term.tuple [a "error", .tuple [a "visible_reply_authorization_retry", a reason]]
  let candidate ← ReplyQuery.derive state (← ReplyQuery.currentSourceMessageIds state)
  let scope ← field state "visible_reply_activation_scope"
  let phase ← ReplyQuery.phase state
  let guard ← ReplyQuery.guard state
  let required ← StateQuery.repairRequired state
  match candidate with
  | .tuple [.atom "ok", candidate] =>
    if !scope.isMap then return error "activation_scope_missing"
    if !validScope scope || !(← ReplyQuery.scopesEquivalent (.tuple [candidate, scope])).truthy then
      return error "activation_scope_mismatch"
    return .tuple [a "ok", scope, phase, guard, Term.bool required]
  | _ => return .tuple [a "ok", nil, phase, guard, Term.bool required]

private def activationError (reason checkpoint : Term) : Term :=
  finish (.tuple [a "error", .tuple [a "visible_reply_authorization_retry", reason]]) checkpoint

def activated (state details : Term) : KernelM Term := do
  let current ← field state "visible_reply_activation_scope"
  let retired := details.get (a "retired_scope")
  let replaced := details.get (a "replaced_scope")
  let scope := if retired.isMap && current == nil then retired
    else if replaced.isMap && value replaced "response_identity" != value current "response_identity"
      then replaced else nil
  if scope.isMap then
    return perform (.tuple [a "draft_clear", scope]) (b "activated")
  return finish (a "ok")

-- `session` is `projected state args`, computed once by the caller: the
-- projection replays the materialization over the whole transcript, and
-- one activation phase used to replay it at every step.
def commitActivation (state session args events details checkpoint : Term) : KernelM Term := do
  let .tuple [leading, hwm, prompt, active] := args | fail "function_clause"
  let candidate ← project session (← asList events)
  let .tuple [promptEvents, _] ← ReplyQuery.promptSnapshot candidate prompt | fail "function_clause"
  let status := .map [(b "type", b "status"),
    (b "session_id", ← field state "session_id"), (b "status", b "active")]
  let promptEvents ← asList promptEvents
  let all := (← asList leading) ++ (← asList events) ++
    (if active.truthy then promptEvents ++ [status] else [])
  if all.isEmpty then return ← activated state details
  let opts := list [.tuple [a "hwm", hwm], .tuple [a "on_conflict", a "error"]]
  return perform (.tuple [a "write", list all, opts])
    (.tuple [b "activation_written", details, checkpoint, active])

def retireActivation (state session args : Term) : KernelM Term := do
  let .tuple [events, details] ← ReplyQuery.activationRetirement session
    (.tuple [← field state "session_id", i (integerValue (← observe (a "time")) / 1000)])
    | fail "function_clause"
  commitActivation state session args events details nil

def installActivation (state session args candidate checkpoint : Term) : KernelM Term := do
  let result ← ReplyQuery.activationStart session (.tuple [candidate,
    ← ReplyQuery.currentSourceMessageIds session, ← field state "session_id",
    i (integerValue (← observe (a "time")) / 1000)])
  match result with
  | .tuple [.atom "ok", events, _, details] => commitActivation state session args events details checkpoint
  | .tuple [.atom "error", reason] => pure (activationError reason checkpoint)
  | _ => fail "function_clause"

def authorizedActivation (state session args candidate : Term) : KernelM Term := do
  match ← ReplyQuery.reusableScope session candidate with
  | .tuple [.atom "ok", current] =>
    return ← commitActivation state session args (list []) (.map [(a "scope", current)]) candidate
  | _ => pure ()
  let identity := value candidate "response_identity"
  if identity != nil then
    if !validResponseIdentity identity then return activationError (a "invalid_response_identity") candidate
    return ← installActivation state session args (candidate.put (b "response_identity") identity) candidate
  return perform (.tuple [a "random", i 18]) (.tuple [b "activation_entropy", args, candidate])

def activate (state args checkpoint : Term) : KernelM Term := do
  let session ← projected state args
  match ← ReplyQuery.derive session (← ReplyQuery.currentSourceMessageIds session) with
  | .tuple [.atom "ok", candidate] =>
    if checkpoint.isMap && (← ReplyQuery.scopesEquivalent (.tuple [checkpoint, candidate])).truthy then
      authorizedActivation state session args checkpoint
    else pure (perform (.tuple [a "authorize", candidate]) (.tuple [b "activation_authorized", args, candidate]))
  | _ => retireActivation state session args

private def recover (state checkpoint : Term) : KernelM Term := do
  match ← ReplyQuery.abortPendingReply state (.tuple [← field state "session_id",
      i (integerValue (← observe (a "time")) / 1000)]) with
  | .tuple [.atom "ok", events, hwm, intent] =>
    return perform (.tuple [a "write", events, list [.tuple [a "hwm", hwm]]])
      (.tuple [b "recovered", value intent "scope"])
  | _ => return finish (← Recovery.observeSession state checkpoint)

/-- Delivery accepts input records, context facts, birth metadata, and workspace operations.
Owner control events and unknown event types cannot enter through delivery. -/
def inputEventAllowed (event : Term) : Bool :=
  [b "queue_append", b "runtime_message", b "delivery", b "session_log_message",
    b "transcript_seed", b "session_created", b "vfs_write", b "vfs_delete", b "vfs_copy"].contains
    (event.get (b "type")) ||
    (event.get (b "type") == b "session_event" && event.get (b "kind") == b "context")

def timestampLifecycle (event : Term) (now : Int) : Term :=
  if [b "session_created", b "status", b "activity_status", b "wait_set", b "wait_clear"].contains
      (event.get (b "type")) && !(event.get (b "created_at")).isInteger then
    event.put (b "created_at") (i now)
  else event

def inputEvents (entry : Term) : KernelM (List Term) := do
  let payload := value entry "payload"
  let rawEvents := if payload.has (a "events") then payload.get (a "events")
    else (payload.get (b "events")).default (list [])
  let events ← (← asList rawEvents).mapM stringify
  let now := integerValue (← observe (a "time")) / 1000
  return events.map (fun event => timestampLifecycle event now)

/-- Use the identity writers' key rules, including context and transcript records. -/
def inputIdentityGroups (event : Term) : KernelM (List (List Term)) := do
  let kind := event.get (b "type")
  if kind == b "queue_append" then
    let payload ← stringify ((event.get (b "payload")).default empty)
    return [← queueKeys event payload (event.get (b "kind"))]
  if kind == b "runtime_message" then
    if event.get (b "from_queue") != a "true" && event.get (b "from_context_provider") != a "true" then return []
    return [← runtimeKeys event]
  if kind == b "delivery" then
    if event.get (b "from_queue") != a "true" then return []
    return [uniq ([event.get (b "source_message_id"), event.get (b "dedupe_key")].filter (· != nil))]
  if kind == b "session_log_message" then
    return [uniq ([event.get (b "source_message_id"), event.get (b "dedupe_key")].filter (!missing ·))]
  if kind == b "transcript_seed" then
    enumFold ((event.get (b "entries")).default (list [])) [] (fun groups raw => do
      let entry ← stringify raw
      return (← seedKeys entry) :: groups)
  else pure []

/-- Identity aliases must not let one input in a batch suppress another input. -/
def inputIdentitiesDistinct (events : List Term) : KernelM Bool := do
  let groups ← events.mapM inputIdentityGroups
  let keys := groups.flatten.flatten
  return (uniq keys).length == keys.length

def commitInput (state entry : Term) (trailing : List Term) (notifyInput : Bool) : KernelM Term := do
  let payload := value entry "payload"
  let source := value entry "source_message_id"
  let agentId ← field state "agent_id"
  let sessionId ← field state "session_id"
  let events ← inputEvents entry
  if !(events ++ trailing).all inputEventAllowed then
    return finish (.tuple [a "error", a "invalid_delivery_events"])
  if !(← inputIdentitiesDistinct (events ++ trailing)) then
    return finish (.tuple [a "error", a "invalid_delivery_events"])
  let isWorkspace := fun event => [b "vfs_write", b "vfs_delete", b "vfs_copy"].contains (event.get (b "type"))
  let workspace := events.filter isWorkspace
  let events := list (events.filter (fun event => !isWorkspace event) ++ trailing)
  let write := writeInput events notifyInput
  if workspace.isEmpty then return write
  let .binary agentBytes := agentId | fail "badarg"
  let .binary sessionBytes := sessionId | fail "badarg"
  let .binary sourceBytes ← stringChars source | fail "badarg"
  let operationId := Term.binary ("delivery-workspace:".toUTF8 ++ agentBytes ++ ":".toUTF8 ++
    sessionBytes ++ ":".toUTF8 ++ sourceBytes)
  let metadata := compact [("source_message_id", ← stringChars source), ("session_id", sessionId),
    ("event_count", i (Int.ofNat workspace.length))]
  return perform (.tuple [a "workspace", operationId, metadata, list workspace,
    (value payload "billing_context").default empty])
    (.tuple [b "input_workspace", events, Term.bool notifyInput])

private def logInput (state entry : Term) : KernelM Term := do
  let payload := value entry "payload"
  let role := value payload "role"
  if [b "user", b "runtime", a "user", a "runtime"].contains role then
    return finish (.tuple [a "error", .tuple [a "invalid_session_log_role", role]])
  let event := compact [("type", b "session_log_message"), ("session_id", ← field state "session_id"),
    ("message_id", value payload "message_id"), ("role", b "event"), ("content", value payload "content"),
    ("source_message_id", value entry "source_message_id"), ("dedupe_key", value payload "dedupe_key"),
    ("created_at", (value payload "created_at").default (i (integerValue (← observe (a "time")) / 1000)))]
  commitInput state entry [event] false

def duplicateInput : Term := perform (a "durable_fence") (b "input_duplicate_fenced")

def input (state args : Term) : KernelM Term := do
  let .tuple [entry, born] := args | fail "function_clause"
  let payload := value entry "payload"
  let source := value entry "source_message_id"
  let limit ← observe (.tuple [a "config", a "salix_agent", a "session_input_queue_limit", i 1000])
  match ← RoundQuery.deliveryAdmission state (.tuple [source, payload, limit]) with
  | .atom "duplicate" => return duplicateInput
  | .atom "saturated" => return finish (.tuple [a "error", a "saturated"])
  | _ => pure ()
  let sessionId ← field state "session_id"
  let now := i (integerValue (← observe (a "time")) / 1000)
  let created := timestampLifecycle
    ((← initialAttrs payload).put (b "type") (b "session_created") |>.put (b "session_id") sessionId)
    (integerValue now)
  let pre := ((wrap (value payload "pre_deliveries")).filter Term.isMap).map (preInputEvent sessionId)
  let events := (if born.truthy then [created] else []) ++ pre ++ [← inputEvent sessionId source payload now]
  commitInput state entry events true

def conversationFrontier (source : Term) : Term :=
  .map [(b "type", b "conversation_source_advance"), (b "source", source)]

def withConversationFrontier (source : Term) (result : Term) : Term :=
  match result with
  | .tuple [.atom "perform", .tuple [.atom "write", .list events, options],
      .tuple [.binary fence, continuation]] =>
    let batch := list (events ++ [conversationFrontier source])
    let continuation := if continuation == b "log_written" then continuation
      else .tuple [b "input_written", batch]
    if fence == "durable_fence".toUTF8 then
      perform (.tuple [a "write", batch, options]) continuation
    else result
  | .tuple [.atom "perform", request,
      .tuple [.binary phase, .list events, notifyInput]] =>
    if phase == "input_workspace".toUTF8 then
      perform request (.tuple [b "input_workspace",
        list (events ++ [conversationFrontier source]), notifyInput])
    else result
  | _ => result

def isDuplicateInput : Term → Bool
  | .tuple [.atom "perform", .atom "durable_fence", .binary phase] =>
    phase == "input_duplicate_fenced".toUTF8
  | _ => false

def conversationInput (state args : Term) : KernelM Term := do
  let .tuple [entry, _] := args | fail "function_clause"
  let progress := value entry "conversation_source"
  let sources := (← field state "conversation_sources").default empty
  let previous := (sources.get (progress.get (b "participant_id"))).default empty
  let before := conversationSourceBefore previous progress
  let seq := progress.get (b "seq")
  if !progress.isMap || !(progress.get (b "participant_id")).isBinary ||
      progress.get (b "generation") != (← field state "session_id") ||
      (previous != empty && previous.get (b "conversation_id") != progress.get (b "conversation_id")) ||
      !seq.isInteger || integerValue seq > integerValue before + 1 then
    return finish (.tuple [a "error", a "conversation_source_gap"])
  if integerValue seq ≤ integerValue before then return duplicateInput
  let result ← if value entry "conversation_scan_only" == a "true" then
      commitInput state entry [] false
    else do
      let result ← input state args
      if isDuplicateInput result then commitInput state entry [] false else pure result
  return withConversationFrontier progress result

/-- Direct-log admission returns working state, never a durable acknowledgment.
The owner must fence this revision, normally together with activation, before
advancing its source cursor. Generic input retains its durable acknowledgment. -/
def stageConversationResult (result : Term) : Term :=
  match result with
  | .tuple [.atom "perform", request@(.tuple [.atom "write", events, _]),
      .tuple [.binary fence, _]] =>
    if fence == "durable_fence".toUTF8 then
      .tuple [a "perform", request, .tuple [b "conversation_staged", events]]
    else result
  | .tuple [.atom "perform", request, continuation@(.tuple [.binary phase, _, _])] =>
    if phase == "input_workspace".toUTF8 then
      perform request (.tuple [b "conversation_stage_effect", continuation])
    else result
  | _ => result

def resumeCommitted (state args : Term) : KernelM Term := do
  let .tuple [continuation, result] := args | fail "function_clause"
  match continuation with
  | .tuple [.binary phase, args, candidate] =>
    if phase == "input_workspace".toUTF8 then
      return if result == a "ok" then writeInput args candidate.truthy else finish result
    if phase == "activation_authorized".toUTF8 then
      match result with
      | .atom "ok" => return ← authorizedActivation state (← projected state args) args candidate
      | .atom "none" => return ← retireActivation state (← projected state args) args
      | .tuple [.atom "error", .tuple [.atom "permanent", _]] =>
        return ← retireActivation state (← projected state args) args
      | .tuple [.atom "error", reason] => return activationError reason nil
      | _ => fail "invalid_observation"
    if phase == "activation_entropy".toUTF8 then
      let .binary bytes := result | fail "invalid_observation"
      return ← installActivation state (← projected state args) args
        (candidate.put (b "response_identity") (.binary ("rsp_".toUTF8 ++ bytes))) candidate
    fail "invalid_observation"
  | .tuple [.binary phase, details, checkpoint, active] =>
    if phase == "activation_written".toUTF8 then
      match result with
      | .atom "ok" => return ← activated state details
      | .tuple [.atom "error", reason] =>
        let reason := if active.truthy then
          .tuple [a "visible_reply_pre_llm_error", a "round_status_activation", reason] else reason
        return activationError reason checkpoint
      | _ => fail "invalid_observation"
    fail "invalid_observation"
  | .tuple [.binary phase, events] =>
    if phase == "recovered".toUTF8 then
      match result with
      | .atom "ok" =>
        return perform (.tuple [a "draft_clear", events]) (b "recovery_cleared")
      | .tuple [.atom "error", reason] =>
        return finish (Recovery.outcome "retry" (b "append") (a "settlement") reason)
      | _ => fail "invalid_observation"
    if phase == "input_written".toUTF8 then
      return if result == a "ok" then
        perform (.tuple [a "notify", b "input_accepted", events]) (b "input_notified")
      else finish result
    fail "invalid_observation"
  | .binary phase =>
    if phase == "input_duplicate_fenced".toUTF8 then
      return if result == a "ok" then finish (.tuple [a "ok", a "duplicate"]) else finish result
    if phase == "recovery_cleared".toUTF8 then return finish (Recovery.outcome "settled")
    if phase == "log_written".toUTF8 then
      return if result == a "ok" then finish (.tuple [a "ok", a "committed"]) else finish result
    if phase == "activated".toUTF8 then return finish (a "ok")
    if phase == "input_notified".toUTF8 then return finish (.tuple [a "ok", a "committed"])
    fail "invalid_observation"
  | _ => fail "invalid_observation"

-- State application is not a durable observation. Acceptance and effect
-- continuations advance only after the host confirms the persistence fence.
def resume (state args : Term) : KernelM Term := do
  let .tuple [continuation, result] := args | fail "function_clause"
  match continuation with
  | .tuple [.binary phase, next] =>
    if phase == "conversation_staged".toUTF8 then
      return finish (if result == a "ok" then .tuple [a "ok", a "staged", next] else result)
    else if phase == "conversation_stage_effect".toUTF8 then
      return stageConversationResult (← resumeCommitted state (.tuple [next, result]))
    else if phase == "durable_fence".toUTF8 then
      if result == a "ok" then return perform (a "durable_fence") next
      else resumeCommitted state (.tuple [next, result])
    else resumeCommitted state args
  | _ => resumeCommitted state args

def start (state args : Term) : KernelM Term := do
  let .tuple [command, args, checkpoint] := args | fail "function_clause"
  if command == a "input" then input state args
  else if command == a "conversation_input" then conversationInput state args
  else if command == a "stage_conversation" then
    return stageConversationResult (← conversationInput state args)
  else if command == a "log" then logInput state args
  else if command == a "activate" then activate state args checkpoint
  else if command == a "recover" then recover state checkpoint
  else fail "function_clause"

def table : OpTable :=
  [("command", start), ("resume_command", resume),
   ("activation_fast", fun state _ => activationFast state),
   ("activation_next", activationNext),
   ("wait_timeout_event", waitTimeout),
   ("llm_retry_metadata", llmRetry),
   ("materialization_plan", materializationPlan),
   ("direct_round_ready", fun state _ => directReady state),
   ("round_presentation", fun state _ => roundPresentation state),
   ("response_stale?", fun state args => do
     let .tuple [snapshot, guard] := args | fail "function_clause"
     return Term.bool ((← RoundQuery.freshWakeableInput state snapshot).truthy ||
       (← repairExhausted state) || (← ReplyQuery.guard state) != guard)),
   ("initial_attributes", fun _ args => initialAttrs args)] ++ Recovery.table

end VerifiedKernel.Session.Command
