import VerifiedKernel.Session.Query
import VerifiedKernel.AgentLoop.TurnOutcome
import VerifiedKernel.AgentLoop.Round
import VerifiedKernel.AgentLoop.WaitExtension
import VerifiedKernel.AgentLoop.ToolSideEffects

/-! # The agent loop

`step : (session, machine, event) → (machine', [effect])`.

The kernel owns the sequence of one model round, from the provider response to
the round's outcome: stale-response steering, model failure, context overflow,
final output, tool turns, result settlement, continuation, guard parking and the
runtime failure notice. The host executes effects and answers with events. It
decides no branch.

A step is one transaction. At most one effect is a `commit`, and only
notifications may precede it. The host runs the step as the commit builder, so
a storage conflict re-runs the same step against the fresh session. Effects
after the commit run once the commit is durable. The last effect is the step's
single blocking effect, whose outcome is the next event:

* `continue` re-enters the machine with the event `continue`;
* `build_record` returns `{:record, record}`: the transcript record for the
  provider output, positioned at the session's next message id;
* `run_tools` returns `{:tools_done, results, async?}`;
* `store_results` returns `{:results_stored, events, hwm, base, results}`, the
  results as the workspace commit returned them;
* `commit_planned_results` returns `continue`;
* `stop` ends the round with its outcome.

Records carry the `base` message id they were built at. A record whose base no
longer matches the session is requested again, so a retried transaction never
commits a record positioned for another state.

The tool turn follows the proven `AgentLoop.Round` order: the intent commits
before tools execute, and results commit before the round continues. -/

namespace VerifiedKernel.Session.Loop
open Data
open RoundQuery (valueOf textKey)

/-- A query oracle: `ask state name args` answers the named session query.
The loop reads the session only through this oracle, `field`, `observe` and
`Command.project`. Proofs can reason about the control flow of `stepWith` for
any oracle. -/
abbrev Ask := Term → String → Term → KernelM Term

/-- The kernel's query oracle. It runs the named operation of `queryTable`. -/
def queryAsk (state : Term) (name : String) (args : Term) : KernelM Term :=
  match lookupOp queryTable (a name) with
  | some op => op state args
  | none => fail "unknown_query" [b name]

private def truthy (ask : Ask) (state : Term) (name : String) (args : Term := nil) : KernelM Bool :=
  return (← ask state name args).truthy

private def key (m : Term) (k : String) : Term := if m.isMap then m.get (b k) else nil

/-! ## Effects -/

private def notify (kind : String) (data : Term := nil) : Term := .tuple [a "notify", a kind, data]
private def commit (events : List Term) (hwm : Term := nil) (mode : Term := nil) : Term :=
  .tuple [a "commit", list events, (if hwm == nil then list [] else list [.tuple [a "hwm", hwm]]), mode]
private def stop (outcome : Term) : Term := .tuple [a "stop", outcome]
private def cont : Term := a "continue"

private def result (machine : Term) (effects : List Term) : Term := .tuple [machine, list effects]

private def phase (machine : Term) (name : String) : Term := machine.put (b "phase") (b name)

/-! ## Events the kernel constructs -/

private def seconds : KernelM Term := do
  let now ← observe (a "time")
  return i (integerValue now / 1000)

private def text (v : Term) : KernelM String := do
  match ← stringChars v with
  | .binary raw => return String.fromUTF8! raw
  | _ => return ""

private def statusEvent (sid : Term) (status : String) : Term :=
  .map [(b "type", b "status"), (b "session_id", sid), (b "status", b status)]

private def runawayUnsettled (sid aid content nonce : Term) : KernelM Term := do
  let bytes := match content with | .binary raw => raw.size | _ => 0
  return .map [(b "type", b "session_event"),
    (b "event_id", b s!"runaway-unsettled-round:{← text sid}:{← text aid}:{← text nonce}"),
    (b "kind", b "runaway_unsettled_round"), (b "source", b "internal_runtime"),
    (b "event", .map [(b "assistant_message_id", aid), (b "content_bytes", i bytes)]),
    (b "created_at", ← seconds)]

private def runawayReset (sid aid calls nonce : Term) : KernelM Term := do
  return .map [(b "type", b "session_event"),
    (b "event_id", b s!"runaway-guard-reset:{← text sid}:{← text aid}:{← text nonce}"),
    (b "kind", b "runaway_guard_reset"), (b "source", b "internal_runtime"),
    (b "event", .map [(b "assistant_message_id", aid), (b "tool_call_count", i (wrap calls).length)]),
    (b "created_at", ← seconds)]

/-! ## Host-built events

The host builds some events that the loop commits: the intent and admission
events of a tool turn, the leading and assistant events of a final output, and
the tool-result events of a batch. These events must not retire input, advance
the archive or stamp the session. Those kinds belong to other owners. The check
reads every map key that converts to `type`, as the key conversion of
`shallowStringify` does, and fails closed on a retiring or owner kind. -/

