import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel

/-! Shared readers behind the `SalixAgent.InternalSession.State` query catalog.

Every definition here mirrors one private or public Elixir function. Elixir
truthiness (`||` skips `nil` and `false`), atom/string key precedence, and the
short-circuit order of `and`/`cond` are preserved, because the queries observe
configuration lazily and a reordered branch would read a different key. -/

namespace VerifiedKernel.Session.StateQuery
open Data

/-! ### Field readers -/

/-- `Map.get(map, "key") || Map.get(map, :key)`: no Access protocol, so a struct reads too. -/
@[inline] def dual (value : Term) (key : String) : Term := (value.get (b key)).default (value.get (a key))

/-- `value[:key] || value["key"]` through Access: atom key first. -/
@[inline] def pick (value : Term) (key : String) : KernelM Term := alias value (a key) (b key)

/-- `value["key"] || value[:key]` through Access: string key first. -/
@[inline] def pickText (value : Term) (key : String) : KernelM Term := alias value (b key) (a key)

/-- `int_value/1`: integers pass, floats truncate, complete decimal text parses, else zero. -/
def intOf (value : Term) : Term := i (integerValue value)

/-- `message_id/1`. -/
def messageId (message : Term) : KernelM Term := do return intOf (← pick message "id")

/-- `Enum.any?/2` over any supported container, with the same early exit. -/
def enumAny (value : Term) (f : Term → KernelM Bool) : KernelM Bool :=
  enumUntil value false (fun _ item => do
    if ← f item then return (false, true) else return (true, false))

/-- `Enum.take/2` for the non-negative counts these reducers use. -/
def takeUpTo (xs : List Term) (limit : Int) : List Term :=
  if limit ≤ 0 then [] else xs.take limit.toNat

/-- Accumulate the accepted prefix without retaining a frame per queue item. -/
def splitWhileLoop (f : Term → KernelM Bool) (acc : List Term) :
    List Term → KernelM (List Term × List Term)
  | [] => pure (acc.reverse, [])
  | x :: rest => do
    if ← f x then splitWhileLoop f (x :: acc) rest
    else pure (acc.reverse, x :: rest)

/-- `Enum.split_while/2`, preserving predicate order and early exit. -/
def splitWhile (f : Term → KernelM Bool) (xs : List Term) : KernelM (List Term × List Term) :=
  splitWhileLoop f [] xs

/-- `List.last/1`: defined only for proper lists. -/
def properList (value : Term) : KernelM (List Term) :=
  match value with
  | .list xs => pure xs
  | _ => fail "function_clause"

/-! ### Guards and streaks -/

/-- `State.waiting?/1`. -/
def waiting (state : Term) : KernelM Bool := do
  return (← field state "status") == a "idle" && (← field state "wait").isMap

/-- `is_integer(cap) and cap > 0 and count >= cap` over a configured cap. -/
def capReached (name : String) (fallback : Int) (count : Term) : KernelM Bool := do
  let cap ← configuration name fallback
  if cap.isInteger && integerValue cap > 0 then atMost cap count else return false

/-- `State.llm_failures_exhausted?/1`. -/
def failuresExhausted (state : Term) : KernelM Bool := do
  capReached "llm_failure_activation_cap" 3 (← failureCount state)

/-- `State.runaway_unsettled_rounds_exhausted?/1`. -/
def runawayExhausted (state : Term) : KernelM Bool := do
  capReached "runaway_unsettled_round_cap" 2 (← unsettledCount state)

/-- `State.repeated_tool_results_exhausted?/1`. -/
def repeatedExhausted (state : Term) : KernelM Bool := do
  capReached "repeated_tool_result_cap" 5 (← unsettledCount state "repeated_tool_result_streak")

/-- `State.input_round_budget_exhausted?/1`. -/
def roundBudgetExhausted (state : Term) : KernelM Bool := do
  capReached "input_round_cap" 120 (← unsettledCount state "input_round_streak")

