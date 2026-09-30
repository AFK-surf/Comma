import VerifiedKernel.Session.Ops
import VerifiedKernel.Session.Kernel
import VerifiedKernel.Session.Legacy

/-! Lifecycle ported from `SalixAgent.InternalSession.State` (`new/3`, `normalize/1`,
`persistable/1`) and `SalixAgent.InternalSessionFormat.prepare_write/1`. -/

namespace VerifiedKernel.Session.Lifecycle
open Data

/-! ### The struct envelope -/

/-- `MapSet.new()`. -/
def emptySet : Term := .map [(a "__struct__", a "Elixir.MapSet"), (a "map", empty)]

/-- Every `defstruct` field of `SalixAgent.InternalSession.State` with its default. -/
def defaults : List (String × Term) :=
  [("agent_id", nil), ("session_id", nil), ("name", b "Default"), ("hidden", a "false"),
   ("created_at", nil), ("last_activity_at", nil), ("status", a "idle"),
   ("activity_status", a "paused"), ("activity_status_updated_at", nil), ("activity_revision", nil),
   ("last_ack_message_id", i 0), ("terminal_reply_ack_hwm", nil), ("runtime_failure_reply", nil), ("queue_ack_id", i 0),
   ("next_queue_id", i 1), ("input_queue", list []), ("next_message_id", i 1),
   ("input_dedupe", emptySet), ("conversation_sources", empty), ("summary_sequence", i 0), ("compacted_through", i 0),
   ("summary", nil), ("provider_compaction", nil), ("compaction_failure", nil),
   ("visible_reply_repair", nil), ("visible_reply_activation_scope", nil),
   ("visible_reply_intent", nil), ("visible_reply_egress_facts", empty),
   ("provider_reply_obligations", empty), ("messages", list []), ("events", list []),
   ("wait", nil), ("async_tool_calls", empty), ("storage_revision", nil), ("runtime_epoch", i 0),
   ("runtime_node", nil), ("work_index_token", nil), ("work_index_reasons", list []),
   ("platform", nil), ("billing_context", empty), ("task_origin", nil), ("source_agent_id", nil),
   ("source_session_id", nil), ("source_schedule_id", nil), ("system_prompt", nil),
   ("context_provider_states", empty), ("miniskills", empty), ("live_context_bytes", nil), ("storage_format", i 1),
   ("last_seq", i 0), ("compacted_seq", i 0), ("archived_through", i 0), ("archive_chunks", list []),
   ("segment_catalog", list []), ("flush_id", nil), ("async_results", list []),
   ("async_result_refs", empty), ("redactions", list []), ("llm_failure_streak", nil), ("context_overflow_recovery", nil),
   ("runaway_unsettled_streak", nil), ("repeated_tool_result_streak", nil), ("input_round_streak", nil),
   ("active_source_message_ids", list []), ("last_compaction_recovery", nil),
   ("compact_results", empty), ("fork_request_id", nil)]

/-- `%State{}` with every default. -/
def blank : Term :=
  .map ((a "__struct__", a "Elixir.SalixAgent.InternalSession.State") ::
    defaults.map (fun pair => (a pair.1, pair.2)))

/-- `%State{overrides}`. -/
def build (overrides : List (String × Term)) : Term :=
  overrides.foldl (fun state pair => state.put (a pair.1) pair.2) blank

/-! ### Field normalizers -/

/-- `parse_status/1`. -/
def parseStatus (value : Term) : KernelM Term := do
  if value == b "idle" then return a "idle"
  if value == b "active" then return a "active"
  if value == a "idle" || value == a "active" then return value
  if value == nil then return a "idle"
  inspectedError "invalid internal session status " value

/-- `normalize_stored_activity_status/1`. -/
def storedActivity (value : Term) : Term :=
  let names := ["thinking", "execution", "messaging", "waiting", "failed", "paused"]
  match names.find? (fun name => value == a name || value == b name) with
  | some name => a name
  | none => a "paused"

/-- `normalize_optional_map/1`. -/
def optionalMap (value : Term) : Term := if value.isMap then value else nil

