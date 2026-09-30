defmodule BillingStripe.Checkout do
  @moduledoc "Stripe checkout session command."

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(attrs) when is_map(attrs) do
    BillingStripe.Telemetry.observe(
      :stripe_checkout,
      BillingStripe.Telemetry.surface(attrs),
      fn ->
        if (attrs[:mode] || attrs["mode"] || "subscription") == "subscription" do
          BillingCommerce.SubscriptionCheckout.create(
            attrs,
            &do_create_session/1,
            &retrieve_session/1
          )
        else
          do_create_session(attrs)
        end
      end
    )
  end

  defp do_create_session(attrs) do
    with {:ok, config} <- config(),
         {:ok, provider_price_id} <- provider_price_id(attrs),
         {:ok, mode} <- checkout_mode(attrs) do
      idempotency_key = required(attrs, :idempotency_key)
      metadata = metadata(attrs, mode)

      params =
        %{
          mode: stripe_mode(mode),
          success_url: required(attrs, :success_url),
          cancel_url: required(attrs, :cancel_url),
          line_items: [%{price: provider_price_id, quantity: 1}],
          customer: attrs[:customer_id] || attrs["customer_id"],
          client_reference_id: required(attrs, :billing_account_id),
          metadata: metadata,
          expires_at: attrs[:expires_at] || attrs["expires_at"]
        }
        |> put_provider_metadata(mode, metadata)
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      case config.api.create_checkout_session(params, stripe_opts(config, idempotency_key)) do
        {:ok, session} -> {:ok, public_session(session)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp checkout_mode(attrs) do
    case attrs[:mode] || attrs["mode"] || "subscription" do
      mode when mode in ["subscription", "payment"] -> {:ok, mode}
      _ -> {:error, :invalid_checkout_mode}
    end
  end

  defp provider_price_id(attrs) do
    cond do
      is_binary(attrs[:provider_price_id] || attrs["provider_price_id"]) ->
        {:ok, attrs[:provider_price_id] || attrs["provider_price_id"]}

      true ->
        {:error, :provider_price_required}
    end
  end

  defp metadata(attrs, mode) do
    %{
      "billing_account_id" => required(attrs, :billing_account_id),
      "surface" => required(attrs, :surface),
      "product_owner_type" => required(attrs, :product_owner_type),
      "product_owner_id" => required(attrs, :product_owner_id),
      "package_code" => required(attrs, :package_code),
      "package_version" => required(attrs, :package_version)
    }
    |> then(fn metadata ->
      if mode == "subscription",
        do: Map.put(metadata, "subscription_checkout_key", required(attrs, :idempotency_key)),
        else: metadata
    end)
    |> stringify_metadata()
  end

  defp retrieve_session(id) do
    with {:ok, config} <- config(),
         {:ok, session} <-
           config.api.retrieve_checkout_session(id, %{}, api_key: config.secret_key) do
      {:ok, public_session(session)}
    end
  end

  defp stripe_mode("subscription"), do: :subscription
  defp stripe_mode("payment"), do: :payment

  defp put_provider_metadata(params, "subscription", metadata),
    do: Map.put(params, :subscription_data, %{metadata: metadata})

  defp put_provider_metadata(params, "payment", metadata),
    do: Map.put(params, :payment_intent_data, %{metadata: metadata})

  defp stringify_metadata(metadata) do
    Map.new(metadata, fn {key, value} -> {key, to_string(value)} end)
  end

  defp config do
    case Application.get_env(:billing_stripe, :secret_key) do
      key when is_binary(key) and key != "" ->
        {:ok,
         %{
           secret_key: key,
           api: Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)
         }}

      _ ->
        {:error, :stripe_not_configured}
    end
  end

  defp stripe_opts(config, idempotency_key) do
    [api_key: config.secret_key, idempotency_key: idempotency_key]
  end

  defp required(attrs, key),
    do:
      attrs[key] || attrs[to_string(key)] || raise(ArgumentError, "missing checkout field #{key}")

  defp public_session(session) do
    %{
      "id" => session_value(session, :id),
      "url" => session_value(session, :url),
      "provider" => "stripe",
      "status" => session_value(session, :status),
      "expires_at" => session_value(session, :expires_at)
    }
  end

  defp session_value(session, key) when is_map(session),
    do: Map.get(session, key) || Map.get(session, to_string(key))
end
