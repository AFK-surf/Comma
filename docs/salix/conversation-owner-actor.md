# Conversations and delivery

## Dynamic UI content

A `dynamic_ui` block is a Message value, not an application entity.
It carries protocol `version`, `ui_ref`, `path`, `file_name`, `mime_type`, `summary`, and matching `text` fallback.
The sender attachment binder supplies `blob_ref`. Callers cannot substitute arbitrary blob authority.
`ui_ref` projects the existing blob UUID. The binder rejects a path that now names different bytes.
This prevents silent version substitution between creation and send. It does not authorize a read or delivery.
`origin_task_id` preserves Task context for a user-submitted follow-up. It grants no Task access.
At most one UI block belongs to a Message. HTML and JavaScript remain in the immutable attachment.
Normal recipient materialization lets the Router forward the same bytes from its authorized workspace.

The Worker explicitly sends the content through the existing Conversation owner and IFC path.
Tool output alone creates no visible Message. External providers receive the summary.
New versions append Messages and use existing reply/thread relationships within each destination Conversation.
Home and Task message IDs remain distinct. They can reference the same attachment version.
Local form state belongs to the device. Reminder and Task state keep their existing server owners.

## Authority

Mutate Conversation facts only through `ConversationServer -> ConversationActor`.
The owner serializes metadata, Message append, and Participant membership transitions.
Participant mutation is separate from Message append.
Participants are delivery targets, not senders. Never persist the in-memory `participant_count` aggregate.
ParticipantActor owns provider delivery, retry, recovery, and participant runtime status.
All Agent Participants use the log admission path below.
Do not create a global dispatcher that bypasses those owners.

Comma keeps its fixed Router `user_chat` binding.
When that Conversation needs the current Router Participant, ensure the Participant and append to the same Conversation.
Do not create another `user_chat` or replacement binding to repair a missing Participant.
Repeated Router setup reuses active User membership and does not rewrite unchanged Agent activation fields.
An active Agent source keeps its subscription start and cursor during setup, even when unread Messages exist.
Reactivation and Triage joins retain their explicit position rules.
Preparation can share control reads within one call. Router authority checks before and after reconciliation read current records.
A busy Session retains at most 64 consumer wake hints, matching the per-Agent source bound.
The owner sends these hints when processing unblocks. Unadmitted inputs stay in the Conversation log.
Hints are disposable. The existing five-second consumer retry and log recovery cover lost hints and owner restarts.
BFT and Comma product records may project canonical IDs. They do not own a second copy of execution history.

The Conversation owner retains at most 32 storage observations for serialized request scopes.
Ordinary store calls and recovery read fresh storage. Conditional writes retain their CAS fences.
Repeated Router setup compares resident membership with fresh Group and Agent records.
The Group owner retains one Router address hint to overlap those reads. The hint grants no authority.

A single-Agent append may prepare live provider configuration before Message publication.
Only an idle consumer can reuse completed observations, within 50 ms of notification.
Queued work, retries, and switches resolve fresh configuration. Unfinished preparation ends with the append scope.

Read-tool timer registration follows durable Session and recovery-candidate writes.
At most 256 registration tasks run per node. Saturation uses synchronous registration.
Live pending tools avoid duplicate registration. Recovery reconstructs timers from durable wait state.

Segment index counts, byte totals, and sequence bounds are projections of canonical rows.
Readers derive these facts from rows instead of treating disagreement as storage corruption.
Storage owns integrity checks. Application schema, sequence continuity, CAS, and retry identity checks remain.

## Message and visible reply

Message identity, reply relationships, ordered canonical history, and explicit delivery belong to Salix IM.
A model response or internal Session record is not automatically a public message.
Visible egress must use the explicit reply path and its destination authority.
Internal planning, tool results, provider context, and private summaries must not leak through an implicit assistant projection.
File delivery must preserve the source and authorized audience rather than treating a local path as a public URL.

