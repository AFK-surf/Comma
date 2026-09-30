# Storage and search

## Durable facts and projections

Canonical Conversation metadata, Message slots, and explicit tombstones remain in S3.
PostgreSQL Task search is a bounded rebuildable projection, not a source of Conversation truth.
Control metadata, credentials, billing grants, and execution state are not disposable merely because another store can mirror them.
Use the owner-approved scope and [release fences](release-operations.md) for any rebuild or migration.

Conversation metadata, Messages, Participants, and provider receipts are separate collections.
Use segmented or directory-sharded access for growing data.
Do not reconstruct a full history on an interactive request path.

## Internal Session format 3

The Session prefix is `agents/{agent_id}/internal_runtime/sessions/{Crypto.hex(session_id)}/`.
`Crypto.hex` is the existing hash-addressing function, not direct hexadecimal Session-ID encoding.

- `state.etf.zst` contains state, permanent delivery deduplication, live references, segment catalog, optional old archive prefix, and the hot window.
- `segments/{first_seq:020d}.etf.zst` contains a create-once immutable record list.
- Records have `seq`, binary `kind`, and string-keyed `data`. Key normalization traverses maps and lists, but leaves tuples unchanged.
- The hot envelope is `{:comma_internal_session, 3, state}`.
- New objects use ETF in one zstd frame, normally level 3.

The reader accepts format 3 and the supported old snapshots/archives.
New writes use format 3. A first business write can publish the new hot object while retaining a read-only old archive prefix.
Do not add writes to the old JSONL archive.
Use OTP zstd. Cross-OTP byte equality is not a durable protocol guarantee.

New materialized user and runtime messages retain `accepted_input`: `{queue_id, kind, dedupe_key, payload}` from the canonical queue item.
This immutable value retains the full accepted payload, including attachment, origin, billing, and reply-obligation metadata.
It is part of the existing Session record, not a separate ledger or authority for billing or reply state.
Flat message fields remain consumer projections. Model, compaction, and public history views omit `accepted_input` so it cannot bypass disclosure or attachment policy.
This duplicates some projected content and increases record size. The existing byte-bounded sealing path also measures these bytes.
The change retains format 3 and existing records. Historical records lack this value and cannot reconstruct previously discarded metadata.

Each catalog entry is `[first_seq, last_seq, message_count, measured_bytes]`.
The old prefix and new segments together cover `1..archived_through` exactly.
The hot-state ETag CAS publishes the catalog and its watermark together.
History reads follow the committed catalog with zero LIST calls.
Unreferenced segments are invisible but can be adopted by a later sealing attempt.
`measured_bytes` is a writer diagnostic, not an authenticated object size or decompression bound.

### Sealing and recovery

Compaction completion calls `InternalSessionStore.archive_compacted`.
Sealing failure keeps history hot and does not itself block processing.
Ordinary flush does not promise archival or create another retry worker.

1. Read a durable revision with its ETag, contiguous window, catalog, watermark, and compaction ceiling.
2. Read the exact next segment key from `archived_through + 1`.
3. Validate an existing winner against the captured record prefix.
4. Adopt its boundaries when records agree, even if another writer chose different segment sizes.
5. Otherwise create a segment through `Settle.create_once` within the captured ceiling.
6. Apply `archive_advance` to that revision and CAS against its captured ETag.

On a CAS conflict, read a new revision and repeat publication within the existing commit retry budget.
Never apply the old archive event to a different revision.
The optional caller Session is a hint. The sealer always reads the current durable revision before publication.
An existing segment beyond the captured window returns `:archive_ahead`. A later call reads a fresh revision.
Different records or malformed segments return `{:segment_divergence, key}`.
The Lean `archive_match_prefix` query compares complete, locally re-encoded ETF values after decode.
It preserves numeric types and float bits, but permits different stored compression bytes.
Only retired `activation_key` diagnostics in `runaway_guard_reset` and `runaway_unsettled_round` facts are excluded.
Message input metadata remains authoritative. FFI input contains only the current segment and its matching captured prefix.
The ordinary publisher keeps its captured window in a resident Lean cursor and generates the final `archive_advance` event there.
The host executes storage and codec requests. It does not select new segments or assemble that event.
Ambiguous create settlement must finish before the catalog advances.
A crash between object creation and catalog commit leaves an adoptable orphan, not visible history.
Redaction is a read-side overlay. It does not rewrite immutable records.

