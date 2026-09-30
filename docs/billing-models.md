# Billing and models

## Financial authority

PostgreSQL owns grants, sources, payments, and redemptions. Spendable credit comes from active `credit_grants`, not the `credit_balances` projection.
ClickHouse usage projections must not gate resources, refunds, revocation, or grant issuance.
Use typed decisions from `BillingCore.FeeControl.authorize/1` for new fee gates.
Fee Control owns cache and pending replies. Supervised checks stop at request timeout.
Slow/failed queries cannot block the mailbox or erase other accounts' cache. Enforcement queries current facts.
Refreshes affect only their key. Older results cannot overwrite newer refreshes.

Plans/packages use stable product-owned and provider lookup keys. Stripe `price_*`/`cus_*` values are mappings, not product identity.
Migrations seed local catalogs without provider calls. Release/operations tasks converge providers with dry-run, retry, and drift failure.

A Stripe event in `processing` does not prove that its worker still runs.
Redelivery locks the event row and retries any state except `processed`.
Domain writes and the processed marker commit together.
A failed provider GET rolls back domain writes and leaves a retryable event.
Correct the cause, then use provider redelivery. There is no unconditional local sweep or delivery-progress guarantee.
Subscription status and plan come from Stripe GET under the local subscription lock.
Paid invoice periods own their credits. Cancellation does not revoke already-paid periods.

## Tenant-private templates

Tenant-private model/provider templates serve all its Groups.
Global keys: `ctl/templates/{template_id}.json`. Private keys: `ctl/tenant_templates/{tenant_id}/{template_id}.json`.
Private IDs use `ptm1_` plus a 19-digit Snowflake. Tenant and ID are immutable; names do not shadow or inherit across scopes.

Creation derives ownership from authentication, ignoring supplied identity. Runtime uses the canonical Agent tenant.
A missing or foreign private ID fails closed without global, name, or platform-default fallback.
Deployment-wide meeting, ASR, and system references remain global-only.

Private main, media, vision, and analyze configuration cannot reference server `api_key_env` or `auth_token_env` values.
Validate nested configuration on write and again before runtime resolution.
Private media does not inherit platform credentials or endpoint defaults.
Image/video providers must be explicitly supported. Endpoints must be absolute HTTP(S).
These restrictions prevent a tenant-controlled URL from receiving platform credentials.

Tenant-key management exposes full private configuration, without granting product member roles. Catalogs whitelist credential-free fields plus `scope`. Comma management returns a separate secret-free view.

Catalogs read at most `limit + 1` keys and `limit` records per scope, at concurrency eight.
Combined results cannot exceed `limit` (maximum 100). Overflow/read failures return errors.
Private deletion scans at most 100 Agent keys in that tenant.
Archived Agents count toward that bound but do not block deletion through their template reference.
A larger or unreadable inventory rejects deletion.
The scan-then-delete check is not transactional with concurrent assignment and does not protect initial-Agent references.
Deletion removes configuration, not Agents, Sessions, or Conversations.

## Comma BYOK

Owners select Router/Workers independently, at most 50 per page, without polling or scan-ahead.
Tenant defaults apply at creation. Provisioning preserves Agent choices.
Comma has no Router default. Template sources are `pinned` or `platform_default`. Provider errors never select Comma-funded models.
Compute uses an explicit model or Agent template. In-flight models stay fixed.
Workers with runtime model settings show that model or runtime default. They reject templates.

Comma exposes name, provider, protocol, model, Key, endpoint, token limits, and image support.
Protocols: Responses, Chat Completions, Anthropic Messages. Unexposed auxiliary configuration survives edits.
`supports_images` enables native images and defaults to false. Each round captures model, protocol, and capability.
Switches affect later rounds, including retained-image reads. `fs.read_file` with `vision_query` uses configured auxiliary vision.
Otherwise, it returns image content only with declared native image support.
Omitted keys preserve the protected record version's Key. Empty keys are invalid.
Public responses expose `has_api_key`, never Keys/headers. Forms clear Keys on exit/save and never use browser storage.

