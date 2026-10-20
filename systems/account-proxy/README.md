# Salix subscription SDK adapter

Salix owns subscription accounts, tenant access, encrypted credentials, OAuth attempts, quota snapshots, and account selection.
This Go worker executes a supplied credential through the native CLIProxyAPI executors.
It has no account database, tenant registry, Manager, model-registration lifecycle, or background quota worker.

## Build and run

`mix compile` builds `priv/subscription_worker` through the account-proxy Makefile.
The local build requires Go and Git.
The systems image uses a Go build stage and copies the binary into the Salix release.
The build uses the CLIProxyAPI commit pinned in `bootstrap.sh` and `patches/embedded-sdk.patch`. A separate GitHub fork is not required.
Without an explicit proxy or an injected transport, the Codex and Claude fingerprint transports follow `HTTPS_PROXY` (or `ALL_PROXY`) and `NO_PROXY` per request.

`bootstrap.sh` preserves an existing `.upstream` checkout. After a patch change, remove `.upstream` and run it again.

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

## Subscription providers

Salix provider IDs name subscription products. The worker maps each ID to one native CLIProxyAPI executor.

| Provider         | Executor               | Sign-in                 | Inference protocol | Quota source                      |
| ---------------- | ---------------------- | ----------------------- | ------------------ | --------------------------------- |
| `codex`          | Codex                  | Callback or device code | Responses          | `wham/usage`                      |
| `claude`         | Claude                 | Callback                | Anthropic Messages | `api/oauth/usage`                 |
| `gemini`         | Antigravity            | Callback                | Chat Completions   | `fetchAvailableModels`, per model |
| `grok`           | xAI (Grok Build proxy) | Device code             | Responses          | `billing?format=credits`          |
| `kimi-code`      | Kimi                   | Device code             | Anthropic Messages | `coding/v1/usages`                |
| `github-copilot` | OpenAI-compatible      | Device code             | Chat Completions   | `copilot_internal/user`           |

`SalixAgent.AccountPool.route/1` maps a provider to its protocol and reserved base URL, for example `subscription://grok/v1`.
`dispatch/4` maps the route back to the provider and selects only that provider's accounts.
The worker rejects a credential whose provider does not serve the requested protocol.

`copilot.go` implements the GitHub Copilot device login and token exchange.
The GitHub OAuth token is the stored refresh token. Preparation exchanges it for a short-lived Copilot token.
Requests use the Copilot API host named in that token. The worker accepts only `*.githubcopilot.com` hosts.
GitHub Enterprise domains and Copilot model-policy enablement are not supported.
Copilot accounts use only the numeric GitHub account id (`id:github:<id>`) for reconnect matching.
Sign-in and imports read the id from GitHub `/user`. They fail when the profile has no id.

Imported credentials keep identity and token fields only. The worker drops endpoint fields such as `base_url` and `token_endpoint`.
Thus a tenant-supplied URL cannot choose where the worker sends a bearer token.
Kimi keeps its device ID, which its token endpoint requires for refresh. Gemini keeps its Cloud Code project ID.

The worker returns each provider's quota answer as the provider gave it. Salix reads it with the Profiles
logic (`systems/profiles` `quota.rs`). A missing or malformed provider value remains unknown.
Gemini windows apply only to requests for the reporting model. Copilot premium requests use the `premium` scope and do not exclude an account.
The Kimi, Grok, Gemini, and Copilot quota readers have only synthetic tests. Validate them with real accounts before you rely on them.
Model discovery supports only Codex and Claude.
Grok has no native compaction. Salix uses its own summary compaction for Grok.

## Reconnect an account

Imports and OAuth additions match accounts by tenant, provider, and email.
Email matching ignores case and surrounding spaces. Missing emails do not match.
The email comes from normalized credential metadata. It does not prove authorization.
A match keeps the record ID and disabled setting, replaces credentials, and changes the record version.
It clears prepared state, quota, expiry, and cooldown, then schedules a fresh quota poll.
A late refresh with the previous version cannot overwrite the new credentials.
Concurrent additions serialize in a database transaction. Existing duplicate rows remain.

## Codex reset credits

The worker reads `rate_limit_reset_credits.available_count` from `GET /wham/usage`.
The public snapshot stores it as `quota.reset_credits.available_count`.
A missing or invalid count means unknown, not zero. Only Codex supports reset credits.

