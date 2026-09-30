import VerifiedKernel.Order
import VerifiedKernel.Json
import VerifiedKernel.Session.Metadata

namespace VerifiedKernel.Session
open Data

def queueKeys (event payload kind : Term) : KernelM (List Term) := do
  let common := [← Data.event event "dedupe_key", ← Data.event event "source_message_id", ← Data.event payload "source_message_id"]
  let all ← if kind == b "runtime_message" then do
    pure (common ++ [← Data.event payload "runtime_message_id"])
    else pure common
  return uniq (all.filter (!missing ·))

def validateQueue (kind event : Term) : KernelM Unit := do
  if kind != b "user_message" && kind != b "runtime_message" then
    argumentError "queue_append kind must be user_message or runtime_message"
  let payload ← stringify ((← Data.event event "payload").default empty)
  let keys ← queueKeys event payload kind
  if keys.isEmpty then
    argumentError (if kind == b "user_message" then "user_message queue item requires source_message_id or dedupe_key"
      else "runtime_message queue item requires runtime_message_id or dedupe_key")
  if kind == b "user_message" then
    let payload ← stringify ((← Data.event event "payload").default empty)
    let role := (← Data.event payload "role").default (b "user")
    if role != b "user" && role != b "summary" then
      argumentError "user_message queue item role must be user or summary"
    let payload ← stringify ((← Data.event event "payload").default empty)
    let role := (← Data.event payload "role").default (b "user")
    if role == b "summary" && (← Data.event event "wake") != a "false" then
      argumentError "summary user_message queue item must use wake=false"

def queueItemId (item : Term) : KernelM Term := do
  let binary ← access item (b "queue_id")
  let atom ← access item (a "queue_id")
  return i (integerValue (binary.default atom))

def normalizeQueue (value : Term) : KernelM (List Term) := do
  match value with
  | .list xs =>
    let maps := xs.filter Term.isMap
    let normalized ← maps.mapM shallowStringify
    let positive ← normalized.filterM (fun x => return integerValue (← queueItemId x) > 0)
    sortBy positive queueItemId
  | .improper _ _ => fail "enum_filter_tail"
  | _ => pure []

def queueAppend (state event : Term) : KernelM Term := do
  if !event.has (b "kind") then fail "function_clause"
  let rawKind := event.get (b "kind")
  validateQueue rawKind event
  let kind ← Data.event event "kind"
  let payload ← stringify ((← Data.event event "payload").default empty)
  let keys ← queueKeys event payload rawKind
  let key := (← Data.event event "dedupe_key").default (keys.head?.getD nil)
  let dedupe ← field state "input_dedupe"
  if ← dedupeHit dedupe keys then return state
  let id := (← field state "next_queue_id").default (i 1)
  let wake := Term.bool ((← Data.event event "wake") != a "false")
  let item0 := Term.map [(b "queue_id", id), (b "wake", wake), (b "payload", payload)]
  let item1 ← nonnilPut item0 (b "kind") kind
  let item2 ← nonnilPut item1 (b "dedupe_key") key
  let item ← nonnilPut item2 (b "created_at") (← Data.event event "created_at")
  let queue := (← normalizeQueue (← field state "input_queue")) ++ [item]
  let next ← maximum ((← field state "next_queue_id").default (i 1)) (← add id (i 1))
  let dedupe ← addDedupe dedupe keys
  let activity := (← Data.event event "created_at").default (← field state "last_activity_at")
  write state [("input_queue", list queue), ("next_queue_id", next), ("input_dedupe", dedupe), ("last_activity_at", activity)]

private def collectRefsFuel : Nat → Term → KernelM (List Term)
  | 0, _ => fail "invalid_observation"
  | fuel + 1, value => do
    match value with
    | .map _ =>
      let direct := if value.has (b "result_ref") then value.get (b "result_ref") else value.get (a "result_ref")
      let initial := if direct.isBinary && direct != b "" then [direct] else []
      enumFold value initial (fun acc pair => do
        let .tuple [_, item] := pair | fail "function_clause"
        return acc ++ (← collectRefsFuel fuel item))
    | .list xs => xs.foldlM (fun acc x => return acc ++ (← collectRefsFuel fuel x)) []
    | _ => pure []

def collectRefs (value : Term) : KernelM (List Term) := do
  let journal ← get
  collectRefsFuel (value.depth + 1 + (journal.map Term.depth).foldl (· + ·) 0) value

