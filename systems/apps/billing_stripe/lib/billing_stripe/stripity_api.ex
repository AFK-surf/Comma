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
  def create_customer_portal(params, opts) do
    Stripe.BillingPortal.Session.create(params, opts)
  end

  @impl true
  def retrieve_subscription(subscription_id, params, opts) do
    Stripe.Subscription.retrieve(subscription_id, params, opts)
  end

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
  def construct_webhook_event(payload, signature_header, secret, tolerance, opts) do
    opts = Keyword.put(opts, :response_as, :map)
    Stripe.Webhook.construct_event(payload, signature_header, secret, tolerance, opts)
  end
end