/-- Any model guard that parks continuation until fresh input arrives:
unsettled rounds, repeated tool results, or the per-input round budget. -/
def modelGuardExhausted (state : Term) : KernelM Bool := do
  if ← runawayExhausted state then return true
  if ← repeatedExhausted state then return true
  roundBudgetExhausted state

/-- The retry record `llm_retry_at_ms/1` reads: the control field, or the legacy tail fact. -/
def retryRecord (state : Term) : KernelM Term := do
  if ← atMost (i 2) (← field state "storage_format") then return ← field state "llm_failure_streak"
  let facts ← asList ((← field state "events").default (list []))
  let fact := facts.getLast?.getD nil
  let payload := fact.get (b "event")
  if fact.get (b "kind") == b "llm_call_failed" && payload.isMap then
    return .map [(b "hwm", payload.get (b "transcript_hwm")), (b "retry_at_ms", payload.get (b "retry_at_ms"))]
  return nil

/-- `State.llm_retry_at_ms/1`: the deadline only while the streak still owns the position. -/
def retryAt (state : Term) : KernelM Term := do
  let hwm ← highWatermark state
  let retry ← retryRecord state
  let deadline := retry.get (b "retry_at_ms")
  if retry.get (b "hwm") == hwm && deadline.isInteger then
    if (← failuresExhausted state) || (← terminalFailure state) then return nil else return deadline
  return nil

/-- `State.visible_reply_repair_required?/1`. -/
def repairRequired (state : Term) : KernelM Bool := do
  let repair ← field state "visible_reply_repair"
  if !repair.isMap then return false
  return (← alias repair (b "status") (a "status")) == b "required"

/-- `State.pending_visible_reply?/1`. -/
def pendingVisibleReply (state : Term) : KernelM Bool := do
  let intent ← field state "visible_reply_intent"
  if !intent.isMap then return false
  let key ← alias intent (b "idempotency_key") (a "idempotency_key")
  let scope ← alias intent (b "scope") (a "scope")
  return key.isBinary && scope.isMap

/-- `VisibleReplyPolicy.phase/1 == :clean`. `string_value/2` converts the status. -/
def phaseClean (state : Term) : KernelM Bool := do
  let repair ← field state "visible_reply_repair"
  if !repair.isMap then return true
  return (← stringChars (dual repair "status")) != b "required"

/-- `ProviderReplyObligation.pending?/1`. -/
def obligationPending (state : Term) : KernelM Bool := do
  return !(← entries (obligationMap state)).isEmpty

/-- `has_running_async_tool?/1`: a `"status"` of `"running"` or `:running`. -/
def hasRunningAsyncTool (state : Term) : KernelM Bool := do
  let calls ← field state "async_tool_calls"
  let calls := if calls.isMap then calls else empty
  let items ← entries calls
  return items.any (fun pair =>
    let status := pair.2.get (b "status")
    status == b "running" || status == a "running")

/-- `terminal_reply_tail?/1`. -/
def terminalReplyTail (state : Term) : KernelM Bool := do
  let hwm ← field state "terminal_reply_ack_hwm"
  if !(hwm.isInteger && integerValue hwm > 0) then return false
  if !hwm.numericEq (← sub (← field state "next_message_id") (i 1)) then return false
  atMost hwm (← field state "last_ack_message_id")

/-! ### Transcript readers -/

/-- `TurnOutcome.pending_assistant_id/1`: the unacked settled assistant tail, or `nil`. -/
def pendingAssistantId (state : Term) : KernelM Term := do
  -- A list maps to itself; only other containers need the traversal.
  let trailing ← match (dual state "messages").default (list []) with
    | .list messages => pure messages.reverse
    | messages => do pure (← enumMap messages pure).reverse
  let ignorable (message : Term) : Bool :=
    dual message "no_wake" == a "true" &&
      (let role := dual message "role"
       role == b "user" || role == b "runtime" || role == b "summary")
  let message := (trailing.dropWhile ignorable).head?.getD nil
  let id := (dual message "id").default (i 0)
  let phase := dual message "visible_reply_phase"
  if dual message "role" == b "assistant" && dual message "no_wake" != a "true" &&
      (← greater id ((dual state "last_ack_message_id").default (i 0))) &&
      dual message "tool_calls" == list [] &&
      (phase == nil || phase == a "clean" || phase == b "clean") then
    return id
  return nil