A tool result, provider ACK, canonical append, and user-visible delivery are different observations.
Use a stable delivery identity for retry and deduplication.
Do not claim exactly-once external delivery from an internal retry ledger.
A late result must satisfy the current owner and activation fences before it changes state.

## History and projections

Canonical Conversation metadata, Messages, Participants, and provider receipts use separate storage collections.
Growing collections use bounded segmented or directory-sharded access.
Runtime Session history remains separate from user-visible Conversation history.
Comma Conversation detail accepts `message_limit` (1–1000; default 1000) through the authorized tail read for Home and Task. It keeps total `message_count`, Message identity, and the latest review metadata.
Comma `GET .../messages` pages by `seq`: one of `before`, `after`, or `around`, and `limit` (default 100, max 200). A `seq` outside this Conversation is 404. It uses detail authorization and no owner.
Task lists prepare at most six visible cards per update, with two concurrent requests and 24 Messages per card. They read only queued visible targets: no full-list fan-out, polling, retry loop, or live Conversation connection. The session cache keeps at most 16 canonical snapshots. Leaving the list aborts preparation; late or foreign-session results cannot enter the cache. A failed preparation or a tail with no public Messages leaves loading to the open path. It cannot establish empty public history.
Opening a prepared card reads that snapshot synchronously, then the runtime reconciles full detail. Preparation alone does not mark a Task read or mutate state. A cold open before preparation still needs network data.

A renderer reload reads canonical history and reconciles pending local state.
It must not erase history because a live stream ended or create a new identity to hide a read failure.

Participant status is a participant-owned projection, not a scan of internal runtime processes.
ConversationServer resolves the Participant owner through ConversationActor, then requests status or a subscription directly from ParticipantActor.
ConversationActor does not wait for the runtime status read. The status request releases its Message append mailbox before that wait.
Resident internal Session owners project activity from their committed revision. Pending changes stay private until the commit.
Absent resident revisions use the existing storage read. A busy resident owner returns a bounded error without a duplicate storage read.
ParticipantActor combines queued activity invalidations into one pending refresh, without a timer.
Notifications during a read schedule a follow-up refresh. Retiring the Session subscription cancels its pending refresh.
Status queries and SSE recovery must be bounded and preserve current identity.
Do not let stale stream events overwrite a newer snapshot or another Conversation's state.
For active work, Participant status can include `working_provider`: `wechat`, `telegram`, or `signal`.
The projection uses the runtime's current activation source IDs, with no history scan or extra RPC.
It omits the field for mixed or unknown sources and stopped or failed work.
Comma shows the capsule from this field. Internal source IDs never enter the public status.
For active work started only by Loop inputs, Participant status includes `loop_wake: true`.
It omits this field for mixed, stopped, or failed work and does not expose Loop source IDs.
Home keeps the Participant active but shows no reply activity bubble for a Loop wake.
See [Storage](../storage-search.md) for archive errors and [Tasks](tasks-background-execution.md) for Task state.

## Provider ingress and egress

Every provider adapter normalizes its events into the same ownership path.
Provider thread identity is context, not a replacement Conversation owner.
Apply provider retry and concurrency bounds without bypassing canonical admission.
Keep external formatting and rich-card behavior in the provider adapter.
An error in visible reply repair must become an actionable outcome, not an infinite re-execution loop.

## Validation boundary

Preserve integration regressions for ownership, stale delivery, retry identity, history recovery, streaming interruption, and permission checks.
Pure reducer proofs do not establish provider delivery or storage transport behavior.
Read the relevant `systems/apps/salix_im` owner and tests before changing these transitions.

## Conversation log consumption

