defmodule BridgeForTeams.M2square.Ops do
  @moduledoc """
  Pure Elixir operational reconciliation, ledger export, conflict inspection, and
  offline-refund helpers for M2square Teams orders (invoked via `bin/comma rpc`
  or tests, with no background polling).
  """

  alias BillingCommerce.PaidCycles
  alias BridgeForTeams.{Observability, Orgs, PaidSignup}
  alias BridgeForTeams.M2square.Orders

  @doc """
  Triggers an active upstream `verifyStatus` reconciliation for `mch_order_id`.
  """
  @spec reconcile_order(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_order(mch_order_id, opts \\ []) when is_binary(mch_order_id) and is_list(opts) do
    repo = billing_repo()

    case Orders.get_by_mch_order_id(repo, mch_order_id) do
      {:ok, order} ->
        provider_order_id = Keyword.get(opts, :provider_order_id) || order.provider_order_id

        if is_binary(provider_order_id) and provider_order_id != "" do
          PaidSignup.reconcile_m2square_order(
            mch_order_id,
            Keyword.put(opts, :provider_order_id, provider_order_id)
          )
        else
          {:error, :missing_provider_order_id}
        end

      {:error, :not_found} ->
        {:error, :order_not_found}
    end
  end

  @doc """
  Records an offline full refund for a `paid` or `conflict_paid` M2square order.

  Acquires locks in strict `billing_accounts -> billing_m2square_orders` order,
  revokes the attributed payment source when `cycle_id != nil`, atomically marks
  the order `reversed` with durable `refund_metadata`, and projects an idempotent
  audit log entry when the organization exists.
  """
  @spec record_offline_refund(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def record_offline_refund(mch_order_id, operator_label, reason)
      when is_binary(mch_order_id) and is_binary(operator_label) and is_binary(reason) do
    operator = String.trim(operator_label)
    trimmed_reason = String.trim(reason)

    if operator == "" or trimmed_reason == "" do
      {:error, :invalid_refund_metadata}
    else
      do_record_offline_refund(mch_order_id, operator, trimmed_reason)
    end
  end

  def record_offline_refund(_, _, _), do: {:error, :invalid_refund_metadata}

  defp do_record_offline_refund(mch_order_id, operator, reason) do
    repo = billing_repo()
    now = SystemsClock.utc_now()

    tx_result =
      repo.transaction(fn ->
        billing_account_id =
          case Orders.get_by_mch_order_id(repo, mch_order_id) do
            {:ok, %{billing_account_id: account_id}} -> account_id
            {:error, :not_found} -> repo.rollback(:order_not_found)
          end

        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
          [billing_account_id]
        )

        order =
          case Orders.lock_by_mch_order_id(repo, mch_order_id) do
            {:ok, locked} -> locked
            {:error, :not_found} -> repo.rollback(:order_not_found)
          end

        refund_meta = %{
          "mch_order_id" => mch_order_id,
          "cycle_id" => order.cycle_id,
          "operator" => operator,
          "reason" => reason,
          "offline_refund" => true,
          "recorded_at" => DateTime.to_iso8601(now)
        }

        cond do
          order.status == "reversed" ->
            if is_nil(order.refund_metadata) do
              Orders.backfill_refund_metadata!(repo, mch_order_id, refund_meta, now)
            end

            %{
              idempotent: true,
              mch_order_id: mch_order_id,
              product_owner_id: order.product_owner_id,
              cycle_id: order.cycle_id,
              refund_metadata: order.refund_metadata || refund_meta
            }

          order.status not in ["paid", "conflict_paid"] ->
            repo.rollback(:order_not_refundable)

          true ->
            if is_binary(order.cycle_id) and order.cycle_id != "" do
              :ok =
                PaidCycles.revoke_payment_source!(
                  repo,
                  order.billing_account_id,
                  order.cycle_id,
                  "m2square:" <> mch_order_id,
                  %{
                    "reason" => reason,
                    "operator" => operator,
                    "offline_refund" => true
                  }
                )
            end

            Orders.mark_offline_refunded!(
              repo,
              mch_order_id,
              order.provider_order_id,
              refund_meta,
              now
            )

            %{
              idempotent: false,
              mch_order_id: mch_order_id,
              product_owner_id: order.product_owner_id,
              cycle_id: order.cycle_id,
              refund_metadata: refund_meta
            }
        end
      end)

    case tx_result do
      {:ok, result} ->
        case ensure_org_refund_audit(
               result.product_owner_id,
               mch_order_id,
               result.refund_metadata
             ) do
          :ok ->
            {:ok, Map.take(result, [:idempotent, :mch_order_id, :cycle_id, :refund_metadata])}

          {:error, :audit_log_failed} ->
            {:error, :audit_log_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists paged summaries of orders needing operator reconciliation (`conflict_paid`,
  `quarantined`, non-empty `duplicate_events`, or stale `creating`/`open`), including
  full `duplicate_events` and `refund_metadata`.
  """
  @spec list_orders_for_reconciliation(keyword()) :: [map()]
  def list_orders_for_reconciliation(opts \\ []) when is_list(opts) do
    billing_repo()
    |> Orders.list_for_reconciliation(opts)
    |> Enum.map(&format_reconciliation_order/1)
  end

  @doc """
  Exports settled financial M2square ledger entries (`paid`, `reversed`, `conflict_paid`,
  and orders with `duplicate_events`) by optional `:currency`, `:from`, `:to`, `:after_cursor`,
  and `:limit` (1..100).

  Note on time basis: `:from`, `:to`, and `:after_cursor` filter and sort by order
  creation time (`inserted_at`, order-ledger view). Each returned entry also includes
  `paid_at` and `reversed_at` for cash-basis / settlement-period accounting.
  """
  @spec export_ledger_entries(keyword()) :: %{entries: [map()], next_cursor: String.t() | nil}
  def export_ledger_entries(opts \\ []) when is_list(opts) do
    %{entries: orders, next_cursor: next_cursor} =
      Orders.list_ledger_entries(billing_repo(), opts)

    %{
      entries: Enum.map(orders, &format_ledger_entry/1),
      next_cursor: next_cursor
    }
  end

  @doc """
  Lists durable Stripe-vs-M2square period-overlap conflict records persisted on
  `m2square_term` subscriptions with stable keyset cursor pagination ordered by
  `(recorded_at ASC, invoice_id ASC)`.

  By default excludes conflicts marked resolved (`resolved == true`); pass
  `include_resolved: true` to include them. Supports optional `:billing_account_id`,
  `:invoice_id`, `:after_cursor` (`"<recorded_at>|<invoice_id>"`), and `:limit` (1..100).
  """
  @spec list_stripe_overlap_conflicts(keyword()) :: %{
          entries: [map()],
          next_cursor: String.t() | nil
        }
  def list_stripe_overlap_conflicts(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    include_resolved? = Keyword.get(opts, :include_resolved, false) == true

    {clauses, params} =
      {[
         "s.source_type = 'm2square_term'",
         "jsonb_array_length(COALESCE(s.source_metadata->'stripe_overlap_conflicts', '[]'::jsonb)) > 0"
       ], []}

    {clauses, params} =
      if include_resolved? do
        {clauses, params}
      else
        {clauses ++ ["COALESCE((conflict->>'resolved')::boolean, false) = false"], params}
      end

    {clauses, params} =
      case Keyword.get(opts, :billing_account_id) do
        id when is_binary(id) and id != "" ->
          idx = length(params) + 1
          {clauses ++ ["s.billing_account_id = $#{idx}"], params ++ [id]}

        _ ->
          {clauses, params}
      end

    {clauses, params} =
      case Keyword.get(opts, :invoice_id) do
        inv when is_binary(inv) and inv != "" ->
          idx = length(params) + 1
          {clauses ++ ["(conflict->>'invoice_id') = $#{idx}"], params ++ [inv]}

        _ ->
          {clauses, params}
      end

    {clauses, params} =
      case parse_overlap_cursor(Keyword.get(opts, :after_cursor)) do
        {:ok, cursor_recorded_at, cursor_invoice_id} ->
          idx1 = length(params) + 1
          idx2 = idx1 + 1

          {clauses ++
             ["((conflict->>'recorded_at'), (conflict->>'invoice_id')) > ($#{idx1}, $#{idx2})"],
           params ++ [cursor_recorded_at, cursor_invoice_id]}

        :none ->
          {clauses, params}
      end

    limit_idx = length(params) + 1
    where_sql = Enum.join(clauses, " AND ")

    rows =
      Ecto.Adapters.SQL.query!(
        billing_repo(),
        """
        SELECT conflict
        FROM billing_subscriptions s
        CROSS JOIN LATERAL jsonb_array_elements(
          COALESCE(s.source_metadata->'stripe_overlap_conflicts', '[]'::jsonb)
        ) AS conflict
        WHERE #{where_sql}
        ORDER BY (conflict->>'recorded_at') ASC, (conflict->>'invoice_id') ASC
        LIMIT $#{limit_idx}
        """,
        params ++ [limit + 1]
      ).rows
      |> Enum.map(fn [conflict] -> conflict end)

    {entries, next_cursor} =
      if length(rows) > limit do
        page = Enum.take(rows, limit)
        last = List.last(page)
        {page, "#{last["recorded_at"]}|#{last["invoice_id"]}"}
      else
        {rows, nil}
      end

    %{entries: entries, next_cursor: next_cursor}
  end

  @doc """
  Marks a persisted Stripe-vs-M2square period-overlap conflict as resolved under the
  account's `billing_accounts FOR UPDATE` lock.
  """
  @spec resolve_stripe_overlap_conflict(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_stripe_overlap_conflict(billing_account_id, invoice_id, operator_label, note)
      when is_binary(billing_account_id) and is_binary(invoice_id) and
             is_binary(operator_label) and is_binary(note) do
    account_id = String.trim(billing_account_id)
    inv_id = String.trim(invoice_id)
    operator = String.trim(operator_label)
    trimmed_note = String.trim(note)

    if account_id == "" or inv_id == "" or operator == "" or trimmed_note == "" do
      {:error, :invalid_resolution_metadata}
    else
      do_resolve_stripe_overlap_conflict(account_id, inv_id, operator, trimmed_note)
    end
  end

  def resolve_stripe_overlap_conflict(_, _, _, _), do: {:error, :invalid_resolution_metadata}

  defp do_resolve_stripe_overlap_conflict(billing_account_id, invoice_id, operator, note) do
    repo = billing_repo()
    now = SystemsClock.utc_now()
    now_iso = DateTime.to_iso8601(now)

    repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
        [billing_account_id]
      )

      subs =
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT id, source_metadata
          FROM billing_subscriptions
          WHERE billing_account_id = $1
            AND source_type = 'm2square_term'
          ORDER BY inserted_at ASC, id ASC
          FOR UPDATE
          """,
          [billing_account_id]
        ).rows

      found =
        Enum.find_value(subs, fn [sub_id, meta] ->
          meta = meta || %{}
          conflicts = Map.get(meta, "stripe_overlap_conflicts", [])

          if is_list(conflicts) and Enum.any?(conflicts, &(&1["invoice_id"] == invoice_id)) do
            {sub_id, meta, conflicts}
          end
        end)

      case found do
        nil ->
          repo.rollback(:conflict_not_found)

        {sub_id, meta, conflicts} ->
          existing = Enum.find(conflicts, &(&1["invoice_id"] == invoice_id))

          if existing["resolved"] == true do
            %{
              idempotent: true,
              billing_account_id: billing_account_id,
              invoice_id: invoice_id,
              conflict: existing
            }
          else
            resolved_entry =
              Map.merge(existing, %{
                "resolved" => true,
                "resolved_by" => operator,
                "resolution_note" => note,
                "resolved_at" => now_iso
              })

            updated_conflicts =
              Enum.map(conflicts, fn entry ->
                if entry["invoice_id"] == invoice_id, do: resolved_entry, else: entry
              end)

            updated_meta = Map.put(meta, "stripe_overlap_conflicts", updated_conflicts)

            Ecto.Adapters.SQL.query!(
              repo,
              """
              UPDATE billing_subscriptions
              SET source_metadata = $2,
                  updated_at = $3
              WHERE id = $1
              """,
              [sub_id, updated_meta, now]
            )

            %{
              idempotent: false,
              billing_account_id: billing_account_id,
              invoice_id: invoice_id,
              conflict: resolved_entry
            }
          end
      end
    end)
  end

  defp parse_overlap_cursor(cursor) when is_binary(cursor) and cursor != "" do
    case String.split(cursor, "|", parts: 2) do
      [recorded_at, invoice_id] when recorded_at != "" and invoice_id != "" ->
        {:ok, recorded_at, invoice_id}

      _ ->
        :none
    end
  end

  defp parse_overlap_cursor(_), do: :none

  defp format_reconciliation_order(order) do
    %{
      mch_order_id: order.mch_order_id,
      provider_order_id: order.provider_order_id,
      billing_account_id: order.billing_account_id,
      product_owner_id: order.product_owner_id,
      kind: order.kind,
      target_slot: order.target_slot,
      country: order.country,
      currency: order.currency,
      teams_seats: order.teams_seats,
      locked_amount: order.locked_amount,
      real_amount: order.real_amount,
      mch_fee: order.mch_fee,
      bank_id: order.bank_id,
      status: order.status,
      duplicate_event_count: length(order.duplicate_events),
      duplicate_events: order.duplicate_events,
      refund_metadata: order.refund_metadata,
      cycle_id: order.cycle_id,
      inserted_at: order.inserted_at,
      updated_at: order.updated_at
    }
  end

  defp format_ledger_entry(order) do
    %{
      mch_order_id: order.mch_order_id,
      provider_order_id: order.provider_order_id,
      billing_account_id: order.billing_account_id,
      product_owner_id: order.product_owner_id,
      kind: order.kind,
      target_slot: order.target_slot,
      country: order.country,
      currency: order.currency,
      display_currency: order.display_currency,
      teams_seats: order.teams_seats,
      usd_net_minor: order.usd_net_minor,
      locked_amount: order.locked_amount,
      real_amount: order.real_amount,
      mch_fee: order.mch_fee,
      bank_id: order.bank_id,
      status: order.status,
      subscription_id: order.subscription_id,
      cycle_id: order.cycle_id,
      paid_at: order.paid_at,
      reversed_at: order.reversed_at,
      refund_metadata: order.refund_metadata,
      duplicate_events: order.duplicate_events,
      inserted_at: order.inserted_at
    }
  end

  defp ensure_org_refund_audit(product_owner_id, mch_order_id, refund_meta) do
    case Orgs.get_org(product_owner_id) do
      {:ok, org} ->
        org_uuid = Ecto.UUID.dump!(org.id)

        case BridgeForTeams.Repo.transaction(fn ->
               Ecto.Adapters.SQL.query!(
                 BridgeForTeams.Repo,
                 "SELECT id FROM organizations WHERE id = $1 FOR UPDATE",
                 [org_uuid]
               )

               exists? =
                 Ecto.Adapters.SQL.query!(
                   BridgeForTeams.Repo,
                   """
                   SELECT 1 FROM audit_logs
                   WHERE org_id = $1
                     AND action = 'billing.m2square.offline_refund'
                     AND resource_id = $2
                   LIMIT 1
                   """,
                   [org_uuid, mch_order_id]
                 ).rows != []

               if exists? do
                 :ok
               else
                 case Observability.record_audit(%{
                        org_id: org.id,
                        actor_type: "system",
                        actor_label: refund_meta["operator"],
                        action: "billing.m2square.offline_refund",
                        target: "m2square_order:" <> mch_order_id,
                        resource_type: "billing_m2square_order",
                        resource_id: mch_order_id,
                        resource_label: mch_order_id,
                        result: "ok",
                        metadata: %{
                          "mch_order_id" => mch_order_id,
                          "cycle_id" => refund_meta["cycle_id"],
                          "operator" => refund_meta["operator"],
                          "reason" => refund_meta["reason"]
                        }
                      }) do
                   {:ok, _} -> :ok
                   {:error, _} -> BridgeForTeams.Repo.rollback(:audit_log_failed)
                 end
               end
             end) do
          {:ok, :ok} -> :ok
          {:error, :audit_log_failed} -> {:error, :audit_log_failed}
          {:error, _} -> {:error, :audit_log_failed}
        end

      _ ->
        :ok
    end
  end

  defp billing_repo do
    SystemsRuntime.get_env(:billing_commerce, :repo, BillingCore.Repo)
  end
end
