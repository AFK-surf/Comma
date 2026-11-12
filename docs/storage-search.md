# Storage and search

## Durable facts and projections

PostgreSQL owns online Agent, Session, Conversation, Message, Participant, and provider receipt facts.
Immutable attachments and sealed history bodies remain in S3. PostgreSQL directories identify published history.
Task search remains a bounded rebuildable projection, separate from canonical Conversation facts.
Control metadata, credentials, billing grants, and execution state are not disposable because another store mirrors them.
Use the owner-approved scope and [release fences](release-operations.md) for any rebuild or migration.

Conversation metadata, Messages, Participants, and provider receipts use separate PostgreSQL relations.
Use indexed, bounded pages for growing data.
Do not reconstruct a full history on an interactive request path.

## Conversation bodies

ConversationServer routes archival through ConversationActor and its private ConversationStore.
PostgreSQL retains Message identities, revisions, accepted request facts, and published body locations.
Each cut holds at most 1,000 records and targets one MB of encoded JSONL.
A legal Message larger than that target occupies one cut. Archival adds no Message size restriction.

The owner captures Message revisions and directory locations in one PostgreSQL snapshot.
It selects the hot body prefix from bounded length headers before transferring bodies.
The existing Conversation revision distinguishes immutable object addresses within its owned segments prefix.
S3 create or adoption occurs outside the transaction.
Publication locks the Conversation and compares the captured directory and Message revisions.
It commits directory changes, Message pointers, and matching hot-body eviction together. Unrelated appends do not invalidate the cut.
S3 failure retains hot bodies. A concurrent body change retains its new revision for a later cut.

An edited archived Message becomes hot again.
Archival rebuilds a bounded prefix of that span's current view and retains the unchanged suffix location.
The same transaction remaps suffix pointers before replacing their directory entry.
Readers use locations captured in their PostgreSQL snapshot, including an old immutable object after directory replacement.
Existing tombstone cleanup removes current catalog objects and PostgreSQL facts.
Updated owners also delete retired or unpublished objects visible under the exact segments prefix, in bounded pages.
An older owner can complete deletion with uncataloged objects still present.
No subsequent automatic cleanup is promised for those objects.
An already in-flight S3 PUT can land after an empty LIST observation. That observation does not fence the PUT.

One worker per SalixIM node checks at most 16 hot Conversation scopes per tick through the partial hot-body index.
Each scope probes at most 256 hot records. The cursor advances past failed scopes and returns to the start after the last scope.
The worker archives after 30 seconds without a body change, or when 256 hot records or one MB accumulate.
PostgreSQL computes body lengths within that bounded page without transferring the bodies to the worker.
These scheduling values are workload controls, not Conversation capacity limits.
`body_updated_at` records body activity for this schedule. Imported and old rows use the epoch to become eligible immediately.
Metadata-only changes do not postpone archival.
The separate body-cleanup operation only converges residual bodies from older publications. Ordinary publication already evicts its cut.

## Internal Session history

The retained S3 Session prefix is `agents/{agent_id}/internal_runtime/sessions/{Crypto.hex(session_id)}/`.
`Crypto.hex` is the existing hash-addressing function, not a direct hexadecimal encoding of the Session ID.

Ordinary Session commits update PostgreSQL inputs, control, records, source progress, and due state in one transaction.
They do not write a hot S3 snapshot. Imported history retains its published segment locations and supported encoding.
Frozen JSONL ranges retain their original object key, byte offset, and length in the same PostgreSQL directory as ETF segments.
Readers use the recorded encoding. Import does not rewrite these history bodies or require a separate format conversion.
A reload captures control, inputs, hot records, context, and directory pages in one short REPEATABLE READ transaction.
S3 downloads follow that transaction and use its captured locations. They do not reconstruct a key from the current Session identity.
The reader restores cold records needed above `compacted_seq` and retained terminal-call references.
It restores named message fields through a fixed schema. Free metadata keys stay strings, and identity values keep their stored types.
PG record payloads use trusted ETF decoding, like Session snapshots. Kernel deltas supply these payloads through the owner encoder.
Record reads preserve ETF values and distinct atom and binary keys, even when the current VM has not loaded an older atom.
Control, context, queue inputs, and dedupe identities retain their existing safe decoding.
Archive shaping still converts map keys to strings recursively. Same-name atom and binary keys can merge there.
`compacted_seq` controls logical context release. `archived_through` identifies published body locations and does not remove uncompacted runtime context.
History pages merge each record once, even when the runtime context contains records from an archive.
Do not add writes to the old JSONL archive.
Use OTP zstd. Cross-OTP byte equality is not a durable protocol guarantee.