private def matchAt (haystack needle : ByteArray) (start : Nat) : Nat → Bool
  | 0 => true
  | index + 1 => if haystack[start + index]! == needle[index]! then matchAt haystack needle start index else false

-- Candidate positions come from the compiled byte search for the needle's
-- first byte; comparing the needle at every position cost a long transcript
-- hundreds of milliseconds per scan.
private def searchFrom (haystack needle : ByteArray) (start : Nat) : Nat → Bool
  | 0 => false
  | fuel + 1 =>
    match haystack.findIdx? (· == needle[0]!) start with
    | none => false
    | some pos =>
      if pos + needle.size > haystack.size then false
      else if matchAt haystack needle pos needle.size then true
      else searchFrom haystack needle (pos + 1) fuel

/-- True when `needle` occurs in `haystack`. -/
def containsBytes (haystack needle : ByteArray) : Bool :=
  if needle.size == 0 then true
  else if needle.size > haystack.size then false
  else searchFrom haystack needle 0 (haystack.size + 1)

/-- True when the first byte outside JSON whitespace opens an array or object.
Any other JSON text decodes to a scalar, which holds no reference. -/
private def jsonContainer (bytes : ByteArray) (index : Nat) : Nat → Bool
  | 0 => false
  | remaining + 1 =>
    let byte := bytes[index]!
    if byte == 32 || byte == 9 || byte == 13 || byte == 10 then jsonContainer bytes (index + 1) remaining
    else byte == 123 || byte == 91

/-- A JSON text can only decode to an object with a `result_ref` key when the
key appears literally or through a `\u` escape. Every other escape decodes to
punctuation or a control character, so other texts hold no reference. -/
def mayHoldRef (bytes : ByteArray) : Bool :=
  jsonContainer bytes 0 bytes.size &&
    (containsBytes bytes "result_ref".toUTF8 || containsBytes bytes "\\u".toUTF8)

private def refPrefix : ByteArray := "trf1_".toUTF8

/-- True when a `trf1_` reference in `candidates` occurs literally in `bytes`. -/
private def hasCandidate (bytes : ByteArray) (candidates : Std.HashSet ByteArray) (start : Nat) : Nat → Bool
  | 0 => false
  | fuel + 1 =>
    match bytes.findIdx? (· == refPrefix[0]!) start with
    | none => false
    | some pos =>
      if pos + 24 > bytes.size then false
      else if matchAt bytes refPrefix pos refPrefix.size &&
          (candidates.contains (bytes.extract pos (pos + 24)) || candidates.contains (bytes.extract pos (pos + 25))) then true
      else hasCandidate bytes candidates (pos + 1) fuel

/-- One pass over `bytes` for a `\u` escape or a `trf1_` reference in
`candidates`, stopping at the first hit. -/
private def escapeOrCandidate (bytes : ByteArray) (candidates : Std.HashSet ByteArray) (start : Nat) : Nat → Bool
  | 0 => false
  | fuel + 1 =>
    match bytes.findIdx? (fun byte => byte == 92 || byte == refPrefix[0]!) start with
    | none => false
    | some pos =>
      if bytes[pos]! == 92 then
        if pos + 1 < bytes.size && bytes[pos + 1]! == 117 then true
        else escapeOrCandidate bytes candidates (pos + 1) fuel
      else if pos + 24 ≤ bytes.size && matchAt bytes refPrefix pos refPrefix.size &&
          (candidates.contains (bytes.extract pos (pos + 24)) || candidates.contains (bytes.extract pos (pos + 25))) then true
      else escapeOrCandidate bytes candidates (pos + 1) fuel

/-- Whether decoding `bytes` can yield one of the candidate references. A
decoded JSON string equal to a `trf1_` reference contains it literally unless
a `\u` escape spelled part of it, so a text without either cannot protect a
candidate, and no text protects one of none. Without candidates every
reference matters. -/
private def mayProtect (bytes : ByteArray) : Option (Std.HashSet ByteArray) → Bool
  | none => true
  | some candidates => !candidates.isEmpty && escapeOrCandidate bytes candidates 0 (bytes.size + 1)

private def contentKey (key : Term) : Bool := key == a "content" || key == b "content"

/-- `collectRefs` of `value` without its content keys. When no other value
holds a map or list, only the map's own `result_ref` can be a reference, so
the map is neither copied nor walked. -/
private def otherRefs (value : Term) : KernelM (List Term) :=
  match value with
  | .map entries =>
    if entries.any (fun (key, item) => (item.isMap || item.isList) && !contentKey key) then
      collectRefs (.map (entries.filter (fun (key, _) => !contentKey key)))
    else
      let direct := if value.has (b "result_ref") then value.get (b "result_ref") else value.get (a "result_ref")
      pure (if direct.isBinary && direct != b "" then [direct] else [])
  | _ => collectRefs value