/-- `TurnOutcome.decision_required?/1`. -/
def decisionRequired (state : Term) : KernelM Bool := do
  return (← pendingAssistantId state).isInteger

/-- `continuation_runnable?/1`. -/
def continuationRunnable (state : Term) : KernelM Bool := do
  if (← field state "status") != a "idle" then return false
  if (← retryAt state) != nil then return false
  if ← terminalReplyTail state then return false
  if ← hasRunningAsyncTool state then return false
  if (← failuresExhausted state) || (← modelNotificationParked state) then return false
  if ← repairExhausted state then return false
  if ← modelGuardExhausted state then return false
  return true

/-- `State.needs_transcript_continuation?/1`. Atom-keyed tails match before string-keyed ones. -/
def needsContinuation (state : Term) : KernelM Bool := do
  if ← decisionRequired state then return ← continuationRunnable state
  let messages ← properList ((← field state "messages").default (list []))
  let last := messages.getLast?.getD nil
  if !last.isMap then return false
  if last.get (a "role") == b "tool" && last.get (a "no_wake") == a "true" then return false
  if last.get (b "role") == b "tool" && last.get (b "no_wake") == a "true" then return false
  if last.get (a "role") == b "tool" || last.get (b "role") == b "tool" then
    return ← continuationRunnable state
  return false

/-- `State.has_pending_stable_input?/1`. -/
def hasPendingStableInput (state : Term) : KernelM Bool := do
  let ack := (← field state "last_ack_message_id").default (i 0)
  enumAny ((← field state "messages").default (list [])) (fun message => do
    if ← greater (← messageId message) ack then pendingInput message else pure false)

/-- `State.has_unprocessed_stable_work?/1`. -/
def hasUnprocessedStableWork (state : Term) : KernelM Bool := do
  if ← waiting state then return false
  if (← failuresExhausted state) || (← modelNotificationParked state) then return false
  if ← repairExhausted state then return false
  if ← modelGuardExhausted state then return false
  if (← retryAt state).isInteger then return true
  if ← hasPendingStableInput state then return true
  if ← needsContinuation state then return true
  if ← repairRequired state then return true
  obligationPending state

/-! ### Queue readers -/

/-- `queue_item_wake?/1`: only an explicit `false` suppresses the wake. -/
def queueWake (item : Term) : KernelM Bool := do
  if !item.isMap then fail "badmap" [item]
  let value := if item.has (b "wake") then item.get (b "wake")
    else if item.has (a "wake") then item.get (a "wake") else a "true"
  return value != a "false"

/-- `State.unacked_queue_items/1`. -/
def unackedItems (state : Term) : KernelM (List Term) := do
  let ack := (← field state "queue_ack_id").default (i 0)
  let kept ← (wrap (← field state "input_queue")).filterM (fun item => do
    greater (← queueItemId item) ack)
  sortBy kept queueItemId

/-- `State.has_unacked_wakeable_input?/1`. -/
def hasUnackedWakeable (state : Term) : KernelM Bool := do
  (← unackedItems state).anyM queueWake

/-- `present_external_provider?/1`. -/
def presentExternalProvider (provider : Term) : KernelM Bool := do
  let .binary raw ← stringChars provider | fail "badarg" [provider]
  let text := Term.binary (trim raw)
  return text != b "" && text != b "internal"

/-- `State.human_source_origin?/1`. -/
def humanSourceOrigin (origin : Term) : KernelM Bool := do
  if !origin.isMap then return false
  let provider ← pickText origin "provider"
  let actorType ← pickText origin "source_actor_type"
  if ← presentExternalProvider provider then return true
  return provider == b "internal" && actorType == b "user"

