import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Query.Materialize
import VerifiedKernel.Session.Query.Round

/-! Queries ported from `SalixAgent.InternalSession.State`, `SalixAgent.TurnOutcome`,
and `SalixAgent.Waits.consecutive_timeouts`. See the README query catalog. -/

namespace VerifiedKernel.Session.StateQuery
open Data

/-! ### Scheduler state -/

/-- `State.derived_state/1`. -/
def derivedState (state : Term) : KernelM Term := do
  if (← field state "status") == a "active" then return a "active"
  if ← hasUnackedWakeable state then return a "queued"
  if ← waiting state then return a "waiting"
  if (← retryAt state).isInteger then return a "waiting"
  if ← hasUnprocessedStableWork state then return a "queued"
  return a "paused"

/-- The earliest durable deadline owns discovery, independent of the model wait. -/
def recoveryWait (state : Term) : KernelM Term := do
  let retry ← retryAt state
  let wait ← field state "wait"
  let calls := (← field state "async_tool_calls").default empty
  let callback ← if calls.isMap then pure ((← entries calls).map (fun pair => capabilityDueAt pair.2)) else pure []
  let deadlines := (retry :: wait.get (b "deadline_ms") :: callback).filter Term.isInteger
  match deadlines with
  | [] => return wait
  | first :: rest =>
    let deadline := rest.foldl (fun acc value => if integerValue value < integerValue acc then value else acc) first
    if wait.get (b "deadline_ms") == deadline then return wait
    return .map [(b "deadline_ms", deadline)]

/-- `State.activity_issue/1`. -/
def activityIssue (state : Term) : KernelM Term := do
  if (← activity state) != a "failed" then return nil
  if ← repairExhausted state then return b "visible_reply_repair_exhausted"
  if ← runawayExhausted state then return b "runaway_guard_parked"
  if ← repeatedExhausted state then return b "repeated_tool_result_parked"
  if ← roundBudgetExhausted state then return b "input_round_budget_parked"
  let billing ← billingFailureReason state
  if billing.isBinary then return billing
  if ← terminalFailure state then return b "model_connection_failed"
  return nil

/-- `State.monitored_activity_signature/1`. -/
def monitoredSignature (state : Term) : KernelM Term := do
  let status ← activity state
  if status == a "paused" then return a "stopped"
  if status == a "failed" then
    return .tuple [a "error", (← activityIssue state).default (b "runtime_failed")]
  return a "active"

/-! ### Context size -/

/-- `State.estimated_tokens/1`: `div(context_byte_size(state), 4)`. -/
def estimatedTokens (state : Term) : KernelM Term := do
  let bytes ← contextBytes state
  if !bytes.isInteger then fail "badarith"
  let count := integerValue bytes
  return i (if count < 0 then -(Int.ofNat (count.natAbs / 4)) else Int.ofNat (count.toNat / 4))

/-- `State.observed_prompt_tokens/1`: the newest fenced assistant usage, else zero. -/
def observedPromptTokens (state : Term) (model : Term := nil) : KernelM Term := do
  let found ← findFirst (fun message => do
    if (← pick message "role") != b "assistant" then return false
    let tokens ← pick message "input_tokens"
    return tokens.isInteger && integerValue tokens > 0)
    (wrap (← field state "messages")).reverse
  if found == nil then return i 0
  if model != nil && (← pick found "model") != model then return i 0
  let tokens ← pick found "input_tokens"
  let sequence ← pick found "request_summary_sequence"
  let watermark ← pick found "request_compacted_through"
  let currentSequence := (← field state "summary_sequence").default (i 0)
  let currentWatermark := (← field state "compacted_through").default (i 0)
  if sequence.isInteger && watermark.isInteger && sequence.numericEq currentSequence &&
      watermark.numericEq currentWatermark then return tokens
  if sequence == nil && watermark == nil && currentSequence.numericEq (i 0) &&
      currentWatermark.numericEq (i 0) then return tokens
  return i 0

/-! ### Work index -/

