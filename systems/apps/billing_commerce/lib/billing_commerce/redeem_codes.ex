defmodule BillingCommerce.RedeemCodes do
  @moduledoc "Package-backed redeem code admin and apply commands."

  alias BillingCommerce.PackageCatalog
  alias BillingCommerce.Projection
  alias BillingCommerce.RedeemCodeCommands
  alias BillingCommerce.RedeemCodeCommands.{Apply, Create, Disable}
  alias BillingCommerce.Subscriptions

  @spec create_code(map() | Create.t()) ::
          {:ok, map()} | {:already_applied, map()} | {:error, term()}
  def create_code(%Create{} = command) do
    repo = repo(command)
    sql = sql(command)

    case find_admin_command_code(repo, sql, command.admin_command_id) do
      {:ok, existing} ->
        {:already_applied, existing}

      :not_found ->
        create_new_code(repo, sql, command)
    end
  end

  def create_code(attrs) when is_map(attrs) do
    with {:ok, command} <- RedeemCodeCommands.legacy_create(attrs) do
      create_code(command)
    end
  end

  @spec disable_code(map() | Disable.t()) :: {:ok, map()} | {:error, term()}
  def disable_code(%Disable{} = command) do
    repo = repo(command)
    sql = sql(command)

    result =
      sql.query!(
        repo,
        """
        UPDATE billing_redeem_codes
        SET status = 'disabled',
            updated_at = now()
        WHERE id = $1
        RETURNING id, code_hash, display_prefix, package_code, package_version,
          code_type, surface, scope_product_owner_type, scope_product_owner_id,
          status, max_redemptions, per_account_limit, valid_from, expires_at, metadata
        """,
        [command.id]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_code(row)}
      [] -> {:error, :not_found}
    end
  end

  def disable_code(attrs) when is_map(attrs) do
    with {:ok, command} <- RedeemCodeCommands.legacy_disable(attrs) do
      disable_code(command)
    end
  end

  defp create_new_code(repo, sql, %Create{} = command) do
    with {:ok, package_version} <-
           PackageCatalog.get_package_version(%{
             repo: repo,
             sql_runner: sql,
             package_code: command.package_code,
             version: command.package_version
           }),
         :ok <- validate_package_surface(package_version, command.surface),
         {:ok, code_type} <- resolve_package_code_type(package_version, command.code_type),
         {:ok, valid_from} <- resolve_command_datetime(command.valid_from),
         :ok <- validate_create_window(valid_from, command.expires_at),
         code <- materialize_code(command.code) do
      result =
        sql.query!(
          repo,
          """
          INSERT INTO billing_redeem_codes (
            id, code_hash, display_prefix, package_code, package_version,
            code_type, surface, scope_product_owner_type, scope_product_owner_id,
            status, max_redemptions, per_account_limit, valid_from, expires_at,
            metadata, admin_command_id, inserted_at, updated_at
          ) VALUES (
            $1, $2, $3, $4, $5,
            $6, $7, $8, $9,
            $10, $11, $12, $13, $14,
            $15, $16, now(), now()
          )
          ON CONFLICT DO NOTHING
          RETURNING id, code_hash, display_prefix, package_code, package_version,
            code_type, surface, scope_product_owner_type, scope_product_owner_id,
            status, max_redemptions, per_account_limit, valid_from, expires_at, metadata
          """,
          [
            command.id || id("redeem_code"),
            hash_code(code),
            display_prefix(code),
            package_version.package_code,
            package_version.version,
            code_type,
            command.surface,
            command.scope_product_owner_type,
            command.scope_product_owner_id,
            command.status,
            command.max_redemptions,
            command.per_account_limit,
            valid_from,
            command.expires_at,
            command.metadata_json,
            command.admin_command_id
          ]
        )

      case result.rows do
        [row | _] ->
          {:ok, row_to_code(row) |> Map.put(:code, code)}

        [] ->
          case find_admin_command_code(repo, sql, command.admin_command_id) do
            {:ok, existing} -> {:already_applied, existing}
            :not_found -> {:error, :redeem_code_exists}
          end
      end
    end
  end

  @spec list_codes(map()) :: {:ok, map()} | {:error, term()}
  def list_codes(attrs \\ %{}) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    limit = clamp_limit(attrs[:limit] || attrs["limit"] || 100)

    result =
      sql.query!(
        repo,
        """
        SELECT id, code_hash, display_prefix, package_code, package_version,
          code_type, surface, scope_product_owner_type, scope_product_owner_id,
          status, max_redemptions, per_account_limit, valid_from, expires_at, metadata
        FROM billing_redeem_codes
        ORDER BY inserted_at DESC, id
        LIMIT $1
        """,
        [limit]
      )

    {:ok, %{data: Enum.map(result.rows, &row_to_code/1)}}
  end

  @spec list_redemptions(map()) :: {:ok, map()} | {:error, term()}
  def list_redemptions(attrs \\ %{}) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    limit = clamp_limit(attrs[:limit] || attrs["limit"] || 100)
    code_id = attrs[:redeem_code_id] || attrs["redeem_code_id"]

    with {:ok, code_id} <- required_redeem_code_id(code_id) do
      result =
        sql.query!(
          repo,
          """
          SELECT id, redeem_code_id, billing_account_id, surface, product_owner_type,
            product_owner_id, source_type, source_id, source_event_id, idempotency_key,
            operator_snapshot, status, metadata
          FROM billing_redemptions
          WHERE redeem_code_id = $1
          ORDER BY inserted_at DESC, id
          LIMIT $2
          """,
          [code_id, limit]
        )

      {:ok, %{data: Enum.map(result.rows, &row_to_redemption/1)}}
    end
  end

  @spec apply_code(map() | Apply.t()) :: {:ok, map()} | {:error, term()}
  def apply_code(%Apply{} = command) do
    repo = repo(command)
    sql = sql(command)

    case repo.transaction(fn ->
           with {:ok, code} <- lock_code(repo, sql, command),
                idempotency_key <- redemption_idempotency_key(code, command),
                {:new_redemption, ^idempotency_key} <-
                  existing_redemption(repo, sql, code, command, idempotency_key),
                {:ok, at} <- resolve_command_datetime(command.at),
                :ok <- validate_apply(code, command, at),
                :ok <-
                  validate_redemption_limits(
                    code,
                    command.billing_account_id,
                    repo,
                    sql
                  ),
                :ok <- ensure_account(repo, sql, command),
                {:inserted, redemption} <-
                  insert_redemption(repo, sql, code, command, idempotency_key) do
             apply_redemption(repo, sql, code, redemption, at)
           else
             {:duplicate, redemption} ->
               duplicate_redemption_result(redemption)

             {:error, reason} ->
               repo.rollback(reason)
           end
         end) do
      {:ok, result} ->
        project_redemption(result)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_code(attrs) when is_map(attrs) do
    with {:ok, command} <- RedeemCodeCommands.legacy_apply(attrs) do
      apply_code(command)
    end
  end

  defp apply_redemption(
         repo,
         sql,
         %{code_type: "one_time_package"} = code,
         redemption,
         at
       ) do
    period = current_period(at)

    case Subscriptions.issue_one_time_purchase(%{
           repo: repo,
           sql_runner: sql,
           billing_account_id: redemption.billing_account_id,
           surface: redemption.surface,
           product_owner_type: redemption.product_owner_type,
           product_owner_id: redemption.product_owner_id,
           package_code: code.package_code,
           package_version: code.package_version,
           source_type: "redeem_one_time",
           source_id: redemption.id,
           source_event_id: redemption.source_event_id,
           idempotency_key: redemption.idempotency_key,
           source_metadata: %{"redeem_code_id" => code.id, "redemption_id" => redemption.id},
           valid_from: period.valid_from,
           expires_at: period.expires_at
         }) do
      {:ok, %{purchase: purchase, grant: grant} = purchase_result} ->
        redemption = mark_redemption_applied!(repo, sql, redemption, purchase.id)

        Map.merge(purchase_result, %{
          redemption: redemption,
          subscription: nil,
          cycles: [],
          idempotent: false,
          grant: grant
        })

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp apply_redemption(
         repo,
         sql,
         %{code_type: "internal_subscription"} = code,
         redemption,
         at
       ) do
    period = current_period(at)

    case Subscriptions.create_subscription(%{
           repo: repo,
           sql_runner: sql,
           billing_account_id: redemption.billing_account_id,
           surface: redemption.surface,
           product_owner_type: redemption.product_owner_type,
           product_owner_id: redemption.product_owner_id,
           package_code: code.package_code,
           package_version: code.package_version,
           source_type: "internal_subscription",
           source_id: redemption.id,
           source_event_id: redemption.source_event_id,
           idempotency_key: redemption.idempotency_key,
           source_metadata: %{"redeem_code_id" => code.id, "redemption_id" => redemption.id},
           periods: [
             %{
               cycle_key: cycle_key(period.valid_from),
               valid_from: period.valid_from,
               expires_at: period.expires_at,
               source_event_id: redemption.source_event_id,
               grant_source_type: "redeem_subscription_cycle"
             }
           ]
         }) do
      {:ok, %{subscription: subscription, cycles: cycles}} ->
        redemption = mark_redemption_applied!(repo, sql, redemption, subscription.id)

        %{
          redemption: redemption,
          subscription: subscription,
          cycles: cycles,
          grant: nil,
          idempotent: false
        }

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp lock_code(repo, sql, %Apply{} = command) do
    {where, value} =
      case command.selector do
        {:id, id} -> {"id", id}
        {:code, code} -> {"code_hash", hash_code(code)}
      end

    result =
      sql.query!(
        repo,
        """
        SELECT id, code_hash, display_prefix, package_code, package_version,
          code_type, surface, scope_product_owner_type, scope_product_owner_id,
          status, max_redemptions, per_account_limit, valid_from, expires_at, metadata
        FROM billing_redeem_codes
        WHERE #{where} = $1
        FOR UPDATE
        """,
        [value]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_code(row)}
      [] -> {:error, :redeem_code_not_found}
    end
  end

  defp validate_apply(code, %Apply{} = command, at) do
    with :ok <- validate_status(code),
         :ok <- validate_expiry(code, at),
         :ok <- validate_scope(code, command) do
      :ok
    end
  end

  defp ensure_account(repo, sql, %Apply{} = command) do
    BillingCore.Accounts.ensure_account(%{
      repo: repo,
      sql_runner: sql,
      billing_account_id: command.billing_account_id,
      surface: command.surface,
      required_surface: command.surface,
      product_owner_type: command.product_owner_type,
      product_owner_id: command.product_owner_id
    })
  end

  defp validate_package_surface(%{surface: surface}, surface), do: :ok

  defp validate_package_surface(_package_version, _surface),
    do: {:error, :package_surface_mismatch}

  defp resolve_package_code_type(package_version, requested) do
    expected =
      case package_version.kind do
        "one_time" -> "one_time_package"
        "subscription" -> "internal_subscription"
        _other -> nil
      end

    cond do
      is_nil(expected) ->
        {:error, :invalid_redeem_code_type}

      requested == :derive ->
        {:ok, expected}

      requested == expected ->
        {:ok, expected}

      true ->
        {:error, :invalid_redeem_code_type}
    end
  end

  defp resolve_command_datetime(:now), do: {:ok, DateTime.utc_now()}
  defp resolve_command_datetime(%DateTime{} = value), do: {:ok, value}
  defp resolve_command_datetime(_value), do: {:error, :invalid_redeem_request}

  defp validate_create_window(_valid_from, nil), do: :ok

  defp validate_create_window(%DateTime{} = valid_from, %DateTime{} = expires_at) do
    if DateTime.compare(expires_at, valid_from) == :gt,
      do: :ok,
      else: {:error, :invalid_redeem_code}
  end

  defp materialize_code(:generate), do: random_code()
  defp materialize_code({:provided, code}), do: code

  defp validate_status(%{status: "active"}), do: :ok
  defp validate_status(_code), do: {:error, :redeem_code_disabled}

  defp validate_expiry(code, at) do
    cond do
      DateTime.compare(code.valid_from, at) == :gt ->
        {:error, :redeem_code_not_yet_active}

      match?(%DateTime{}, code.expires_at) and DateTime.compare(code.expires_at, at) != :gt ->
        {:error, :redeem_code_expired}

      true ->
        :ok
    end
  end

  defp validate_scope(code, %Apply{} = command) do
    cond do
      code.surface != command.surface ->
        {:error, :redeem_scope_mismatch}

      is_binary(code.scope_product_owner_type) and
          code.scope_product_owner_type != command.product_owner_type ->
        {:error, :redeem_scope_mismatch}

      is_binary(code.scope_product_owner_id) and
          code.scope_product_owner_id != command.product_owner_id ->
        {:error, :redeem_scope_mismatch}

      true ->
        :ok
    end
  end

  defp validate_redemption_limits(code, account_id, repo, sql) do
    %{rows: [[total, account_total]]} =
      sql.query!(
        repo,
        """
        SELECT
          count(*),
          count(*) FILTER (WHERE billing_account_id = $2)
        FROM billing_redemptions
        WHERE redeem_code_id = $1
          AND status = 'applied'
        """,
        [code.id, account_id]
      )

    cond do
      account_total >= code.per_account_limit ->
        {:error, :redeem_code_account_limit_reached}

      is_integer(code.max_redemptions) and total >= code.max_redemptions ->
        {:error, :redeem_code_max_redemptions_reached}

      true ->
        :ok
    end
  end

  defp existing_redemption(repo, sql, code, %Apply{} = command, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, redeem_code_id, billing_account_id, surface, product_owner_type,
          product_owner_id, source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, status, metadata
        FROM billing_redemptions
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [command.billing_account_id, idempotency_key]
      )

    case result.rows do
      [] ->
        {:new_redemption, idempotency_key}

      [row | _] ->
        redemption = row_to_redemption(row)

        if matching_redemption?(redemption, code, command, idempotency_key) do
          {:duplicate, redemption}
        else
          {:error, :redeem_idempotency_key_conflict}
        end
    end
  end

  defp insert_redemption(repo, sql, code, %Apply{} = command, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_redemptions (
          id, redeem_code_id, billing_account_id, surface, product_owner_type,
          product_owner_id, source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, status, metadata, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5,
          $6, $7, NULL, $8, $9,
          $10, 'pending', $11, now(), now()
        )
        ON CONFLICT (billing_account_id, idempotency_key) DO NOTHING
        RETURNING id, redeem_code_id, billing_account_id, surface, product_owner_type,
          product_owner_id, source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, status, metadata
        """,
        [
          command.redemption_id || id("redemption"),
          code.id,
          command.billing_account_id,
          command.surface,
          command.product_owner_type,
          command.product_owner_id,
          redemption_source_type(code),
          redemption_source_event_id(command, idempotency_key),
          idempotency_key,
          command.operator_json,
          command.metadata_json
        ]
      )

    case result.rows do
      [row | _] -> {:inserted, row_to_redemption(row)}
      [] -> existing_redemption(repo, sql, code, command, idempotency_key)
    end
  end

  defp mark_redemption_applied!(repo, sql, redemption, source_id) do
    result =
      sql.query!(
        repo,
        """
        UPDATE billing_redemptions
        SET source_id = $2,
            status = 'applied',
            updated_at = now()
        WHERE id = $1
        RETURNING id, redeem_code_id, billing_account_id, surface, product_owner_type,
          product_owner_id, source_type, source_id, source_event_id, idempotency_key,
          operator_snapshot, status, metadata
        """,
        [redemption.id, source_id]
      )

    result.rows |> hd() |> row_to_redemption()
  end

  defp project_redemption(%{redemption: redemption, idempotent: false} = result) do
    Projection.emit(%{
      source_key: "redemption:#{redemption.id}:#{redemption.status}",
      occurred_at: DateTime.utc_now(),
      surface: redemption.surface,
      billing_account_id: redemption.billing_account_id,
      product_owner_type: redemption.product_owner_type,
      product_owner_id: redemption.product_owner_id,
      event_kind: "redeem_applied",
      source_type: redemption.source_type,
      source_id: redemption.source_id || redemption.id,
      source_event_id: redemption.source_event_id,
      idempotency_key: redemption.idempotency_key,
      package_code: package_code(result),
      package_version: package_version(result),
      credit_grant_id: get_in(result, [:grant, :id]),
      status: redemption.status,
      metadata: %{"redeem_code_id" => redemption.redeem_code_id}
    })
  end

  defp project_redemption(_result), do: :ok

  defp package_code(%{grant: %{package_code: package_code}}), do: package_code
  defp package_code(%{subscription: %{package_code: package_code}}), do: package_code
  defp package_code(_result), do: nil

  defp package_version(%{grant: %{package_version: package_version}}), do: package_version
  defp package_version(%{subscription: %{package_version: package_version}}), do: package_version
  defp package_version(_result), do: nil

  defp redemption_idempotency_key(code, %Apply{} = command),
    do:
      command.idempotency_key ||
        "redeem:#{code.id}:#{command.billing_account_id}"

  defp redemption_source_event_id(%Apply{} = command, idempotency_key),
    do: command.source_event_id || idempotency_key

  defp matching_redemption?(redemption, code, %Apply{} = command, idempotency_key) do
    redemption.redeem_code_id == code.id and
      redemption.billing_account_id == command.billing_account_id and
      redemption.surface == command.surface and
      redemption.product_owner_type == command.product_owner_type and
      redemption.product_owner_id == command.product_owner_id and
      redemption.source_type == redemption_source_type(code) and
      redemption.source_event_id == redemption_source_event_id(command, idempotency_key)
  end

  defp duplicate_redemption_result(redemption) do
    %{
      redemption: redemption,
      grant: nil,
      subscription: nil,
      cycles: [],
      idempotent: true
    }
  end

  defp redemption_source_type(%{code_type: "one_time_package"}), do: "redeem_one_time"
  defp redemption_source_type(%{code_type: "internal_subscription"}), do: "redeem_subscription"

  defp current_period(%DateTime{} = at) do
    date = DateTime.to_date(at)
    start_date = Date.new!(date.year, date.month, 1)
    end_date = add_month(start_date)

    %{
      valid_from: DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
      expires_at: DateTime.new!(end_date, ~T[00:00:00], "Etc/UTC")
    }
  end

  defp add_month(%Date{year: year, month: 12}), do: Date.new!(year + 1, 1, 1)
  defp add_month(%Date{year: year, month: month}), do: Date.new!(year, month + 1, 1)

  defp cycle_key(%DateTime{} = at) do
    date = DateTime.to_date(at)
    "#{date.year}-#{String.pad_leading(Integer.to_string(date.month), 2, "0")}"
  end

  defp required_redeem_code_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_redeem_code_id}
      code_id -> {:ok, code_id}
    end
  end

  defp required_redeem_code_id(_value), do: {:error, :invalid_redeem_code_id}

  defp find_admin_command_code(_repo, _sql, nil), do: :not_found

  defp find_admin_command_code(repo, sql, admin_command_id) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, code_hash, display_prefix, package_code, package_version,
          code_type, surface, scope_product_owner_type, scope_product_owner_id,
          status, max_redemptions, per_account_limit, valid_from, expires_at, metadata
        FROM billing_redeem_codes
        WHERE admin_command_id = $1
        LIMIT 1
        """,
        [admin_command_id]
      )

    case result.rows do
      [row | _] -> {:ok, row_to_code(row)}
      [] -> :not_found
    end
  end

  defp normalize_code(code) when is_binary(code), do: code |> String.trim() |> String.upcase()

  defp hash_code(code),
    do: :crypto.hash(:sha256, normalize_code(code)) |> Base.encode16(case: :lower)

  defp display_prefix(code),
    do: normalize_code(code) |> String.slice(0, 8)

  defp random_code,
    do: "COMMA-" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))

  defp row_to_code([
         id,
         code_hash,
         display_prefix,
         package_code,
         package_version,
         code_type,
         surface,
         scope_product_owner_type,
         scope_product_owner_id,
         status,
         max_redemptions,
         per_account_limit,
         valid_from,
         expires_at,
         metadata
       ]) do
    %{
      id: id,
      code_hash: code_hash,
      display_prefix: display_prefix,
      package_code: package_code,
      package_version: package_version,
      code_type: code_type,
      surface: surface,
      scope_product_owner_type: scope_product_owner_type,
      scope_product_owner_id: scope_product_owner_id,
      status: status,
      max_redemptions: max_redemptions,
      per_account_limit: per_account_limit,
      valid_from: valid_from,
      expires_at: expires_at,
      metadata: decode_json(metadata)
    }
  end

  defp row_to_redemption([
         id,
         redeem_code_id,
         billing_account_id,
         surface,
         product_owner_type,
         product_owner_id,
         source_type,
         source_id,
         source_event_id,
         idempotency_key,
         operator_snapshot,
         status,
         metadata
       ]) do
    %{
      id: id,
      redeem_code_id: redeem_code_id,
      billing_account_id: billing_account_id,
      surface: surface,
      product_owner_type: product_owner_type,
      product_owner_id: product_owner_id,
      source_type: source_type,
      source_id: source_id,
      source_event_id: source_event_id,
      idempotency_key: idempotency_key,
      operator_snapshot: decode_json(operator_snapshot),
      status: status,
      metadata: decode_json(metadata)
    }
  end

  defp repo(%{repo: repo}) when not is_nil(repo), do: repo

  defp repo(attrs) when is_map(attrs),
    do: Map.get(attrs, "repo") || Application.fetch_env!(:billing_commerce, :repo)

  defp sql(%{sql_runner: sql}) when not is_nil(sql), do: sql

  defp sql(attrs) when is_map(attrs),
    do: Map.get(attrs, "sql_runner") || Ecto.Adapters.SQL

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp clamp_limit(_limit), do: 100

  defp id(prefix),
    do: "#{prefix}_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value), do: value
end
