defmodule BillingStripe.PriceSync do
  @moduledoc "Synchronizes local package versions to Stripe Products and Prices."

  @spec sync_catalog(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_catalog(catalog, opts \\ []) when is_map(catalog) do
    BillingStripe.Telemetry.observe(:stripe_catalog_sync, "system", fn ->
      do_sync_catalog(catalog, opts)
    end)
  end

  defp do_sync_catalog(catalog, opts) do
    if Keyword.get(opts, :dry_run, false) do
      validate_catalog(catalog, opts)
    else
      sync_catalog_mutating(catalog, opts)
    end
  end

  defp sync_catalog_mutating(catalog, opts) do
    with {:ok, config} <- config(),
         {:ok, local} <- BillingCommerce.sync_local_pricing_catalog(catalog, opts) do
      versions = catalog[:versions] || catalog["versions"] || []

      sync_results =
        Enum.reduce_while(versions, {:ok, []}, fn version, {:ok, acc} ->
          case sync_version(version, config, Keyword.put(opts, :catalog_versions, versions)) do
            {:ok, result} -> {:cont, {:ok, [result | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case sync_results do
        {:ok, provider_prices} ->
          with :ok <- assert_product_groups(provider_prices) do
            {:ok, %{local: local, provider_prices: Enum.reverse(provider_prices)}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_catalog(catalog, opts) do
    with {:ok, config} <- config() do
      versions = catalog[:versions] || catalog["versions"] || []

      verify_local_mapping? = Keyword.get(opts, :verify_local_mapping, false)

      case Enum.reduce_while(versions, {:ok, []}, fn version, {:ok, acc} ->
             lookup_key = required(version, :provider_lookup_key)

             case find_existing_price(lookup_key, config) do
               {:ok, price} ->
                 with :ok <- assert_price_matches(price, version, lookup_key),
                      :ok <-
                        maybe_assert_local_mapping_matches(
                          version,
                          price,
                          lookup_key,
                          opts,
                          verify_local_mapping?
                        ) do
                   {:cont, {:ok, [dry_run_entry(:reuse, version, price) | acc]}}
                 else
                   {:error, reason} -> {:halt, {:error, reason}}
                 end

               {:error, {:provider_price_missing, ^lookup_key}} when not verify_local_mapping? ->
                 {:cont, {:ok, [dry_run_entry(:create, version, nil) | acc]}}

               {:error, reason} ->
                 {:halt, {:error, reason}}
             end
           end) do
        {:ok, plan} ->
          plan = Enum.reverse(plan)

          with :ok <- assert_product_groups(Enum.filter(plan, & &1.provider_price_id)) do
            {:ok,
             %{
               local: :dry_run,
               provider_prices: plan |> Enum.flat_map(&existing_price/1),
               provider_plan: plan,
               provider_sync: :dry_run
             }}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp sync_version(version, config, opts) do
    lookup_key = required(version, :provider_lookup_key)

    with {:ok, price} <- find_or_create_price(version, lookup_key, config, opts),
         :ok <- assert_price_matches(price, version, lookup_key),
         {:ok, mapping} <-
           BillingCommerce.put_provider_price(%{
             repo: opts[:repo],
             package_code: required(version, :package_code),
             package_version: required(version, :version),
             provider: "stripe",
             provider_lookup_key: lookup_key,
             provider_price_id: value(price, :id),
             currency: required(version, :currency),
             amount_minor: required(version, :amount_minor),
             metadata: provider_metadata(version, price, lookup_key)
           }),
         :ok <- assert_mapping_matches(mapping, price, lookup_key) do
      {:ok, mapping}
    end
  end

  defp provider_metadata(version, price, lookup_key) do
    metadata = %{
      "catalog" => "stripe_price_sync",
      "stripe_product_id" => product_id(price),
      "provider_lookup_key" => lookup_key
    }

    if required(version, :surface) == "comma",
      do:
        Map.put(
          metadata,
          "comma_purchasable",
          value(value(price, :metadata) || %{}, :comma_purchasable) == "true"
        ),
      else: metadata
  end

  defp find_or_create_price(version, lookup_key, config, opts) do
    case find_existing_price(lookup_key, config) do
      {:ok, price} ->
        {:ok, price}

      {:error, {:provider_price_missing, ^lookup_key}} ->
        create_price(version, lookup_key, config, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_existing_price(lookup_key, config) do
    case config.api.list_prices(
           %{lookup_keys: [lookup_key], active: true, limit: 1, expand: ["data.product"]},
           stripe_opts(config)
         ) do
      {:ok, prices} ->
        case list_data(prices) do
          [price | _] -> {:ok, price}
          [] -> {:error, {:provider_price_missing, lookup_key}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_price(version, lookup_key, config, opts) do
    siblings =
      Enum.filter(opts[:catalog_versions] || [version], fn other ->
        required(other, :package_code) == required(version, :package_code)
      end)

    keys = Enum.map(siblings, &required(&1, :provider_lookup_key))

    with {:ok, prices} <-
           config.api.list_prices(
             %{lookup_keys: keys, active: true, limit: 100, expand: ["data.product"]},
             stripe_opts(config)
           ),
         {:ok, product} <- find_or_create_product(list_data(prices), hd(siblings), config) do
      with {:ok, price} <-
             config.api.create_price(
               price_params(version, lookup_key, product),
               stripe_opts(config, "billing:stripe:price:#{lookup_key}")
             ) do
        {:ok, Map.put(price, :product, product)}
      end
    end
  end

  defp find_or_create_product([], version, config) do
    config.api.create_product(
      product_params(version, required(version, :provider_lookup_key)),
      stripe_opts(
        config,
        "billing:stripe:product:#{required(version, :surface)}:#{required(version, :package_code)}"
      )
    )
  end

  defp find_or_create_product(prices, version, _config) do
    products = Enum.map(prices, &value(&1, :product))
    ids = Enum.uniq(Enum.map(products, &value(&1, :id)))

    if length(ids) == 1 and
         Enum.all?(products, fn product ->
           metadata = value(product, :metadata) || %{}

           value(product, :name) == product_name(version) and
             value(metadata, :package_code) == required(version, :package_code) and
             value(metadata, :surface) == required(version, :surface)
         end) do
      {:ok, hd(products)}
    else
      {:error, {:provider_product_drift, required(version, :package_code)}}
    end
  end

  defp product_params(version, lookup_key) do
    %{
      name: product_name(version),
      description: get_in(required(version, :usage_policy), ["description"]),
      metadata: %{
        package_code: required(version, :package_code),
        package_version: required(version, :version),
        provider_lookup_key: lookup_key,
        surface: required(version, :surface)
      }
    }
    |> reject_blank()
  end

  defp price_params(version, lookup_key, product) do
    %{
      product: value(product, :id),
      currency: required(version, :currency),
      unit_amount: required(version, :amount_minor),
      lookup_key: lookup_key,
      nickname: product_name(version),
      metadata: %{
        package_code: required(version, :package_code),
        package_version: required(version, :version),
        provider_lookup_key: lookup_key,
        grant_credits: to_string(required(version, :grant_credits))
      }
    }
    |> maybe_put_recurring(version)
  end

  defp maybe_put_recurring(params, %{kind: "subscription", billing_period: interval}) do
    Map.put(params, :recurring, %{interval: interval})
  end

  defp maybe_put_recurring(params, %{"kind" => "subscription", "billing_period" => interval}) do
    Map.put(params, :recurring, %{interval: interval})
  end

  defp maybe_put_recurring(params, _version), do: params

  defp assert_price_matches(price, version, lookup_key) do
    expected_type = if required(version, :kind) == "one_time", do: "one_time", else: "recurring"
    expected_interval = if expected_type == "recurring", do: required(version, :billing_period)

    cond do
      value(price, :lookup_key) != lookup_key ->
        {:error, {:provider_price_drift, lookup_key, :lookup_key}}

      value(price, :currency) != required(version, :currency) ->
        {:error, {:provider_price_drift, lookup_key, :currency}}

      value(price, :unit_amount) != required(version, :amount_minor) ->
        {:error, {:provider_price_drift, lookup_key, :amount}}

      value(price, :type) != expected_type ->
        {:error, {:provider_price_drift, lookup_key, :type}}

      expected_interval && recurring_interval(price) != expected_interval ->
        {:error, {:provider_price_drift, lookup_key, :interval}}

      not is_map(value(price, :product)) or
          (value(value(price, :product), :name) != product_name(version) or
             value(value(value(price, :product), :metadata), :package_code) !=
               required(version, :package_code) or
             value(value(value(price, :product), :metadata), :surface) !=
               required(version, :surface)) ->
        {:error, {:provider_product_drift, required(version, :package_code)}}

      true ->
        :ok
    end
  end

  defp assert_product_groups(mappings) do
    mappings
    |> Enum.group_by(& &1.package_code)
    |> Enum.reduce_while(:ok, fn {code, entries}, :ok ->
      if entries |> Enum.map(& &1.metadata["stripe_product_id"]) |> Enum.uniq() |> length() == 1,
        do: {:cont, :ok},
        else: {:halt, {:error, {:provider_product_drift, code}}}
    end)
  end

  defp assert_mapping_matches(mapping, price, lookup_key) do
    if mapping.provider_price_id == value(price, :id) do
      :ok
    else
      {:error, {:provider_price_mapping_conflict, lookup_key}}
    end
  end

  defp assert_local_mapping_matches(version, price, lookup_key, opts) do
    provider_price_id = value(price, :id)

    case BillingCommerce.get_provider_plan(%{
           repo: opts[:repo],
           surface: required(version, :surface),
           provider: "stripe",
           provider_lookup_key: lookup_key
         }) do
      {:ok, plan} ->
        if plan.provider_price_id == provider_price_id and
             (required(version, :surface) != "comma" or
                plan.provider_metadata["comma_purchasable"] ==
                  (value(value(price, :metadata) || %{}, :comma_purchasable) == "true")) do
          :ok
        else
          {:error, {:provider_price_mapping_conflict, lookup_key}}
        end

      {:error, :not_found} ->
        {:error, {:provider_price_mapping_missing, lookup_key}}
    end
  end

  defp maybe_assert_local_mapping_matches(version, price, lookup_key, opts, true),
    do: assert_local_mapping_matches(version, price, lookup_key, opts)

  defp maybe_assert_local_mapping_matches(_version, _price, _lookup_key, _opts, false), do: :ok

  defp dry_run_entry(action, version, price) do
    %{
      action: action,
      amount_minor: required(version, :amount_minor),
      currency: required(version, :currency),
      provider_lookup_key: required(version, :provider_lookup_key),
      package_code: required(version, :package_code),
      metadata: %{"stripe_product_id" => price && product_id(price)},
      provider_price_id: price && value(price, :id)
    }
  end

  defp existing_price(%{provider_price_id: nil}), do: []

  defp existing_price(%{provider_price_id: _id, provider_lookup_key: _lookup_key} = entry),
    do: [entry]

  defp recurring_interval(price) do
    case value(price, :recurring) do
      nil -> nil
      recurring -> value(recurring, :interval)
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

  defp stripe_opts(config), do: [api_key: config.secret_key]

  defp stripe_opts(config, idempotency_key),
    do: Keyword.put(stripe_opts(config), :idempotency_key, idempotency_key)

  defp list_data(prices), do: value(prices, :data) || []

  defp product_id(price) do
    case value(price, :product) do
      product when is_map(product) -> value(product, :id)
      id -> id
    end
  end

  defp product_name(version) do
    version[:name] || version["name"] ||
      String.replace(required(version, :package_code), "_", " ")
  end

  defp reject_blank(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] || raise ArgumentError, "missing price sync field #{key}"
  end
end
