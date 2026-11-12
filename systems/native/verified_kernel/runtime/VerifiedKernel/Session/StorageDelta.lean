import VerifiedKernel.Session.Lifecycle

namespace VerifiedKernel.Session.StorageDelta
open Data

def columnFields : List String :=
  ["name", "hidden", "created_at", "last_activity_at", "storage_revision", "runtime_epoch",
   "last_seq", "compacted_seq", "archived_through", "queue_ack_id", "next_queue_id", "next_message_id"]

def contextFields : List String :=
  ["summary_sequence", "compacted_through", "summary", "provider_compaction", "compaction_failure",
   "system_prompt", "miniskills", "compact_results", "platform", "billing_context", "task_origin",
   "source_agent_id", "source_session_id", "source_schedule_id"]

def controlFields : List String :=
  ["status", "activity_status", "activity_status_updated_at", "activity_revision", "last_ack_message_id",
   "terminal_reply_ack_hwm", "runtime_failure_reply", "visible_reply_repair", "visible_reply_activation_scope",
   "visible_reply_intent", "visible_reply_egress_facts", "provider_reply_obligations", "wait",
   "async_tool_calls", "async_result_refs", "llm_failure_streak", "context_overflow_recovery",
   "runaway_unsettled_streak", "repeated_tool_result_streak", "input_round_streak",
   "active_source_message_ids", "last_compaction_recovery", "fork_request_id", "model", "runtime_node"]

def selected (state : Term) (names : List String) : Term :=
  .map (names.map (fun name => (b name, state.get (a name))))

def changed (before after : Term) (names : List String) (all : Bool) : Term :=
  .map (names.filterMap (fun name =>
    let value := after.get (a name)
    if all || before.get (a name) != value then some (b name, value) else none))

/-- A retained callback owns a record reference and its unsettled capability fields. -/
def calls (state : Term) : KernelM Term := do
  let pairs ← entries ((← field state "async_tool_calls").default empty)
  let refs := (← field state "async_result_refs").default empty
  let pairs ← pairs.mapM (fun (key, call) => do
    let seq := refs.get key
    if terminal call && seq.isInteger then
      let pending := select call ["completion_mode", "capability_request_id", "capability_deadline_ms",
        "capability_retry_at_ms", "capability_sync_failed", "capability_error_since_ms"]
      pure (key, Term.map [(b "record_seq", seq), (b "pending", pending)])
    else pure (key, call))
  return .map pairs

def control (state : Term) : KernelM Term := do
  let projected := selected state controlFields
  return projected.put (b "async_tool_calls") (← calls state)

def mapChanges (before after : Term) (all : Bool) : KernelM Term := do
  let pairs ← entries after
  return .map (pairs.filter (fun (key, value) => all || !before.has key || before.get key != value))

/-- Identity groups use the same order and aliases as their reducers. -/
def identityGroups (event : Term) : KernelM (List (List Term)) := do
  let kind := event.get (b "type")
  if kind == b "queue_append" then
    return [← queueKeys event (← stringify ((event.get (b "payload")).default empty)) (event.get (b "kind"))]
  if kind == b "runtime_message" then
    if event.get (b "from_queue") != a "true" && event.get (b "from_context_provider") != a "true" then return []
    return [← runtimeKeys event]
  if kind == b "delivery" then
    if event.get (b "from_queue") != a "true" then return []
    return [uniq ([event.get (b "source_message_id"), event.get (b "dedupe_key")].filter (· != nil))]
  if kind == b "session_log_message" then
    return [uniq ([event.get (b "source_message_id"), event.get (b "dedupe_key")].filter (!missing ·))]
  if kind == b "transcript_seed" then
    let entries ← asList ((event.get (b "entries")).default (list []))
    return ← entries.mapM (fun entry => do seedKeys (← stringify entry))
  return []

/-- Capture only touched identities after the reducer completes, including aliases
that the stored queue payload does not carry. This value lives in the pending revision. -/
def captureDedupe (before after event : Term) : KernelM (List Term) := do
  let keys := uniq (← identityGroups event).flatten
  let previous := (← field before "input_dedupe").default Lifecycle.emptySet
  let current := (← field after "input_dedupe").default Lifecycle.emptySet
  let keys ← keys.filterM (fun key => do
    return !(← setMember previous key) && (← setMember current key))
  let queueId := if event.get (b "type") == b "queue_append" then
      (before.get (a "next_queue_id")).default (i 1)
    else match event.get (b "accepted_input") with
      | .tuple [queueId, _, _, _] => queueId
      | _ => nil
  return keys.map (fun key => Term.tuple [key, queueId])

