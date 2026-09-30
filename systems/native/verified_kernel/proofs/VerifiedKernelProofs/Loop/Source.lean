import VerifiedKernel.Session.Loop
import VerifiedKernelProofs.Proof.NativeProducerTactic

/-! # Sources of loop effects

Definitions only. This module names the effects that `Loop.stepWith` emits and
records, for each `commit`, `run_tools` and `write` effect, the place in
`Loop.lean` that emits it and the facts that hold there. `Loop/Shape.lean`
proves that every such effect has a source. -/

namespace VerifiedKernel.Session.LoopProof
open Data
set_option Elab.async false

/-! ## Kernel computations -/

/-- The computation returns `value` for some observations. -/
def Returns (m : KernelM Term) (value : Term) : Prop := ∃ j j', m j = .ok (value, j')

/-- The kernel query `name` answers `result` on `state` for `args`. -/
def Answers (state : Term) (name : String) (args result : Term) : Prop :=
  Returns (Loop.queryAsk state name args) result

/-- The session field `name` of `state` is `value`. -/
def FieldIs (state : Term) (name : String) (value : Term) : Prop := Returns (field state name) value

/-- One successful transition of `stepWith ask`. -/
def StepOK (ask : Loop.Ask) (state machine event machine' : Term) (effects : List Term) : Prop :=
  ∃ j j', Loop.stepWith ask state (.tuple [machine, event]) j = .ok (.tuple [machine', list effects], j')

/-! ## Machine access

These copy the private helpers of `Loop.lean`. -/

/-- The loop's `key`: a binary-keyed map read, nil for a non-map. -/
def mkey (m : Term) (k : String) : Term := if m.isMap then m.get (b k) else nil

/-- A round fact of the machine. -/
def fact (machine : Term) (k : String) : Term := mkey (mkey machine "round") k

def phaseIs (machine : Term) (name : String) : Prop := mkey machine "phase" = b name

/-- The ack watermark of a round: `id_snapshot - 1`, or 0. -/
def ackHwmOf (round : Term) : Int :=
  let snapshot := integerValue (mkey round "id_snapshot")
  if snapshot > 0 then snapshot - 1 else 0

/-- The round that a model failure reads. -/
def failureRound (machine event : Term) : Term :=
  match event with
  | .tuple [.atom "model_failure", _, round] => round
  | _ => mkey machine "round"

/-- The machine that `guardNotice` reads. -/
def guardMachine (machine event : Term) : Term :=
  match event with
  | .tuple [.atom "guard_notice", round] =>
    (Term.map [(b "round", round.put (b "entry") (b "guard_notice"))]).put (b "phase") (b "guard_notice")
  | _ => machine

/-- The round facts that activation and wait expiry read. -/
def entryRound (machine event : Term) : Term :=
  match event with
  | .tuple [.atom "activate", facts] => facts
  | .tuple [.atom "wait_timeout", _, _, facts] => facts
  | _ => mkey machine "round"

/-- The router fact that `activation` passes to `activation_next`. -/
def activationRouter (machine event : Term) : Term :=
  match event with
  | .tuple [.atom "activate", _] => nil
  | .tuple [.atom "fact", value] => value
  | _ => mkey machine "router"

/-- The private `decodeRound` of `Loop.lean`. -/
def decodeRoundOf : Term → VerifiedKernel.AgentLoop.Round.State :=
  native_decl% "VerifiedKernel.Session.Loop.decodeRound"

/-- The private `noticeCall` of `Loop.lean`: the notice call for a binding. -/
def noticeCallOf : Term → Term := native_decl% "VerifiedKernel.Session.Loop.noticeCall"

/-! ## Effects -/

inductive EffectKind where
  | notify | commit | write | setTimer | cancelTimer | blocking | unknown
  deriving DecidableEq, Repr

