# Billing and models

## Financial authority

PostgreSQL owns grants, sources, payments and redemptions. Active `credit_grants` own the balance.
ClickHouse cannot gate resources, compensation or issuance.
`BillingCore.FeeControl.authorize/1` owns current-fact admission, cache and pending replies, within request timeout.
Failed queries preserve cache entries; stale refreshes cannot replace newer results. See the [paid-work contract](architecture/DOMAIN_CONCEPTS.md#paid-work-admission).

Plan/package keys and provider lookup keys are stable. Stripe IDs are mappings.
Migrations seed catalogs. Release tasks synchronize providers with dry-run, retry, and drift failure.
Redelivery locks every event except `processed`. Domain writes and that marker commit together.
Failed provider GETs roll back. Correct the cause and request redelivery. No sweep or delivery-progress guarantee exists.
Reconciliation reads Stripe under Account/Subscription locks.

Comma uses stable `comma_*` keys and provider sale metadata. Historical mappings resolve events.
Monthly/yearly Prices share one Product per package. One nondefault Comma portal manages payment methods, invoices, and cancellation only.
Changes stay within the paid cadence. One lower target applies at next monthly or annual renewal.
Selecting the current tier clears that target. A higher tier requires confirmation of Stripe's invoice preview.
Confirmation clears the downgrade before payment. Failed payment keeps the current tier without restoring the downgrade.
`pending_if_incomplete` applies paid upgrades. Existing cancellation remains independent.
Subscription retains one change operation with request, key, and invoice mapping.
Unknown results block different changes. Expired retries require exact evidence or actionable errors.
Schedules contain the current phase and one target. Comma handles cancellation where the portal cannot cancel scheduled subscriptions.

Confirmed Stripe cash grants credits. Offline paid markers do not qualify.
Invoices select the positive subscription line, not line order or the latest display plan.
Cycles retain invoice/PaymentIntent allocations. Each allocation issues one idempotent Grant.
Upgrades grant the positive tier difference times remaining cycle seconds, rounded down.
Missing predecessor payments retry without granting a full base allocation.
Partial refunds record money and preserve credits. Full refunds/lost disputes revoke only that payment's unspent/future rights.
Spent amounts remain recorded. Refunds preserve issued Cycles. Cancellation preserves paid-period credits.
Open disputes suspend rights. Wins restore valid remaining rights without undoing refunds.
Recharge expires at the end of Stripe's confirmed payment month in UTC.

Comma JSON columns contain objects. Conversion preserves encoded strings and retains original array entries in `_legacy_updates`.
It cannot infer invoice allocation. Snapshot affected durable rows before release.
Migration and post-rollout repair affect only Comma rows. Requests/migrations never synchronize providers.

## Tenant-private templates

Tenant-private model/provider templates serve its Groups.
Global keys: `ctl/templates/{template_id}.json`. Private keys: `ctl/tenant_templates/{tenant_id}/{template_id}.json`.
Private IDs use `ptm1_` plus a 19-digit Snowflake. Tenant and ID are immutable. Names cannot shadow or inherit across scopes.

Creation derives ownership from authentication, ignoring supplied identity. Runtime uses the canonical Agent tenant.
A missing or foreign private ID fails closed without global, name, or platform-default fallback.
Deployment-wide meeting, ASR, and system references remain global-only.

To prevent platform credential disclosure, reject server `api_key_env`/`auth_token_env` references in private main, media, vision, and analyze configuration.
Validate nested configuration on write and runtime resolution. Private media cannot inherit platform credentials or endpoints.
Image/video providers require explicit support and absolute HTTP(S) endpoints.

Tenant-key management exposes full private configuration, without granting product member roles. Catalogs whitelist credential-free fields plus `scope`. Comma management returns a separate secret-free view.

Catalogs read at most `limit + 1` keys and `limit` records per scope, at concurrency eight.
Combined limit: 100. Overflow/read failures return errors.
Private deletion scans at most 100 tenant Agent keys, including archived Agents. Their references do not block deletion.
Larger/unreadable inventories reject deletion. Concurrent assignments and initial-Agent references are unprotected.
Deletion preserves Agents, Sessions, and Conversations.

## Comma BYOK

Owners select Router/Workers independently, at most 50 per page, without polling or scan-ahead.
Tenant defaults apply at creation. Provisioning preserves Agent choices.
Comma has no Router default. Template sources are `pinned` or `platform_default`. Provider errors never select Comma-funded models.
Compute uses an explicit model or Agent template. In-flight models stay fixed.
Workers with runtime model settings show that model or runtime default. They reject templates.

Comma exposes name, provider, protocol, model, Key, endpoint, token limits, and image support.
Protocols: Responses, Chat Completions, Anthropic Messages. Edits preserve unexposed auxiliary configuration.
`supports_images` enables native images and defaults to false. Each round captures model, protocol, and capability.
Switches affect later rounds, including retained-image reads. `fs.read_file` with `vision_query` uses configured auxiliary vision.
Otherwise, it returns image content only with declared native image support.
Omitted keys preserve the protected record version's Key. Empty keys are invalid.
Public responses expose `has_api_key`, never Keys/headers. Forms clear Keys on exit/save and never use browser storage.

Base URLs: absolute HTTP(S), no user info/query/fragment.
Discovery rejects redirects. Endpoint changes require a fresh Key.
Bounds: five pages, 1,000 choices, 2 MB/response, 15 seconds overall, 5 seconds/read.
Discovery: no retries or per-model calls. Partial catalogs set `truncated`. Manual entry remains.
Desktop Add profile links TokenDance in one step. Discovery and saved reads normalize TokenDance names/vendors only.
Clients render metadata. IDs and aliases remain unchanged.
`supported_protocols`: `responses`, `chat_completions`, `anthropic`. Missing means unknown. Empty means no recognized protocol.
Main saves one Custom `chat_completions` profile serving each listed model that declares it or no protocol.
Main owns PKCE, callback state, and Keys. The renderer receives only the status and the model metadata.
Authorization: ten minutes. Polling: 1/second.
Exit, cancellation, expiry, Session loss, and shutdown clear local state, preserving Keys.
TokenDance bills users. Build identity sets `app://{urlScheme}` and the Key name.
[Code](../clients/apps/electron/src/main/tokendance-authorization.ts).

Dispatch and metering carry validated `credential_scope`.
Comma tenant-credential calls record `not_billable` usage and skip model-credit admission/charging. Platform calls retain charges and dispatch fee admission.
Model switches cannot exempt platform calls. Compute, storage, interaction budgets, tool authorization, and BFT billing remain unchanged.

Self-hosted Compose sets `COMMA_ENVIRONMENT=selfhost`. Workspace convergence issues one idempotent `unlimited_metered` grant through `BillingCore.Credits`.
Authorization and hosted billing remain unchanged. Stripe is unnecessary. Instance owners pay providers.

## Default Router and Worker models

Agents select concrete templates or follow platform role defaults.
Salix admins set platform pointers through the Agent Defaults page or `PATCH /v1/admin/agent-defaults`.
Tenant callers set creation pointers through `PATCH /v1/agent-defaults`.
BFT publishes Organization Router and Worker creation defaults to its Tenant config.
Creation copies the Tenant pointer unless a template is specified. Later Tenant changes leave existing Agents unchanged.
Empty Agent pointers follow platform changes on their next round.
A template referenced by a configured default cannot be deleted until that pointer changes.

Unset platform roles use built-in `default` (`gpt-test`). Selectors show one `Default (model)` and omit built-in fallback choices.
Concrete platform-default templates remain selectable without following later pointer changes.

Comma Model & API lists profiles and gives each Agent one picker: models by family, effort, and account (automatic or one profile).
A Worker on a Codex or Claude Code compute runtime picks among its plan's models, with no account. Earlier template choices show until replaced.
Salix and BFT selectors show the model display name or ID. Template names are aliases. Model/connection edits clear display metadata unless replacements are supplied.
`SalixAgent.ModelDiscovery` serves Comma, Salix, and BFT with each surface's authorization and credential scope.
API-key discovery retains these bounds and manual entry on failure. Salix scrolls returned matches. BFT shows up to 50. Search uses returned data.
Discovery retains at most 32 efforts per Codex model.
Comma Custom and Ollama profiles list the endpoint's models once, when they connect. Visits, retries, or profile changes reload the catalog, profiles, and Agents without polling.
Failure preserves choices and allows retry. A model no enabled profile serves is not offered.

Migration `20260922000001_agent_creation_defaults` copies Tenant templates into empty Agent choices in pages of 100 conditional writes.
It preserves explicit choices, conflicts, deleted records, unrelated fields, Agents, Sessions, credentials, and Tenant configuration.
Back up canonical Agent records and Tenant defaults before migration. Retry interruption through the release runner. Storage failures stop the migration.
The owner accepts temporary model differences and replacement of concurrent Default choices. Writes stay available. No consistent inheritance snapshot is promised.
Old processes can write empty choices after their page passes. These follow platform defaults after rollout. Retries can replace newer Default choices.
Recovery uses forward repair. Users can select their models again after rollout.
Use the mainline rolling release flow and existing phase budget, without shutdown or a new admission gate.
Convergence requires completed migration and new processes that resolve empty choices through platform defaults.

## Free Comma Router models

Comma Admin Billing owns a database-backed, initially empty free Router list, limited to 100 provider/SKU pairs.
Saves require authorization, confirmation, reason, and audit. Displayed revision checks prevent lost edits. Audits retain both lists.
Files and environment variables cannot configure this policy.

A matching Comma Router main-model call does not require a positive model-credit balance and does not debit credits.
The owner checks the actual Agent against the Workspace Router, tenant, and billing account.
Workers, tools, auxiliary calls, compute, storage, account status, permissions, and interaction budgets retain their existing rules.
Model selection and prices are unchanged. BYOK and subscription exemptions remain separate.

The message entry checks the current Router model. Each Round checks its actual model again before provider dispatch.
Rounds retain admitted exemptions through asynchronous completion. List changes affect later admissions only.
Paid calls retain decisions through delayed settlement and pending-price replay.
Free calls record usage with `charge_status = free_router_model`. They do not enter the pending user-charge queue, even without a price.
Raw usage remains available for cost analysis. This change does not add automatic cost valuation or a durable usage journal.

Each qualifying Round reads one Workspace by primary key and one policy row, limited to 100 models.
Router message entry reads one policy row and resolves one template when nonempty. No Workspace polling or model scan occurs.
Policy failures reject platform calls without charging. Usage-buffer loss and shutdown limits below still apply.

## Subscription accounts

Workspace-owner APIs at `/v1/comma/workspaces/:workspace_id/subscription-accounts` expose AccountPool import, versioned update/delete, quota refresh and OAuth.
The owner enforces tenant scope, encryption, versions, and OAuth ownership. Credential-free responses set `Cache-Control: no-store`.
UI pages: 25 accounts, no account/quota polling. JSON imports (BFT only): two megabytes, cleared on category/workspace change or cancellation.

Device codes: Codex web, Grok, Kimi Code, Copilot. Callback URLs or codes: Claude, Gemini.
Start with `POST /oauth` (Codex: `mode: "device"`). Check through `POST /oauth/:id` with empty `code`.
Device IDs stay inside encrypted OAuth attempts. The browser receives only the user code, verification URL, interval, and expiry.
One open enrollment polls one indexed attempt, never the account list. Polling stops on completion, failure, cancellation, or expiry.
Each provider check has a 30-second budget. The provider interval is at least five seconds, with at most 180 checks per 15-minute attempt.
The owner claims attempts before exchange. Worker failure consumes attempts and requires login again.
Cancellation stops checks without undoing accepted exchanges.

Electron binds loopback before browser launch: Codex (`127.0.0.1:1455`), Claude (`127.0.0.1:54545`).
Main validates state and exchanges through its Session transport. Codes/tokens stay in Main. Polling: 1/second, 15 minutes.
Listeners close on callback, cancellation, expiry, Session loss, or shutdown. Occupied ports allow retry. Credentials stay valid.
Valid loopback callbacks foreground Comma. Pages attempt closure after 1.5 seconds, with manual return.
Billing/Telegram use flavor-specific links. Browser restrictions can prevent closure.

Codex menus show `Reset quota (N resets left)` and require confirmation. Unknown counts show `count unknown`. Unknown/zero disables new resets.
Pending attempts retry with the same key across reloads. Claude cannot reset.

`POST /:id/quota` refreshes quota and the optional Codex reset-credit count.
`POST /:id/quota/reset` can consume one Codex reset credit. Pass `version` and `request_id`.
Reuse `request_id` for retries. A pending `reset_attempt` in the account response supplies the recovery key.
Responses and Settings separate `outcome` from `quota_refreshed`. Refresh failure cannot undo a confirmed reset. Resets do not purchase credits.

Subscription templates store model, effort, and `provider_config.account_pool`, with no account binding, endpoint, or API key.
Comma resolves through `POST /v1/comma/workspaces/:workspace_id/model-templates/resolve-subscription`, then assigns through the Agent/default API.
Resolution reuses matching tenant, pool, model, and effort unchanged. Duplicates use the lowest visible private template ID.
Otherwise, create a 500,000-context-token template. Codex choices save the image configuration below.
A tenant database lock serializes menu resolutions across nodes, with a five-second lock timeout and bounded catalog reads.
Failed assignment can leave reusable templates. Manual writes remain unchanged. Selection does not check inference availability.
Runtime selects tenant accounts per request. Upstream validates SDK Codex effort.
Missing usable accounts return the bounded pool error without platform fallback.
Discovery selects one indexed enabled account.
Listing limits: 15 seconds, 1,000 models, two megabytes, and five Claude pages.
Credential preparation uses the shared LLM request budget, normally 600 seconds, without a separate worker receive timeout.

Pool calls record usage without Comma model-credit charges. Compute and storage charges remain.
Local key custody and worker setup are in [Development](development.md#local-subscription-setup).
Agent handoff troubleshooting is in [Development](development.md#local-model-switching).

## Bounded diagnosis

Before mutation, read active grants, source/redemption/Stripe events, errors, and idempotency keys. Delayed dashboards cannot prove credits.
VM availability uses typed `resource_kind = vm` decisions and grant transitions. Best-effort wakes require reconciliation from PostgreSQL facts.

## LLM usage delivery

LLM completion admits a fixed usage row and charge inputs to node-local ETS, without waiting for ClickHouse/ledger charging.
Fee authorization precedes provider calls.
The buffer holds up to 1,000 rows including the active batch. An occupied slot rejects the row without waiting or retry.
The owner accepts crash loss; capacity rejection and shutdown expiry can also lose usage.
No durable journal, outbox, or disk spill exists.

The writer stores raw usage before charging. Failed in-memory batches retry after at least one second.
Retries preserve ClickHouse row versions and billing source keys. Ledger idempotency prevents duplicate debits.
Shutdown closes admission and attempts each remaining batch once within 30 seconds.
Dependency failure or timeout can prevent drain. Crashes skip cleanup.
Live workers count rejections/write failures. Dead nodes cannot report lost rows.

## Codex subscription images

A Tenant-private template can select its Codex subscription pool in `image_config`:

```json
{
  "provider": "openai",
  "model": "gpt-image-2",
  "provider_config": {"account_pool": "codex"}
}
```

For Tenant-private Codex main-model templates, empty `image_config` resolves to the configuration above without a storage write. Explicit configuration takes precedence.
Salix, BFT, and Comma share this rule. Switching away from Codex removes only the implicit default.
In Salix Dashboard, set **Image generation source** to **Codex subscription** to save this configuration.
To follow the automatic rule, leave **Default / custom configuration** empty. Supply no endpoint or key.
The template owner determines the pool tenant. User-supplied tenant fields, endpoints, keys, and headers cannot change that route.
Global templates/Claude image pools are unsupported. Empty/unavailable pools fail without platform fallback.

`image.generate` uses the existing SDK image operation for `gpt-image-2`.
Reference images select the SDK's JSON image-edit operation. Size, quality, and output format come from the tool arguments.
The existing account selection reads at most three candidates per call. No image-specific polling or account scan is added.
Limits remain: 120 seconds/tool, 10 MB/output file, 16 MiB/worker input frame, 32 MiB/worker output.
Subscription image calls use the existing provider archive and usage metering seam. They do not charge Comma model credits.
After receiving response bytes, the host never retries another account, including on parse failure.

Template ownership, credential refresh, and account version checks remain authoritative.
Implementation tests cover image routing and tenant isolation. TLA+ transitions remain unchanged.

## Script and Loop decisions

`decide` uses an operator-owned Jev-compatible endpoint through existing LLM fee, usage, and archive seams.
Agent subscriptions/tenant keys are excluded. Usage retains the Session billing account.
The local pricing catalog seeds `typesafe/jev-1.13.0`: $0.042 per million input tokens, with free output tokens.
Source: [TypeSafe model pricing](https://docs.typesafe.ai/models), checked 2026-09-20.
The migration inserts local prices without provider calls. Rollback preserves existing pricing evidence.
A custom model requires its own catalog price. Missing pricing follows the existing pending-charge repair path.
See the [decision contract](salix/tasks-background-execution.md#decision-capability-design) for configuration and limits.
