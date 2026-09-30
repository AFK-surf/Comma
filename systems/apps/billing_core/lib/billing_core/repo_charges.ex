defmodule BillingCore.RepoCharges do
  @moduledoc """
  Repo-backed charge engine for production billing.

  The transaction locks only the current billing account row, then performs
  bounded active grant/remainder reads for that account. Idempotency is the
  database unique key on `(billing_account_id, source_key)`.
  """

  alias BillingCore.Time
  alias BillingCore.Entitlements.Policy

  @credits_per_usd 1_000_000

  def charge_meter_event(attrs) when is_map(attrs) do
    repo = attrs[:repo] || Application.fetch_env!(:billing_core, :repo)
    sql = attrs[:sql_runner] || Ecto.Adapters.SQL

    repo
    |> transaction(fn ->
      charge_in_transaction(repo, sql, attrs)
    end)
    |> unwrap_transaction()
  end

  defp charge_in_transaction(repo, sql, attrs) do
    event = normalize_event!(attrs)

    # The sweeper hoists ensure_account out of the per-charge transaction to
    # avoid serializing on the same billing_accounts row; it passes
    # ensure_account: false. Live callers leave it unset and ensure here.
    unless attrs[:ensure_account] == false do
      :ok = BillingCore.Accounts.ensure_account(Map.merge(event, %{repo: repo, sql_runner: sql}))
    end

    lock_idempotency_key(repo, sql, event)

    case existing_ledger(repo, sql, event) do
      {:ok, ledger} ->
        {:ok, Map.put(ledger, :idempotent, true)}

      :not_found ->
        case resolve_pricing(repo, sql, event) do
          {:ok, components, calculated} ->
            commit_charge(repo, sql, event, components, calculated)

          :missing_pricing ->
            {:pending, insert_pending(repo, sql, event)}
        end
    end
  end

  defp lock_idempotency_key(repo, sql, event) do
    sql.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [event.billing_account_id, event.source_key]
    )

    :ok
  end

  defp existing_ledger(repo, sql, event) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, charged_credits, balance_after, status
        FROM credit_ledger
        WHERE billing_account_id = $1 AND source_key = $2
        """,
        [event.billing_account_id, event.source_key]
      )

    case result.rows do
      [[id, charged_credits, balance_after, status] | _] ->
        {:ok,
         %{
           id: id,
           charged_credits: charged_credits,
           balance_after: balance_after,
           status: status
         }}

      [] ->
        :not_found
    end
  end

  defp commit_charge(repo, sql, event, components, calculated) do
    lock_account(repo, sql, event.billing_account_id)
    entitlement = active_entitlement(repo, sql, event)

    if entitlement.mode == :unlimited_metered do
      commit_unlimited_charge(repo, sql, event, components, calculated, entitlement)
    else
      commit_metered_charge(repo, sql, event, components, calculated, entitlement)
    end
  end

  defp commit_metered_charge(repo, sql, event, components, calculated, entitlement) do
    remainder = lock_remainder(repo, sql, event)
    total = calculated + remainder
    charged_credits = floor(total)
    next_remainder = total - charged_credits
    grants = lock_active_grants(repo, sql, event, charged_credits)

    {grant_credits, grant_debits, grant_updates} = consume_grants(grants, charged_credits)
    balance_after = available_credits(grants, grant_updates)
    grace_credits = charged_credits - grant_credits
    status = if grace_credits == 0, do: "charged", else: "grace"
    ledger_id = id("ledger")

    Enum.each(grant_updates, fn {grant_id, remaining} ->
      sql.query!(
        repo,
        "UPDATE credit_grants SET remaining_credits = $2 WHERE id = $1",
        [grant_id, remaining]
      )
    end)

    update_balance_projection(repo, sql, event.billing_account_id, balance_after)

    sql.query!(
      repo,
      """
      INSERT INTO meter_rounding_remainders (
        billing_account_id, resource_kind, provider, sku, remainder_credits, updated_at
      ) VALUES ($1, $2, $3, $4, $5, now())
      ON CONFLICT (billing_account_id, resource_kind, provider, sku)
      DO UPDATE SET remainder_credits = EXCLUDED.remainder_credits, updated_at = now()
      """,
      [
        event.billing_account_id,
        event.resource_kind,
        event.provider,
        event.sku,
        next_remainder
      ]
    )

    sql.query!(
      repo,
      """
      INSERT INTO credit_ledger (
        id, billing_account_id, source_key, resource_kind, provider, sku,
        pricing_components, credits_per_usd, calculated_credits, charged_credits,
        grace_credits, balance_after, grant_debits, balance_after_snapshot, status, inserted_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
      ON CONFLICT (billing_account_id, source_key) DO NOTHING
      """,
      [
        ledger_id,
        event.billing_account_id,
        event.source_key,
        event.resource_kind,
        event.provider,
        event.sku,
        Jason.encode!(components),
        @credits_per_usd,
        floor(calculated),
        charged_credits,
        grace_credits,
        balance_after,
        Jason.encode!(grant_debits),
        Jason.encode!(%{available_credits: balance_after, entitlement_mode: entitlement.mode}),
        status,
        event.metered_at
      ]
    )

    {:ok,
     %{
       id: ledger_id,
       billing_account_id: event.billing_account_id,
       source_key: event.source_key,
       charged_credits: charged_credits,
       calculated_credits: floor(calculated),
       grace_credits: grace_credits,
       balance_after: balance_after,
       balance_after_snapshot: %{
         available_credits: balance_after,
         entitlement_mode: entitlement.mode
       },
       grant_debits: grant_debits,
       entitlement_mode: entitlement.mode,
       status: status,
       pricing_components: components,
       credits_per_usd: @credits_per_usd,
       idempotent: false
     }}
    |> emit_charge_event(event)
  end

  defp commit_unlimited_charge(repo, sql, event, components, calculated, entitlement) do
    balance_after = entitlement.balance_snapshot
    ledger_id = id("ledger")

    update_balance_projection(repo, sql, event.billing_account_id, balance_after)

    sql.query!(
      repo,
      """
      INSERT INTO credit_ledger (
        id, billing_account_id, source_key, resource_kind, provider, sku,
        pricing_components, credits_per_usd, calculated_credits, charged_credits,
        grace_credits, balance_after, grant_debits, balance_after_snapshot, status, inserted_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 0, 0, $10, '[]'::jsonb, $11, 'unlimited_metered', $12)
      ON CONFLICT (billing_account_id, source_key) DO NOTHING
      """,
      [
        ledger_id,
        event.billing_account_id,
        event.source_key,
        event.resource_kind,
        event.provider,
        event.sku,
        Jason.encode!(components),
        @credits_per_usd,
        floor(calculated),
        balance_after,
        Jason.encode!(%{available_credits: balance_after, entitlement_mode: entitlement.mode}),
        event.metered_at
      ]
    )

    {:ok,
     %{
       id: ledger_id,
       billing_account_id: event.billing_account_id,
       source_key: event.source_key,
       charged_credits: 0,
       calculated_credits: floor(calculated),
       grace_credits: 0,
       balance_after: balance_after,
       balance_after_snapshot: %{
         available_credits: balance_after,
         entitlement_mode: entitlement.mode
       },
       grant_debits: [],
       entitlement_mode: entitlement.mode,
       status: "unlimited_metered",
       pricing_components: components,
       credits_per_usd: @credits_per_usd,
       idempotent: false
     }}
    |> emit_charge_event(event)
  end

  defp emit_charge_event({:ok, charge}, event) do
    case charge_typed_sink(event) do
      nil ->
        {:ok, charge}

      sink ->
        row =
          event
          |> Map.merge(%{
            source: "billing_core.ledger",
            source_key: event.source_key,
            status: charge.status,
            charge_status: charge.status,
            pricing_status: "priced",
            calculated_credits: charge.calculated_credits,
            charged_credits: charge.charged_credits,
            grace_credits: charge.grace_credits,
            balance_after: charge.balance_after,
            entitlement_mode: Atom.to_string(charge.entitlement_mode || :metered),
            pricing_components: charge.pricing_components,
            credits_per_usd: charge.credits_per_usd
          })
          |> SalixAnalytics.BillingChargeEvent.build()

        _ = safe_sink_insert(sink, [row])
        {:ok, charge}
    end
  end

  defp safe_sink_insert(sink, rows) do
    case sink.insert(rows) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:charge_event_sink, reason}}
      other -> {:error, {:charge_event_sink, other}}
    end
  rescue
    exception ->
      {:error, {:charge_event_sink, {exception.__struct__, Exception.message(exception)}}}
  catch
    kind, reason -> {:error, {:charge_event_sink, {kind, reason}}}
  end

  defp charge_typed_sink(%{typed_sink: false}), do: nil

  defp charge_typed_sink(event),
    do: event[:typed_sink] || Application.get_env(:billing_core, :charge_typed_sink)

  defp transaction(repo, fun), do: repo.transaction(fun)
  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp unwrap_transaction(result), do: result

  defp lock_account(repo, sql, account_id) do
    sql.query!(
      repo,
      """
      SELECT id
      FROM billing_accounts
      WHERE id = $1
      FOR UPDATE
      """,
      [account_id]
    )

    :ok
  end

  defp lock_active_grants(repo, sql, event, required_credits) do
    do_lock_active_grants(repo, sql, event, required_credits, nil, [])
  end

  defp active_entitlement(repo, sql, event) do
    result =
      sql.query!(
        repo,
        """
        SELECT
          COALESCE(SUM(GREATEST(remaining_credits, 0)), 0),
          COALESCE(jsonb_agg(policy_snapshot) FILTER (WHERE policy_snapshot IS NOT NULL), '[]'::jsonb)
        FROM credit_grants
        WHERE billing_account_id = $1
          AND status = 'active'
          AND valid_from <= $2
          AND (expires_at IS NULL OR expires_at > $2)
        """,
        [event.billing_account_id, event.metered_at]
      )

    {balance, policies} =
      case result.rows do
        [[balance, policies] | _] -> {normalize_number(balance), normalize_policies(policies)}
        [[balance] | _] -> {normalize_number(balance), []}
        _ -> {0, []}
      end

    policy = Policy.merge_active(policies)

    %{
      balance_snapshot: balance,
      mode: Policy.usage_mode(policy),
      policy: policy
    }
  end

  defp do_lock_active_grants(_repo, _sql, _event, required_credits, _cursor, grants)
       when required_credits <= 0 do
    grants
  end

  defp do_lock_active_grants(repo, sql, event, required_credits, cursor, grants) do
    {cursor_clause, cursor_params} =
      case cursor do
        nil ->
          {"", []}

        {expires_at, priority, id} ->
          {
            "AND (COALESCE(expires_at, 'infinity'::timestamptz), priority, id) > (COALESCE($3::timestamptz, 'infinity'::timestamptz), $4, $5)",
            [expires_at, priority, id]
          }
      end

    result =
      sql.query!(
        repo,
        """
        SELECT id, remaining_credits, expires_at, priority
        FROM credit_grants
        WHERE billing_account_id = $1
          AND remaining_credits > 0
          AND status = 'active'
          AND valid_from <= $2
          AND (expires_at IS NULL OR expires_at > $2)
          #{cursor_clause}
        ORDER BY expires_at NULLS LAST, priority, id
        LIMIT 512
        FOR UPDATE
        """,
        [event.billing_account_id, event.metered_at] ++ cursor_params
      )

    page =
      Enum.map(result.rows, fn
        [id, remaining, expires_at, priority] ->
          %{id: id, remaining_credits: remaining, expires_at: expires_at, priority: priority}

        [id, remaining] ->
          %{id: id, remaining_credits: remaining, expires_at: nil, priority: 0}
      end)

    next_grants = grants ++ page
    next_required = required_credits - Enum.sum(Enum.map(page, & &1.remaining_credits))

    if page == [] or next_required <= 0 do
      next_grants
    else
      last = List.last(page)

      do_lock_active_grants(
        repo,
        sql,
        event,
        next_required,
        {last.expires_at, last.priority, last.id},
        next_grants
      )
    end
  end

  defp lock_remainder(repo, sql, event) do
    result =
      sql.query!(
        repo,
        """
        SELECT remainder_credits
        FROM meter_rounding_remainders
        WHERE billing_account_id = $1
          AND resource_kind = $2
          AND provider = $3
          AND sku = $4
        FOR UPDATE
        """,
        [event.billing_account_id, event.resource_kind, event.provider, event.sku]
      )

    case result.rows do
      [[value] | _] -> numeric(value)
      [] -> 0.0
    end
  end

  defp resolve_pricing(repo, sql, %{meter_components: components} = event)
       when is_list(components) and components != [] do
    Enum.reduce_while(components, {:ok, [], 0.0}, fn component, {:ok, acc, total} ->
      component = Map.merge(Map.take(event, [:resource_kind, :provider, :sku]), component)

      case pricing_row(
             repo,
             sql,
             event.billing_account_id,
             BillingCore.Pricing.lookup_component(event, component),
             event.metered_at
           ) do
        {:ok, price} ->
          quantity = Map.fetch!(component, :quantity)
          credits = quantity * numeric(price.usd_micros_per_unit)

          priced =
            component
            |> Map.take([:resource_kind, :provider, :sku, :component, :meter_unit, :quantity])
            |> Map.merge(%{
              pricing_version: price.version,
              usd_micros_per_unit: price.usd_micros_per_unit,
              calculated_credits: credits
            })

          {:cont, {:ok, [priced | acc], total + credits}}

        :missing_pricing ->
          {:halt, :missing_pricing}
      end
    end)
    |> case do
      {:ok, priced, total} -> {:ok, Enum.reverse(priced), total}
      :missing_pricing -> :missing_pricing
    end
  end

  defp resolve_pricing(repo, sql, event) do
    component = %{
      resource_kind: event.resource_kind,
      provider: event.provider,
      sku: event.sku,
      component: event[:component] || :runtime,
      quantity: event.quantity,
      meter_unit: event[:meter_unit]
    }

    case pricing_row(
           repo,
           sql,
           event.billing_account_id,
           BillingCore.Pricing.lookup_component(event, component),
           event.metered_at
         ) do
      {:ok, price} ->
        credits = event.quantity * numeric(price.usd_micros_per_unit)
        {:ok, [Map.merge(component, price) |> Map.put(:calculated_credits, credits)], credits}

      :missing_pricing ->
        :missing_pricing
    end
  end

  defp pricing_row(repo, sql, _account_id, component, metered_at) do
    result =
      sql.query!(
        repo,
        """
        SELECT version, usd_micros_per_unit, meter_unit
        FROM meter_pricing_catalog
        WHERE resource_kind = $1
          AND provider = $2
          AND sku = $3
          AND component = $4
          AND effective_at <= $5
          AND (expires_at IS NULL OR expires_at > $5)
        ORDER BY effective_at DESC, version DESC
        LIMIT 1
        """,
        [
          to_string(component.resource_kind),
          component.provider,
          component.sku,
          to_string(component.component),
          metered_at
        ]
      )

    case result.rows do
      [[version, usd_micros_per_unit, meter_unit] | _] ->
        {:ok,
         %{
           version: version,
           usd_micros_per_unit: numeric(usd_micros_per_unit),
           meter_unit: meter_unit
         }}

      [] ->
        :missing_pricing
    end
  end

  defp insert_pending(repo, sql, event) do
    pending_id = id("pending")
    expires_at = Time.add_one_month(event.metered_at)

    sql.query!(
      repo,
      """
      INSERT INTO pending_meter_charges (
        id, billing_account_id, source_key, resource_kind, provider, sku,
        meter_snapshot, status, metered_at, expires_at, inserted_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', $8, $9, now())
      ON CONFLICT (billing_account_id, source_key)
      DO UPDATE SET meter_snapshot = EXCLUDED.meter_snapshot, expires_at = EXCLUDED.expires_at
      """,
      [
        pending_id,
        event.billing_account_id,
        event.source_key,
        event.resource_kind,
        event.provider,
        event.sku,
        Jason.encode!(Map.drop(event, [:repo, :sql_runner])),
        event.metered_at,
        expires_at
      ]
    )

    %{
      id: pending_id,
      billing_account_id: event.billing_account_id,
      source_key: event.source_key,
      status: "pending",
      expires_at: expires_at
    }
  end

  defp consume_grants(grants, required) do
    {consumed, _remaining, debits, updates} =
      Enum.reduce(grants, {0, required, [], []}, fn grant,
                                                    {consumed, remaining, debits, updates} ->
        used = min(grant.remaining_credits, max(remaining, 0))
        next_remaining = grant.remaining_credits - used

        if used > 0 do
          debit = %{grant_id: grant.id, credits: used}

          {consumed + used, remaining - used, [debit | debits],
           [{grant.id, next_remaining} | updates]}
        else
          {consumed, remaining, debits, updates}
        end
      end)

    {consumed, Enum.reverse(debits), Enum.reverse(updates)}
  end

  defp available_credits(grants, updates) do
    remaining_by_id = Map.new(updates)

    grants
    |> Enum.map(fn grant -> Map.get(remaining_by_id, grant.id, grant.remaining_credits) end)
    |> Enum.sum()
  end

  defp update_balance_projection(repo, sql, account_id, balance_after) do
    # Projection/cache row only; active credit_grants remain the balance truth.
    sql.query!(
      repo,
      """
      INSERT INTO credit_balances (billing_account_id, balance_credits, updated_at)
      VALUES ($1, $2, now())
      ON CONFLICT (billing_account_id)
      DO UPDATE SET balance_credits = EXCLUDED.balance_credits, updated_at = now()
      """,
      [account_id, balance_after]
    )
  end

  defp normalize_policies(policies) when is_list(policies) do
    policies
    |> Enum.map(&normalize_policy/1)
    |> Enum.filter(&is_map/1)
  end

  defp normalize_policies(policies) when is_binary(policies) do
    case Jason.decode(policies) do
      {:ok, decoded} when is_list(decoded) -> normalize_policies(decoded)
      _ -> []
    end
  end

  defp normalize_policies(_policies), do: []

  defp normalize_policy(%{} = policy), do: policy

  defp normalize_policy(policy) when is_binary(policy) do
    case Jason.decode(policy) do
      {:ok, %{} = decoded} -> decoded
      _ -> nil
    end
  end

  defp normalize_policy(_policy), do: nil

  defp normalize_number(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_number(value) when is_integer(value), do: value
  defp normalize_number(value) when is_float(value), do: floor(value)
  defp normalize_number(_value), do: 0

  defp normalize_event!(attrs) do
    required = [:billing_account_id, :source_key, :resource_kind, :provider, :sku, :metered_at]

    Enum.each(required, fn key ->
      if is_nil(attrs[key]), do: raise(ArgumentError, "missing charge field #{key}")
    end)

    Map.merge(%{quantity: 0}, attrs)
  end

  defp numeric(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric(value) when is_integer(value), do: value * 1.0
  defp numeric(value) when is_float(value), do: value

  defp id(prefix) do
    prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end
end
