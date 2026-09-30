import VerifiedKernel.Data
import VerifiedKernel.Inspect

namespace VerifiedKernel.Session
open Data

def argumentError (message : String) : KernelM α := fail "argument" [b message]

def inspectedError (textPrefix : String) (value : Term) : KernelM α := do
  fail "argument" [b (textPrefix ++ Inspect.render value)]

def statusTransition (state event : Term) : KernelM Term := do
  if !event.has (b "status") then return state
  let status := event.get (b "status")
  if status == nil || status == a "idle" || status == b "idle" then
    write state [("status", a "idle")]
  else if status == a "active" || status == b "active" then
    write state [("status", a "active"), ("activity_status", a "thinking")]
  else inspectedError "invalid internal session status " status

def activityTransition (state event : Term) : KernelM Term := do
  if state.get (a "status") != a "active" || !event.has (b "activity_status") then return state
  let status := event.get (b "activity_status")
  match ["thinking", "execution", "messaging"].find? (fun name => status == a name || status == b name) with
  | some name => write state [("activity_status", a name)]
  | none => inspectedError "invalid internal session activity status " status

def metadataCreated (state event : Term) : KernelM Term := do
  let name := (event.get (b "name")).default ((← field state "name").default (b "Default"))
  let hidden := event.get (b "hidden")
  let hidden ← if hidden.isBoolean then pure hidden else field state "hidden"
  let created := (← field state "created_at").default (event.get (b "created_at"))
  let activity := (← field state "last_activity_at").default (event.get (b "created_at"))
  let _ ← field state "status"
  let activityAt := (← field state "activity_status_updated_at").default (event.get (b "created_at"))
  let platform := (event.get (b "platform")).default (← field state "platform")
  let billing := (event.get (b "billing_context")).default ((← field state "billing_context").default empty)
  let origin := (event.get (b "task_origin")).default (← field state "task_origin")
  let source := (event.get (b "source_session_id")).default (← field state "source_session_id")
  let schedule := (event.get (b "source_schedule_id")).default (← field state "source_schedule_id")
  write state [("name", name), ("hidden", hidden), ("created_at", created),
    ("last_activity_at", activity), ("activity_status_updated_at", activityAt),
    ("platform", platform), ("billing_context", billing), ("task_origin", origin),
    ("source_session_id", source), ("source_schedule_id", schedule)]

/-- The Conversation owner supplies the floor for the current Router binding. -/
def conversationSourceBefore (previous next : Term) : Term :=
  let floor := (next.get (b "start_seq")).default (i 0)
  let prior := (previous.get (b "seq")).default floor
  if integerValue prior < integerValue floor then floor else prior

/-- The source frontier and its accepted input share the Session CAS. -/
def conversationSourceAdvance (state event : Term) : KernelM Term := do
  let next := event.get (b "source")
  let sources := (← field state "conversation_sources").default empty
  let key := next.get (b "participant_id")
  let previous := (sources.get key).default empty
  let seq := next.get (b "seq")
  let before := conversationSourceBefore previous next
  if !next.isMap || !key.isBinary || !(next.get (b "conversation_id")).isBinary ||
      next.get (b "generation") != (← field state "session_id") ||
      !before.isInteger || integerValue before < 0 ||
      !seq.isInteger || integerValue seq != integerValue before + 1 then
    argumentError "conversation source must advance one contiguous position"
  if previous != empty && previous.get (b "conversation_id") != next.get (b "conversation_id") then
    argumentError "conversation source binding changed"
  let next := if next.has (b "last_rejection") then next
    else next.put (b "last_rejection") (previous.get (b "last_rejection"))
  write state [("conversation_sources", sources.put key next)]

def metadataPrompt (state event : Term) : KernelM Term :=
  write state [("system_prompt", (event.get (b "system_prompt")).default ((event.get (b "prompt")).default (b "")))]

def metadataPlaceholder (name : Term) : KernelM Bool := do
  if !name.truthy then return true
  if ["", "Chat", "Default", "Untitled"].any (fun s => name == b s || name == a s) then return true
  if name.isBinary then return false
  if let .atom _ := name then return false
  let text ← stringChars name
  return ["", "Chat", "Default", "Untitled"].any (fun s => text == b s)

