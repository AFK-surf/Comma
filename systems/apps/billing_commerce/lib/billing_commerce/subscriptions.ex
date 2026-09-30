defmodule BillingCommerce.Subscriptions do
  @moduledoc """
  Subscription cycles and one-time purchase source commands.

  Payment, cycle issuance, replay, and refund safety are modeled in
  `tla/billing/StripeCredits.tla`.
  """

  alias BillingCommerce.PackageCatalog
  alias BillingCommerce.Projection
  alias BillingCore.Entitlements.Policy

  @subscription_sources ~w(stripe_subscription internal_subscription license_subscription manual_subscription)
  @purchase_sources ~w(stripe_checkout top_up internal_top_up redeem_one_time)

  @spec create_subscription(map()) :: {:ok, map()} | {:error, term()}
  def create_subscription(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    account_id = required(attrs, :billing_account_id)
    source_type = required(attrs, :source_type)
    periods = required(attrs, :periods)

    with :ok <- validate_source(source_type, @subscription_sources),
         :ok <- validate_periods(periods),
         {:ok, package_version} <-
           PackageCatalog.get_package_version(package_lookup(attrs, repo, sql)),
         :ok <- validate_package_surface(package_version, required(attrs, :surface)),
         :ok <- ensure_account(repo, sql, account_id, attrs),
         :ok <- PackageCatalog.ensure_issuable(package_version, first_period_start(periods)) do
      case repo.transaction(fn ->
             Ecto.Adapters.SQL.query!(
               repo,
               "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
               [account_id]
             )

             if source_type == "stripe_subscription" do
               Ecto.Adapters.SQL.query!(
                 repo,
                 "UPDATE billing_accounts SET subscription_checkout = NULL WHERE id = $1 AND subscription_checkout->>'key' = $2",
                 [
                   account_id,
                   attrs[:subscription_checkout_key] || attrs["subscription_checkout_key"]
                 ]
               )
             end

             case insert_subscription(repo, sql, attrs, package_version) do
               {:inserted, subscription} ->
                 cycles = insert_cycles(repo, sql, subscription, package_version, periods)
                 %{subscription: subscription, cycles: cycles, idempotent: false}

               {:duplicate, subscription} ->
                 subscription =
                   update_subscription_package!(
                     repo,
                     sql,
                     subscription,
                     package_version,
                     attrs
                   )

                 cycles = insert_cycles(repo, sql, subscription, package_version, periods)

                 %{
                   subscription: subscription,
                   cycles: cycles,
                   idempotent: true
                 }
             end
           end) do
        {:ok, result} ->
          project_subscription(result)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec run_due_cycles(map()) :: {:ok, map()} | {:error, term()}
  def run_due_cycles(attrs \\ %{}) when is_map(attrs) do
    started = System.monotonic_time()
    repo = repo(attrs)
    sql = sql(attrs)
    at = attrs[:at] || attrs["at"] || DateTime.utc_now()
    limit = clamp_limit(attrs[:limit] || attrs["limit"] || 50)
    cycle_ids = attrs[:cycle_ids] || attrs["cycle_ids"]

    cycles =
      if is_list(cycle_ids) and cycle_ids != [] do
        due_cycles_by_id(repo, sql, at, cycle_ids, limit)
      else
        due_cycles(repo, sql, at, limit)
      end

    issued =
      Enum.map(cycles, fn cycle ->
        case issue_cycle(repo, sql, cycle) do
          {:ok, result} ->
            project_cycle(result)
            result

          {:error, reason} ->
            result = mark_cycle_failed(repo, sql, cycle, inspect(reason))
            project_cycle(result)
            result
        end
      end)

    BillingTelemetry.emit_operation(
      :cycle,
      "system",
      if(Enum.any?(issued, &(Map.get(&1, :last_error) || Map.get(&1, "last_error"))),
        do: "error",
        else: "ok"
      ),
      System.monotonic_time() - started
    )

    {:ok, %{processed: length(issued), cycles: issued}}
  end

  @spec issue_one_time_purchase(map()) :: {:ok, map()} | {:error, term()}
  def issue_one_time_purchase(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    account_id = required(attrs, :billing_account_id)
    source_type = required(attrs, :source_type)

    with :ok <- validate_source(source_type, @purchase_sources),
         {:ok, period} <- explicit_period(attrs),
         {:ok, package_version} <-
           PackageCatalog.get_package_version(package_lookup(attrs, repo, sql)),
         :ok <- validate_package_surface(package_version, required(attrs, :surface)),
         :ok <- ensure_account(repo, sql, account_id, attrs),
         :ok <- PackageCatalog.ensure_issuable(package_version, period.valid_from),
         {:ok, policy} <- Policy.normalize(package_version.usage_policy) do
      case repo.transaction(fn ->
             case insert_purchase(repo, sql, attrs, package_version, period) do
               {:inserted, purchase} ->
                 grant =
                   issue_core_grant!(
                     repo,
                     account_id,
                     source_type,
                     purchase.id,
                     purchase.source_event_id,
                     purchase.idempotency_key,
                     package_version,
                     policy,
                     period,
                     attrs[:metadata] || attrs["metadata"] || %{}
                   )

                 purchase = mark_purchase_issued!(repo, sql, purchase, grant.id || grant[:id])
                 %{purchase: purchase, grant: grant, idempotent: false}

               {:duplicate, purchase} ->
                 %{purchase: purchase, grant: nil, idempotent: true}
             end
           end) do
        {:ok, result} ->
          project_purchase(result)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Read current provider state while holding the subscription row lock.

  The callback performs one bounded provider read. Serializing that read with
  the update prevents delayed or concurrent webhook snapshots from restoring
  an older status or plan. Modeled in `tla/billing/SubscriptionReconcile.tla`.
  """
  @spec reconcile_provider_subscription(binary(), (-> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def reconcile_provider_subscription(source_id, read_current)
      when is_function(read_current, 0) do
    repo = repo(%{})

    repo.transaction(fn ->
      result =
        sql(%{}).query!(
          repo,
          "SELECT billing_account_id, id FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1",
          [source_id]
        )

      case result.rows do
        [] ->
          # An invoice arriving later creates the paid subscription and also
          # reads current provider state; an early cancellation is not lost.
          %{ignored: true, reason: :subscription_not_recorded}

        [[account_id, subscription_id]] ->
          sql(%{}).query!(repo, "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE", [
            account_id
          ])

          sql(%{}).query!(repo, "SELECT id FROM billing_subscriptions WHERE id = $1 FOR UPDATE", [
            subscription_id
          ])

          with {:ok, attrs} <- read_current.(),
               {:ok, subscription} <-
                 set_provider_subscription_status(Map.put(attrs, :source_id, source_id)) do
            subscription
          else
            {:error, reason} -> repo.rollback(reason)
          end
      end
    end)
  end

  @spec set_provider_subscription_status(map()) :: {:ok, map()} | {:error, term()}
  def set_provider_subscription_status(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    source_id = required(attrs, :source_id)
    status = required(attrs, :status)
    package_code = attrs[:package_code] || attrs["package_code"]
    package_version = attrs[:package_version] || attrs["package_version"]

    if (is_nil(package_code) and not is_nil(package_version)) or
         (not is_nil(package_code) and is_nil(package_version)) do
      {:error, :invalid_subscription_package_change}
    else
      repo.transaction(fn ->
        {:ok, result} =
          update_provider_subscription_status(
            repo,
            sql,
            attrs,
            source_id,
            status,
            package_code,
            package_version
          )

        result
      end)
    end
  end

  defp update_provider_subscription_status(
         repo,
         sql,
         attrs,
         source_id,
         status,
         package_code,
         package_version
       ) do
    metadata =
      case sql.query!(
             repo,
             "SELECT source_metadata FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1 FOR UPDATE",
             [source_id]
           ).rows do
        [[existing]] ->
          Map.merge(
            BillingCore.Metadata.object(existing),
            attrs[:source_metadata] || attrs["source_metadata"] || %{}
          )

        [] ->
          %{}
      end

    result =
      sql.query!(
        repo,
        """
        UPDATE billing_subscriptions
        SET status = $2,
            source_event_id = $3,
            source_metadata = $4::jsonb,
            package_code = COALESCE($5, package_code),
            package_version = COALESCE($6, package_version),
            updated_at = now()
        WHERE source_type = 'stripe_subscription' AND source_id = $1
        RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, status
        """,
        [
          source_id,
          status,
          required(attrs, :source_event_id),
          metadata,
          package_code,
          package_version
        ]
      )

    case result.rows do
      [row | _] ->
        subscription = row_to_subscription(row)

        {:ok, subscription}

      [] ->
        {:ok, %{ignored: true, reason: :subscription_not_recorded}}
    end
  end

  defp update_subscription_package!(repo, sql, subscription, package_version, attrs) do
    result =
      sql.query!(
        repo,
        """
        UPDATE billing_subscriptions
        SET package_code = $2,
            package_version = $3,
            source_event_id = $4,
            source_metadata = $5::jsonb,
            status = 'active',
            updated_at = now()
        WHERE id = $1
        RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, status
        """,
        [
          subscription.id,
          package_version.package_code,
          package_version.version,
          required(attrs, :source_event_id),
          Map.merge(
            subscription.source_metadata,
            attrs[:source_metadata] || attrs["source_metadata"] || %{}
          )
        ]
      )

    result.rows |> hd() |> row_to_subscription()
  end

  @spec refund_one_time_purchase(map()) :: {:ok, map()} | {:error, term()}
  def refund_one_time_purchase(attrs) when is_map(attrs) do
    repo = repo(attrs)
    sql = sql(attrs)
    payment_intent_id = required(attrs, :provider_payment_intent_id)
    refunded_amount = required(attrs, :refunded_amount_minor)
    payment_amount = required(attrs, :payment_amount_minor)

    if not is_integer(refunded_amount) or not is_integer(payment_amount) or
         refunded_amount < 0 or payment_amount <= 0 or refunded_amount > payment_amount do
      {:error, :invalid_refund_amount}
    else
      repo.transaction(fn ->
        purchase = lock_purchase_by_payment_intent!(repo, sql, payment_intent_id)
        grant = lock_purchase_grant!(repo, sql, purchase.credit_grant_id)

        target_refunded_credits =
          if refunded_amount == payment_amount, do: grant.original_credits, else: 0

        credits_to_reduce = max(target_refunded_credits - purchase.refunded_credits, 0)

        {:ok, reduction} =
          BillingCore.Credits.reduce_grant(%{
            repo: repo,
            sql_runner: sql,
            billing_account_id: purchase.billing_account_id,
            credit_grant_id: purchase.credit_grant_id,
            credits: credits_to_reduce,
            source_type: attrs[:source_type] || attrs["source_type"] || "stripe_refund",
            source_id: attrs[:source_id] || attrs["source_id"],
            source_event_id: required(attrs, :source_event_id),
            idempotency_key: "stripe:credit_reduction:#{required(attrs, :source_event_id)}",
            reason: attrs[:reason] || attrs["reason"] || "provider_refund"
          })

        status = if refunded_amount == payment_amount, do: "refunded", else: "partially_refunded"

        updated =
          sql.query!(
            repo,
            """
            UPDATE billing_one_time_purchases
            SET refunded_amount_minor = GREATEST(refunded_amount_minor, $2),
                refunded_credits = GREATEST(refunded_credits, $3),
                refunded_at = now(),
                status = $4,
                updated_at = now()
            WHERE id = $1
            RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
              package_code, package_version, source_type, source_id, source_event_id,
              idempotency_key, source_metadata, period_start, period_end,
              provider_payment_intent_id, credit_grant_id, refunded_amount_minor,
              refunded_credits, refunded_at, status
            """,
            [purchase.id, refunded_amount, target_refunded_credits, status]
          )
          |> Map.fetch!(:rows)
          |> hd()
          |> row_to_purchase()

        %{purchase: updated, reduction: reduction, idempotent: reduction.idempotent}
      end)
    end
  end

  defp project_subscription(%{subscription: subscription, cycles: cycles}) do
    Projection.emit(%{
      source_key: "subscription:#{subscription.id}:#{subscription.status}",
      occurred_at: DateTime.utc_now(),
      surface: subscription.surface,
      billing_account_id: subscription.billing_account_id,
      product_owner_type: subscription.product_owner_type,
      product_owner_id: subscription.product_owner_id,
      event_kind: "subscription_upserted",
      source_type: subscription.source_type,
      source_id: subscription.source_id,
      source_event_id: subscription.source_event_id,
      idempotency_key: subscription.idempotency_key,
      package_code: subscription.package_code,
      package_version: subscription.package_version,
      status: subscription.status,
      metadata: %{"cycle_count" => length(cycles || [])}
    })
  end

  defp project_purchase(%{purchase: purchase, grant: grant}) when not is_nil(grant) do
    Projection.emit(%{
      source_key: "purchase:#{purchase.id}:#{purchase.status}",
      occurred_at: DateTime.utc_now(),
      surface: purchase.surface,
      billing_account_id: purchase.billing_account_id,
      product_owner_type: purchase.product_owner_type,
      product_owner_id: purchase.product_owner_id,
      event_kind: "purchase_issued",
      source_type: purchase.source_type,
      source_id: purchase.id,
      source_event_id: purchase.source_event_id,
      idempotency_key: purchase.idempotency_key,
      package_code: purchase.package_code,
      package_version: purchase.package_version,
      credit_grant_id: purchase.credit_grant_id,
      status: purchase.status,
      metadata: %{"external_source_id" => purchase.source_id}
    })
  end

  defp project_purchase(_result), do: :ok

  defp project_cycle(%{cycle: cycle, grant: grant}) do
    Projection.emit(%{
      source_key: "subscription_cycle:#{cycle.id}:#{cycle.status}",
      occurred_at: DateTime.utc_now(),
      surface: "unknown",
      billing_account_id: cycle.billing_account_id,
      product_owner_type: "unknown",
      product_owner_id: "unknown",
      event_kind:
        if(cycle.status == "issued",
          do: "subscription_cycle_issued",
          else: "subscription_cycle_failed"
        ),
      source_type: cycle.grant_source_type || "subscription_cycle",
      source_id: cycle.id,
      source_event_id: cycle.source_event_id,
      idempotency_key: cycle.grant_idempotency_key,
      package_code: cycle.package_code,
      package_version: cycle.package_version,
      credit_grant_id: cycle.credit_grant_id,
      status: cycle.status,
      reason: cycle.last_error,
      metadata: %{"cycle_key" => cycle.cycle_key, "grant_id" => grant && grant[:id]}
    })
  end

  defp issue_cycle(repo, sql, cycle) do
    [[raw]] =
      sql.query!(repo, "SELECT source_metadata FROM billing_subscription_cycles WHERE id = $1", [
        cycle.id
      ]).rows

    metadata = BillingCore.Metadata.object(raw)

    if map_size(metadata["payment_sources"] || %{}) > 0 do
      BillingCommerce.PaidCycles.issue(cycle)
    else
      issue_original_cycle(repo, sql, cycle)
    end
  end

  defp issue_original_cycle(repo, sql, cycle) do
    with {:ok, package_version} <-
           PackageCatalog.get_package_version(%{
             repo: repo,
             sql_runner: sql,
             package_code: cycle.package_code,
             version: cycle.package_version
           }),
         :ok <-
           validate_account_surface(repo, sql, cycle.billing_account_id, package_version.surface),
         :ok <- PackageCatalog.ensure_issuable(package_version, cycle.valid_from),
         {:ok, policy} <- Policy.normalize(package_version.usage_policy) do
      repo.transaction(fn ->
        locked = lock_cycle!(repo, sql, cycle.id)

        if locked.status == "issued" do
          %{cycle: locked, grant: nil, idempotent: true}
        else
          grant =
            issue_core_grant!(
              repo,
              locked.billing_account_id,
              locked.grant_source_type || "subscription_cycle",
              locked.id,
              locked.source_event_id,
              locked.grant_idempotency_key,
              package_version,
              policy,
              %{valid_from: locked.valid_from, expires_at: locked.expires_at},
              %{"cycle_id" => locked.id, "cycle_key" => locked.cycle_key}
            )

          cycle = mark_cycle_issued!(repo, sql, locked, grant.id || grant[:id])
          %{cycle: cycle, grant: grant, idempotent: grant.idempotent}
        end
      end)
    end
  end

  defp insert_subscription(repo, sql, attrs, package_version) do
    account_id = required(attrs, :billing_account_id)
    idempotency_key = required(attrs, :idempotency_key)

    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_subscriptions (
          id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, status, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5,
          $6, $7, $8, $9, $10,
          $11, $12, 'active', now(), now()
        )
        ON CONFLICT (billing_account_id, idempotency_key) DO NOTHING
        RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, status
        """,
        [
          attrs[:id] || id("sub"),
          account_id,
          required(attrs, :surface),
          required(attrs, :product_owner_type),
          required(attrs, :product_owner_id),
          package_version.package_code,
          package_version.version,
          required(attrs, :source_type),
          required(attrs, :source_id),
          required(attrs, :source_event_id),
          idempotency_key,
          attrs[:source_metadata] || attrs["source_metadata"] || %{}
        ]
      )

    case result.rows do
      [row | _] -> {:inserted, row_to_subscription(row)}
      [] -> {:duplicate, get_subscription!(repo, sql, account_id, idempotency_key)}
    end
  end

  defp insert_cycles(repo, sql, subscription, package_version, periods) do
    Enum.map(periods, fn period ->
      cycle_key = period[:cycle_key] || period["cycle_key"]
      source_event_id = period[:source_event_id] || period["source_event_id"] || cycle_key
      grant_idempotency_key = "subscription_cycle:#{subscription.id}:#{cycle_key}"

      result =
        sql.query!(
          repo,
          """
          INSERT INTO billing_subscription_cycles (
            id, subscription_id, billing_account_id, package_code, package_version,
            cycle_key, period_start, period_end, grant_idempotency_key,
            source_event_id, grant_source_type, source_metadata, status, inserted_at, updated_at
          ) VALUES (
            $1, $2, $3, $4, $5,
            $6, $7, $8, $9,
            $10, $11, $12, 'pending', now(), now()
          )
          ON CONFLICT (subscription_id, cycle_key) DO NOTHING
          RETURNING id, subscription_id, billing_account_id, package_code, package_version,
            cycle_key, period_start, period_end, grant_idempotency_key,
            source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
          """,
          [
            period[:id] || period["id"] || id("cycle"),
            subscription.id,
            subscription.billing_account_id,
            package_version.package_code,
            package_version.version,
            cycle_key,
            period[:valid_from] || period["valid_from"],
            period[:expires_at] || period["expires_at"],
            grant_idempotency_key,
            source_event_id,
            period[:grant_source_type] || period["grant_source_type"] || "subscription_cycle",
            period[:source_metadata] || period["source_metadata"] || %{}
          ]
        )

      case result.rows do
        [row | _] -> row_to_cycle(row)
        [] -> get_cycle!(repo, sql, subscription.id, cycle_key)
      end
    end)
  end

  defp insert_purchase(repo, sql, attrs, package_version, period) do
    account_id = required(attrs, :billing_account_id)
    idempotency_key = required(attrs, :idempotency_key)

    result =
      sql.query!(
        repo,
        """
        INSERT INTO billing_one_time_purchases (
          id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, period_start, period_end, provider_payment_intent_id,
          status, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5,
          $6, $7, $8, $9, $10,
          $11, $12, $13, $14, $15,
          'pending', now(), now()
        )
        ON CONFLICT (billing_account_id, idempotency_key) DO NOTHING
        RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, period_start, period_end,
          provider_payment_intent_id, credit_grant_id, refunded_amount_minor,
          refunded_credits, refunded_at, status
        """,
        [
          attrs[:id] || id("purchase"),
          account_id,
          required(attrs, :surface),
          required(attrs, :product_owner_type),
          required(attrs, :product_owner_id),
          package_version.package_code,
          package_version.version,
          required(attrs, :source_type),
          required(attrs, :source_id),
          required(attrs, :source_event_id),
          idempotency_key,
          attrs[:source_metadata] || attrs["source_metadata"] || %{},
          period.valid_from,
          period.expires_at,
          attrs[:provider_payment_intent_id] || attrs["provider_payment_intent_id"]
        ]
      )

    case result.rows do
      [row | _] -> {:inserted, row_to_purchase(row)}
      [] -> {:duplicate, get_purchase!(repo, sql, account_id, idempotency_key)}
    end
  end

  defp issue_core_grant!(
         repo,
         account_id,
         source_type,
         source_id,
         source_event_id,
         idempotency_key,
         package_version,
         policy,
         period,
         metadata
       ) do
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
        metadata: metadata
      })

    grant
  end

  defp due_cycles(repo, sql, at, limit) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
        FROM billing_subscription_cycles
        WHERE status IN ('pending', 'failed')
          AND period_start <= $1
        ORDER BY period_start, id
        LIMIT $2
        """,
        [at, limit]
      )

    Enum.map(result.rows, &row_to_cycle/1)
  end

  defp due_cycles_by_id(repo, sql, at, cycle_ids, limit) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
        FROM billing_subscription_cycles
        WHERE status IN ('pending', 'failed')
          AND period_start <= $1
          AND id = ANY($2::text[])
        ORDER BY period_start, id
        LIMIT $3
        """,
        [at, Enum.uniq(cycle_ids), limit]
      )

    Enum.map(result.rows, &row_to_cycle/1)
  end

  defp lock_cycle!(repo, sql, cycle_id) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
        FROM billing_subscription_cycles
        WHERE id = $1
        FOR UPDATE
        """,
        [cycle_id]
      )

    result.rows |> hd() |> row_to_cycle()
  end

  defp get_subscription!(repo, sql, account_id, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, status
        FROM billing_subscriptions
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [account_id, idempotency_key]
      )

    result.rows |> hd() |> row_to_subscription()
  end

  defp get_cycle!(repo, sql, subscription_id, cycle_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
        FROM billing_subscription_cycles
        WHERE subscription_id = $1 AND cycle_key = $2
        LIMIT 1
        """,
        [subscription_id, cycle_key]
      )

    result.rows |> hd() |> row_to_cycle()
  end

  defp get_purchase!(repo, sql, account_id, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, period_start, period_end,
          provider_payment_intent_id, credit_grant_id, refunded_amount_minor,
          refunded_credits, refunded_at, status
        FROM billing_one_time_purchases
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [account_id, idempotency_key]
      )

    result.rows |> hd() |> row_to_purchase()
  end

  defp mark_cycle_issued!(repo, sql, cycle, grant_id) do
    result =
      sql.query!(
        repo,
        """
        UPDATE billing_subscription_cycles
        SET credit_grant_id = $2,
            status = 'issued',
            last_error = NULL,
            updated_at = now()
        WHERE id = $1
        RETURNING id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
        """,
        [cycle.id, grant_id]
      )

    result.rows |> hd() |> row_to_cycle()
  end

  defp mark_cycle_failed(repo, sql, cycle, reason) do
    result =
      sql.query!(
        repo,
        """
        UPDATE billing_subscription_cycles
        SET status = 'failed',
            attempts = attempts + 1,
            last_error = $2,
            updated_at = now()
        WHERE id = $1
        RETURNING id, subscription_id, billing_account_id, package_code, package_version,
          cycle_key, period_start, period_end, grant_idempotency_key,
          source_event_id, grant_source_type, credit_grant_id, status, attempts, last_error
        """,
        [cycle.id, reason]
      )

    %{cycle: result.rows |> hd() |> row_to_cycle(), grant: nil, error: reason}
  end

  defp mark_purchase_issued!(repo, sql, purchase, grant_id) do
    result =
      sql.query!(
        repo,
        """
        UPDATE billing_one_time_purchases
        SET credit_grant_id = $2,
            status = 'issued',
            updated_at = now()
        WHERE id = $1
        RETURNING id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, period_start, period_end,
          provider_payment_intent_id, credit_grant_id, refunded_amount_minor,
          refunded_credits, refunded_at, status
        """,
        [purchase.id, grant_id]
      )

    result.rows |> hd() |> row_to_purchase()
  end

  defp ensure_account(repo, sql, account_id, attrs) do
    BillingCore.Accounts.ensure_account(%{
      repo: repo,
      sql_runner: sql,
      billing_account_id: account_id,
      surface: required(attrs, :surface),
      required_surface: required(attrs, :surface),
      product_owner_type: required(attrs, :product_owner_type),
      product_owner_id: required(attrs, :product_owner_id)
    })
  end

  defp lock_purchase_by_payment_intent!(repo, sql, payment_intent_id) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, surface, product_owner_type, product_owner_id,
          package_code, package_version, source_type, source_id, source_event_id,
          idempotency_key, source_metadata, period_start, period_end,
          provider_payment_intent_id, credit_grant_id, refunded_amount_minor,
          refunded_credits, refunded_at, status
        FROM billing_one_time_purchases
        WHERE provider_payment_intent_id = $1
        FOR UPDATE
        """,
        [payment_intent_id]
      )

    case result.rows do
      [row | _] -> row_to_purchase(row)
      [] -> repo.rollback(:stripe_purchase_not_found)
    end
  end

  defp lock_purchase_grant!(repo, sql, grant_id) do
    result =
      sql.query!(
        repo,
        "SELECT id, original_credits FROM credit_grants WHERE id = $1 FOR UPDATE",
        [grant_id]
      )

    case result.rows do
      [[id, original_credits] | _] -> %{id: id, original_credits: original_credits}
      [] -> repo.rollback(:purchase_credit_grant_not_found)
    end
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

  defp validate_periods(periods) when is_list(periods) and periods != [] do
    if Enum.all?(periods, &valid_period?/1), do: :ok, else: {:error, :invalid_cycle_period}
  end

  defp validate_periods(_periods), do: {:error, :periods_required}

  defp valid_period?(period) do
    valid_from = period[:valid_from] || period["valid_from"]
    expires_at = period[:expires_at] || period["expires_at"]
    cycle_key = period[:cycle_key] || period["cycle_key"]

    is_binary(cycle_key) and match?(%DateTime{}, valid_from) and match?(%DateTime{}, expires_at) and
      DateTime.compare(valid_from, expires_at) == :lt
  end

  defp first_period_start([period | _]), do: period[:valid_from] || period["valid_from"]

  defp validate_source(source_type, allowed) do
    if source_type in allowed, do: :ok, else: {:error, :invalid_source_type}
  end

  defp validate_package_surface(%{surface: surface}, surface), do: :ok

  defp validate_package_surface(_package_version, _surface),
    do: {:error, :package_surface_mismatch}

  defp validate_account_surface(repo, sql, account_id, surface) do
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
      [[^surface]] -> :ok
      [[_other]] -> {:error, :billing_account_surface_mismatch}
      [] -> {:error, :billing_account_not_found}
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp clamp_limit(_limit), do: 50

  defp package_lookup(attrs, repo, sql) do
    %{
      repo: repo,
      sql_runner: sql,
      package_code: required(attrs, :package_code),
      version: required(attrs, :package_version)
    }
  end

  defp row_to_subscription([
         id,
         billing_account_id,
         surface,
         product_owner_type,
         product_owner_id,
         package_code,
         package_version,
         source_type,
         source_id,
         source_event_id,
         idempotency_key,
         source_metadata,
         status
       ]) do
    %{
      id: id,
      billing_account_id: billing_account_id,
      surface: surface,
      product_owner_type: product_owner_type,
      product_owner_id: product_owner_id,
      package_code: package_code,
      package_version: package_version,
      source_type: source_type,
      source_id: source_id,
      source_event_id: source_event_id,
      idempotency_key: idempotency_key,
      source_metadata: decode_json(source_metadata),
      status: status
    }
  end

  defp row_to_cycle([
         id,
         subscription_id,
         billing_account_id,
         package_code,
         package_version,
         cycle_key,
         period_start,
         period_end,
         grant_idempotency_key,
         source_event_id,
         grant_source_type,
         credit_grant_id,
         status,
         attempts,
         last_error
       ]) do
    %{
      id: id,
      subscription_id: subscription_id,
      billing_account_id: billing_account_id,
      package_code: package_code,
      package_version: package_version,
      cycle_key: cycle_key,
      valid_from: period_start,
      expires_at: period_end,
      grant_idempotency_key: grant_idempotency_key,
      source_event_id: source_event_id,
      grant_source_type: grant_source_type,
      credit_grant_id: credit_grant_id,
      status: status,
      attempts: attempts,
      last_error: last_error
    }
  end

  defp row_to_purchase([
         id,
         billing_account_id,
         surface,
         product_owner_type,
         product_owner_id,
         package_code,
         package_version,
         source_type,
         source_id,
         source_event_id,
         idempotency_key,
         source_metadata,
         period_start,
         period_end,
         provider_payment_intent_id,
         credit_grant_id,
         refunded_amount_minor,
         refunded_credits,
         refunded_at,
         status
       ]) do
    %{
      id: id,
      billing_account_id: billing_account_id,
      surface: surface,
      product_owner_type: product_owner_type,
      product_owner_id: product_owner_id,
      package_code: package_code,
      package_version: package_version,
      source_type: source_type,
      source_id: source_id,
      source_event_id: source_event_id,
      idempotency_key: idempotency_key,
      source_metadata: decode_json(source_metadata),
      valid_from: period_start,
      expires_at: period_end,
      provider_payment_intent_id: provider_payment_intent_id,
      credit_grant_id: credit_grant_id,
      refunded_amount_minor: refunded_amount_minor,
      refunded_credits: refunded_credits,
      refunded_at: refunded_at,
      status: status
    }
  end

  defp repo(attrs),
    do: attrs[:repo] || attrs["repo"] || Application.fetch_env!(:billing_commerce, :repo)

  defp sql(attrs), do: attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL

  defp decode_json(value), do: BillingCore.Metadata.object(value)

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] ||
      raise ArgumentError, "missing subscription field #{key}"
  end

  defp id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