def refsInMessage (value : Term) (candidates : Option (Std.HashSet ByteArray) := none) : KernelM (List Term) := do
  if !value.isMap then return []
  let content := (value.get (a "content")).default (value.get (b "content"))
  let refs ← otherRefs value
  let more ← match content with
    | .binary bytes =>
      if !mayProtect bytes candidates || !mayHoldRef bytes then pure [] else
      -- A resource rejection is not evidence that the text holds no refs.
      -- Abort this projection rather than pruning still-referenced results.
      match candidates with
      -- With candidates only the set of references matters, so a scan that
      -- decodes no other string replaces building the whole value.
      | some _ =>
        match Json.resultRefs bytes with
        | .ok refs => pure refs
        | .error .syntax => pure []
        | .error .resourceBound => fail "invalid_observation"
      | none =>
        match Json.decodeResult bytes with
        | .ok decoded => collectRefs decoded
        | .error .syntax => pure []
        | .error .resourceBound => fail "invalid_observation"
    | .map _ | .list _ => collectRefs content
    | _ => pure []
  return refs ++ more

@[inline] def validId (value : Term) (kind : String) : Bool :=
  match value with
  | .binary bytes =>
    let head := (kind ++ "_").toUTF8
    let body := bytes.extract head.size bytes.size
    bytes.extract 0 head.size == head &&
      (body.size == 19 || (body.size == 20 && body[19]! == 10)) &&
      (body.extract 0 19).toList.all (fun c => c.toNat ≥ 48 && c.toNat ≤ 57)
  | _ => false

def recordRef (record : Term) : KernelM Term := do
  if !record.isMap then fail "function_clause"
  let ref ← alias record (b "result_ref") (a "result_ref")
  if ref.isBinary && ref != b "" then return ref
  alias record (b "tool_call_id") (a "tool_call_id")

/-- Erases the binary references in `refs` from `remaining`. -/
private def eraseRefs (remaining : Std.HashSet ByteArray) (refs : List Term) : Std.HashSet ByteArray :=
  refs.foldl (fun set ref => match ref with | .binary raw => set.erase raw | _ => set) remaining

/-- The candidates that the state protects, for `protectedRefs` with
candidates. It reads the same sources as the general walk, each only for the
candidates still unprotected, and stops once every candidate is protected. A
candidate is a valid `trf1` reference and a key of `async_result_refs`, so the
summary protects it when the summary holds it. -/
private def protectedCandidates (state : Term) (candidates : Std.HashSet ByteArray) :
    KernelM (List Term) := do
  let queue := (← field state "input_queue").default (list [])
  let remaining ← enumFold queue candidates (fun remaining item => do
    let payload := (← Data.event item "payload").default empty
    let id ← alias payload (b "tool_call_id") (b "source_tool_call_id")
    return eraseRefs remaining (id :: (← refsInMessage payload)))
  let wait ← field state "wait"
  let remaining ← if wait.isMap then do
    let ids ← aliases wait [b "tool_call_ids", a "tool_call_ids", b "tool_call_id", a "tool_call_id"]
    pure (eraseRefs remaining (wrap ids))
    else pure remaining
  let messages := (← field state "messages").default (list [])
  let remaining ← if remaining.isEmpty then pure remaining else
    match messages with
    | .improper _ _ => fail "enum_reduce_tail"
    | _ => enumUntil messages remaining (fun remaining message => do
      let calls := (← access message (a "tool_calls")).default (list [])
      let remaining ← enumFold calls remaining (fun remaining call => do
        return eraseRefs remaining [← alias call (b "id") (a "id")])
      let remaining ← if remaining.isEmpty then pure remaining
        else pure (eraseRefs remaining (← refsInMessage message (some remaining)))
      return (!remaining.isEmpty, remaining))
  -- Every stored record is still read, so a malformed one fails as it does
  -- without candidates; the summary check below uses the candidate set.
  let _ ← enumMap ((← field state "async_results").default (list [])) recordRef
  let remaining ← match ← field state "summary" with
    | .binary summary => pure (remaining.fold (fun set ref =>
        if containsBytes summary ref then set.erase ref else set) remaining)
    | _ => pure remaining
  return candidates.fold (fun found ref =>
    if remaining.contains ref then found else .binary ref :: found) []

