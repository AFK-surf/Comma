# Billing and models

## Financial authority

PostgreSQL owns grants, sources, payments and redemptions. Active `credit_grants` own balances.
ClickHouse cannot gate resources, compensation or issuance.
`BillingCore.FeeControl.authorize/1` owns current-fact admission, cache and pending replies within the request timeout.
Failed queries keep cache entries. Stale refreshes cannot replace newer results. See the [paid-work contract](architecture/DOMAIN_CONCEPTS.md#paid-work-admission).

Plan, package and provider lookup keys are stable. Stripe IDs are mappings.
Migrations seed catalogs. Release tasks synchronize providers with dry-run, retry, and drift failure. Requests and migrations never synchronize providers.
Redelivery locks every event except `processed`. Domain writes and that marker commit together.
Failed provider GETs roll back. Correct the cause and request redelivery. No sweep or delivery-progress guarantee exists.
Reconciliation reads Stripe under Account and Subscription locks.

Comma uses stable `comma_*` keys and provider sale metadata. Historical mappings resolve events.
Monthly and yearly Prices share one Product per package. One nondefault Comma portal manages only payment methods, invoices, and cancellation.
Changes keep the paid cadence. One downgrade target applies at renewal. Selecting the current tier clears it.
Upgrades require Stripe invoice-preview confirmation, which clears the downgrade before payment.
Failed payment keeps the current tier and does not restore the downgrade.
`pending_if_incomplete` applies paid upgrades. Existing cancellation stays independent.
A Subscription keeps one change request, key, and invoice mapping.
Unknown results block different changes. Expired retries require exact evidence or actionable errors.
Schedules contain the current phase and one target. Comma handles cancellation where the portal cannot cancel scheduled subscriptions.

Only confirmed Stripe cash grants credits.
Invoices select the positive subscription line, not line order or the latest display plan.
Cycles keep invoice and PaymentIntent allocations. Each allocation issues one idempotent Grant.
Upgrades grant the positive tier difference times the remaining cycle seconds, rounded down.
Missing predecessor payments retry without granting a full base allocation.
Partial refunds record money and preserve credits. Full refunds and lost disputes revoke only the unspent and future rights of that payment.
Spent amounts stay recorded. Refunds preserve issued Cycles. Cancellation preserves paid-period credits.
Open disputes suspend rights. Wins restore valid remaining rights without undoing refunds.
Recharge expires at the end of Stripe's confirmed payment month in UTC.

Redeem codes bind an immutable Package Version. Their expiry limits when a code can be redeemed, not the redeemed entitlement's duration.
Internal subscription redemption starts in the current UTC calendar month. Monthly packages create one monthly Cycle. Annual packages create twelve consecutive monthly Cycles.
Each Cycle issues the package's monthly credits through the existing scheduler. Credits expire at that Cycle's end. The subscription does not renew beyond the redeemed term.
Existing redemptions keep their recorded Cycles. Repair missing annual Cycles through the subscription command with the original redemption identity and month, after checking existing Cycles.

A Grant with `usage_credits.resource_kinds` pays only for those kinds. Monthly free credits pay only for Cloud VM and storage ([rule](architecture/DOMAIN_CONCEPTS.md)).

## Comma BYOK

Dispatch and metering carry validated `credential_scope`.
The [client core](../clients/packages/core/src/sign-in-loopback.ts) keeps provider Keys. No renderer receives a Key.
Comma tenant-credential calls record `not_billable` usage and skip model-credit admission and charging. Platform calls keep charges and dispatch fee admission.
Model switches cannot exempt platform calls. Compute, storage, interaction budgets, tool authorization, and BFT billing are unchanged.

Self-hosted Compose sets `COMMA_ENVIRONMENT=selfhost`. Workspace convergence issues one idempotent `unlimited_metered` grant through `BillingCore.Credits`.
Authorization and hosted billing are unchanged. Stripe is not needed. Instance owners pay providers.

## Default Router and Worker models

An Agent holds a model choice (`model`) or follows the Platform Model tier of its role (Router or Worker), set on the Platform model page.
Following Agents use platform changes on their next round.
An unset platform role has no model. Its following Agents fail until the platform configures that tier.
BFT org admins limit choices with an allowed model list and copy per-role org defaults into new Agents ([BFT model settings](bridge-for-teams/design.md#model-settings)).

## Free Comma Router models

Comma Admin Billing owns a database-backed free Router list. It starts empty and holds at most 100 provider and SKU pairs.
Saves require authorization, confirmation, reason, and audit. Displayed revision checks prevent lost edits. Audits keep both lists.
Files and environment variables cannot configure this policy.

A matching Comma Router main-model call does not require a positive model-credit balance and does not debit credits.
The owner checks the actual Agent against the Workspace Router, tenant, and billing account.
Workers, tools, auxiliary calls, compute, storage, account status, permissions, and interaction budgets keep their existing rules.
Model selection and prices are unchanged. BYOK and subscription exemptions stay separate.

The message entry checks the current Router model. Each Round checks its actual model again before provider dispatch.
Rounds keep admitted exemptions through asynchronous completion. List changes affect later admissions only.
Paid calls keep decisions through delayed settlement and pending-price replay.
Free calls record usage with `charge_status = free_router_model`. They do not enter the pending user-charge queue, even without a price.
Raw usage stays available for cost analysis. No automatic cost valuation or durable usage journal exists.

## Subscription accounts

Workspace-owner APIs at `/v1/comma/workspaces/:workspace_id/subscription-accounts` expose AccountPool import, versioned update and delete, quota refresh and OAuth.
The owner enforces tenant scope, encryption, versions, and OAuth ownership. Credential-free responses set `Cache-Control: no-store`.
UI pages show 25 accounts, with no account or quota polling. JSON imports (BFT only) allow two megabytes and clear on category or workspace change or cancellation.

Codex and Claude menus show `Reset quota (N resets left)` and require confirmation. Unknown or zero counts disable new resets.
`quota.resets` lists one entry per reset kind (`session`, `weekly`, `model`, `full`, `credit`) with `left`, `expiries` and `usable`.
`POST /:id/quota/reset` uses one reset. Pass `version`, `request_id` and, for Claude, `kind`.
Reuse `request_id` for retries. A pending `reset_attempt` in the account response supplies the recovery key.
Responses and Settings separate `outcome` from `quota_refreshed`. Refresh failure cannot undo a confirmed reset. Resets do not purchase credits.

Pool calls record usage without Comma model-credit charges. Compute and storage charges remain.
Local key custody and worker setup are in [Development](development.md#local-subscription-setup).
Agent handoff troubleshooting is in [Development](development.md#local-model-switching).

The desktop menu-bar menu shows the subscription cycle's credit use and the 5-hour and weekly quota of at most three signed-in plans.
API-key profiles show no usage. Main holds the `billing` and `models` topics for the active workspace and runs no timer.
Opening the menu reads the balance and profiles again at most once a minute. Refresh reads the balance and the quota of each shown plan.
One read runs at a time; a Refresh chosen during another read runs after it.
The Usage and Model pages read on each entry, because the menu can hold their topics.
Cycle use compares the remaining credits of the subscription cycle grants with their issued credits (`original_credits` in the billing summary).
[Code](../clients/apps/electron/src/main/status-tray-usage.ts).

## Sandbox starts

A [sandbox Task](compute-devices.md#coding-sandboxes) starts a VM the Workspace pays for, so its start is authorized first, as a Group Cloud VM's is: a typed `resource_kind = vm` fee-control decision for provider `l4es` and SKU `sandbox-<size>` (`SalixWeb.CodingSandboxes.authorize/4`, through `vm_authorization_mod`).
Placement asks when a Task is placed on a sandbox (`entrypoint` `sandbox_place`, the user's action): a refusal makes no Task, and the Router is told why (`insufficient_credits`, `account_inactive`, `sandbox_restricted`, or a temporary outage). The product asks again when a Message wakes a stopped sandbox (`sandbox_wake`, the system's, for the sandbox's own size): a refusal leaves the sandbox stopped and posts one notice into the Task per reason and generation; a reply once credits are there wakes it. A fee control that does not answer is a temporary outage: the Task is not made, or the sandbox stays stopped with a notice, and a later reply asks again.
A Workspace with no billing account is neither authorized nor charged. Sandbox time from `ready` to stop is metered on the same SKU. By owner decision (2026-10-27) the SKU has no catalog price yet: sandbox time is recorded, not charged, and its meter rows stay `pending_pricing`. A price seeded later charges the pending rows of the past month (`replay_pending_charges`), so seed it with that in mind.

## Runtime agent pages

Billing inventory reads `GET /v1/runtime/agents/page` with a required, tenant-authorized `group_id`.
`limit` accepts 1 through 100 and defaults to 100. The response contains `data`, `next_cursor`, and `has_more`.
The cursor is the existing opaque group/lifecycle cursor over PostgreSQL Agent IDs.
Status and visibility filters apply to one storage page. They do not scan ahead to fill the result.
Follow the cursor while `has_more` is true, including empty `data` pages.
Task Agents remain included. Hidden Agents stay excluded. `include_archived=true` also includes archived Agents.
The existing `GET /v1/runtime/agents` endpoint retains its array response.

## Bounded diagnosis

Before mutation, read active grants, source, redemption and Stripe events, errors, and idempotency keys. Delayed dashboards cannot prove credits.
VM and sandbox availability use typed `resource_kind = vm` decisions and grant transitions. Best-effort wakes require reconciliation from PostgreSQL facts.

## LLM usage delivery

LLM completion admits a fixed usage row and charge inputs to node-local ETS. It does not wait for ClickHouse or ledger charging.
Fee authorization precedes provider calls.
The buffer holds up to 1,000 rows, including the active batch. An occupied slot rejects the row without waiting or retry.
The owner accepts crash loss. Capacity rejection and shutdown expiry can also lose usage.
No durable journal, outbox, or disk spill exists.

The writer stores raw usage before charging. Failed in-memory batches retry after at least one second.
Retries keep ClickHouse row versions and billing source keys. Ledger idempotency prevents duplicate debits.
Shutdown closes admission and attempts each remaining batch once within 30 seconds.
Dependency failure or timeout can prevent drain. Crashes skip cleanup.
Live workers count rejections and write failures. Dead nodes cannot report lost rows.

## Codex subscription images

A catalog choice that the Tenant's own Codex subscription serves generates images through that subscription pool ([ModelChoice.media/2](../systems/apps/salix_agent/lib/salix_agent/model_choice.ex)):

```json
{
  "provider": "openai",
  "model": "gpt-image-2",
  "provider_config": {"account_pool": "codex"}
}
```

The subscription serves the choice when its pinned Profile is a Codex subscription.
Without a pin, it serves the choice when an enabled, signed-in Codex subscription of the Tenant serves the model.
This configuration replaces the platform image settings for that Agent. Other choices use the platform image settings.
The Agent's Tenant is the pool tenant. User-supplied tenant fields, endpoints, keys, and headers cannot change that route.
Claude image pools are unsupported. Empty or unavailable pools fail without platform fallback.

## Task model selection

The Dashboard Group page edits a route table with Key, Description, Model and Reasoning effort columns.
Keys are unique, case-sensitive strings. Descriptions guide classification. Row order does not set priority.
Users can add or delete entries, then save. The table permits up to 32 entries and 8 KiB of JSON.
Keys permit 128 UTF-8 bytes. Descriptions permit 1024 UTF-8 bytes.
Catalog candidates follow enabled tenant accounts, the saved Profile and the owner's model policy. Efforts follow the model.
Save rechecks availability and policy. An unchanged table can be disabled without a model-list read.
An empty table can be saved without a model-list read. Empty and disabled tables use the same normal Worker model selection path.
Neither case calls Jev, overrides the Task model, nor adds routing-specific tool restrictions.
The enable switch is preserved for empty tables. Adding entries and saving activates an enabled table.
A conditional Group write rejects a stale editor without replacing newer routing or unrelated Group fields.
The stored revision identifies the configuration used by historical decisions. It is not a separate authorization boundary.

The route-table editor imports and exports JSON files with `mode: routes`, `schema_version: 2`, and `entries`.
Export uses the current draft, including unsaved edits. It works when a saved model is unavailable.
Import replaces the draft entries after format validation. Save applies the entries through the normal model-access and concurrent-edit checks.
Invalid files leave the draft unchanged. Discard changes restores the saved table.
Files omit the enable switch, table-level Profile and revision. Save keeps the destination settings and assigns a new revision.
Files can contain at most 64 KiB, including whitespace. The existing 32-entry and 8 KiB compact-table limits still apply.

Stored tables also carry `revision` and `enabled`.
Each entry holds `key`, `description`, and a catalog or platform Model Choice, including its payment and Profile settings.
Table-level `profile_id` constrains every entry.
Other experiment modes keep their existing callers.
API Key choices are labeled "Pay-per-use". Unpinned tables also offer the platform Task model.
A Group without its own table routes built-in-model Tasks by the platform route table, with platform-owned learning ([Platform Model](architecture/DOMAIN_CONCEPTS.md#adaptive-task-routing)).
An empty organization allowlist still requires tenant accounts to serve catalog models.
Save, file transfer and Task creation preserve each choice under normal Task authorization and account selection.

The optional Group value `task_model_selection` selects an internal Task's Session model before its first Conversation commit.
Without this value, the Router can choose a model through the normal Task tool.
Automatic routing applies only to internal Tasks without an explicit Session model.
The Router still supplies `runs_on`. Explicit places, Worker Station bindings and Group default places keep the normal placement rules.
Station and sandbox Tasks keep their runtime models. An explicit model keeps the normal product authorization checks.
For an internal Task without an explicit model, omit `model` and let the Group policy select it.
In `explicit` mode, every internal Task creation path must supply an allowed model, reasoning effort and configured Profile pin.
The common creation entry rejects missing or unsupported choices from Router tools, product APIs and scheduled callers.
Station and sandbox Tasks keep their runtime model rules.
An optional `profile_id` pins the normal tenant-owned Profile. It does not bypass model authorization or payment policy.
The Conversation owner builds the Jev request from the exact delegated content and the Group policy.
Product-created Tasks need no active Router round. Their prepared delegator Participant supplies the Session identity and Group-owned billing context.
`routes` mode classifies the Task against the entry descriptions and uses the selected entry's model.
Request-local choice IDs support arbitrary user keys. Responses resolve against the same configuration snapshot.
One entry selects its model directly, without a Jev call. Unknown choices fail Task selection.
Model choice and inference retain the existing Group policy and Profile authorization checks. Failures do not act as empty tables.
Decision evidence retains the key, configuration revision and complete Model Choice.
`jev` mode asks for one configured candidate. Jev receives no model table or cost facts.
A route table holds at most 32 entries in 8 KiB. It adds no per-child polling.
Server-owned Task decisions accept at most 64 KiB of encoded input, including the complete Task command and question configuration.
All selection failures use `task_model_selection_failed`. An oversized request includes `input_too_large` before inference or Task commit. Shorten the content or routing descriptions, supply an authorized model explicitly, or disable routing.
The server does not truncate the command. A single-entry table makes no decision call and has no decision-input limit.
The public `decide` tool keeps its 12 KiB limit.

The normal product model authorization applies. A standalone Salix Group uses its Tenant's catalog choices; a Bridge Group keeps its organization policy.
A decision failure leaves the Task uncommitted. It never substitutes `default_task_model`.
Errors name the cause and recovery action. Retry `timeout` and `rate_limited`. Fix decision-provider configuration or model/Profile access when those checks fail.
A retry of a committed automatic Task command keeps the stored Participant model and does not call Jev again.
Task metadata stores `policy_mode` (`routes`, `jev`) and `decision_source` (`direct`, `jev`).
It also stores the configuration revision, matched key, Model Choice, original Worker Session ID, usage and elapsed time.
It does not duplicate the Task body, question descriptions, complete answer or route object. A direct selection reports no decision usage.
Full provider requests and responses use the existing encrypted, best-effort archive. A configuration revision identifies provenance. It does not retain historical tables or guarantee replay.
Rule updates affect new Tasks only. Salix never changes an active Session model for learning.
The route table's `learning` switch enables Salix-owned feedback and statistics.
Salix stores one receipt per Task and a bounded evidence window in PostgreSQL. No Evalens process must update the table.
A review accepted by a person counts as a completion and a failed Task as a failure. Tenant APIs read the learned evidence and submit explicit grades.
Infrastructure failures do not count as model failures.
See [learning](architecture/DOMAIN_CONCEPTS.md#adaptive-task-routing) and [routing usage](architecture/DOMAIN_CONCEPTS.md#routing-usage-statistics).

`agent.models` and the BFT model list read the local catalog and Profile state, without remote discovery or credential refresh.
The routing editor uses the same local list, scoped to its optional Profile and product model policy.
Page loads and saves do not call subscription `/models` endpoints. Actual selection uses normal Model Choice authorization.
An account-store failure preserves saved configuration and prevents unverified edits from being saved.
