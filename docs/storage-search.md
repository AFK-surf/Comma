# Storage and search

## Durable facts and projections

Canonical Conversation metadata, Message slots, and explicit tombstones stay in S3.
PostgreSQL Task search is a bounded rebuildable projection, not a source of Conversation truth.
Control metadata, credentials, billing grants, and execution state are not disposable because another store mirrors them.
Use the owner-approved scope and [release fences](release-operations.md) for any rebuild or migration.

Conversation metadata, Messages, Participants, and provider receipts are separate collections.
Use segmented or directory-sharded access for growing data.
Do not reconstruct a full history on an interactive request path.

## Internal Session format 3

The Session prefix is `agents/{agent_id}/internal_runtime/sessions/{Crypto.hex(session_id)}/`.
`Crypto.hex` is the existing hash-addressing function, not a direct hexadecimal encoding of the Session ID.

The reader accepts format 3 and the supported old snapshots and archives. New writes use format 3.
A first business write can publish the new hot object and keep a read-only old archive prefix.
Do not add writes to the old JSONL archive.
Use OTP zstd. Cross-OTP byte equality is not a durable protocol guarantee.

New materialized user and runtime messages keep `accepted_input`: `{queue_id, kind, dedupe_key, payload}` from the canonical queue item.
This immutable value keeps the full accepted payload, including attachment, origin, billing, and reply-obligation metadata.
It is part of the Session record, not a separate ledger or authority for billing or reply state.
Flat message fields stay consumer projections. Model, compaction, and public history views omit `accepted_input`, so it cannot bypass disclosure or attachment policy.
The sealing byte bound counts these bytes. Older records lack this value and cannot recover discarded metadata.

### Sealing and recovery

Compaction completion calls `InternalSessionStore.archive_compacted`.
Sealing failure keeps history hot and does not block processing.
Ordinary flush does not promise archival or create another retry worker.

A missing segment, bad encoding, noncontiguous sequence, or mismatched catalog returns `{:archive_incomplete, detail}`.
Transport failure returns `:archive_unreadable`.
Do not return an empty page or `:not_found` for unreadable committed history.
Page request counts are bounded, but transferred bytes depend on the selected segment sizes.

## Comma Task search

`GET /v1/comma/groups/:group_id/conversations/search?q=...&limit=...` requires authorization for the exact Group.
It calls `SalixIM.Conversations.search_group_tasks/3` for canonical `agent_task` Conversations.
`search_group_conversations` is not a fallback or a migration reader.
Unavailable or unsealed generations fail closed. Queries never scan canonical S3.

Discovery is permanent key-ordered traversal, not an atomic S3 snapshot.
A seal permits the reader but does not prove an exact baseline.
Freshness converges under stable dependencies, fair workers, and finite or quiescent input, or arrivals below service capacity.
One Group drains before later Groups, so fairness alone does not establish that capacity condition.
Use one complete discovery-cycle SLA as the operational freshness objective.

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

`browser.request_control` pauses agent mutations, which require agent control, and returns user instructions.
Takeover requires no pending operation and grants one user, auth session, and viewer a ten-second input lease.
Streams renew it every two seconds. Other viewers are read-only.
Disconnect never resumes the agent. After expiry, another authorized viewer can take control.
Return releases modifiers and buttons, reads the page, saves storage, and restores agent control.
Authorized close permits recovery during pending operations or handoff.
Mouse, wheel, key, and text commands serialize in 32 queue slots. Text supports paste and IME.
Input failure stops the queue and reports uncertainty.

See [browser verification](testing.md#browser-run).