/-- `normalize_required_map/1`. -/
def requiredMap (value : Term) : Term := if value.isMap then value else empty

/-- `normalize_visible_reply_activation_scope/1`. -/
def activationScope (value : Term) : KernelM Term := do
  if !value.isMap then return nil
  let scope ← stringify value
  return if validScope scope then scope else nil

/-- `normalize_work_index_reasons/1`: text, trimmed, non-empty, unique. -/
def workReasons (value : Term) : KernelM Term := do
  match value with
  | .list xs =>
    let texts ← xs.mapM (fun item => do
      let .binary raw ← stringChars item | fail "schema" [b "work index reasons must be text"]
      pure (Term.binary (trim raw)))
    return list (uniq (texts.filter (· != b "")))
  | .improper heads _ => do
    let _ ← heads.mapM stringChars
    fail "enum_map_tail"
  | _ => return list []

/-- `normalize_runtime_epoch/1`. -/
def runtimeEpoch (value : Term) : Term :=
  if value.isInteger && integerValue value ≥ 0 then value else i 0

/-- The `archive_chunks` filter: five integers, anything else is unaddressable. -/
def archiveChunks (value : Term) : KernelM Term := do
  let kept ← enumFold value [] (fun acc item =>
    match item with
    | .list xs => return if xs.length == 5 && xs.all Term.isInteger then acc ++ [item] else acc
    | _ => pure acc)
  return list kept

/-- `SalixStore.SealedSegments.parse_entry/1`. -/
def parseEntry (entry : Term) : Bool :=
  match entry with
  | .list [first, last, messages, uncomp] =>
    if first.isInteger && last.isInteger && messages.isInteger && uncomp.isInteger then
      let f := integerValue first
      let l := integerValue last
      let m := integerValue messages
      f > 0 && l ≥ f && m ≥ 0 && m ≤ l - f + 1 && integerValue uncomp > 0
    else false
  | _ => false

/-- The `segment_catalog` filter. -/
def segmentCatalog (value : Term) : KernelM Term := do
  let kept ← enumFold value [] (fun acc entry =>
    return if parseEntry entry then acc ++ [entry] else acc)
  return list kept

private def stampedMax (records key : Term) (highest : Option Term) : KernelM (Option Term) :=
  enumFold records highest (fun current record => do
    let stamp := (← access record key).default (i 0)
    match current with
    | none => pure (some stamp)
    | some previous =>
      pure (some (if ← less stamp previous then previous else stamp)))

/-- `max_stamped_seq/3`, without allocating three stamp lists and their concatenation. -/
def maxStamped (messages events results : Term) : KernelM Term := do
  let ms ← stampedMax messages (a "seq") none
  let es ← stampedMax events (b "seq") ms
  let rs ← stampedMax results (b "seq") es
  return rs.getD (i 0)

/-- `normalize_last_seq/1`: resume past the highest stamp actually present. -/
def normalizeLastSeq (state : Term) : KernelM Term := do
  let stored := (← field state "last_seq").default (i 0)
  let stamped ← maxStamped ((← field state "messages").default (list []))
    ((← field state "events").default (list [])) ((← field state "async_results").default (list []))
  kmax stored stamped

/-- `next_queue_id_after/2`. -/
def nextQueueId (items : List Term) (stored : Term) : KernelM Term := do
  let ids ← items.mapM queueItemId
  let highest ← largest ids (i 0)
  kmax (← add highest (i 1)) (← kmax (i (integerValue stored)) (i 1))

/-- `prune_input_queue/2` over `normalize_input_queue/1`. -/
def pruneQueue (queue ack : Term) : KernelM (List Term) := do
  let items ← normalizeQueue queue
  items.filterM (fun item => do return !(← atMost (← queueItemId item) ack))

/-- `normalize_runaway_streak/1`. -/
def runawayStreak (state : Term) : KernelM Term := do
  let stored ← field state "runaway_unsettled_streak"
  if stored == nil then return nil
  let streak := (optionalMap stored).default empty
  let legacy := (← alias streak (b "key") (b "activation_key"))
  let count ← unsettledCount state
  if legacy != nil then
    let scope ← normalizeScope legacy
    if scope.isEmpty || list scope != list (← activationKey state) then
      return .map [(b "count", i 0)]
  return .map [(b "count", count)]