/-- The retiring and owner kinds that a host-built event must not carry. -/
def hostForbidden (kind : Term) : Bool :=
  [b "queue_ack", b "queue_consume", b "archive_advance", b "session_stamp"].contains kind

def hostEntry (item : Term) : Term :=
  match item with
  | .tuple [key, kind] =>
    if hostForbidden kind && VerifiedKernel.AgentLoop.ToolSideEffects.typeKey key then .tuple [a "error", kind]
    else a "ok"
  | _ => a "ok"

/-- `ok`, or `{error, reason}` for a non-map or a map with a forbidden type. -/
def hostEvent (value : Term) : Term :=
  if !value.isMap then .tuple [a "error", a "not_a_map"] else
    match enumUntil value (a "ok") (fun _ item =>
      let result := hostEntry item
      pure (result == a "ok", result)) [] with
    | .ok (result, _) => result
    | .error _ => .tuple [a "error", a "not_a_map"]

def hostEventsList : List Term → Term
  | [] => a "ok"
  | value :: rest =>
    let result := hostEvent value
    if result == a "ok" then hostEventsList rest else result

/-- Fail with `invalid_host_event` unless every event passes `hostEvent`. -/
def admitHostEvents (events : List Term) : KernelM Unit := do
  let checked := hostEventsList events
  if checked != a "ok" then
    fail "invalid_host_event" [match checked with | .tuple [_, reason] => reason | other => other]

/-! ## Round facts

The host supplies these once per round: `id_snapshot`, the visible-reply
`guard`, `vphase`, `source_ids`, `restricted`, `role`,
`canonical_router` (whether this session is its agent's Router), `guard_config` (whether the
round can dispatch a failure notice), and a `nonce` for event identities. -/

private def fact (machine : Term) (k : String) : Term := key (key machine "round") k

private def ackHwm (machine : Term) : Int :=
  let snapshot := integerValue (fact machine "id_snapshot")
  if snapshot > 0 then snapshot - 1 else 0

/-! ## Response shape -/

/-- `{kind, content, calls, provider_meta, trace_meta}` of a provider response. -/
private def parts : Term → Term
  | .tuple [.atom "final", content] => .tuple [a "final", content, list [], nil, empty]
  | .tuple [.atom "final", content, tmeta] => .tuple [a "final", content, list [], nil, tmeta]
  | .tuple [.atom "final", content, pmeta, tmeta] => .tuple [a "final", content, list [], pmeta, tmeta]
  | .tuple [.atom "assistant", content, calls] => .tuple [a "assistant", content, calls, nil, empty]
  | .tuple [.atom "assistant", content, calls, pmeta] => .tuple [a "assistant", content, calls, pmeta, empty]
  | .tuple [.atom "assistant", content, calls, pmeta, tmeta] =>
    .tuple [a "assistant", content, calls, pmeta, tmeta]
  | .tuple [.atom "error", info] => .tuple [a "error", info, list [], nil, empty]
  | _ => .tuple [a "other", nil, list [], nil, empty]

private def kindOf (response : Term) : Term :=
  match response with | .tuple (kind :: _) => kind | _ => a "other"

/-! ## The proven round order

The tool turn advances `AgentLoop.Round.step` at each transition and fails
closed if the proven machine would not issue the command the turn is about to
perform. -/

private def decodeRound (t : Term) : VerifiedKernel.AgentLoop.Round.State :=
  if t == b "await_intent" then .awaitIntent else if t == b "await_tools" then .awaitTools
  else if t == b "await_results" then .awaitResults else if t == b "settled" then .settled
  else if t == b "failed" then .failed else .ready

private def encodeRound : VerifiedKernel.AgentLoop.Round.State → Term
  | .ready => b "ready" | .awaitIntent => b "await_intent" | .awaitTools => b "await_tools"
  | .awaitResults => b "await_results" | .settled => b "settled" | .failed => b "failed"

private def advance (machine : Term) (event : VerifiedKernel.AgentLoop.Round.Event)
    (expected : VerifiedKernel.AgentLoop.Round.Command) : KernelM Term := do
  let (next, command) := VerifiedKernel.AgentLoop.Round.step (decodeRound (key machine "rstate")) event
  if command != expected then fail "round_order"
  return machine.put (b "rstate") (encodeRound next)

/-! ## Record requests -/

private def recordSpec (machine : Term) (mode : String) (extra : List (Term × Term) := []) : Term :=
  .map ([(b "mode", b mode), (b "content", key machine "content"), (b "calls", key machine "calls"),
    (b "provider_meta", key machine "provider_meta"), (b "trace_meta", key machine "trace_meta"),
    (b "replaced_calls", key machine "replaced_calls"), (b "vphase", fact machine "vphase")] ++ extra)

private def fresh (state record : Term) : KernelM Bool := do
  return key record "base" == (← field state "next_message_id")