The ordered Conversation log supplies inputs to Router, Worker, and Meeting Agents, for internal and external runtimes.
Provider callbacks commit their checked input and provenance through ConversationServer before acknowledgment.
A verified provider source keeps its first accepted input per target Session when retry-time prompt settings or context enrichment change.
A new callback after Router reset can admit that source to the new Session. Reset alone does not replay the old log.
Chat and search projections hide provider prompt envelopes and internal delivery events.
The fixed Router Conversation also records provider context. Its owner-only input fields cannot be supplied by a public Message append.
Provider Participants consume the same log. There is no second delivery queue, active-status index, outbox, or durable wakeup marker.
Owner-authored provider commands and status projections are targeted app events; Agent Sessions do not consume them.
Each provider owner reads at most 32 records and stores its completed position in `delivery_log_cursor_seq`.
It claims an exact Message/Participant receipt before platform I/O, settles that receipt, then advances the cursor.
A restart reads that receipt before another send. Subscription changes and binding fences cannot hide unresolved platform I/O.
Slack receipt verification can confirm a prior send without sending again. It does not establish exactly-once delivery.
Three failed send attempts or three unsuccessful verification settlements produce a terminal error; uncertain results are `unknown`.
A retry delay from a provider does not reset the attempt budget.
Task-thread detachment waits for the log cursor to reach its cutoff and for in-flight I/O to settle.

Conversation status is a projection of durable metadata. `provider_status_version` advances with projected facts or recovery fencing.
The Conversation owner uses that version for publication and recovery, not to authorize a caller.
Provider app events advance the log without changing the Task business version used for review acceptance.
Indexed Conversation recovery retries interrupted status publication. No separate status queue or retry worker exists.
An explicit redelivery appends an idempotent request that refers to the original Message and uses a fresh input identity.

ConversationActor commits segments, locators, and retry identities before publishing the tail.
It then sends a best-effort source hint. Display-list repair runs outside the append mailbox.
Each Agent owner runs one source task, with at most 64 pending hints and 64 cached source positions.
A task reads at most 32 records. Session state remains authoritative if a hint or cached position is lost.

The consumer preserves target filters, attachments, provenance, billing, archive admission, and context-only wake policy.
Each Session stores progress by Participant ID. A single CAS commits input and progress together.
Internal and external Session birth determines runtime ownership. Mutable Agent configuration cannot move an existing Session.
Non-target and imported transcript records advance progress without adding input.
Scans and rejection-only progress do not request a runtime wake.
Muted Participants do not consume the log. Their later Task join can admit the required suffix.

Notifications use a local role actor only while the root Agent Server is local.
A queued consumer without a local Server routes its source hint through Agent placement before reading Session history.
The current owner loads its frontier and applies its canonical-session fence. The old consumer discards its cached position.
An `agent_owner_remote` admission result redirects the source hint without recording a rejection or advancing progress.
Failed routing retains the existing five-second retry and durable log recovery.

Admission makes three attempts for other transient failures. A terminal failure records `last_rejection` with its source position.
An exhausted Triage command escalates its Task before the rejected position commits.
Escalation preserves the grant so an already accepted Worker can still complete the Task.
If storage cannot commit the rejection, progress stays unchanged and recovery retries after five seconds.
Missing and retired bindings stop that source drain.
An explicit Participant delivery-status query includes `source_progress` and requires at most one Session read.
Aggregate reports do not query each Agent. Provider delivery records remain in `deliveries`.

Router reset copies all source positions into the new Session generation.
Participant activation owns its initial source position. Reassignment starts after the current tail.
The consumer uses the greater of saved Session progress and the current Participant's initial position.
This rule also applies when reassignment reuses a previous Router, Session, and Participant.
Stored Messages and already admitted Session inputs remain intact.

