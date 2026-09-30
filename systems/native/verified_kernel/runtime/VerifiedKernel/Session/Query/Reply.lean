import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.TranscriptCore

/-! Queries ported from `SalixAgent.VisibleReplyPolicy` (phase, guard),
`SalixAgent.VisibleReplyScope`, `SalixAgent.ProviderReplyObligation`,
`SalixAgent.Compaction` gating, `SalixAgent.Round.prepare_prompt_snapshot`,
and `SalixAgent.ContextProviders.provider_states`. See the README query catalog. -/

namespace VerifiedKernel.Session.ReplyQuery
open Data

/-! ## Field readers

The three source modules read a field in three different ways and the
distinction is observable, so each has its own reader here. -/

/-- `VisibleReplyScope.value/3`: the string key, then the atom key, then the
default. A key that is present answers with its value, `nil` included. -/
@[inline] def sv (value : Term) (key : String) (fallback : Term := nil) : Term :=
  if value.isMap then
    if value.has (b key) then value.get (b key)
    else if value.has (a key) then value.get (a key)
    else fallback
  else fallback

/-- `VisibleReplyScope.value/3` where the key is already a term. -/
def svKey (value key fallback : Term) : Term :=
  if value.isMap then
    if value.has key then value.get key
    else match key with
      | .binary raw =>
        match String.fromUTF8? raw with
        | some name => if value.has (a name) then value.get (a name) else fallback
        | none => fallback
      | _ => fallback
  else fallback

/-- `VisibleReplyPolicy.value/2`: the string key, then the atom key, under
Elixir truthiness. -/
@[inline] def policyValue (value : Term) (key : String) : Term :=
  (value.get (b key)).default (value.get (a key))

/-- `VisibleReplyPolicy.non_negative_int/1`. -/
def nonNegInt (value : Term) : Term :=
  match value with
  | .integer n => if n ≥ 0 then i n else i 0
  | _ => i 0

/-- `Round.present/1` and `VisibleReplyScope.present_string?/1`: a non-empty
binary, untrimmed. -/
def presentBinary (value : Term) : Bool := value.isBinary && value != b ""

/-- The same test as a value, for `Round.present/1`. -/
def presentTerm (value : Term) : Term := if presentBinary value then value else nil

private def trimmed (value : Term) : Term :=
  match value with | .binary raw => .binary (trim raw) | _ => value

private def anyM (f : Term → KernelM Bool) : List Term → KernelM Bool
  | [] => pure false
  | x :: xs => do if ← f x then pure true else anyM f xs

private def allM (f : Term → KernelM Bool) : List Term → KernelM Bool
  | [] => pure true
  | x :: xs => do if ← f x then allM f xs else pure false

/-! ## `SalixAgent.VisibleReplyPolicy` -/

/-- `VisibleReplyPolicy.phase/1`. -/
def phase (state : Term) : KernelM Term := do
  let repair := state.get (a "visible_reply_repair")
  if !repair.isMap then return a "clean"
  if (← stringChars (policyValue repair "status")) == b "required" then
    return .tuple [a "repair_required", nonNegInt (policyValue repair "attempts")]
  return a "clean"

/-- `VisibleReplyPolicy.guard/1`. -/
def guard (state : Term) : KernelM Term := do
  let repair := state.get (a "visible_reply_repair")
  if !repair.isMap then return a "clean"
  let status ← stringChars (policyValue repair "status")
  let tagged := fun (name : String) => Term.tuple [a name,
    nonNegInt (policyValue repair "attempts"),
    nonNegInt (policyValue repair "revision"),
    nonNegInt (policyValue repair "diagnostic_hwm")]
  if status == b "required" then return tagged "repair_required"
  if status == b "exhausted" then return tagged "repair_exhausted"
  return a "clean"

/-- `VisibleReplyPolicy.target_tool/1`. -/
def targetTool (call : Term) : KernelM Term := do
  let name ← stringChars (policyValue call "name")
  let args := (policyValue call "args").default empty
  if name == b "call" && args.isMap then
    return trimmed (← stringChars (policyValue args "tool"))
  return trimmed name

/-! ## `SalixAgent.VisibleReplyScope` -/