/-- The class of an effect term that `Loop.lean` emits. -/
def effectKind : Term → EffectKind
  | .tuple [.atom "notify", _, _] => .notify
  | .tuple [.atom "commit", _, _, _] => .commit
  | .tuple [.atom "write", _] => .write
  | .tuple [.atom "set_timer", _, _] => .setTimer
  | .tuple [.atom "cancel_timer", _] => .cancelTimer
  | .atom "continue" => .blocking
  | .tuple [.atom "build_record", _] => .blocking
  | .tuple [.atom "run_tools", _, _] => .blocking
  | .tuple [.atom "store_results", _, _] => .blocking
  | .tuple [.atom "commit_planned_results", _, _] => .blocking
  | .tuple [.atom "stop", _] => .blocking
  | .tuple [.atom "fact", _] => .blocking
  | .tuple [.atom "materialize", _] => .blocking
  | _ => .unknown

/-- A blocking effect: its outcome is the next event. -/
def Blocking (effect : Term) : Prop := effectKind effect = .blocking

/-- A non-blocking effect that may follow the commit. -/
def AfterCommit (effect : Term) : Prop :=
  effectKind effect = .notify ∨ effectKind effect = .write ∨
    effectKind effect = .setTimer ∨ effectKind effect = .cancelTimer

/-- The commit options of `Loop.commit`. -/
def hwmOpts (hwm : Term) : Term := if hwm == nil then list [] else list [.tuple [a "hwm", hwm]]

def commitEffect (events : List Term) (opts mode : Term) : Term :=
  .tuple [a "commit", list events, opts, mode]

def runToolsEffect (calls flags : Term) : Term := .tuple [a "run_tools", calls, flags]

def writeEffect (events : List Term) : Term := .tuple [a "write", list events]

/-- Notifications, at most one commit, non-blocking effects, then one blocking effect. -/
def StepShape (effects : List Term) : Prop :=
  ∃ (pre : List Term) (commit : Option Term) (mid : List Term) (last : Term),
    effects = pre ++ commit.toList ++ mid ++ [last] ∧
    (∀ e ∈ pre, effectKind e = .notify) ∧ (∀ e ∈ commit.toList, effectKind e = .commit) ∧
    (∀ e ∈ mid, AfterCommit e) ∧ Blocking last

/-! ## Events that the loop builds -/

def statusIdle (sid : Term) : Term :=
  .map [(b "type", b "status"), (b "session_id", sid), (b "status", b "idle")]

def ackEvent (sid hwm : Term) : Term :=
  .map [(b "type", b "ack"), (b "session_id", sid), (b "last_ack_message_id", hwm)]

/-- The ACK of a model failure. It keeps the round budget. -/
def failureAckEvent (sid hwm : Term) : Term :=
  .map [(b "type", b "ack"), (b "session_id", sid), (b "last_ack_message_id", hwm),
    (b "keep_round_budget", a "true")]

def overflowEvent (eventId created hwm seq compacted : Term) : Term :=
  .map [(b "type", b "session_event"), (b "event_id", eventId),
    (b "kind", b "context_overflow_recovery_requested"), (b "source", b "internal_runtime"),
    (b "created_at", created),
    (b "event", .map [(b "transcript_hwm", hwm), (b "summary_sequence", seq), (b "compacted_through", compacted)])]

def failedEvent (eventId info hwm created : Term) : Term :=
  .map [(b "type", b "session_event"), (b "event_id", eventId),
    (b "kind", b "llm_call_failed"), (b "source", b "internal_runtime"),
    (b "event", info.put (b "transcript_hwm") hwm), (b "created_at", created)]

/-- The `content_bytes` of a runaway-unsettled event. -/
def contentBytes (content : Term) : Term :=
  i (match content with | .binary raw => raw.size | _ => 0)

def unsettledEvent (eventId aid bytes created : Term) : Term :=
  .map [(b "type", b "session_event"), (b "event_id", eventId),
    (b "kind", b "runaway_unsettled_round"), (b "source", b "internal_runtime"),
    (b "event", .map [(b "assistant_message_id", aid), (b "content_bytes", bytes)]),
    (b "created_at", created)]