/-- The references the transcript protects. With `candidates`, the answer is
the candidates that it protects, in no fixed order: `pruneResultRefs` asks only
whether each droppable reference is protected. That search stops once every
candidate is protected, so an item after that point cannot fail it. -/
def protectedRefs (state : Term) (candidates : Option (Std.HashSet ByteArray) := none) : KernelM (List Term) := do
  if let some candidates := candidates then return ← protectedCandidates state candidates
  let queue := (← field state "input_queue").default (list [])
  let queueIds ← enumFold queue [] (fun acc item => do
    let payload := (← Data.event item "payload").default empty
    let id ← alias payload (b "tool_call_id") (b "source_tool_call_id")
    return if id.isBinary then acc ++ [id] else acc)
  let wait ← field state "wait"
  let waitIds ← if wait.isMap then do
    let ids ← aliases wait [b "tool_call_ids", a "tool_call_ids", b "tool_call_id", a "tool_call_id"]
    pure ((wrap ids).filter Term.isBinary)
    else pure []
  let messages := (← field state "messages").default (list [])
  let windowIds ← enumFold messages [] (fun acc message => do
    let calls := (← access message (a "tool_calls")).default (list [])
    enumFold calls acc (fun ids call => do
      let id ← alias call (b "id") (a "id")
      return if id.isBinary then ids ++ [id] else ids))
  let queuedRefs ← enumFold queue [] (fun acc item => do
    let payload := (← Data.event item "payload").default empty
    return acc ++ (← refsInMessage payload))
  -- Accumulate in reverse to avoid copying all earlier references for every message.
  let messageRefs ← enumFold messages [] (fun acc item => return (← refsInMessage item).reverse ++ acc)
  let knownKeys := (← entries ((← field state "async_result_refs").default empty)).map Prod.fst
  let recordRefs ← enumMap ((← field state "async_results").default (list [])) recordRef
  let known := uniq ((knownKeys ++ recordRefs).filter (fun x => validId x "trf1"))
  let summary ← field state "summary"
  let summaryRefs := match summary with
    | .binary bytes => known.filter (fun ref => match ref with
      | .binary needle => containsBytes bytes needle
      | _ => false)
    | _ => []
  return uniq (queueIds ++ waitIds ++ windowIds ++ queuedRefs ++ messageRefs.reverse ++ summaryRefs)

def pruneResultRefs (state : Term) : KernelM Term := do
  let refs := (← field state "async_result_refs").default empty
  let items ← entries refs
  if items.isEmpty then return state
  let compacted := (← field state "compacted_seq").default (i 0)
  -- The droppable references (at or below the compaction point) decide what
  -- the transcript walk must find: a JSON tool result is decoded only when
  -- it can name one of them, and none is when there is nothing to drop.
  let droppable ← items.filterM (fun pair => return !(← greater pair.2 compacted))
  let candidates : Option (Std.HashSet ByteArray) ← pure (
    if droppable.all (fun pair => validId pair.1 "trf1") then
      some (droppable.foldl (fun acc pair =>
        match pair.1 with | .binary raw => acc.insert raw | _ => acc) {})
    else none)
  let protectedIds ← protectedRefs state candidates
  let protectedSet : Std.HashSet ByteArray ← pure (protectedIds.foldl (fun acc ref =>
    match ref with | .binary raw => acc.insert raw | _ => acc) {})
  let kept ← items.filterM (fun pair => do
    if ← greater pair.2 compacted then return true
    return match pair.1 with
      | .binary raw => protectedSet.contains raw
      | other => protectedIds.any (· == other))
  write state [("async_result_refs", .map kept)]

def queueAck (state event : Term) : KernelM Term := do
  let ack ← maximum ((← field state "queue_ack_id").default (i 0)) ((← Data.event event "queue_ack_id").default (i 0))
  let queue ← normalizeQueue (← field state "input_queue")
  let kept ← queue.filterM (fun item => do greater (← queueItemId item) ack)
  pruneResultRefs (← write state [("queue_ack_id", ack), ("input_queue", list kept)])

def queueConsume (state event : Term) : KernelM Term := do
  let id ← get? event (b "queue_id")
  let queue ← normalizeQueue (← field state "input_queue")
  let kept ← queue.filterM (fun item => return !(← queueItemId item).numericEq id)
  pruneResultRefs (← write state [("input_queue", list kept)])

end VerifiedKernel.Session
