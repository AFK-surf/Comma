defmodule BillingStripe do
  @moduledoc "Stripe adapter commands and webhook processing for billing."

  alias BillingStripe.{Checkout, Customers, Portal, PriceSync, Webhooks}

  defdelegate ensure_customer(attrs), to: Customers
  defdelegate create_checkout_session(attrs), to: Checkout, as: :create_session
  defdelegate create_customer_portal(attrs), to: Portal
  defdelegate change_subscription(attrs), to: BillingStripe.SubscriptionChanges, as: :change

  defdelegate preview_subscription_change(attrs),
    to: BillingStripe.SubscriptionChanges,
    as: :preview

  defdelegate cancel_subscription_renewal(attrs),
    to: BillingStripe.SubscriptionChanges,
    as: :cancel

  defdelegate sync_prices(catalog, opts \\ []), to: PriceSync, as: :sync_catalog
  defdelegate handle_webhook(payload, signature_header, opts \\ []), to: Webhooks
end