/-! ## Guard parking and the runtime failure notice -/

private def failureSummary : String :=
  "I couldn't complete this request. I have stopped this execution. Any external action without a confirmed result may still need cleanup."
private def modelSummary : String :=
  "The model service could not continue this request. Ask your workspace administrator to check model availability, access and usage limits. Work already started may still finish. This notice does not cancel it or confirm its result."

private def noticeCall (binding : Term) : Term :=
  let model := key binding "failure_reason" == b "model"
  let billing := key binding "billing_reason"
  let summary := b (if billing == b "insufficient_credits" then
      "Not enough credits to continue this request. Add credits, then send a new message to try again."
    else if billing == b "account_inactive" || billing == b "missing_account" then
      "Billing is unavailable for this request. Ask your workspace administrator to check the billing account, then try again."
    else if model then modelSummary else failureSummary)
  let target := key binding "reply_target"
  let (tool, params) :=
    if target.isMap then
      let tool := key target "tool"
      let params := key target "params"
      (tool, if tool == b "im_api.internal.send_message" then
          params.put (b "content") (list [.map [(b "type", b "text"), (b "text", summary)]])
        else params.put (b "text") summary)
    else
      let thread := key binding "message_thread_id"
      let params := Term.map [(b "connect_id", key binding "connect_id"), (b "chat_id", key binding "chat_id"),
        (b "text", summary)]
      (b "im_api.telegram.send_message",
        if thread == nil || thread == b "" then params else params.put (b "message_thread_id") thread)
  let intent := if model then [(b "reply_mode", b "progress")]
    else [(b "reply_mode", b "final"), (b "final_outcome", b "blocked")]
  .map [(b "id", key binding "tool_call_id"), (b "name", b "call"),
    (b "args", .map ([(b "tool", tool), (b "params", params)] ++ intent)),
    (b "runtime_failure_reply", binding)]

/-- A round entered for a pending failure notice reports whether the notice
settled; any other round ends `final`. -/
private def finalStop (machine : Term) : Term × List Term :=
  if fact machine "entry" == b "guard_notice" then (phase machine "guard_outcome", [cont])
  else (phase machine "done", [stop (a "final")])

private def guardOutcome (ask : Ask) (state machine : Term) : KernelM Term := do
  let settled := (← field state "runtime_failure_reply").isMap || !(← truthy ask state "guard_disposition_pending?")
  return result (phase machine "done") [stop (if settled then a "final" else a "guard_failure_parked")]

/-- The report and activity of the guard that parked, then the notice. -/
private def park (ask : Ask) (state machine : Term) : KernelM Term := do
  let (guard, detail) ←
    if ← truthy ask state "runaway_unsettled_rounds_exhausted?" then
      pure ("runaway_guard_parked", ← ask state "consecutive_unsettled_rounds" nil)
    else if ← truthy ask state "repeated_tool_results_exhausted?" then
      pure ("repeated_tool_result_parked", Term.tuple [← ask state "consecutive_repeated_tool_results" nil,
        ← ask state "repeated_tool_result_tool" nil])
    else pure ("input_round_budget_parked", ← ask state "rounds_since_fresh_input" nil)
  return result (phase machine "guard_notice")
    [notify "guard_parked" (.tuple [b guard, detail]), notify "report" (b guard),
     notify "activity" (a "llm_failed"), notify "activity" (a "idle"), cont]

/-- `GuardFailureReply`: retire, settle locally, or reserve one notice. -/
private def guardNotice (ask : Ask) (state machine : Term) : KernelM Term := do
  let (stopped, stopEffects) := finalStop machine
  let retire ← ask state "runaway_retirement" nil
  if retire.isList then return result stopped (commit (← asList retire) :: stopEffects)
  let settle ← ask state "guard_failure_local_settlement" nil
  if settle.isList then return result stopped (commit (← asList settle) :: stopEffects)
  if (← field state "runtime_failure_reply").isMap then return result stopped stopEffects
  if !(fact machine "guard_config").truthy then return result stopped stopEffects
  let sid ← field state "session_id"
  let aid ← field state "next_message_id"
  let callId := b s!"runtime-failure-reply:{← text sid}:{← text aid}"
  let sources ← ask state "current_source_ids" nil
  let scope ← ask state "terminal_reply_source_scope" nil
  let router := fact machine "role" == b "router" && (fact machine "canonical_router").truthy
  let send ← ask state "terminal_reply_context" (.map [(b "role", fact machine "role"),
    (b "router_authority", Term.bool router), (b "agent_id", ← field state "agent_id"),
    (b "trusted_origin", key scope "trusted_origin"), (b "source_message_id", key scope "source_message_id"),
    (b "source_message_ids", sources), (b "assistant_id", aid), (b "call_count", i 1)])
  let disposition ← ask state "guard_disposition_binding" aid
  if !disposition.isMap then return result stopped stopEffects
  let binding := match disposition with
    | .map xs => Term.map (xs.filter (fun (k, _) => k != b "eligible"))
    | other => other
  let binding := (binding.put (b "outcome") (b "blocked")).put (b "tool_call_id") callId
  let attempt ← ask state "guard_failure_prepare" binding
  if !attempt.isMap then return result stopped stopEffects
  let call := noticeCall (key attempt "event")
  let assistant := Term.map [(b "type", b "assistant"), (b "session_id", sid), (b "message_id", aid),
    (b "content", b ""), (b "tool_calls", list [call]), (b "visible_reply_phase", b "clean")]
  let machine := ((machine.put (b "notice") call).put (b "notice_aid") aid).put (b "notice_authorized")
    (Term.bool send.isMap)
  return result (phase machine "notice_cleanup") [commit [assistant, attempt] aid, cont]

