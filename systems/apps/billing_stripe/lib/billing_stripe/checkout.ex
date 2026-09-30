defmodule BillingStripe.Checkout do
  @moduledoc "Stripe checkout session command."

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(attrs) when is_map(attrs) do
    BillingStripe.Telemetry.observe(
      :stripe_checkout,
      BillingStripe.Telemetry.surface(attrs),
      fn -> do_create_session(attrs) end
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
          metadata: metadata
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
    base = %{
      "billing_account_id" => required(attrs, :billing_account_id),
      "surface" => required(attrs, :surface),
      "product_owner_type" => required(attrs, :product_owner_type),
      "product_owner_id" => required(attrs, :product_owner_id),
      "package_code" => required(attrs, :package_code),
      "package_version" => required(attrs, :package_version)
    }

    if mode == "payment" do
      period = current_month_period(attrs[:now] || attrs["now"] || DateTime.utc_now())

      Map.merge(base, %{
        "period_start" => DateTime.to_unix(period.valid_from),
        "period_end" => DateTime.to_unix(period.expires_at)
      })
    else
      base
    end
    |> stringify_metadata()
  end

  defp current_month_period(%DateTime{} = now) do
    date = DateTime.to_date(now)
    start_date = Date.new!(date.year, date.month, 1)
    end_date = add_month(start_date)

    %{
      valid_from: DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
      expires_at: DateTime.new!(end_date, ~T[00:00:00], "Etc/UTC")
    }
  end

  defp add_month(%Date{year: year, month: 12}), do: Date.new!(year + 1, 1, 1)
  defp add_month(%Date{year: year, month: month}), do: Date.new!(year, month + 1, 1)

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
      "provider" => "stripe"
    }
  end

  defp session_value(session, key) when is_map(session),
    do: Map.get(session, key) || Map.get(session, to_string(key))
end
