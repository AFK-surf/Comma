import VerifiedKernel.Session.Records

/-! The format-1 to format-3 migration ported from
`SalixAgent.InternalSessionFormat3Legacy.normalize/1`. -/

namespace VerifiedKernel.Session.Legacy
open Data

/-- `timestamp/1`: integers order the legacy history, everything else sorts first. -/
def timestampOf (value : Term) : Term := if value.isInteger then value else i 0

private def keyOf (entry : Term) : KernelM Term :=
  match entry with | .tuple [key, _] => pure key | _ => fail "invalid_term"

private def payloadOf (entry : Term) : Option Term :=
  match entry with | .tuple [_, value] => some value | _ => none

/-- The ordered seq references `mapped!/2` resolves, in evaluation order. -/
private def lookups (stamped : List (Term × Term)) (refs redactions : List Term) :
    KernelM (List Term) := do
  let messages ← stamped.foldlM (fun acc pair => do
    match pair.2 with
    | .tuple [.atom "message", record] => do
      let atomSeq ← access record (a "result_seq")
      let textSeq ← access record (b "result_seq")
      let acc := if atomSeq.isInteger then acc ++ [atomSeq] else acc
      return if textSeq.isInteger then acc ++ [textSeq] else acc
    | _ => pure acc) []
  let marked := redactions.filter (fun record =>
    record.isMap && record.has (b "seq") && (record.get (b "seq")).isInteger)
  return messages ++ refs ++ marked.map (fun record => record.get (b "seq"))

