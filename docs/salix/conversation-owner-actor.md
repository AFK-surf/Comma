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
Ensure a missing Router Participant and append to that Conversation. Never replace its `user_chat` or binding.
Repeated setup reuses active User membership and unchanged Agent activation fields.
Active Agent sources retain their subscription start and cursor, including with unread Messages.
Reactivation and Triage joins retain their explicit position rules.
Preparation can share control reads within one call. Router authority checks read current records before and after reconciliation.
A busy Session retains at most 64 consumer wake hints, matching the per-Agent source bound. The owner sends them when processing unblocks.
Unadmitted inputs stay in the log. Five-second consumer retries and log recovery cover lost disposable hints and owner restarts.
BFT and Comma may project canonical IDs, but own no second execution history.

The Conversation owner retains at most 32 storage observations for serialized request scopes. Ordinary calls and recovery read fresh storage.
Conditional writes retain CAS fences. Router setup compares resident membership with fresh Group and Agent records.
The Group owner's one Router address hint overlaps those reads but grants no authority.

A single-Agent append may prepare live provider configuration before publication.
Only idle consumers reuse completed observations, within 50 ms of notification.
Queued work, retries, and switches read fresh configuration. Unfinished preparation ends with the append scope.

Read-tool timer registration follows durable Session and recovery-candidate writes.
At most 256 registration tasks run per node. Saturation uses synchronous registration.
Live pending tools avoid duplicate registration. Recovery reconstructs timers from durable wait state.

Readers derive segment counts, byte totals, and sequence bounds from canonical rows. Index disagreement does not establish storage corruption.
Storage owns integrity checks. Schema, sequence continuity, CAS, and retry identity checks remain.

## Message and visible reply

Salix IM owns Message identity, reply relationships, ordered history, and explicit delivery.
Model responses and internal Session records are not automatically public Messages.
Visible egress requires the explicit reply path and destination authority.
Never expose internal planning, tool results, provider context, or private summaries through implicit assistant projection.
File delivery preserves source and authorized audience. Local paths are not public URLs.

Tool results, provider ACKs, canonical appends, and user-visible delivery differ.
Retry and deduplication require stable delivery identity. An internal retry ledger does not prove exactly-once external delivery.
Late results must satisfy current owner and activation fences before changing state.

## History and projections

Conversation metadata, Messages, Participants, and provider receipts use separate collections with bounded segmented or directory-sharded access.
Runtime Session history stays separate from visible Conversation history.
Home shows external inputs and successful explicit replies. Only user inputs show a platform icon and `From <platform>` above the bubble.
`platform_message` carries provider, role, and content. Inputs use checked sender text and attachment names, never Agent prompts.
Bounded reads derive older inputs from trusted text, but cannot reconstruct older replies.
The owner links WeChat replies only to checked Home source Messages. WeChat sends stay unchanged.
Media captions and names or types grant no access to private runtime paths or provider URLs.
Badges and reply links survive native transport and reload. External messages neither settle pending Comma replies nor trigger their notifications.

Home and Task detail use authorized tail reads with `message_limit` (1–1000, default 1000), retaining total `message_count`, Message identity, and latest review metadata.
`GET .../messages` pages by `seq` with one of `before`, `after`, or `around`, and `limit` (default 100, maximum 200).
Sequences outside this Conversation return 404. Pages use detail authorization without an owner.
Task lists prepare at most six visible cards per update, with two concurrent requests and 24 Messages per card.
Only queued visible targets load. No full-list fan-out, polling, retry loop, or live Conversation connection runs.
The session cache holds at most 16 canonical snapshots. Leaving aborts preparation. Late or foreign-session results cannot enter the cache.
Failed preparation or tails without public Messages defer loading to the open path. They cannot establish empty public history.
Prepared cards open from their snapshot synchronously, then reconcile full detail. Preparation neither marks Tasks read nor mutates state.
Cold opens before preparation need network data.

Renderer reloads reconcile canonical history and pending local state.
Never erase history when a stream ends or create a new identity to hide a read failure.

ParticipantActor owns status, without runtime-process scans.
ConversationServer resolves it through ConversationActor, then requests status or subscription directly. The read never holds ConversationActor's Message append mailbox.
Resident internal Sessions project only committed revisions. Absent revisions use storage. Busy resident owners return bounded errors without duplicate storage reads.
ParticipantActor coalesces queued activity invalidations into one refresh without a timer.
Notifications during reads schedule another refresh. Session subscription retirement cancels pending refreshes.
Bound status queries and SSE recovery. Preserve identity. Stale events cannot overwrite newer snapshots or another Conversation's state.
Active work can report `working_provider`: `wechat`, `telegram`, or `signal`, from current activation source IDs without history scans or extra RPC.
Mixed or unknown sources and stopped or failed work omit it. Comma projects the channel capsule without exposing internal source IDs.
Work started only by Loop inputs reports `loop_wake: true`. Mixed, stopped, or failed work omits it. Loop source IDs stay private.
Home keeps Loop Participants active without a reply activity bubble.
See [Storage](../storage-search.md) for archive errors and [Tasks](tasks-background-execution.md) for Task state.

## Provider ingress and egress

Every provider adapter uses the same ownership path.
Provider threads supply context, not Conversation ownership.
Preserve canonical admission and provider retry/concurrency bounds.
Provider adapters own external formatting and rich cards.
Visible reply repair errors must produce actionable outcomes, never infinite retries.

## Validation boundary

Keep integration regressions for ownership, stale delivery, retry identity, history recovery, streaming interruption, and permission checks.
Pure reducer proofs do not establish provider delivery or storage transport behavior.
Read the relevant `systems/apps/salix_im` owner and tests before changing these transitions.

## Conversation log consumption

The ordered log supplies Router, Worker, and Meeting inputs to internal and external runtimes.
Provider callbacks commit checked input and provenance through ConversationServer before acknowledgment.
Each verified provider source retains its first accepted input per target Session, despite retry-time prompt or context changes.
After Router reset, a new callback can admit the source to the new Session. Reset alone never replays the log.
Chat shows `platform_message` when present, never provider prompt envelopes or delivery control events. Search omits internal delivery records.
The fixed Router Conversation records provider context. Public Message appends cannot supply owner-only input fields.
After successful explicit sends, the dispatcher attempts a `provider.message` record through that owner, with no delivery targets or Agent input.
It deduplicates by existing tool call or provider receipt, without new delivery identity or retry queue.
History writes use 64 shared projection slots. Failure or saturation can omit history, but never fails or repeats a successful platform send.
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