The default sealing line is 16 MiB, configurable by `:salix_store, :seal_line_bytes`.
It is a segment fill target, not a minimum archive size or a hard Session-size bound.
The current Lean encoder measures new cuts. Different encoder versions can choose different cuts and diagnostic byte counts.
The final segment closes at the captured compaction ceiling even when smaller than the target.
Confirmed archive publication removes that compacted prefix from hot messages, facts, and inline results.
Records above the compaction ceiling stay hot. One oversized record can exceed the target.
Catalogs and permanent deduplication still grow with history.
After failure, another compaction or explicit call must retry sealing.

A missing segment, bad encoding, noncontiguous sequence, or mismatched catalog returns `{:archive_incomplete, detail}`.
Transport failure returns `:archive_unreadable`.
Do not return an empty page or `:not_found` for unreadable committed history.
Page request counts are bounded, but transferred bytes depend on the selected segment sizes.

## Comma Task search

`GET /v1/comma/groups/:group_id/conversations/search?q=...&limit=...` requires authorization for the exact Group.
It calls `SalixIM.Conversations.search_group_tasks/3` for canonical `agent_task` Conversations.
Legacy `search_group_conversations` is not a fallback or a migration reader.
Unavailable or unsealed generations fail closed. Queries never scan canonical S3.

The trimmed raw and folded query each contain 2 to 128 Unicode code points.
Folding applies NFKC, OTP full case fold, then NFKC per extended grapheme.
The limit is 1 to 50, default 20.
Results have one primary hit per Task, canonical update time, snippet, and end-exclusive UTF-16 highlight ranges.
Title wins when both fields match. An optional atomic `content_match` supplies the newest retained matching Message subtitle.

The projection keeps at most 65 documents per Task:

- A grapheme-safe title prefix up to 16 KiB.
- The latest 64 Message slots, selected before empty-text filtering.
- At most 32 KiB each of original and folded text per Message.
- A 256 KiB Message budget charged by the larger original/folded size.

Total persisted text is at most 560 KiB before row, index, and storage overhead.
Reconstruction can transfer about 64 MiB across 64 immutable Message segments.
That work belongs to the background projector, not a query.

SQL produces at most `limit` title candidates and `limit * 64` Message candidates.
A 250 ms statement timeout is the hard execution bound.
Candidate limits do not bound the index entries PostgreSQL inspects.
Ordering applies within the bounded subset, not all matching Tasks.
The API does not promise globally newest, globally most relevant, or repeat-stable selection.

Discovery is permanent key-ordered traversal, not an atomic S3 snapshot.
A seal permits the reader but does not prove an exact baseline.
Freshness converges under stable dependencies, fair workers, and finite/quiescent input or arrivals below service capacity.
One Group drains before later Groups, so fairness alone does not establish that capacity condition.
Use one complete discovery-cycle SLA as the operational freshness objective.

## Message-search publication

Message search has a separate ClickHouse component projection and PostgreSQL publication protocol.
A PostgreSQL source epoch cannot prove which ClickHouse body survived a late write.
A frozen `source_write_id` travels in the durable write intent and the canonical row.
It is write identity, not a content digest or authenticity credential.
Retries reuse the frozen row and ID. New observations create new intents.

Source admission increments epoch and stores the intent transactionally before provider ACK.
Canonical Message and required payload writes must ACK before the exact intent is removed.
Unknown results remain replayable.
Background builds capture source IDs, epochs, file state, and a globally allocated build sequence under the relevant source locks.
Locks do not span provider, GPU, or ClickHouse calls.
Complete components enter ClickHouse before the PostgreSQL owner publishes them.
An unpublished component is not query-visible.

A query ranks at most 200 distinct candidate Messages, then:

1. Read canonical FINAL primary keys, write IDs, and deletion state from both source tables.
2. Check current PostgreSQL publication, source/file epochs, and absence of pending writes.
3. Recheck tenant/Group, current installation, workspace, and channel source relationship.
4. Read snippets only for the authorized, current page.

Only immutable keys belong in PREWHERE before FINAL. Do not filter out tombstones early.
Every continuation page repeats these checks and keeps the original expiration.
The continuation window contains no body, vector, or unauthorized candidate content.
Current-installation checks cover at most 64 connects with concurrency four and a three-second total wait.
The facade has a ten-second deadline. ClickHouse retains its two-second execution budget.