/-- `VisibleReplyScope.source_ids/1`. -/
def sourceIds (messages : List Term) : List Term :=
  uniq (messages.filterMap (fun message =>
    let value := sv message "source_message_id"
    if presentBinary value then some value else none))

/-- `VisibleReplyScope.trusted_origin_matches?/2`. -/
def trustedOriginMatches (origin common : Term) : Bool :=
  origin.isMap && common.isMap &&
    sv origin "provider" == b "internal" &&
    sv origin "conversation_kind" == b "user_chat" &&
    sv origin "source_actor_type" == b "user" &&
    sv origin "agent_group_id" == sv common "agent_group_id" &&
    sv origin "conversation_id" == sv common "conversation_id" &&
    sv origin "participant_id" == sv common "participant_id"

private def sourceEntry (sourceId messageId : Term) : Term :=
  .map [(b "source_message_id", sourceId), (b "message_id", messageId)]

private def trustedEntriesLoop :
    List Term → List Term → Option Term → Option (List Term × Term)
  | [], entries, common =>
    match common with
    | some value => if entries.isEmpty then none else some (entries, value)
    | none => none
  | message :: rest, entries, common =>
    let sourceId := sv message "source_message_id"
    let origin := sv message "trusted_origin"
    let conversation := sv origin "conversation_id"
    let messageId := sv origin "message_id"
    let participant := sv origin "participant_id"
    let group := sv origin "agent_group_id"
    if presentBinary sourceId && origin.isMap &&
        sv origin "provider" == b "internal" &&
        sv origin "conversation_kind" == b "user_chat" &&
        sv origin "source_actor_type" == b "user" &&
        presentBinary conversation && presentBinary messageId &&
        presentBinary participant && presentBinary group then
      let next := Term.map [(a "conversation_id", conversation),
        (a "participant_id", participant), (a "agent_group_id", group)]
      let entries := entries ++ [sourceEntry sourceId messageId]
      match common with
      | some value => if value == next then trustedEntriesLoop rest entries common else none
      | none => trustedEntriesLoop rest entries (some next)
    else none

/-- `VisibleReplyScope.trusted_source_entries/1`: the entries and the one
origin identity they all share, or nothing. -/
def trustedSourceEntries (messages : List Term) : Option (List Term × Term) :=
  trustedEntriesLoop messages [] none

/-- `VisibleReplyScope.decode_args/1`. -/
def decodeArgs (args : Term) : Term :=
  if args.isMap then args
  else match args with
    | .binary raw =>
      match Json.decode raw with
      | some decoded => if decoded.isMap then decoded else empty
      | none => empty
    | _ => empty

/-- `VisibleReplyScope.canonical_source_send_call?/2`. -/
def canonicalSourceSendCall (call conversation : Term) : KernelM Bool := do
  if (← targetTool call) != b "im_api.internal.send_message" then return false
  let args := decodeArgs (sv call "args" empty)
  let params := if sv call "name" == b "call" then sv args "params" empty else args
  return sv params "conversation_id" == conversation

/-- `VisibleReplyScope.source_send_call?/2`. -/
def sourceSendCall (call conversation : Term) : KernelM Bool := do
  if !call.isMap then return false
  canonicalSourceSendCall call conversation

/-- `VisibleReplyScope.explicit_source_send_intent?/2`. -/
def explicitSourceSendIntent (messages : List Term) (conversation : Term) : KernelM Bool :=
  anyM (fun message =>
    enumUntil (sv message "tool_calls" (list [])) false (fun _ call => do
      if ← sourceSendCall call conversation then return (false, true)
      return (true, false))) messages

/-- `VisibleReplyScope.executed_nested_source_send?/3`. -/
def executedNestedSourceSend (state common sources : Term) : KernelM Bool := do
  let group := sv common "agent_group_id"
  let conversation := sv common "conversation_id"
  if !(group.isBinary && conversation.isBinary && sources.isList) then fail "function_clause"
  let key ← egressKey group conversation sources
  let payload := svKey (sv state "visible_reply_egress_facts" empty) key empty
  return sv payload "agent_group_id" == group &&
    sv payload "conversation_id" == conversation &&
    sv payload "source_message_ids" (list []) == sources &&
    sv payload "ownership_key" == key

