import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Query.StateCore
import VerifiedKernel.Session.Query.Reply

/-! Queries ported from SalixAgent.ToolCallProvenance and SalixAgent.IFC.Context. See the README query catalog.

`ToolCallProvenance.current_source_ids/1` itself lives in `Query/Round.lean`;
what is here is the labelled transcript view `SalixAgent.IFC.Context` builds
over the same messages, plus the activation projection
`SalixAgent.ProjectKnowledgeContext` reads before it calls its provider. -/

namespace VerifiedKernel.Session.ProvenanceQuery
open Data

/-! ## Field readers

These modules read a field in three different ways and the distinction is
observable, so each has its own reader here. A present key answers with its
value, `nil` included. -/

/-- `IFC.Context.value/2`: `Map.get(map, :key, Map.get(map, "key"))` — the atom
key, then the string key. A non-map reads as `nil`. -/
@[inline] def cv (value : Term) (key : String) : Term :=
  if value.isMap then (if value.has (a key) then value.get (a key) else value.get (b key))
  else nil

/-- `SalixAgent.IFC.value/2`: `Map.fetch(map, "key")`, then the atom key. -/
@[inline] def iv (value : Term) (key : String) : Term :=
  if value.isMap then (if value.has (b key) then value.get (b key) else value.get (a key))
  else nil

/-- `ProjectKnowledgeContext.value/3`: the atom key, the string key, the default. -/
@[inline] def pv (value : Term) (key : String) (fallback : Term := nil) : Term :=
  if value.isMap then
    (if value.has (a key) then value.get (a key)
     else if value.has (b key) then value.get (b key) else fallback)
  else fallback

/-- `SalixAgent.IFC.text/1`: `nil` is the empty string, everything else is its
`to_string/1`, trimmed. -/
def text (value : Term) : KernelM Term := do
  match ← stringChars value with
  | .binary raw => return .binary (trim raw)
  | other => return other

/-- `Enum.join/2` over binaries. -/
-- A part that is not a binary contributes no bytes but still takes a
-- separator. One left fold over a uniquely owned accumulator keeps the join
-- linear in the total size, where a right-recursive `head ++ rest` copied the
-- whole tail once per part.
private def joinText (separator : String) (parts : List Term) : ByteArray :=
  let sep := separator.toUTF8
  (parts.foldl (fun (acc, first) part =>
    let raw := match part with | .binary raw => raw | _ => ByteArray.empty
    (if first then acc ++ raw else acc ++ sep ++ raw, false)) (ByteArray.empty, true)).1

/-- `Enum.max/2` with the `fn -> 0 end` empty default these reducers use. -/
private def maxOr0 : List Term → KernelM Term
  | [] => pure (i 0)
  | x :: xs => xs.foldlM maximum x

/-! ## `SalixIFC.Codec`

`IFC.Context` reads sealed labels and principals back out of the transcript, so
the wire grammar of `SalixIFC.Codec` is part of the projection. -/

/-- `String.split(value, "|", parts: 3)`: the tail keeps its own separators. -/
private def split3 (value : String) : List String :=
  match value.splitOn "|" with
  | x :: y :: z :: rest => [x, y, String.intercalate "|" (z :: rest)]
  | parts => parts

/-- `Codec.encodable_part?/1`. -/
private def encodablePart (part : String) : Bool := part != "" && !part.contains '|'

/-- `Codec.join/1`. -/
private def joinParts (parts : List String) : Option String :=
  if parts.all encodablePart then some (String.intercalate "|" parts) else none

/-- `Codec.join_tail/2`: the tail is itself encoded, so it may carry separators. -/
private def joinTail (parts : List String) (tail : String) : Option String :=
  if parts.all encodablePart && tail != "" then
    some (String.intercalate "|" (parts ++ [tail])) else none

private def partText : Term → Option String
  | .binary raw => String.fromUTF8? raw
  | _ => none

/-- `Codec.decode_atom/1` accepts exactly these shapes, and `encode_atom!/1`
inverts it: a part of a full split carries no separator and is never blank, so a
decoded audience atom re-encodes to the very bytes it was read from. The label
projection therefore only has to recognise a valid atom string. -/
def atomString (value : Term) : Bool :=
  match partText value with
  | none => false
  | some raw =>
    match raw.splitOn "|" with
    | ["public"] => true
    | ["agent_private"] => true
    | ["space", c] => c != ""
    | ["scope", c, id] => c != "" && id != ""
    | ["tag", name] => name != ""
    | ["conversation", id] => id != ""
    | ["group", id] => id != ""
    | ["task", id] => id != ""
    | _ => false

