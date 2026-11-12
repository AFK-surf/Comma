import VerifiedKernel.Session.TranscriptCore
import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Async
import VerifiedKernel.Grapheme

namespace VerifiedKernel.Session
open Data

def compactedSequence (state through pinned : Term) : KernelM Term := do
  let candidate ← if pinned.isInteger then pure pinned else do
    let found ← enumFind ((← field state "messages").default (list [])) (fun message => do
      if ← greater ((← access message (a "id")).default (i 0)) through then
        return (← access message (a "seq")).isInteger
      return false)
    if found.has (a "seq") then sub (found.get (a "seq")) (i 1)
    else if found == nil then pure ((← field state "last_seq").default (i 0))
    else fail "case_clause" [found]
  minimum (← maximum candidate ((← field state "compacted_seq").default (i 0))) ((← field state "last_seq").default (i 0))

def pruneCompactResults (state : Term) : KernelM Term := do
  let results := (← field state "compact_results").default empty
  let pairs ← entries results
  if pairs.isEmpty then return state
  let manual := pairs.filter (fun pair => !pair.1.isInteger)
  let keyed := pairs.filter (fun pair => pair.1.isInteger)
  let kept ← keyed.filterM (fun pair => do greater pair.1 ((← field state "compacted_through").default (i 0)))
  let sorted ← sortBy (manual.map (fun pair => .tuple [pair.1, pair.2])) (fun pair => do
    let .tuple [_, fact] := pair | fail "function_clause"
    let seq ← Data.event fact "seq"
    let created ← Data.event fact "created_at"
    return seq.default (created.default (i 0))) true
  let recent := sorted.take 8 |>.filterMap (fun pair => match pair with | .tuple [key, value] => some (key, value) | _ => none)
  let result := (kept ++ recent).foldl (fun acc pair => acc.put pair.1 pair.2) empty
  write state [("compact_results", result)]

def recomputeContext (state : Term) : KernelM Term := do write state [("live_context_bytes", ← recomputeBytes state)]

def historyCompaction (state event : Term) (provider : Bool) : KernelM Term := do
  let baseline ← Data.event event "summary_sequence"
  if baseline.isInteger then
    if ← atMost baseline ((← field state "summary_sequence").default (i 0)) then return state
  let through := (← Data.event event "compacted_through").default (← field state "compacted_through")
  let providerRecord := if provider then
      let selected := select event ["provider", "protocol", "strategy", "items", "compacted_through", "created_at"]
      present (if selected.has (b "strategy") then selected else selected.put (b "strategy") (b "openai_responses"))
    else nil
  let summary ← if provider then pure nil else pure ((← Data.event event "summary").default (← field state "summary"))
  let sequence ← if baseline.truthy then pure baseline else add (← field state "summary_sequence") (i 1)
  let compacted ← write state [("summary_sequence", sequence), ("compacted_through", through),
    ("compacted_seq", ← compactedSequence state through (← Data.event event "compacted_seq")),
    ("summary", summary), ("provider_compaction", providerRecord), ("compaction_failure", nil)]
  let timed ← if provider then write compacted [("last_activity_at", metadataSeconds ((← Data.event event "created_at").default (← field state "last_activity_at")))] else pure compacted
  recomputeContext (← pruneCompactResults (← pruneResultRefs timed))

def compactResult (state event : Term) : KernelM Term := do
  let base := present ((select event ["source_message_id", "status", "reason", "created_at"]).put (b "kind") (b "session_compact_result"))
  let seq ← add ((← field state "last_seq").default (i 0)) (i 1)
  let fact := base.put (b "seq") seq
  let results := (← field state "compact_results").default empty
  let id ← Data.event fact "source_message_id"
  let nextResults ← if id == nil then pure results else put results id fact
  let next ← write state [("events", ← append ((← field state "events").default (list [])) (list [fact])),
    ("last_seq", seq), ("llm_failure_streak", nil), ("compact_results", nextResults),
    ("last_activity_at", metadataSeconds ((← Data.event event "created_at").default (← field state "last_activity_at")))]
  pruneCompactResults next

def validSegment : Term → Bool
  | .list [.integer first, .integer last, .integer messages, .integer uncomp] =>
    first > 0 && last ≥ first && messages ≥ 0 && messages ≤ last - first + 1 && uncomp > 0
  | _ => false

def archiveAdvance (state event : Term) : KernelM Term := do
  let through ← Data.event event "archived_through"
  let segments ← Data.event event "segments"
  if !segments.isList || !through.isInteger then return state
  if !(← greater through ((← field state "archived_through").default (i 0))) then return state
  if !(← atMost through ((← field state "last_seq").default (i 0))) then return state
  let released := i (min (integerValue through)
    (integerValue ((state.get (a "compacted_seq")).default (i 0))))
  let parsed := (wrap segments).filter validSegment
  let catalog ← sortBy parsed (fun entry => pure ((wrap entry).head?.getD nil))
  let messages ← enumMap ((← field state "messages").default (list [])) pure
  let messages ← messages.filterM (fun message => do
    let seq ← access message (a "seq")
    if seq.isInteger then greater seq released else pure true)
  let events ← enumMap ((← field state "events").default (list [])) pure
  let events ← events.filterM (fun fact => do
    let seq ← Data.event fact "seq"
    if seq.isInteger then greater seq released else pure true)
  let results ← enumMap ((← field state "async_results").default (list [])) pure
  let results ← results.filterM (fun record => do greater (← Data.event record "seq") released)
  let advanced ← write state [("archived_through", through), ("segment_catalog", list catalog),
    ("messages", list messages), ("events", list events), ("async_results", list results)]
  recomputeContext (← pruneResultRefs advanced)

