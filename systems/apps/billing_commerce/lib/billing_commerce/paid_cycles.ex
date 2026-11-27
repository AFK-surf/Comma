defmodule BillingCommerce.PaidCycles do
  @moduledoc """
  Payment-attributed issuance within the existing subscription credit cycles.

  A payment comes from one provider (`stripe`, `apple` or `google`). Stripe
  sources keep their original keys and metadata. Other providers record
  `provider` and `payment_id`, and their grants carry `provider_payment_id`.

  A replacement (`payment.replaces`, `%{at: time, payment_id: old}` or
  `%{at: time, provider: provider}`) is a plan
  change that starts a new store period at that time. It ends the old payment's
  cycle there, marks that payment's later unissued cycles `replaced`, and
  subtracts the unused share of the old tier from the first new cycle.
  Modeled in `tla/billing/StripeCredits.tla`.
  """

  alias BillingCore.{Credits, Metadata}
  alias BillingCommerce.PackageCatalog

  def record_invoice(subscription, package, invoice, payment, at) do
    repo = SystemsRuntime.fetch_env!(:billing_commerce, :repo)

    provider = Map.get(payment, :provider, "stripe")
    payment_id = Map.get(payment, :payment_id) || Map.get(payment, :payment_intent_id)

    repo.transaction(fn ->
      lock_owner(repo, subscription.billing_account_id, subscription.id)

      offset =
        case Map.get(payment, :replaces) do
          %{at: %DateTime{} = replace_at, payment_id: old} ->
            replace!(repo, subscription.id, replace_at, old)

          %{at: %DateTime{} = replace_at, provider: replace_provider} ->
            case find_replaced_payment(
                   repo,
                   subscription.id,
                   replace_at,
                   replace_provider,
                   payment_id
                 ) do
              nil -> 0
              old -> replace!(repo, subscription.id, replace_at, old)
            end

          nil ->
            0
        end

      cycles =
        case Map.get(payment, :cycle_ids) do
          cycle_ids when is_list(cycle_ids) and cycle_ids != [] ->
            Ecto.Adapters.SQL.query!(
              repo,
              """
              SELECT id, period_start, period_end, status, source_metadata
              FROM billing_subscription_cycles
              WHERE subscription_id = $1 AND id = ANY($2::text[]) AND status <> 'replaced'
              ORDER BY period_start, id FOR UPDATE
              """,
              [subscription.id, cycle_ids]
            ).rows

          nil ->
            Ecto.Adapters.SQL.query!(
              repo,
              """
              SELECT id, period_start, period_end, status, source_metadata
              FROM billing_subscription_cycles
              WHERE subscription_id = $1 AND period_start < $3 AND period_end > $2
                AND status <> 'replaced'
              ORDER BY period_start, id FOR UPDATE
              """,
              [subscription.id, payment.valid_from, payment.expires_at]
            ).rows

          [] ->
            []
        end

      if cycles == [], do: repo.rollback(:stripe_paid_cycle_missing)

      first_cycle = cycles |> hd() |> hd()

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

          cycle_offset = if id == first_cycle, do: offset, else: 0

          source =
            %{
              "credits" => max(increment - cycle_offset, 0),
              "previous_tier" => prior_tier,
              "target_tier" => package.grant_credits,
              "state" => payment_state(payment),
              "disputes" => payment.disputes,
              "package_code" => package.package_code,
              "package_version" => package.version,
              "effective_at" => DateTime.to_iso8601(payment.valid_from),
              "coverage_start" => DateTime.to_iso8601(payment.valid_from),
              "coverage_end" => DateTime.to_iso8601(payment.expires_at),
              "paid_at" => DateTime.to_iso8601(at)
            }
            |> Map.merge(payment_identity(provider, payment_id))
            |> then(
              &if(cycle_offset > 0, do: Map.put(&1, "replacement_offset", cycle_offset), else: &1)
            )

          source =
            case payment[:teams_seats] do
              seats when is_integer(seats) and seats > 0 ->
                Map.put(source, "teams_seats", seats)

              _ ->
                source
            end

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
    repo = SystemsRuntime.fetch_env!(:billing_commerce, :repo)

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
            idempotency_key: "#{source["provider"] || "stripe"}:cycle:#{id}:#{invoice}",
            package_code: package.package_code,
            package_version: package.version,
            package_snapshot: PackageCatalog.package_snapshot(package),
            policy_snapshot: package.usage_policy,
            metadata: grant_metadata(id, invoice, source)
          })
      end
    end)

    Ecto.Adapters.SQL.query!(
      repo,
      "UPDATE billing_subscription_cycles SET status = 'issued', updated_at = now() WHERE id = $1",
      [id]
    )
  end

  @spec revoke_payment_source!(Ecto.Repo.t(), binary(), binary(), binary(), map()) ::
          :ok | {:error, :payment_source_not_found}
  def revoke_payment_source!(
        repo,
        billing_account_id,
        cycle_id,
        allocation_key,
        refund_meta \\ %{}
      )
      when is_binary(billing_account_id) and is_binary(cycle_id) and is_binary(allocation_key) and
             is_map(refund_meta) do
    if repo.in_transaction?() do
      do_revoke_payment_source!(repo, billing_account_id, cycle_id, allocation_key, refund_meta)
    else
      case repo.transaction(fn ->
             do_revoke_payment_source!(
               repo,
               billing_account_id,
               cycle_id,
               allocation_key,
               refund_meta
             )
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_revoke_payment_source!(repo, billing_account_id, cycle_id, allocation_key, refund_meta) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
      [billing_account_id]
    )

    subscription_id =
      case Ecto.Adapters.SQL.query!(
             repo,
             """
             SELECT subscription_id
             FROM billing_subscription_cycles
             WHERE id = $1 AND billing_account_id = $2
             """,
             [cycle_id, billing_account_id]
           ).rows do
        [[sub_id]] -> sub_id
        [] -> repo.rollback(:payment_source_not_found)
      end

    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT id FROM billing_subscriptions WHERE id = $1 FOR UPDATE",
      [subscription_id]
    )

    raw =
      case Ecto.Adapters.SQL.query!(
             repo,
             """
             SELECT source_metadata
             FROM billing_subscription_cycles
             WHERE id = $1 AND billing_account_id = $2
             FOR UPDATE
             """,
             [cycle_id, billing_account_id]
           ).rows do
        [[metadata]] -> metadata
        [] -> repo.rollback(:payment_source_not_found)
      end

    metadata = Metadata.object(raw)
    sources = metadata["payment_sources"] || %{}

    unless Map.has_key?(sources, allocation_key) do
      repo.rollback(:payment_source_not_found)
    end

    source = Map.fetch!(sources, allocation_key)

    if source["state"] == "refunded" do
      :ok
    else
      updated_source =
        Map.merge(source, %{
          "state" => "refunded",
          "refund" =>
            Map.merge(%{"type" => "refund", "full" => true}, stringify_keys(refund_meta))
        })

      updated_metadata =
        Map.put(metadata, "payment_sources", Map.put(sources, allocation_key, updated_source))

      Ecto.Adapters.SQL.query!(
        repo,
        """
        UPDATE billing_subscription_cycles
        SET source_metadata = $2, updated_at = now()
        WHERE id = $1 AND billing_account_id = $3
        """,
        [cycle_id, updated_metadata, billing_account_id]
      )

      :ok
    end
  end

  @doc """
  Marks a newly recorded eligible paid invoice as eligible for a confirmation
  email inside `source_metadata["confirmation_emails"][invoice_id]` without
  touching `payment_sources`. Uses the standard lock order
  (`billing_accounts -> billing_subscriptions -> billing_subscription_cycles`).
  """
  @spec mark_confirmation_email_eligible!(Ecto.Repo.t(), binary(), binary(), binary()) :: :ok
  def mark_confirmation_email_eligible!(repo, billing_account_id, subscription_id, invoice_id)
      when is_binary(billing_account_id) and is_binary(subscription_id) and is_binary(invoice_id) do
    with_cycle_confirmation_lock(repo, billing_account_id, subscription_id, invoice_id, fn
      nil ->
        :ok

      {cycle_id, metadata} ->
        emails = Map.get(metadata, "confirmation_emails") || %{}
        entry = Map.get(emails, invoice_id) || %{}

        if Map.get(entry, "eligible") == true do
          :ok
        else
          updated_entry = Map.put(entry, "eligible", true)

          updated_metadata =
            Map.put(metadata, "confirmation_emails", Map.put(emails, invoice_id, updated_entry))

          update_cycle_source_metadata!(repo, cycle_id, billing_account_id, updated_metadata)
          :ok
        end
    end)
  end

  @doc """
  Returns true when `invoice_id` has an explicit `confirmation_emails` eligibility
  entry on `billing_account_id` whose `notified_at` is still nil. Pre-existing
  historical invoices without a `confirmation_emails` entry return false.
  """
  @spec confirmation_email_pending?(Ecto.Repo.t(), binary(), binary()) :: boolean()
  def confirmation_email_pending?(repo, billing_account_id, invoice_id)
      when is_binary(billing_account_id) and is_binary(invoice_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT 1
      FROM billing_subscription_cycles c
      WHERE c.billing_account_id = $1
        AND (c.source_metadata->'confirmation_emails' ? $2)
        AND (c.source_metadata->'confirmation_emails'->$2->>'eligible') = 'true'
        AND (c.source_metadata->'confirmation_emails'->$2->>'notified_at') IS NULL
      LIMIT 1
      """,
      [billing_account_id, invoice_id]
    ).rows != []
  end

  @doc """
  Atomically claims a 60-second send lease for an eligible, unsent invoice
  confirmation email under the standard lock order.
  """
  @spec claim_confirmation_email_send?(
          Ecto.Repo.t(),
          binary(),
          binary(),
          binary(),
          DateTime.t(),
          non_neg_integer()
        ) :: boolean()
  def claim_confirmation_email_send?(
        repo,
        billing_account_id,
        subscription_id,
        invoice_id,
        %DateTime{} = now,
        lease_sec \\ 60
      )
      when is_binary(billing_account_id) and is_binary(subscription_id) and is_binary(invoice_id) and
             is_integer(lease_sec) and lease_sec >= 0 do
    cutoff = DateTime.add(now, -lease_sec, :second)

    with_cycle_confirmation_lock(repo, billing_account_id, subscription_id, invoice_id, fn
      nil ->
        false

      {cycle_id, metadata} ->
        emails = Map.get(metadata, "confirmation_emails") || %{}
        entry = Map.get(emails, invoice_id)

        claimable? =
          is_map(entry) and
            entry["eligible"] == true and
            is_nil(entry["notified_at"]) and
            claim_expired?(entry["claimed_at"], cutoff)

        if claimable? do
          updated_entry = Map.put(entry, "claimed_at", DateTime.to_iso8601(now))

          updated_metadata =
            Map.put(metadata, "confirmation_emails", Map.put(emails, invoice_id, updated_entry))

          update_cycle_source_metadata!(repo, cycle_id, billing_account_id, updated_metadata)
          true
        else
          false
        end
    end)
  end

  @doc "Records confirmed delivery handoff (`notified_at`) for an invoice confirmation email."
  @spec mark_confirmation_email_sent!(Ecto.Repo.t(), binary(), binary(), binary(), DateTime.t()) ::
          :ok
  def mark_confirmation_email_sent!(
        repo,
        billing_account_id,
        subscription_id,
        invoice_id,
        %DateTime{} = now
      )
      when is_binary(billing_account_id) and is_binary(subscription_id) and is_binary(invoice_id) do
    with_cycle_confirmation_lock(repo, billing_account_id, subscription_id, invoice_id, fn
      nil ->
        :ok

      {cycle_id, metadata} ->
        emails = Map.get(metadata, "confirmation_emails") || %{}
        entry = Map.get(emails, invoice_id) || %{"eligible" => true}
        notified_at = entry["notified_at"] || DateTime.to_iso8601(now)
        updated_entry = Map.put(entry, "notified_at", notified_at)

        updated_metadata =
          Map.put(metadata, "confirmation_emails", Map.put(emails, invoice_id, updated_entry))

        update_cycle_source_metadata!(repo, cycle_id, billing_account_id, updated_metadata)
        :ok
    end)
  end

  @doc "Releases a transient send claim after a failed confirmation email attempt."
  @spec release_confirmation_email_claim!(Ecto.Repo.t(), binary(), binary(), binary()) :: :ok
  def release_confirmation_email_claim!(repo, billing_account_id, subscription_id, invoice_id)
      when is_binary(billing_account_id) and is_binary(subscription_id) and is_binary(invoice_id) do
    with_cycle_confirmation_lock(repo, billing_account_id, subscription_id, invoice_id, fn
      nil ->
        :ok

      {cycle_id, metadata} ->
        emails = Map.get(metadata, "confirmation_emails") || %{}
        entry = Map.get(emails, invoice_id)

        if is_map(entry) and is_nil(entry["notified_at"]) and Map.has_key?(entry, "claimed_at") do
          updated_entry = Map.delete(entry, "claimed_at")

          updated_metadata =
            Map.put(metadata, "confirmation_emails", Map.put(emails, invoice_id, updated_entry))

          update_cycle_source_metadata!(repo, cycle_id, billing_account_id, updated_metadata)
        end

        :ok
    end)
  end

  defp with_cycle_confirmation_lock(repo, billing_account_id, subscription_id, invoice_id, fun) do
    run = fn ->
      lock_owner(repo, billing_account_id, subscription_id)

      row =
        case Ecto.Adapters.SQL.query!(
               repo,
               """
               SELECT id, source_metadata
               FROM billing_subscription_cycles
               WHERE billing_account_id = $1
                 AND subscription_id = $2
                 AND (cycle_key = $3 OR (source_metadata->'payment_sources' ? $3))
               ORDER BY period_start ASC, id ASC
               LIMIT 1
               FOR UPDATE
               """,
               [billing_account_id, subscription_id, invoice_id]
             ).rows do
          [[cycle_id, raw]] -> {cycle_id, Metadata.object(raw)}
          [] -> nil
        end

      fun.(row)
    end

    if repo.in_transaction?() do
      run.()
    else
      {:ok, value} = repo.transaction(run)
      value
    end
  end

  defp update_cycle_source_metadata!(repo, cycle_id, billing_account_id, metadata) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_subscription_cycles
      SET source_metadata = $2, updated_at = now()
      WHERE id = $1 AND billing_account_id = $3
      """,
      [cycle_id, metadata, billing_account_id]
    )
  end

  defp claim_expired?(nil, _cutoff), do: true

  defp claim_expired?(claimed_iso, cutoff) when is_binary(claimed_iso) do
    case parse_iso8601(claimed_iso) do
      {:ok, claimed_at} -> DateTime.compare(claimed_at, cutoff) != :gt
      :error -> true
    end
  end

  defp claim_expired?(_, _cutoff), do: true

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) and not is_struct(v) -> {to_string(k), stringify_keys(v)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp payment_identity("stripe", payment_id), do: %{"payment_intent_id" => payment_id}

  defp payment_identity(provider, payment_id),
    do: %{"provider" => provider, "payment_id" => payment_id}

  defp grant_metadata(id, invoice, %{"provider" => provider} = source) do
    %{
      "cycle_id" => id,
      "provider" => provider,
      "provider_source_id" => invoice,
      "provider_payment_id" => source["payment_id"]
    }
  end

  defp grant_metadata(id, invoice, source) do
    %{
      "cycle_id" => id,
      "stripe_invoice_id" => invoice,
      "stripe_payment_intent_id" => source["payment_intent_id"]
    }
  end

  defp find_replaced_payment(repo, subscription, at, provider, current_payment_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT source_metadata
      FROM billing_subscription_cycles
      WHERE subscription_id = $1 AND status <> 'replaced'
        AND period_start <= $2 AND period_end > $2
      """,
      [subscription, at]
    ).rows
    |> Enum.flat_map(fn [raw] ->
      raw
      |> Metadata.object()
      |> Map.get("payment_sources", %{})
      |> Map.values()
    end)
    |> Enum.flat_map(fn source ->
      with true <- source["provider"] == provider,
           old_payment_id when is_binary(old_payment_id) <- source["payment_id"],
           true <- old_payment_id != current_payment_id,
           true <- source["state"] == "paid",
           {:ok, coverage_start} <- parse_iso8601(source["coverage_start"]),
           {:ok, coverage_end} <- parse_iso8601(source["coverage_end"]),
           :lt <- DateTime.compare(coverage_start, at),
           :gt <- DateTime.compare(coverage_end, at) do
        [{old_payment_id, coverage_start}]
      else
        _ -> []
      end
    end)
    |> Enum.max_by(&elem(&1, 1), DateTime, fn -> nil end)
    |> case do
      {old_payment_id, _} -> old_payment_id
      nil -> nil
    end
  end

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_iso8601(_), do: :error

  # Ends the old payment's cycle that contains `at` and returns the old tier's unused credits:
  # P * (E - at) / (nominal_end - S). Its issued grants keep their expiry.
  # Later unissued cycles belong to the replaced period and are marked `replaced`.
  defp replace!(repo, subscription, at, old_payment) do
    id = Jason.encode!(old_payment)
    path = "$.* ? (@.payment_intent_id == #{id} || @.payment_id == #{id})"

    Ecto.Adapters.SQL.query!(
      repo,
      """
      UPDATE billing_subscription_cycles SET status = 'replaced', updated_at = now()
      WHERE subscription_id = $1 AND period_start >= $2 AND status IN ('pending', 'failed')
        AND source_metadata->'payment_sources' @? ($3::text)::jsonpath
      """,
      [subscription, at, path]
    )

    case Ecto.Adapters.SQL.query!(
           repo,
           """
           SELECT id, period_start, period_end, source_metadata FROM billing_subscription_cycles
           WHERE subscription_id = $1 AND period_start <= $2 AND period_end > $2
             AND status <> 'replaced' AND source_metadata->'payment_sources' @? ($3::text)::jsonpath
           ORDER BY period_start, id FOR UPDATE
           """,
           [subscription, at, path]
         ).rows do
      [] ->
        0

      [[id, starts, ends, raw]] ->
        metadata = Metadata.object(raw)

        nominal_end =
          case metadata["nominal_end"] do
            nil -> ends
            iso -> elem(DateTime.from_iso8601(iso), 1)
          end

        unused =
          div(
            (metadata["paid_tier_credits"] || 0) * DateTime.diff(ends, at, :second),
            DateTime.diff(nominal_end, starts, :second)
          )

        metadata =
          metadata
          |> Map.put("nominal_end", DateTime.to_iso8601(nominal_end))
          |> Map.put("replaced_at", DateTime.to_iso8601(at))

        Ecto.Adapters.SQL.query!(
          repo,
          """
          UPDATE billing_subscription_cycles SET period_end = $2, source_metadata = $3,
            updated_at = now()
          WHERE id = $1
          """,
          [id, at, metadata]
        )

        unused

      _ ->
        repo.rollback(:replaced_cycle_ambiguous)
    end
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
