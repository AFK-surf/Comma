defmodule BillingStripe.Customers do
  @moduledoc "Stripe customer creation backed by authoritative provider customer mappings."

  @provider "stripe"
  @provider_context "default"

  @spec ensure_customer(map()) :: {:ok, map()} | {:error, term()}
  def ensure_customer(attrs) when is_map(attrs) do
    BillingStripe.Telemetry.observe(
      :stripe_customer,
      BillingStripe.Telemetry.surface(attrs),
      fn -> do_ensure_customer(attrs) end
    )
  end

  defp do_ensure_customer(attrs) do
    lookup = customer_lookup(attrs)

    case BillingCommerce.get_active_provider_customer(lookup) do
      {:ok, customer} ->
        {:ok, customer}

      {:error, :not_found} ->
        create_and_bind_customer(attrs)
    end
  end

  defp create_and_bind_customer(attrs) do
    with {:ok, config} <- config() do
      account_id = required(attrs, :billing_account_id)

      idempotency_key =
        attrs[:idempotency_key] || attrs["idempotency_key"] || "stripe:customer:#{account_id}"

      metadata = %{
        "billing_account_id" => account_id,
        "surface" => required(attrs, :surface),
        "product_owner_type" => required(attrs, :product_owner_type),
        "product_owner_id" => required(attrs, :product_owner_id)
      }

      params =
        %{
          email: attrs[:billing_email] || attrs["billing_email"],
          name: attrs[:display_name] || attrs["display_name"],
          metadata: metadata
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      case config.api.create_customer(params, stripe_opts(config, idempotency_key)) do
        {:ok, customer} ->
          provider_customer_id = session_value(customer, :id)

          BillingCommerce.bind_provider_customer(
            attrs
            |> Map.merge(%{
              provider: @provider,
              provider_context: @provider_context,
              provider_customer_id: provider_customer_id,
              source_type: "stripe_customer",
              metadata:
                Map.merge(attrs[:metadata] || attrs["metadata"] || %{}, %{
                  "stripe_customer_created" => true
                })
            })
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp customer_lookup(attrs) do
    %{
      repo: attrs[:repo] || attrs["repo"],
      sql_runner: attrs[:sql_runner] || attrs["sql_runner"],
      billing_account_id: required(attrs, :billing_account_id),
      provider: @provider,
      provider_context: @provider_context
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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

  defp session_value(session, key) when is_map(session),
    do: Map.get(session, key) || Map.get(session, to_string(key))

  defp required(attrs, key) do
    value = attrs[key] || attrs[to_string(key)]

    if is_nil(value) or value == "" do
      raise ArgumentError, "missing Stripe customer field #{key}"
    else
      value
    end
  end
end