/-- `async_work_reasons/1`: one reason per running background call. -/
def asyncWorkReasons (state : Term) : KernelM (List Term) := do
  let calls ← field state "async_tool_calls"
  let calls := if calls.isMap then calls else empty
  if !calls.isMap then return []
  return (← entries calls).flatMap (fun pair =>
    let record := pair.2
    let status := record.get (b "status")
    let running := status == b "running" || status == a "running"
    if record.get (b "completion_mode") == b "external_callback" then
      (if running then [b "external_callback_tool_call"] else []) ++
        (if (capabilityDueAt record).isInteger then [b "capability_deadline"] else [])
    else if running then [b "process_local_background_tool_run"] else [])

/-- `State.work_reasons/1`. -/
def workReasons (state : Term) : KernelM Term := do
  let parked ← do
    if (← retryAt state).isInteger then pure true
    else if (← billingFailureReason state).isBinary || (← failuresExhausted state) || (← modelNotificationParked state) then pure true
    else if ← repairExhausted state then pure true
    else modelGuardExhausted state
  let flag (name : String) (condition : Bool) : List Term := if condition then [b name] else []
  let unacked := flag "unacked_queue_item" (← hasUnackedWakeable state)
  let active := flag "active_round" ((← field state "status") == a "active")
  let deadline := flag "wait_deadline" (← field state "wait").isMap
  let stable := flag "stable_input_pending" ((← hasPendingStableInput state) && !parked)
  let obligation := flag "provider_reply_obligation" ((← obligationPending state) && !parked)
  let continuation := flag "transcript_continuation" (← needsContinuation state)
  let retry := flag "llm_retry" (← retryAt state).isInteger
  let repair := flag "visible_reply_repair" (← repairRequired state)
  let attempt ← field state "runtime_failure_reply"
  let failure := flag "runtime_failure_reply" ((attempt.isMap && !(attempt.get (b "notification_outcome")).isBinary) ||
    ((← RoundQuery.failureReason state) != nil &&
      integerValue (← field state "next_message_id") - 1 > integerValue (← field state "last_ack_message_id")))
  let commit := flag "visible_reply_commit" (← pendingVisibleReply state)
  return list (uniq (unacked ++ active ++ deadline ++ stable ++ obligation ++ continuation ++
    retry ++ repair ++ commit ++ failure ++ (← asyncWorkReasons state)))

/-! ### Transcript projections -/

/-- `State.covered_seq/2`. -/
def coveredSeq (state compactedThrough : Term) : KernelM Term := do
  let messages := (← field state "messages").default (list [])
  let found ← enumFind messages (fun message => do
    if ← greater ((← access message (a "id")).default (i 0)) compactedThrough then
      return (← access message (a "seq")).isInteger
    return false)
  let lastSeq := (← field state "last_seq").default (i 0)
  let candidate ← if found == nil then pure lastSeq else sub (found.get (a "seq")) (i 1)
  minimum (← maximum candidate ((← field state "compacted_seq").default (i 0))) lastSeq

/-- `State.total_message_count/1`: the live window plus the catalog's message counts. -/
def totalMessageCount (state : Term) : KernelM Term := do
  let chunks ← asList ((← field state "archive_chunks").default (list []))
  let catalog ← asList ((← field state "segment_catalog").default (list []))
  let archived ← (chunks ++ catalog).foldlM (fun acc span => do
    match span with
    | .list (_ :: _ :: messages :: _) => if messages.isInteger then add acc messages else pure acc
    | _ => pure acc) (i 0)
  add archived (i (← asList ((← field state "messages").default (list []))).length)

/-- `State.predicate_replacement/4` for an integer id: the first matching predicate's
replacement. A non-integer id falls to the catch-all clause and masks nothing. -/
def predicateReplacement (role id content : Term) : List Term → KernelM Term
  | [] => pure nil
  | entry :: rest => do
    if !id.isInteger then return nil
    let kind ← access entry (b "kind")
    let found ←
      if kind == b "tool_messages_through" && role == b "tool" then do
        if ← atMost id ((← access entry (b "through_id")).default (i 0)) then
          access entry (b "replacement")
        else pure nil
      else if kind == b "non_model_messages_over_bytes_through" && role != b "assistant" then do
        let limit ← access entry (b "max_bytes")
        let .binary bytes := content | pure nil
        if limit.isInteger && integerValue limit > 0 &&
            (← atMost id ((← access entry (b "through_id")).default (i 0))) &&
            (← greater (i bytes.size) limit) then access entry (b "replacement")
        else pure nil
      else pure nil
    if found.truthy then return found
    predicateReplacement role id content rest