/-- `normalize_dedupe/1` members. -/
def dedupeMembers (value : Term) : KernelM (List Term) := do
  if value.get (a "__struct__") == a "Elixir.MapSet" then
    let inner := value.get (a "map")
    if inner.isMap then return (← entries inner).map Prod.fst
    fail "schema" [b "expected MapSet data"]
  match value with
  | .list xs => return xs
  | .improper _ _ => fail "enum_reduce_tail"
  | _ => return []

/-- `SalixAgent.ProviderReplyObligation.normalize_map/1`. -/
def obligationTable (value : Term) : KernelM Term := do
  if !value.isMap then return empty
  (← entries value).foldlM (fun acc pair => do
    let target ← normalizeObligation pair.2
    if target.isMap && target.has (b "key") then put acc (target.get (b "key")) target
    else pure acc) empty

/-- `normalize_dedupe/1`. -/
def normalizeDedupe (value : Term) : KernelM Term := do
  if value.get (a "__struct__") == a "Elixir.MapSet" then
    if let .map pairs := value.get (a "map") then
      -- Map keys already form a set. Do not sort and hash the full ledger again.
      let pairs := pairs.map (fun pair => (pair.1, list []))
      return .map [(a "__struct__", a "Elixir.MapSet"), (a "map", .map pairs)]
    fail "schema" [b "expected MapSet data"]
  let members ← dedupeMembers value
  return .map [(a "__struct__", a "Elixir.MapSet"),
    (a "map", .map ((uniq members).map (fun key => (key, list []))))]

/-- `queue_item_dedupe_keys/1`. -/
def queueDedupeKeys (item : Term) : KernelM (List Term) := do
  if !item.isMap then return []
  let raw ← alias item (b "payload") (a "payload")
  let payload ← stringify (raw.default empty)
  -- A payload that is not a map (a bare text item) carries no identity keys.
  let payloadKeys ← if payload.isMap then
      pure [← access payload (b "source_message_id"), ← access payload (b "runtime_message_id")]
    else pure []
  return [← access item (b "dedupe_key"), ← access item (a "dedupe_key"),
    ← access item (b "source_message_id"), ← access item (a "source_message_id")] ++ payloadKeys

/-- `preserve_input_dedupe_with_pending_queue_keys/1`. -/
def preserveDedupe (state : Term) : KernelM Term := do
  let queue := wrap (← field state "input_queue")
  let queueKeys ← queue.foldlM (fun acc item => return acc ++ (← queueDedupeKeys item)) []
  let dedupe ← field state "input_dedupe"
  let .map pairs := dedupe.get (a "map") | fail "schema" [b "expected MapSet data"]
  let members := Term.map (pairs.filter (fun pair => !missing pair.1))
  let members ← queueKeys.foldlM (fun acc key =>
    if missing key then pure acc else put acc key (list [])) members
  return .map [(a "__struct__", a "Elixir.MapSet"), (a "map", members)]

/-! ### Context provider states -/

/-- The first test of `messageProviderStates`: only an assistant map can carry states. -/
@[inline] private def assistantMap (message : Term) : Bool :=
  message.isMap && (message.get (a "role") == b "assistant" || message.get (b "role") == b "assistant")

/-- Plain metadata whose keys are all atoms or binaries, none named
`context_provider_states`, stringifies to a map without that key, so it carries
no states. A struct keeps the full path and its enumeration failure. -/
private def lacksStates (metadata : Term) : Bool :=
  match metadata with
  | .map pairs => pairs.all (fun pair => match pair.1 with
      | .atom name => name != "context_provider_states" && name != "__struct__"
      | key@(.binary _) => key != b "context_provider_states"
      | _ => false)
  | _ => true

/-- `message_context_provider_states/1`. -/
def messageProviderStates (message : Term) : KernelM Term := do
  if !message.isMap then return empty
  if message.get (a "role") != b "assistant" && message.get (b "role") != b "assistant" then
    return empty
  let metadata ← alias message (a "do_not_send_to_llm") (b "do_not_send_to_llm")
  if !metadata.isMap then return empty
  if lacksStates metadata then return empty
  let normalized ← shallowStringify metadata
  providerStates (normalized.get (b "context_provider_states"))