def resetEvent (eventId aid count created : Term) : Term :=
  .map [(b "type", b "session_event"), (b "event_id", eventId),
    (b "kind", b "runaway_guard_reset"), (b "source", b "internal_runtime"),
    (b "event", .map [(b "assistant_message_id", aid), (b "tool_call_count", count)]),
    (b "created_at", created)]

def noticeAssistant (sid aid call : Term) : Term :=
  .map [(b "type", b "assistant"), (b "session_id", sid), (b "message_id", aid),
    (b "content", b ""), (b "tool_calls", list [call]), (b "visible_reply_phase", b "clean")]

def waitSetEvent (sid wait : Term) : Term :=
  .map [(b "type", b "wait_set"), (b "session_id", sid), (b "wait", wait)]

/-- The binding that `guardNotice` passes to `guard_failure_prepare`. -/
def noticeBinding (disposition callId : Term) : Term :=
  let binding := match disposition with
    | .map xs => Term.map (xs.filter (fun (k, _) => k != b "eligible"))
    | other => other
  (binding.put (b "outcome") (b "blocked")).put (b "tool_call_id") callId

/-- The events of a tool-turn record: its intent, then its admission events. -/
def intentEvents (record : Term) : List Term :=
  wrap (mkey record "intent") ++
    (if (mkey record "admission").isMap then wrap (mkey (mkey record "admission") "events") else [])

def intentHwm (record : Term) : Term :=
  if (mkey record "admission").isMap then mkey (mkey record "admission") "hwm" else mkey record "aid"

def intentMode (record : Term) : Term :=
  .map [(b "speculative", Term.bool (mkey record "speculative").truthy), (b "cancel_draft_on_error", a "true")]

/-- The commit watermark of a final output. -/
def finishHwm (opts aid : Term) : Term :=
  match opts with | .list [.tuple [_, h]] => h | _ => aid

/-! ## Entry conditions -/

/-- `guardNotice` runs for a `guard_notice` event or a `continue` in phase `guard_notice`. -/
def GuardEntry (machine event : Term) : Prop :=
  (∃ round, event = .tuple [a "guard_notice", round]) ∨ (event = a "continue" ∧ phaseIs machine "guard_notice")

/-- `modelFailure` runs for a classified error response or a `model_failure` event. -/
def FailureEntry (machine event : Term) : Prop :=
  (event = a "continue" ∧ phaseIs machine "classify") ∨
    ∃ info round, event = .tuple [a "model_failure", info, round]

/-- `activation` runs for these events. -/
def ActivationEntry (machine event : Term) : Prop :=
  (∃ facts, event = .tuple [a "activate", facts]) ∨ (event = a "continue" ∧ phaseIs machine "activation") ∨
    ∃ value, event = .tuple [a "fact", value] ∧ phaseIs machine "router"

/-- `expire` runs for these events. -/
def WaitEntry (machine event : Term) : Prop :=
  ActivationEntry machine event ∨ (∃ w s facts, event = .tuple [a "wait_timeout", w, s, facts]) ∨
    (event = a "continue" ∧ phaseIs machine "timeout") ∨
    ∃ value, event = .tuple [a "fact", value] ∧ phaseIs machine "busy"

/-- A re-entry that reads a machine carried by the host: `{:fact, value}` in
phase `busy` or `router`, or `continue` in phase `activation`. -/
def CarriedEntry (machine event value : Term) : Prop :=
  (event = .tuple [a "fact", value] ∧ (phaseIs machine "busy" ∨ phaseIs machine "router")) ∨
    (event = a "continue" ∧ phaseIs machine "activation")

/-! ## Commit sources -/