private def noticeCleanup (ask : Ask) (state machine : Term) : KernelM Term := do
  let now ← observe (a "time")
  let events ← ask state "guard_failure_cleanup_events" (.tuple [nil, now])
  if events == nil then return result machine [stop (.tuple [a "error", a "guard_failure_foreign_running_work"])]
  let call := key machine "notice"
  let pending := Term.map [(b "calls", list [call]), (b "aid", key machine "notice_aid"),
    (b "track", a "false"), (b "checkpoint", nil)]
  let machine := (phase machine "notice_results").put (b "pending") pending
  let cleanupEvents ← asList events
  let cleanup := if cleanupEvents.isEmpty then [] else [commit cleanupEvents]
  if (key machine "notice_authorized").truthy then
    return result machine (cleanup ++
      [.tuple [a "run_tools", list [call], .map [(b "mode", b "runtime_failure_notice"),
        (b "aid", key machine "notice_aid")]]])
  -- No send authority: the notice is refused without a provider side effect.
  let refusal := Term.map [(a "id", key call "id"), (a "name", key (key call "args") "tool"),
    (a "status", b "guidance"), (a "error", a "true"),
    (a "content", b "Runtime failure notification was refused: this session has no send authority."),
    (a "runtime_failure_reply", key call "runtime_failure_reply")]
  let machine := (machine.put (b "results") (list [refusal])).put (b "async") (a "false")
  return result machine (cleanup ++ [.tuple [a "store_results", pending, list [refusal]]])

/-! ## Final output -/

private def finalize (ask : Ask) (state machine : Term) (terminal : Term) : KernelM Term := do
  let prep ← ask state "output_preparation" (.tuple [fact machine "vphase", key terminal "outcome"])
  let .tuple [terminalResult, _] := prep | fail "function_clause"
  let machine := (phase machine "final_record").put (b "terminal") terminal
  return result machine [.tuple [a "build_record", recordSpec machine "final"
    [(b "terminal_call", key terminal "call"), (b "terminal_result", terminalResult)]]]

private def finalRecord (ask : Ask) (state machine record : Term) : KernelM Term := do
  if !(← fresh state record) then
    return ← finalize ask state machine (key machine "terminal")
  admitHostEvents (wrap (key record "leading") ++ [key record "assistant"])
  let terminal := key machine "terminal"
  let vphase := fact machine "vphase"
  let prep ← ask state "output_preparation" (.tuple [vphase, key terminal "outcome"])
  let .tuple [_, preparation] := prep | fail "function_clause"
  let aid := key record "aid"
  let sid ← field state "session_id"
  let unsettled ← runawayUnsettled sid aid (key machine "content") (fact machine "nonce")
  let finished ← ask state "finish_output" (.tuple [key record "leading", key record "assistant", aid,
    vphase, Term.bool terminal.isMap, unsettled])
  let .tuple [_, events, opts, plan] := finished | fail "function_clause"
  let onboarding ← if (plan.get (a "onboarding?")).truthy then
      ask state "onboarding_settlement" (.tuple [list [], events,
        Term.bool ((← truthy ask state "onboarding_authority_required?") && (fact machine "canonical_router").truthy)])
    else pure nil
  let committed := if onboarding.isList then onboarding else events
  let hwm := match opts with | .list [.tuple [_, h]] => h | _ => aid
  let pre := if (wrap preparation).contains (a "draft_clear") then [notify "draft" (a "cancel")] else []
  let machine := (phase machine "output_committed").put (b "output") (.tuple [plan, Term.bool onboarding.isList])
  return result machine (pre ++ [commit (← asList committed) hwm, cont])

private def outputCommitted (ask : Ask) (state machine : Term) : KernelM Term := do
  let .tuple [outcome, effects] ← ask state "output_committed" (key machine "output") | fail "function_clause"
  let reports := (wrap effects).map (fun effect => match effect with
    | .tuple [.atom "report", status] => notify "report" status
    | .tuple [.atom "activity", activity] => notify "activity" activity
    | other => notify "effect" other)
  if outcome == a "completed" then
    return result (phase machine "done") (reports ++ [notify "telemetry" (a "finalize"),
      notify "report" (b "completed"), notify "activity" (a "idle"), stop (a "final")])
  if outcome == a "park" then
    let .tuple [next, parked] ← park ask state machine | fail "function_clause"
    return result next (reports ++ (wrap parked))
  return result (phase machine "done") (reports ++ [stop outcome])