private def decodePrincipalFuel : Nat → String → Option Term
  | 0, _ => none
  | fuel + 1, value =>
    match split3 value with
    | ["system"] => some (a "system")
    | ["comma_user", id] => if id != "" then some (.tuple [a "comma_user", b id]) else none
    | ["agent", id] => if id != "" then some (.tuple [a "agent", b id]) else none
    | ["provider_user", c, u] =>
      if c != "" && u != "" then some (.tuple [a "provider_user", b c, b u]) else none
    | ["schedule", id, creator] =>
      match decodePrincipalFuel fuel creator with
      | some creator => if id != "" then some (.tuple [a "schedule", b id, creator]) else none
      | none => none
    | ["api_key", id, creator] =>
      match decodePrincipalFuel fuel creator with
      | some creator => if id != "" then some (.tuple [a "api_key", b id, creator]) else none
      | none => none
    | _ => none

/-- `Codec.decode_principal/1`. Only a binary decodes; every other term is
`:error`, which every caller here reads as `nil`. -/
def decodePrincipal (value : Term) : Option Term :=
  match partText value with
  | some raw => decodePrincipalFuel (raw.length + 1) raw
  | none => none

private def encodePrincipalFuel : Nat → Term → Option String
  | 0, _ => none
  | fuel + 1, value =>
    match value with
    | .atom "system" => some "system"
    | .tuple [.atom "provider_user", c, u] =>
      match partText c, partText u with
      | some c, some u => joinParts ["provider_user", c, u]
      | _, _ => none
    | .tuple [.atom "comma_user", id] =>
      match partText id with | some id => joinParts ["comma_user", id] | none => none
    | .tuple [.atom "agent", id] =>
      match partText id with | some id => joinParts ["agent", id] | none => none
    | .tuple [.atom "schedule", id, creator] =>
      match encodePrincipalFuel fuel creator, partText id with
      | some tail, some id => joinTail ["schedule", id] tail
      | _, _ => none
    | .tuple [.atom "api_key", id, creator] =>
      match encodePrincipalFuel fuel creator, partText id with
      | some tail, some id => joinTail ["api_key", id] tail
      | _, _ => none
    | _ => none

/-- `Codec.encode_principal/1` as the wire binary, or `nil` for `:error`. An id
that would break the grammar is refused rather than round-tripping wrong. -/
def encodePrincipal : Option Term → Term
  | none => nil
  | some value =>
    match encodePrincipalFuel (value.depth + 1) value with
    | some encoded => b encoded
    | none => nil

/-! ## `SalixAgent.IFC` -/

/-- The fail-closed label: readable by the runtime and no human. -/
def privateLabel : Term := list [b "agent_private"]

/-- `IFC.sealed_principal/1`. -/
def sealedPrincipal (origin : Term) : KernelM (Option Term) := do
  let ifc := (iv origin "ifc").default empty
  return decodePrincipal (← text (iv ifc "principal"))

/-- `IFC.human_authored?/1`: the sealed integrity class when ingress wrote one,
else the actor type the delivery came in with. -/
def humanAuthored (origin : Term) : KernelM Bool := do
  let ifc := iv origin "ifc"
  if ifc.isMap && ifc.has (b "integrity") then
    return (← text (iv ifc "integrity")) == b "command"
  let actor ← text (iv origin "source_actor_type")
  return actor == b "user" || actor == b "provider_user"

/-- `IFC.principal/1`: the principal a sealed `trusted_origin` names, or none.
Manufacturing one from a worker's id would hand an agent the authority to
command effects, so an internal delivery is a person only when it says so. -/
def originPrincipal (origin : Term) : KernelM (Option Term) := do
  if !origin.isMap then return none
  let ref := iv origin "principal_ref"
  if ref.isMap then
    let connect ← text (iv ref "connect_id")
    let subject ← text (iv ref "subject_id")
    if connect != b "" && subject != b "" then
      return some (.tuple [a "provider_user", connect, subject])
    if subject != b "" then return some (.tuple [a "comma_user", subject])
    return none
  let provider ← text (iv origin "provider")
  if provider == b "schedule" then return ← sealedPrincipal origin
  if provider == b "internal" &&
      ((iv origin "meeting_preparation").isMap || (iv origin "triage_investigation").isMap) then
    match ← sealedPrincipal origin with
    | some (.tuple [.atom "agent", id]) => return some (.tuple [a "agent", id])
    | _ => return none
  if provider == b "internal" then
    if ← humanAuthored origin then
      let participant ← text (iv origin "participant_id")
      if participant == b "" then return none
      return some (.tuple [a "comma_user", participant])
    return none
  return none

