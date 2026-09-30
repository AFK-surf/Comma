import VerifiedKernel.Session.Loop
import VerifiedKernel.ETF

/-! # Session driver

`session_step {machine, event, host}` sequences one session for its host. It
decides every step between the host's I/O: recovery and crash repair, the
activation decision, materialization, the activate command, compaction, model
rounds, and the agent loop (`loop_step`). Each step returns one effect; the
host performs it and answers with `{:done, value}`. A `nil` machine is an
idle session.

Host events:

- `{:process, entry}`: process the session. `entry` holds the tool call ids
  that live processes own (`live`) and the recovery checkpoint
  (`checkpoint`).
- `{:process_fast, entry}`: the same after the host committed async work. A
  session without repair events activates on the fast path.
- `:activate_fast`: activate an admitted conversation on the fast path.
- `{:round_run, kind}`: one round that the host starts directly: `:normal`,
  `:prepared`, or `:speculative` for an activation whose fence the host
  already started. A pending runtime failure notice turns a normal or
  prepared round into a `:guard` round.
- `{:compact, mode, facts, continuation}`: an explicit compaction.
- `{:loop, machine, event}`: one loop run that ends with the host.
- `{:model, response}`: a model call answered. `{:model_lost, facts}`: it
  ended without a response; `facts` holds the failure's `detail` and the
  input queue position when the call started (`queue_snapshot`).
- `:rebuild`: the last commit met a newer revision.

Effects the host answers:

- Revision I/O: `{:commit, events, opts, mode}`, `{:write, events}`, `:fence`,
  `{:plan, mode}` (answered with `{outcome, changed}`), and
  `{:command, name, args}`. A commit whose mode says `"fresh" => true`
  applies to the session as stored now. A commit is rebuilt unless its mode
  says `"rebuild" => false`: when it meets a newer revision, the host sends
  `:rebuild` against that revision, and the answer is the rebuilt commit or
  the effects of the branch that the step took instead.