/-! ## Model failure and context overflow -/

private def modelFailure (ask : Ask) (state machine info : Term) (recover : Bool := true) : KernelM Term := do
  let sid ← field state "session_id"
  let hwm := i (ackHwm machine)
  let overflow := key info "category" == b "context_overflow"
  let recovery ← field state "context_overflow_recovery"
  let attempted := recovery.isMap && recovery.get (b "transcript_hwm") == hwm
  if recover && overflow && !attempted then
    let event := Term.map [(b "type", b "session_event"),
      (b "event_id", b s!"context-overflow:{← text sid}:{← text hwm}"),
      (b "kind", b "context_overflow_recovery_requested"), (b "source", b "internal_runtime"),
      (b "created_at", ← seconds),
      (b "event", .map [(b "transcript_hwm", hwm), (b "summary_sequence", ← field state "summary_sequence"),
        (b "compacted_through", ← field state "compacted_through")])]
    return result (phase machine "done")
      [notify "draft" (a "cancel"), commit [event, statusEvent sid "idle"], stop (a "context_overflow")]
  let info ← ask state "llm_retry_metadata" (.tuple [info, hwm])
  let failed := Term.map [(b "type", b "session_event"),
    (b "event_id", b s!"llm-call-failed:{← text sid}:{← text (fact machine "nonce")}"),
    (b "kind", b "llm_call_failed"), (b "source", b "internal_runtime"),
    (b "event", info.put (b "transcript_hwm") hwm), (b "created_at", ← seconds)]
  let events := [failed, statusEvent sid "idle"]
  let projected ← Command.project state events
  let ack ← if ← truthy ask projected "llm_failure_ack?" then
      pure [Term.map [(b "type", b "ack"), (b "session_id", sid), (b "last_ack_message_id", hwm),
        (b "keep_round_budget", a "true")]]
    else pure []
  return result ((phase machine "model_failed").put (b "failure") info)
    [notify "draft" (a "cancel"), commit (events ++ ack) (if integerValue hwm > 0 then hwm else nil), cont]

private def modelFailed (ask : Ask) (state machine : Term) : KernelM Term := do
  let parked ← if ← truthy ask state "llm_failures_exhausted?" then
      pure [notify "llm_parked" (.tuple [← ask state "consecutive_llm_failures" nil, key machine "failure"])]
    else pure []
  return result (phase machine "done") ([notify "report" (b "llm_failed"),
    notify "activity" (a "llm_failed"), notify "activity" (a "idle")] ++ parked ++ [stop (a "final")])

/-! ## Tool turn -/

/-- A tool turn. `outcome` is the model's `end_turn` outcome when the turn
delivers its reply; the record then keeps the model's own calls. -/
private def toolTurn (machine outcome : Term) : KernelM Term := do
  let machine := (phase machine "intent").put (b "decision_outcome") outcome
  return result machine [notify "draft" (.tuple [a "cancel_unless_source_send", key machine "calls"]),
    .tuple [a "build_record", recordSpec machine "tools"
      [(b "decision_outcome", outcome), (b "record_calls", key machine "record_calls")]]]

private def intentRecord (state machine record : Term) : KernelM Term := do
  if !(← fresh state record) then
    return ← toolTurn machine (key machine "decision_outcome")
  let aid := key record "aid"
  let admission := key record "admission"
  let planned := admission.isMap
  let events := (wrap (key record "intent")) ++ (if planned then wrap (key admission "events") else [])
  admitHostEvents events
  -- The intent commits, and only then do the tools execute.
  let machine ← advance machine .start .commitIntent
  let machine ← advance machine .committed .executeTools
  let hwm := if planned then key admission "hwm" else aid
  let calls := key machine "calls"
  let mode := Term.map [(b "speculative", Term.bool (key record "speculative").truthy),
    (b "cancel_draft_on_error", a "true")]
  let progress ← runawayReset (← field state "session_id") aid calls (fact machine "nonce")
  let machine := (((phase machine "tools").put (b "aid") aid).put (b "planned") (Term.bool planned)).put
    (b "progress_event") progress
  return result machine [commit events hwm mode,
    notify "timers" (.tuple [list (if planned then wrap (key admission "events") else []),
      Term.bool (key record "speculative").truthy]),
    notify "telemetry" (a "response_commit"), notify "activity" (.tuple [a "tool_calls_started", calls]),
    .tuple [a "run_tools", calls, .map [(b "mode", b "model_turn"), (b "planned", Term.bool planned),
      (b "aid", aid), (b "progress_event", progress)]]]