/-- `VisibleReplyScope.source_send_owns_reply?/4`. -/
def sourceSendOwnsReply (state : Term) (messages : List Term) (common sources : Term) :
    KernelM Bool := do
  if ← explicitSourceSendIntent messages (sv common "conversation_id") then return true
  executedNestedSourceSend state common sources

/-- `VisibleReplyScope.trusted_async_continuation?/4`. -/
def trustedAsyncContinuation (message : Term) (messages : List Term)
    (sources common : Term) : Bool :=
  let toolCallId := sv message "source_tool_call_id"
  let kind := sv message "type"
  (kind == b "tool_call_completed" || kind == b "tool_call_failed") &&
    presentBinary toolCallId &&
    sv message "trusted_origin_source_message_ids" (list []) == sources &&
    trustedOriginMatches (sv message "trusted_origin") common &&
    messages.any (fun candidate =>
      sv candidate "role" == b "tool" &&
        sv candidate "tool_call_id" == toolCallId &&
        sv candidate "status" == b "async_running")

/-- `VisibleReplyScope.only_trusted_async_continuations?/3`. -/
def onlyTrustedAsyncContinuations (messages : List Term) (sources common : Term) : Bool :=
  (messages.filter (fun message =>
    sv message "role" == b "runtime" && sv message "no_wake" != a "true")).all
    (fun message => trustedAsyncContinuation message messages sources common)

/-- `VisibleReplyScope.persisted_compacted_scope/3`, the fallback of `derive/2`. -/
def persistedCompactedScope (state : Term) (messages : List Term) (sources : Term) :
    KernelM Term := do
  let scope := sv state "visible_reply_activation_scope"
  let ack := sv state "last_ack_message_id" (i 0)
  let compactedThrough := sv state "compacted_through" (i 0)
  let scopeIds := sv scope "source_message_ids" (list [])
  let scopedMessages ← allM (fun message => do
    let role := sv message "role"
    let noWake := sv message "no_wake"
    if role == b "user" then return noWake == a "true"
    if role == b "runtime" && noWake != a "true" then
      return sv message "trusted_origin_source_message_ids" (list []) == scopeIds &&
        trustedOriginMatches (sv message "trusted_origin") scope
    return true) messages
  if (← phase state) != a "clean" then return a "none"
  if !validScope scope then return a "none"
  if sources != scopeIds then return a "none"
  if !(← greater compactedThrough ack) then return a "none"
  if !scopedMessages then return a "none"
  if ← sourceSendOwnsReply state messages scope scopeIds then return a "none"
  return .tuple [a "ok", scope]

private def deriveScope (state sources : Term) (current userMessages : List Term)
    (compactedScope compactedIds : Term) : KernelM (Option Term) := do
  if (← phase state) != a "clean" then return none
  if userMessages.isEmpty then return none
  if (← append compactedIds (list (sourceIds userMessages))) != sources then return none
  if sources == list [] then return none
  let some (entries, common) := trustedSourceEntries userMessages | return none
  if !(compactedIds == list [] || trustedOriginMatches compactedScope common) then return none
  if !onlyTrustedAsyncContinuations current sources common then return none
  if ← sourceSendOwnsReply state current common sources then return none
  let inherited ← asList (sv compactedScope "source_messages" (list []))
  return some (.tuple [a "ok", .map [
    (b "version", i 1),
    (b "provider", b "internal"),
    (b "agent_group_id", common.get (a "agent_group_id")),
    (b "conversation_id", common.get (a "conversation_id")),
    (b "conversation_kind", b "user_chat"),
    (b "participant_id", common.get (a "participant_id")),
    (b "source_actor_type", b "user"),
    (b "source_message_ids", sources),
    (b "source_messages", list (inherited ++ entries))]])

/-- `VisibleReplyScope.derive/2`. -/
def derive (state sources : Term) : KernelM Term := do
  if !state.isMap || !sources.isList then return a "none"
  let lastAck := (sv state "last_ack_message_id").default (i 0)
  let reversed ← enumFold (sv state "messages" (list [])) [] (fun acc message => do
    let id := (sv message "id").default (i 0)
    if id.isInteger && (← greater id lastAck) then return message :: acc else return acc)
  let current := reversed.reverse
  let userMessages := current.filter (fun message =>
    sv message "role" == b "user" &&
      (sv message "no_wake" != a "true" || presentBinary (sv message "source_message_id")))
  let stored := sv state "visible_reply_activation_scope" empty
  let past ← greater (sv state "compacted_through" (i 0)) lastAck
  let compactedScope := if past then stored else empty
  let compactedIds := sv compactedScope "source_message_ids" (list [])
  match ← deriveScope state sources current userMessages compactedScope compactedIds with
  | some result => return result
  | none => persistedCompactedScope state current sources

