defmodule BillingCore.Accounts do
  @moduledoc "Billing account provisioning helpers."

  def ensure_account(attrs) when is_map(attrs) do
    repo = attrs[:repo] || Application.get_env(:billing_core, :repo, BillingCore.Repo)
    sql = attrs[:sql_runner] || Ecto.Adapters.SQL

    if repo_started?(repo) or attrs[:repo] do
      ensure_account(repo, sql, attrs)
    else
      :ok
    end
  end

  @doc "Verify that an existing Billing account still belongs to the expected product owner."
  def verify_account(attrs) when is_map(attrs) do
    repo = attrs[:repo] || Application.get_env(:billing_core, :repo, BillingCore.Repo)
    sql = attrs[:sql_runner] || Ecto.Adapters.SQL

    if repo_started?(repo) or attrs[:repo] do
      verify_account(repo, sql, attrs)
    else
      {:error, :billing_repo_not_started}
    end
  end

  defp ensure_account(repo, sql, attrs) do
    account_id = attrs[:billing_account_id] || attrs["billing_account_id"]

    if present?(account_id) do
      surface = attrs[:surface] || attrs["surface"] || "unknown"
      required_surface = attrs[:required_surface] || attrs["required_surface"]

      product_owner_type =
        attrs[:product_owner_type] || attrs["product_owner_type"] || "unknown"

      product_owner_id = attrs[:product_owner_id] || attrs["product_owner_id"] || "unknown"
      enforce_owner_identity? = enforce_product_owner_identity?(attrs)

      with :ok <-
             validate_existing_account(
               repo,
               sql,
               account_id,
               required_surface || surface,
               product_owner_type,
               product_owner_id,
               enforce_owner_identity?
             ) do
        result =
          sql.query!(
            repo,
            account_upsert_sql(enforce_owner_identity?),
            [
              account_id,
              surface,
              product_owner_type,
              product_owner_id
            ]
          )

        if result.num_rows == 0 do
          account_conflict(repo, sql, attrs, enforce_owner_identity?)
        else
          ensure_balance(repo, sql, account_id)
        end
      end
    else
      {:error, :missing_billing_account_id}
    end
  end

  defp account_upsert_sql(true) do
    """
    INSERT INTO billing_accounts (
      id, surface, product_owner_type, product_owner_id, status, inserted_at, updated_at
    ) VALUES ($1, $2, $3, $4, 'active', now(), now())
    ON CONFLICT (id) DO UPDATE
    SET updated_at = now()
    WHERE billing_accounts.surface = EXCLUDED.surface
      AND billing_accounts.product_owner_type = EXCLUDED.product_owner_type
      AND billing_accounts.product_owner_id = EXCLUDED.product_owner_id
    RETURNING id
    """
  end

  defp account_upsert_sql(false) do
    """
    INSERT INTO billing_accounts (
      id, surface, product_owner_type, product_owner_id, status, inserted_at, updated_at
    ) VALUES ($1, $2, $3, $4, 'active', now(), now())
    ON CONFLICT (id) DO UPDATE
    SET product_owner_type = EXCLUDED.product_owner_type,
        product_owner_id = EXCLUDED.product_owner_id,
        updated_at = now()
    WHERE billing_accounts.surface = EXCLUDED.surface
    RETURNING id
    """
  end

  defp validate_existing_account(
         repo,
         sql,
         account_id,
         surface,
         product_owner_type,
         product_owner_id,
         true
       ) do
    validate_existing_identity(
      repo,
      sql,
      account_id,
      surface,
      product_owner_type,
      product_owner_id
    )
  end

  defp validate_existing_account(repo, sql, account_id, surface, _owner_type, _owner_id, false) do
    validate_existing_surface(repo, sql, account_id, surface)
  end

  defp account_conflict(repo, sql, attrs, true), do: verify_account(repo, sql, attrs)

  defp account_conflict(_repo, _sql, _attrs, false),
    do: {:error, :billing_account_surface_mismatch}

  defp validate_existing_surface(repo, sql, account_id, surface) do
    result =
      sql.query!(
        repo,
        """
        SELECT surface
        FROM billing_accounts
        WHERE id = $1
        """,
        [account_id]
      )

    case result.rows do
      [] -> :ok
      [[^surface]] -> :ok
      [[_other]] -> {:error, :billing_account_surface_mismatch}
    end
  end

  defp ensure_balance(repo, sql, account_id) do
    # Projection/cache row only; active credit_grants remain the balance truth.
    sql.query!(
      repo,
      """
      INSERT INTO credit_balances (billing_account_id, balance_credits, updated_at)
      VALUES ($1, 0, now())
      ON CONFLICT (billing_account_id) DO NOTHING
      """,
      [account_id]
    )

    :ok
  end

  defp validate_existing_identity(
         repo,
         sql,
         account_id,
         surface,
         product_owner_type,
         product_owner_id
       ) do
    result =
      sql.query!(
        repo,
        """
        SELECT surface, product_owner_type, product_owner_id
        FROM billing_accounts
        WHERE id = $1
        """,
        [account_id]
      )

    case result.rows do
      [] ->
        :ok

      [[^surface, ^product_owner_type, ^product_owner_id]] ->
        :ok

      [[other_surface, _other_type, _other_id]] when other_surface != surface ->
        {:error, :billing_account_surface_mismatch}

      [[_surface, _other_type, _other_id]] ->
        {:error, :billing_account_owner_mismatch}
    end
  end

  defp verify_account(repo, sql, attrs) do
    account_id = attrs[:billing_account_id] || attrs["billing_account_id"]

    surface =
      attrs[:required_surface] || attrs["required_surface"] || attrs[:surface] ||
        attrs["surface"] || "unknown"

    product_owner_type = attrs[:product_owner_type] || attrs["product_owner_type"] || "unknown"
    product_owner_id = attrs[:product_owner_id] || attrs["product_owner_id"] || "unknown"

    if present?(account_id) and present?(surface) and present?(product_owner_type) and
         present?(product_owner_id) do
      result =
        sql.query!(
          repo,
          """
          SELECT surface, product_owner_type, product_owner_id, status
          FROM billing_accounts
          WHERE id = $1
          """,
          [account_id]
        )

      case result.rows do
        [[^surface, ^product_owner_type, ^product_owner_id, "active"]] ->
          :ok

        [] ->
          {:error, :billing_account_not_found}

        [[other_surface, _other_type, _other_id, _status]] when other_surface != surface ->
          {:error, :billing_account_surface_mismatch}

        [[^surface, ^product_owner_type, ^product_owner_id, _status]] ->
          {:error, :billing_account_inactive}

        [[_surface, _other_type, _other_id, _status]] ->
          {:error, :billing_account_owner_mismatch}
      end
    else
      {:error, :missing_billing_account_identity}
    end
  end

  defp repo_started?(repo) when is_atom(repo), do: Process.whereis(repo) != nil
  defp repo_started?(_repo), do: false

  defp enforce_product_owner_identity?(attrs),
    do:
      attrs[:enforce_product_owner_identity] == true or
        attrs["enforce_product_owner_identity"] == true

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