- Recovery: `:recover` (answered with the recovery command's result) and
  `{:apply_recovery, recovery}`.
- Activation: `:round_config` (answered with `{:ok, %{"prompt", "compaction"}}`),
  `{:speculate, args}` (answered with `:started`, `:sequential`, or an
  error), and `:await_fence` (join the activation's fence, then open the
  gate of a model call that started beside it).
- Rounds: `:refresh` (read the session again), `{:round_prepare, kind}`
  (answered with the round configuration), `{:round, facts}` (answered with
  `:ok` or an error), `{:round_abandon, reason}` (release a prepared round
  whose request failed), `{:call_model, request, facts}` (answered with
  `:started` or an error), `{:round_outcome, outcome}`, and
  `{:call_failed, committed}` after the events of a lost or unstarted call
  were committed or not. An error `{:unstarted, detail}` from a
  refresh, a round preparation, or a model call records a call that never
  started.
- Compaction: `{:compaction_facts, mode}`, `:compaction_config`,
  `{:compaction_prompt, plan}`, `{:summarize, plan, prompt}` (answered with
  `:started`; the outcome follows as `{:done, outcome}`), and
  `{:compacted, result, continuation}`.
- Loop: `{:notify, kind, data}`, `{:set_timer, kind, data}`,
  `{:cancel_timer, kind}`, `{:fact, request}`, and the loop data effects
  `{:build_record, spec}`, `{:run_tools, calls, flags}`,
  `{:store_results, pending, results}`, and `{:commit_planned_results,
  pending, results}`. The host answers these with the next loop event, built
  with the `LoopHost` queries and its own context.

Effects that end the step: `:idle`, `:await` (a model call or compaction
runs), `:reprocess` (process again later), `{:apply_recovery, recovery}` for
a recovery that does not continue, `{:loop_end, outcome}`,
`{:fast_end, outcome}`, `{:recovery_failure, stage, reason}`,
`{:round_failure, reason}`, and `{:activation_error, reason}`. A step that
ends returns an idle machine (`"phase" => "idle"`), except `:await`: its
machine waits for the dependency, and the host sends the dependency's answer
to that machine.

The host holds the large values of a round between steps: the loop state
(`"loop"`) and the input of the last loop step that emitted a commit
(`"loop_in"`). They hold the model response and the tool results, so they do
not cross the boundary on each step. A step returns the held values it
changed in the machine's `"held"` map and reads the others with `{:held,
key}`, answered with the value's external term format. The host merges `"held"` into the values it holds, sends the machine
without them, and drops them when the machine is idle.

The query reader answers `{:held, key}`, `:clock`, `:nonce`, the repair reads of
`guard_recovery` and `capability_observation`, `{:restart, request,
guard_events}` for the restart requests that only the host can encode (over
the session with the guard events applied), `{:capability_unknown, id,
reason}`, and the request reads of `round_request`.

The driver runs only data transitions. The loop's proofs cover `loop_step`;
no theorem covers this driver. -/

namespace VerifiedKernel.Session.Drive
open Data

private def ask (state : Term) (name : String) (args : Term := nil) : KernelM Term :=
  Loop.queryAsk state name args

private def get (m : Term) (k : String) : Term := if m.isMap then m.get (b k) else nil

private def set (m : Term) (pairs : List (String × Term)) : Term :=
  pairs.foldl (fun acc pair => acc.put (b pair.1) pair.2) m

private def idleMachine : Term := .map [(b "phase", b "idle")]

/-- A held value: changed in this step, or read from the host. The host
answers with the value's external term format, because a held value can
carry host data, such as tool timing, that an observation cannot. -/
private def held (machine : Term) (key : String) : KernelM Term := do
  let changed := get machine "held"
  if changed.has (b key) then return changed.get (b key)
  let .binary bytes ← observe (.tuple [a "held", b key]) | fail "invalid_held"
  match ETF.decode bytes with
  | .ok value => return value
  | .error reason => fail "invalid_held" [b reason]

/-- Changes held values. -/
private def hold (machine : Term) (pairs : List (String × Term)) : Term :=
  set machine [("held", set (get machine "held") pairs)]

/-- One transition: emit an effect, or continue with an instruction. -/
inductive Step where
  | emit (machine effect : Term)
  | next (machine instr : Term)

private def emitIn (machine : Term) (phase : String) (effect : Term) : Step :=
  .emit (set machine [("phase", b phase)]) effect

/-- An effect that ends the step: the machine is idle again. -/
private def finish (effect : Term) : Step := .emit idleMachine effect

private def isOk (value : Term) : Bool :=
  match value with
  | .atom "ok" => true
  | .tuple (.atom "ok" :: _) => true
  | _ => false

private def errorReason (value : Term) : Term :=
  match value with
  | .tuple [.atom "error", reason] => reason
  | other => other

/-- A commit that the host must not rebuild. -/
private def plainCommit (events : Term) (mode : List (Term × Term) := []) : Term :=
  .tuple [a "commit", events, list [], .map ((b "rebuild", a "false") :: mode)]

/-- A materialization error: the activation failed before its model call. -/
private def materializationError (reason : Term) : Term :=
  .tuple [a "visible_reply_pre_llm_error", a "activation_materialization", reason]

/-! ## Crash repair -/

/-- One restart-plan request. The kernel classifies capability requests and
encodes missing and external-callback results. The host answers the rest
over the session with the guard events applied, so it sends them too. -/
private def restartAnswer (state guard request : Term) : KernelM Term := do
  match request with
  | .tuple [.binary name, record] =>
    if name == "capability".toUTF8 then
      let .tuple [observation, reason] ← ask state "capability_observation" record | fail "invalid_observation"
      if reason != nil then
        let _ ← observe (.tuple [a "capability_unknown",
          (record.get (b "tool_call_id")).default (record.get (a "tool_call_id")), reason])
      return observation
    if name == "encode_missing".toUTF8 || name == "encode_external".toUTF8 then
      return ← ask state "restart_encode" request
    observe (.tuple [a "restart", request, guard])
  | _ => fail "invalid_restart_request"

/-- The repair of a crash: the runtime failure reply's settlement, then the
restart plan over the session with those events applied. `{:ok, events,
next_message_id}`, or `{:error, reason}` when a staged result could not be
read. -/
private def repairEvents (state entry : Term) : KernelM Term := do
  let live := (get entry "live").default (list [])
  let disposition ← ask state "recovery_policy" (.tuple [a "disposition", get entry "checkpoint"])
  let guard ← asList ((← ask state "guard_recovery" live).default (list []))
  let recovered ← Command.project state guard
  let mut plan ← ask recovered "restart_plan" (.tuple [live, disposition])
  for _ in [0:4096] do
    match plan with
    | .tuple [.atom "return", .tuple [.list events, next]] => return .tuple [a "ok", list (guard ++ events), next]
    | .tuple [.atom "return", result] => return .tuple [a "error", errorReason result]
    | .tuple [.atom "perform", request, continuation] =>
      plan ← ask recovered "resume_restart" (.tuple [continuation, ← restartAnswer recovered (list guard) request])
    | _ => fail "invalid_restart_plan"
  fail "restart_plan_fuel"

/-- The recovery observed on this state, from the host's checkpoint. -/
private def observeRecovery (state machine : Term) : KernelM Term :=
  ask state "reconcile" (get (get machine "entry") "checkpoint")

private def continues (recovery : Term) : Bool :=
  (recovery.get (a "action")).default (recovery.get (b "action")) == a "continue"

/-! ## Loop effects -/

/-- The first commit of a loop step: `(commit, effects after it)`. -/
private def splitCommit : List Term → Option (Term × List Term)
  | [] => none
  | effect :: rest => match effect with
    | .tuple [.atom "commit", _, _, _] => some (effect, rest)
    | _ => splitCommit rest

/-- The next loop effect. The host performs I/O effects and answers facts
and loop data with the next loop event. `materialize` and `stop` end the
loop run. -/
private def drain (machine : Term) : KernelM Step := do
  match get machine "pending" with
  | .list (effect :: rest) =>
    let machine := set machine [("pending", list rest)]
    match effect with
    | .atom "continue" => return .next machine (.tuple [a "loop", a "continue"])
    | .tuple [.atom "notify", _, _] | .tuple [.atom "commit", _, _, _] | .tuple [.atom "write", _]
    | .tuple [.atom "set_timer", _, _] | .tuple [.atom "cancel_timer", _] =>
      return emitIn (set machine [("rebuild", a "loop")]) "loop_io" effect
    | .tuple [.atom "fact", _] => return emitIn machine "loop_answer" effect
    | .tuple [.atom "build_record", _] | .tuple [.atom "run_tools", _, _]
    | .tuple [.atom "store_results", _, _] | .tuple [.atom "commit_planned_results", _, _] =>
      return emitIn machine "loop_data" effect
    | .tuple [.atom "materialize", _] | .tuple [.atom "stop", _] =>
      return .next machine (.tuple [a "loop_end", effect])
    | _ => fail "unsupported_loop_effect" [effect]
  | _ => fail "loop_ended_without_outcome"

/-- One `loop_step`. The input of a step that commits stays held, so a
commit that meets a newer revision rebuilds from it. -/
private def loopStep (state machine event : Term) : KernelM Step := do
  let input := .tuple [← held machine "loop", event]
  let .tuple [next, effects] ← Loop.step state input | fail "invalid_loop_step"
  let rebuildable := (splitCommit (← asList effects)).isSome
  let machine := hold machine [("loop", next), ("loop_in", if rebuildable then input else nil)]
  return .next (set machine [("pending", effects)]) (a "drain")

/-- A fresh loop run from `event`. `after` names what its end means:
`return` hands it to the host, `activation` settles the activation, and
`round` reports the round's outcome. -/
private def freshLoop (machine : Term) (after : String) (event : Term) : Step :=
  .next (hold (set machine [("after", b after)]) [("loop", nil)]) (.tuple [a "loop", event])

/-- A loop run of one round: the host first learns the round's facts
(`{:round, facts}`), which its record and tool answers use. -/
private def roundLoop (machine facts event : Term) : Step :=
  emitIn (hold (set machine [("after", b "round"), ("response", nil), ("start", event)]) [("loop", nil)])
    "round_io"
    (.tuple [a "round", facts])

/-! ## Lost model calls -/

/-- The events of a model call that ended without a response: the session
idles and records the failure, at the request's transcript position when the
call started (`snapshot`). A failure notice that already reported its
outcome is acknowledged; a model failure keeps the round budget. -/
private def lostEvents (state detail snapshot : Term) : KernelM Term := do
  let sid ← field state "session_id"
  let .binary sidText := sid | fail "badarg"
  let nonce := integerValue (← observe (a "nonce"))
  let now := i (integerValue (← observe (a "time")) / 1000)
  let event := Term.map [(b "reason", b "llm_task_failed"), (b "detail", detail)]
  let started := snapshot.isInteger && integerValue snapshot > 0
  let event := if started then event.put (b "transcript_hwm") (i (integerValue snapshot - 1)) else event
  let eventId := "llm-call-failed:".toUTF8 ++ sidText ++ s!":{nonce}".toUTF8
  let events := [Term.map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")],
    .map [(b "type", b "session_event"), (b "event_id", .binary eventId), (b "kind", b "llm_call_failed"),
      (b "source", b "internal_runtime"), (b "event", event), (b "created_at", now)]]
  if !started then return list events
  let failed ← Command.project state events
  let notified ← field failed "runtime_failure_reply"
  let ack ← if notified.isMap && (notified.get (b "notification_outcome")).isBinary &&
      (← ask failed "llm_failure_ack?").truthy then
      pure [Term.map [(b "type", b "ack"), (b "session_id", sid),
        (b "last_ack_message_id", i (integerValue snapshot - 1)), (b "keep_round_budget", a "true")]]
    else pure []
  return list (events ++ ack)

/-- After a lost call: process again when input arrived during the call or a
failure notice waits; otherwise the session stays idle, so the same
transcript is not requested again at once. -/
private def afterLost (state machine : Term) : KernelM Step := do
  let snapshot := get (get machine "facts") "id_snapshot"
  let queued := get machine "queue_snapshot"
  let next ← field state "next_message_id"
  let queue ← field state "next_queue_id"
  let transcript := snapshot.isInteger && next.isInteger && integerValue next > integerValue snapshot
  let arrived := queued.isInteger && queue.isInteger && integerValue queue > integerValue queued
  if transcript || arrived || (← ask state "guard_disposition_pending?").truthy then return finish (a "reprocess")
  return finish (a "idle")

/-! ## Rebuilt commits -/

private def compactionError (answer : Term) : Term :=
  match answer with
  | .tuple [.atom "stale_compaction_view", expected, actual] =>
    .tuple [a "stale_compaction_view", .map [(a "expected", expected), (a "actual", actual)]]
  | .tuple [.atom "error", reason] => reason
  | other => other

/-- The pending commit, built on this revision: the loop step again, or the
compaction commit checked against the summarized view. -/
private def rebuild (state machine : Term) : KernelM Step := do
  match get machine "rebuild" with
  | .atom "loop" =>
    let .tuple [next, effects] ← Loop.step state (← held machine "loop_in") | fail "invalid_loop_step"
    let effects ← asList effects
    let machine := hold machine [("loop", next)]
    match splitCommit effects with
    | some (commit, post) => return emitIn (set machine [("pending", list post)]) "loop_io" commit
    | none => return .next (set machine [("pending", list effects)]) (a "drain")
  | .tuple [.atom "compaction_commit", plan, outcome, prompt] =>
    match ← ask state "compaction_commit" (.tuple [plan, outcome, prompt]) with
    | .tuple [.atom "ok", events, result, archive] =>
      return emitIn (set machine [("result", result)]) "compaction_commit"
        (.tuple [a "commit", events, list [], .map [(b "archive", archive)]])
    | other => return .next machine (.tuple [a "compacted", .tuple [a "error", compactionError other]])
  | .atom "lost" =>
    let events ← lostEvents state (get machine "detail") (get (get machine "facts") "id_snapshot")
    return emitIn machine "lost_commit" (.tuple [a "commit", events, list [], .map [(b "lost", a "true")]])
  | other => fail "not_rebuildable" [other]

/-! ## Activation -/

/-- The end of a materialization that runs no round: fence the working
revision, which also holds any earlier yield writes. A clean revision needs
no storage write. -/
private def settle (machine outcome : Term) : Step :=
  emitIn (set machine [("outcome", outcome)]) "settle" (a "fence")

/-- An activation error: the full path recovers, the fast path hands the
error to its entry. -/
private def activationFailure (machine reason : Term) : Step :=
  if get machine "entry_kind" == b "full" then
    finish (.tuple [a "recovery_failure", a "activation_read", reason])
  else finish (.tuple [a "activation_error", reason])

/-! ## Rounds -/

/-- The round configuration's facts for a loop entry outside a request. -/
private def configFacts (state config snapshot : Term) : KernelM Term := do
  let config := config.put (b "nonce") (← observe (a "nonce"))
  ask state "round_facts" (.tuple [config, snapshot, nil])

/-- A prepared round whose request failed: the host releases what it
prepared, then the round fails. -/
private def abandon (machine reason : Term) : Step :=
  emitIn (set machine [("reason", reason)]) "abandon" (.tuple [a "round_abandon", reason])

/-- A failed round. The failure round after an overflow recovery belongs to
that recovery, so it fails as the compaction. -/
private def roundFailure (machine reason : Term) : Step :=
  if get machine "fail_as" == b "compaction" then
    finish (.tuple [a "recovery_failure", a "compaction", reason])
  else finish (.tuple [a "round_failure", reason])

/-- A round's outcome, after the host reported it. -/
private def afterOutcome (machine outcome : Term) : Step :=
  match outcome with
  | .atom "context_overflow" => .next machine (a "compact_round")
  | .atom "async_tools_started" | .atom "guard_failure_parked" => finish (a "idle")
  | .tuple [.atom "error", reason] => roundFailure machine reason
  | _ => finish (a "reprocess")

/-! ## Compaction -/

private def commitThen (machine events result : Term) : Step :=
  if (wrap events).isEmpty then .next machine (.tuple [a "compacted", .tuple [a "ok", result]])
  else emitIn (set machine [("result", result)]) "compaction_commit" (plainCommit events)

private def prepared (machine answer : Term) : KernelM Step := do
  match answer with
  | .tuple [.atom "done", result, events] => return commitThen machine events result
  | .tuple [.atom "fail", plan, reason] =>
    return .next machine (.tuple [a "finish", plan, .tuple [a "error", reason]])
  | .tuple [.atom "summarize", plan] =>
    return emitIn (set machine [("plan", plan)]) "compaction_prompt" (.tuple [a "compaction_prompt", plan])
  | other => fail "invalid_compaction_prepare" [other]

private def finishCompaction (state machine plan raw : Term) : KernelM Step := do
  match ← ask state "compaction_outcome" (.tuple [plan, raw]) with
  | .tuple [.atom "result", result, events] => return commitThen machine events result
  | .tuple [.atom "commit", outcome] =>
    let machine := set machine [("rebuild", .tuple [a "compaction_commit", plan, outcome, get machine "refreshed"])]
    rebuild state machine
  | other => fail "invalid_compaction_outcome" [other]

private def staleView (result : Term) : Bool :=
  match result with
  | .tuple [.atom "error", .tuple [.atom tag, _]] => tag == "stale_compaction_view" || tag == "stale_compaction_snapshot"
  | _ => false

/-- A compaction result, after the host reported it to its continuation. -/
private def afterCompaction (state machine : Term) : KernelM Step := do
  let cont := get machine "cont"
  let result := get machine "result"
  if cont == a "reply" then return finish (a "idle")
  if cont == a "control" then
    if isOk result then return finish (a "reprocess")
    return finish (.tuple [a "recovery_failure", a "compaction", errorReason result])
  if !isOk result then
    if staleView result then
      return if cont == a "recover_overflow" then finish (a "reprocess")
        else .next machine (.tuple [a "round", a "fresh"])
    return finish (.tuple [a "recovery_failure", a "compaction", errorReason result])
  -- After an overflow, a compaction that did not make the request fit ends
  -- the request with the context-overflow failure.
  if cont == a "recover_overflow" && (← ask state "context_overflow_pending?").truthy then
    let reason := match result with
      | .tuple [.atom "ok", r] => (r.get (b "reason")).default (b "no compaction progress")
      | _ => b "no compaction progress"
    return emitIn (set machine [("reason", reason), ("fail_as", b "compaction")]) "failure_config"
      (.tuple [a "round_prepare", a "failure"])
  return .next machine (.tuple [a "round", a "normal"])

/-! ## Instructions -/

private def run (state machine instr : Term) : KernelM Step := do
  match instr with
  -- Recovery, then crash repair.
  | .atom "process" =>
    return emitIn (set machine [("entry_kind", b "full")]) "recover" (a "recover")
  | .atom "repair" =>
    match ← repairEvents state (get machine "entry") with
    | .tuple [.atom "ok", .list [], _] =>
      let recovery ← observeRecovery state machine
      return emitIn (set machine [("recovery", recovery)]) "repaired" (.tuple [a "apply_recovery", recovery])
    | .tuple [.atom "ok", events, _] =>
      return emitIn machine "repair_commit" (plainCommit events [(b "timers", a "true")])
    | .tuple [.atom "error", reason] => return finish (.tuple [a "recovery_failure", a "repair_read", reason])
    | other => fail "invalid_repair" [other]
  | .atom "process_fast" =>
    match ← repairEvents state (get machine "entry") with
    | .tuple [.atom "ok", .list [], _] => return .next (set machine [("entry_kind", b "fast")]) (a "fast_activation")
    | .tuple [.atom "ok", _, _] => return .next machine (a "process")
    | .tuple [.atom "error", reason] => return finish (.tuple [a "recovery_failure", a "repair_read", reason])
    | other => fail "invalid_repair" [other]
  -- The activation decision.
  | .atom "prepare_activation" =>
    -- Only a pending guard disposition asks for the input materialization.
    if (← ask state "guard_disposition_pending?").truthy then
      if (← ask state "materialize_pending_input_events" (i 100)) == .tuple [list [], a "false", i 0] then
        return .next machine (.tuple [a "round", a "guard"])
    let facts ← ask state "activation_facts"
    return freshLoop machine "activation" (.tuple [a "activate", facts])
  | .atom "fast_activation" =>
    if (← ask state "guard_disposition_pending?").truthy then return .next machine (a "fast_fallback")
    return emitIn machine "plan" (.tuple [a "plan", a "fast"])
  | .atom "fast_fallback" =>
    if get machine "entry_kind" == b "fast" then return .next machine (a "process")
    return finish (.tuple [a "fast_end", a "fallback"])
  | .tuple [.atom "loop", event] => loopStep state machine event
  | .atom "drain" => drain machine
  | .tuple [.atom "loop_end", outcome] =>
    let after := get machine "after"
    if after == b "return" then return finish (.tuple [a "loop_end", outcome])
    match outcome with
    | .tuple [.atom "materialize", mode] => return emitIn machine "plan" (.tuple [a "plan", mode])
    | .tuple [.atom "stop", result] =>
      if after == b "round" then
        return emitIn (set machine [("outcome", result)]) "round_outcome" (.tuple [a "round_outcome", result])
      match result with
      | .atom "idle" | .atom "wait" => return emitIn (set machine [("outcome", result)]) "settle" (a "fence")
      | .tuple [.atom "error", reason] => return activationFailure machine reason
      | _ => fail "invalid_loop_outcome" [result]
    | _ => fail "invalid_loop_outcome" [outcome]
  | .atom "rebuild" => rebuild state machine
  | .tuple [.atom "planned", .tuple [outcome, changed]] =>
    let machine := set machine [("changed", changed)]
    match outcome with
    | .atom "run" => return emitIn machine "round_config" (a "round_config")
    | .atom "wait" => return emitIn (set machine [("outcome", outcome)]) "plan_wait" (.tuple [a "set_timer", a "wait", nil])
    | .atom "fallback" => return .next machine (a "fast_fallback")
    | .atom "idle" | .atom "continue" =>
      if get machine "entry_kind" == b "full" then return settle machine outcome
      return finish (.tuple [a "fast_end", outcome])
    | _ => fail "invalid_plan_outcome" [outcome]
  | .tuple [.atom "configured", config] =>
    let plan ← ask state "activation_plan" (.tuple [get config "prompt", get config "compaction"])
    let machine := set machine [("args", get plan "args")]
    if (get plan "compact").truthy then
      if get machine "entry_kind" != b "full" then return .next machine (a "fast_fallback")
      return emitIn machine "fallback_fence" (a "fence")
    if (get plan "sequential").truthy then
      return emitIn machine "activate" (.tuple [a "command", a "activate", get plan "args"])
    return emitIn machine "speculate" (.tuple [a "speculate", get plan "args"])
  | .atom "fallback_activate" =>
    return emitIn machine "fallback_activate"
      (.tuple [a "command", a "activate", .tuple [list [], i 0, nil, a "false"]])
  -- Rounds.
  | .tuple [.atom "round", kind] =>
    -- A round after a lost compaction race reads the winner's session first.
    if kind == a "fresh" then return emitIn machine "refresh" (a "refresh")
    -- A pending runtime failure notice takes the round.
    let guardable := kind == a "normal" || kind == a "prepared"
    let kind ← if guardable then
        (do if (← ask state "guard_disposition_pending?").truthy then pure (a "guard") else pure kind)
      else pure kind
    return emitIn (set machine [("kind", kind), ("fail_as", nil), ("args", nil)]) "round_prepare"
      (.tuple [a "round_prepare", kind])
  | .tuple [.atom "prepared_round", config] =>
    if get machine "kind" == a "guard" then
      let facts ← configFacts state config nil
      return roundLoop machine facts (.tuple [a "guard_notice", facts])
    match ← ask state "round_request" config with
    | .tuple [.atom "ok", request, facts] =>
      return emitIn (set machine [("facts", facts)]) "call_model" (.tuple [a "call_model", request, facts])
    | .tuple [.atom "guard_notice", _] => return abandon machine (a "guard_disposition_pending")
    | .tuple [.atom "error", reason] => return abandon machine reason
    | other => fail "invalid_round_request" [other]
  -- A round that an overlapped activation started without its model call
  -- runs again once the activation is durable.
  | .tuple [.atom "round_failed", reason] =>
    if get machine "kind" == a "speculative" then
      return emitIn (set machine [("kind", a "prepared")]) "retry_fence" (a "await_fence")
    match reason with
    -- A model call that never started records its failure without a
    -- transcript position.
    | .tuple [.atom "unstarted", detail] =>
      let events ← lostEvents state detail nil
      return emitIn (set machine [("detail", detail)]) "unstarted_commit"
        (plainCommit events [(b "fresh", a "true")])
    | _ => return roundFailure machine reason
  | .atom "lost" =>
    let machine := set machine [("rebuild", a "lost")]
    rebuild state machine
  | .atom "compact_round" =>
    let recovery := (← ask state "context_overflow_pending?").truthy
    let cont := if recovery then a "recover_overflow" else a "run_round"
    let machine := set machine [("cont", cont), ("mode", a "maybe_compact"), ("recovery", Term.bool recovery)]
    return emitIn machine "compaction_facts" (.tuple [a "compaction_facts", a "maybe_compact"])
  -- Compaction.
  | .tuple [.atom "compaction_prepare", facts] =>
    match ← ask state "compaction_prepare" (.tuple [get machine "mode", facts]) with
    | .atom "needs_config" =>
      return emitIn (set machine [("facts", facts)]) "compaction_config" (a "compaction_config")
    | answer => prepared machine answer
  | .tuple [.atom "finish", plan, raw] => finishCompaction state machine plan raw
  | .tuple [.atom "compacted", result] =>
    return emitIn (set machine [("result", result)]) "compacted" (.tuple [a "compacted", result, get machine "cont"])
  | .atom "after_compaction" => afterCompaction state machine
  | _ => fail "invalid_instruction" [instr]

/-- The instruction that a host event resumes. -/
private def resume (state machine event : Term) : KernelM Step := do
  let phase := get machine "phase"
  let is := fun (name : String) => phase == b name
  -- A host starts each entry on a fresh machine.
  match event with
  | .tuple [.atom "process", entry] => return .next (set machine [("entry", entry)]) (a "process")
  | .tuple [.atom "process_fast", entry] => return .next (set machine [("entry", entry)]) (a "process_fast")
  | .atom "activate_fast" =>
    return .next (set machine [("entry", empty), ("entry_kind", b "admission")]) (a "fast_activation")
  | .tuple [.atom "round_run", kind] =>
    return .next (set machine [("entry_kind", b "round")]) (.tuple [a "round", kind])
  | .tuple [.atom "compact", mode, facts, cont] =>
    return .next (set machine [("mode", mode), ("cont", cont), ("recovery", a "false")])
      (.tuple [a "compaction_prepare", facts])
  -- A loop run that ends with the host: `{:loop, loop_machine, event}`.
  | .tuple [.atom "loop", loopMachine, loopEvent] =>
    return .next (hold (set machine [("after", b "return")]) [("loop", loopMachine)]) (.tuple [a "loop", loopEvent])
  | .atom "rebuild" =>
    if is "loop_io" || is "compaction_commit" || is "lost_commit" then return .next machine (a "rebuild")
    fail "unexpected_event" [phase, event]
  | .tuple [.atom "done", value] =>
    -- Recovery and repair.
    if is "recover" then
      if continues value then return .next machine (a "repair")
      return finish (.tuple [a "apply_recovery", value])
    if is "repair_commit" then
      if !isOk value then return finish (.tuple [a "recovery_failure", a "repair_commit", errorReason value])
      let recovery ← observeRecovery state machine
      return emitIn (set machine [("recovery", recovery)]) "repaired" (.tuple [a "apply_recovery", recovery])
    if is "repaired" then
      if continues (get machine "recovery") then return .next machine (a "prepare_activation")
      return finish (a "idle")
    -- The loop.
    if is "loop_io" then
      if value == a "ok" then return .next machine (a "drain")
      if get machine "after" == b "activation" then
        return activationFailure machine (materializationError (errorReason value))
      return roundFailure machine (errorReason value)
    if is "loop_answer" then return .next machine (.tuple [a "loop", .tuple [a "fact", value]])
    if is "loop_data" then
      match value with
      | .tuple [.atom "error", reason] => return roundFailure machine reason
      | _ => return .next machine (.tuple [a "loop", value])
    if is "round_io" then
      match value with
      | .tuple [.atom "error", reason] => return roundFailure machine reason
      | _ => return .next (set machine [("start", nil)]) (.tuple [a "loop", get machine "start"])
    if is "refresh" then
      if isOk value then return .next machine (.tuple [a "round", a "normal"])
      return .next (set machine [("kind", a "fresh")]) (.tuple [a "round_failed", errorReason value])
    if is "abandon" then return .next machine (.tuple [a "round_failed", get machine "reason"])
    -- Activation.
    if is "plan" then return .next machine (.tuple [a "planned", value])
    if is "plan_wait" then return settle machine (get machine "outcome")
    if is "settle" then
      if !isOk value then return activationFailure machine (materializationError (errorReason value))
      return if get machine "outcome" == a "continue" then finish (a "reprocess") else finish (a "idle")
    if is "round_config" then
      match value with
      | .tuple [.atom "ok", config] => return .next machine (.tuple [a "configured", config])
      | _ => return activationFailure machine (errorReason value)
    if is "fallback_fence" then
      if isOk value then return .next machine (a "fallback_activate")
      return activationFailure machine (materializationError (errorReason value))
    if is "fallback_activate" then
      if isOk value then return .next machine (a "compact_round")
      return activationFailure machine (errorReason value)
    if is "activate" then
      if isOk value then return .next machine (.tuple [a "round", a "prepared"])
      return activationFailure machine (errorReason value)
    if is "speculate" then
      if value == a "started" then return .next machine (.tuple [a "round", a "speculative"])
      if value == a "sequential" then
        return emitIn machine "activate" (.tuple [a "command", a "activate", get machine "args"])
      return activationFailure machine (errorReason value)
    if is "retry_fence" then
      if isOk value then return .next machine (.tuple [a "round", a "prepared"])
      return activationFailure machine (errorReason value)
    if is "gate_fence" then
      if isOk value then return .emit (set machine [("phase", b "model")]) (a "await")
      return activationFailure machine (errorReason value)
    -- Rounds.
    if is "round_prepare" then
      match value with
      | .tuple [.atom "ok", config] => return .next machine (.tuple [a "prepared_round", config])
      | _ => return .next machine (.tuple [a "round_failed", errorReason value])
    if is "failure_config" then
      match value with
      | .tuple [.atom "ok", config] =>
        let facts ← configFacts state config (a "current")
        let failure ← ask state "context_overflow_failure" (get machine "reason")
        return roundLoop machine facts (.tuple [a "model_failure", failure, facts])
      | _ => return finish (.tuple [a "recovery_failure", a "compaction", errorReason value])
    if is "call_model" then
      if value == a "started" then
        if get machine "kind" == a "speculative" then return emitIn machine "gate_fence" (a "await_fence")
        return .emit (set machine [("phase", b "model")]) (a "await")
      return .next machine (.tuple [a "round_failed", errorReason value])
    if is "round_outcome" then return afterOutcome machine (get machine "outcome")
    if is "lost_commit" then
      return emitIn machine "lost_report" (.tuple [a "call_failed", Term.bool (isOk value)])
    if is "lost_report" then return ← afterLost state machine
    if is "unstarted_commit" then
      return emitIn machine "unstarted_report" (.tuple [a "call_failed", Term.bool (isOk value)])
    if is "unstarted_report" then return finish (a "idle")
    if is "response_router" then
      let facts := (get machine "facts").put (b "canonical_router") value
      return roundLoop machine facts (.tuple [a "model_response", get machine "response", facts])
    -- Compaction.
    if is "compaction_facts" then
      let facts := value.put (b "overflow_recovery") (get machine "recovery")
      return .next machine (.tuple [a "compaction_prepare", facts])
    if is "compaction_config" then
      let facts := get machine "facts"
      let facts := match value with
        | .tuple [.atom "ok", config] => facts.put (b "config") config
        | other => facts.put (b "config_error") (errorReason other)
      return ← prepared machine (← ask state "compaction_prepare" (.tuple [get machine "mode", facts]))
    if is "compaction_prompt" then
      let plan := get machine "plan"
      match value with
      | .tuple [.atom "ok", prompts] =>
        let machine := set machine [("refreshed", get prompts "refreshed")]
        return emitIn machine "summarize" (.tuple [a "summarize", plan, get prompts "prompt"])
      | other =>
        return .next machine (.tuple [a "finish", plan, .tuple [a "error", .tuple [a "session_config", errorReason other]]])
    if is "summarize" then
      if value == a "started" then return .emit (set machine [("phase", b "compaction")]) (a "await")
      return .next machine (.tuple [a "finish", get machine "plan", value])
    if is "compaction" then return .next machine (.tuple [a "finish", get machine "plan", value])
    if is "compaction_commit" then
      if isOk value then return .next machine (.tuple [a "compacted", .tuple [a "ok", get machine "result"]])
      return .next machine (.tuple [a "compacted", .tuple [a "error", errorReason value]])
    if is "compacted" then return .next machine (a "after_compaction")
    fail "unexpected_event" [phase, event]
  | .tuple [.atom "model", response] =>
    if !is "model" then fail "unexpected_event" [phase, event]
    -- The Router fact holds at the response.
    return emitIn (set machine [("response", response)]) "response_router" (.tuple [a "fact", a "canonical_router"])
  | .tuple [.atom "model_lost", facts] =>
    if !is "model" then fail "unexpected_event" [phase, event]
    return .next (set machine [("detail", get facts "detail"), ("queue_snapshot", get facts "queue_snapshot")])
      (a "lost")
  | _ => fail "unexpected_event" [phase, event]

/-- `session_step {machine, event, host}` → `{machine, effect}`. Internal
transitions are bounded. -/
def step (state args : Term) : KernelM Term := do
  let .tuple [machine, event, _host] := args | fail "function_clause"
  let machine := if machine.isMap then machine else idleMachine
  let mut current ← resume state machine event
  for _ in [0:4096] do
    match current with
    | .emit machine effect => return .tuple [machine, effect]
    | .next machine instr => current ← run state machine instr
  fail "session_step_fuel"

/-- `session_repair {live, checkpoint}`: the repair of a crash, for a host
that repairs outside a processing entry. -/
def table : OpTable := [("session_step", step),
  ("session_repair", fun state entry => repairEvents state entry)]

end VerifiedKernel.Session.Drive