/-- The place in `Loop.lean` that emits `commit events opts mode` for
`stepWith queryAsk state (machine, event)`, with the facts that hold there. -/
inductive CommitSource (state machine event : Term) : List Term → Term → Term → Prop
  /-- Context-overflow recovery for a classified error response. -/
  | overflow (sid hwm eventId created seq compacted recovery : Term)
      (entry : event = a "continue" ∧ phaseIs machine "classify")
      (session : FieldIs state "session_id" sid)
      (ackHwm : hwm = i (ackHwmOf (mkey machine "round")))
      (recoveryField : FieldIs state "context_overflow_recovery" recovery)
      (notAttempted : (recovery.isMap && recovery.get (b "transcript_hwm") == hwm) = false)
      (summary : FieldIs state "summary_sequence" seq)
      (compactedField : FieldIs state "compacted_through" compacted) :
      CommitSource state machine event
        [overflowEvent eventId created hwm seq compacted, statusIdle sid] (list []) nil
  /-- A model failure: the failure, idle, and the ack when `llm_failure_ack?`
  holds on the projected state. -/
  | modelFailure (sid hwm raw info eventId created projected ackAnswer : Term)
      (entry : FailureEntry machine event)
      (session : FieldIs state "session_id" sid)
      (ackHwm : hwm = i (ackHwmOf (failureRound machine event)))
      (retry : Answers state "llm_retry_metadata" (.tuple [raw, hwm]) info)
      (project : Returns (Command.project state [failedEvent eventId info hwm created, statusIdle sid]) projected)
      (ackQuery : Answers projected "llm_failure_ack?" nil ackAnswer) :
      CommitSource state machine event
        ([failedEvent eventId info hwm created, statusIdle sid] ++
          (if ackAnswer.truthy then [failureAckEvent sid hwm] else []))
        (hwmOpts (if integerValue hwm > 0 then hwm else nil)) nil
  /-- An idle status at a round boundary. -/
  | boundaryIdle (sid : Term) (p : String)
      (entry : event = a "continue") (phase : phaseIs machine p)
      (named : p = "boundary" ∨ p = "async_boundary" ∨ p = "boundary_after_tools")
      (session : FieldIs state "session_id" sid) :
      CommitSource state machine event [statusIdle sid] (list []) nil
  /-- Runaway retirement. -/
  | guardRetire (events : List Term)
      (entry : GuardEntry machine event)
      (retire : Answers state "runaway_retirement" nil (list events)) :
      CommitSource state machine event events (list []) nil
  /-- Local settlement of a runtime failure. -/
  | guardLocal (retire : Term) (events : List Term)
      (entry : GuardEntry machine event)
      (retireAnswer : Answers state "runaway_retirement" nil retire) (retireNotList : retire.isList = false)
      (settle : Answers state "guard_failure_local_settlement" nil (list events)) :
      CommitSource state machine event events (list []) nil
  /-- The runtime failure notice: its assistant record and its attempt. -/
  | notice (retire settle reply sid aid disposition callId attempt : Term)
      (entry : GuardEntry machine event)
      (retireAnswer : Answers state "runaway_retirement" nil retire) (retireNotList : retire.isList = false)
      (settleAnswer : Answers state "guard_failure_local_settlement" nil settle)
      (settleNotList : settle.isList = false)
      (replyField : FieldIs state "runtime_failure_reply" reply) (noReply : reply.isMap = false)
      (config : (fact (guardMachine machine event) "guard_config").truthy = true)
      (session : FieldIs state "session_id" sid)
      (nextId : FieldIs state "next_message_id" aid)
      (dispositionAnswer : Answers state "guard_disposition_binding" aid disposition)
      (dispositionMap : disposition.isMap = true)
      (prepare : Answers state "guard_failure_prepare" (noticeBinding disposition callId) attempt)
      (attemptMap : attempt.isMap = true) :
      CommitSource state machine event
        [noticeAssistant sid aid (noticeCallOf (mkey attempt "event")), attempt] (hwmOpts aid) nil
  /-- Cleanup of orphaned local work before the notice runs. -/
  | noticeCleanup (now : Term) (events : List Term)
      (entry : event = a "continue" ∧ phaseIs machine "notice_cleanup")
      (cleanup : Answers state "guard_failure_cleanup_events" (.tuple [nil, now]) (list events))
      (nonempty : events ≠ []) :
      CommitSource state machine event events (list []) nil
  /-- A final output: the `finish_output` events, or the `onboarding_settlement`
  output when the plan asks for onboarding. -/
  | finalOutput (record nmid sid aid unsettledId created tag outputEvents fopts plan onboarding : Term)
      (events : List Term)
      (entry : event = .tuple [a "record", record]) (phase : phaseIs machine "final_record")
      (nextId : FieldIs state "next_message_id" nmid) (fresh : (mkey record "base" == nmid) = true)
      (checked : Loop.hostEventsList (wrap (mkey record "leading") ++ [mkey record "assistant"]) = a "ok")
      (aidIs : aid = mkey record "aid")
      (session : FieldIs state "session_id" sid)
      (finish : Answers state "finish_output"
        (.tuple [mkey record "leading", mkey record "assistant", aid, fact machine "vphase",
          Term.bool (mkey machine "terminal").isMap,
          unsettledEvent unsettledId aid (contentBytes (mkey machine "content")) created])
        (.tuple [tag, outputEvents, fopts, plan]))
      (onboardingCase : ((plan.get (a "onboarding?")).truthy = true ∧ ∃ router : Bool,
          Answers state "onboarding_settlement" (.tuple [list [], outputEvents, Term.bool router]) onboarding) ∨
        ((plan.get (a "onboarding?")).truthy = false ∧ onboarding = nil))
      (committed : (if onboarding.isList then onboarding else outputEvents) = list events) :
      CommitSource state machine event events (hwmOpts (finishHwm fopts aid)) nil
  /-- A tool-turn intent at the session's next message id. The proven round
  machine issues `commitIntent`, then `executeTools`. -/
  | intent (record nmid : Term)
      (entry : event = .tuple [a "record", record]) (phase : phaseIs machine "intent")
      (nextId : FieldIs state "next_message_id" nmid) (fresh : (mkey record "base" == nmid) = true)
      (checked : Loop.hostEventsList (intentEvents record) = a "ok")
      (roundStart : (VerifiedKernel.AgentLoop.Round.step (decodeRoundOf (mkey machine "rstate")) .start).2 =
        .commitIntent)
      (roundCommitted : (VerifiedKernel.AgentLoop.Round.step
        (VerifiedKernel.AgentLoop.Round.step (decodeRoundOf (mkey machine "rstate")) .start).1 .committed).2 =
          .executeTools) :
      CommitSource state machine event (intentEvents record) (hwmOpts (intentHwm record)) (intentMode record)
  /-- Settlement of a stored tool batch, including `results_only` and notice results. -/
  | settle (hostEvents hwm base stored nmid sid unsettledId unsettledAt resetId resetAt : Term)
      (router : Bool) (events : List Term)
      (entry : event = .tuple [a "results_stored", hostEvents, hwm, base, stored])
      (phase : phaseIs machine "results" ∨ phaseIs machine "results_only" ∨ phaseIs machine "notice_results")
      (nextId : FieldIs state "next_message_id" nmid) (fresh : (base != nmid) = false)
      (checked : Loop.hostEventsList (wrap hostEvents) = a "ok")
      (session : FieldIs state "session_id" sid)
      (settleAnswer : Answers state "settle_tool_batch"
        (.tuple [hostEvents, stored, mkey (mkey machine "pending") "track",
          unsettledEvent unsettledId (mkey (mkey machine "pending") "aid") (contentBytes (b "")) unsettledAt,
          resetEvent resetId (mkey (mkey machine "pending") "aid")
            (i (wrap (mkey (mkey machine "pending") "calls")).length) resetAt,
          Term.bool router]) (list events)) :
      CommitSource state machine event events (hwmOpts hwm) nil
  /-- A wait extension. -/
  | waitExtend (sid wait busy now ceiling next : Term)
      (entry : WaitEntry machine event)
      (session : FieldIs state "session_id" sid)
      (waitField : FieldIs state "wait" wait)
      (ceilingIs : ceiling = mkey (entryRound machine event) "ceiling_ms")
      (decided : VerifiedKernel.AgentLoop.WaitExtension.decide wait busy now ceiling = .tuple [a "extend", next]) :
      CommitSource state machine event [waitSetEvent sid next] (list []) nil
  /-- A wait timeout that this step answered from `wait_timeout_event`. -/
  | waitTimeoutFresh (waitId source timeout : Term)
      (entry : (∃ facts, event = .tuple [a "wait_timeout", waitId, source, facts]) ∨
        (event = a "continue" ∧ phaseIs machine "timeout" ∧
          waitId = mkey machine "wait_id" ∧ source = mkey machine "source"))
      (answer : Answers state "wait_timeout_event" (.tuple [waitId, source]) timeout)
      (present : (timeout == nil) = false) :
      CommitSource state machine event [timeout] (list []) nil
  /-- A wait timeout that an earlier step stored in the host-held machine. The
  step reads it from the machine, after the busy-delegate fact or on another
  re-entry of a machine whose entry is `wait_timeout`. -/
  | waitTimeoutCarried (value : Term)
      (entry : CarriedEntry machine event value)
      (timer : mkey machine "entry" = b "wait_timeout") :
      CommitSource state machine event [mkey machine "timeout_event"] (list []) nil