History search indexes canonical records in PostgreSQL, then transfers complete records to ClickHouse.
A bounded HTTP read must confirm the exact cold documents before hot document deletion.
Table-name substitution preserves literal document content.

Failed confirmation preserves hot documents. The existing `checked_at` field delays retries five seconds across Pods, including direct hints.
Canonical indexing and body archival continue independently. Oversized records remain hot without reporting a storage failure.

New materialized user and runtime messages keep `accepted_input`: `{queue_id, kind, dedupe_key, payload}` from the canonical queue item.
This immutable value keeps the full accepted payload, including attachment, origin, billing, and reply-obligation metadata.
It is part of the Session record, not a separate ledger or authority for billing or reply state.
Flat message fields stay consumer projections. Model, compaction, and public history views omit `accepted_input`, so it cannot bypass disclosure or attachment policy.
The sealing byte bound counts these bytes. Older records lack this value and cannot recover discarded metadata.

### Sealing and recovery

Deploy the reader that restores uncompacted cold context to all serving nodes before deploying this producer.
Record commits raise the archive target to committed `last_seq`. Logical compaction remains independent.
The existing global worker discovers 256 pending records or a tail idle for 30 seconds, using `last_activity_at`.
Each discovery page returns at most 128 control rows and advances past rows that are still waiting.
An admitted hint also inspects at most 256 payload lengths against the existing 16 MiB segment line.
Continuous input drains through bounded visits, and idle tails close without model compaction.
New cuts stop at 256 records or the first byte-line crossing, including an oversized record.
A matching landed segment retains its original boundary.

S3 create or adoption finishes outside the PostgreSQL transaction.
Publication locks the Agent and Session, then commits the directory, archive watermark, and cut's body deletion together.
It increments the SQL revision while preserving business storage identity, control, runtime epoch, accepted inputs, dedupe facts, and source progress.
An owner write with the same base storage identity lands above the watermark and reloads.
It clears a reached target and preserves a newer pending target. Later appends do not invalidate an immutable captured prefix.
An S3 failure or rejected SQL transaction keeps the cut unpublished and its PG bodies available.
An unknown commit result settles the same captured publication through its directory entries.

After the reader and producer rollouts complete, an operator can run `SalixAgent.SessionHistory.ArchiveEviction.run()` through release eval.
`run(agent_id: id)` limits an initial pass to one Agent. The runner starts database and object transports without Session Actors.
It scans PG metadata in keyset pages with four concurrent archive visits.
Revision-one materialized Sessions admit immediate transfer. Existing pending targets authorize continuation after a restart.
The pass raises missing or partial targets to committed `last_seq`. A later-revision Session transfers only its previously pending prefix immediately.
The normal worker receives its newly queued tail. A business change after capture returns the item to normal processing.
The pass also removes old, already-published duplicate bodies through the existing directory.
New publications need no separate cleanup phase. Per-item failures retain pending work while other Sessions continue.

A missing segment, bad encoding, noncontiguous sequence, or mismatched catalog returns `{:archive_incomplete, detail}`.
Transport failure returns `:archive_unreadable`.
Do not return an empty page or `:not_found` for unreadable committed history.
Page request counts are bounded, but transferred bytes depend on the selected segment sizes.

## Capability import delivery

For non-cancelled requests with stored results, the S3 importer reads one control snapshot per scoped Session in a page.
It reads only required indexed results or exact cold references. Running calls stay due.
Existing terminals end delivery with the current check time without replacing the Session result. Cancelled requests stay inactive.
Missing evidence stops the exact source object. Existing request and tool bindings must agree for running calls.
Pre-handoff intents can lack `capability_request_id` or callback mode. Requests without results retain their existing import behavior.
If a legacy request has no deadline, import applies the request owner's existing deadline policy from its original creation time.
Import preserves its status, result, and source object. An explicit deadline remains unchanged.

