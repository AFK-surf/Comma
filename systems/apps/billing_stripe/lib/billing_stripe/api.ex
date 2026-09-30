defmodule BillingStripe.API do
  @moduledoc "Boundary around the maintained Stripe library used by BillingStripe."

  @callback create_customer(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback create_checkout_session(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback create_customer_portal(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback retrieve_subscription(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback retrieve_payment_intent(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback list_prices(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback create_product(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback create_price(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_portal_configurations(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback retrieve_portal_configuration(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback create_portal_configuration(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback update_portal_configuration(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback retrieve_checkout_session(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback retrieve_invoice(binary(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback retrieve_charge(binary(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback retrieve_price(binary(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback retrieve_dispute(binary(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_invoice_payments(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_checkout_sessions(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_disputes(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback update_subscription(binary(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback create_subscription_schedule(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback update_subscription_schedule(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback release_subscription_schedule(binary(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback preview_invoice(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @optional_callbacks update_subscription: 3,
                      create_subscription_schedule: 2,
                      update_subscription_schedule: 3,
                      release_subscription_schedule: 3,
                      preview_invoice: 2,
                      list_invoice_payments: 2,
                      list_checkout_sessions: 2,
                      list_disputes: 2,
                      retrieve_price: 3,
                      retrieve_dispute: 3,
                      retrieve_invoice: 3,
                      retrieve_charge: 3,
                      retrieve_checkout_session: 3,
                      list_portal_configurations: 2,
                      retrieve_portal_configuration: 3,
                      create_portal_configuration: 2,
                      update_portal_configuration: 3
  @callback construct_webhook_event(binary(), binary(), binary(), non_neg_integer(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