def queuePuts (before after : Term) (all : Bool) : KernelM Term := do
  let previous ← normalizeQueue ((← field before "input_queue").default (list []))
  let current ← normalizeQueue ((← field after "input_queue").default (list []))
  let rows ← current.filterM (fun row => do
    if all then return true
    let key ← queueItemId row
    let old ← previous.findM? (fun old => return (← queueItemId old) == key)
    return old != some row)
  return list rows

/-- Exact removals preserve queue-consume holes without advancing the ACK. -/
def queueRemoves (before after : Term) : KernelM Term := do
  let previous ← normalizeQueue ((← field before "input_queue").default (list []))
  let current ← normalizeQueue ((← field after "input_queue").default (list []))
  let keys ← current.mapM queueItemId
  let removed ← previous.filterM (fun row => return !keys.contains (← queueItemId row))
  return list (← removed.mapM queueItemId)

def records (state : Term) (afterSeq : Int) : KernelM Term := do
  let collect (name kind : String) (seqKey : Term) := do
    let rows ← asList ((← field state name).default (list []))
    rows.filterMapM (fun row => do
      let seq := row.get seqKey
      if !seq.isInteger || integerValue seq ≤ afterSeq then return none
      let kind := if name == "async_results" then (row.get (b "kind")).default (b kind) else b kind
      let payload ← remove (← remove row (a "seq")) (b "seq")
      let identity := if kind == b "message" then (row.get (a "id")).default (row.get (b "id"))
        else if kind == b "tool_result" then row.get (b "result_ref")
        else if kind == b "async_result" then row.get (b "tool_call_id") else nil
      return some (Term.map [(b "seq", seq), (b "kind", kind), (b "record_id", identity), (b "payload", payload)]))
  let messages ← collect "messages" "message" (a "seq")
  let facts ← collect "events" "fact" (b "seq")
  let results ← collect "async_results" "async_result" (b "seq")
  return list (← sortBy (messages ++ facts ++ results) (fun row => pure (row.get (b "seq"))))

/-- The part of `current` after the prefix it shares with `previous`. -/
def afterShared : List Term → List Term → List Term
  | x :: xs, y :: ys => if x == y then afterShared xs ys else y :: ys
  | _, current => current

/-- The catalog is ordered by first seq and an archive advance adds later segments,
so a fence that publishes nothing compares each entry once rather than searching
the whole catalog for it. -/
def archiveAdds (before after : Term) (all : Bool) : KernelM Term := do
  let previous := wrap ((← field before "segment_catalog").default (list []))
  let current := wrap ((← field after "segment_catalog").default (list []))
  if all then return list current
  return list ((afterShared previous current).filter (fun entry => !previous.contains entry))

/-- Rebuild the provider projection from committed assistant boundaries and keep
only live input identities as a positive cache. -/
def committedView (state : Term) : KernelM Term := do
  let queue := wrap ((← field state "input_queue").default (list []))
  let keys ← queue.foldlM (fun keys item => do
    return keys ++ (← Lifecycle.queueDedupeKeys item)) []
  let cache ← addDedupe Lifecycle.emptySet (uniq (keys.filter (!missing ·)))
  let migration ← Lifecycle.migrationStates state
  let providers ← Lifecycle.retainedProviderStates state migration
  write state [("input_dedupe", cache), ("context_provider_states", providers)]

/-- This projection grants no authority to delete hot records or publish archives. -/
def project (before after : Term) (all : Bool) (dedupeAdd : List Term) : KernelM Term := do
  let beforeControl ← control before
  let afterControl ← control after
  let context := selected after contextFields
  let context := if all || selected before contextFields != context then context else nil
  let sources := (← field after "conversation_sources").default empty
  let previousSources := (← field before "conversation_sources").default empty
  let initialDedupe ← if all then do
      let members ← Lifecycle.dedupeMembers (← field before "input_dedupe")
      pure (members.map (fun key => Term.tuple [key, nil]))
    else pure []
  let removed ← if all then pure (list []) else queueRemoves before after
  let baselineSeq ← field before "last_seq"
  let appended ← records after (if all then 0 else integerValue baselineSeq)
  return .map [(b "kind", if all then b "create" else b "update"),
    (b "columns", changed before after columnFields all),
    (b "control_put", ← mapChanges beforeControl afterControl all),
    (b "context", context), (b "inputs_put", ← queuePuts before after all),
    (b "inputs_remove", removed),
    (b "dedupe_add", list (initialDedupe ++ dedupeAdd)),
    (b "sources_put", ← mapChanges previousSources sources all),
    (b "records", appended),
    (b "archives_add", ← archiveAdds before after all)]

end VerifiedKernel.Session.StorageDelta
