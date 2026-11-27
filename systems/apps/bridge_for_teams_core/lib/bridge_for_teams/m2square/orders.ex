defmodule BridgeForTeams.M2square.Orders do
  @moduledoc """
  Persistent projection and order-ID helpers for `billing_m2square_orders` in `BillingCore.Repo`.

  Only non-sensitive snapshot fields (`email`, `org_name`, `name`, and
  `analytics_opt_out` for a DNT signup) are persisted in `signup_snapshot`. Payer document numbers (`docNumber`, `beneficiaryId`) and phone
  numbers are never stored.
  """

  @mch_order_prefix "mtt"
  @mch_order_random_len 21
  @base_order_regex ~r/\A([a-z]{24})\z/
  @duplicate_order_regex ~r/\A([a-z]{24})_([1-9][0-9]*)\z/
  @signup_snapshot_keys ["email", "org_name", "name", "analytics_opt_out"]

  @select_columns """
  mch_order_id, provider_order_id, billing_account_id, product_owner_id,
  kind, target_slot, country, payment_type, currency, display_currency,
  teams_seats, usd_net_minor, locked_amount, fx_rate, fx_source,
  fee_rate, markup_rate, signup_snapshot, checkout_url, status,
  real_amount, mch_fee, bank_id, duplicate_events, subscription_id,
  cycle_id, paid_at, reversed_at, refund_metadata, notification_claimed_at,
  notified_at, last_checked_at, inserted_at, updated_at
  """

  @doc """
  Generates a 24-character lowercase alphabetic merchant order ID (`"mtt"` + 21 uniform `[a-z]`).
  Contains no digits or underscores so M2square duplicate-payment suffixes (`_1`, `_2`, ...)
  cannot collide with base order IDs.
  """
  @spec generate_mch_order_id() :: String.t()
  def generate_mch_order_id do
    @mch_order_prefix <> random_lowercase_letters(@mch_order_random_len, [])
  end

  defp random_lowercase_letters(0, acc), do: IO.iodata_to_binary(acc)

  defp random_lowercase_letters(remaining, acc) do
    bytes = SystemsRuntime.Proc.random_bytes(max(remaining * 2, 16))
    collect_letters(bytes, remaining, acc)
  end

  defp collect_letters(_bytes, 0, acc), do: IO.iodata_to_binary(acc)
  defp collect_letters(<<>>, remaining, acc), do: random_lowercase_letters(remaining, acc)

  defp collect_letters(<<b, rest::binary>>, remaining, acc) when b < 234 do
    collect_letters(rest, remaining - 1, [rem(b, 26) + ?a | acc])
  end

  defp collect_letters(<<_b, rest::binary>>, remaining, acc) do
    collect_letters(rest, remaining, acc)
  end

  @doc """
  Parses a webhook `mchOrderId` into `{:base, base_id}`, `{:duplicate, base_id, suffix}`,
  or `:invalid`.
  """
  @spec parse_webhook_order_id(term()) ::
          {:base, String.t()} | {:duplicate, String.t(), String.t()} | :invalid
  def parse_webhook_order_id(raw) when is_binary(raw) do
    cond do
      Regex.match?(@base_order_regex, raw) ->
        {:base, raw}

      match = Regex.run(@duplicate_order_regex, raw) ->
        [_full, base_id, suffix] = match
        {:duplicate, base_id, suffix}

      true ->
        :invalid
    end
  end

  def parse_webhook_order_id(_), do: :invalid

  @doc """
  Returns the most recent paid (unrevoked) cycle ID for `billing_account_id`,
  including expired cycles.

  Must be called inside a `billing_accounts FOR UPDATE` transaction. Deliberately
  omits any `period_end > now` filter so renewals created before and after a term
  boundary map to the same `target_slot = "after:<cycle_id>"`.
  """
  @spec prior_paid_cycle_id(Ecto.Repo.t(), String.t()) :: String.t() | nil
  def prior_paid_cycle_id(repo, billing_account_id) when is_binary(billing_account_id) do
    case Ecto.Adapters.SQL.query!(
           repo,
           """
           SELECT c.id
           FROM billing_subscription_cycles c
           CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
           WHERE c.billing_account_id = $1
             AND p.value->>'state' = 'paid'
             AND p.value->>'teams_seats' IS NOT NULL
             AND (p.value->>'teams_seats')::bigint > 0
           ORDER BY c.period_end DESC, c.period_start DESC, c.id DESC
           LIMIT 1
           """,
           [billing_account_id]
         ).rows do
      [[cycle_id]] -> cycle_id
      [] -> nil
    end
  end

  @doc """
  Inserts a new `creating` order row, stripping any sensitive PII from `signup_snapshot`.
  """
  @spec insert_creating_order!(Ecto.Repo.t(), map()) :: map()
  def insert_creating_order!(repo, attrs) when is_map(attrs) do
    now = Map.get(attrs, :inserted_at) || SystemsClock.utc_now()
    snapshot = sanitize_signup_snapshot(fetch_attr(attrs, :signup_snapshot))

    %{rows: [row]} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        INSERT INTO billing_m2square_orders (
          mch_order_id, billing_account_id, product_owner_id, kind, target_slot,
          country, payment_type, currency, display_currency, teams_seats,
          usd_net_minor, locked_amount, fx_rate, fx_source, fee_rate, markup_rate,
          signup_snapshot, status, duplicate_events, inserted_at, updated_at
        ) VALUES (
          $1, $2, $3, $4, $5,
          $6, $7, $8, $9, $10,
          $11, $12, $13, $14, $15, $16,
          $17::jsonb, 'creating', '[]'::jsonb, $18, $18
        )
        RETURNING #{@select_columns}
        """,
        [
          fetch_attr!(attrs, :mch_order_id),
          fetch_attr!(attrs, :billing_account_id),
          fetch_attr!(attrs, :product_owner_id),
          fetch_attr!(attrs, :kind),
          fetch_attr!(attrs, :target_slot),
          fetch_attr!(attrs, :country),
          fetch_attr!(attrs, :payment_type),
          fetch_attr!(attrs, :currency),
          fetch_attr!(attrs, :display_currency),
          fetch_attr!(attrs, :teams_seats),
          fetch_attr!(attrs, :usd_net_minor),
          fetch_attr!(attrs, :locked_amount),
          fetch_attr!(attrs, :fx_rate),
          fetch_attr!(attrs, :fx_source),
          fetch_attr!(attrs, :fee_rate),
          fetch_attr!(attrs, :markup_rate),
          snapshot,
          now
        ]
      )

    row_to_order(row)
  end

  @doc """
  Atomically binds `provider_order_id` and `checkout_url` under an order row lock,
  enforcing first-bind immutability (`nil -> bind`, same -> idempotent, different -> conflict).
  """
  @spec bind_open_order(Ecto.Repo.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found | :provider_order_id_conflict | :order_not_openable}
  def bind_open_order(repo, mch_order_id, provider_order_id, checkout_url) do
    now = SystemsClock.utc_now()

    repo.transaction(fn ->
      case lock_by_mch_order_id(repo, mch_order_id) do
        {:error, :not_found} ->
          repo.rollback(:not_found)

        {:ok, locked} ->
          cond do
            non_empty_binary?(locked.provider_order_id) and
                locked.provider_order_id != provider_order_id ->
              repo.rollback(:provider_order_id_conflict)

            locked.status in ["creating", "open"] ->
              %{rows: [row]} =
                Ecto.Adapters.SQL.query!(
                  repo,
                  """
                  UPDATE billing_m2square_orders
                  SET provider_order_id = COALESCE(provider_order_id, $2),
                      checkout_url = COALESCE(checkout_url, $3),
                      status = 'open',
                      updated_at = $4
                  WHERE mch_order_id = $1
                  RETURNING #{@select_columns}
                  """,
                  [mch_order_id, provider_order_id, checkout_url, now]
                )

              row_to_order(row)

            locked.provider_order_id == provider_order_id and
                non_empty_binary?(locked.checkout_url) ->
              locked

            true ->
              repo.rollback(:order_not_openable)
          end
      end
    end)
  end

  @doc "Transitions a `creating` or `open` order to `open` with `provider_order_id` and optional `checkout_url`."
  @spec mark_open!(Ecto.Repo.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def mark_open!(repo, mch_order_id, provider_order_id, checkout_url) do
    now = SystemsClock.utc_now()

    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET provider_order_id = COALESCE(provider_order_id, $2),
          checkout_url = COALESCE(checkout_url, $3),
          status = 'open',
          updated_at = $4
      WHERE mch_order_id = $1
        AND status IN ('creating', 'open')
        AND (provider_order_id IS NULL OR provider_order_id = $2)
      """,
      [mch_order_id, provider_order_id, checkout_url, now]
    )

    :ok
  end

  @doc """
  Persistently quarantines an order (e.g., `pay` returned mismatched currency) while
  binding `provider_order_id` so subsequent webhooks/reconciliation route to `conflict_paid`
  instead of granting seats.
  """
  @spec mark_quarantined!(Ecto.Repo.t(), String.t(), String.t() | nil) :: :ok
  def mark_quarantined!(repo, mch_order_id, provider_order_id) do
    now = SystemsClock.utc_now()

    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET status = 'quarantined',
          provider_order_id = COALESCE(provider_order_id, $2::text),
          updated_at = $3
      WHERE mch_order_id = $1
        AND status IN ('creating', 'open', 'failed', 'quarantined')
        AND (provider_order_id IS NULL OR $2::text IS NULL OR provider_order_id = $2::text)
      """,
      [mch_order_id, provider_order_id, now]
    )

    :ok
  end

  @doc "Transitions a `creating` or `open` order to `failed`, binding `provider_order_id` on first observation. Never downgrades terminal or quarantined orders."
  @spec mark_failed!(Ecto.Repo.t(), String.t(), String.t() | nil) :: :ok
  def mark_failed!(repo, mch_order_id, provider_order_id \\ nil) do
    now = SystemsClock.utc_now()

    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET status = 'failed',
          provider_order_id = COALESCE(provider_order_id, $3::text),
          updated_at = $2
      WHERE mch_order_id = $1
        AND status IN ('creating', 'open')
        AND (provider_order_id IS NULL OR $3::text IS NULL OR provider_order_id = $3::text)
      """,
      [mch_order_id, now, provider_order_id]
    )

    :ok
  end

  @doc "Fetches an order by `mch_order_id`."
  @spec get_by_mch_order_id(Ecto.Repo.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_mch_order_id(repo, mch_order_id) when is_binary(mch_order_id) do
    case Ecto.Adapters.SQL.query!(
           repo,
           "SELECT #{@select_columns} FROM billing_m2square_orders WHERE mch_order_id = $1 LIMIT 1",
           [mch_order_id]
         ).rows do
      [row] -> {:ok, row_to_order(row)}
      [] -> {:error, :not_found}
    end
  end

  def get_by_mch_order_id(_repo, _), do: {:error, :not_found}

  @doc "Fetches and row-locks an order by `mch_order_id` (`FOR UPDATE`)."
  @spec lock_by_mch_order_id(Ecto.Repo.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lock_by_mch_order_id(repo, mch_order_id) when is_binary(mch_order_id) do
    case Ecto.Adapters.SQL.query!(
           repo,
           "SELECT #{@select_columns} FROM billing_m2square_orders WHERE mch_order_id = $1 FOR UPDATE",
           [mch_order_id]
         ).rows do
      [row] -> {:ok, row_to_order(row)}
      [] -> {:error, :not_found}
    end
  end

  def lock_by_mch_order_id(_repo, _), do: {:error, :not_found}

  @doc """
  Atomically claims a return-check slot if the order is still non-terminal (`creating`,
  `open`, `failed`, `quarantined`) and at least `cooldown_sec` seconds have elapsed since
  `last_checked_at`.
  """
  @spec claim_return_check?(Ecto.Repo.t(), String.t(), DateTime.t(), pos_integer()) :: boolean()
  def claim_return_check?(repo, mch_order_id, %DateTime{} = now, cooldown_sec \\ 5)
      when is_binary(mch_order_id) and is_integer(cooldown_sec) and cooldown_sec >= 0 do
    cutoff = DateTime.add(now, -cooldown_sec, :second)

    %{num_rows: count} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        UPDATE billing_m2square_orders
        SET last_checked_at = $2,
            updated_at = $2
        WHERE mch_order_id = $1
          AND status IN ('creating', 'open', 'failed', 'quarantined')
          AND (last_checked_at IS NULL OR last_checked_at <= $3)
        """,
        [mch_order_id, now, cutoff]
      )

    count == 1
  end

  @doc """
  Atomically claims a transient send lease (`notification_claimed_at`) for an order whose
  confirmation email has not yet been confirmed (`notified_at IS NULL`).
  """
  @spec claim_notification_send?(Ecto.Repo.t(), String.t(), DateTime.t(), pos_integer()) ::
          boolean()
  def claim_notification_send?(repo, mch_order_id, %DateTime{} = now, lease_sec \\ 60)
      when is_binary(mch_order_id) and is_integer(lease_sec) and lease_sec >= 0 do
    cutoff = DateTime.add(now, -lease_sec, :second)

    %{num_rows: count} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        UPDATE billing_m2square_orders
        SET notification_claimed_at = $2,
            updated_at = $2
        WHERE mch_order_id = $1
          AND notified_at IS NULL
          AND (notification_claimed_at IS NULL OR notification_claimed_at <= $3)
        """,
        [mch_order_id, now, cutoff]
      )

    count == 1
  end

  @doc "Records confirmed delivery handoff to the mail provider (`notified_at`)."
  @spec mark_notified!(Ecto.Repo.t(), String.t(), DateTime.t()) :: :ok
  def mark_notified!(repo, mch_order_id, %DateTime{} = now) when is_binary(mch_order_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET notified_at = COALESCE(notified_at, $2),
          updated_at = $2
      WHERE mch_order_id = $1
      """,
      [mch_order_id, now]
    )

    :ok
  end

  @doc "Releases a transient send claim after a failed email attempt while leaving `notified_at` NULL."
  @spec release_notification_claim!(Ecto.Repo.t(), String.t()) :: :ok
  def release_notification_claim!(repo, mch_order_id) when is_binary(mch_order_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET notification_claimed_at = NULL,
          updated_at = $2
      WHERE mch_order_id = $1
        AND notified_at IS NULL
      """,
      [mch_order_id, SystemsClock.utc_now()]
    )

    :ok
  end

  @doc """
  Idempotently upserts a duplicate-payment event by `provider_order_id` with monotonic
  per-entry state transitions (`REVERSED` is terminal; `SUCCESS` only transitions to `REVERSED`).
  """
  @spec upsert_duplicate_event!(Ecto.Repo.t(), String.t(), map()) :: :ok
  def upsert_duplicate_event!(repo, mch_order_id, event_map)
      when is_binary(mch_order_id) and is_map(event_map) do
    now = SystemsClock.utc_now()
    incoming = stringify_map(event_map)
    event_provider_id = incoming["provider_order_id"]

    case lock_by_mch_order_id(repo, mch_order_id) do
      {:ok, order} ->
        events = order.duplicate_events

        updated =
          if non_empty_binary?(event_provider_id) do
            case Enum.find_index(events, &(&1["provider_order_id"] == event_provider_id)) do
              nil ->
                events ++ [incoming]

              idx ->
                List.update_at(events, idx, &merge_duplicate_entry(&1, incoming))
            end
          else
            if Enum.member?(events, incoming), do: events, else: events ++ [incoming]
          end

        Ecto.Adapters.SQL.query!(
          repo,
          """
          UPDATE billing_m2square_orders
          SET duplicate_events = $2::jsonb,
              updated_at = $3
          WHERE mch_order_id = $1
          """,
          [mch_order_id, updated, now]
        )

        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @doc "Alias for `upsert_duplicate_event!/3`."
  @spec append_duplicate_event!(Ecto.Repo.t(), String.t(), map()) :: :ok
  def append_duplicate_event!(repo, mch_order_id, event_map),
    do: upsert_duplicate_event!(repo, mch_order_id, event_map)

  defp merge_duplicate_entry(existing, incoming) do
    existing_status = existing["order_status"]
    incoming_status = incoming["order_status"]

    next_status =
      cond do
        existing_status == "REVERSED" -> "REVERSED"
        incoming_status == "REVERSED" -> "REVERSED"
        existing_status == "SUCCESS" -> "SUCCESS"
        incoming_status == "SUCCESS" -> "SUCCESS"
        is_binary(incoming_status) -> incoming_status
        true -> existing_status
      end

    existing_settled? = existing_status in ["SUCCESS", "REVERSED"]
    incoming_settled? = incoming_status in ["SUCCESS", "REVERSED"]

    {amount, real_amount, mch_fee, bank_id, paid_at} =
      cond do
        not existing_settled? and incoming_settled? ->
          {
            non_empty_or(incoming["amount"], existing["amount"]),
            non_empty_string(incoming["real_amount"]),
            non_empty_string(incoming["mch_fee"]),
            non_empty_or(incoming["bank_id"], existing["bank_id"]),
            non_empty_string(incoming["paid_at"])
          }

        existing_settled? and incoming_settled? ->
          settled_real_amount =
            if existing_status == "REVERSED" and incoming_status == "SUCCESS" and
                 is_nil(existing["paid_at"]) do
              non_empty_or(incoming["real_amount"], existing["real_amount"])
            else
              non_empty_or(existing["real_amount"], incoming["real_amount"])
            end

          {
            non_empty_or(existing["amount"], incoming["amount"]),
            settled_real_amount,
            non_empty_or(existing["mch_fee"], incoming["mch_fee"]),
            non_empty_or(existing["bank_id"], incoming["bank_id"]),
            non_empty_or(existing["paid_at"], incoming["paid_at"])
          }

        existing_settled? ->
          {
            non_empty_string(existing["amount"]),
            non_empty_string(existing["real_amount"]),
            non_empty_string(existing["mch_fee"]),
            non_empty_string(existing["bank_id"]),
            non_empty_string(existing["paid_at"])
          }

        true ->
          {
            non_empty_or(existing["amount"], incoming["amount"]),
            nil,
            nil,
            non_empty_or(existing["bank_id"], incoming["bank_id"]),
            nil
          }
      end

    %{
      "mch_order_id" => existing["mch_order_id"] || incoming["mch_order_id"],
      "suffix" => existing["suffix"] || incoming["suffix"],
      "provider_order_id" => existing["provider_order_id"] || incoming["provider_order_id"],
      "kind" => existing["kind"] || incoming["kind"],
      "order_status" => next_status,
      "amount" => amount,
      "real_amount" => real_amount,
      "mch_fee" => mch_fee,
      "currency" => existing["currency"] || incoming["currency"],
      "bank_id" => bank_id,
      "paid_at" => paid_at,
      "reversed_at" =>
        if(next_status == "REVERSED",
          do: non_empty_or(existing["reversed_at"], incoming["reversed_at"]),
          else: nil
        ),
      "recorded_at" => existing["recorded_at"] || incoming["recorded_at"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp non_empty_string(v) when is_binary(v) and v != "", do: v
  defp non_empty_string(_), do: nil

  defp non_empty_or(primary, _fallback) when is_binary(primary) and primary != "", do: primary
  defp non_empty_or(_primary, fallback), do: non_empty_string(fallback)

  @doc "Finds recent active (`creating` or `open`) orders for a `(billing_account_id, target_slot)` within 1 hour."
  @spec recent_pending_for_slot(Ecto.Repo.t(), String.t(), String.t(), DateTime.t()) :: [map()]
  def recent_pending_for_slot(repo, billing_account_id, target_slot, %DateTime{} = now) do
    cutoff = DateTime.add(now, -3600, :second)

    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT #{@select_columns}
      FROM billing_m2square_orders
      WHERE billing_account_id = $1
        AND target_slot = $2
        AND status IN ('creating', 'open')
        AND inserted_at > $3
      ORDER BY inserted_at DESC, mch_order_id DESC
      """,
      [billing_account_id, target_slot, cutoff]
    ).rows
    |> Enum.map(&row_to_order/1)
  end

  @doc "Returns whether another `paid` order already occupies `(billing_account_id, target_slot)`."
  @spec paid_slot_exists?(Ecto.Repo.t(), String.t(), String.t(), String.t() | nil) :: boolean()
  def paid_slot_exists?(repo, billing_account_id, target_slot, exclude_mch_order_id \\ nil) do
    {sql, params} =
      if is_binary(exclude_mch_order_id) do
        {"""
         SELECT 1 FROM billing_m2square_orders
         WHERE billing_account_id = $1 AND target_slot = $2 AND status = 'paid' AND mch_order_id <> $3
         LIMIT 1
         """, [billing_account_id, target_slot, exclude_mch_order_id]}
      else
        {"""
         SELECT 1 FROM billing_m2square_orders
         WHERE billing_account_id = $1 AND target_slot = $2 AND status = 'paid'
         LIMIT 1
         """, [billing_account_id, target_slot]}
      end

    Ecto.Adapters.SQL.query!(repo, sql, params).rows != []
  end

  @doc "Marks an order as `paid` with subscription/cycle attribution and settlement details."
  @spec mark_paid!(Ecto.Repo.t(), String.t(), map()) :: :ok
  def mark_paid!(repo, mch_order_id, attrs) when is_map(attrs) do
    now = Map.get(attrs, :paid_at) || SystemsClock.utc_now()

    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET status = 'paid',
          provider_order_id = COALESCE(provider_order_id, $2),
          subscription_id = $3,
          cycle_id = $4,
          real_amount = COALESCE($5, real_amount),
          mch_fee = COALESCE($6, mch_fee),
          bank_id = COALESCE($7, bank_id),
          paid_at = COALESCE(paid_at, $8),
          updated_at = $8
      WHERE mch_order_id = $1
      """,
      [
        mch_order_id,
        attrs[:provider_order_id],
        attrs[:subscription_id],
        attrs[:cycle_id],
        attrs[:real_amount],
        attrs[:mch_fee],
        attrs[:bank_id],
        now
      ]
    )

    :ok
  end

  @doc "Marks an order as `conflict_paid` without granting seats."
  @spec mark_conflict_paid!(Ecto.Repo.t(), String.t(), map()) :: :ok
  def mark_conflict_paid!(repo, mch_order_id, attrs) when is_map(attrs) do
    now = Map.get(attrs, :paid_at) || SystemsClock.utc_now()

    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET status = 'conflict_paid',
          provider_order_id = COALESCE(provider_order_id, $2),
          real_amount = COALESCE($3, real_amount),
          mch_fee = COALESCE($4, mch_fee),
          bank_id = COALESCE($5, bank_id),
          paid_at = COALESCE(paid_at, $6),
          updated_at = $6
      WHERE mch_order_id = $1
      """,
      [
        mch_order_id,
        attrs[:provider_order_id],
        attrs[:real_amount],
        attrs[:mch_fee],
        attrs[:bank_id],
        now
      ]
    )

    :ok
  end

  @doc "Marks an order as `reversed` (terminal)."
  @spec mark_reversed!(Ecto.Repo.t(), String.t(), String.t() | nil, DateTime.t()) :: :ok
  def mark_reversed!(repo, mch_order_id, provider_order_id, %DateTime{} = now) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET status = 'reversed',
          provider_order_id = COALESCE(provider_order_id, $2),
          reversed_at = COALESCE(reversed_at, $3),
          updated_at = $3
      WHERE mch_order_id = $1
      """,
      [mch_order_id, provider_order_id, now]
    )

    :ok
  end

  @doc "Atomically marks an order `reversed` and persists durable offline `refund_metadata`."
  @spec mark_offline_refunded!(Ecto.Repo.t(), String.t(), String.t() | nil, map(), DateTime.t()) ::
          :ok
  def mark_offline_refunded!(
        repo,
        mch_order_id,
        provider_order_id,
        refund_meta,
        %DateTime{} = now
      )
      when is_map(refund_meta) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET status = 'reversed',
          provider_order_id = COALESCE(provider_order_id, $2),
          reversed_at = COALESCE(reversed_at, $3),
          refund_metadata = COALESCE(refund_metadata, $4::jsonb),
          updated_at = $3
      WHERE mch_order_id = $1
      """,
      [mch_order_id, provider_order_id, now, stringify_map(refund_meta)]
    )

    :ok
  end

  @doc "Backfills `refund_metadata` on an already-reversed order when absent."
  @spec backfill_refund_metadata!(Ecto.Repo.t(), String.t(), map(), DateTime.t()) :: :ok
  def backfill_refund_metadata!(repo, mch_order_id, refund_meta, %DateTime{} = now)
      when is_map(refund_meta) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_m2square_orders
      SET refund_metadata = COALESCE(refund_metadata, $2::jsonb),
          updated_at = $3
      WHERE mch_order_id = $1
        AND refund_metadata IS NULL
      """,
      [mch_order_id, stringify_map(refund_meta), now]
    )

    :ok
  end

  @doc "Backfills optional fee metadata on an already-paid order without altering status or attribution."
  @spec backfill_paid_metadata!(Ecto.Repo.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok
  def backfill_paid_metadata!(repo, mch_order_id, mch_fee, bank_id) do
    if is_binary(mch_fee) or is_binary(bank_id) do
      Ecto.Adapters.SQL.query!(
        repo,
        """
        UPDATE billing_m2square_orders
        SET mch_fee = COALESCE(mch_fee, $2),
            bank_id = COALESCE(bank_id, $3),
            updated_at = $4
        WHERE mch_order_id = $1
        """,
        [mch_order_id, mch_fee, bank_id, SystemsClock.utc_now()]
      )
    end

    :ok
  end

  @doc "Lists orders requiring operator reconciliation (`conflict_paid`, `quarantined`, non-empty `duplicate_events`, or stale `creating`/`open`)."
  @spec list_for_reconciliation(Ecto.Repo.t(), keyword()) :: [map()]
  def list_for_reconciliation(repo, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    stale_seconds = opts |> Keyword.get(:stale_seconds, 3600) |> max(0)
    stale_before = DateTime.add(SystemsClock.utc_now(), -stale_seconds, :second)

    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT #{@select_columns}
      FROM billing_m2square_orders
      WHERE status IN ('conflict_paid', 'quarantined')
         OR jsonb_array_length(COALESCE(duplicate_events, '[]'::jsonb)) > 0
         OR (status IN ('creating', 'open') AND inserted_at <= $1)
      ORDER BY inserted_at DESC, mch_order_id DESC
      LIMIT $2 OFFSET $3
      """,
      [stale_before, limit, offset]
    ).rows
    |> Enum.map(&row_to_order/1)
  end

  @doc """
  Lists settled/financial M2square orders (`paid`, `reversed`, `conflict_paid`, or
  non-empty `duplicate_events`) ordered deterministically by `(inserted_at ASC, mch_order_id ASC)`
  with optional currency, time-window, and cursor pagination.

  Note on time basis: `:from`, `:to`, and `:after_cursor` filter and paginate by order
  creation time (`inserted_at`, order-ledger view). Each returned entry also carries
  `paid_at` and `reversed_at` for cash-basis / settlement-period accounting.
  """
  @spec list_ledger_entries(Ecto.Repo.t(), keyword()) :: %{
          entries: [map()],
          next_cursor: String.t() | nil
        }
  def list_ledger_entries(repo, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)

    {clauses, params} =
      {[
         "(status IN ('paid', 'reversed', 'conflict_paid') OR jsonb_array_length(COALESCE(duplicate_events, '[]'::jsonb)) > 0)"
       ], []}

    {clauses, params} =
      case Keyword.get(opts, :currency) do
        ccy when is_binary(ccy) and ccy != "" ->
          idx = length(params) + 1
          {clauses ++ ["currency = $#{idx}"], params ++ [String.upcase(String.trim(ccy))]}

        _ ->
          {clauses, params}
      end

    {clauses, params} =
      case Keyword.get(opts, :from) do
        %DateTime{} = from_dt ->
          idx = length(params) + 1
          {clauses ++ ["inserted_at >= $#{idx}"], params ++ [from_dt]}

        _ ->
          {clauses, params}
      end

    {clauses, params} =
      case Keyword.get(opts, :to) do
        %DateTime{} = to_dt ->
          idx = length(params) + 1
          {clauses ++ ["inserted_at <= $#{idx}"], params ++ [to_dt]}

        _ ->
          {clauses, params}
      end

    {clauses, params} =
      case parse_cursor(Keyword.get(opts, :after_cursor)) do
        {:ok, cursor_dt, cursor_id} ->
          idx1 = length(params) + 1
          idx2 = idx1 + 1

          {clauses ++ ["(inserted_at, mch_order_id) > ($#{idx1}, $#{idx2})"],
           params ++ [cursor_dt, cursor_id]}

        :none ->
          {clauses, params}
      end

    limit_idx = length(params) + 1

    sql = """
    SELECT #{@select_columns}
    FROM billing_m2square_orders
    WHERE #{Enum.join(clauses, " AND ")}
    ORDER BY inserted_at ASC, mch_order_id ASC
    LIMIT $#{limit_idx}
    """

    rows =
      Ecto.Adapters.SQL.query!(repo, sql, params ++ [limit + 1]).rows
      |> Enum.map(&row_to_order/1)

    if length(rows) > limit do
      entries = Enum.take(rows, limit)
      last = List.last(entries)

      %{
        entries: entries,
        next_cursor: DateTime.to_iso8601(last.inserted_at) <> "|" <> last.mch_order_id
      }
    else
      %{entries: rows, next_cursor: nil}
    end
  end

  defp parse_cursor(%{inserted_at: %DateTime{} = dt, mch_order_id: id})
       when is_binary(id) and id != "" do
    {:ok, dt, id}
  end

  defp parse_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, "|", parts: 2) do
      [iso, id] when id != "" ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> {:ok, dt, id}
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp parse_cursor(_), do: :none

  defp sanitize_signup_snapshot(nil), do: nil

  defp sanitize_signup_snapshot(%{} = map) do
    map
    |> stringify_map()
    |> Map.take(@signup_snapshot_keys)
  end

  defp sanitize_signup_snapshot(_), do: nil

  defp fetch_attr(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp fetch_attr!(attrs, key) do
    case fetch_attr(attrs, key) do
      nil -> raise ArgumentError, "missing required order attribute: #{inspect(key)}"
      value -> value
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) and not is_struct(v) -> {to_string(k), stringify_map(v)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp row_to_order([
         mch_order_id,
         provider_order_id,
         billing_account_id,
         product_owner_id,
         kind,
         target_slot,
         country,
         payment_type,
         currency,
         display_currency,
         teams_seats,
         usd_net_minor,
         locked_amount,
         fx_rate,
         fx_source,
         fee_rate,
         markup_rate,
         signup_snapshot,
         checkout_url,
         status,
         real_amount,
         mch_fee,
         bank_id,
         duplicate_events,
         subscription_id,
         cycle_id,
         paid_at,
         reversed_at,
         refund_metadata,
         notification_claimed_at,
         notified_at,
         last_checked_at,
         inserted_at,
         updated_at
       ]) do
    %{
      mch_order_id: mch_order_id,
      provider_order_id: provider_order_id,
      billing_account_id: billing_account_id,
      product_owner_id: product_owner_id,
      kind: kind,
      target_slot: target_slot,
      country: country,
      payment_type: payment_type,
      currency: currency,
      display_currency: display_currency,
      teams_seats: teams_seats,
      usd_net_minor: usd_net_minor,
      locked_amount: locked_amount,
      fx_rate: fx_rate,
      fx_source: fx_source,
      fee_rate: fee_rate,
      markup_rate: markup_rate,
      signup_snapshot: signup_snapshot,
      checkout_url: checkout_url,
      status: status,
      real_amount: real_amount,
      mch_fee: mch_fee,
      bank_id: bank_id,
      duplicate_events: duplicate_events || [],
      subscription_id: subscription_id,
      cycle_id: cycle_id,
      paid_at: paid_at,
      reversed_at: reversed_at,
      refund_metadata: refund_metadata,
      notification_claimed_at: notification_claimed_at,
      notified_at: notified_at,
      last_checked_at: last_checked_at,
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end
end
