defmodule BillingCore.Pricing do
  @moduledoc """
  Resolves meter pricing from an in-memory catalog.

  Catalog entries are maps with at least `:provider`, `:sku`, and
  `:usd_micros_per_unit`. Optional `:resource_kind`, `:component`,
  `:meter_unit`, `:billing_account_id`, `:effective_at`, and `:expires_at`
  fields constrain selection. Account-specific prices outrank default prices,
  then the newest effective price wins.
  """

  alias BillingCore.Time

  @type resolve_result :: {:ok, map()} | {:error, :missing_pricing}

  @spec resolve([map()], String.t(), String.t(), String.t(), DateTime.t()) :: resolve_result()
  def resolve(catalog, billing_account_id, provider, sku, metered_at)
      when is_list(catalog) and is_binary(billing_account_id) do
    catalog
    |> Enum.filter(&matches?(&1, billing_account_id, provider, sku, nil, nil, nil, metered_at))
    |> Enum.sort_by(&sort_key(&1, billing_account_id), :desc)
    |> List.first()
    |> case do
      nil -> {:error, :missing_pricing}
      price -> {:ok, normalize(price)}
    end
  end

  def resolve_component(catalog, billing_account_id, component, metered_at) do
    provider = Map.fetch!(component, :provider)
    sku = Map.fetch!(component, :sku)
    resource_kind = Map.get(component, :resource_kind)
    name = Map.get(component, :component) || Map.get(component, :name)
    meter_unit = Map.get(component, :meter_unit)

    catalog
    |> Enum.filter(
      &matches?(
        &1,
        billing_account_id,
        provider,
        sku,
        resource_kind,
        name,
        meter_unit,
        metered_at
      )
    )
    |> Enum.sort_by(&sort_key(&1, billing_account_id), :desc)
    |> List.first()
    |> case do
      nil -> {:error, :missing_pricing}
      price -> {:ok, normalize(price)}
    end
  end

  @doc "Select the catalog component from the original usage facts, including pending replays."
  def lookup_component(event, component) do
    kind = to_string(component[:resource_kind])
    name = to_string(component[:component] || component[:name])
    threshold = context_threshold(component)

    cond do
      kind == "llm" and is_integer(threshold) and name in ~w(input output cache_read cache_write) and
        is_list(event[:meter_components]) and event.meter_components != [] ->
        prompt_tokens =
          event
          |> Map.get(:meter_components, [])
          |> Enum.filter(
            &(to_string(&1[:component] || &1[:name]) in ~w(input cache_read cache_write))
          )
          |> Enum.reduce(0, &(&1.quantity + &2))

        tier = if prompt_tokens > threshold, do: "long_context", else: "short_context"
        Map.put(component, :component, name <> ":" <> tier)

      kind == "voice" and name == "carrier_seconds" ->
        Map.put(component, :component, name <> ":" <> to_string(event[:carrier]))

      true ->
        component
    end
  end

  @openai_long_context_skus for base <- ~w(gpt-6-sol gpt-6-astra gpt-6-luna gpt-6.1-sol),
                                name <- [base, "openai/" <> base],
                                do: name

  defp context_threshold(%{provider: "openai", sku: sku})
       when sku in @openai_long_context_skus,
       do: 272_000

  defp context_threshold(%{provider: "x-ai", sku: sku})
       when sku in ~w(grok-4.6 x-ai/grok-4.6), do: 200_000

  defp context_threshold(_), do: nil

  defp matches?(price, account_id, provider, sku, resource_kind, component, meter_unit, at) do
    account_matches? = Map.get(price, :billing_account_id) in [nil, account_id]

    resource_matches? =
      is_nil(resource_kind) or Map.get(price, :resource_kind) in [nil, resource_kind]

    component_matches? = is_nil(component) or Map.get(price, :component) in [nil, component]
    unit_matches? = is_nil(meter_unit) or Map.get(price, :meter_unit) in [nil, meter_unit]

    account_matches? and resource_matches? and component_matches? and unit_matches? and
      Map.fetch!(price, :provider) == provider and Map.fetch!(price, :sku) == sku and
      Time.before_or_equal?(Map.get(price, :effective_at), at) and
      (is_nil(price[:expires_at]) or DateTime.compare(at, price.expires_at) == :lt)
  end

  defp sort_key(price, account_id) do
    account_rank = if Map.get(price, :billing_account_id) == account_id, do: 1, else: 0
    effective_us = price |> Map.get(:effective_at) |> to_unix()

    {account_rank, effective_us}
  end

  defp normalize(price) do
    price
    |> Map.put_new(:currency, "USD")
    |> Map.put_new(:credits_per_usd, 1_000_000)
    |> Map.put_new(:components, [])
  end

  defp to_unix(nil), do: 0
  defp to_unix(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
end