private def toolsDone (ask : Ask) (state machine results async : Term) : KernelM Term := do
  let machine ← advance machine .executed .commitResults
  let checkpoint ← ask state "tool_batch_checkpoint" results
  let pending := Term.map [(b "calls", key machine "calls"), (b "aid", key machine "aid"),
    (b "track", a "true"), (b "checkpoint", checkpoint), (b "planned", key machine "planned"),
    (b "progress_event", key machine "progress_event")]
  let machine := (((phase machine "results").put (b "pending") pending).put (b "results") results).put
    (b "async") async
  if (key machine "planned").truthy then
    return result (phase machine "continuation") [.tuple [a "commit_planned_results", pending, results]]
  return result machine [.tuple [a "store_results", pending, results]]

private def resultsStored (ask : Ask) (state machine events hwm base stored : Term) : KernelM Term := do
  if base != (← field state "next_message_id") then
    return result machine [.tuple [a "store_results", key machine "pending", key machine "results"]]
  admitHostEvents (wrap events)
  let pending := key machine "pending"
  let sid ← field state "session_id"
  let aid := key pending "aid"
  let nonce := fact machine "nonce"
  let settled ← ask state "settle_tool_batch" (.tuple [events, stored, key pending "track",
    ← runawayUnsettled sid aid (b "") nonce, ← runawayReset sid aid (key pending "calls") nonce,
    Term.bool ((← truthy ask state "onboarding_authority_required?") && (fact machine "canonical_router").truthy)])
  let committed ← asList settled
  if key machine "phase" == b "results_only" then
    return result (phase machine "done")
      [commit committed hwm, notify "timers" (.tuple [settled, a "false"]), stop (a "committed")]
  let machine := (phase machine (if key machine "phase" == b "notice_results" then "notice_committed" else "continuation")).put
    (b "settled") (Term.bool (Settlement.settled committed))
  return result machine [commit committed hwm, notify "timers" (.tuple [settled, a "false"]), cont]

private def waitSet (results : Term) : Bool :=
  (wrap results).any (fun r =>
    let events := if r.has (a "events") then r.get (a "events") else r.get (b "events")
    (wrap events).any (fun e => e.get (b "type") == b "wait_set" || e.get (a "type") == b "wait_set"))

private def continuation (ask : Ask) (state machine : Term) : KernelM Term := do
  let pending := key machine "pending"
  let results := key machine "results"
  let async := (key machine "async").truthy
  let parked := ((key pending "track").truthy && (← truthy ask state "runaway_unsettled_rounds_exhausted?")) ||
    (← truthy ask state "repeated_tool_results_exhausted?") || (← truthy ask state "input_round_budget_exhausted?")
  let parked := parked && !(key pending "planned").truthy
  let settled := (key machine "settled").truthy && !(key pending "planned").truthy
  let committedNotices := (if async then [] else [notify "draft" (a "cancel")]) ++
    [notify "observations" results, notify "telemetry" (a "tool_commit")]
  let machine ← advance machine .committed .continue
  let decision ← ask state "tool_continuation" (.tuple [Term.bool parked, Term.bool settled, Term.bool async,
    Term.bool (waitSet results), results, key pending "checkpoint"])
  let done := phase machine "done"
  if decision == a "park" then
    let .tuple [next, parkEffects] ← park ask state machine | fail "function_clause"
    return result next (committedNotices ++ wrap parkEffects)
  if decision == a "terminal_reply" || decision == a "contained_failure" then
    return result done (committedNotices ++ [notify "activity" (a "idle_unscoped"), stop (a "final")])
  if decision == a "repair_exhausted" then
    return result done (committedNotices ++
      [notify "activity" (a "llm_failed"), notify "activity" (a "idle"), stop (a "final")])
  if decision == a "async_pause" then
    if waitSet results then return result done (committedNotices ++ [stop (a "async_tools_started")])
    return result (phase machine "async_boundary") (committedNotices ++ [cont])
  if decision == a "wait" then return result done (committedNotices ++ [stop (a "final")])
  return result (phase machine "boundary_after_tools") (committedNotices ++ [cont])

/-! ## Activation

`{:activate, facts}` decides what a processing entry does with a session that
runs no round: check the Router fact, yield a provider wait to queued input,
extend or deliver an expired wait, arm a wait or retry timer, or hand the
queued input to the activation commit. `{:wait_timeout, wait_id, source,
facts}` decides a fired wait timer the same way. `facts` carries the wait
extension `ceiling_ms`.

The host answers `{:fact, name}` with `{:fact, value}`, applies `{:write,
events}` to its working revision and answers `continue`, and runs
`{:materialize, mode}` as the step's last effect. -/

private def fetch (name : Term) : Term := .tuple [a "fact", name]
private def setTimer (kind : String) (data : Term := nil) : Term := .tuple [a "set_timer", a kind, data]
private def materialize (mode : String) : Term := .tuple [a "materialize", a mode]