Recovery uses the PostgreSQL `conversation_log_recovery` due index. It never traverses Group or Conversation directories.
One row per pending Conversation records the greatest prepared sequence and provider status version. Message payloads and delivery outcomes remain with their existing owners.
Append prepares the segment and all locators, marks the index, then publishes the canonical tail.
If publication stops, recovery finishes the prepared append through ConversationActor and its normal Store CAS.
A failed index write prevents tail publication. No acknowledged append depends on a later index write.
Metadata changes register their next provider status version before CAS. A failed status-event append retains the same recovery row.
If metadata still has an older version, recovery reserves the indexed publication version with a normal metadata CAS.
This preserves all current product facts and the Task business version. It prevents a late, unacknowledged write from committing after cleanup.
A failed fence retains the candidate. The version is a publication precondition, not a security boundary.
Recovery removes only the observed sequence and status version after publication and durable consumer progress. A greater concurrent target prevents deletion.
Changes to Agent filters or Session bindings, including the first Triage join, register recovery before activation.
Cleanup returns to the Conversation owner with its observed membership revision. A changed revision or owner rejects cleanup and retains the candidate.
This ephemeral revision prevents stale consumption checks from hiding a newly exposed suffix. It is not a second durable delivery position.

Each Pod polls once per second and runs at most eight recovery tasks, each with a 30-second execution budget.
The indexed `SKIP LOCKED` query claims only available task slots. A claim defers its next attempt by one second.
Claims distribute discovery work. They do not authorize delivery or replace Session CAS and provider receipt claims.
Each task checks at most 200 Participant slots in one pending Conversation. Idle Conversations cost no recovery reads.
Recovery includes inactive provider slots so unresolved platform calls can settle after owner loss. Inactivity prevents new sends.
With available capacity, initial discovery waits at most one polling interval plus database and owner I/O.
Backlog, slow dependencies, or failed ownership admission can extend this delay. The interval is not an end-to-end recovery guarantee.
Normal delivery uses hints and does not wait for recovery. Notification and display-repair supervisors each allow at most 64 tasks.

### Automatic initialization of existing conversations

The product owner permits loss of unprocessed Agent inputs and pending provider output from before this deployment's per-Conversation switch.
Canonical Messages, Participants, admitted Session inputs, and deduplication records remain stored.
The first append or Agent source read saves the current Message tail before committing any new Message.
A provider reached first uses the current tail as its initial cursor.
New Conversations start at zero. Restart never moves an initialized lower bound forward.
The same rule applies to IM, Worker, Router, and external-runtime inputs.
Old delivery queues, indexes, and wakeup markers no longer select work. Historical receipts remain available for diagnostics.
No import or replay of old provider backlog runs. Existing platform receipts and canonical history remain stored.
Diagnostics show abandoned pending receipts as cancelled and unresolved platform calls as unknown.
The lower bound is `log_start_seq`; each provider initializes its cursor at that bound or its later Participant start position.

Use the approved mainline rolling release. The normal release runs the additive index migration automatically. No manual command, historical scan, or shutdown is required.
Conversations initialize on access. New appends create recovery candidates. The approved discarded prefix needs no backfill.
Initialization failure rejects the operation before a new Message commits.
After cutover, use forward repair. An old consumer can replay inputs excluded by the owner's decision.

### Evidence and limits

`provider_conversation_log_test.exs` covers provider restart, automatic backlog disposal, and indexed recovery.
`router_conversation_log_test.exs` covers lost hints, ordered scans, indexed discovery, interrupted tail publication, concurrent index retirement, automatic initialization, preserved Session inputs, and restart stability.
`internal_session_flush_settlement_test.exs` and `external_session_store_test.exs` cover atomic admission, ambiguous CAS completion, independent source positions, and duplicate replay.
`RpcDeliver` models one target source position and its atomic queue/frontier CAS.
It does not prove multi-record ordering, notification liveness, or external exactly-once delivery.
The local `bench/router_ingress.exs` probe measures message construction to runtime admission start and completion with injected storage latency.
It uses a resident Router and an existing canonical Session and holds the model request pending.
It does not measure client upload, production storage latency, model execution, or user-visible reply time.
Operation histograms report source-consume, admission, and indexed recovery duration. Recovery outcomes distinguish cleaned, retained, failed, and timed-out candidates. Claim outcomes expose index query failures.
Source samples report unread backlog and oldest unread age. Projection samples report display-repair lag.
These samples do not establish a bound when storage or the recovery owner remains unavailable.