These observations are not a cross-store linearizable snapshot.
Do not promise complete history under permanent webhook loss, infinite changes, or permanent dependency failure.
Known invalidation fails closed. Background sweep repairs mismatches, not an extra query-time scan.

Before first new-reader rollout, all source writers must participate in admission and frozen write identity.
A rollback to a nonparticipating writer must stop new-search results first.
Use approved mainline artifacts and the source-owner preparation stage, not a legacy-search fallback.
Do not infer live deployment enablement from historical experiments.

### Mail Task associations

Task `source_refs.comma_mail` stores the connection, thread, message, and source URL. The Conversation remains its owner.
A reconnect can change the connection ID. No cross-account or cross-reconnect mailbox identity is inferred.
One thread can have several Tasks. A lookup never claims uniqueness.
ConversationSearch projects the account and thread into an indexed positive lookup within its existing writer generation.
Incremental Message indexing requires matching association fields or rebuilds the canonical snapshot.
Routine reads at most 40 canonical Task records, with four concurrent reads and a 1.5-second lookup budget.
It verifies the Group, Task kind, Router, account, and thread again. Ambiguous or missing hits remain unknown.
A confirmed association shows that Task, and its Routine row opens that Task. Other Gmail rows keep their pre-task prompt. The member confirms it, as for other sources.
Completed and stopped Tasks are omitted. The client uses existing Task summaries to hide stale stopped rows.
A deleted target never falls back to Task creation. Other source actions retain their existing behavior.
The additive lookup columns contain disposable projections. They do not change canonical Task facts or the existing search cutover procedure.

## Browser Run settings and runtime resources

`BrowserSettings` owns Postgres configuration. `/dash/browser` requires platform-admin authentication.
Modes: `inherit`, `override`, `disabled`. Missing settings inherit the initially disabled default.
Account, token, timeouts, and hostnames form one configuration. Invalid overrides fail.
Blank tokens preserve saved values. Account changes require a token.
Connection tests create/delete browsers and consume usage.

Provider tokens use scope-bound AES-GCM under `compute_workload_credential_secret`.
`SalixStore.BrowserStorage` uses a separate derived key with tenant/Group-bound AES-GCM.
Encryption protects database disclosure and cross-scope copies, not application compromise.
Preserve the root with the database. Missing keys fail closed. Adapters decrypt.
Logs suppress secrets. Public responses omit stored contents.

Saved storage belongs to `(tenant_id, group_id)`.
Router/Worker tasks share HttpOnly cookies and first-party local storage.
Signing in grants those tasks account access. Comma displays this scope.
Storage survives closure, task completion, Agent changes, and same-Group migration.
Replacement Groups need explicit storage transfer or the original identity.
Group deletion holds admission. Failure preserves storage/admission. Success clears storage and rejects late admission.

`BrowserBindings` owns `(agent_id, session_id)` browser identity, control, credentials, and pending commands.
A Group advisory lock serializes admission. Active bindings reject other tasks with `browser_shared_profile_in_use`.
Only provider-confirmed closure releases ownership, never command inactivity or driver loss.
Close pre-upgrade browsers before shared use. They cannot save shared storage.
Additive migrations preserve existing facts and need no exclusive cutover.
Existing browsers retain policy/cleanup credentials. New browsers use current settings.
Explicit disable rejects commands and viewing at the next authorization check. Close and clear remain available.
Close clears binding credentials and retains saved website storage.

`SalixAgent.Browser` records command admission under SQL row locks.
Background saves preserve command admission and human control. Commands queue behind exports.
Writes compare provider ID, pending state, and command/save times to reject stale results.
Creation restores storage before readiness. Reconnection never restores old values.
Transfers use private intercepted HTML, bypass service-workers/cache, and make no website requests.
Excluded: IndexedDB, sessionStorage, cache, service workers, and partitioned third-party local storage. Opaque cookie partition keys fail saves.

Each active Group has one save worker/timer, 15 seconds after activity/save completion.
Each save captures cookies and four origins, preserves other origins, and applies deletions.
Empty origins leave. Live frames return next scan. No Group/Agent/Task scans.
Return-control/normal close drain batches within 15 seconds. Transfers have a 15-second timeout.
Interrupted commands skip final saves because their remote outcomes remain uncertain.
Saves stop after command inactivity. Viewing streams do not renew activity.