def metadataUpdate (state event : Term) : KernelM Term := do
  let supplied := event.get (b "name")
  let previous ← field state "name"
  let name ← if supplied == nil then pure previous
    else if event.get (b "if_unnamed") == a "true" then
      pure (if ← metadataPlaceholder previous then supplied else previous)
    else pure supplied
  let hidden := event.get (b "hidden")
  let hidden ← if hidden.isBoolean then pure hidden else field state "hidden"
  let activity := (event.get (b "updated_at")).default (← field state "last_activity_at")
  write state [("name", name), ("hidden", hidden), ("last_activity_at", activity)]

def compactionFailure (state event : Term) : KernelM Term := do
  let failure := select event ["category", "retryable", "reason", "attempts", "live_context_watermark",
    "config_fingerprint", "failed_at", "next_retry_at", "recovery_summary_written"] true
  let activity := (event.get (b "failed_at")).default (← field state "last_activity_at")
  write state [("compaction_failure", failure), ("last_activity_at", activity)]

def compactionRecovery (state event : Term) : KernelM Term := do
  let event := if event.has (b "kind") then event else event.put (b "kind") (b "compaction_recovery")
  let base := select event ["kind", "category", "reason", "compacted_through", "summary_sequence", "created_at"] true
  let seq ← add ((← field state "last_seq").default (i 0)) (i 1)
  let fact := base.put (b "seq") seq
  let events ← append ((← field state "events").default (list [])) (list [fact])
  let activity := (event.get (b "created_at")).default (← field state "last_activity_at")
  write state [("events", events), ("last_seq", seq), ("llm_failure_streak", nil),
    ("last_compaction_recovery", fact), ("last_activity_at", activity)]

/-- `work_index_reasons` normalized as `State.put_work_index/3` does: strings, trimmed, non-empty, unique. -/
def stampWorkReasons (state event : Term) : KernelM Term := do
  if !event.has (b "work_index_reasons") then return state
  let reasons ← match ← Data.event event "work_index_reasons" with
    | .list items => items.mapM (fun item => do
        let .binary raw ← stringChars item | fail "schema" [b "work index reasons must be text"]
        pure (Term.binary (trim raw)))
    | _ => pure []
  write state [("work_index_reasons", list (uniq (reasons.filter (!missing ·))))]

def stampAgentId (state event : Term) : KernelM Term :=
  if event.has (b "agent_id") then do write state [("agent_id", ← Data.event event "agent_id")] else pure state

def stampRuntimeEpoch (state event : Term) : KernelM Term :=
  if event.has (b "runtime_epoch") then do write state [("runtime_epoch", ← Data.event event "runtime_epoch")] else pure state

def stampRuntimeNode (state event : Term) : KernelM Term :=
  if event.has (b "runtime_node") then do write state [("runtime_node", ← Data.event event "runtime_node")] else pure state

def stampActivityRevision (state event : Term) : KernelM Term :=
  if event.has (b "activity_revision") then do write state [("activity_revision", ← Data.event event "activity_revision")] else pure state

def stampStorageRevision (state event : Term) : KernelM Term :=
  if event.has (b "storage_revision") then do write state [("storage_revision", ← Data.event event "storage_revision")] else pure state

def stampFlushId (state event : Term) : KernelM Term :=
  if event.has (b "flush_id") then do write state [("flush_id", ← Data.event event "flush_id")] else pure state

def stampWorkIndexToken (state event : Term) : KernelM Term :=
  if event.has (b "work_index_token") then do write state [("work_index_token", ← Data.event event "work_index_token")] else pure state

/-- `session_stamp`: `agent_id`, `runtime_epoch`, `runtime_node`, `activity_revision`,
`storage_revision`, `flush_id`, `work_index_token`, and `work_index_reasons`.
Each field is written only when the event carries it. -/
def sessionStamp (state event : Term) : KernelM Term := do
  let s ← stampAgentId state event
  let s ← stampRuntimeEpoch s event
  let s ← stampRuntimeNode s event
  let s ← stampActivityRevision s event
  let s ← stampStorageRevision s event
  let s ← stampFlushId s event
  let s ← stampWorkIndexToken s event
  stampWorkReasons s event

end VerifiedKernel.Session
