# Salix subscription SDK adapter

Salix owns subscription accounts, tenant access, encrypted credentials, OAuth attempts, quota snapshots, and account selection.
This Go worker executes a supplied credential through the native CLIProxyAPI executors.
It has no account database, tenant registry, Manager, model-registration lifecycle, or background quota worker.

## Build and run

`mix compile` builds `priv/subscription_worker` through the account-proxy Makefile.
The local build requires Go and Git.
The systems image uses a Go build stage and copies the binary into the Salix release.
The build uses CLIProxyAPI v8.0.4 at commit `d33f63f8e3d98428440ebca5a5b6a981a61ff71e` and `patches/embedded-sdk.patch`.
The patch exports `NewSubscriptionExecutor`, `oauth.Begin`, `oauth.Exchange`, and split-phase Codex device authorization helpers.
The adapter uses native request conversion and disables Claude prompt cloaking.
The pinned SDK's static model table rejects newer Codex reasoning efforts, including `ultra`.
`SubscriptionModelRequest` uses its existing request-local user-defined-model path.
It preserves selected model and effort values through normal SDK conversion. Codex validates support.
Adapter tests cover this behavior for blocking and streaming requests.

For Go tests, run:

```sh
./bootstrap.sh
go test -race ./...
```

Set `subscription_proxy.storage_key` in Salix `config.json` to a persistent 32-byte key encoded in Base64.
If this field is absent, Salix reads `SALIX_SUBSCRIPTION_STORAGE_KEY` from the environment.
Without a key, Salix starts, but subscription operations fail with a configuration error.
Keep the existing key when you update a deployment.
The worker requires no service token, listener, separate image, storage volume, or encryption key.
Remove `SALIX_SDK_BASE_URL`, `SALIX_SDK_TOKEN`, and the old adapter container from deployment configuration.

## Reconnect an account

Imports and OAuth additions match accounts by tenant, provider, and email.
Email matching ignores case and surrounding spaces. Missing emails do not match.
The email comes from normalized credential metadata. It does not prove authorization.
A match keeps the record ID and disabled setting, replaces credentials, and changes the record version.
It clears prepared state, quota, expiry, and cooldown, then schedules a fresh quota poll.
A late refresh with the previous version cannot overwrite the new credentials.
Concurrent additions serialize in a database transaction with a five-second lock timeout.
The email index bounds lookup to one record. Existing duplicate rows are not deleted by this change.

## Codex reset credits

The pinned CPA SDK has no reset-credit operation. It supplies authenticated HTTP through `ProviderExecutor.HttpRequest`.
The adapter extends the existing `GET /wham/usage` parser to read `rate_limit_reset_credits.available_count`.
The public snapshot stores this as `quota.reset_credits.available_count`.
A missing or invalid count means unknown, not zero. Claude does not expose this capability through this adapter.
The existing bounded quota worker updates this count. The account list does not add provider requests or polling.