Base URLs: absolute HTTP(S), without user info, query, or fragment.
Discovery rejects redirects. Endpoint changes require a fresh Key.
Bounds: five pages, 1,000 choices, 2 MB/response, 15 seconds overall, 5 seconds/read.
Discovery: no retries or per-model calls. Partial catalogs set `truncated`. Manual entry remains.
Add model links TokenDance under API key using Responses.
Salix normalizes TokenDance names/vendors on discovery and saved-template reads.
Other sources retain names. Clients render metadata. IDs and aliases stay unchanged.
`supported_protocols`: `responses`, `chat_completions`, `anthropic`. Missing means unknown. Empty means no recognized protocol.
Selection assumes Responses without filtering. Unsupported calls return provider errors.
Main owns PKCE, callback state, and Key. Discovery/save reuse Tenant templates.
Authorization/selection: ten minutes each. Local polling: 1/second.
Exit/cancellation/expiry/Session loss/shutdown clears local state. Keys remain valid.
TokenDance bills users. Build identity sets `app://{urlScheme}` and the Key name.
[Code](../clients/apps/electron/src/main/tokendance-authorization.ts).

The validated configuration carries `credential_scope` through actual dispatch and metering.
Comma tenant-credential calls record usage as `not_billable` and skip model-credit admission and charging.
Platform-credential calls retain their model charges.
Compute, storage, interaction budgets, and tool authorization do not change.
BFT billing does not inherit this Comma-only exemption.
The dispatch performs its own fee admission so a model switch cannot exempt a platform call.

Self-hosted Compose sets `COMMA_ENVIRONMENT=selfhost`.
Workspace convergence issues one idempotent `unlimited_metered` grant through `BillingCore.Credits`.
It does not bypass authorization, change hosted billing, or require Stripe.
Provider charges remain the instance owner's responsibility.

## Default Router and Worker models

An existing Agent either selects a concrete template or follows its platform role default.
Salix admins set platform pointers through the Agent Defaults page or `PATCH /v1/admin/agent-defaults`.
Tenant callers set creation pointers through `PATCH /v1/agent-defaults`.
BFT publishes Organization Router and Worker creation defaults to its Tenant config.
Creation without a specific template copies the Tenant pointer. Later Tenant changes do not affect that Agent.
An empty Agent pointer follows the platform. Platform changes apply on its next round.
A template referenced by a configured default cannot be deleted until that pointer changes.

An unset platform role uses the built-in `default` template (`gpt-test`).
Selectors show one `Default (model)` option and omit that fallback from concrete choices.
A concrete template that also supplies the platform default remains selectable: it does not follow later platform pointer changes.

Comma selectors show Default, vendor, model, then reasoning effort from low to high, including a single effort.
Vendor metadata or model ID determines the group and logo. Unknown vendors use a generic icon. Routing does not change the vendor.
Choices show the model display name or ID. Template names are aliases, shown after dashboard choices or as Comma subtitles for duplicates.
Model/connection edits clear display metadata unless replacements are supplied.
`SalixAgent.ModelDiscovery` serves Comma, Salix, and BFT with each surface's authorization and credential scope.
API-key discovery retains these bounds and manual entry on failure. Salix scrolls returned matches. BFT shows up to 50. Search uses returned data.
The API key model list and editor exclude subscription templates. Agent menus use saved API-key templates and discovered subscription models with efforts.
Discovery retains at most 32 efforts per Codex model.
Model & API manages subscription accounts. Catalogs refresh on visits, retries, or account changes: two calls, no polling.
Failure keeps saved choices and offers retry. No account returns no models.

Migration `20260922000001_agent_creation_defaults` copies Tenant templates into empty Agent choices in pages of 100 conditional writes.
It preserves explicit choices, conflicts, deleted records, unrelated fields, Agents, Sessions, credentials, and Tenant configuration.
Back up canonical Agent records and Tenant defaults before migration. Retry interruption through the release runner. Storage failures stop the migration.
The owner accepts temporary model differences and replacement of concurrent Default choices. Writes stay available. No consistent inheritance snapshot is promised.
Old processes can write empty choices after their page passes. These follow platform defaults after rollout. Retries can replace newer Default choices.
Recovery uses forward repair. Users can select their models again after rollout.
Use the mainline rolling release flow and existing phase budget, without shutdown or a new admission gate.
Convergence requires completed migration and new processes that resolve empty choices through platform defaults.