/-- `State.masked_messages/1`: the window read through its redaction overlay. -/
def maskedMessages (state : Term) : KernelM Term := do
  let redactions ← field state "redactions"
  let messages := (← field state "messages").default (list [])
  if redactions == nil || redactions == list [] then return messages
  let overlays ← asList redactions
  let bySeq ← overlays.foldlM (fun acc entry => do
    let seq ← access entry (b "seq")
    if seq.isInteger then put acc seq (← access entry (b "replacement")) else pure acc) empty
  let byId ← overlays.foldlM (fun acc entry => do
    let id ← access entry (b "message_id")
    if id != nil then put acc id (← access entry (b "replacement")) else pure acc) empty
  let predicates ← overlays.filterM (fun entry => do
    let kind ← access entry (b "kind")
    return kind == b "tool_messages_through" || kind == b "non_model_messages_over_bytes_through")
  let masked ← (← asList messages).mapM (fun message => do
    let direct := (bySeq.get (← pick message "seq")).default (byId.get (← pick message "id"))
    let replacement ← if direct.truthy then pure direct else
      predicateReplacement (← pick message "role") (← pick message "id")
        (← pick message "content") predicates
    if replacement == nil then return message
    if message.has (a "content") then put message (a "content") replacement
    else put message (b "content") replacement)
  return list masked

/-! ### Wait timeouts -/

private def timeoutTail (count : Term) : List Term → KernelM Term
  | [] => pure count
  | message :: rest => do
    let role ← pick message "role"
    if role == b "assistant" || role == b "tool" then timeoutTail count rest
    else if role != b "runtime" then pure count
    else if (← pick message "type") == b "wait_expired" then
      timeoutTail (← add count (i 1)) rest
    else
      let kind ← pick message "type"
      if kind != b "tool_call_completed" && kind != b "tool_call_failed" then pure count
      else if (← pick ((← pick message "source_refs").default empty) "tool_name") ==
          b "im_api.internal.send_message" then timeoutTail count rest
      else pure count

/-- `Waits.consecutive_timeouts/1` over the session transcript. -/
def consecutiveTimeouts (state : Term) : KernelM Term := do
  timeoutTail (i 0) (← properList (← field state "messages")).reverse

/-! ### Compaction gate -/

/-- `0.9 * window` at IEEE-754 double precision, as `Compaction` computes it. -/
def triggerLimit (window : Term) : KernelM Term := do
  let some value := Number.asFloat window | fail "badarith"
  let product := (Float.Model.ofScientific 9 (-1)).mul value
  let bits := product.toBits
  if bits.toNat / 2 ^ 52 % 2048 == 2047 then fail "badarith" else return .floatBits bits

/-- `Compaction.should_compact?/2` on `{threshold, context_tokens}`. -/
def shouldCompact (state args : Term) : KernelM Term := do
  if ← repairRequired state then return Term.bool false
  let (threshold, window, model) ← match args with
    | .tuple [threshold, window] => pure (threshold, window, nil)
    | .tuple [threshold, window, model] => pure (threshold, window, model)
    | _ => fail "function_clause"
  let threshold ← if threshold.truthy then pure threshold
    else observe (.tuple [a "config", a "salix_agent", a "compaction_threshold", nil])
  -- Optional instruction bodies live outside transcript/compaction summaries.
  -- Reserve one token per UTF-8 byte, conservatively, before provider dispatch.
  let selected := (state.get (a "miniskills")).get (b "inputs")
  let bytes := (wrap selected).foldl (fun total input =>
    total + (wrap (input.get (b "skills"))).foldl (fun n skill =>
      n + (match skill.get (b "content") with | .binary text => text.size | _ => 0)) 0) 0
  if threshold.isInteger then return Term.bool (← greater (← add (← contextBytes state) (i bytes)) threshold)
  if threshold != nil then fail "case_clause" [threshold]
  let trigger ← observedPromptTokens state model
  return Term.bool (← greater (← add trigger (i bytes)) (← triggerLimit (window.default (i 128000))))