/-- `context_provider_states_from_boundaries/1`. -/
def boundaryProviderStates (state : Term) : KernelM Term := do
  let compacted := (← field state "compacted_through").default (i 0)
  let messages := wrap (← field state "messages")
  -- The states of the highest-id live message that carries any: one walk
  -- keeping the best candidate, where sorting the whole transcript by id at
  -- every normalization cost a long session tens of milliseconds. On equal
  -- ids the earlier message wins, as the stable descending sort chose.
  let found ← messages.foldlM (fun (acc : Option (Int × Term)) message => do
    -- Only assistant metadata can name states: other messages skip the id read.
    if !(assistantMap message) then return acc
    let id := integerValue (← alias message (a "id") (b "id"))
    if !(← greater (i id) compacted) then return acc
    if let some (best, _) := acc then
      if id ≤ best then return acc
    let states ← messageProviderStates message
    match states with
    | .map (_ :: _) => return some (id, states)
    | _ => return acc) none
  return (found.map Prod.snd).getD empty

/-- `SalixAgent.ContextProviders.migration_provider_states/1` over the struct's own fields.
The struct never carries `tool_disclosure_*`, so only the notice seed can apply. -/
def migrationStates (state : Term) : KernelM Term := do
  let messages := (state.get (a "messages")).default nil
  let adopted ← match messages with
    | .list xs => xs.foldlM (fun acc message => do
        if acc then return true
        if !message.isMap then return false
        let role := (message.get (a "role")).default (message.get (b "role"))
        return role == b "assistant" || role == b "tool") false
    | _ => pure false
  let compaction := (state.get (a "provider_compaction")).default nil
  let nonempty := match compaction with | .map (_ :: _) => true | _ => false
  let summary := (state.get (a "summary")).default nil
  if adopted || nonempty || !(missing summary) then
    return .map [(b "migration_notice", .map [(b "version", i 0)])]
  return empty

/-! ### `normalize` -/

/-- Missing `defstruct` fields take their defaults, as `struct/2` fills them:
a snapshot written before a field existed still normalizes. -/
def fillDefaults (state : Term) : Term :=
  defaults.foldl (fun s pair => if s.has (a pair.1) then s else s.put (a pair.1) pair.2) state

