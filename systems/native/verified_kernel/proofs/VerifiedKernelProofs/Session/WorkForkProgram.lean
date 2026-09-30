import VerifiedKernelProofs.Session.WorkIdentityInitial

namespace VerifiedKernel.Session.WorkConservation
open Data Fork
set_option Elab.async false

/-- This factorization retains the executable fork's order of effects and all constructor fields. -/
def forkFinish (source sessionId attrs : Term) (copy : Bool)
    (messages facts results remapped clamped : List Term)
    (lastSeq lastAck forkThrough nextId created : Term) : KernelM Term := do
  let child ← Lifecycle.normalize (Lifecycle.build
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

def forkSelection (source sessionId attrs maxId : Term) : KernelM Term := do
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
  let ordered ← sortBy window (fun item =>
    match item with | .tuple [_, key, _] => pure key | _ => fail "invalid_term")
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
  forkFinish source sessionId attrs copy messages facts results remapped clamped lastSeq lastAck forkThrough nextId created

theorem current_fork_factor (source sessionId attrs maxId : Term) :
    Fork.currentFork source sessionId attrs maxId = forkSelection source sessionId attrs maxId := rfl

end VerifiedKernel.Session.WorkConservation
