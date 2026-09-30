import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Lifecycle

/-! Forking ported from `SalixAgent.InternalSession.State.fork_from/3` and
`fork_inline_result_seqs/2`. -/

namespace VerifiedKernel.Session.Fork
open Data
open Lifecycle (build maxStamped normalize)

/-- `fork_window_messages/2`: stamped messages above the compaction watermark, up to the cutoff. -/
def windowMessages (source maxId : Term) : KernelM (List Term) := do
  let compacted := (← field source "compacted_seq").default (i 0)
  let messages ← asList ((← field source "messages").default (list []))
  messages.filterM (fun message => do
    let seq ← access message (a "seq")
    if !seq.isInteger then return false
    if !(← greater seq compacted) then return false
    if !maxId.isInteger then return true
    atMost ((← access message (a "id")).default (i 0)) maxId)

/-- `copy_compaction_to_fork?/2`. -/
def copyCompaction (source maxId : Term) : KernelM Bool := do
  let through := (← field source "compacted_through").default (i 0)
  if !(← greater through (i 0)) then return false
  if maxId.isInteger && (← less maxId through) then return false
  return true

/-- `fork_last_ack_message_id/2`. -/
def forkLastAck (lastAck maxId : Term) : KernelM Term := do
  if maxId.isInteger then minimum (lastAck.default (i 0)) maxId else pure (lastAck.default (i 0))

/-- `next_message_id_from_messages/1` for a list. -/
def nextMessageId (messages : List Term) : KernelM Term := do
  let ids ← messages.mapM (fun message => do
    return (← access message (a "id")).default ((← access message (b "id")).default (i 0)))
  kmax (← add (← largest ids (i 0)) (i 1)) (i 1)

/-- `fork_input_dedupe/1`: the keys of the records that actually travelled. -/
def forkDedupe (messages : List Term) : KernelM Term := do
  let keys ← messages.foldlM (fun acc message => do
    if !message.isMap then return acc
    return acc ++ [← access message (a "source_message_id"), ← access message (b "source_message_id"),
      ← access message (a "dedupe_key"), ← access message (b "dedupe_key"),
      ← access message (a "runtime_message_id"), ← access message (b "runtime_message_id")]) []
  let kept := uniq (keys.filter (!missing ·))
  return .map [(a "__struct__", a "Elixir.MapSet"),
    (a "map", .map (kept.map (fun key => (key, list []))))]

/-- `fork_selected_tool_result_refs/4`: only the selected transcript or an inspectable
summary may name a carried result. -/
def selectedRefs (source : Term) (windowMsgs : List Term) (copy : Bool) (known : List Term) :
    KernelM (List Term) := do
  let messageRefs ← windowMsgs.foldlM (fun acc message =>
    return acc ++ (← refsInMessage message)) []
  let summary ← field source "summary"
  let summaryRefs := if !copy then [] else
    match summary with
    | .binary bytes => known.filter (fun ref =>
      match ref with | .binary needle => containsBytes bytes needle | _ => false)
    | _ => []
  return uniq (messageRefs ++ summaryRefs)

/-- `carried_live_results/5`: records at or below the watermark that the fork still references. -/
def carriedResults (source attrs compacted : Term) (windowMsgs : List Term) (copy : Bool) :
    KernelM (List Term) := do
  let inline ← asList ((← alias attrs (a "inline_results") (b "inline_results")).default (list []))
  let stored ← asList ((← field source "async_results").default (list []))
  let bySeq ← (stored ++ inline).foldlM (fun acc record => do
    let seq ← access record (b "seq")
    if seq.isInteger then put acc seq record else pure acc) empty
  let records ← entries bySeq
  let toolRecords := (records.map Prod.snd).filter toolResultRecord
  let knownRefs ← toolRecords.mapM recordRef
  let known := knownRefs.filter (fun ref => validId ref "trf1")
  let selected ← selectedRefs source windowMsgs copy known
  let stamps ← entries ((← field source "async_result_refs").default empty)
  let legacySeqs := (stamps.filter (fun pair =>
    !validId pair.1 "trf1" && !toolResultRecord (bySeq.get pair.2))).map Prod.snd
  let selectedSeqs ← records.foldlM (fun acc pair => do
    if !toolResultRecord pair.2 then return acc
    let ref ← recordRef pair.2
    return if selected.any (· == ref) then acc ++ [pair.1] else acc) []
  let runtimeSeqs ← windowMsgs.mapM (fun message => alias message (a "result_seq") (b "result_seq"))
  let referenced := legacySeqs ++ selectedSeqs ++ runtimeSeqs
  let filtered ← referenced.filterM (fun seq => do
    return seq.isInteger && (← atMost seq compacted))
  return ((uniq filtered).map bySeq.get).filter Term.isMap