/-- `{:ok, state}` or `{:error, {:legacy_normalization_failed, reason}}`. -/
def migrateFormat1 (state : Term) : KernelM Term := do
  if (← field state "storage_format") != i 1 then fail "function_clause"
  let messages ← asList ((← field state "messages").default (list []))
  let events ← asList ((← field state "events").default (list []))
  let boundary := (← field state "compacted_through").default (i 0)
  let covered ← messages.filterM (fun m => do
    atMost ((← access m (a "id")).default (i 0)) boundary)
  let live ← messages.filterM (fun m => do
    return !(← atMost ((← access m (a "id")).default (i 0)) boundary))
  let coveredKeyed ← (indexed covered).mapM (fun pair =>
    return Term.tuple [.tuple [timestampOf (← access pair.2 (a "created_at")), i 0, i pair.1],
      .tuple [a "message", pair.2]])
  let factKeyed ← (indexed events).mapM (fun pair =>
    return Term.tuple [.tuple [timestampOf (← access pair.2 (b "created_at")), i 1, i pair.1],
      .tuple [a "fact", pair.2]])
  let first := (← sortBy (coveredKeyed ++ factKeyed) keyOf).filterMap payloadOf
  -- Terminal async calls become stored results; running ones stay live.
  let calls ← entries ((← field state "async_tool_calls").default empty)
  let isTerminal (pair : Term × Term) : KernelM Bool := do
    let status ← access pair.2 (b "status")
    return status == b "completed" || status == b "failed" || status == b "cancelled"
  let terminated ← calls.filterM isTerminal
  let running ← calls.filterM (fun pair => do return !(← isTerminal pair))
  let legacyResults ← terminated.mapM (fun pair => do
    put (← put pair.2 (b "tool_call_id") pair.1) (b "kind") (b "async_result"))
  let stored ← asList ((← field state "async_results").default (list []))
  let resultKeyed ← (indexed (stored ++ legacyResults)).mapM (fun pair => do
    let when := (← access pair.2 (b "completed_at")).default
      ((← access pair.2 (b "stored_at_ms")).default (i 0))
    let owner := (← access pair.2 (b "tool_call_id")).default (b "")
    return Term.tuple [.tuple [when, owner, i pair.1], pair.2])
  let results := (← sortBy resultKeyed keyOf).filterMap payloadOf
    |>.map (fun record => Term.tuple [a "result", record])
  let liveSorted ← sortBy live (fun m => return (← access m (a "id")).default (i 0))
  let ordered := first ++ results ++ liveSorted.map (fun m => Term.tuple [a "message", m])
  let stamped := (indexed ordered).map (fun pair => (i (Int.ofNat pair.1 + 1), pair.2))
  let oldSeqs ← stamped.foldlM (fun acc pair => do
    let some record := payloadOf pair.2 | fail "invalid_term"
    let seq ← alias record (a "seq") (b "seq")
    return if seq.isInteger then acc ++ [seq] else acc) []
  if (uniq oldSeqs).length != oldSeqs.length then
    return .tuple [a "error", .tuple [a "legacy_normalization_failed", a "duplicate_legacy_seq"]]
  let remap ← stamped.foldlM (fun acc pair => do
    let some record := payloadOf pair.2 | fail "invalid_term"
    let seq ← alias record (a "seq") (b "seq")
    if seq.isInteger then put acc seq pair.1 else pure acc) empty
  let storedRefs ← entries ((← field state "async_result_refs").default empty)
  let redactions ← asList ((← field state "redactions").default (list []))
  let pending ← lookups stamped (storedRefs.map Prod.snd) redactions
  match pending.find? (fun seq => !remap.has seq) with
  | some seq =>
    return .tuple [a "error", .tuple [a "legacy_normalization_failed",
      .tuple [a "missing_legacy_reference", seq]]]
  | none => pure ()
  let split ← stamped.foldlM (fun (acc : List Term × List Term × List Term) pair => do
    let (msgs, facts, records) := acc
    match pair.2 with
    | .tuple [.atom "message", record] => do
      let record ← put record (a "seq") pair.1
      let atomSeq ← access record (a "result_seq")
      let record ← if atomSeq.isInteger then put record (a "result_seq") (remap.get atomSeq)
        else pure record
      let textSeq ← access record (b "result_seq")
      let record ← if textSeq.isInteger then put record (b "result_seq") (remap.get textSeq)
        else pure record
      return (msgs ++ [record], facts, records)
    | .tuple [.atom "fact", record] =>
      return (msgs, facts ++ [← put record (b "seq") pair.1], records)
    | .tuple [.atom "result", record] =>
      return (msgs, facts, records ++ [← put record (b "seq") pair.1])
    | _ => fail "invalid_term") ([], [], [])
  let (msgs, facts, records) := split
  let refs := Term.map (storedRefs.map (fun pair => (pair.1, remap.get pair.2)))
  let remapped ← redactions.mapM (fun record => do
    if record.isMap && record.has (b "seq") && (record.get (b "seq")).isInteger then
      put record (b "seq") (remap.get (record.get (b "seq")))
    else pure record)
  let derived ← events.foldlM (fun acc fact => do
    if (← access fact (b "kind")) != b "session_compact_result" then return acc
    let owner ← access fact (b "source_message_id")
    if owner == nil then return acc
    put acc owner fact) empty
  let stored ← field state "llm_failure_streak"
  let streak ← if stored.truthy then pure stored else do
    let count ← failureCount state
    let hwm ← sub ((← field state "next_message_id").default (i 1)) (i 1)
    let terminal ← terminalFailure state
    pure (Term.map [(b "count", count), (b "hwm", hwm), (b "terminal", Term.bool terminal)])
  let recovery ← field state "last_compaction_recovery"
  let recovery ← if recovery.truthy then pure recovery else
    firstWhere events.reverse
      (fun fact => do return (← access fact (b "kind")) == b "compaction_recovery")
  let merged ← merge derived ((← field state "compact_results").default empty)
  let next ← write state
    [("storage_format", i 3), ("messages", list msgs), ("events", list facts),
     ("async_results", list records), ("async_tool_calls", .map running),
     ("async_result_refs", refs), ("redactions", list remapped),
     ("last_seq", i (Int.ofNat ordered.length)),
     ("compacted_seq", i (Int.ofNat (first.length + results.length))),
     ("archived_through", i 0), ("archive_chunks", list []), ("segment_catalog", list []),
     ("llm_failure_streak", streak), ("last_compaction_recovery", recovery),
     ("compact_results", merged)]
  return .tuple [a "ok", ← rebuildRefs next]

end VerifiedKernel.Session.Legacy