/-- `State.normalize/1`. -/
def normalize (state : Term) : KernelM Term := do
  let state := fillDefaults state
  let migration ← migrationStates state
  let ack := (← field state "queue_ack_id").default (i 0)
  let queue ← pruneQueue (← field state "input_queue") ack
  let scope ← activationKey state
  let streak ← runawayStreak state
  let normalized ← write state
    [("status", ← parseStatus (← field state "status")),
     ("activity_status", storedActivity (← field state "activity_status")),
     ("last_ack_message_id", (← field state "last_ack_message_id").default (i 0)),
     ("queue_ack_id", ack),
     ("next_queue_id", ← nextQueueId queue (← field state "next_queue_id")),
     ("input_queue", list queue),
     ("next_message_id", ← kmax ((← field state "next_message_id").default (i 1)) (i 1)),
     ("input_dedupe", ← normalizeDedupe (← field state "input_dedupe")),
     ("summary_sequence", (← field state "summary_sequence").default (i 0)),
     ("compacted_through", (← field state "compacted_through").default (i 0)),
     ("provider_compaction", optionalMap (← field state "provider_compaction")),
     ("compaction_failure", optionalMap (← field state "compaction_failure")),
     ("visible_reply_repair", optionalMap (← field state "visible_reply_repair")),
     ("visible_reply_activation_scope", ← activationScope (← field state "visible_reply_activation_scope")),
     ("visible_reply_intent", optionalMap (← field state "visible_reply_intent")),
     ("visible_reply_egress_facts", requiredMap (← field state "visible_reply_egress_facts")),
     ("provider_reply_obligations", ← obligationTable (← field state "provider_reply_obligations")),
     ("messages", (← field state "messages").default (list [])),
     ("events", (← field state "events").default (list [])),
     ("async_tool_calls", (← field state "async_tool_calls").default empty),
     ("work_index_reasons", ← workReasons (← field state "work_index_reasons")),
     ("billing_context", (← field state "billing_context").default empty),
     ("context_provider_states", empty),
     ("miniskills", requiredMap (← field state "miniskills")),
     ("storage_format", (← field state "storage_format").default (i 1)),
     ("last_seq", ← normalizeLastSeq state),
     ("compacted_seq", (← field state "compacted_seq").default (i 0)),
     ("archived_through", (← field state "archived_through").default (i 0)),
     ("archive_chunks", ← archiveChunks ((← field state "archive_chunks").default (list []))),
     ("segment_catalog", ← segmentCatalog ((← field state "segment_catalog").default (list []))),
     ("async_results", (← field state "async_results").default (list [])),
     ("async_result_refs", (← field state "async_result_refs").default empty),
     ("runtime_epoch", runtimeEpoch (← field state "runtime_epoch")),
     ("redactions", (← field state "redactions").default (list [])),
     ("llm_failure_streak", optionalMap (← field state "llm_failure_streak")),
     ("runaway_unsettled_streak", streak),
     ("repeated_tool_result_streak", optionalMap (← field state "repeated_tool_result_streak")),
     ("input_round_streak", optionalMap (← field state "input_round_streak")),
     ("active_source_message_ids", list scope),
     ("last_compaction_recovery", optionalMap (← field state "last_compaction_recovery")),
     ("compact_results", (← field state "compact_results").default empty),
     ("fork_request_id", ← field state "fork_request_id")]
  let normalized ← write normalized [("activity_status", ← activity normalized)]
  let boundaries ← boundaryProviderStates normalized
  let providers := match boundaries with | .map (_ :: _) => boundaries | _ => migration
  let normalized ← write normalized [("context_provider_states", providers)]
  write normalized [("input_dedupe", ← preserveDedupe normalized)]

/-- `State.new/3` on `{agent_id, session_id, attrs}`; the state argument is unused. -/
def create (_state args : Term) : KernelM Term := do
  let .tuple [agent, session, attrs] := args | fail "function_clause"
  let pick (name : String) : KernelM Term := alias attrs (b name) (a name)
  let now ← pick "created_at"
  let hidden := Term.bool ((← access attrs (b "hidden")) == a "true" ||
    (← access attrs (a "hidden")) == a "true")
  normalize (build
    [("agent_id", agent), ("session_id", session), ("storage_format", i 3),
     ("name", (← pick "name").default (b "Default")), ("hidden", hidden),
     ("created_at", now), ("last_activity_at", now), ("activity_status", a "paused"),
     ("activity_status_updated_at", now), ("platform", ← pick "platform"),
     ("billing_context", (← pick "billing_context").default empty),
     ("task_origin", ← pick "task_origin"), ("source_agent_id", ← pick "source_agent_id"),
     ("source_session_id", ← pick "source_session_id"),
     ("conversation_sources", (← pick "conversation_sources").default empty),
     ("source_schedule_id", ← pick "source_schedule_id"),
     ("system_prompt", ← pick "system_prompt")])

/-- `State.persistable/1`: the state without `context_provider_states`. -/
def persistable (state : Term) : KernelM Term := put state (a "context_provider_states") empty

/-- `InternalSessionFormat.prepare_write/1`: `{:ok, state}` or `{:error, :unsupported_storage_format}`. -/
def prepareWrite (state : Term) : KernelM Term := do
  let state ← normalize state
  let format ← field state "storage_format"
  if format == i 1 then Legacy.migrateFormat1 state
  else if format == i 2 || format == i 3 then
    return .tuple [a "ok", ← write state [("storage_format", i 3)]]
  else return .tuple [a "error", a "unsupported_storage_format"]

/-- Lifecycle operations by name. `args` is unused unless stated. -/
def table : OpTable :=
  [("normalize", fun state _ => normalize state),
   ("new", create),
   ("prepare_write", fun state _ => prepareWrite state)]

end VerifiedKernel.Session.Lifecycle