/-- `renumber/1`: dense renumbering from 1 with the source-to-fork seq map. -/
def renumber (items : List Term) :
    KernelM (List Term × List Term × List Term × Term × Term) :=
  items.foldlM (fun (acc : List Term × List Term × List Term × Term × Term) item => do
    let (messages, facts, results, remap, n) := acc
    let .tuple [kind, original, record] := item | fail "invalid_term"
    let seq ← add n (i 1)
    let remap ← put remap original seq
    if kind == a "message" then
      return (messages ++ [← put record (a "seq") seq], facts, results, remap, seq)
    else if kind == a "fact" then
      return (messages, facts ++ [← put record (b "seq") seq], results, remap, seq)
    else
      return (messages, facts, results ++ [← put record (b "seq") seq], remap, seq))
    ([], [], [], empty, i 0)

/-- `remap_runtime_result_seq/2`: a pointer whose exact target travelled is remapped,
a missing target is dropped. -/
def remapRuntimeSeq (message remap : Term) : KernelM Term := do
  let atomSeq ← access message (a "result_seq")
  if atomSeq.isInteger then
    if remap.has atomSeq then return ← put message (a "result_seq") (remap.get atomSeq)
    return ← remove message (a "result_seq")
  let textSeq ← access message (b "result_seq")
  if textSeq.isInteger then
    if remap.has textSeq then return ← put message (b "result_seq") (remap.get textSeq)
    return ← remove message (b "result_seq")
  return message

private def entryKey (item : Term) : KernelM Term :=
  match item with | .tuple [_, key, _] => pure key | _ => fail "invalid_term"

