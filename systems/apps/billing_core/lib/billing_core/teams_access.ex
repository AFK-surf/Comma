defmodule BillingCore.TeamsAccess do
  @moduledoc "Teams access reads paid subscription allocations, independently of model credits."

  @doc "Read one account's current licensed seats. Existing accounts retain their current policy."
  def check(account_id) when is_binary(account_id) do
    repo = SystemsRuntime.get_env(:billing_core, :repo, BillingCore.Repo)

    case Ecto.Adapters.SQL.query(
           repo,
           """
           SELECT a.teams_subscription_required, a.status,
             COALESCE((
               SELECT max((p.value->>'teams_seats')::bigint)
               FROM billing_subscription_cycles c
               CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
               WHERE c.billing_account_id = a.id
                 AND c.period_start <= $2 AND c.period_end > $2
                 AND p.value->>'state' = 'paid'
                 AND p.value->>'teams_seats' IS NOT NULL
             ), 0)
           FROM billing_accounts a WHERE a.id = $1
           """,
           [account_id, SystemsClock.utc_now()],
           timeout: 1_000
         ) do
      {:ok, %{rows: [[false, _, _]]}} -> {:ok, :unmanaged}
      {:ok, %{rows: [[true, "active", seats]]}} when seats > 0 -> {:ok, seats}
      {:ok, %{rows: [[true, _, _]]}} -> {:error, :teams_subscription_required}
      {:ok, %{rows: []}} -> {:error, :billing_account_not_found}
      {:error, _} -> {:error, :billing_unavailable}
    end
  rescue
    _ -> {:error, :billing_unavailable}
  catch
    :exit, _ -> {:error, :billing_unavailable}
  end

  def check(_), do: {:error, :billing_account_not_found}

  @doc "Read one account's current and upcoming paid Teams coverage in a single indexed query."
  def coverage(account_id, now \\ SystemsClock.utc_now())

  def coverage(account_id, %DateTime{} = now) when is_binary(account_id) do
    repo = SystemsRuntime.get_env(:billing_core, :repo, BillingCore.Repo)
    coverage_in_repo(repo, account_id, now)
  end

  def coverage(_, _), do: {:error, :billing_account_not_found}

  @doc "Read one account's current and upcoming paid Teams coverage on a specific `repo` (e.g. inside an existing lock transaction)."
  def coverage_in_repo(repo, account_id, %DateTime{} = now) when is_binary(account_id) do
    case Ecto.Adapters.SQL.query(
           repo,
           """
           SELECT
             a.teams_subscription_required,
             a.status,
             EXISTS (
               SELECT 1
               FROM billing_subscriptions s
               WHERE s.billing_account_id = a.id
                 AND s.source_type = 'stripe_subscription'
                 AND s.status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused')
             ) AS has_active_stripe_subscription,
             COALESCE((
               SELECT jsonb_agg(
                 jsonb_build_object(
                   'period_start', c.period_start,
                   'period_end', c.period_end,
                   'teams_seats', (p.value->>'teams_seats')::bigint,
                   'source_type', s.source_type
                 )
                 ORDER BY c.period_start ASC, c.period_end ASC
               )
               FROM billing_subscription_cycles c
               JOIN billing_subscriptions s ON s.id = c.subscription_id
               CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
               WHERE c.billing_account_id = a.id
                 AND c.period_end > $2
                 AND p.value->>'state' = 'paid'
                 AND p.value->>'teams_seats' IS NOT NULL
                 AND (p.value->>'teams_seats')::bigint > 0
             ), '[]'::jsonb) AS active_or_future_allocations,
             COALESCE(
               (
                 SELECT s.source_type
                 FROM billing_subscription_cycles c
                 JOIN billing_subscriptions s ON s.id = c.subscription_id
                 CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
                 WHERE c.billing_account_id = a.id
                   AND p.value->>'state' = 'paid'
                   AND p.value->>'teams_seats' IS NOT NULL
                   AND (p.value->>'teams_seats')::bigint > 0
                 ORDER BY c.period_end DESC, c.period_start DESC
                 LIMIT 1
               ),
               (
                 SELECT s2.source_type
                 FROM billing_subscriptions s2
                 WHERE s2.billing_account_id = a.id
                 ORDER BY s2.updated_at DESC, s2.inserted_at DESC
                 LIMIT 1
               )
             ) AS latest_paid_source_type
           FROM billing_accounts a
           WHERE a.id = $1
           """,
           [account_id, now],
           timeout: 1_000
         ) do
      {:ok, %{rows: [[managed, status, has_active_stripe, raw_allocations, latest_source_type]]}} ->
        {:ok,
         build_coverage(
           managed == true,
           status == "active",
           has_active_stripe == true,
           parse_allocations(raw_allocations),
           latest_source_type,
           now
         )}

      {:ok, %{rows: []}} ->
        {:error, :billing_account_not_found}

      {:error, _} ->
        {:error, :billing_unavailable}
    end
  rescue
    _ -> {:error, :billing_unavailable}
  catch
    :exit, _ -> {:error, :billing_unavailable}
  end

  def coverage_in_repo(_, _, _), do: {:error, :billing_account_not_found}

  @doc """
  Batch-read current and contiguous-future Teams coverage summaries for a page
  of owner/admin billing accounts in one `ANY($1)` query with a 1-second timeout.
  """
  def batch_admin_summary(account_ids, now \\ SystemsClock.utc_now())

  def batch_admin_summary([], %DateTime{}), do: {:ok, %{}}

  def batch_admin_summary(account_ids, %DateTime{} = now) when is_list(account_ids) do
    ids =
      account_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if ids == [] do
      {:ok, %{}}
    else
      repo = SystemsRuntime.get_env(:billing_core, :repo, BillingCore.Repo)

      case Ecto.Adapters.SQL.query(
             repo,
             """
             SELECT
               a.id,
               a.teams_subscription_required,
               a.status,
               COALESCE((
                 SELECT jsonb_agg(
                   jsonb_build_object(
                     'period_start', c.period_start,
                     'period_end', c.period_end,
                     'teams_seats', (p.value->>'teams_seats')::bigint,
                     'source_type', s.source_type
                   )
                   ORDER BY c.period_start ASC, c.period_end ASC
                 )
                 FROM billing_subscription_cycles c
                 JOIN billing_subscriptions s ON s.id = c.subscription_id
                 CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
                 WHERE c.billing_account_id = a.id
                   AND c.period_end > $2
                   AND p.value->>'state' = 'paid'
                   AND p.value->>'teams_seats' IS NOT NULL
                   AND (p.value->>'teams_seats')::bigint > 0
               ), '[]'::jsonb) AS active_or_future_allocations
             FROM billing_accounts a
             WHERE a.id = ANY($1::text[])
             """,
             [ids, now],
             timeout: 1_000
           ) do
        {:ok, %{rows: rows}} ->
          summaries =
            Map.new(rows, fn [account_id, managed, status, raw_allocations] ->
              cov =
                build_coverage(
                  managed == true,
                  status == "active",
                  false,
                  parse_allocations(raw_allocations),
                  nil,
                  now
                )

              {account_id,
               %{
                 managed: cov.managed,
                 active: cov.active,
                 licensed_seats: cov.licensed_seats,
                 expires_at: cov.expires_at
               }}
            end)

          {:ok, summaries}

        {:error, _} ->
          {:error, :billing_unavailable}
      end
    end
  rescue
    _ -> {:error, :billing_unavailable}
  catch
    :exit, _ -> {:error, :billing_unavailable}
  end

  def batch_admin_summary(_, _), do: {:error, :billing_unavailable}

  defp build_coverage(managed, account_active, has_active_stripe, allocations, latest_source, now) do
    current =
      Enum.filter(allocations, fn alloc ->
        DateTime.compare(alloc.period_start, now) != :gt and
          DateTime.compare(alloc.period_end, now) == :gt
      end)

    future =
      Enum.filter(allocations, fn alloc ->
        DateTime.compare(alloc.period_start, now) == :gt
      end)

    current_seats =
      current
      |> Enum.map(& &1.teams_seats)
      |> Enum.max(fn -> 0 end)

    current_period_end =
      current
      |> Enum.map(& &1.period_end)
      |> Enum.max(DateTime, fn -> nil end)

    next_period_end =
      future
      |> Enum.map(& &1.period_end)
      |> Enum.max(DateTime, fn -> nil end)

    expires_at = contiguous_end(current_period_end, future)
    licensed_seats = if account_active, do: current_seats, else: 0
    active = account_active and current_seats > 0

    provider_source =
      case current do
        [] ->
          latest_source

        list ->
          list
          |> Enum.max_by(&DateTime.to_unix(&1.period_end, :microsecond))
          |> Map.fetch!(:source_type)
      end

    %{
      managed: managed,
      account_active: account_active,
      active: active,
      licensed_seats: licensed_seats,
      expires_at: expires_at,
      current_period_end: current_period_end,
      next_period_end: next_period_end,
      has_future_paid_cycle: future != [],
      provider: map_provider(provider_source),
      has_active_stripe_subscription: has_active_stripe
    }
  end

  defp contiguous_end(nil, _future), do: nil

  defp contiguous_end(current_end, future) do
    future
    |> Enum.sort_by(
      &{DateTime.to_unix(&1.period_start, :microsecond),
       DateTime.to_unix(&1.period_end, :microsecond)}
    )
    |> Enum.reduce(current_end, fn alloc, acc ->
      if DateTime.compare(alloc.period_start, acc) != :gt and
           DateTime.compare(alloc.period_end, acc) == :gt do
        alloc.period_end
      else
        acc
      end
    end)
  end

  defp parse_allocations(allocations) when is_list(allocations) do
    Enum.flat_map(allocations, fn
      %{
        "period_start" => start_iso,
        "period_end" => end_iso,
        "teams_seats" => seats,
        "source_type" => source_type
      }
      when is_binary(start_iso) and is_binary(end_iso) and is_integer(seats) and seats > 0 ->
        with {:ok, period_start, _} <- DateTime.from_iso8601(start_iso),
             {:ok, period_end, _} <- DateTime.from_iso8601(end_iso) do
          [
            %{
              period_start: period_start,
              period_end: period_end,
              teams_seats: seats,
              source_type: source_type
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp parse_allocations(_), do: []

  defp map_provider("stripe_subscription"), do: "stripe"
  defp map_provider("m2square_term"), do: "m2square"
  defp map_provider(_), do: nil
end
