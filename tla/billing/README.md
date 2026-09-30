# Stripe credits lifecycle model

`StripeCredits.tla` models the payment-to-entitlement boundary shared by
`BillingStripe.Events`, `BillingCommerce.Subscriptions`, and
`BillingCore.Credits`.

The checked contract is deliberately narrow:

- subscription cycles become grantable only after an `invoice.paid` fact;
- duplicate delivery and scheduler replay cannot issue the same cycle/payment allocation twice;
- cancellation changes subscription state but preserves an already-paid grant;
- plan changes update subscription identity without rewriting or revoking
  credits from an already-paid cycle; the next paid cycle uses the new package;
- partial refunds preserve credits and record only the monetary refund state;
- full refunds reduce only this payment's credits, without a negative balance;
- disputes suspend spending and issuance. Winning does not recreate spent or refunded credits.

Each model cycle value represents one cycle/payment allocation. Invoice-to-Grant
attribution and upgrade arithmetic remain covered by runtime behavior tests.

Loss is modeled as the absence of an input transition; no delivery liveness is
claimed. Stripe owns webhook retry. The application journals every accepted
event and fails non-2xx on processing failure so provider redelivery can retry.
The unsafe configuration deliberately permits issuing before payment and must
violate `NoGrantBeforePayment`.

Run with `make tla-billing`.

## Webhook journal and subscription ordering

`WebhookJournal.tla` maps `BillingStripe.Webhooks.journal_event/2` to durable
insertion, and `process_journaled/1` to row lock, domain effects, and atomic
processed-marker commit. Requests can crash before or after commit; redelivery
can duplicate a request. Only committed events can be acknowledged. The grant
counter represents one grant-bearing event; ignored events have no grant claim.
The unsafe configuration acknowledges an unfinished journal row and must fail.

`SubscriptionReconcile.tla` maps `BillingStripe.Events.reconcile_subscription/3`
and `BillingCommerce.Subscriptions.reconcile_provider_subscription/2` to taking
the subscription row lock, reading Stripe, and committing current status/plan.
Delayed event snapshots do not supply status. Revision numbers are model-only
ordering of provider states, not database fields. The model assumes Stripe GET
returns current state at some instant during the call. It excludes arbitrary
provider corruption. Timeout, disconnect, and process restart abort the SQL
transaction; retries are fresh webhook requests. The unsafe configuration uses
delayed payload state and must violate non-regression.

These lifecycles remain separate from paid-cycle entitlement rules. There is no
delivery, provider-availability, or scheduler fairness assumption and no liveness
claim. A provider change after the last GET needs a later successful delivery.
PG supplies atomic transactions and row locking; effects use the same repo.
The existing CI `tla-other` suite runs all three models and their counterexamples.
