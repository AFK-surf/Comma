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

  @spec create_subscription_change_portal(map()) :: {:ok, map()} | {:error, term()}
  def create_subscription_change_portal(attrs) when is_map(attrs) do
    BillingStripe.Telemetry.observe(
      :stripe_subscription_change_portal,
      BillingStripe.Telemetry.surface(attrs),
      fn -> do_create_subscription_change_portal(attrs) end
    )
  end

  defp do_create_customer_portal(attrs) do
    with {:ok, config} <- config() do
      idempotency_key =
        attrs[:idempotency_key] || attrs["idempotency_key"] ||
          required(attrs, :billing_account_id)

      params =
        %{
          customer: required(attrs, :customer_id),
          return_url: required(attrs, :return_url)
        }
        |> put_configuration()

      case config.api.create_customer_portal(params, stripe_opts(config, idempotency_key)) do
        {:ok, session} -> {:ok, public_session(session)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_create_subscription_change_portal(attrs) do
    with {:ok, config} <- config(),
         subscription_id <- required(attrs, :subscription_id),
         {:ok, subscription} <-
           config.api.retrieve_subscription(
             subscription_id,
             %{expand: ["items.data.price"]},
             api_key: config.secret_key
           ),
         {:ok, subscription_item_id} <- subscription_item_id(subscription) do
      return_url = required(attrs, :return_url)
      success_url = required(attrs, :success_url)

      params =
        %{
          customer: required(attrs, :customer_id),
          return_url: return_url,
          flow_data: %{
            type: "subscription_update_confirm",
            after_completion: %{
              type: "redirect",
              redirect: %{return_url: success_url}
            },
            subscription_update_confirm: %{
              subscription: subscription_id,
              items: [
                %{
                  id: subscription_item_id,
                  price: required(attrs, :provider_price_id),
                  quantity: 1
                }
              ]
            }
          }
        }
        |> put_configuration()

      idempotency_key = required(attrs, :idempotency_key)

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

  defp put_configuration(params) do
    case Application.get_env(:billing_stripe, :portal_configuration_id) do
      id when is_binary(id) and id != "" -> Map.put(params, :configuration, id)
      _ -> params
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

  defp subscription_item_id(subscription) do
    items = session_value(subscription, :items)
    data = session_value(items || %{}, :data) || []

    case data do
      [item] ->
        case session_value(item, :id) do
          id when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, :stripe_subscription_item_missing}
        end

      _ ->
        {:error, :stripe_subscription_item_unsupported}
    end
  end
end