/-- `human_source_queue_item?/1`. -/
def humanSourceQueueItem (item : Term) : KernelM Bool := do
  let payload ← stringify ((← pickText item "payload").default empty)
  let origin ← access payload (b "trusted_origin")
  let obligation ← access payload (b "provider_reply_obligation")
  if (← pickText item "kind") != b "user_message" then return false
  if ← humanSourceOrigin origin then return true
  if !obligation.isMap then return false
  presentExternalProvider (← access obligation (b "provider"))

/-- `human_source_wakeable_queue_item?/1`. -/
def humanSourceWakeable (item : Term) : KernelM Bool := do
  if ← queueWake item then humanSourceQueueItem item else pure false

/-! ### Wait identity -/

/-- `Waits.wait_fingerprint/1` over the stringified wait. -/
def waitFingerprint (wait : Term) : KernelM Term := do
  let payload := Term.tuple [wait.get (b "reason"), wait.get (b "deadline_ms"),
    wait.get (b "timeout_seconds"), wait.get (b "source"), wait.get (b "tool_call_id"),
    wait.get (b "tool_call_ids")]
  let hash ← digest (← deterministic payload)
  let encoded := (ByteDigest.base64Url hash.toList).take 16
  return .binary ("fingerprint-".toUTF8 ++ encoded.toByteArray)

/-- `Waits.identity/1`: `{:ok, id}` or `{:error, :invalid_wait}`. -/
def waitIdentity (wait : Term) : KernelM Term := do
  if !wait.isMap then return .tuple [a "error", a "invalid_wait"]
  let stringified ← stringify wait
  let id := stringified.get (b "wait_id")
  if id.isBinary then
    if missing id then return .tuple [a "ok", ← waitFingerprint stringified]
    return .tuple [a "ok", id]
  if id == nil then return .tuple [a "ok", ← waitFingerprint stringified]
  return .tuple [a "error", a "invalid_wait"]

/-- `current_wait_timeout?/2` through `Waits.identity_matches?/2`. -/
def currentWaitTimeout (payload wait : Term) : KernelM Bool := do
  if !payload.isMap || payload.get (b "type") != b "wait_expired" then return false
  if !wait.isMap then return false
  let candidate ← access payload (b "wait_id")
  if !candidate.isBinary then return false
  match ← waitIdentity wait with
  | .tuple [.atom "ok", id] => return id == candidate
  | _ => return false

/-! ### Activation sources -/

/-- `active_human_source_ids/1` as the sorted set its MapSet enumerates. -/
def activeHumanSourceIds (state : Term) : KernelM (List Term) := do
  let lastAck := (← field state "last_ack_message_id").default (i 0)
  let collected ← (wrap (← field state "messages")).foldlM (fun acc message => do
    let origin ← pick message "trusted_origin"
    if (← greater (← messageId message) lastAck) && (← pick message "role") == b "user" &&
        (← access message (a "no_wake")) != a "true" &&
        (← access message (b "no_wake")) != a "true" && (← humanSourceOrigin origin) then
      return acc ++ [← pick message "source_message_id",
        ← pickText origin "source_message_id"]
    return acc) []
  sorted (uniq (collected.filter (fun value => value.isBinary && value != b "")))

/-- `current_source_runtime_queue_item?/3`. -/
def currentSourceRuntimeItem (item : Term) (sourceIds : List Term) (wait : Term) : KernelM Bool := do
  let payload ← stringify ((← pickText item "payload").default empty)
  let origin ← access payload (b "trusted_origin")
  let carried ← if origin.isMap then do pure [← pickText origin "source_message_id"] else pure []
  let inherited := wrap (← access payload (b "trusted_origin_source_message_ids")) ++ carried
  if (← pickText item "kind") != b "runtime_message" then return false
  if !(← queueWake item) then return false
  if inherited.any (fun value => sourceIds.any (· == value)) then return true
  currentWaitTimeout payload wait

/-- `current_activation_key/2` with the caller's extra ids. -/
def activationKeyWith (state ids : Term) : KernelM (List Term) := do
  let current ← normalizeScope (list ((← normalizeScope ids) ++ (← liveScope state)))
  if !current.isEmpty then return current
  if ← unacked state then storedScope state else pure []

end VerifiedKernel.Session.StateQuery
