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

Codex menus show `Reset quota (N resets left)` and require confirmation. Unknown counts show `count unknown`. Unknown or zero counts disable new resets.
Pending attempts retry with the same key across reloads. Claude cannot reset.

`POST /:id/quota` refreshes quota and the optional Codex reset-credit count.
`POST /:id/quota/reset` can consume one Codex reset credit. Pass `version` and `request_id`.
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

## Bounded diagnosis

Before mutation, read active grants, source, redemption and Stripe events, errors, and idempotency keys. Delayed dashboards cannot prove credits.
VM availability uses typed `resource_kind = vm` decisions and grant transitions. Best-effort wakes require reconciliation from PostgreSQL facts.

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