## Free Comma Router models

Comma Admin's Billing page owns a global free Router model list. The list starts empty and stores at most 100 provider/SKU pairs.
The database owns this Fee Control policy. Files and environment variables do not contain the list.
Admin saves require the existing authorization, confirmation, reason, and audit contract.
Each save checks the displayed revision to prevent lost edits. Audit evidence retains the previous and next lists.

A matching Comma Router main-model call does not require a positive model-credit balance and does not debit credits.
The owner checks the actual Agent against the Workspace Router, tenant, and billing account.
Workers, tools, auxiliary calls, compute, storage, account status, permissions, and interaction budgets retain their existing rules.
This list does not change model selection or the price catalog. Existing BYOK and subscription exemptions remain separate.

The message entry checks the current Router model. Each Round checks its actual model again before provider dispatch.
The Round retains the admitted exemption through asynchronous completion. List changes affect later admissions, not calls already admitted.
Paid calls also keep their original decision during delayed settlement and pending-price replay.
Free calls record usage with `charge_status = free_router_model`. They do not enter the pending user-charge queue, even without a price.
Raw usage remains available for cost analysis. This change does not add automatic cost valuation or a durable usage journal.

Each qualifying Round reads one Workspace by primary key and one policy row, bounded to 100 models.
Each Router message entry reads one policy row and, when nonempty, resolves one Agent template.
There is no per-Workspace polling or model scan. Policy read failures return an error before a platform call rather than silently charging it.
The existing usage-buffer loss and shutdown limits below still apply.

## Subscription accounts

Workspace-owner APIs at `/v1/comma/workspaces/:workspace_id/subscription-accounts` expose AccountPool import, versioned update/delete, quota refresh and OAuth.
The owner enforces tenant scope, encryption, versions, and OAuth ownership. Responses exclude credentials and set `Cache-Control: no-store`.
The UI pages 25 accounts without account/quota polling. JSON imports allow two megabytes and clear on category/workspace change or cancellation.

Web enrollment uses device codes for Codex. Claude web enrollment still accepts a callback URL or authorization code.
Start Codex device enrollment with `POST /oauth` and `mode: "device"`. Check it with `POST /oauth/:id` and an empty `code`.
Device IDs stay inside encrypted OAuth attempts. The browser receives only the user code, verification URL, interval, and expiry.
One open enrollment polls one indexed attempt, never the account list. Polling stops on completion, failure, cancellation, or expiry.
Each provider check has a 30-second budget. The provider interval is at least five seconds, with at most 180 checks per 15-minute attempt.
The owner claims attempts before exchange. Worker failure consumes the attempt and requires login again.
Cancellation stops future checks. It does not undo a credential exchange already accepted by the server.

Electron binds loopback before browser launch: Codex (`127.0.0.1:1455`), Claude (`127.0.0.1:54545`).
Main validates state and exchanges through its Session transport. Codes/tokens stay in Main. Polling: 1/second, 15 minutes.
Listeners close on callback, cancellation, expiry, Session loss, or shutdown. Occupied ports allow retry. Credentials stay valid.
Valid loopback callbacks foreground Comma. Pages attempt closure after 1.5 seconds and retain manual return.
Billing/Telegram pages use flavor-specific app links. Browser restrictions can prevent closure.

Each Codex account menu shows `Reset quota (N resets left)` and opens a confirmation page.
An unknown count shows `count unknown`. Unknown or zero counts disable new resets.
Pending attempts retain same-key retry across reloads. Claude has no reset action.

`POST /:id/quota` refreshes quota and the optional Codex reset-credit count.
`POST /:id/quota/reset` can consume one Codex reset credit. Pass `version` and `request_id`.
Reuse `request_id` for retries. A pending `reset_attempt` in the account response supplies the recovery key.
The response separates `outcome` from `quota_refreshed`. A failed quota refresh does not undo a confirmed reset.
The Settings result reports those outcomes separately. This operation does not purchase credits.

