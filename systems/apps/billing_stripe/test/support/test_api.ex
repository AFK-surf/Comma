defmodule BillingStripe.TestAPI do
  @moduledoc false

  @behaviour BillingStripe.API

  @recorder BillingStripe.TestAPI.Recorder

  @impl true
  def create_customer(params, opts) do
    record({:customer, params, opts})

    customer_id =
      params[:metadata]
      |> case do
        %{"billing_account_id" => account_id} when is_binary(account_id) ->
          "cus_" <> digest(account_id)

        _ ->
          "cus_" <> digest(opts[:idempotency_key] || inspect(params))
      end

    {:ok, %{id: customer_id, email: params[:email]}}
  end

  @impl true
  def create_checkout_session(params, opts) do
    record({:checkout, params, opts})
    suffix = digest(opts[:idempotency_key] || inspect(params))
    {:ok, %{id: "cs_test_" <> suffix, url: "https://checkout.stripe.test/session/" <> suffix}}
  end

  @impl true
  def create_customer_portal(params, opts) do
    record({:portal, params, opts})
    suffix = digest(opts[:idempotency_key] || inspect(params))
    {:ok, %{id: "bps_test_" <> suffix, url: "https://billing.stripe.test/session/" <> suffix}}
  end

  @impl true
  def retrieve_subscription(subscription_id, params, opts) do
    record({:retrieve_subscription, subscription_id, params, opts})

    case Application.get_env(:billing_stripe, :test_subscriptions, %{})[subscription_id] do
      {:error, reason} ->
        {:error, reason}

      subscription when is_map(subscription) ->
        {:ok, subscription}

      nil ->
        {:ok,
         %{
           "id" => subscription_id,
           "status" => "active",
           "items" => %{"data" => [%{"id" => "si_test_current"}]}
         }}
    end
  end

  @impl true
  def retrieve_payment_intent(payment_intent_id, params, opts) do
    record({:retrieve_payment_intent, payment_intent_id, params, opts})

    case Application.get_env(:billing_stripe, :test_payment_intents, %{}) do
      %{^payment_intent_id => {:error, reason}} ->
        {:error, reason}

      %{^payment_intent_id => amount} when is_integer(amount) and amount > 0 ->
        {:ok, %{id: payment_intent_id, amount: amount}}

      _ ->
        {:ok, %{id: payment_intent_id, amount: 2_000}}
    end
  end

  @impl true
  def list_prices(params, opts) do
    record({:list_prices, params, opts})
    {:ok, %{data: []}}
  end

  @impl true
  def create_product(params, opts) do
    record({:product, params, opts})

    {:ok,
     %{
       id: "prod_" <> digest(params[:metadata][:provider_lookup_key] || inspect(params)),
       name: params[:name],
       metadata: params[:metadata]
     }}
  end

  @impl true
  def create_price(params, opts) do
    record({:price, params, opts})

    {:ok,
     %{
       id: "price_" <> digest(params[:lookup_key]),
       lookup_key: params[:lookup_key],
       currency: params[:currency],
       unit_amount: params[:unit_amount],
       type: if(Map.has_key?(params, :recurring), do: "recurring", else: "one_time"),
       recurring: params[:recurring],
       nickname: params[:nickname],
       product: params[:product],
       metadata: params[:metadata]
     }}
  end

  @impl true
  def construct_webhook_event(payload, "t=1,v1=bad", _secret, _tolerance, opts) do
    record({:webhook, payload, "t=1,v1=bad", opts})
    {:error, :invalid_signature}
  end

  def construct_webhook_event(payload, signature_header, _secret, _tolerance, opts) do
    record({:webhook, payload, signature_header, opts})
    Jason.decode(payload)
  end

  defp record(call) do
    case Process.whereis(@recorder) do
      nil -> :ok
      _pid -> Agent.update(@recorder, &[call | &1])
    end
  end

  defp digest(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end