Cookies, local storage, and recency share 1 MiB per Group, without count limits.
Overflow evicts least recently used cookies/whole origins. Active website storage is unchanged.
Recency uses observed website activity and cookie changes. CDP has no cookie access timestamps.
Exports/restores do not refresh origin recency. Evicted logins can require reauthentication.
`storage_error` reports save failure. `browser_storage_checkpoint` records latency/failure, without contents.
Recovery uses saved batches. Unsaved changes can be lost. Checkpoints are not atomic across sites.

Use **Clear shared logins**, then **Clear and close**, to clear an open browser.
With no active browser, use **Settings > General > Shared browser logins**.
Both human-only paths retain ownership through clearing. Failed deletion retains data/ownership.
Clear rejects stale saves. No saved batches: `browser_storage_not_saved`. Later failure: `browser_storage_partially_saved`. Committed batches survive.

Elixir CDP uses Mint to avoid Playwright's Node process.
Mint owns TLS/framing/handshake. Adapters own correlation/bounded targets.
Tools expose no arbitrary scripts. DOM inspection uses isolated worlds and CDP handles.
Frames remain available during navigation/waits/input.
Fills select existing values and preserve CDP input events.
Text waits normalize inline rendered text: at most 10,000 elements and 32,000 characters/element.
Global OTP addresses share drivers. SQL owns admission across distribution failure.
HTTP lifecycle calls never retry. Driver loss, connection conflicts, and uncertainty never replay commands.
Unknown outcomes retain admission. Close can interrupt them. Close, then open, to recover.
Lost creates permit admission recovery or close after idle timeout plus 60 seconds. Late results cannot replace recovery.

Cloudflare idle expiry: default 60 seconds, maximum 600.
Admission checks the holder, including self. Known IDs require provider-confirmed expiry. Lookup errors retain ownership.
Self-open restores expired browsers and preserves live tabs. Passive streams/checkpoints cannot renew or restart an idle driver.
Commands renew its ten-minute window. Human leases retain it until expiry. Handoff does not.
At idle expiry, check one binding, then at lease expiry. Refresh resumes a stopped viewer.
Listings return the latest 50 active bindings. Each Runtime Session has one browser.
Tab responses contain at most 32 tabs. A transfer adds one private target.
Snapshots allow 100 element references and 32,000 text characters.
References expire after navigation, snapshot, or driver replacement. Page content is untrusted.
Screenshots use the authorized workspace file path and journal seam.
Tools retain admission, IFC, and archive boundaries. Unknown tools retain conservative public-egress classification.

Commands check user/workspace authorization and exact tenant/Group scope.
Restricted Task-panel sessions have no access. Provider tokens/IDs/CDP URLs never reach Comma.
Electron reuses main-owned `/v1`, without renderer credentials or new capabilities.
The Browser header requires the current Participant's ready browser.
Visible chats check one Participant/binding initially and ten seconds after completion.
Hidden/inactive surfaces and Side Chats skip checks. Windows check main/selected sidebar chats.
Each chat has one request, a ten-second timeout, and no Agent/workspace scan. Close refreshes the UI.

Each tab has one renewable 30-second SSE stream with two-second authentication/workspace/settings/binding checks.
Revocation takes at most two seconds. Commands authorize immediately.
Viewers sample at most ten JPEGs/second, each at most 1280 by 720 pixels and 1.4 MB encoded.
Screencast commands execute in order with 32 queue slots and a 35-second budget including queue time. Timeout closes without replay.
Viewers wait for stops. Repeated frames are omitted. Hidden panels cancel streams. No workspace-wide polling occurs.

`browser.request_control` pauses agent mutations, which require agent control, and returns user instructions.
Takeover requires no pending operation and grants one user/auth-session/viewer a ten-second input lease.
Streams renew it every two seconds. Other viewers are read-only.
Disconnect never resumes the agent. After expiry, another authorized viewer can take control.
Return releases modifiers/buttons, reads the page, saves storage, and restores agent control.
Authorized close permits recovery during pending operations or handoff.
Mouse/wheel/key/text commands serialize in 32 queue slots. Text supports paste and IME.
Input failure stops the queue and reports uncertainty.

See [browser verification](testing.md#browser-run).