/-! ### Registry -/

private def query (f : Term → KernelM Term) : Op := fun state _ => f state
private def predicate (f : Term → KernelM Bool) : Op :=
  fun state _ => return Term.bool (← f state)

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("derived_state", query derivedState),
   ("waiting?", predicate waiting),
   ("llm_retry_at_ms", query retryAt),
   ("recovery_wait", query recoveryWait),
   ("activity_status", query activity),
   ("activity_issue", query activityIssue),
   ("monitored_activity_signature", query monitoredSignature),
   ("context_byte_size", query contextBytes),
   ("estimated_tokens", query estimatedTokens),
   ("observed_prompt_tokens", query (fun state => observedPromptTokens state)),
   ("work_reasons", query workReasons),
   ("has_unacked_wakeable_input?", predicate hasUnackedWakeable),
   ("unacked_queue_items", query (fun state => return list (← unackedItems state))),
   ("materialize_pending_input_events", fun state args => do
     if args == nil then materialize state 100
     else if args.isInteger && integerValue args > 0 then materialize state (integerValue args)
     else fail "function_clause"),
   ("yieldable_provider_wait?", predicate yieldableProviderWait),
   ("wait_identity", query (fun state => do
     let wait ← field state "wait"
     if wait.isMap then waitIdentity wait else pure nil)),
   ("active_human_source_ids", query (fun state => return list (← activeHumanSourceIds state))),
   ("provider_wait_yield_events", waitYieldEvents),
   ("needs_transcript_continuation?", predicate needsContinuation),
   ("visible_reply_repair_required?", predicate repairRequired),
   ("visible_reply_repair_exhausted?", predicate repairExhausted),
   ("pending_visible_reply?", predicate pendingVisibleReply),
   ("current_activation_key", fun state args => return list (← activationKeyWith state args)),
   ("consecutive_unsettled_rounds", query unsettledCount),
   ("runaway_unsettled_rounds_exhausted?", predicate runawayExhausted),
   ("consecutive_repeated_tool_results",
     query (fun state => unsettledCount state "repeated_tool_result_streak")),
   ("repeated_tool_results_exhausted?", predicate repeatedExhausted),
   ("rounds_since_fresh_input", query (fun state => unsettledCount state "input_round_streak")),
   ("input_round_budget_exhausted?", predicate roundBudgetExhausted),
   ("repeated_tool_result_tool", query (fun state => do
     let streak ← field state "repeated_tool_result_streak"
     let name := streak.get (b "tool_name")
     return if streak.isMap && name.isBinary then name else nil)),
   ("consecutive_llm_failures", query failureCount),
   ("llm_failures_exhausted?", predicate failuresExhausted),
   ("llm_failure_terminal?", predicate terminalFailure),
   ("has_unprocessed_stable_work?", predicate hasUnprocessedStableWork),
   ("has_pending_stable_input?", predicate hasPendingStableInput),
   ("lookup_async_call", fun state args => do
     if !args.isBinary then fail "function_clause" else resolveResult state args),
   ("covered_seq", coveredSeq),
   ("total_message_count", query totalMessageCount),
   ("masked_messages", query maskedMessages),
   ("human_source_origin?", fun _ args => return Term.bool (← humanSourceOrigin args)),
   ("pending_assistant_id", query pendingAssistantId),
   ("decision_required?", predicate decisionRequired),
   ("consecutive_timeouts", query consecutiveTimeouts),
   ("conversation_sources", query (fun state => field state "conversation_sources")),
   ("should_compact?", shouldCompact)]

end VerifiedKernel.Session.StateQuery
