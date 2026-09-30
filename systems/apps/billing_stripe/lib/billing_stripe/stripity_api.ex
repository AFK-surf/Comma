defmodule BillingStripe.StripityAPI do
  @moduledoc "Stripe API implementation backed by stripity_stripe."

  @behaviour BillingStripe.API

  @impl true
  def create_customer(params, opts) do
    Stripe.Customer.create(params, opts)
  end

  @impl true
  def create_checkout_session(params, opts) do
    Stripe.Checkout.Session.create(params, opts)
  end

  @impl true
  def retrieve_checkout_session(id, params, opts),
    do: Stripe.Checkout.Session.retrieve(id, params, opts)

  @impl true
  def create_customer_portal(params, opts) do
    Stripe.BillingPortal.Session.create(params, opts)
  end

  @impl true
  def retrieve_subscription(subscription_id, params, opts) do
    Stripe.Subscription.retrieve(subscription_id, params, opts)
  end

  @impl true
  def update_subscription(id, params, opts), do: Stripe.Subscription.update(id, params, opts)
  @impl true
  def create_subscription_schedule(params, opts),
    do: Stripe.SubscriptionSchedule.create(params, opts)

  @impl true
  def update_subscription_schedule(id, params, opts),
    do: Stripe.SubscriptionSchedule.update(id, params, opts)

  @impl true
  def release_subscription_schedule(id, params, opts),
    do: Stripe.SubscriptionSchedule.release(id, params, opts)

  @impl true
  def preview_invoice(params, opts), do: Stripe.Invoice.create_preview(params, opts)

  @impl true
  def list_invoice_payments(params, opts), do: Stripe.InvoicePayment.list(params, opts)
  @impl true
  def list_checkout_sessions(params, opts), do: Stripe.Checkout.Session.list(params, opts)
  @impl true
  def list_disputes(params, opts), do: Stripe.Dispute.list(params, opts)

  @impl true
  def retrieve_price(id, params, opts), do: Stripe.Price.retrieve(id, params, opts)
  @impl true
  def retrieve_dispute(id, params, opts), do: Stripe.Dispute.retrieve(id, params, opts)

  @impl true
  def retrieve_invoice(id, params, opts), do: Stripe.Invoice.retrieve(id, params, opts)
  @impl true
  def retrieve_charge(id, params, opts), do: Stripe.Charge.retrieve(id, params, opts)

  @impl true
  def retrieve_payment_intent(payment_intent_id, params, opts) do
    Stripe.PaymentIntent.retrieve(payment_intent_id, params, opts)
  end

  @impl true
  def list_prices(params, opts) do
    Stripe.Price.list(params, opts)
  end

  @impl true
  def create_product(params, opts) do
    Stripe.Product.create(params, opts)
  end

  @impl true
  def create_price(params, opts) do
    Stripe.Price.create(params, opts)
  end

  @impl true
  def list_portal_configurations(params, opts),
    do: Stripe.BillingPortal.Configuration.list(params, opts)

  @impl true
  def retrieve_portal_configuration(id, params, opts),
    do: Stripe.BillingPortal.Configuration.retrieve(id, params, opts)

  @impl true
  def create_portal_configuration(params, opts),
    do: Stripe.BillingPortal.Configuration.create(params, opts)

  @impl true
  def update_portal_configuration(id, params, opts),
    do: Stripe.BillingPortal.Configuration.update(id, params, opts)

  @impl true
  def construct_webhook_event(payload, signature_header, secret, tolerance, opts) do
    opts = Keyword.put(opts, :response_as, :map)
    Stripe.Webhook.construct_event(payload, signature_header, secret, tolerance, opts)
  end
end