## Comma Task search

`GET /v1/comma/groups/:group_id/conversations/search?q=...&limit=...` requires authorization for the exact Group.
It calls `SalixIM.Conversations.search_group_tasks/3` for `agent_task` Conversations.
`GET .../conversations/:conversation_id/search?q=...` lists one Task's matching Messages (id, `seq`) by `seq`.
Task search uses an `agent_task` allowlist. Every other nonempty string kind is a non-Task, including unknown kinds.
Discovery skips these Conversations; queued projection work removes their old Task projection.
Missing or malformed kinds, mismatched identities, and invalid metadata still fail validation.
`search_group_conversations` is not a fallback or a migration reader.
Unavailable or unsealed generations fail closed. Queries never scan canonical S3.

Canonical Conversation mutations enqueue search work in the same PostgreSQL transaction.
The explicit release backfill captures an upper key and scans bounded canonical pages.
Each page commits its jobs and cursor together. The existing writer barrier, completed scan, and drained jobs permit sealing.
A sealed generation does not start another discovery cycle. Subsequent mutations use the transactional jobs.
Freshness depends on worker service capacity and available dependencies.

## Message-search publication

Message search has a separate ClickHouse component projection and PostgreSQL publication protocol.
A PostgreSQL source epoch cannot prove which ClickHouse body survived a late write.
A frozen `source_write_id` travels in the durable write intent and the canonical row.
It is write identity, not a content digest or authenticity credential.
Retries reuse the frozen row and ID. New observations create new intents.

Source admission increments the epoch and stores the intent transactionally before provider ACK.
Canonical Message and required payload writes must ACK before the exact intent is removed. Unknown results stay replayable.
Background builds capture source IDs, epochs, file state, and a globally allocated build sequence under the relevant source locks.
Locks do not span provider, GPU, or ClickHouse calls.
Complete components enter ClickHouse before the PostgreSQL owner publishes them. An unpublished component is not query-visible.

A query ranks at most 200 distinct candidate Messages, then:

1. Read canonical FINAL primary keys, write IDs, and deletion state from both source tables.
2. Check current PostgreSQL publication, source and file epochs, and absence of pending writes.
3. Recheck the tenant and Group, current installation, workspace, and channel source relationship.
4. Read snippets only for the authorized, current page.

Only immutable keys belong in PREWHERE before FINAL. Do not filter out tombstones early.
Every continuation page repeats these checks and keeps the original expiration.
The continuation window contains no body, vector, or unauthorized candidate content.

Before the first new-reader rollout, all source writers must use admission and frozen write identity.
Before a rollback to a writer without them, stop new-search results.
Use approved mainline artifacts and the source-owner preparation stage, not a legacy-search fallback.

### Slack index scheduling

Oban owns text, file, and enumeration jobs in `slack_semantic.oban_jobs`.
Releases preserve every pending job ID, attempt, scope, and recovery state.

Admission commits source epochs, channel provenance, and canonical write intents together.
Each source retains its fixed dispatch epoch, installation cursor, and due time.
One transaction inserts at most 20 installation jobs and advances that cursor.
A newer epoch waits for the current round to finish. Each page then yields to other due sources.
Live priority covers every pending epoch.
Due live sources dispatch first. Pending canonical writes defer dispatch without holding an executor.
The existing Queue processes at most 20 source pages per turn, apart from canonical initialization.
Persistent pending epochs recover lost notifications.

Authenticated channel observation seeds one finite initialization cursor in the same transaction.
Connect workspace and activation changes initialize retained channels in bounded pages.
Canonical pages read outside PostgreSQL locks. Cursor checks fence their transactional job commits.
Completed cursors cause no further canonical reads or jobs.
Editable file publications schedule a one-hour refresh. Inaccessible files retain their Oban retry.
The migration initializes existing sources and canonical channels once.

