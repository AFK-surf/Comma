defmodule BillingStripe.PortalSync do
  @moduledoc "Explicit operations for the nondefault Comma customer portal."

  def sync(_catalog, opts \\ []) do
    api = Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)
    key = Application.get_env(:billing_stripe, :secret_key)
    id = opts[:configuration_id] || Application.get_env(:billing_stripe, :portal_configuration_id)
    stripe_opts = [api_key: key]

    with true <- is_binary(key) and key != "",
         :ok <- configured_or_bootstrap(id, opts),
         {:ok, portal} <- existing(api, id, stripe_opts),
         :ok <- nondefault(portal),
         params <- params(),
         {:ok, result} <- converge(api, portal, params, stripe_opts, opts) do
      {:ok, result}
    else
      false -> {:error, :stripe_not_configured}
      {:error, _} = error -> error
    end
  end

  defp configured_or_bootstrap(id, opts) do
    if opts[:bootstrap] == true or (is_binary(id) and id != ""),
      do: :ok,
      else: {:error, :stripe_portal_not_configured}
  end

  defp existing(api, id, opts) when is_binary(id) and id != "",
    do: api.retrieve_portal_configuration(id, %{}, opts)

  defp existing(api, _, opts), do: discover(api, opts, nil, nil)

  defp discover(api, opts, cursor, found) do
    params = %{limit: 100} |> maybe_cursor(cursor)

    with {:ok, page} <- api.list_portal_configurations(params, opts) do
      data = field(page, :data) || []

      matches =
        Enum.filter(data, fn portal ->
          not field(portal, :is_default) and
            field(field(portal, :metadata) || %{}, :surface) == "comma"
        end)

      case Enum.reject([found | matches], &is_nil/1) do
        [_, _ | _] ->
          {:error, :ambiguous_comma_portal}

        candidates ->
          candidate = List.first(candidates)

          if field(page, :has_more) and data != [] do
            discover(api, opts, field(List.last(data), :id), candidate)
          else
            {:ok, candidate}
          end
      end
    end
  end

  defp nondefault(nil), do: :ok

  defp nondefault(portal) do
    surface = field(field(portal, :metadata) || %{}, :surface)

    if field(portal, :is_default) or surface not in [nil, "comma"],
      do: {:error, :portal_not_comma},
      else: :ok
  end

  defp params do
    %{
      name: "Comma",
      metadata: %{surface: "comma"},
      business_profile: %{headline: "Comma billing"},
      login_page: %{enabled: false},
      features: %{
        customer_update: %{enabled: false},
        invoice_history: %{enabled: true},
        payment_method_update: %{enabled: true},
        subscription_cancel: %{enabled: true, mode: "at_period_end", proration_behavior: "none"},
        subscription_update: %{enabled: false}
      }
    }
  end

  defp converge(api, portal, params, stripe_opts, opts) do
    cond do
      opts[:dry_run] == true and opts[:verify] == true ->
        if portal && matches?(portal, params) && field(portal, :active),
          do: {:ok, %{configuration_id: field(portal, :id), action: :verified}},
          else: {:error, :portal_configuration_drift}

      opts[:dry_run] ->
        {:ok,
         %{
           configuration_id: portal && field(portal, :id),
           action: if(portal, do: :update, else: :create),
           params: params
         }}

      portal ->
        api.update_portal_configuration(
          field(portal, :id),
          Map.put(params, :active, true),
          stripe_opts
        )

      true ->
        api.create_portal_configuration(
          params,
          Keyword.put(
            stripe_opts,
            :idempotency_key,
            "comma:portal:bootstrap"
          )
        )
    end
  end

  defp matches?(actual, expected) when is_map(expected),
    do: Enum.all?(expected, fn {key, value} -> matches?(field(actual, key), value) end)

  defp matches?(actual, expected) when is_list(expected) do
    is_list(actual) and length(actual) == length(expected) and
      Enum.all?(expected, fn item -> Enum.any?(actual, &matches?(&1, item)) end)
  end

  defp matches?(actual, expected), do: actual == expected
  defp maybe_cursor(params, nil), do: params
  defp maybe_cursor(params, cursor), do: Map.put(params, :starting_after, cursor)
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp field(_, _), do: nil
end