The reset operation posts to `/wham/rate-limit-reset-credits/consume` on the ChatGPT backend origin.
It sends the selected account credentials and one `redeem_request_id`.
The backend chooses an available credit. Salix does not list, select, or purchase credits.
See the [upstream request implementation](https://github.com/openai/codex/blob/654b0a77d0d2f81aa21f61caf7af4be88fe550bb/codex-rs/backend-client/src/client/rate_limit_resets.rs).

`AccountPool.reset_quota/3` accepts `version` and `request_id`.
A new request requires the current account version. The owner saves a pending `reset_attempt` before the provider call.
Another request cannot replace a pending attempt. Retries reuse its key, including after a browser reconnect or process restart.
The provider owns redemption deduplication. Salix keeps only the last attempt in the account JSON.
The stored key identifies an operation. It is not a credential or authorization boundary.
Credential replacement clears the attempt. A stale result cannot overwrite replaced credentials because the write checks the record version.

The provider returns `reset`, `already_redeemed`, `no_credit`, or `nothing_to_reset`.
Transport errors and unknown responses leave the attempt pending. Retry that attempt, not a new request.
After a confirmed result, the owner reads quota again. It never sets local allowance to 100 percent.
A failed follow-up read returns the confirmed outcome with `quota_refreshed: false` and the previous snapshot.
Provider cooldown policy does not change.

The shared Salix and BFT dashboard shows the count and asks for confirmation before a reset.
BFT applies the organization owner/admin check. The workspace API applies its full-session owner check.
Logs use `subscription_account_reset` and the worker operation events. They exclude credentials and redemption keys.
A real reset consumes account rights and requires separate operator approval.

## Subprocess protocol

`SalixAgent.SubscriptionWorker` owns one local Go subprocess per Salix node.
It starts the subprocess on the first call.
Each frame contains a four-byte big-endian length followed by JSON.
Standard output carries protocol frames only. Logs use standard error.

A `call` contains a unique request ID, operation, JSON body, and optional selected credential.
Operations use path names, but they are local dispatch names, not HTTP endpoints.

| Operation                | Result                                                                             |
| ------------------------ | ---------------------------------------------------------------------------------- |
| `/normalize`             | Normalized imported credentials and email                                          |
| `/prepare`               | Refreshed credentials and native account metadata                                  |
| `/quota`                 | The provider's quota answer (`body`), as it gave it                                |
| `/quota/reset`           | Result of one Codex reset-credit request                                           |
| `/oauth/begin`           | Authorization URL and private PKCE context                                         |
| `/oauth/exchange`        | Provider credentials                                                               |
| `/oauth/device/begin`    | Private device code and context, user code, verification URL, and polling interval |
| `/oauth/device/poll`     | One provider check: pending status, optional `slow_down`, or normal credentials    |
| `/v1/responses`          | Native Codex or Grok JSON or SSE bytes                                             |
| `/v1/responses/compact`  | Native Codex compaction result                                                     |
| `/v1/messages`           | Native Claude or Kimi JSON or SSE bytes                                            |
| `/v1/chat/completions`   | Chat Completions JSON or SSE bytes from Gemini or Copilot                          |
| `/v1/images/generations` | Codex image generation through the SDK image adapter                               |
| `/v1/images/edits`       | Codex image edits through the SDK JSON image adapter                               |

Replies carry the request ID and type: `data`, `done`, or `error`.
Data bytes use Base64 inside the JSON frame.
The consumer sends `ack` after each data frame, or `cancel` to stop one call.
Each call permits only one unacknowledged data frame.
`worker.go` and `subscription_worker.ex` define the frame, call, output, and active-byte limits.
These transport limits do not define the model's image or context budget.
The worker rejects excess calls without a queue and returns `429 worker_busy`.
The account selector does not rotate or cool accounts after a local capacity or frame-size rejection.
Provider failures keep the normal cooldown policy.
The limits protect other calls from concurrent large inputs. They do not authenticate requests or promise a process memory ceiling.

The Elixir owner bounds calls with the shared LLM request budget. The Go worker follows owner cancellation and adds no separate deadline.
Streaming inference also uses `llm_stream_first_event_timeout_ms` and `llm_stream_idle_timeout_ms` in `salix_agent`.
Either setting accepts `:infinity`. The owner still enforces the total request budget.
Blocking executors return data only after the complete response arrives.

The Elixir owner monitors each caller. Caller exit cancels its upstream operation.
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
Normal templates cannot keep the reserved tenant routing field.
The route has no network destination. It dispatches only through the tenant-indexed account selector.
The billing path exempts this subscription route. A changed network endpoint receives no exemption.
There is no unauthenticated network listener.
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
This protects against file disclosure and ciphertext relocation.
It does not protect credentials from an operator who controls both the process and key.
Queries that carry credentials disable parameter logging.

Account edits and deletes compare the current row version.
Before external credential preparation, Salix claims the row through a versioned update.
Concurrent callers cannot refresh the same record. Different records remain independent, including duplicate upstream accounts.
Salix saves the result before an inference call can use it.
A crash, lost refresh response, or failed save leaves the record unavailable and requires reauthorization.
A confirmed pre-execution capacity or frame-size rejection restores the original record through the refresh claim's version check.
A concurrent edit or deletion prevents restoration.
A late result cannot overwrite a replacement or restore a deleted record.
A prepared account with an unexpired token does not repeat preparation for each request.
Native Codex imports use the access-token `exp` claim as an expiry hint. The provider remains the authentication authority.
An unknown expiry with a refresh token triggers preparation before use.

`SubscriptionStore.candidates/3` reads a provider's enabled accounts and returns at most three.
The Profiles pool (`systems/profiles` `pool.rs`) orders them. A used-up window that has not refilled excludes an account.
A failed request cools the account, except a 400, 403, or 404 response, which rejects the model or request, not the account.
Salix can try another candidate before stream output starts.
After a 403 or 404, Salix fetches untried accounts, within a fixed attempt budget per request.
The dispatcher does not execute cooling accounts. If no account is ready, the error includes the earliest cooldown delay.
Round retries honor that delay, within the round retry limit and dependency deadline.
An empty, disabled, or quota-exhausted pool does not report a cooldown delay.
A partial stream is never replayed on another account.
The first nonempty transport chunk stops account fallback, including reasoning and tool-only output.
Recognized context-overflow errors cross the pipe as `context_length_exceeded`. Other errors keep a generic code without raw provider text.

The Salix quota worker claims due rows through PostgreSQL `SKIP LOCKED`.
Each node runs one worker and does no per-tenant polling fan-out.
Failures back off. Failed queries keep the last snapshot. Quota comes from explicit provider usage queries.
OAuth attempts expire and survive adapter restarts.
Salix validates state and atomically consumes the attempt before exchanging the code.
The Dashboard exposes only the authorization URL, attempt ID, and expiry.

Private templates keep the provider choice. Runtime resolution supplies the trusted adapter route.
Salix LLM dispatch keeps usage metering and request/response archive boundaries.
Subscription traffic does not charge Comma model credits. Other product charges do not change.

## Diagnostic logs

Subscription operations use the Elixir Logger and `CommaLog.Formatter` JSON output.
The Go worker writes JSON logs to standard error.

Account logs cover selection, execution attempts, refresh, cooldown, quota queries, account mutations, and OAuth operations.
Selection records candidate, ready, and cooling counts. Completion records duration, outcome, normalized error code, and available HTTP status or retry delay.
Storage failures record a fixed error code without SQL or parameters.

Agent dispatch logs carry `tenant_id`, `agent_id`, `session_id`, and the selected `account_id` when available.
Worker calls add `worker_request_id`, `operation`, and `stream`.
Request IDs are local to one BEAM instance. Use them with the cloud resource and process lifetime.
Go events share the request ID with host events. IDs are log fields only, not metric labels or trace attributes.

These events separate upstream HTTP progress from host delivery:

| Event                                   | Meaning                                                        |
| --------------------------------------- | -------------------------------------------------------------- |
| `subscription_worker_call_start`        | Host starts a worker request                                   |
| `subscription_sdk_call_start`           | Go starts the operation                                        |
| `subscription_upstream_request_written` | First successful HTTP request write                            |
| `subscription_upstream_first_byte`      | First observed HTTP response byte, which can belong to headers |
| `subscription_sdk_call_finish`          | Go operation completes or fails                                |
| `subscription_worker_call_finish`       | Host consumer completes or fails                               |

Host completion records `host_frames`, `host_bytes`, and `host_first_frame_ms` when a frame arrives.
These fields count protocol data frames, not upstream bytes or model tokens.
A blocking response can have an upstream first-byte event while the host still has zero frames.
Neither the HTTP first-byte event nor a missing completion event proves continued upstream progress.
Caller cancellation, owner deadline, subprocess start, and subprocess stop have separate events.

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
An environment that never used the local prototype needs no import.

## Release integration

The BEAM CI jobs install Go before compilation and run this worker's race tests.

The release manifest step `salix-20260910000001` creates `subscription_accounts` and `subscription_oauth_attempts`.
Account credentials and pending OAuth material are durable encrypted data.
Keep these tables and the storage key during recovery. Do not run a down migration after accounts exist.
A runtime rollback can leave the new tables in place. Repair failed schema creation through the release transaction retry.

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

Real-provider verification requires user-authorized test accounts. Synthetic provider tests do not prove live OAuth, refresh, or quota compatibility.

## Subscription model discovery

The `/models` worker operation accepts a prepared Codex or Claude credential from the tenant account owner.
It returns model IDs and names, never credentials or provider error bodies.
It permits only the fixed provider model endpoints. It rejects redirects with `models_unavailable` before a credential reaches another location.
`models.go` defines the deadline, response size, page, and model count limits.
The redirect guard uses standard Go TLS, not the SDK's private TLS fingerprints.
Credential refresh stays with the Elixir account owner. Discovery does not perform inference or select a fallback account.

Discovery keeps provider-declared image input support.
Codex declares it through `input_modalities`. Claude declares it through `capabilities.image_input.supported`.
Missing declarations remain false. Model names do not determine capabilities.
A discovered model supplies this capability to the template editor. Saved templates keep their configuration.

## Diagnose compaction latency

Use `agent_id` and `session_id` to locate `compaction_job_pending`, `compaction_execute_start`, and `compaction_execute_finish`.
The actor records `compaction_job_result`, `compaction_job_timeout`, or `compaction_job_down` when the dependency settles.
`timeout_ms` records the actor budget. `compaction_commit_start` and `compaction_commit_finish` measure result persistence.
Execution and commit spans do not guarantee a finish event after process termination.

Within execution, account selection and attempt logs identify each candidate.
`subscription_retry_next` records the remaining candidate count, including zero when the pool is exhausted.
`subscription_retry_stopped` means host data or caller-visible progress prevents another account attempt.
Join host and Go logs by `worker_request_id` within the same Pod lifetime.

The HTTP transport adds these events for each response:

| Event suffix after `subscription_upstream_` | Meaning                                                   |
| ------------------------------------------- | --------------------------------------------------------- |
| `headers`                                   | HTTP response headers and status received                 |
| `first_body`                                | First response body bytes read                            |
| `first_event`                               | First bounded SSE data line observed                      |
| `terminal`                                  | First recognized completion, failure, or stream-end event |
| `progress`                                  | Body bytes read since the previous progress report        |
| `body_end`                                  | EOF, read failure, cancellation, deadline, or early close |

The `headers` event records `response_content_type` from a fixed allowlist, never the raw header.
The body observer counts SSE events only when the content type starts with `text/event-stream`.

`subscription_sdk_failure` records the normalized `failure_class` and SDK HTTP status before host output starts.
Unknown errors use `unclassified`. Logs exclude the SDK error message and response body.
This event does not change account selection, retries, or the public error code.
A provider HTTP 200 followed by an SDK 502 does not prove an upstream HTTP 502.

The Go start event also records the requested model, reasoning effort, output limit, and request body size.
These fields describe the request before SDK conversion. An unspecified effort does not show the provider default.
Body events include `upstream_body_bytes`, `sse_events`, `last_event_type`, `terminal_seen`, and `oversized_lines`.
Progress reports require reads and are not heartbeat events.
No progress log during a blocked read proves neither failure nor continued generation.
A terminal event before EOF exposes SDK time spent awaiting body termination.
An error terminal does not mean successful generation.

The observer reads only a bounded prefix of each line. Event types outside the prefix are invisible.
Thus a missing terminal event does not prove that the provider never sent one.
Logs exclude response content, request bodies, headers, URLs, and credentials.
The observer preserves response bytes and the selected proxy and TLS transports.

### Response diagnostics

Command fields describe what Salix sent to the SDK. They do not prove effective provider defaults.
`prompt_cache_key_present` reports presence only. It does not expose the key or
prove that the SDK used the same key upstream. Salix sends one key per session
(`SalixAgent.LLM.prompt_cache_key/1`) on every agent-round Responses request.
The SDK forwards it as `prompt_cache_key` and `Session_id`.

The HTTP body observer records the first nonempty reasoning, text, and tool
argument delta separately. These are observed read times, not server generation timestamps.
A reasoning summary delta is not the full private reasoning trace.

`subscription_upstream_response_metadata` records reported token counters and
only the count and byte length of encrypted reasoning items. It never logs the
ciphertext. An oversized terminal event has `response_metadata_complete=false`.
Absent counters then remain unknown.

Responses usage includes `usage_reported`, `prompt_tokens_reported`,
`completion_tokens_reported`, `cache_read_tokens_reported`, and nullable
`reasoning_tokens`. ClickHouse stores these fields on both LLM table generations.
A NULL flag means the observation is unavailable, including historical rows and
other protocol parsers. False means the Responses parser did not receive the
numeric counter. A reported zero cache count means an explicit zero, not missing data.
The requested model remains the billing SKU. The response model identifies the returned model.