`SlackSemanticEngine` uses indexed probes and bounded claims, then delegates settlement and recovery to Oban Basic.
Available live work wins dispatch. Executing live work holds its lane. Delayed retries do not hold lanes.
Live text also preempts historical media. Live files do not block historical text.
Running historical builds yield cooperatively.
Retries retain jobs and wait at most five minutes. Preemption retries after one second.
New jobs do not coalesce with old executors.

### Mail Task associations

Task `source_refs.comma_mail` stores the connection, thread, message, and source URL. The Conversation stays its owner.
A reconnect can change the connection ID. No cross-account or cross-reconnect mailbox identity is inferred.
One thread can have several Tasks. A lookup never claims uniqueness.
ConversationSearch projects the account and thread into an indexed positive lookup within its existing writer generation.
Incremental Message indexing requires matching association fields or rebuilds the canonical snapshot.
The Routine lookup verifies the Group, Task kind, Router, account, and thread again. Ambiguous or missing hits stay unknown.
The lookup columns are disposable projections. They do not change canonical Task facts or the search cutover procedure.

## Browser Run settings and runtime resources

Provider tokens use scope-bound AES-GCM under `compute_workload_credential_secret`.
`SalixStore.BrowserStorage` uses a separate derived key with tenant- and Group-bound AES-GCM.
Encryption protects against database disclosure and cross-scope copies, not application compromise.
Preserve the root secret with the database. Missing keys fail closed. Adapters decrypt.
Logs suppress secrets. Public responses omit stored contents.

Saved storage belongs to `(tenant_id, group_id)`.
Router and Worker tasks share HttpOnly cookies and first-party local storage.
Signing in grants those tasks account access. Comma shows this scope.
Storage survives closure, task completion, Agent changes, and same-Group migration.
Replacement Groups need explicit storage transfer or the original identity.
Group deletion holds admission. Failure preserves storage and admission. Success clears storage and rejects late admission.

To clear an open browser, use **Clear shared logins**, then **Clear and close**.
With no active browser, use **Settings > General > Shared browser logins**.
Both human-only paths keep ownership through clearing. Failed deletion keeps data and ownership.
Clear rejects stale saves. With no saved batches it returns `browser_storage_not_saved`. A later failure returns `browser_storage_partially_saved`. Committed batches survive.

Commands check user and workspace authorization and exact tenant and Group scope.
Restricted Task-panel sessions have no access. Provider tokens, IDs, and CDP URLs never reach Comma.
Electron reuses main-owned `/v1`, without renderer credentials or new capabilities.
The Browser header requires the current Participant's ready browser.
Visible chats check one Participant and binding at first and ten seconds after completion.
Hidden or inactive surfaces skip checks. Windows check the main and selected sidebar chats.
Each chat has one request, a ten-second timeout, and no Agent or workspace scan. Close refreshes the UI.

Agent actions (`navigate`, `click`, `fill`, `press`, `scroll`, `select`, `wait`, `dialog`) return a receipt: URL, title and a viewport snapshot of the page after the action.
An action that starts a navigation waits for the new document; while it has not committed, the receipt says `loading` instead of a snapshot.
`browser.actions` runs up to ten steps in one command and stops at the first step that cannot run, which it reports with the steps completed.
A snapshot is an indented outline of roles, names and states. Interactive elements carry refs (`e12`) that stay valid until the tab navigates.
Targets are a ref, visible text, a role with a name, or a CSS selector, and must match one visible element.
A failure before any input reaches the page (no target, an ambiguous target, a stale ref, a wait timeout, an open dialog) releases admission at once.
An open JavaScript dialog blocks page reads and actions until `browser.dialog` accepts or dismisses it.

`browser.request_control` pauses agent mutations, which require agent control, and returns user instructions.
Takeover requires no pending operation and grants one user, auth session, and viewer a ten-second input lease.
Streams renew it every two seconds. Other viewers are read-only.
Disconnect never resumes the agent. After expiry, another authorized viewer can take control.
Return releases modifiers and buttons, reads the page, saves storage, and restores agent control.
Authorized close permits recovery during pending operations or handoff.
Mouse, wheel, key, and text commands serialize in 32 queue slots. Text supports paste and IME.
Input failure stops the queue and reports uncertainty.

See [browser verification](testing.md#browser-run).
