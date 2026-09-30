defmodule BillingCommerce.ProviderCustomers do
  @moduledoc "Provider customer identity mappings for billing accounts."

  @spec get_active_customer(map()) :: {:ok, map()} | {:error, :not_found}
  def get_active_customer(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    account_id = required(attrs, :billing_account_id)
    provider = required(attrs, :provider)
    provider_context = provider_context(attrs)

    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, surface, product_owner_type, product_owner_id,
          provider, provider_context, provider_customer_id, status,
          billing_email_snapshot, display_name_snapshot, created_by_actor_type,
          created_by_actor_id, source_type, source_event_id, metadata,
          inserted_at, updated_at
        FROM billing_provider_customers
        WHERE billing_account_id = $1
          AND provider = $2
          AND provider_context = $3
          AND status = 'active'
        LIMIT 1
        """,
        [account_id, provider, provider_context]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_customer(row)}
      [] -> {:error, :not_found}
    end
  end

  @spec bind_customer(map()) :: {:ok, map()} | {:error, term()}
  def bind_customer(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    provider_context = provider_context(attrs)
    account_id = required(attrs, :billing_account_id)
    provider = required(attrs, :provider)
    provider_customer_id = required(attrs, :provider_customer_id)
    metadata = attrs[:metadata] || attrs["metadata"] || %{}

    case repo.transaction(fn ->
           ensure_account!(repo, sql, account_id, attrs)

           bind_customer!(
             sql,
             repo,
             attrs,
             provider_context,
             provider,
             provider_customer_id,
             metadata
           )
         end) do
      {:ok, customer} -> {:ok, customer}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec upsert_from_provider_event(map()) :: {:ok, map()} | {:error, term()}
  def upsert_from_provider_event(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:source_type, "provider_event")
    |> bind_customer()
  end

  defp bind_customer!(
         sql,
         repo,
         attrs,
         provider_context,
         provider,
         provider_customer_id,
         metadata
       ) do
    account_id = required(attrs, :billing_account_id)
    surface = required(attrs, :surface)
    owner_type = required(attrs, :product_owner_type)
    owner_id = required(attrs, :product_owner_id)

    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_provider_customers (
          id, billing_account_id, surface, product_owner_type, product_owner_id,
          provider, provider_context, provider_customer_id, status,
          billing_email_snapshot, display_name_snapshot, created_by_actor_type,
          created_by_actor_id, source_type, source_event_id, metadata,
          inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5,
          $6, $7, $8, 'active',
          $9, $10, $11,
          $12, $13, $14, $15,
          now(), now()
        )
        ON CONFLICT (provider, provider_context, provider_customer_id) DO UPDATE
        SET billing_account_id = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN EXCLUDED.billing_account_id
              ELSE billing_provider_customers.billing_account_id
            END,
            surface = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN EXCLUDED.surface
              ELSE billing_provider_customers.surface
            END,
            product_owner_type = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN EXCLUDED.product_owner_type
              ELSE billing_provider_customers.product_owner_type
            END,
            product_owner_id = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN EXCLUDED.product_owner_id
              ELSE billing_provider_customers.product_owner_id
            END,
            status = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN 'active'
              ELSE billing_provider_customers.status
            END,
            billing_email_snapshot = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN COALESCE(EXCLUDED.billing_email_snapshot, billing_provider_customers.billing_email_snapshot)
              ELSE billing_provider_customers.billing_email_snapshot
            END,
            display_name_snapshot = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN COALESCE(EXCLUDED.display_name_snapshot, billing_provider_customers.display_name_snapshot)
              ELSE billing_provider_customers.display_name_snapshot
            END,
            created_by_actor_type = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN COALESCE(EXCLUDED.created_by_actor_type, billing_provider_customers.created_by_actor_type)
              ELSE billing_provider_customers.created_by_actor_type
            END,
            created_by_actor_id = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN COALESCE(EXCLUDED.created_by_actor_id, billing_provider_customers.created_by_actor_id)
              ELSE billing_provider_customers.created_by_actor_id
            END,
            source_type = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN EXCLUDED.source_type
              ELSE billing_provider_customers.source_type
            END,
            source_event_id = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN COALESCE(EXCLUDED.source_event_id, billing_provider_customers.source_event_id)
              ELSE billing_provider_customers.source_event_id
            END,
            metadata = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN EXCLUDED.metadata
              ELSE billing_provider_customers.metadata
            END,
            updated_at = CASE
              WHEN billing_provider_customers.billing_account_id = EXCLUDED.billing_account_id
              THEN now()
              ELSE billing_provider_customers.updated_at
            END
        RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
          provider, provider_context, provider_customer_id, status,
          billing_email_snapshot, display_name_snapshot, created_by_actor_type,
          created_by_actor_id, source_type, source_event_id, metadata,
          inserted_at, updated_at
        """,
        [
          attrs[:id] || attrs["id"] || id("pcus"),
          account_id,
          surface,
          owner_type,
          owner_id,
          provider,
          provider_context,
          provider_customer_id,
          attrs[:billing_email] || attrs["billing_email"],
          attrs[:display_name] || attrs["display_name"],
          attrs[:created_by_actor_type] || attrs["created_by_actor_type"],
          attrs[:created_by_actor_id] || attrs["created_by_actor_id"],
          attrs[:source_type] || attrs["source_type"] || "operator",
          attrs[:source_event_id] || attrs["source_event_id"],
          metadata
        ]
      )

    customer = result.rows |> hd() |> row_to_customer()

    if customer.billing_account_id == account_id do
      customer
    else
      repo.rollback(:provider_customer_already_bound)
    end
  end

  defp ensure_account!(repo, sql, account_id, attrs) do
    BillingCore.Accounts.ensure_account(%{
      repo: repo,
      sql_runner: sql,
      billing_account_id: account_id,
      surface: required(attrs, :surface),
      product_owner_type: required(attrs, :product_owner_type),
      product_owner_id: required(attrs, :product_owner_id)
    })
  end

  defp row_to_customer([
         id,
         billing_account_id,
         surface,
         product_owner_type,
         product_owner_id,
         provider,
         provider_context,
         provider_customer_id,
         status,
         billing_email_snapshot,
         display_name_snapshot,
         created_by_actor_type,
         created_by_actor_id,
         source_type,
         source_event_id,
         metadata,
         inserted_at,
         updated_at
       ]) do
    %{
      id: id,
      billing_account_id: billing_account_id,
      surface: surface,
      product_owner_type: product_owner_type,
      product_owner_id: product_owner_id,
      provider: provider,
      provider_context: provider_context,
      provider_customer_id: provider_customer_id,
      status: status,
      billing_email_snapshot: billing_email_snapshot,
      display_name_snapshot: display_name_snapshot,
      created_by_actor_type: created_by_actor_type,
      created_by_actor_id: created_by_actor_id,
      source_type: source_type,
      source_event_id: source_event_id,
      metadata: decode_json(metadata),
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  defp provider_context(attrs) do
    attrs[:provider_context] || attrs["provider_context"] || "default"
  end

  defp repo(attrs),
    do: attrs[:repo] || attrs["repo"] || Application.fetch_env!(:billing_commerce, :repo)

  defp sql(attrs), do: attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL

  defp required(attrs, key) do
    value = attrs[key] || attrs[to_string(key)]

    if is_nil(value) or value == "" do
      raise ArgumentError, "missing provider customer field #{key}"
    else
      value
    end
  end

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value || %{}

  defp id(prefix) do
    prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