/-- `VisibleReplyScope.current_source_message_ids/1`. -/
def currentSourceMessageIds (state : Term) : KernelM Term := do
  if !state.isMap then return list []
  let lastAck := sv state "last_ack_message_id" (i 0)
  let selected ← enumFold (sv state "messages" (list [])) [] (fun acc message => do
    let id := sv message "id" (i 0)
    if sv message "role" == b "user" && id.isInteger && (← greater id lastAck) then
      return acc ++ [message]
    return acc)
  let ids := sourceIds selected
  let scope := sv state "visible_reply_activation_scope"
  if (← greater (sv state "compacted_through" (i 0)) lastAck) && validScope scope then
    return list (uniq ((← asList (sv scope "source_message_ids")) ++ ids))
  return list ids

/-- `VisibleReplyScope.equivalent?/2` on args `{left, right}`. Elixir `==` on
maps is structural and order-independent, and compares numbers by value. -/
def scopesEquivalent (args : Term) : KernelM Term := do
  let .tuple [left, right] := args | return a "false"
  if !left.isMap || !right.isMap then return a "false"
  let drop := fun (value : Term) => do
    remove (← remove value (b "response_identity")) (a "response_identity")
  return Term.bool (Term.numericEq (← drop left) (← drop right))

/-! ## Actor reply plans -/

/-- Reuse an equivalent committed scope before the host allocates an identity. -/
def reusableScope (state candidate : Term) : KernelM Term := do
  let current ← field state "visible_reply_activation_scope"
  if validScope current && (← scopesEquivalent (.tuple [current, candidate])).truthy then
    return .tuple [a "ok", current]
  return a "none"

/-- Recheck the source scope when the host returns a newly allocated identity. -/
def activationStart (state args : Term) : KernelM Term := do
  let .tuple [minted, sources, sessionId, now] := args | fail "function_clause"
  match ← reusableScope state minted with
  | .tuple [.atom "ok", current] =>
    return .tuple [a "ok", list [], list [], .map [(a "scope", current)]]
  | _ => pure ()
  match ← derive state sources with
  | .tuple [.atom "ok", candidate] =>
    if candidate.isMap && (← scopesEquivalent (.tuple [candidate, minted])).truthy then
      let current ← field state "visible_reply_activation_scope"
      let event := .map [(b "type", b "visible_reply_activation_started"),
        (b "session_id", sessionId), (b "scope", minted), (b "created_at", now)]
      return .tuple [a "ok", list [event], list [], .map [(a "scope", minted),
        (a "replaced_scope", if validScope current then current else nil)]]
  | _ => pure ()
  return .tuple [a "error", a "visible_reply_scope_changed"]

/-- The event and cancellation scope for retirement, or an empty plan. -/
def activationRetirement (state args : Term) : KernelM Term := do
  let .tuple [sessionId, now] := args | fail "function_clause"
  let scope ← field state "visible_reply_activation_scope"
  if !validScope scope then return .tuple [list [], .map [(a "scope", nil)]]
  let event := .map [(b "type", b "visible_reply_activation_finished"),
    (b "session_id", sessionId), (b "response_identity", policyValue scope "response_identity"),
    (b "created_at", now)]
  return .tuple [list [event], .map [(a "scope", nil), (a "retired_scope", scope)]]

/-- Recover a pending reply with one abort, acknowledgement, and idle batch. -/
def abortPendingReply (state args : Term) : KernelM Term := do
  let .tuple [sessionId, now] := args | fail "function_clause"
  let intent ← field state "visible_reply_intent"
  if !intent.isMap then return a "none"
  let hwm := (policyValue intent "assistant_message_id").default (i 0)
  let events := list [
    .map [(b "type", b "visible_reply_aborted"), (b "session_id", sessionId),
      (b "idempotency_key", policyValue intent "idempotency_key"), (b "created_at", now)],
    .map [(b "type", b "ack"), (b "session_id", sessionId), (b "last_ack_message_id", hwm)],
    .map [(b "type", b "status"), (b "session_id", sessionId), (b "status", b "idle")]]
  return .tuple [a "ok", events, hwm, intent]