The reset operation posts to `/wham/rate-limit-reset-credits/consume` on the existing ChatGPT backend origin.
It sends the selected account credentials and one `redeem_request_id`.
The backend chooses an available credit. This version does not list or select individual credits, or purchase credits.
See the [upstream request implementation](https://github.com/openai/codex/blob/654b0a77d0d2f81aa21f61caf7af4be88fe550bb/codex-rs/backend-client/src/client/rate_limit_resets.rs).

`AccountPool.reset_quota/3` accepts `version` and `request_id`.
A new request requires the current account version. The owner saves a pending `reset_attempt` before the provider call.
Another request cannot replace a pending attempt. Retries reuse its key, including after a browser reconnect or process restart.
The provider owns redemption deduplication. Salix retains the last attempt in the account JSON, not an unbounded history.
The stored key identifies an operation. It is not a credential or authorization boundary.
Credential replacement clears the attempt. A stale result cannot overwrite replaced credentials because the write checks the record version.

The provider returns `reset`, `already_redeemed`, `no_credit`, or `nothing_to_reset`.
Transport errors and unknown responses leave the attempt pending. Retry that attempt, not a new request.
After a confirmed result, the owner reads quota again. It never sets local allowance to 100 percent.
A failed follow-up read returns the confirmed outcome with `quota_refreshed: false` and the previous snapshot.
The user can refresh allowance without another reset. Existing provider cooldown policy stays unchanged.

The shared Salix and BFT dashboard shows the count and asks for confirmation before a reset.
BFT applies the existing organization owner/admin check. The workspace API applies its existing full-session owner check.
Logs use `subscription_account_reset` and the existing worker operation events. They exclude credentials and redemption keys.
Tests use synthetic provider responses. A real reset consumes account rights and requires separate operator approval.

This adds optional fields to the existing account JSON. It changes no credential format and requires no migration.
Retained TLA+ models are unchanged: this feature uses the existing account CAS and provider-owned deduplication contract.
Regression tests cover pending retries, tenant access, credential replacement, and response-loss recovery.

## Subprocess protocol

`SalixAgent.SubscriptionWorker` owns one local Go subprocess per Salix node.
It starts the subprocess on the first call.
Each frame contains a four-byte big-endian length followed by JSON.
Standard output carries protocol frames only. Logs use standard error.

A `call` contains a unique request ID, operation, JSON body, and optional selected credential.
Operations retain their path names, but they are local dispatch names, not HTTP endpoints.

| Operation | Result |
| --- | --- |
| `/normalize` | Normalized imported credentials and email |
| `/prepare` | Refreshed credentials and native account metadata |
| `/quota` | Normalized quota windows and optional Codex reset-credit count |
| `/quota/reset` | Result of one Codex reset-credit request |
| `/oauth/begin` | Authorization URL and private PKCE context |
| `/oauth/exchange` | Provider credentials |
| `/oauth/device/begin` | Private device ID, user code, verification URL, and polling interval |
| `/oauth/device/poll` | One provider check: pending status or normal Codex credentials |
| `/v1/responses` | Native Codex JSON or SSE bytes |
| `/v1/responses/compact` | Native Codex compaction result |
| `/v1/messages` | Native Claude JSON or SSE bytes |
| `/v1/images/generations` | Codex image generation through the SDK image adapter |
| `/v1/images/edits` | Codex image edits through the SDK JSON image adapter |

Replies carry the request ID and type: `data`, `done`, or `error`.
Data bytes use Base64 inside the JSON frame.
The consumer sends `ack` after each data frame, or `cancel` to stop one call.
Each call permits only one unacknowledged data frame, at most 64 KiB.
The worker admits at most 64 concurrent calls and rejects excess calls without a queue.
Request frames cannot exceed 16 MiB, including the JSON envelope and credential.
The Elixir sender rejects larger frames before sending them. The Go reader enforces the same limit before allocating a frame.
This transport allowance does not define the model's image or context budget.
Each call can emit at most 32 MiB.
The Elixir owner bounds calls with the shared LLM request budget, which defaults to 600 seconds.
The Go worker follows owner cancellation and adds no separate fixed deadline.
Streaming inference uses the shared first-event and idle settings: 120 seconds before the first data frame, then 30 seconds between data frames.
These settings are `llm_stream_first_event_timeout_ms` and `llm_stream_idle_timeout_ms` in `salix_agent`.
Either setting accepts `:infinity`. The owner still enforces the total request budget.
Blocking inference and control operations use the total request budget without a separate 30-second receive limit.
Blocking executors return data only after the complete response arrives.

The Go worker also limits active request frames to 192 MiB in total, using the actual received JSON frame lengths.
This preserves the former maximum encoded input allowance: 64 calls at 3 MiB each.
Small requests can use all 64 call slots. Twelve full 16 MiB requests consume the byte allowance.
There are no size classes or additional queues. A request that exceeds remaining capacity returns `429 worker_busy`.
The account selector does not rotate or cool accounts after a local capacity or frame-size rejection.
Only the worker's pre-execution rejection signal selects this path. Provider failures retain the existing cooldown policy.
The Go worker reserves bytes before execution and releases them only after execution ends. Sending cancellation does not release capacity.
This protects other calls from concurrent large inputs. It does not authenticate requests or promise a process memory ceiling.
The receiver can read and decode one additional frame before rejecting it. Elixir callers also encode requests before admission.
JSON decoding, SDK conversion, and response buffers add memory beyond the active input allowance.
The 32 MiB output check runs after SDK emission. It does not cap SDK allocations or total process memory.
Historical logical-request archives motivate the larger single-call limit, but do not measure final frame sizes or establish a safe RSS budget.

The Elixir owner monitors each caller. Caller exit cancels its upstream operation.
A cancelled caller deactivates its reply alias, so late frames cannot accumulate in its mailbox.
Subprocess exit fails all active calls. The next call starts a new subprocess.
End-of-input cancels Go operations and ends the subprocess.
A stalled protocol write recycles the subprocess and fails its active calls.

Salix removes refresh tokens and ID tokens before inference.
The worker executes only the supplied credential. It does not choose another account or save refresh results.
Native provider encoders, response parsers, and SSE parsers remain in Salix.
A request-scoped transport function supplies the pipe result to these parsers without an HTTP connection.
Only host code can supply that function. Serialized template input cannot select an executable or transport function.

## Routing and billing

The private-template resolver injects its owning tenant and a `subscription://worker` route.
It drops user endpoints, headers, and credential references.
Normal templates cannot retain the reserved tenant routing field.
The route has no network destination. It dispatches only through the tenant-indexed account selector.
The existing billing path exempts this subscription route. A changed network endpoint receives no exemption.
Removing the service token does not create an unauthenticated network listener.
The local process and the Salix template owner replace that network boundary.

Triage resolves the identity-bound agent template and uses the same `AccountPool.dispatch` entry point.
A valid subscription route does not require an API key in the template.
Triage records the encoded provider request before dispatch and prevents another account attempt after that point.
Provider options cannot replace the template's tenant route or inject a transport function.

## Salix ownership

`SalixAgent.AccountPool` is the Dashboard and Agent API.
`SubscriptionStore` stores tenant-scoped rows in PostgreSQL.
Credential JSON and private OAuth context use AES-GCM encryption.
The operator key is the decryption authority. Tenant and record IDs are authenticated context.
This preserves the previous vault's file-disclosure and ciphertext-relocation protections.
It does not protect credentials from an operator who controls both the process and key.
Queries that carry credentials disable parameter logging.

Account edits and deletes compare the current row version.
Before external credential preparation, Salix claims the row through a versioned update.
Concurrent callers cannot refresh the same record. Different records remain independent, including duplicate upstream accounts.
Salix saves the result before an inference call can use it.
A crash, lost refresh response, or failed save leaves the record unavailable and requires reauthorization.
A confirmed pre-execution capacity or frame-size rejection restores the original record through the refresh claim's version check.
No refresh executor ran in that case. A concurrent edit or deletion prevents restoration.
A late result cannot overwrite a replacement or restore a deleted record.
A prepared account with an unexpired token does not repeat preparation for each request.
Native Codex imports use the access-token `exp` claim as an expiry hint. The provider remains the authentication authority.
An unknown expiry with a refresh token triggers preparation before use. Salix stores the replacement credential and expiry.

Salix selects at most three candidates from its tenant-indexed account query.
The policy lives in `SubscriptionStore.candidates/3`, as SQL authored in Elixir.
Applicable exhausted short windows exclude an account. Weekly quota determines ranking, with monthly quota as the fallback.
An account resetting within one day ranks first, ordered by reset time and then remaining percentage.
Other known accounts rank by remaining percentage divided by remaining days.
Quota older than 15 minutes is unknown. Unknown accounts remain eligible after known accounts.
A failed request cools the account for 30 seconds. Salix can try another candidate before stream output starts.
Selection returns at most three accounts. Ready accounts precede cooling accounts, which sort by their cooldown end time.
The dispatcher does not execute cooling accounts. If no account is ready, the error includes the earliest selected cooldown delay.
Round retries honor that delay, capped at 30 seconds per retry. The five-retry limit and dependency deadline still apply.
An empty, disabled, or quota-exhausted pool does not report a cooldown delay.
A partial stream is never replayed on another account.
The first nonempty transport chunk stops account fallback, including reasoning and tool-only output. Text latency measurement remains separate.
Recognized context-overflow errors cross the pipe as `context_length_exceeded`. Other errors retain a generic code without raw provider text.

The Salix quota worker claims four due rows per tick through PostgreSQL `SKIP LOCKED`.
It queries those rows concurrently. Each node runs one worker and does no per-tenant polling fan-out.
Successful accounts become due after five minutes. Failures back off from 15 minutes to two hours.
Failed queries retain the last snapshot. Quota comes from explicit provider usage queries.
OAuth attempts expire after 15 minutes and survive adapter restarts.
Salix validates state and atomically consumes the attempt before exchanging the code.
The Dashboard exposes only the authorization URL, attempt ID, and expiry.

Private templates retain the provider choice. Runtime resolution supplies the trusted adapter route.
Salix's existing LLM dispatch retains usage metering and request/response archive boundaries.
Subscription traffic does not charge Comma model credits. Other product charges remain unchanged.

## Diagnostic logs

Subscription operations use the existing Elixir Logger and `CommaLog.Formatter` JSON output.
The Go worker writes JSON logs to standard error. Standard output remains the framed protocol.

Account logs cover selection, execution attempts, refresh, cooldown, quota queries, account mutations, and OAuth operations.
Selection records candidate, ready, and cooling counts. Completion records duration, outcome, normalized error code, and available HTTP status or retry delay.
Storage failures record a fixed error code without SQL or parameters.

Agent dispatch logs carry `tenant_id`, `agent_id`, `session_id`, and the selected `account_id` when available.
Worker calls add `worker_request_id`, `operation`, and `stream`.
Use the cloud resource, process lifetime, and request ID together. Request IDs are local to one BEAM instance.
Go events share the request ID with host events. IDs remain log fields and do not become metric labels or trace attributes.

The following events separate upstream HTTP progress from host delivery:

| Event | Meaning |
| --- | --- |
| `subscription_worker_call_start` | Host starts a worker request |
| `subscription_sdk_call_start` | Go starts the operation |
| `subscription_upstream_request_written` | First successful HTTP request write |
| `subscription_upstream_first_byte` | First observed HTTP response byte, which can belong to headers |
| `subscription_sdk_call_finish` | Go operation completes or fails |
| `subscription_worker_call_finish` | Host consumer completes or fails |

Host completion records `host_frames`, `host_bytes`, and `host_first_frame_ms` when a frame arrives.
These fields count protocol data frames, not upstream bytes or model tokens.
A blocking response can have an upstream first-byte event while the host still has zero frames.
Neither the HTTP first-byte event nor a missing completion event proves continued upstream progress.
Caller cancellation, owner deadline, subprocess start, and subprocess stop have separate events.

Each worker call emits at most two host call events. Go events include operation, HTTP, body, and failure observations.
Body progress emits at most once per 15 seconds of reads. First-event and terminal observations emit once per response.
Account attempts remain bounded by the existing three-candidate selection. Quota polling retains its existing four-row tick.
Logs do not include credentials, OAuth codes, authorization URLs, prompts, completions, raw provider errors, or SQL parameters.
Logging failures do not replace operation results. Process death can prevent a completion event.

For a known request, filter Cloud Logging by the Salix workload and `jsonPayload.worker_request_id`.
Use `jsonPayload.session_id` to find the host dispatch, then use its request IDs to inspect Go events.

## Local cutover

Stop the old Go writer before copying its encrypted credential directory.
Use `SalixAgent.SubscriptionImport.run/3` with that copy, the tenant ID, and the old raw key.
The importer preserves account IDs, providers, credentials, and disabled state.
It does not delete source files. An identical import is repeatable. A divergent destination fails closed.
Back up both the encrypted source and its key separately before cutover.
After the new service accepts mutations, recover forward from Salix's stored records.
Do not restart the old writer as a rollback after new mutations.
Quota snapshots are rebuilt. Old pending OAuth attempts must restart.

## Validation

Go tests exercise native executors against synthetic providers, including streaming, tool calls, system instructions, and compaction.
Protocol tests cover frame reassembly, slow consumers, cancellation, admission limits, and parent exit.
Elixir integration tests run the actual Go worker against synthetic providers.
They cover both provider parsers, caller cancellation, partial-stream failure, and subprocess restart.
Salix tests cover tenant access, credential encryption, versions, refresh concurrency, late refresh after deletion, quota ranking, and Dashboard flows.
The existing financial and archive seams remain in `SalixAgent.LLM`; this change does not alter agent ownership or delivery protocols.
No new TLA+ model is introduced for account lifecycle behavior.
Real-provider refresh and plan-specific quota behavior need representative subscription validation before deployment.

## Release integration

The existing BEAM jobs install Go before compilation. The existing connector test job also runs this worker's race tests.
These tests cover the subprocess boundary: cancellation, worker failure, framing, and provider response conversion.
They help reviewers reject a worker that can lose or corrupt a model response. No additional deployment check is required.
The retained TLA+ protocols are unchanged. Subscription storage and subprocess behavior use implementation tests.

The release manifest includes `salix-20260910000001` as an additive schema step.
It creates `subscription_accounts` and `subscription_oauth_attempts` before the new runtime starts.
Existing product data remains unchanged. Account credentials and pending OAuth material are durable encrypted data.
Keep these tables and the storage key during recovery. Do not run a down migration after accounts exist.
A runtime rollback can leave the new tables in place. Repair failed schema creation through the existing transaction retry.
The schema step uses the existing 300-second timeout and five-second lock budget.
No account import is required for an environment that has never used the local prototype.

The release workflow reads the environment's GitHub `SALIX_CONFIG_JSON` secret.
The release bundler preserves `subscription_proxy.storage_key` inside the mounted Salix config Secret.
A JSON file on an operator's computer does not update that GitHub secret.

1. Preserve the configured storage key for subsequent releases.
2. Update the staging environment's `SALIX_CONFIG_JSON` through the existing secret-management procedure.
3. Merge the reviewed changes into `main` after CI passes.
4. Deploy the image and chart published from that mainline commit.
5. Confirm the subscription schema step completes before use.
6. Connect a Codex subscription and a Claude subscription through the dashboard.
7. Verify import, authorization, quota refresh, and an Agent response for each provider.
8. Verify that the subscriptions remain usable after a Salix restart.

Real-provider verification requires user-authorized test accounts. Synthetic provider tests do not prove live OAuth or quota compatibility.
The worker uses an upstream commit plus a committed patch. A separate GitHub fork is not required for a clean build.

## Subscription model discovery

The `/models` worker operation accepts a prepared Codex or Claude credential from the tenant account owner.
The pinned SDK has no exported subscription-discovery function. This adapter uses its authenticated `HttpRequest` executor and converts the provider catalog.
The operation returns model IDs and names, never credentials or provider error bodies.
It permits only the fixed provider model endpoints and rejects redirects before a credential reaches another location.
This prevents a redirect response from forwarding the subscription token to another endpoint.
The adapter owns that check and returns `models_unavailable` on a redirect.
The query has a 15-second deadline, a total two-megabyte response limit, at most five pages, and at most 1,000 models.
The redirect guard uses standard Go TLS through the SDK transport hook instead of the SDK's private TLS fingerprints.
Credential refresh remains with the existing Elixir account owner. Discovery does not perform inference or select a fallback account.

Discovery preserves provider-declared image input support.
Codex declares it through `input_modalities`; Claude declares it through `capabilities.image_input.supported`.
Missing declarations remain false. Model names do not determine capabilities.
Selecting a discovered model supplies this capability to the template editor. Existing saved templates retain their configuration.

## Diagnose compaction latency

Use `agent_id` and `session_id` to locate `compaction_job_pending`, `compaction_execute_start`, and `compaction_execute_finish`.
The actor records `compaction_job_result`, `compaction_job_timeout`, or `compaction_job_down` when the dependency settles.
`timeout_ms` records the actor budget. `compaction_commit_start` and `compaction_commit_finish` measure result persistence.
Execution and commit spans do not guarantee a finish event after process termination.
These logs do not change dependency deadlines, retries, storage, or the retained TLA+ transitions.

Within execution, account selection and attempt logs identify each candidate.
`subscription_retry_next` records the remaining candidate count, including zero when the pool is exhausted.
`subscription_retry_stopped` means host data or caller-visible progress prevents another account attempt.
Join host and Go logs by `worker_request_id` within the same Pod lifetime.

The HTTP transport adds these events for each response:

| Event suffix after `subscription_upstream_` | Meaning |
| --- | --- |
| `headers` | HTTP response headers and status received |
| `first_body` | First response body bytes read |
| `first_event` | First bounded SSE data line observed |
| `terminal` | First recognized completion, failure, or stream-end event |
| `progress` | Body bytes read after at least 15 seconds since the previous progress report |
| `body_end` | EOF, read failure, cancellation, deadline, or early close |

The `headers` event records `response_content_type` from a fixed allowlist, never the raw header.
The body observer counts SSE events only when the content type starts with `text/event-stream`.
Zero observed events with another content type do not establish that the body contained no SSE events.

`subscription_sdk_failure` records the normalized `failure_class` and SDK HTTP status before host output starts.
Known classes distinguish missing terminal events, empty incomplete responses, and selected structured provider errors.
Unknown errors use `unclassified`. Logs exclude the SDK error message and response body.
This event does not change account selection, retries, or the public error code.
A provider HTTP 200 followed by an SDK 502 does not establish an upstream HTTP 502.

The Go start event also records the requested model, reasoning effort, output limit, and request body size.
An unspecified effort does not establish the provider default. These fields describe the request before SDK conversion.
`elapsed_ms` starts at the Go operation boundary.
Body events include `upstream_body_bytes`, `sse_events`, `last_event_type`, `terminal_seen`, and `oversized_lines`.
Each HTTP response has separate counters. Progress reports require reads and are not heartbeat events.
No progress log during a blocked read proves neither failure nor continued generation.
A terminal event before EOF exposes SDK time spent awaiting body termination.
An error terminal does not mean successful generation.

The observer uses a diagnostic line reader because SDK callbacks occur after buffering on the non-streaming path.
It inspects at most the first 64 KiB of each line and skips the remainder.
GJSON reads a top-level event type from this prefix, including prefixes of large completion events.
Types outside the prefix are invisible. A missing terminal event is therefore not proof that the provider never sent one.
Event types use an allowlist. Logs exclude response content, request bodies, headers, URLs, and credentials.
The observer preserves response bytes and the selected proxy and TLS transports.
EOF timing and provider event timing remain separate from host frame timing.
EOF tests use a server that sends completion before it closes the response.

### Response diagnostics

Subscription logs correlate through `worker_request_id`. Command fields describe
what Salix sent to the SDK. They do not prove effective provider defaults.
`prompt_cache_key_present` reports presence only. It does not expose the key or
prove that the SDK used the same key upstream. Salix sends one key per session
(`SalixAgent.LLM.prompt_cache_key/1`, a UUID v5 of the session id) on every
agent-round Responses request; the SDK forwards it as `prompt_cache_key` and
`Session_id`. Without it the SDK mints a random `Session_id` per request and the
upstream prompt cache misses between rounds.

The HTTP body observer records the first nonempty reasoning, text, and tool
argument delta separately. These times also cover blocking SDK calls that read
upstream SSE. They are observed read times, not server generation timestamps.
A reasoning summary delta is not the full private reasoning trace.

`subscription_upstream_response_metadata` records reported token counters and
only the count and byte length of encrypted reasoning items. It never logs the
ciphertext. These sizes cannot measure reasoning quality. The observer retains
at most one 64 KiB line. An oversized terminal event has
`response_metadata_complete=false`; absent counters then remain unknown.

Responses usage includes `usage_reported`, `prompt_tokens_reported`,
`completion_tokens_reported`, `cache_read_tokens_reported`, and nullable
`reasoning_tokens`. ClickHouse stores these fields on both LLM table generations.
A NULL flag means the observation is unavailable, including historical rows and
other protocol parsers. False means the Responses parser did not receive the
numeric counter. A reported zero cache count means an explicit zero, not missing data.
Existing billing counters retain their previous normalization. The requested
model remains the billing SKU; the response model identifies the returned model.

The additive migration preserves all existing rows and keys. It updates both
table generations before new writers start. No data rebuild or backfill is
required. Retry the migration and release to repair an interrupted cutover.
The retained TLA+ transitions do not change because these fields are observational.