/-- `current_fork/4`: the format-2/3 fork contract. -/
def currentFork (source sessionId attrs maxId : Term) : KernelM Term := do
  let compacted := (← field source "compacted_seq").default (i 0)
  let windowMsgs ← windowMessages source maxId
  let cutoff ←
    if !maxId.isInteger then pure ((← field source "last_seq").default (i 0))
    else if windowMsgs.isEmpty then pure compacted
    else largest (← windowMsgs.mapM (fun message => access message (a "seq"))) (i 0)
  let inWindow (record key : Term) : KernelM Bool := do
    let seq ← access record key
    return (← greater seq compacted) && (← atMost seq cutoff)
  let windowEvents ← (← asList ((← field source "events").default (list []))).filterM
    (fun fact => inWindow fact (b "seq"))
  let windowResults ← (← asList ((← field source "async_results").default (list []))).filterM
    (fun record => inWindow record (b "seq"))
  let copy ← copyCompaction source maxId
  let carried ← carriedResults source attrs compacted windowMsgs copy
  let window := windowMsgs.map (fun m => Term.tuple [a "message", m.get (a "seq"), m]) ++
    windowEvents.map (fun e => Term.tuple [a "fact", e.get (b "seq"), e]) ++
    windowResults.map (fun r => Term.tuple [a "async_result", r.get (b "seq"), r])
  let ordered ← sortBy window entryKey
  let carriedSorted ← sortBy carried (fun record => access record (b "seq"))
  let tail := carriedSorted.map (fun r => Term.tuple [a "async_result", r.get (b "seq"), r])
  let (messages, facts, results, remap, lastSeq) ← renumber (ordered ++ tail)
  let messages ← messages.mapM (fun message => remapRuntimeSeq message remap)
  let through := (← field source "compacted_through").default (i 0)
  let maxCopied ← largest (← messages.mapM (fun message => do
    return (← access message (a "id")).default (i 0))) through
  let redactions ← asList ((← field source "redactions").default (list []))
  let remapped ← redactions.foldlM (fun acc entry => do
    let next := remap.get (← access entry (b "seq"))
    if next.isInteger then return acc ++ [← put entry (b "seq") next] else pure acc) []
  let clamped ← redactions.foldlM (fun acc entry => do
    let kind ← access entry (b "kind")
    if kind != b "tool_messages_through" && kind != b "non_model_messages_over_bytes_through" then
      return acc
    let value ← minimum ((← access entry (b "through_id")).default (i 0)) maxCopied
    if ← greater value (i 0) then return acc ++ [← put entry (b "through_id") value] else pure acc) []
  let lastAck ← forkLastAck (← field source "last_ack_message_id") maxId
  let forkThrough ← if copy then pure through else pure (i 0)
  let nextId ← largest [← nextMessageId messages, ← add forkThrough (i 1), ← add lastAck (i 1)] (i 0)
  let created ← alias attrs (b "created_at") (a "created_at")
  let child ← normalize (build
    [("agent_id", ← field source "agent_id"), ("session_id", sessionId), ("storage_format", i 3),
     ("name", (← alias attrs (b "name") (a "name")).default (b "Fork")),
     ("hidden", Term.bool ((← access attrs (b "hidden")) == a "true" ||
       (← access attrs (a "hidden")) == a "true")),
     ("created_at", created), ("last_activity_at", created), ("status", a "idle"),
     ("activity_status", a "paused"), ("activity_status_updated_at", created),
     ("last_ack_message_id", lastAck), ("queue_ack_id", i 0), ("next_queue_id", i 1),
     ("input_queue", list []), ("next_message_id", nextId),
     ("input_dedupe", ← forkDedupe messages),
     ("summary_sequence", ← if copy then field source "summary_sequence" else pure (i 0)),
     ("compacted_through", forkThrough),
     ("summary", ← if copy then field source "summary" else pure nil),
     ("provider_compaction", ← if copy then field source "provider_compaction" else pure nil),
     ("visible_reply_repair", nil), ("visible_reply_activation_scope", nil),
     ("visible_reply_intent", nil), ("visible_reply_egress_facts", empty),
     ("provider_reply_obligations", empty), ("messages", list messages), ("events", list facts),
     ("async_results", list results), ("wait", nil), ("async_tool_calls", empty),
     ("work_index_token", nil), ("work_index_reasons", list []),
     ("platform", ← field source "platform"),
     ("billing_context", (← field source "billing_context").default empty),
     ("task_origin", ← field source "task_origin"),
     ("source_agent_id", ← field source "agent_id"),
     ("source_session_id", ← field source "session_id"),
     ("source_schedule_id", ← field source "source_schedule_id"),
     ("system_prompt", ← if copy then field source "system_prompt" else pure nil),
     ("context_provider_states", empty), ("last_seq", lastSeq), ("compacted_seq", i 0),
     ("archived_through", i 0), ("archive_chunks", list []),
     ("redactions", list (remapped ++ clamped)), ("llm_failure_streak", nil), ("context_overflow_recovery", nil),
     ("fork_request_id", ← alias attrs (b "fork_request_id") (a "fork_request_id"))])
  rebuildRefs child

/-- `legacy_fork_from/4`: the whole-copy selection for a format-1 source. -/
def legacyFork (source sessionId attrs maxId : Term) : KernelM Term := do
  let messages ←
    if maxId.isInteger then do
      let all ← asList (← field source "messages")
      let kept ← all.filterM (fun message => do
        atMost ((← access message (a "id")).default (i 0)) maxId)
      pure (list kept)
    else field source "messages"
  let copy ← copyCompaction source maxId
  let created ← alias attrs (b "created_at") (a "created_at")
  let nextId ← match messages with | .list xs => nextMessageId xs | _ => pure (i 1)
  normalize (build
    [("agent_id", ← field source "agent_id"), ("session_id", sessionId),
     ("name", (← alias attrs (b "name") (a "name")).default (b "Fork")),
     ("hidden", Term.bool ((← access attrs (b "hidden")) == a "true" ||
       (← access attrs (a "hidden")) == a "true")),
     ("created_at", created), ("last_activity_at", created), ("status", a "idle"),
     ("activity_status", a "paused"), ("activity_status_updated_at", created),
     ("last_ack_message_id", ← forkLastAck (← field source "last_ack_message_id") maxId),
     ("queue_ack_id", i 0), ("next_queue_id", i 1), ("input_queue", list []),
     ("next_message_id", nextId), ("input_dedupe", ← forkDedupe (wrap messages)),
     ("summary_sequence", ← if copy then field source "summary_sequence" else pure (i 0)),
     ("compacted_through", ← if copy then field source "compacted_through" else pure (i 0)),
     ("summary", ← if copy then field source "summary" else pure nil),
     ("provider_compaction", ← if copy then field source "provider_compaction" else pure nil),
     ("visible_reply_repair", nil), ("visible_reply_activation_scope", nil),
     ("visible_reply_intent", nil), ("visible_reply_egress_facts", empty),
     ("provider_reply_obligations", empty), ("messages", messages),
     ("events", (← field source "events").default (list [])), ("wait", nil),
     ("async_tool_calls", empty), ("work_index_token", nil), ("work_index_reasons", list []),
     ("platform", ← field source "platform"),
     ("billing_context", (← field source "billing_context").default empty),
     ("task_origin", ← field source "task_origin"),
     ("source_agent_id", ← field source "agent_id"),
     ("source_session_id", ← field source "session_id"),
     ("source_schedule_id", ← field source "source_schedule_id"),
     ("system_prompt", ← if copy then field source "system_prompt" else pure nil),
     ("context_provider_states", empty),
     ("storage_format", (← field source "storage_format").default (i 1)),
     ("last_seq", ← maxStamped messages ((← field source "events").default (list [])) (list [])),
     ("compacted_seq", i 0), ("archived_through", i 0), ("archive_chunks", list []),
     ("async_results", list []), ("async_result_refs", empty), ("redactions", list []),
     ("llm_failure_streak", nil), ("context_overflow_recovery", nil),
     ("fork_request_id", ← alias attrs (b "fork_request_id") (a "fork_request_id"))])

