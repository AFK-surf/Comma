defmodule BillingCommerce.ManualGrants do
  @moduledoc "Operator-safe manual source commands that issue BillingCore grants."

  alias BillingCommerce.{ManualGrantCommands, PackageCatalog}
  alias BillingCommerce.Projection
  alias BillingCore.Accounts
  alias BillingCore.Entitlements.Policy

  @manual_source_types ~w(manual_contract manual_adjustment license_period default_entitlement)

  @spec issue_bridge_org_grant(map()) :: {:ok, map()} | {:error, term()}
  def issue_bridge_org_grant(attrs) when is_map(attrs) do
    org_id = required(attrs, :organization_id)

    attrs
    |> Map.merge(%{
      surface: "bridge",
      product_owner_type: "organization",
      product_owner_id: org_id,
      source_type: attrs[:source_type] || attrs["source_type"] || "manual_contract"
    })
    |> issue_manual_grant()
  end

  @spec issue_comma_support_grant(map()) :: {:ok, map()} | {:error, term()}
  def issue_comma_support_grant(attrs) when is_map(attrs) do
    workspace_id = required(attrs, :workspace_id)

    attrs
    |> Map.merge(%{
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: workspace_id,
      source_type: attrs[:source_type] || attrs["source_type"] || "manual_contract"
    })
    |> issue_manual_grant()
  end

  @doc """
  Issues or recovers the human Admin direct-grant command.

  This narrow entry point owns the cross-database recovery contract for Comma
  Admin. It reconciles an existing grant before consulting mutable account,
  package, or period state. Other manual-grant callers retain their legacy
  semantics.
  """
  @spec issue_comma_admin_support_grant(map()) :: {:ok, map()} | {:error, term()}
  def issue_comma_admin_support_grant(attrs) when is_map(attrs) do
    with {:ok, identity} <- admin_grant_identity(attrs) do
      case existing_admin_manual_source(attrs, identity) do
        {:ok, source} ->
          duplicate_admin_result(source, identity)

        :not_found ->
          with :ok <- verify_admin_expiry(identity),
               :ok <- verify_admin_account(attrs, identity),
               {:ok, result} <- issue_comma_support_grant(attrs) do
            if result.idempotent do
              duplicate_admin_result(result.manual_grant, identity)
            else
              {:ok, result}
            end
          end
      end
    end
  end

  @spec issue_manual_grant(map()) :: {:ok, map()} | {:error, term()}
  def issue_manual_grant(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    account_id = required(attrs, :billing_account_id)
    source_type = required(attrs, :source_type)
    _idempotency_key = required(attrs, :idempotency_key)

    with :ok <- validate_source_type(source_type),
         {:ok, operator} <- operator_snapshot(attrs[:operator] || attrs["operator"]),
         {:ok, period} <- explicit_period(attrs),
         {:ok, package_version} <-
           PackageCatalog.get_package_version(package_lookup(attrs, repo, sql)),
         :ok <- validate_package_surface(package_version, required(attrs, :surface)),
         :ok <- ensure_account(repo, sql, account_id, attrs),
         :ok <- PackageCatalog.ensure_issuable(package_version, period.valid_from),
         {:ok, policy} <- Policy.normalize(package_version.usage_policy) do
      case repo.transaction(fn ->
             case insert_manual_source(repo, sql, attrs, package_version, operator, period) do
               {:inserted, manual_source} ->
                 grant =
                   issue_core_grant!(
                     repo,
                     account_id,
                     attrs,
                     package_version,
                     policy,
                     period
                   )

                 manual_source =
                   mark_issued!(repo, sql, manual_source, grant.id || grant[:id])

                 wake_payload = %{
                   billing_account_id: account_id,
                   credit_grant_id: grant.id || grant[:id],
                   source_type: source_type
                 }

                 {
                   %{manual_grant: manual_source, grant: grant, idempotent: false},
                   wake_payload
                 }

               {:duplicate, manual_source} ->
                 {%{manual_grant: manual_source, grant: nil, idempotent: true}, nil}
             end
           end) do
        {:ok, {result, nil}} ->
          project_manual_grant(result, attrs)
          {:ok, result}

        {:ok, {result, wake_payload}} ->
          best_effort_wake(wake_payload)
          project_manual_grant(result, attrs)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp insert_manual_source(repo, sql, attrs, package_version, operator, period) do
    account_id = required(attrs, :billing_account_id)
    idempotency_key = required(attrs, :idempotency_key)
    source_type = required(attrs, :source_type)
    source_id = required(attrs, :source_id)
    source_event_id = required(attrs, :source_event_id)

    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_manual_grants (
          id, billing_account_id, package_code, package_version,
          source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, period_start, period_end, credit_grant_id,
          status, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4,
          $5, $6, $7, $8,
          $9, $10, $11, NULL,
          'pending', now(), now()
        )
        ON CONFLICT (billing_account_id, idempotency_key) DO NOTHING
        RETURNING id, billing_account_id, package_code, package_version,
          source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, period_start, period_end, credit_grant_id, status
        """,
        [
          attrs[:id] || id("manual_grant"),
          account_id,
          package_version.package_code,
          package_version.version,
          source_type,
          source_id,
          source_event_id,
          idempotency_key,
          Jason.encode!(operator),
          period.valid_from,
          period.expires_at
        ]
      )

    case result.rows do
      [row | _] -> {:inserted, row_to_manual_grant(row)}
      [] -> {:duplicate, get_manual_source!(repo, sql, account_id, idempotency_key)}
    end
  end

  defp issue_core_grant!(repo, account_id, attrs, package_version, policy, period) do
    source_type = required(attrs, :source_type)
    source_id = required(attrs, :source_id)
    source_event_id = required(attrs, :source_event_id)
    idempotency_key = required(attrs, :idempotency_key)

    {:ok, grant} =
      BillingCore.Credits.issue_grant(%{
        repo: repo,
        billing_account_id: account_id,
        credits: package_version.grant_credits,
        valid_from: period.valid_from,
        expires_at: period.expires_at,
        source_type: source_type,
        source_id: source_id,
        source_event_id: source_event_id,
        idempotency_key: idempotency_key,
        package_code: package_version.package_code,
        package_version: package_version.version,
        package_snapshot: PackageCatalog.package_snapshot(package_version),
        policy_snapshot: policy,
        metadata: attrs[:metadata] || attrs["metadata"] || %{}
      })

    grant
  end

  defp mark_issued!(repo, sql, manual_source, grant_id) do
    result =
      sql.query!(
        repo,
        """
        UPDATE billing_manual_grants
        SET credit_grant_id = $2,
            status = 'issued',
            updated_at = now()
        WHERE id = $1
        RETURNING id, billing_account_id, package_code, package_version,
          source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, period_start, period_end, credit_grant_id, status
        """,
        [manual_source.id, grant_id]
      )

    result.rows |> hd() |> row_to_manual_grant()
  end

  defp project_manual_grant(%{manual_grant: source, grant: grant}, attrs)
       when not is_nil(grant) do
    Projection.emit(%{
      source_key: "manual_grant:#{source.id}:#{source.status}",
      occurred_at: DateTime.utc_now(),
      surface: required(attrs, :surface),
      billing_account_id: source.billing_account_id,
      product_owner_type: required(attrs, :product_owner_type),
      product_owner_id: required(attrs, :product_owner_id),
      event_kind: "grant_issued",
      source_type: source.source_type,
      source_id: source.source_id,
      source_event_id: source.source_event_id,
      idempotency_key: source.idempotency_key,
      package_code: source.package_code,
      package_version: source.package_version,
      credit_grant_id: source.credit_grant_id,
      status: source.status,
      metadata: %{"manual_grant_id" => source.id}
    })
  end

  defp project_manual_grant(_result, _attrs), do: :ok

  defp get_manual_source!(repo, sql, account_id, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, package_code, package_version,
          source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, period_start, period_end, credit_grant_id, status
        FROM billing_manual_grants
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [account_id, idempotency_key]
      )

    result.rows |> hd() |> row_to_manual_grant()
  end

  defp existing_admin_manual_source(attrs, identity) do
    result =
      sql(attrs).query!(
        repo(attrs),
        """
        SELECT id, billing_account_id, package_code, package_version,
          source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, period_start, period_end, credit_grant_id, status
        FROM billing_manual_grants
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [identity.billing_account_id, identity.idempotency_key]
      )

    case result.rows do
      [] -> :not_found
      [row] -> {:ok, row_to_manual_grant(row)}
    end
  end

  defp admin_grant_identity(%{
         billing_account_id: billing_account_id,
         workspace_id: workspace_id,
         package_code: package_code,
         package_version: package_version,
         source_type: "manual_adjustment",
         source_id: source_id,
         source_event_id: source_event_id,
         idempotency_key: idempotency_key,
         operator: %{
           "id" => operator_id,
           "type" => "comma_admin_user",
           "reason" => reason
         },
         expires_at: %DateTime{} = expires_at,
         enforce_product_owner_identity: true
       })
       when is_binary(billing_account_id) and billing_account_id != "" and
              is_binary(workspace_id) and workspace_id != "" and
              is_binary(package_code) and package_code != "" and
              is_binary(package_version) and package_version != "" and
              is_binary(source_event_id) and source_event_id != "" and
              is_binary(operator_id) and operator_id != "" and is_binary(reason) do
    expected_source_id = "comma_admin:#{workspace_id}"
    expected_idempotency_key = ManualGrantCommands.billing_idempotency_key(source_event_id)

    if source_id == expected_source_id and idempotency_key == expected_idempotency_key do
      {:ok,
       %{
         billing_account_id: billing_account_id,
         workspace_id: workspace_id,
         package_code: package_code,
         package_version: package_version,
         source_type: "manual_adjustment",
         source_id: expected_source_id,
         source_event_id: source_event_id,
         idempotency_key: expected_idempotency_key,
         operator_snapshot: %{
           "id" => operator_id,
           "type" => "comma_admin_user",
           "reason" => reason
         },
         expires_at: expires_at
       }}
    else
      {:error, :invalid_manual_grant}
    end
  end

  defp admin_grant_identity(_attrs), do: {:error, :invalid_manual_grant}

  defp verify_admin_account(attrs, identity) do
    Accounts.verify_account(%{
      repo: repo(attrs),
      sql_runner: sql(attrs),
      billing_account_id: identity.billing_account_id,
      required_surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: identity.workspace_id
    })
  end

  defp verify_admin_expiry(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :invalid_manual_grant}
  end

  defp duplicate_admin_result(source, identity) do
    if matching_admin_manual_source?(source, identity) do
      {:ok, %{manual_grant: source, grant: nil, idempotent: true}}
    else
      {:error, :admin_idempotency_key_conflict}
    end
  end

  defp matching_admin_manual_source?(source, identity) do
    source.billing_account_id == identity.billing_account_id and
      source.package_code == identity.package_code and
      source.package_version == identity.package_version and
      source.source_type == identity.source_type and
      source.source_id == identity.source_id and
      source.source_event_id == identity.source_event_id and
      source.idempotency_key == identity.idempotency_key and
      source.operator_snapshot == identity.operator_snapshot and
      same_datetime?(source.expires_at, identity.expires_at) and
      is_binary(source.credit_grant_id) and source.credit_grant_id != "" and
      source.status == "issued"
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp package_lookup(attrs, repo, sql) do
    %{
      repo: repo,
      sql_runner: sql,
      package_code: required(attrs, :package_code),
      version: required(attrs, :package_version)
    }
  end

  defp explicit_period(attrs) do
    valid_from = attrs[:valid_from] || attrs["valid_from"]
    expires_at = attrs[:expires_at] || attrs["expires_at"]

    cond do
      match?(%DateTime{}, valid_from) and match?(%DateTime{}, expires_at) and
          DateTime.compare(valid_from, expires_at) == :lt ->
        {:ok, %{valid_from: valid_from, expires_at: expires_at}}

      true ->
        {:error, :explicit_valid_from_and_expires_at_required}
    end
  end

  defp operator_snapshot(%{} = operator) do
    operator_id = operator[:id] || operator["id"]

    if is_binary(operator_id) and String.trim(operator_id) != "" do
      {:ok,
       %{
         "id" => operator_id,
         "type" => operator[:type] || operator["type"] || "operator",
         "reason" => operator[:reason] || operator["reason"]
       }}
    else
      {:error, :operator_id_required}
    end
  end

  defp operator_snapshot(_operator), do: {:error, :operator_id_required}

  defp validate_source_type(source_type) when source_type in @manual_source_types, do: :ok
  defp validate_source_type(_source_type), do: {:error, :invalid_manual_source_type}

  defp validate_package_surface(%{surface: surface}, surface), do: :ok

  defp validate_package_surface(_package_version, _surface),
    do: {:error, :package_surface_mismatch}

  defp ensure_account(repo, sql, account_id, attrs) do
    BillingCore.Accounts.ensure_account(%{
      repo: repo,
      sql_runner: sql,
      billing_account_id: account_id,
      surface: required(attrs, :surface),
      required_surface: required(attrs, :surface),
      product_owner_type: required(attrs, :product_owner_type),
      product_owner_id: required(attrs, :product_owner_id),
      enforce_product_owner_identity:
        attrs[:enforce_product_owner_identity] ||
          attrs["enforce_product_owner_identity"] ||
          false
    })
  end

  defp row_to_manual_grant([
         id,
         billing_account_id,
         package_code,
         package_version,
         source_type,
         source_id,
         source_event_id,
         idempotency_key,
         operator_snapshot,
         period_start,
         period_end,
         credit_grant_id,
         status
       ]) do
    %{
      id: id,
      billing_account_id: billing_account_id,
      package_code: package_code,
      package_version: package_version,
      source_type: source_type,
      source_id: source_id,
      source_event_id: source_event_id,
      idempotency_key: idempotency_key,
      operator_snapshot: decode_json(operator_snapshot),
      valid_from: period_start,
      expires_at: period_end,
      credit_grant_id: credit_grant_id,
      status: status
    }
  end

  defp best_effort_wake(payload) do
    case Application.get_env(
           :billing_commerce,
           :vm_resume_waker,
           BillingCommerce.VMWake.SalixCloudVM
         ) do
      nil ->
        :ok

      {mod, fun} ->
        safe_apply(mod, fun, [payload])

      mod when is_atom(mod) ->
        safe_apply(mod, :billing_grant_issued, [payload])
    end
  end

  defp safe_apply(mod, fun, args) do
    try do
      apply(mod, fun, args)
      :ok
    catch
      _, _ -> :ok
    end
  end

  defp repo(attrs),
    do: attrs[:repo] || attrs["repo"] || Application.fetch_env!(:billing_commerce, :repo)

  defp sql(attrs), do: attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] ||
      raise ArgumentError, "missing manual grant field #{key}"
  end

  defp id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