/-- `IFC.input_ref/1`, `IFC.result_ref/1` and `IFC.assistant_ref/1`. -/
def prefixedRef (marker : String) (id : Term) : KernelM Term := do
  match ← text id with
  | .binary raw => if raw.isEmpty then return nil else return .binary (marker.toUTF8 ++ raw)
  | _ => return nil

/-! ## `SalixAgent.IFC.Context` -/

/-- One transcript message projected into the wire context. -/
structure Entry where
  ref : Term
  integrity : Term
  sourceId : Term
  items : List Term

/-- `Context.ref/2`: the `src:` ref one role cites a record by. -/
def entryRef (role message : Term) : KernelM Term := do
  if role == b "user" then prefixedRef "src:q-" (cv message "id")
  else if role == b "assistant" then prefixedRef "src:a-" (cv message "id")
  else if role == b "tool" then
    prefixedRef "src:t-" ((cv message "tool_call_id").default (cv message "id"))
  else if role == b "summary" || role == b "runtime" || role == b "system" then
    prefixedRef "src:a-" (cv message "id")
  else return nil

/-- `Context.label_of_block/1`: `Codec.decode_label/1` then `encode_label/1`.
`Label.new/1` keeps `:public` only when it is the sole atom and `encode_label/1`
sorts, so a readable block answers with the sorted normal form of its own
strings. One unreadable atom makes the whole label fail closed, because a
partially decoded label would be weaker than the one that was stored. -/
def labelOfBlock (ifc : Term) : KernelM Term := do
  let .list xs := ifc.get (b "label") | return privateLabel
  if !xs.all atomString then return privateLabel
  let unique := uniq xs
  let normalized :=
    if unique.isEmpty then [b "public"]
    else if unique.length == 1 then unique
    else unique.filter (· != b "public")
  return list (← sorted normalized)

/-- `Context.element_items/2`: one extra item per labelled element of a
list-shaped tool result, so a single search hit can be cited without dragging
in the rest of the page. -/
def elementItems (ref ifc : Term) : List Term :=
  if !ifc.isMap then [] else
  (wrap (ifc.get (b "items"))).filterMap (fun element =>
    match ref, element.get (b "index"), element.get (b "label") with
    | .binary raw, .integer index, .list labels =>
      if element.isMap && index ≥ 0 then
        some (.map
          [(b "ref", .binary (raw ++ "#".toUTF8 ++ (toString index).toUTF8)),
           (b "label", .list labels),
           (b "integrity", b "data"),
           (b "principal", nil)])
      else none
    | _, _, _ => none)

/-- `Context.ifc_block/2`: the record's own block, else the block sealed onto
its origin by provider ingress, else nothing. -/
def ifcBlock (message trustedOrigin : Term) : Term :=
  if (cv message "ifc").isMap then cv message "ifc"
  else if trustedOrigin.isMap && (iv trustedOrigin "ifc").isMap then iv trustedOrigin "ifc"
  else empty

/-- `Context.entries/1`: one transcript message as one item, plus its elements. -/
def entryOf (message : Term) : KernelM (Option Entry) := do
  let role ← text (cv message "role")
  let trustedOrigin := cv message "trusted_origin"
  let ifc := ifcBlock message trustedOrigin
  let ref ← entryRef role message
  if ref == nil then return none
  -- `"user"` is the session's transport role, not proof of human authorship: a
  -- bot post reaches the transcript in that role too. Ingress has already
  -- classified the sender and sealed the answer, so the seal decides and the
  -- role is only the reading for an input that crossed no labelling funnel.
  let sealed := ifc.get (b "integrity")
  let integrity :=
    if role == b "user" then
      (if sealed.isBinary then (if sealed == b "command" then b "command" else b "data")
       else b "command")
    else b "data"
  let principal ← if role == b "user" then
      (match decodePrincipal (ifc.get (b "principal")) with
       | some named => pure (some named)
       | none => originPrincipal trustedOrigin)
    else pure none
  let label ← labelOfBlock ifc
  let sourceId ← text (cv message "source_message_id")
  let item := Term.map
    [(b "ref", ref),
     (b "source_message_id", sourceId),
     (b "label", label),
     (b "integrity", integrity),
     (b "principal", encodePrincipal principal)]
  return some ⟨ref, integrity, sourceId, item :: elementItems ref ifc⟩