/-- `fork_from(source, session_id, attrs)` on args `{session_id, attrs}`:
`{:ok, state}` or `{:error, :fork_cutoff_below_compaction}`. -/
def fork (source args : Term) : KernelM Term := do
  let .tuple [sessionId, attrs] := args | fail "function_clause"
  let maxId ← alias attrs (b "message_id") (a "message_id")
  let format ← field source "storage_format"
  if format.isInteger && integerValue format ≥ 2 then
    if maxId.isInteger &&
        (← less maxId ((← field source "compacted_through").default (i 0))) then
      return .tuple [a "error", a "fork_cutoff_below_compaction"]
    return .tuple [a "ok", ← currentFork source sessionId attrs maxId]
  -- A legacy fork copies the transcript but no result store, so private
  -- pointers to absent records must not travel.
  let child ← legacyFork source sessionId attrs maxId
  let messages ← asList (← field child "messages")
  let dropped ← messages.mapM (fun message => do
    remove (← remove message (a "result_seq")) (b "result_seq"))
  Legacy.migrateFormat1 (← write child [("messages", list dropped)])

/-- `fork_inline_result_seqs(source, attrs)` on args `attrs`: a sorted list of seqs. -/
def inlineResultSeqs (source args : Term) : KernelM Term := do
  let format ← field source "storage_format"
  if !(format.isInteger && integerValue format ≥ 2 && args.isMap) then return list []
  let maxId ← alias args (b "message_id") (a "message_id")
  if maxId.isInteger && (← less maxId ((← field source "compacted_through").default (i 0))) then
    return list []
  let archived := (← field source "archived_through").default (i 0)
  let windowMsgs ← windowMessages source maxId
  let copy ← copyCompaction source maxId
  let stamps ← entries ((← field source "async_result_refs").default empty)
  let known := (stamps.map Prod.fst).filter (fun ref => validId ref "trf1")
  let selected ← selectedRefs source windowMsgs copy known
  let legacySeqs := (stamps.filter (fun pair => !validId pair.1 "trf1")).map Prod.snd
  let selectedSeqs := (stamps.filter (fun pair => selected.any (· == pair.1))).map Prod.snd
  let runtimeSeqs ← windowMsgs.mapM (fun message =>
    alias message (a "result_seq") (b "result_seq"))
  let candidates ← (legacySeqs ++ selectedSeqs ++ runtimeSeqs).filterM (fun seq => do
    return seq.isInteger && (← greater seq (i 0)) && (← atMost seq archived))
  return list (← sorted (uniq candidates))

/-- `fork` is a lifecycle operation whose `{:ok, state}` result the dispatcher unwraps;
`fork_inline_result_seqs` is a query. -/
def lifecycleTable : OpTable := [("fork", fork)]
def queryTable : OpTable := [("fork_inline_result_seqs", inlineResultSeqs)]

end VerifiedKernel.Session.Fork
