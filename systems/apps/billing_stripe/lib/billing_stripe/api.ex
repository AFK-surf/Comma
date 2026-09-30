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
  @callback construct_webhook_event(binary(), binary(), binary(), non_neg_integer(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