/-! ## Dispatch sources -/

/-- The place that emits `run_tools calls flags`. -/
inductive DispatchSource (state machine event : Term) : Term → Term → Prop
  /-- A model tool turn. The same effect list commits `intentEvents record`
  first (see `Loop/Shape.lean`). -/
  | modelTurn (record nmid progress : Term)
      (entry : event = .tuple [a "record", record]) (phase : phaseIs machine "intent")
      (nextId : FieldIs state "next_message_id" nmid) (fresh : (mkey record "base" == nmid) = true)
      (checked : Loop.hostEventsList (intentEvents record) = a "ok") :
      DispatchSource state machine event (mkey machine "calls")
        (.map [(b "mode", b "model_turn"), (b "planned", Term.bool (mkey record "admission").isMap),
          (b "aid", mkey record "aid"), (b "progress_event", progress)])
  /-- The runtime failure notice at the aid that the `notice` commit used. -/
  | notice (now : Term) (events : List Term)
      (entry : event = a "continue" ∧ phaseIs machine "notice_cleanup")
      (cleanup : Answers state "guard_failure_cleanup_events" (.tuple [nil, now]) (list events))
      (authorized : (mkey machine "notice_authorized").truthy = true) :
      DispatchSource state machine event (list [mkey machine "notice"])
        (.map [(b "mode", b "runtime_failure_notice"), (b "aid", mkey machine "notice_aid")])

/-! ## Write sources -/

/-- The place that emits `write events`: the provider-wait yield. -/
inductive WriteSource (state machine event : Term) : List Term → Prop
  | yield (waitIdentity nmid ack human : Term) (events : List Term)
      (entry : ActivationEntry machine event)
      (next : Answers state "activation_next" (activationRouter machine event) (a "yield"))
      (identity : Answers state "wait_identity" nil waitIdentity)
      (nextId : FieldIs state "next_message_id" nmid)
      (acked : FieldIs state "last_ack_message_id" ack)
      (humans : Answers state "active_human_source_ids" nil human)
      (yielded : Answers state "provider_wait_yield_events"
        (.map [(b "wait_identity", waitIdentity), (b "next_message_id", nmid),
          (b "last_ack_message_id", ack), (b "active_human_source_ids", human)]) (list events))
      (nonempty : events ≠ []) :
      WriteSource state machine event events

end VerifiedKernel.Session.LoopProof
