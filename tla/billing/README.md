# Stripe credits lifecycle model

`StripeCredits.tla` models the payment-to-entitlement boundary shared by
`BillingStripe.Events`, `BillingCommerce.Subscriptions`, and
`BillingCore.Credits`. The checked contract:

- Subscription cycles become grantable only after an `invoice.paid` fact.
- Duplicate delivery and scheduler replay cannot issue the same cycle/payment allocation twice.
- Cancellation changes subscription state but preserves an already-paid grant.
- Plan changes do not rewrite or revoke credits from an already-paid cycle. The
  next paid cycle uses the new package.
- Partial refunds preserve credits and record only the monetary refund state.
- Full refunds reduce only this payment's credits, without a negative balance.
- Disputes suspend spending and issuance. Winning does not recreate spent or refunded credits.

Each model cycle value is one cycle/payment allocation. Runtime tests cover
Invoice-to-Grant attribution and upgrade arithmetic.

Loss is the absence of an input transition. No delivery liveness is claimed.
Stripe owns webhook retry. The application journals every accepted event and
returns non-2xx on processing failure so the provider can redeliver. The unsafe
configuration issues before payment and must violate `NoGrantBeforePayment`.

Run with `make tla-billing`. `make tla-other` runs all three billing models and
their counterexamples.

## Webhook journal and subscription ordering

`WebhookJournal.tla` maps `BillingStripe.Webhooks.journal_event/2` to durable
insertion, and `process_journaled/1` to row lock, domain effects, and atomic
processed-marker commit. Requests can crash before or after commit. Redelivery
can duplicate a request. Only committed events can be acknowledged. The unsafe
configuration acknowledges an unfinished journal row and must fail.

`SubscriptionReconcile.tla` maps `BillingStripe.Events.reconcile_subscription/3`
and `BillingCommerce.Subscriptions.reconcile_provider_subscription/2` to taking
the subscription row lock, reading Stripe, and committing current status/plan.
Delayed event snapshots do not supply status. Revision numbers are model-only
ordering of provider states, not database fields. The model assumes Stripe GET
returns current state at some instant during the call. It excludes arbitrary
provider corruption. Timeout, disconnect, and process restart abort the SQL
transaction. Retries are fresh webhook requests. The unsafe configuration uses
delayed payload state and must violate non-regression.

There is no delivery, provider-availability, or scheduler fairness assumption
and no liveness claim. A provider change after the last GET needs a later
successful delivery. Postgres supplies atomic transactions and row locking.
Effects use the same repo.
