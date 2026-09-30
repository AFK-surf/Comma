defmodule BillingCore.Metering.PricingBackfill do
  @moduledoc """
  Replays pending meter charges after pricing catalog updates.

  Expired pending charges are marked `:expired_unpriced`. Repriced charges use
  the regular charge path, preserving idempotency and grant/balance semantics.
  """

  alias BillingCore.{Charges, State, Time}

  # Exponential backoff (seconds) applied to a charge that stays unpriced or
  # errors on a sweep. Index n-1 is the delay after the n-th attempt; attempts
  # past the schedule are capped.
  @backoff_schedule [60, 300, 1800, 7200]
  @backoff_cap 21_600

  @spec run(map()) :: {:ok, map(), State.t()} | {:error, atom()}
  def run(%{state: %State{} = state, now: %DateTime{} = now}) do
    {expired, active, retained} =
      state.pending_meter_charges
      |> Enum.reduce({[], [], []}, fn {key, pending}, {expired, active, retained} ->
        cond do
          Map.get(pending, :status) == :expired_unpriced ->
            {expired, active, [{key, pending} | retained]}

          Time.after?(now, Map.fetch!(pending, :expires_at)) ->
            expired_pending =
              pending
              |> Map.put(:status, :expired_unpriced)
              |> Map.put(:pricing_status, :expired_unpriced)

            {[expired_pending | expired], active, [{key, expired_pending} | retained]}

          true ->
            {expired, [{key, pending} | active], retained}
        end
      end)

    state = %{state | pending_meter_charges: Map.new(active ++ retained)}

    {charged, still_pending, state} =
      active
      |> Enum.map(fn {_key, pending} -> pending end)
      |> Enum.reduce({[], [], state}, fn pending, {charged, still_pending, acc_state} ->
        event = Map.put(pending, :state, acc_state)

        case Charges.charge_meter_event(event) do
          {:ok, charge, next_state} ->
            {[charge | charged], still_pending, next_state}

          {:pending, pending_charge, next_state} ->
            {charged, [pending_charge | still_pending], next_state}
        end
      end)

    summary = %{
      charged_count: length(charged),
      pending_count: length(still_pending),
      expired_count: length(expired),
      charged: Enum.reverse(charged),
      pending: Enum.reverse(still_pending),
      expired: Enum.reverse(expired)
    }

    {:ok, summary, state}
  end

  def run(attrs) when is_map(attrs) do
    repo = attrs[:repo] || Application.fetch_env!(:billing_core, :repo)
    sql = attrs[:sql_runner] || Ecto.Adapters.SQL
    now = attrs[:now] || DateTime.utc_now()
    limit = attrs[:limit] || 100

    with {:ok, %{expired_count: expired_count, active: active}} <-
           transaction(repo, fn ->
             %{
               expired_count: expire_pending(repo, sql, now, limit),
               active: active_pending(repo, sql, now, limit)
             }
           end) do
      {charged, still_pending, backed_off_count, failed_count, _ensured} =
        Enum.reduce(active, {[], [], 0, 0, %{}}, fn pending,
                                                    {charged, still_pending, backed_off, failed,
                                                     ensured} ->
          event =
            pending.meter_snapshot
            |> decode_snapshot()
            |> atomize_known()
            |> Map.merge(%{
              repo: repo,
              sql_runner: sql,
              billing_account_id: pending.billing_account_id,
              source_key: pending.source_key,
              resource_kind: pending.resource_kind,
              provider: pending.provider,
              sku: canonical_sku(pending),
              metered_at: pending.metered_at,
              typed_sink: Map.get(attrs, :typed_sink, false),
              # Account is ensured once per (account, surface) below, hoisted out
              # of the per-charge transaction to avoid same-row contention.
              ensure_account: false
            })

          {ensure_result, ensured} = ensure_account_once(repo, sql, event, ensured)

          case ensure_result do
            :ok ->
              case BillingCore.RepoCharges.charge_meter_event(event) do
                {:ok, charge} ->
                  delete_pending(repo, sql, pending.id)
                  {[charge | charged], still_pending, backed_off, failed, ensured}

                {:pending, next_pending} ->
                  schedule_retry(repo, sql, pending, now)
                  {charged, [next_pending | still_pending], backed_off + 1, failed, ensured}

                {:error, _reason} ->
                  schedule_retry(repo, sql, pending, now)
                  {charged, [pending | still_pending], backed_off, failed + 1, ensured}
              end

            {:error, _reason} ->
              schedule_retry(repo, sql, pending, now)
              {charged, [pending | still_pending], backed_off, failed + 1, ensured}
          end
        end)

      %{
        charged_count: length(charged),
        pending_count: length(still_pending),
        expired_count: expired_count,
        selected_count: length(active),
        backed_off_count: backed_off_count,
        failed_count: failed_count,
        charged: Enum.reverse(charged),
        pending: Enum.reverse(still_pending)
      }
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_attrs), do: {:error, :missing_state}

  defp expire_pending(repo, sql, now, limit) do
    result =
      sql.query!(
        repo,
        """
        WITH expired AS (
          SELECT id
          FROM pending_meter_charges
          WHERE status = 'pending' AND expires_at < $1
          ORDER BY expires_at, id
          LIMIT $2
          FOR UPDATE SKIP LOCKED
        )
        UPDATE pending_meter_charges p
        SET status = 'expired_unpriced'
        FROM expired
        WHERE p.id = expired.id
        """,
        [now, limit],
        log: false
      )

    result.num_rows || 0
  end

  defp active_pending(repo, sql, now, limit) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, source_key, resource_kind, provider, sku,
               meter_snapshot, metered_at, attempts, next_attempt_at
        FROM pending_meter_charges
        WHERE status = 'pending'
          AND expires_at >= $1
          AND (next_attempt_at IS NULL OR next_attempt_at <= $1)
        ORDER BY next_attempt_at NULLS FIRST, expires_at, id
        LIMIT $2
        FOR UPDATE SKIP LOCKED
        """,
        [now, limit],
        log: false
      )

    Enum.map(result.rows, fn [
                               id,
                               billing_account_id,
                               source_key,
                               resource_kind,
                               provider,
                               sku,
                               meter_snapshot,
                               metered_at,
                               attempts,
                               next_attempt_at
                             ] ->
      %{
        id: id,
        billing_account_id: billing_account_id,
        source_key: source_key,
        resource_kind: resource_kind,
        provider: provider,
        sku: sku,
        meter_snapshot: meter_snapshot,
        metered_at: metered_at,
        attempts: attempts || 0,
        next_attempt_at: next_attempt_at
      }
    end)
  end

  defp delete_pending(repo, sql, pending_id) do
    sql.query!(repo, "DELETE FROM pending_meter_charges WHERE id = $1", [pending_id], log: false)
  end

  # Ensures a billing account exists at most once per (account, surface) per
  # sweep, memoising the result so a failure (e.g. surface mismatch) is not
  # re-attempted for every charge of the same account.
  defp ensure_account_once(repo, sql, event, ensured) do
    key = {event.billing_account_id, event[:surface] || "unknown"}

    case Map.fetch(ensured, key) do
      {:ok, result} ->
        {result, ensured}

      :error ->
        result =
          BillingCore.Accounts.ensure_account(Map.merge(event, %{repo: repo, sql_runner: sql}))

        {result, Map.put(ensured, key, result)}
    end
  end

  defp schedule_retry(repo, sql, pending, now) do
    next_attempts = (pending.attempts || 0) + 1
    next_attempt_at = DateTime.add(now, backoff_seconds(next_attempts), :second)

    sql.query!(
      repo,
      "UPDATE pending_meter_charges SET attempts = $2, next_attempt_at = $3 WHERE id = $1",
      [pending.id, next_attempts, next_attempt_at],
      log: false
    )

    %{id: pending.id, attempts: next_attempts, next_attempt_at: next_attempt_at}
  end

  defp backoff_seconds(attempt) when attempt >= 1 do
    Enum.at(@backoff_schedule, attempt - 1, @backoff_cap)
  end

  defp canonical_sku(%{sku: sku}), do: sku

  defp transaction(repo, fun), do: repo.transaction(fun)

  defp decode_snapshot(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_snapshot(value) when is_map(value), do: value

  defp atomize_known(map) do
    Map.new(map, fn
      {"meter_components", value} -> {:meter_components, Enum.map(value, &atomize_known/1)}
      {"component", value} -> {:component, String.to_atom(value)}
      {"meter_unit", value} -> {:meter_unit, String.to_atom(value)}
      {"quantity", value} -> {:quantity, value}
      {"owner_snapshot", value} -> {:owner_snapshot, value}
      {key, value} -> {String.to_atom(key), value}
    end)
  end
end