/-- `Context.requester/3`: the sealed origin of the activation, falling back to
the request item's own principal so schedule and internal activations work. -/
def requesterOf (trustedOrigin : Term) (entries : List Entry) (request : Term) :
    KernelM Term := do
  match ← originPrincipal trustedOrigin with
  | some principal => return encodePrincipal (some principal)
  | none =>
    match entries.find? (fun entry => entry.ref == request) with
    | none => return nil
    | some entry =>
      return encodePrincipal (decodePrincipal ((entry.items.head?.getD nil).get (b "principal")))

/-- `Context.build/2` on args `{source_message_id, source_message_ids, trusted_origin}`.
Nothing is filtered: the model sees the whole context, and this exists so that
an effect can be checked against what it says it used. -/
def build (state args : Term) : KernelM Term := do
  let .tuple [currentRaw, sourceIdsRaw, trustedOrigin] := args | fail "function_clause"
  let messages := (wrap (cv state "messages")).filter Term.isMap
  let sourceIds := wrap sourceIdsRaw
  let current ← text currentRaw
  let entries ← messages.foldlM (fun acc message => do
    match ← entryOf message with
    | some entry => return acc ++ [entry]
    | none => return acc) []
  -- An activation with no provider sources consumed nothing, so nothing in the
  -- transcript can be cited as the request it acts on. A direct runtime call
  -- with no human behind it must not inherit the last person who spoke.
  let consumes := fun (entry : Entry) =>
    !sourceIds.isEmpty && sourceIds.any (· == entry.sourceId)
  let consumed := (entries.filter (fun entry =>
    entry.integrity == b "command" && consumes entry)).map Entry.ref
  let request :=
    match entries.find? (fun entry =>
      entry.integrity == b "command" && entry.sourceId == current && current != b "") with
    | some entry => entry.ref
    | none => consumed.getLast?.getD nil
  let currentRef :=
    match entries.find? (fun entry => entry.sourceId == current && current != b "") with
    | some entry => entry.ref
    | none => nil
  let scope := match entries.find? (fun entry => entry.ref == request.default currentRef) with
    | some entry => (entry.items.head?.getD nil).get (b "label")
    | none => privateLabel
  -- Instruction overlays are runtime file reads. They retain the same private
  -- audience as FileBackend.label/2, without entering the transcript.
  let active ← asList (← ReplyQuery.currentSourceMessageIds state)
  let selections := (wrap ((cv state "miniskills").get (b "inputs"))).filter fun input =>
    active.contains (input.get (b "source_message_id"))
  let skills := selections.flatMap fun input => wrap (input.get (b "skills"))
  let overlayItems ← skills.mapM fun skill => do
    return Term.map [(b "ref", ← prefixedRef "src:k-" (skill.get (b "skill_id"))),
      (b "label", privateLabel), (b "integrity", b "data"), (b "principal", nil)]
  return .map
    [(b "items", list (entries.flatMap Entry.items ++ uniq overlayItems)),
     (b "input_refs", (entries.filter consumes).foldl
       (fun acc entry => acc.put entry.sourceId entry.ref) empty),
     (b "requester", ← requesterOf trustedOrigin entries request),
     (b "source_scope", scope),
     (b "consumed_refs", list consumed),
     (b "request", request)]

/-- `Context.organization_scopes/3` on args `{source_message_ids, kind}`:
organization grants on consumed commands, independent of the latest input or
IFC mode. -/
def organizationScopes (state args : Term) : KernelM Term := do
  let .tuple [sourceIdsRaw, kind] := args | fail "function_clause"
  if !kind.isBinary then fail "badarg" [kind]
  let sourceIds := wrap sourceIdsRaw
  let messages := (wrap (cv state "messages")).filter Term.isMap
  let scopes ← messages.foldlM (fun acc message => do
    let origin := (cv message "trusted_origin").default empty
    let role := cv message "role"
    let integrity ← access (← access origin (b "ifc")) (b "integrity")
    if (role == a "user" || role == b "user") &&
        sourceIds.any (· == cv message "source_message_id") && integrity == b "command" then
      let scope ← access origin kind
      if scope.isMap then return acc ++ [scope] else return acc
    return acc) []
  return list (uniq scopes)

