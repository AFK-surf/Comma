import VerifiedKernel.Session.Async
import VerifiedKernel.Session.Queue

namespace VerifiedKernel.Session
open Data

def bounded (value : Term) (limit : Nat) : Term :=
  match value with
  | .binary raw =>
    if (String.fromUTF8? raw).isNone then b "" else
      let bytes := trim raw
      if bytes.size ≤ limit then .binary bytes else b ""
  | _ => b ""

def putBounded (target key value : Term) (limit : Nat) : Term :=
  let value := bounded value limit
  if value == b "" then target else target.put key value

def obligationKey (target : Term) : KernelM Term := do
  let parts := if target.get (b "kind") == b "task_card" then
      [target.get (b "provider"), b "task_card", target.get (b "conversation_id")]
    else [target.get (b "provider"), target.get (b "connect_id"), target.get (b "channel"), target.get (b "thread_ts")]
  let some bytes ← Json.encode (list parts) | fail "invalid_term"
  return .binary (hex (← digest bytes))

def normalizeObligation (value : Term) : KernelM Term := do
  if !value.isMap then return nil
  let raw ← stringify value
  let kind := bounded (← Data.event raw "kind") 32
  if kind != b "" && kind != b "task_card" then return nil
  if bounded (← Data.event raw "provider") 32 != b "slack" then return nil
  if kind == b "task_card" then
    let conversation := bounded (← Data.event raw "conversation_id") 128
    if conversation == b "" then return nil
    let base := Term.map [(b "provider", b "slack"), (b "kind", b "task_card"), (b "conversation_id", conversation)]
    let target := putBounded base (b "connect_id") (← Data.event raw "connect_id") 256
    let target := putBounded target (b "channel") (← Data.event raw "channel") 128
    let target := putBounded target (b "thread_ts") (← Data.event raw "thread_ts") 64
    return target.put (b "key") (← obligationKey target)
  else
    let connect := bounded (← Data.event raw "connect_id") 256
    if connect == b "" then return nil
    let channel := bounded (← Data.event raw "channel") 128
    if channel == b "" then return nil
    let thread := bounded (← Data.event raw "thread_ts") 64
    if thread == b "" then return nil
    let target := Term.map [(b "provider", b "slack"), (b "connect_id", connect), (b "channel", channel), (b "thread_ts", thread)]
    return target.put (b "key") (← obligationKey target)

@[inline] def obligationValue (value : Term) (key : String) : Term :=
  (value.get (b key)).default (value.get (a key))

def obligationMap (state : Term) : Term :=
  let value := obligationValue state "provider_reply_obligations"
  if value.isMap then value else empty

def addObligation (state raw : Term) : KernelM Term := do
  let target ← normalizeObligation raw
  if target.isMap && target.has (b "key") then
    write state [("provider_reply_obligations", (obligationMap state).put (target.get (b "key")) target)]
  else pure state

def queuedObligations (state : Term) : KernelM (List Term) :=
  (wrap (obligationValue state "input_queue")).foldlM (fun acc item => do
    let payload := obligationValue item "payload"
    let target ← normalizeObligation (obligationValue payload "provider_reply_obligation")
    return if target.has (b "key") then acc ++ [target.get (b "key")] else acc) []

def obligationBlocking (state : Term) : Bool :=
  match obligationMap state with
  | .map xs => xs.any (fun pair => obligationValue pair.2 "kind" == b "task_card")
  | _ => false

def obligationResolve (state key : Term) : KernelM Term := do
  if !key.isBinary then return state
  write state [("provider_reply_obligations", ← remove (obligationMap state) key)]

/-- Admit cards only while their gate is open and capacity remains. -/
def obligationCard (state conversation limit : Term) : KernelM Term := do
  let targets := (← entries (obligationMap state)).map Prod.snd
  let targets ← sortBy targets (fun target => Data.event target "key")
  let replies := targets.filter (fun target =>
    let kind := obligationValue target "kind"
    kind == nil || kind == b "")
  if replies.isEmpty || !limit.isInteger || integerValue limit ≤ 0 then return state
  let base := Term.map [(b "provider", b "slack"), (b "kind", b "task_card"), (b "conversation_id", conversation)]
  let raw ← match replies with
    | [only] => merge base (select only ["connect_id", "channel", "thread_ts"])
    | _ => pure base
  let target ← normalizeObligation raw
  if !target.has (b "key") then return state
  let key := target.get (b "key")
  let obligations := obligationMap state
  let queued ← queuedObligations state
  let occupied := uniq ((← entries obligations).map Prod.fst ++ queued)
  if obligations.has key || Int.ofNat occupied.length < integerValue limit then
    write state [("provider_reply_obligations", obligations.put key target)]
  else pure state

def presentString (value : Term) : Bool := value.isBinary && value != b ""

@[inline] def scopeValue (value : Term) (key : String) : Term :=
  if value.has (b key) then value.get (b key) else value.get (a key)

def validResponseIdentity (value : Term) : Bool :=
  match value with
  | .binary bytes =>
    bytes.size == 28 && bytes.extract 0 4 == "rsp_".toUTF8 &&
      (bytes.extract 4 28).toList.all (fun byte =>
        let n := byte.toNat
        (65 ≤ n && n ≤ 90) || (97 ≤ n && n ≤ 122) || (48 ≤ n && n ≤ 57) || n == 45 || n == 95)
  | _ => false

