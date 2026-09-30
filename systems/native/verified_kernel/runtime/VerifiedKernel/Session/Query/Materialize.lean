import VerifiedKernel.Session.Query.StateCore

/-! `State.materialize_pending_input_events/2` and the provider-wait yield it gates.

The batch admits at most one human activation at a time: leading no-wake context
stays ordinary Router context, one human input opens the activation, and while
one is open only runtime completions inherited from that source (or the current
wait's own timeout) still materialize. -/

namespace VerifiedKernel.Session.StateQuery
open Data

/-- `Enum.find/2`. -/
def findFirst (f : Term → KernelM Bool) : List Term → KernelM Term
  | [] => pure nil
  | x :: rest => do if ← f x then pure x else findFirst f rest

/-- Tail-recursive selection preserves the predicate's observation order. -/
def takeMatchingLoop (f : Term → KernelM Bool) (acc : List Term) :
    List Term → Nat → KernelM (List Term)
  | [], _ => pure acc.reverse
  | _, 0 => pure acc.reverse
  | x :: rest, limit + 1 => do
    if ← f x then takeMatchingLoop f (x :: acc) rest limit
    else takeMatchingLoop f acc rest (limit + 1)

/-- `Stream.filter |> Enum.take`: stops evaluating predicates at the limit. -/
def takeMatching (f : Term → KernelM Bool) (xs : List Term) (limit : Nat) : KernelM (List Term) :=
  takeMatchingLoop f [] xs limit

/-- `Enum.any?/2` with the same early exit. -/
def anyOf (f : Term → KernelM Bool) : List Term → KernelM Bool
  | [] => pure false
  | x :: rest => do if ← f x then pure true else anyOf f rest

/-- `put_present/3`: absent for `nil` and for the empty binary. -/
def putPresent (target : Term) (name : String) (value : Term) : Term :=
  if value == nil || value == b "" then target else target.put (b name) value

def stringKeyed (entries : List (String × Term)) : Term :=
  .map (entries.map (fun pair => (b pair.1, pair.2)))

/-- Immutable work fields from the queue. Retry and wake bookkeeping are not input content. -/
def acceptedInput (item : Term) : Term :=
  .tuple [item.get (b "queue_id"), item.get (b "kind"),
    item.get (b "dedupe_key"), item.get (b "payload")]

/-- `Map.new` over the runtime event literal, dropping every `nil` value. -/
def runtimeEvent (sessionId item payload nextId : Term) : KernelM Term := do
  let wake ← queueWake item
  let dedupe ← access item (b "dedupe_key")
  let read (name : String) : KernelM Term := access payload (b name)
  let created := (← access item (b "created_at")).default (← read "created_at")
  let identity := ((← read "runtime_message_id").default (← read "source_message_id")).default dedupe
  let summary := (← read "summary").default (← read "content")
  let carried ← ["source_message_id", "content", "source_tool_call_id", "wait_id", "reason",
    "timeout_seconds", "deadline_ms", "source", "elapsed_ms", "overdue_ms", "tool_call_id",
    "tool_call_ids", "failed_tool_calls", "pending_external_callback_tool_calls",
    "failed_llm_call", "diagnostic_visibility", "public_summary", "visible_reply_origin",
    "trusted_origin", "trusted_origins", "trusted_origin_source_message_ids",
    "source_refs"].mapM (fun name => do return (name, ← read name))
  let entries : List (String × Term) :=
    [("type", b "runtime_message"), ("session_id", sessionId), ("from_queue", a "true"),
     ("message_id", nextId), ("runtime_message_id", identity),
     ("runtime_message_type", ← read "type"), ("dedupe_key", dedupe),
     ("summary", summary), ("accepted_input", acceptedInput item)] ++ carried ++
    [("no_wake", Term.bool (!wake)), ("created_at", created)]
  return stringKeyed (entries.filter (fun pair => pair.2 != nil))

/-- The delivery event literal. It keeps its `nil` values; only the three
`put_present/3` fields are conditional. -/
def deliveryEvent (sessionId item payload nextId : Term) : KernelM Term := do
  let wake ← queueWake item
  let dedupe ← access item (b "dedupe_key")
  let read (name : String) : KernelM Term := access payload (b name)
  let created := (← access item (b "created_at")).default (← read "created_at")
  let event := stringKeyed
    [("type", b "delivery"), ("session_id", sessionId), ("message_id", nextId),
     ("source_message_id", (← read "source_message_id").default dedupe),
     ("dedupe_key", dedupe), ("role", (← read "role").default (b "user")),
     ("content", ← read "content"), ("accepted_input", acceptedInput item),
     ("trusted_attachment_refs", ← read "trusted_attachment_refs"),
     ("trusted_origin", ← read "trusted_origin"),
     ("provider_reply_obligation", ← read "provider_reply_obligation"),
     ("no_wake", Term.bool (!wake)), ("from_queue", a "true"), ("created_at", created)]
  let event := putPresent event "billing_context" (← read "billing_context")
  let event := putPresent event "delivered_at_ms" (← read "delivered_at_ms")
  return putPresent event "input_time" (← read "input_time")

/-- `materialize_queue_item_event/4`: the event plus the next id and high watermark. -/
def queueItemEvent (sessionId item nextId hwm : Term) : KernelM (Term × Term × Term) := do
  let payload ← stringify ((← access item (b "payload")).default empty)
  let event ← if (← access item (b "kind")) == b "runtime_message" then
      runtimeEvent sessionId item payload nextId
    else deliveryEvent sessionId item payload nextId
  return (event, ← add nextId (i 1), ← maximum hwm nextId)

/-- `materialize_batch/3`: the admitted items, the queue-ack item, and the exact consumes. -/
def materializeBatch (state : Term) (items : List Term) (limit : Int) :
    KernelM (List Term × Term × List Term) := do
  let sourceIds ← activeHumanSourceIds state
  let active := !sourceIds.isEmpty
  let items := if active then items else takeUpTo items limit
  let (leading, deferred) ← splitWhile (fun item => return !(← humanSourceWakeable item)) items
  let leading := takeUpTo leading limit
  if !active then
    let selected := takeUpTo (leading ++ takeUpTo deferred 1) limit
    return (selected, selected.getLast?.getD nil, [])
  let wait ← field state "wait"
  let remaining := limit - Int.ofNat leading.length
  let consumes ← takeMatching (fun item => currentSourceRuntimeItem item sourceIds wait)
    deferred (if remaining ≤ 0 then 0 else remaining.toNat)
  return (leading ++ consumes, leading.getLast?.getD nil, consumes)

/-- `provider_activation_retry_events/2`: one durable retry budget per queued human input. -/
def activationRetryEvents (state : Term) (materialized : List Term) : KernelM (List Term) := do
  if !materialized.isEmpty then return []
  if (← field state "status") != a "idle" then return []
  if ← waiting state then return []
  if !((← failuresExhausted state) || (← modelNotificationParked state)) then return []
  if (← activeHumanSourceIds state).isEmpty then return []
  let found ← findFirst (fun item => do
    if ← humanSourceWakeable item then
      return (← access item (b "activation_retry_consumed")) != a "true"
    return false) (← unackedItems state)
  if found == nil then return []
  return [stringKeyed
    [("type", b "session_event"), ("session_id", ← field state "session_id"),
     ("kind", b "provider_activation_retry"),
     ("event", stringKeyed [("queue_id", ← queueItemId found)])]]

/-- Generate each selected record before the batch's queue retirement events. -/
def materializeItems (sessionId : Term) (items : List Term)
    (initial : List Term × Term × Term × Bool) : KernelM (List Term × Term × Term × Bool) :=
  items.foldlM (fun acc item => do
      let (events, nextId, hwm, wake) := acc
      let (event, nextId, hwm) ← queueItemEvent sessionId item nextId hwm
      return (event :: events, nextId, hwm, wake || (← queueWake item)))
    initial

/-- `State.materialize_pending_input_events/2`: `{events, wake?, hwm}`. -/
def materialize (state : Term) (limit : Int) : KernelM Term := do
  let sessionId ← field state "session_id"
  let (items, ackItem, consumes) ← materializeBatch state (← unackedItems state) limit
  let (events, _, hwm, wake) ← materializeItems sessionId items
    ([], (← field state "next_message_id").default (i 1), i 0, false)
  let events := events.reverse
  let ackEvents ← if ackItem == nil then pure [] else do
    pure [stringKeyed [("type", b "queue_ack"), ("session_id", sessionId),
      ("queue_ack_id", ← queueItemId ackItem)]]
  let consumeEvents ← consumes.mapM (fun item => do
    return stringKeyed [("type", b "queue_consume"), ("session_id", sessionId),
      ("queue_id", ← queueItemId item)])
  let retries ← activationRetryEvents state events
  return .tuple [list (events ++ ackEvents ++ consumeEvents ++ retries),
    Term.bool (wake || !retries.isEmpty), hwm]

/-- `State.yieldable_provider_wait?/1`. -/
def yieldableProviderWait (state : Term) : KernelM Bool := do
  if (← field state "status") != a "idle" then return false
  let wait ← field state "wait"
  if !wait.isMap || wait.get (b "source") != b "wait_for" then return false
  if (← activeHumanSourceIds state).isEmpty then return false
  if !(← anyOf humanSourceWakeable (← unackedItems state)) then return false
  -- A generic wait yields scheduling ownership, not ownership of async calls.
  if obligationBlocking state then return false
  if !(← phaseClean state) then return false
  if ← pendingVisibleReply state then return false
  return (← materialize state 100) == .tuple [list [], a "false", i 0]

/-- `State.provider_wait_yield_events/2` against the caller's expected snapshot. -/
def waitYieldEvents (state expected : Term) : KernelM Term := do
  if !(← yieldableProviderWait state) then return list []
  let identity ← waitIdentity (← field state "wait")
  if identity != (← access expected (b "wait_identity")) then return list []
  if !(← field state "next_message_id").numericEq (← access expected (b "next_message_id")) then
    return list []
  if !(← field state "last_ack_message_id").numericEq (← access expected (b "last_ack_message_id")) then
    return list []
  let claimed ← sorted (uniq (wrap (← access expected (b "active_human_source_ids"))))
  if (← activeHumanSourceIds state) != claimed then return list []
  let .tuple [.atom "ok", waitId] := identity | return list []
  let sessionId ← field state "session_id"
  let hwm ← sub (← field state "next_message_id") (i 1)
  return list [
    stringKeyed [("type", b "session_event"), ("session_id", sessionId),
      ("kind", b "provider_wait_yielded"),
      ("event", stringKeyed [("wait_id", waitId), ("outcome", b "blocked"),
        ("reason", b "queued_provider_input"), ("last_ack_message_id", hwm)])],
    stringKeyed [("type", b "wait_clear"), ("session_id", sessionId)],
    stringKeyed [("type", b "ack"), ("session_id", sessionId), ("last_ack_message_id", hwm)]]

end VerifiedKernel.Session.StateQuery