/-! ## `SalixAgent.ProjectKnowledgeContext` -/

/-- `activation_ack_id/2`: the acknowledged watermark, else the last user id. -/
def activationAckId (state : Term) (messages : List Term) : KernelM Term := do
  let stored := pv state "last_ack_message_id"
  if stored.truthy then return stored
  maxOr0 (((messages.filter (fun message => pv message "role" == b "user")).map
    (fun message => pv message "id")).filter Term.isInteger)

/-- `activation_user_messages/2`: the user messages of the current activation —
everything after the assistant answer the acknowledged watermark covers, or the
last user message when nothing is acknowledged yet. -/
def activationUserMessages (state : Term) (messages : List Term) : KernelM (List Term) := do
  let ackId ← activationAckId state messages
  if ackId.isInteger && (← greater ackId (i 0)) then
    let answered ← messages.filterM (fun message => do
      let id := pv message "id"
      if !(pv message "role" == b "assistant" && id.isInteger) then return false
      atMost id ackId)
    let previous ← maxOr0 (answered.map (fun message => pv message "id"))
    messages.filterM (fun message => do
      let id := pv message "id"
      if !(pv message "role" == b "user" && id.isInteger) then return false
      if !(← greater id previous) then return false
      atMost id ackId)
  else
    match messages.reverse.find? (fun message => pv message "role" == b "user") with
    | some message => return [message]
    | none => return []

private def messageActivationId (message : Term) : Option Term :=
  match pv message "id" with
  | .integer n => some (.binary ("message:".toUTF8 ++ (toString n).toUTF8))
  | .binary raw => if raw.isEmpty then none else some (.binary ("message:".toUTF8 ++ raw))
  | _ => none

/-- `user_activation_id/1`: the admitted source id, else the message id. -/
def userActivationId (message : Term) : Option Term :=
  match pv message "source_message_id" with
  | .binary raw => if raw.isEmpty then messageActivationId message
      else some (.binary ("source:".toUTF8 ++ raw))
  | _ => messageActivationId message

/-- `fresh_question/1`: `{:ok, question, activation_ids}`, or `:none` when this
activation has no fully identified user question. -/
def freshQuestion (state : Term) : KernelM Term := do
  let messages := wrap (pv state "messages" (list []))
  let userMessages ← activationUserMessages state messages
  if userMessages.isEmpty then return a "none"
  -- Accumulated in reverse: appending to the end once per message is
  -- quadratic in the number of activation messages.
  let collected := userMessages.foldl (fun acc message =>
    match acc with
    | none => none
    | some (questions, ids) =>
      match pv message "content" with
      | .binary raw =>
        let trimmed := trim raw
        if trimmed.isEmpty then none
        else match userActivationId message with
          | some id => some (Term.binary trimmed :: questions, id :: ids)
          | none => none
      | _ => none) (some ([], []))
  match collected with
  | none => return a "none"
  | some (questions, ids) =>
    return .tuple [a "ok", .binary (joinText "\n\n" questions.reverse), list ids.reverse]

/-- `activation_id/2`'s boundary: `next_message_id` is the stable pre-commit
boundary for one model activation, and the transcript head stands in when the
session does not carry one. -/
def activationBoundary (state : Term) : KernelM Term := do
  let stored := pv state "next_message_id"
  if stored.truthy then return stored
  let messages := wrap (pv state "messages" (list []))
  add (← maxOr0 ((messages.map (fun message => pv message "id" (i 0))).filter Term.isInteger))
    (i 1)

/-- `already_committed?/2`. -/
def alreadyCommitted (state args : Term) : KernelM Term := do
  let messages := wrap (pv state "messages" (list []))
  return Term.bool (messages.any (fun message => pv message "runtime_message_id" == args))

/-- Name → operation. Names match the Elixir functions they replace. -/
def table : OpTable :=
  [("ifc_context", build),
   ("ifc_organization_scopes", organizationScopes),
   ("project_knowledge_question", fun state _ => freshQuestion state),
   ("project_knowledge_activation_boundary", fun state _ => activationBoundary state),
   ("project_knowledge_committed?", alreadyCommitted)]

end VerifiedKernel.Session.ProvenanceQuery