def validScope (scope : Term) : Bool :=
  let ids := scopeValue scope "source_message_ids"
  let messages := scopeValue scope "source_messages"
  validResponseIdentity (scopeValue scope "response_identity") &&
    presentString (scopeValue scope "conversation_id") &&
    match ids, messages with
    | .list ids, .list messages =>
      !ids.isEmpty && ids.all presentString && uniq ids == ids &&
        messages.length == ids.length && messages.map (fun message => scopeValue message "source_message_id") == ids
    | _, _ => false

def replyRepair (state event : Term) : KernelM Term := do
  let repair := select event ["status", "attempts", "revision", "diagnostic_hwm", "completed_at_hwm", "public_summary", "created_at"] true
  let current := if [b "completed", b "aborted"].contains (← Data.event event "status") then nil else repair
  let updated ← write state [("visible_reply_repair", current)]
  let seq ← add ((← field updated "last_seq").default (i 0)) (i 1)
  let fact := repair.put (b "kind") (b "visible_reply_repair") |>.put (b "seq") seq
  let events ← append ((← field updated "events").default (list [])) (list [fact])
  let time := (← Data.event event "created_at").default (← field updated "last_activity_at")
  write updated [("events", events), ("last_seq", seq), ("llm_failure_streak", nil), ("last_activity_at", time)]

def replyIntent (state event : Term) : KernelM Term := do
  let intent ← stringify (select event ["assistant_message_id", "content", "scope", "idempotency_key", "created_at"])
  let time := (← Data.event event "created_at").default (← field state "last_activity_at")
  write state [("visible_reply_intent", intent), ("last_activity_at", time)]

def retireIntent (state event : Term) : KernelM Term := do
  let intent ← field state "visible_reply_intent"
  let current ← if intent.isMap then alias intent (b "idempotency_key") (a "idempotency_key") else pure nil
  if current.isBinary && current == (← Data.event event "idempotency_key") then
    write state [("visible_reply_intent", nil)]
  else pure state

def activationStarted (state raw : Term) : KernelM Term := do
  let scope ← stringify raw
  if validScope scope then
    write state [("visible_reply_activation_scope", scope), ("last_activity_at", ← field state "last_activity_at")]
  else pure state

def activationFinished (state identity : Term) : KernelM Term := do
  let scope ← field state "visible_reply_activation_scope"
  let current ← if scope.isMap then alias scope (b "response_identity") (a "response_identity") else pure nil
  if current.isBinary && current == identity then write state [("visible_reply_activation_scope", nil)] else pure state

/-- The value an advancing ACK leaves behind: `cleared`, or the stored value.
A named choice over unconditional reads, not a monadic `if` per field: each
`let x ← if …` duplicates the rest of the reducer into both branches, and the
append-only and ledger-frame walkers cannot digest that term past five fields. -/
def clearedWhen (advanced : Bool) (cleared value : Term) : Term := if advanced then cleared else value

/-- Pending card obligations prevent an advancing ACK. An ACK marked
`keep_round_budget` does not start the round budget over: only fresh input
does that. A model-failure ACK carries the mark. -/
def sessionAck (state event : Term) : KernelM Term := do
  let previous ← field state "last_ack_message_id"
  let next ← maximum previous ((← Data.event event "last_ack_message_id").default (i 0))
  let advanced ← greater next previous
  if advanced && obligationBlocking state then return state
  let keepRounds := (← Data.event event "keep_round_budget") == a "true"
  let obligations := clearedWhen advanced empty (← field state "provider_reply_obligations")
  let sources := clearedWhen advanced (list []) (← field state "active_source_message_ids")
  let scope := clearedWhen advanced nil (← field state "visible_reply_activation_scope")
  let egress := clearedWhen advanced empty ((← field state "visible_reply_egress_facts").default empty)
  let streak := clearedWhen advanced nil (← field state "runaway_unsettled_streak")
  let rounds := clearedWhen (advanced && !keepRounds) nil (← field state "input_round_streak")
  let attempt ← field state "runtime_failure_reply"
  let attempt := if attempt.isMap && integerValue next ≥ integerValue (attempt.get (b "assistant_id")) then nil else attempt
  write state [("last_ack_message_id", next), ("provider_reply_obligations", obligations),
    ("active_source_message_ids", sources), ("visible_reply_activation_scope", scope),
    ("visible_reply_egress_facts", egress), ("runaway_unsettled_streak", streak), ("input_round_streak", rounds),
    ("runtime_failure_reply", attempt)]

def waitExact (state id : Term) : KernelM Bool := do
  let wait := state.get (a "wait")
  if !wait.isMap then return false
  let raw := (← Data.event wait "tool_call_id") :: wrap (← Data.event wait "tool_call_ids")
  let ids := uniq (raw.filter presentString)
  if (← Data.event wait "source") != b "auto_wait" || !ids.any (· == id) then return false
  ids.allM (fun key => do
    match ← resolveResult state key with
    | .tuple [.atom "ok", record] => return terminal record
    | .tuple [.atom "archived", .integer seq] => return seq > 0
    | _ => return false)

def waitClear (state event : Term) : KernelM Term := do
  let id := event.get (b "tool_call_id")
  if presentString id then
    if !(← waitExact state id) then return state
  pruneResultRefs (← write state [("wait", nil)])

end VerifiedKernel.Session