Subscription templates store model, effort, and `provider_config.account_pool`, with no account binding, endpoint, or API key.
Comma calls `POST /v1/comma/workspaces/:workspace_id/model-templates/resolve-subscription`, then the Agent/default assignment API.
Resolution reuses matching tenant, pool, model, and effort unchanged. Duplicates use the lowest visible private template ID.
Otherwise it creates a template with 500,000 context tokens. Codex choices also save the Codex image configuration below.
A tenant database lock serializes menu resolutions across nodes, with a five-second lock timeout and bounded catalog reads.
Failed assignment can leave a reusable template. Manual writes are unchanged.
Selection does not check inference availability. Runtime selects a tenant account per request.
The SDK passes Codex effort without static capability checks. Upstream validates it.
Missing usable accounts return the bounded pool error without platform fallback.
Discovery selects one indexed enabled account.
Its listing deadline is 15 seconds, maximum 1,000 models and two megabytes total.
Claude pagination stops after five pages.
Credential preparation uses the shared LLM request budget, normally 600 seconds, without a separate worker receive timeout.

Pool calls record usage without Comma model-credit charges. Compute and storage charges remain.
Local key custody and worker setup are in [Development](development.md#local-subscription-setup).
Agent handoff troubleshooting is in [Development](development.md#local-model-switching).

## Bounded diagnosis

Before mutation, read the account's active grants, source/redemption/Stripe event, errors, and idempotency keys. A delayed dashboard is not credit evidence.
For VM availability, check typed `resource_kind = vm` decisions and authoritative grant transitions.
A wake is best-effort. The reconciler must derive availability from PostgreSQL facts again.

## LLM usage delivery

LLM completion admits a fixed usage row and charge inputs to a node-local ETS buffer.
It does not wait for ClickHouse or ledger charging. Fee authorization still precedes each provider call.
The buffer holds up to 1,000 rows including the active batch. An occupied slot rejects the row without waiting or retry.
The owner accepts crash loss; capacity rejection and shutdown expiry can also lose usage.
No durable journal, PostgreSQL outbox, or disk spill exists.

The background writer stores raw usage before it charges through the existing charge engine.
Failed batches stay in memory and retry after at least one second.
Retries retain the original ClickHouse row version and billing source key. Ledger idempotency prevents duplicate debits.
Graceful shutdown closes admission and attempts each remaining batch once within a 30-second supervisor budget.
Dependency failure or budget expiry can prevent a complete drain. A crash does not run shutdown cleanup.
Live workers count rejected rows and write failures. A dead node cannot report the rows it lost.

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
This applies across Salix, BFT, and Comma. Switching away from Codex removes the implicit default. Explicit configuration remains.
In Salix Dashboard, set **Image generation source** to **Codex subscription** to save this configuration.
To follow the automatic rule, leave **Default / custom configuration** empty. Supply no endpoint or key.
The template owner determines the pool tenant. User-supplied tenant fields, endpoints, keys, and headers cannot change that route.
Global templates and Claude image pools are not supported.
Empty/unavailable pools return errors without platform fallback.

`image.generate` uses the existing SDK image operation for `gpt-image-2`.
Reference images select the SDK's JSON image-edit operation. Size, quality, and output format come from the tool arguments.
The existing account selection reads at most three candidates per call. No image-specific polling or account scan is added.
The tool retains its 120-second execution budget and 10 MB output-file limit.
The worker retains its 16 MiB input-frame limit and 32 MiB emitted-output limit.
Subscription image calls use the existing provider archive and usage metering seam. They do not charge Comma model credits.
Once the host receives response bytes, it does not try another account, even if parsing fails.

Template ownership, credential refresh, and account version checks remain authoritative.
Image routing and tenant isolation use implementation tests; retained TLA+ transitions are unchanged.

## Script and Loop decisions

The `decide` capability uses an operator-owned Jev-compatible endpoint and the existing LLM fee, usage, and archive seams.
It does not use the calling Agent's subscription or tenant API key. Usage retains the calling Session's billing account.
The local pricing catalog seeds `typesafe/jev-1.13.0`: $0.042 per million input tokens, with free output tokens.
Source: [TypeSafe model pricing](https://docs.typesafe.ai/models), checked 2026-09-20.
The migration only inserts local prices. It makes no provider request and preserves existing pricing evidence on rollback.
A custom model requires its own catalog price. Missing pricing follows the existing pending-charge repair path.
See the [decision contract](salix/tasks-background-execution.md#decision-capability-design) for configuration and limits.