private def waitSetEvent (state wait : Term) : KernelM Term := do
  return .map [(b "type", b "wait_set"), (b "session_id", ← field state "session_id"), (b "wait", wait)]

/-- Extend the expired wait while its delegate is busy, else deliver it. A
changed wait re-enters the decision from the fresh session. -/
private def expire (state machine busy : Term) : KernelM Term := do
  let wait ← field state "wait"
  let timer := key machine "entry" == b "wait_timeout"
  let entry := phase machine (if timer then "timeout" else "activation")
  if wait != key machine "expected" then return result entry [cont]
  let now ← observe (a "time")
  match VerifiedKernel.AgentLoop.WaitExtension.decide wait busy now (fact machine "ceiling_ms") with
  | .tuple [.atom "extend", next] =>
    let event ← waitSetEvent state next
    if timer then
      return result (phase machine "done") [commit [event], setTimer "wait_for" next,
        notify "wait_extended" (.tuple [next, b "timer"]), stop (a "ignored")]
    return result entry [commit [event], notify "wait_extended" (.tuple [next, b "recovery"]), cont]
  | _ =>
    if timer then return result (phase machine "done") [commit [key machine "timeout_event"], stop (a "committed")]
    return result (phase machine "done") [materialize "expire"]

private def expireEntry (state machine : Term) : KernelM Term := do
  let wait ← field state "wait"
  let machine := machine.put (b "expected") wait
  if wait.isMap && wait.get (b "source") == b "wait_for" then
    return result (phase machine "busy") [fetch (.tuple [a "delegates_busy", wait])]
  expire state machine (a "false")

private def activation (ask : Ask) (state machine : Term) : KernelM Term := do
  let machine := phase machine "activation"
  let done := phase machine "done"
  match ← ask state "activation_next" (key machine "router") with
  | .atom "check_router" => return result (phase machine "router") [fetch (a "canonical_router")]
  | .atom "yield" =>
    let expected := Term.map [(b "wait_identity", ← ask state "wait_identity" nil),
      (b "next_message_id", ← field state "next_message_id"),
      (b "last_ack_message_id", ← field state "last_ack_message_id"),
      (b "active_human_source_ids", ← ask state "active_human_source_ids" nil)]
    let events ← asList (← ask state "provider_wait_yield_events" expected)
    if events.isEmpty then fail "provider_wait_not_yieldable"
    return result machine [.tuple [a "write", list events], cont]
  | .atom "expire" => expireEntry state machine
  | .atom "materialize" => return result done [materialize "until_wake"]
  | .atom "wait" => return result done [setTimer "wait", stop (a "wait")]
  | .tuple [.atom "retry", retryAt] => return result done [setTimer "retry" retryAt, stop (a "wait")]
  | .atom "resume" => return result done [.tuple [a "cancel_timer", a "retry"], materialize "run"]
  | .atom "run" => return result done [materialize "run"]
  | .atom "idle" => return result done [stop (a "idle")]
  | .tuple [.atom "error", reason] => return result done [stop (.tuple [a "error", reason])]
  | other => fail "function_clause" [other]

private def timeoutEntry (ask : Ask) (state machine : Term) : KernelM Term := do
  let event ← ask state "wait_timeout_event" (.tuple [key machine "wait_id", key machine "source"])
  if event == nil then return result (phase machine "done") [stop (a "ignored")]
  expireEntry state (machine.put (b "timeout_event") event)

/-! ## Entry -/

private def classify (ask : Ask) (state machine : Term) : KernelM Term := do
  let response := key machine "response"
  let .tuple [kind, content, calls, pmeta, tmeta] := parts response | fail "function_clause"
  let terminalCall := VerifiedKernel.AgentLoop.TurnOutcome.classify calls
  let terminal? := match terminalCall with | .tuple [.atom "settle", _] => true | _ => false
  let plan ← ask state "prepare_response" (.tuple [(if kind == a "error" then a "other" else kind), calls,
    Term.bool terminal?, fact machine "source_ids", fact machine "restricted"])
  let (kind, content, calls, replaced) := match plan with
    | .tuple [.atom "replace_calls", replacement] => (a "assistant", b "", replacement, true)
    | _ => (kind, content, calls, false)
  let machine := ((((machine.put (b "content") content).put (b "calls") calls).put (b "provider_meta") pmeta).put
    (b "trace_meta") tmeta).put (b "replaced_calls") (Term.bool replaced)
  if kind == a "error" then return ← modelFailure ask state machine content
  if kind == a "final" then return ← finalize ask state machine nil
  if kind != a "assistant" then fail "function_clause"
  match VerifiedKernel.AgentLoop.TurnOutcome.classify calls with
  | .tuple [.atom "settle", decision] =>
    let callsList := wrap calls
    let call := callsList.headD nil
    let reply := decision.get (a "reply")
    if reply.isMap then
      -- History keeps the model's decision; only dispatch unwraps its reply.
      let replyCall := Term.map [(a "id", valueOf call "id"), (a "name", b "call"), (a "args", reply)]
      toolTurn ((machine.put (b "calls") (list [replyCall])).put (b "record_calls") calls)
        (decision.get (a "outcome"))
    else
      finalize ask state machine (.map [(b "call", call), (b "outcome", decision.get (a "outcome"))])
  | _ =>
    if (wrap calls).isEmpty then finalize ask state machine nil else toolTurn machine nil

