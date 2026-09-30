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
  def retrieve_checkout_session(id, params, opts) do
    record({:retrieve_checkout_session, id, params, opts})

    {:ok,
     Application.get_env(:billing_stripe, :test_checkout_sessions, %{})[id] ||
       %{id: id, status: "open", url: "https://checkout.stripe.test/session/" <> id}}
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
           "items" => %{
             "data" => [
               %{"id" => "si_test_current", "price" => %{"recurring" => %{"interval" => "month"}}}
             ]
           }
         }}
    end
  end

  @impl true
  def retrieve_payment_intent(payment_intent_id, params, opts) do
    record({:retrieve_payment_intent, payment_intent_id, params, opts})

    case Application.get_env(:billing_stripe, :test_payment_intents, %{})[payment_intent_id] do
      {:error, reason} ->
        {:error, reason}

      value when is_map(value) ->
        {:ok, value}

      amount ->
        {:ok,
         %{
           "id" => payment_intent_id,
           "amount_received" => amount || 2_000,
           "amount" => amount || 2_000,
           "status" => "succeeded",
           "metadata" => %{},
           "latest_charge" => %{"paid" => true, "created" => 1_780_272_000}
         }}
    end
  end

  @impl true
  def retrieve_charge(id, params, opts) do
    record({:retrieve_charge, id, params, opts})
    response(:test_charges, id)
  end

  @impl true
  def retrieve_dispute(id, params, opts) do
    record({:retrieve_dispute, id, params, opts})
    response(:test_disputes, id)
  end

  @impl true
  def retrieve_price(id, params, opts) do
    record({:retrieve_price, id, params, opts})
    response(:test_prices, id)
  end

  @impl true
  def retrieve_invoice(id, params, opts) do
    record({:retrieve_invoice, id, params, opts})
    response(:test_invoices, id)
  end

  @impl true
  def list_invoice_payments(params, opts) do
    record({:list_invoice_payments, params, opts})
    response(:test_invoice_payment_pages, params.payment.payment_intent)
  end

  @impl true
  def list_checkout_sessions(params, opts) do
    record({:list_checkout_sessions, params, opts})
    response(:test_checkout_session_pages, params.payment_intent)
  end

  @impl true
  def list_disputes(params, opts) do
    record({:list_disputes, params, opts})
    response(:test_dispute_pages, params.payment_intent)
  end

  defp response(key, id) do
    case Application.get_env(:billing_stripe, key, %{})[id] do
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  def list_prices(params, opts) do
    record({:list_prices, params, opts})
    calls = if Process.whereis(@recorder), do: Agent.get(@recorder, & &1), else: []

    prices =
      for {:price, price, _} <- calls, price.lookup_key in params.lookup_keys do
        {:ok, result} = price_result(price)

        product =
          Enum.find_value(calls, fn
            {:product, product, _} ->
              id = "prod_" <> digest(product[:metadata][:provider_lookup_key] || inspect(product))
              if id == price.product, do: Map.put(product, :id, id)

            _ ->
              nil
          end)

        Map.put(result, :product, product)
      end

    {:ok, %{data: Enum.uniq_by(prices, & &1.id)}}
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
    price_result(params)
  end

  defp price_result(params) do
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
       metadata: Map.put_new(params[:metadata] || %{}, :comma_purchasable, "true")
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