/-! ## `SalixAgent.ProviderReplyObligation` -/

/-- `ProviderReplyObligation.key/1`. The canonical list is JSON, so the encoder
must agree with Jason byte for byte. -/
def obligationKeyOf (target : Term) : KernelM Term := do
  if !target.isMap then fail "function_clause"
  let parts := if obligationValue target "kind" == b "task_card" then
      [obligationValue target "provider", b "task_card", obligationValue target "conversation_id"]
    else [obligationValue target "provider", obligationValue target "connect_id",
      obligationValue target "channel", obligationValue target "thread_ts"]
  let some bytes ← Json.encode (list parts) | fail "invalid_term"
  return .binary (hex (← digest bytes))

/-- `ProviderReplyObligation.pending/1`. -/
def pendingObligations (state : Term) : KernelM Term := do
  let targets := (← entries (obligationMap state)).map Prod.snd
  return list (← sortBy targets (fun target => pure (target.get (b "key"))))

/-- `ProviderReplyObligation.pending_count/1`. -/
def pendingObligationCount (state : Term) : KernelM Term := do
  return i (Int.ofNat (← entries (obligationMap state)).length)

/-- `ProviderReplyObligation.blocking_count/1`. `target["kind"]` is `Access`,
so only the string key counts here. -/
def blockingObligationCount (state : Term) : KernelM Term := do
  let xs ← entries (obligationMap state)
  return i (Int.ofNat (xs.filter (fun pair => pair.2.get (b "kind") == b "task_card")).length)

/-- `ProviderReplyObligation.admission_full?/3` on args `{payload, limit}`. -/
def admissionFull (state args : Term) : KernelM Term := do
  let .tuple [payload, limit] := args | return a "false"
  if !state.isMap || !payload.isMap || !limit.isInteger || integerValue limit < 0 then
    return a "false"
  let accepted := uniq ((← entries (obligationMap state)).map Prod.fst ++ (← queuedObligations state))
  let target ← normalizeObligation (obligationValue payload "provider_reply_obligation")
  if !(target.isMap && target.has (b "key")) then return a "false"
  let key := target.get (b "key")
  return Term.bool (!accepted.any (· == key) && Int.ofNat accepted.length ≥ integerValue limit)

/-! ## `SalixAgent.Round` and `SalixAgent.ContextProviders` -/

/-- `Round.prepare_prompt_snapshot/2` on the same configuration used for dispatch.
The stored value records the last activation. It does not freeze runtime rules. -/
def promptSnapshot (state args : Term) : KernelM Term := do
  let prompt := presentTerm args
  let stored := presentTerm (state.get (a "system_prompt"))
  if prompt == nil || prompt == stored then return .tuple [list [], stored]
  return .tuple [list [.map [(b "type", b "session_system_prompt"),
    (b "session_id", ← field state "session_id"), (b "system_prompt", prompt)]], prompt]

/-- `ContextProviders.provider_states/1`. -/
def providerStatesOf (state : Term) : KernelM Term :=
  providerStates ((state.get (a "context_provider_states")).default
    (state.get (b "context_provider_states")))

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("visible_reply_phase", fun state _ => phase state),
   ("visible_reply_guard", fun state _ => guard state),
   ("derive_visible_reply_scope", derive),
   ("current_source_message_ids", fun state _ => currentSourceMessageIds state),
   ("valid_activation_scope?", fun _ args => pure (Term.bool (validScope args))),
   ("scopes_equivalent?", fun _ args => scopesEquivalent args),
   ("pending_obligations", fun state _ => pendingObligations state),
   ("pending_obligation_count", fun state _ => pendingObligationCount state),
   ("blocking_obligation_count", fun state _ => blockingObligationCount state),
   ("obligation_admission_full?", admissionFull),
   ("normalize_obligation", fun _ args => normalizeObligation args),
   ("obligation_key", fun _ args => obligationKeyOf args),
   ("prepare_prompt_snapshot", promptSnapshot),
   ("provider_states", fun state _ => providerStatesOf state)]

end VerifiedKernel.Session.ReplyQuery