/-- One transition for the query oracle `ask`. `machine` is `nil` before the
first event. -/
def stepWith (ask : Ask) (state args : Term) : KernelM Term := do
  let .tuple [machine, event] := args | fail "function_clause"
  let sid ← field state "session_id"
  match event with
  | .tuple [.atom "model_response", response, round] =>
    let machine := (Term.map [(b "round", round), (b "response", response)])
    let stale ← truthy ask state "response_stale?" (.tuple [key round "id_snapshot", key round "guard"])
    if stale then
      return result (phase machine "boundary")
        [notify "steered" (kindOf response), notify "meter" (b "stale"), notify "draft" (a "cancel"), cont]
    return result (phase machine "classify") [notify "meter" (b "ok"), cont]
  | .tuple [.atom "guard_notice", round] =>
    let machine := phase (Term.map [(b "round", round.put (b "entry") (b "guard_notice"))]) "guard_notice"
    guardNotice ask state machine
  | .tuple [.atom "model_failure", info, round] =>
    modelFailure ask state (phase (Term.map [(b "round", round)]) "classify") info false
  | .tuple [.atom "commit_results", pending, results, round] =>
    let machine := (((phase (Term.map [(b "round", round)]) "results_only").put (b "pending") pending).put
      (b "results") results)
    return result machine [.tuple [a "store_results", pending, results]]
  | .tuple [.atom "record", record] =>
    let current := key machine "phase"
    if current == b "final_record" then finalRecord ask state machine record
    else if current == b "intent" then intentRecord state machine record
    else fail "loop_order" [current]
  | .tuple [.atom "tools_done", results, async] =>
    let current := key machine "phase"
    if current == b "tools" then toolsDone ask state machine results async
    else if current == b "notice_results" then
      return result (machine.put (b "results") results |>.put (b "async") async)
        [.tuple [a "store_results", key machine "pending", results]]
    else fail "loop_order" [current]
  | .tuple [.atom "results_stored", events, hwm, base, stored] =>
    let current := key machine "phase"
    if current == b "results" || current == b "results_only" || current == b "notice_results" then
      resultsStored ask state machine events hwm base stored
    else fail "loop_order" [current]
  | .tuple [.atom "activate", facts] =>
    activation ask state (Term.map [(b "round", facts), (b "entry", b "activation")])
  | .tuple [.atom "wait_timeout", waitId, source, facts] =>
    timeoutEntry ask state (Term.map [(b "round", facts), (b "entry", b "wait_timeout"),
      (b "wait_id", waitId), (b "source", source)])
  | .tuple [.atom "fact", value] =>
    let current := key machine "phase"
    if current == b "router" then activation ask state (machine.put (b "router") value)
    else if current == b "busy" then expire state machine value
    else fail "loop_order" [current]
  | .atom "continue" =>
    let current := key machine "phase"
    if current == b "classify" then classify ask state machine
    else if current == b "activation" then activation ask state machine
    else if current == b "timeout" then timeoutEntry ask state machine
    else if current == b "boundary" then
      return result (phase machine "done") [commit [statusEvent sid "idle"], stop (a "round_boundary")]
    else if current == b "output_committed" then outputCommitted ask state machine
    else if current == b "model_failed" then modelFailed ask state machine
    else if current == b "guard_notice" then guardNotice ask state machine
    else if current == b "notice_cleanup" then noticeCleanup ask state machine
    else if current == b "notice_committed" then
      if (key machine "async").truthy then
        return result (phase machine "done")
          [notify "observations" (key machine "results"), stop (a "async_tools_started")]
      let (stopped, stopEffects) := finalStop machine
      return result stopped (notify "observations" (key machine "results") :: stopEffects)
    else if current == b "guard_outcome" then guardOutcome ask state machine
    else if current == b "continuation" then continuation ask state machine
    else if current == b "async_boundary" then
      return result (phase machine "done") [commit [statusEvent sid "idle"], stop (a "async_tools_started")]
    else if current == b "boundary_after_tools" then
      return result (phase machine "done")
        [commit [statusEvent sid "idle"], notify "telemetry" (a "boundary"), stop (a "round_boundary")]
    else fail "loop_order" [current]
  | _ => fail "function_clause"

/-- One transition against the kernel's query table. -/
def step (state args : Term) : KernelM Term := stepWith queryAsk state args

def table : OpTable := [("loop_step", step)]

end VerifiedKernel.Session.Loop
