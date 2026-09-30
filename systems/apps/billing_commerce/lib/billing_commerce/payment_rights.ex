defmodule BillingCommerce.PaymentRights do
  @moduledoc "Compensate only grants and unissued allocations owned by one Stripe payment."

  alias BillingCore.{Credits, Metadata}

  def apply(payment_intent_id, event_id, read_provider) do
    repo = Application.fetch_env!(:billing_commerce, :repo)
    path = "$.*.payment_intent_id ? (@ == #{Jason.encode!(payment_intent_id)})"

    accounts =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT billing_account_id FROM billing_one_time_purchases WHERE provider_payment_intent_id = $1
        UNION SELECT billing_account_id FROM credit_grants WHERE metadata->>'stripe_payment_intent_id' = $1
        UNION SELECT billing_account_id FROM billing_subscription_cycles WHERE source_metadata->'payment_sources' @? ($2::text)::jsonpath
        """,
        [payment_intent_id, path]
      ).rows

    case accounts do
      [[account]] ->
        repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
            [account]
          )

          Ecto.Adapters.SQL.query!(
            repo,
            "SELECT id FROM billing_subscriptions WHERE billing_account_id = $1 ORDER BY id FOR UPDATE",
            [account]
          )

          cycles =
            Ecto.Adapters.SQL.query!(
              repo,
              """
              SELECT id, source_metadata, period_start, period_end FROM billing_subscription_cycles
              WHERE billing_account_id = $1 AND source_metadata->'payment_sources' @? ($2::text)::jsonpath
              ORDER BY period_start, id FOR UPDATE
              """,
              [account, path]
            ).rows

          grants =
            Ecto.Adapters.SQL.query!(
              repo,
              """
              SELECT id FROM credit_grants WHERE billing_account_id = $1 AND metadata->>'stripe_payment_intent_id' = $2
              ORDER BY id
              """,
              [account, payment_intent_id]
            ).rows

          # Legacy purchases have their authoritative grant link even before metadata repair.
          purchase_grants =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT credit_grant_id FROM billing_one_time_purchases WHERE billing_account_id = $1 AND provider_payment_intent_id = $2 FOR UPDATE",
              [account, payment_intent_id]
            ).rows

          {:ok, action} =
            case read_provider.() do
              {:ok, action} -> {:ok, action}
              {:error, reason} -> repo.rollback(reason)
            end

          results =
            Enum.map(Enum.uniq(grants ++ purchase_grants), fn [grant] ->
              case Credits.payment_rights(%{
                     repo: repo,
                     billing_account_id: account,
                     credit_grant_id: grant,
                     payment_action: action,
                     source_event_id: event_id
                   }) do
                {:ok, result} -> result
                {:error, reason} -> repo.rollback(reason)
              end
            end)

          Enum.each(cycles, fn [id, raw, _starts, _ends] ->
            metadata = Metadata.object(raw)

            sources =
              Map.new(metadata["payment_sources"], fn {invoice, source} ->
                if source["payment_intent_id"] == payment_intent_id,
                  do: {invoice, update_source(source, action)},
                  else: {invoice, source}
              end)

            # Preserve issuance. Restoring a payment cannot turn an issued cycle into a new base allocation.
            Ecto.Adapters.SQL.query!(
              repo,
              """
              UPDATE billing_subscription_cycles SET source_metadata = $2,
                updated_at = now()
              WHERE id = $1
              """,
              [id, Map.put(metadata, "payment_sources", sources)]
            )
          end)

          if action.type == :dispute and action.status in ["won", "warning_closed"] do
            Enum.each(cycles, fn [id, _, starts, ends] ->
              now = DateTime.utc_now()

              if DateTime.compare(starts, now) != :gt and DateTime.compare(ends, now) == :gt,
                do:
                  BillingCommerce.PaidCycles.issue_payment_sources(
                    repo,
                    account,
                    id,
                    starts,
                    ends
                  )
            end)
          end

          update_purchase(repo, account, payment_intent_id, action)
          %{grants: results, cycles: length(cycles), action: action}
        end)

      [] ->
        {:error, :stripe_payment_not_recorded}

      _ ->
        {:error, :stripe_payment_owner_conflict}
    end
  end

  defp update_source(source, %{type: :refund, full: true} = action),
    do: source |> Map.put("state", "refunded") |> Map.put("refund", action)

  defp update_source(source, %{type: :refund} = action), do: Map.put(source, "refund", action)

  defp update_source(source, %{type: :dispute, id: id, status: status}) do
    disputes = Map.put(source["disputes"] || %{}, id, status)

    state =
      cond do
        source["state"] == "refunded" or "lost" in Map.values(disputes) -> "refunded"
        Enum.any?(Map.values(disputes), &(&1 not in ["won", "warning_closed"])) -> "disputed"
        true -> "paid"
      end

    source |> Map.put("disputes", disputes) |> Map.put("state", state)
  end

  defp update_purchase(repo, account, pi, %{type: :refund} = action) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_one_time_purchases SET refunded_amount_minor = GREATEST(refunded_amount_minor, $3),
        refunded_at = now(), status = CASE WHEN $4 THEN 'refunded' ELSE 'partially_refunded' END, updated_at = now()
      WHERE billing_account_id = $1 AND provider_payment_intent_id = $2
      """,
      [account, pi, action.amount, action.full]
    )
  end

  defp update_purchase(_, _, _, _), do: :ok
end