def validStoredResult (event : Term) : KernelM Bool := do
  let json ← Data.event event "result_json"
  let bytes ← Data.event event "result_bytes"
  let chars ← Data.event event "result_chars"
  let hash ← Data.event event "result_sha256"
  let time ← Data.event event "stored_at_ms"
  if !validId (← Data.event event "session_id") "ses1" || !validId (← Data.event event "result_ref") "trf1" then return false
  for name in ["tool_call_id", "tool_name"] do
    let value ← Data.event event name
    if !value.isBinary || missing value then return false
    if let .binary raw := value then
      if (String.fromUTF8? raw).isNone then return false
  let .binary raw := json | return false
  let some text := String.fromUTF8? raw | return false
  if bytes != i raw.size then return false
  if chars != i (Grapheme.countString text) then return false
  let .binary digestBytes := hash | return false
  if digestBytes.size != 64 then return false
  if hash != .binary (hex (← digest raw)) then return false
  let status ← Data.event event "status"
  let .binary statusBytes := status | return false
  if (String.fromUTF8? statusBytes).isNone || missing status then return false
  return (← Data.event event "is_error").isBoolean && time.isInteger && integerValue time ≥ 0

def storedResult (state event : Term) : KernelM Term := do
  if !(← validStoredResult event) then return state
  if (← resolveResult state (← Data.event event "result_ref")) != a "not_found" then return state
  let base := select event ["result_ref", "tool_call_id", "tool_name", "result_json", "result_sha256", "result_bytes", "result_chars",
    "status", "is_error", "ifc", "stored_at_ms"]
  let seq ← add ((← field state "last_seq").default (i 0)) (i 1)
  let record := base.put (b "kind") (b "tool_result") |>.put (b "seq") seq
  let results ← append ((← field state "async_results").default (list [])) (list [record])
  let ref ← Data.event event "result_ref"
  let refs ← put ((← field state "async_result_refs").default empty) ref seq
  write state [("async_results", results), ("async_result_refs", refs), ("last_seq", seq),
    ("last_activity_at", i (integerValue (← Data.event event "stored_at_ms") / 1000))]

def storedResultFields : List String :=
  ["result_ref", "tool_call_id", "tool_name", "result_json", "result_sha256", "result_bytes", "result_chars",
    "status", "is_error", "ifc", "stored_at_ms"]

/-- Only live pointers may request immutable archived result bodies. -/
def storedResultRequests (state : Term) (events : List Term) : KernelM Term := do
  let requests ← events.foldlM (fun requests raw => do
    let event ← shallowStringify raw
    if event.get (b "type") != b "tool_result_stored" then return requests
    let ref := event.get (b "result_ref")
    match ← resolveResult state ref with
    | .tuple [.atom "archived", seq] => pure (.tuple [ref, seq] :: requests)
    | _ => pure requests) []
  return list (uniq requests.reverse)

def validateStoredResults (state facts : Term) (events : List Term) (seen : Term := empty) : KernelM Term := do
  match events with
  | [] => pure (a "ok")
  | raw :: rest =>
    let event ← shallowStringify raw
    let kind := event.get (b "type")
    if (kind == b "tool_result_stored" || kind == a "tool_result_stored") &&
        event.get (b "session_id") != (← field state "session_id") then
      return .tuple [a "error", a "session_id_mismatch"]
    if kind != b "tool_result_stored" then return ← validateStoredResults state facts rest seen
    let ref := event.get (b "result_ref")
    let resolved ← if seen.has ref then pure (.tuple [a "seen", seen.get ref]) else resolveResult state ref
    let existing ← match resolved with
      | .tuple [.atom "ok", record] =>
        if record.get (b "kind") != b "tool_result" then
          pure (.tuple [a "error", a "tool_result_ref_conflict"])
        else pure record
      | .tuple [.atom "archived", seq] =>
        let found := (wrap facts).find? (fun fact => match fact with
          | .tuple [key, position, _] => key == ref && position == seq
          | _ => false)
        match found with
        | some (.tuple [_, _, record]) =>
          if record.get (b "kind") == b "tool_result" then pure record
          else pure (.tuple [a "error", a "tool_result_ref_conflict"])
        | _ => pure (.tuple [a "error", a "not_found"])
      | .tuple [.atom "seen", record] => pure record
      | _ => pure nil
    match existing with
    | .tuple [.atom "error", _] => return existing
    | _ => pure ()
    if existing != nil then
      if select (← shallowStringify existing) storedResultFields != select event storedResultFields then
        return .tuple [a "error", a "tool_result_ref_conflict"]
    validateStoredResults state facts rest (seen.put ref (if existing == nil then event else existing))

def recordAdmissionTable : OpTable :=
  [("stored_result_requests", fun state args => do storedResultRequests state (← asList args)),
   ("validate_stored_results", fun state args => do
     let .tuple [.list events, facts] := args | fail "function_clause"
     validateStoredResults state facts events)]

end VerifiedKernel.Session
