defmodule BillingCommerce.PaidCycles do
  @moduledoc "Payment-attributed issuance within the existing subscription credit cycles."

  alias BillingCore.{Credits, Metadata}
  alias BillingCommerce.PackageCatalog

  def record_invoice(subscription, package, invoice, payment, at) do
    repo = Application.fetch_env!(:billing_commerce, :repo)

    repo.transaction(fn ->
      lock_owner(repo, subscription.billing_account_id, subscription.id)

      cycles =
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT id, period_start, period_end, status, source_metadata
          FROM billing_subscription_cycles
          WHERE subscription_id = $1 AND period_start < $3 AND period_end > $2
          ORDER BY period_start, id FOR UPDATE
          """,
          [subscription.id, payment.valid_from, payment.expires_at]
        ).rows

      if cycles == [], do: repo.rollback(:stripe_paid_cycle_missing)

      for [id, starts, ends, status, raw] <- cycles do
        metadata = Metadata.object(raw)
        sources = metadata["payment_sources"] || %{}

        if Map.has_key?(sources, invoice) do
          :ok
        else
          if status == "issued" and sources == %{},
            do: repo.rollback({:legacy_payment_attribution_missing, id})

          prior_tier = Map.get(payment, :prior_tier)

          prior_invoice = Map.get(payment, :prior_invoice)

          previous_source =
            sources
            |> Map.values()
            |> Enum.filter(&(&1["effective_at"] <= DateTime.to_iso8601(payment.valid_from)))
            |> Enum.max_by(&{&1["effective_at"], &1["target_tier"]}, fn -> nil end)

          if is_integer(prior_tier) and
               (sources == %{} or
                  (is_binary(prior_invoice) and not Map.has_key?(sources, prior_invoice)) or
                  is_nil(previous_source) or previous_source["target_tier"] != prior_tier),
             do: repo.rollback(:stripe_prior_payment_not_recorded)

          previous_tier = prior_tier || metadata["paid_tier_credits"] || 0

          effective =
            if DateTime.compare(payment.valid_from, starts) == :gt,
              do: payment.valid_from,
              else: starts

          covered_end =
            if DateTime.compare(payment.expires_at, ends) == :lt,
              do: payment.expires_at,
              else: ends

          remaining = max(DateTime.diff(covered_end, effective, :second), 0)

          nominal_end =
            case metadata["nominal_end"] do
              nil -> ends
              iso -> elem(DateTime.from_iso8601(iso), 1)
            end

          duration = DateTime.diff(nominal_end, starts, :second)

          covered_credits =
            div(
              package.grant_credits * max(DateTime.diff(covered_end, starts, :second), 0),
              duration
            )

          increment =
            if is_integer(prior_tier) or status == "issued",
              do: div(max(package.grant_credits - previous_tier, 0) * remaining, duration),
              else: covered_credits

          source = %{
            "credits" => increment,
            "previous_tier" => prior_tier,
            "target_tier" => package.grant_credits,
            "payment_intent_id" => payment.payment_intent_id,
            "state" => payment_state(payment),
            "disputes" => payment.disputes,
            "package_code" => package.package_code,
            "package_version" => package.version,
            "effective_at" => DateTime.to_iso8601(payment.valid_from),
            "coverage_start" => DateTime.to_iso8601(payment.valid_from),
            "coverage_end" => DateTime.to_iso8601(payment.expires_at),
            "paid_at" => DateTime.to_iso8601(at)
          }

          metadata =
            metadata
            |> Map.put("payment_sources", Map.put(sources, invoice, source))
            |> Map.put("paid_tier_credits", package.grant_credits)

          Ecto.Adapters.SQL.query!(
            repo,
            "UPDATE billing_subscription_cycles SET source_metadata = $2 WHERE id = $1",
            [id, metadata]
          )
        end

        if DateTime.compare(starts, at) != :gt do
          issue_payment_sources(repo, subscription.billing_account_id, id, starts, ends)
        end
      end

      %{invoice_id: invoice, cycle_count: length(cycles)}
    end)
  end

  def issue(cycle) do
    repo = Application.fetch_env!(:billing_commerce, :repo)

    repo.transaction(fn ->
      lock_owner(repo, cycle.billing_account_id, cycle.subscription_id)

      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT id FROM billing_subscription_cycles WHERE id = $1 FOR UPDATE",
        [cycle.id]
      )

      issue_payment_sources(
        repo,
        cycle.billing_account_id,
        cycle.id,
        cycle.valid_from,
        cycle.expires_at
      )

      %{cycle: %{cycle | status: "issued"}, grant: nil, idempotent: false}
    end)
  end

  def issue_payment_sources(repo, account, id, starts, ends) do
    [[raw]] =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT source_metadata FROM billing_subscription_cycles WHERE id = $1",
        [id]
      ).rows

    sources = Metadata.object(raw)["payment_sources"] || %{}

    Enum.each(sources, fn {invoice, source} ->
      if source["state"] == "paid" and source["credits"] > 0 do
        {:ok, package} =
          PackageCatalog.get_package_version(%{
            repo: repo,
            package_code: source["package_code"],
            version: source["package_version"]
          })

        {:ok, _grant} =
          Credits.issue_grant(%{
            repo: repo,
            billing_account_id: account,
            credits: source["credits"],
            valid_from: starts,
            expires_at: ends,
            source_type: "subscription_cycle",
            source_id: id,
            source_event_id: invoice,
            idempotency_key: "stripe:cycle:#{id}:#{invoice}",
            package_code: package.package_code,
            package_version: package.version,
            package_snapshot: PackageCatalog.package_snapshot(package),
            policy_snapshot: package.usage_policy,
            metadata: %{
              "cycle_id" => id,
              "stripe_invoice_id" => invoice,
              "stripe_payment_intent_id" => source["payment_intent_id"]
            }
          })
      end
    end)

    Ecto.Adapters.SQL.query!(
      repo,
      "UPDATE billing_subscription_cycles SET status = 'issued', updated_at = now() WHERE id = $1",
      [id]
    )
  end

  defp payment_state(payment) do
    cond do
      payment.fully_refunded or "lost" in Map.values(payment.disputes) ->
        "refunded"

      Enum.any?(Map.values(payment.disputes), &(&1 not in ["won", "warning_closed"])) ->
        "disputed"

      true ->
        "paid"
    end
  end

  defp lock_owner(repo, account, subscription) do
    Ecto.Adapters.SQL.query!(repo, "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE", [
      account
    ])

    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT id FROM billing_subscriptions WHERE id = $1 FOR UPDATE",
      [subscription]
    )
  end
end
