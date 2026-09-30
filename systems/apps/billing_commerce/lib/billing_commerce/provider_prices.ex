defmodule BillingCommerce.ProviderPrices do
  @moduledoc "Provider price mappings and purchasable plan queries."

  @spec put_provider_price(map()) :: {:ok, map()} | {:error, term()}
  def put_provider_price(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    provider_lookup_key = attrs[:provider_lookup_key] || attrs["provider_lookup_key"]
    metadata = attrs[:metadata] || attrs["metadata"] || %{}

    desired = %{
      package_code: required(attrs, :package_code),
      package_version: required(attrs, :package_version),
      provider: required(attrs, :provider),
      provider_lookup_key: provider_lookup_key,
      provider_price_id: required(attrs, :provider_price_id),
      currency: attrs[:currency] || attrs["currency"],
      amount_minor: attrs[:amount_minor] || attrs["amount_minor"]
    }

    case get_existing_provider_price(
           repo,
           sql,
           desired.provider,
           desired.provider_price_id,
           provider_lookup_key
         ) do
      {:ok, price} ->
        with :ok <- validate_existing_provider_price(price, desired) do
          {:ok, price}
        end

      {:error, :not_found} ->
        insert_provider_price(repo, sql, attrs, desired, metadata)
    end
  end

  @spec list_provider_plans(map()) :: {:ok, [map()]} | {:error, term()}
  def list_provider_plans(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    surface = attrs[:surface] || attrs["surface"]
    provider = required(attrs, :provider)
    synced_only? = attrs[:synced_only] || attrs["synced_only"] || false

    result =
      sql.query!(
        repo,
        """
        SELECT
          v.id, v.package_code, v.version, v.surface, v.kind, v.billing_period,
          v.grant_credits, v.grant_period, v.currency, v.amount_minor, v.usage_policy,
          v.effective_at, v.expires_at, v.status,
          p.name, p.metadata,
          pp.provider, pp.provider_lookup_key, pp.provider_price_id, pp.metadata
        FROM billing_package_versions v
        JOIN billing_packages p ON p.code = v.package_code
        LEFT JOIN billing_provider_prices pp
          ON pp.package_code = v.package_code
         AND pp.package_version = v.version
         AND pp.provider = $1
        WHERE v.surface = $2
          AND v.status = 'active'
          AND p.status = 'active'
          AND ($3 = false OR pp.provider_price_id IS NOT NULL)
        ORDER BY v.kind DESC, v.amount_minor ASC, v.package_code ASC
        """,
        [provider, surface, synced_only?]
      )

    {:ok, Enum.map(result.rows, &row_to_plan/1)}
  end

  @spec get_provider_plan(map()) :: {:ok, map()} | {:error, :not_found}
  def get_provider_plan(attrs) when is_map(attrs) do
    provider_price_id = attrs[:provider_price_id] || attrs["provider_price_id"]
    provider_lookup_key = attrs[:provider_lookup_key] || attrs["provider_lookup_key"]
    package_code = attrs[:package_code] || attrs["package_code"]
    package_version = attrs[:package_version] || attrs["package_version"]

    with {:ok, plans} <- list_provider_plans(attrs) do
      plan =
        Enum.find(plans, fn plan ->
          cond do
            is_binary(provider_lookup_key) ->
              plan.provider_lookup_key == provider_lookup_key

            is_binary(provider_price_id) ->
              plan.provider_price_id == provider_price_id

            is_binary(package_code) and is_binary(package_version) ->
              plan.package_code == package_code and plan.package_version == package_version

            true ->
              false
          end
        end)

      if plan, do: {:ok, plan}, else: {:error, :not_found}
    end
  end

  defp insert_provider_price(repo, sql, attrs, desired, metadata) do
    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_provider_prices (
          id, package_code, package_version, provider, provider_lookup_key, provider_price_id,
          currency, amount_minor, metadata, inserted_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
        ON CONFLICT (provider, provider_price_id) DO NOTHING
        RETURNING id, package_code, package_version, provider, provider_lookup_key, provider_price_id,
          currency, amount_minor, metadata
        """,
        [
          attrs[:id] || id("price"),
          desired.package_code,
          desired.package_version,
          desired.provider,
          desired.provider_lookup_key,
          desired.provider_price_id,
          desired.currency,
          desired.amount_minor,
          Jason.encode!(metadata)
        ]
      )

    case result.rows do
      [row | _] ->
        {:ok, row_to_price(row) |> Map.put(:idempotent, false)}

      [] ->
        with {:ok, price} <-
               get_provider_price(repo, sql, desired.provider, desired.provider_price_id),
             :ok <- validate_existing_provider_price(price, desired) do
          {:ok, price}
        end
    end
  end

  defp get_provider_price(repo, sql, provider, provider_price_id) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, package_code, package_version, provider, provider_lookup_key, provider_price_id,
          currency, amount_minor, metadata
        FROM billing_provider_prices
        WHERE provider = $1 AND provider_price_id = $2
        LIMIT 1
        """,
        [provider, provider_price_id]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_price(row) |> Map.put(:idempotent, true)}
      [] -> {:error, :not_found}
    end
  end

  defp get_existing_provider_price(repo, sql, provider, provider_price_id, provider_lookup_key) do
    case get_provider_price(repo, sql, provider, provider_price_id) do
      {:ok, price} ->
        {:ok, price}

      {:error, :not_found} when is_binary(provider_lookup_key) ->
        get_provider_price_by_lookup_key(repo, sql, provider, provider_lookup_key)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp get_provider_price_by_lookup_key(repo, sql, provider, provider_lookup_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, package_code, package_version, provider, provider_lookup_key, provider_price_id,
          currency, amount_minor, metadata
        FROM billing_provider_prices
        WHERE provider = $1 AND provider_lookup_key = $2
        LIMIT 1
        """,
        [provider, provider_lookup_key]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_price(row) |> Map.put(:idempotent, true)}
      [] -> {:error, :not_found}
    end
  end

  defp validate_existing_provider_price(existing, desired) do
    cond do
      existing.package_code != desired.package_code ->
        {:error, {:provider_price_mapping_conflict, :package_code}}

      existing.package_version != desired.package_version ->
        {:error, {:provider_price_mapping_conflict, :package_version}}

      existing.provider != desired.provider ->
        {:error, {:provider_price_mapping_conflict, :provider}}

      different_nonblank?(existing.provider_lookup_key, desired.provider_lookup_key) ->
        {:error, {:provider_price_mapping_conflict, :provider_lookup_key}}

      existing.provider_price_id != desired.provider_price_id ->
        {:error, {:provider_price_mapping_conflict, :provider_price_id}}

      different_nonblank?(existing.currency, desired.currency) ->
        {:error, {:provider_price_mapping_conflict, :currency}}

      different_nonblank?(existing.amount_minor, desired.amount_minor) ->
        {:error, {:provider_price_mapping_conflict, :amount_minor}}

      true ->
        :ok
    end
  end

  defp different_nonblank?(nil, _right), do: false
  defp different_nonblank?(_left, nil), do: false
  defp different_nonblank?("", _right), do: false
  defp different_nonblank?(_left, ""), do: false
  defp different_nonblank?(left, right), do: left != right

  defp row_to_price([
         id,
         package_code,
         package_version,
         provider,
         provider_lookup_key,
         provider_price_id,
         currency,
         amount_minor,
         metadata
       ]) do
    %{
      id: id,
      package_code: package_code,
      package_version: package_version,
      provider: provider,
      provider_lookup_key: provider_lookup_key,
      provider_price_id: provider_price_id,
      currency: currency,
      amount_minor: amount_minor,
      metadata: decode_json(metadata)
    }
  end

  defp row_to_plan([
         id,
         package_code,
         version,
         surface,
         kind,
         billing_period,
         grant_credits,
         grant_period,
         currency,
         amount_minor,
         usage_policy,
         effective_at,
         expires_at,
         status,
         name,
         package_metadata,
         provider,
         provider_lookup_key,
         provider_price_id,
         provider_metadata
       ]) do
    %{
      id: id,
      package_code: package_code,
      package_version: version,
      version: version,
      surface: surface,
      kind: kind,
      mode: if(kind == "one_time", do: "payment", else: "subscription"),
      billing_period: billing_period,
      grant_credits: grant_credits,
      grant_period: grant_period,
      currency: currency,
      amount_minor: amount_minor,
      usage_policy: decode_json(usage_policy),
      effective_at: effective_at,
      expires_at: expires_at,
      status: status,
      name: name,
      metadata: decode_json(package_metadata),
      provider: provider,
      provider_lookup_key:
        provider_lookup_key || get_in(decode_json(usage_policy), ["stripe_lookup_key"]),
      provider_price_id: provider_price_id,
      provider_metadata: decode_json(provider_metadata || %{})
    }
  end

  defp repo(attrs),
    do: attrs[:repo] || attrs["repo"] || Application.fetch_env!(:billing_commerce, :repo)

  defp sql(attrs), do: attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] ||
      raise ArgumentError, "missing provider price field #{key}"
  end

  defp id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
