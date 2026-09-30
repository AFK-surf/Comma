defmodule BillingStripe.Portal do
  @moduledoc "Stripe customer portal command."

  @spec create_customer_portal(map()) :: {:ok, map()} | {:error, term()}
  def create_customer_portal(attrs) when is_map(attrs) do
    BillingStripe.Telemetry.observe(
      :stripe_portal,
      BillingStripe.Telemetry.surface(attrs),
      fn -> do_create_customer_portal(attrs) end
    )
  end

  defp do_create_customer_portal(attrs) do
    with {:ok, config} <- config(),
         {:ok, configuration} <- configured_portal() do
      idempotency_key =
        attrs[:idempotency_key] || attrs["idempotency_key"] ||
          required(attrs, :billing_account_id)

      params =
        %{
          customer: required(attrs, :customer_id),
          return_url: required(attrs, :return_url)
        }
        |> Map.put(:configuration, configuration)

      case config.api.create_customer_portal(params, stripe_opts(config, idempotency_key)) do
        {:ok, session} -> {:ok, public_session(session)}
        {:error, reason} -> {:error, reason}
      end
    end
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

  defp configured_portal do
    case Application.get_env(:billing_stripe, :portal_configuration_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :stripe_portal_not_configured}
    end
  end

  defp stripe_opts(config, idempotency_key) do
    [api_key: config.secret_key, idempotency_key: idempotency_key]
  end

  defp required(attrs, key),
    do: attrs[key] || attrs[to_string(key)] || raise(ArgumentError, "missing portal field #{key}")

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
