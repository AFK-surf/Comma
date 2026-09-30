defmodule BillingStripe.SubscriptionChanges do
  @moduledoc "Same-cadence paid upgrades and one scheduled downgrade, owned by the existing Subscription."
  alias BillingCore.Metadata

  def change(attrs) do
    with {:ok, command} <- reserve(attrs) do
      case command do
        %{operation: operation} ->
          with {:ok, result} <- resume(attrs.subscription_id, operation, attrs.success_url) do
            if operation["key"] == attrs.idempotency_key,
              do: {:ok, result},
              else: {:error, :subscription_quote_changed}
          end

        result ->
          {:ok, result}
      end
    end
  end

  def preview(attrs) do
    owned(attrs, fn current, _local ->
      if current["status"] != "active", do: repo().rollback(:subscription_payment_pending)
      {item, plan} = current_plan!(current)
      {:ok, target} = target_plan(attrs)
      same_period!(plan, target)
      purchasable_target!(plan, target)
      at = System.system_time(:second)

      if target.grant_credits > plan.grant_credits do
        case api().preview_invoice(
               %{
                 subscription: attrs.subscription_id,
                 subscription_details: %{
                   proration_date: at,
                   proration_behavior: "always_invoice",
                   items: [%{id: item["id"], price: target.provider_price_id}]
                 }
               },
               opts()
             ) do
          {:ok, invoice} ->
            %{
              amount_minor: invoice["amount_due"],
              currency: invoice["currency"],
              proration_date: at,
              current_price_id: plan.provider_price_id,
              period_end: period_end(current),
              effect: "upgrade"
            }

          {:error, reason} ->
            repo().rollback(reason)
        end
      else
        %{
          amount_minor: 0,
          currency: target.currency,
          proration_date: at,
          current_price_id: plan.provider_price_id,
          period_end: period_end(current),
          effect:
            if(target.grant_credits == plan.grant_credits, do: "keep_current", else: "downgrade")
        }
      end
    end)
  end

  def cancel(attrs) do
    owned(attrs, fn current, local ->
      if Metadata.object(local)["change_operation"] || current["pending_update"],
        do: repo().rollback(:subscription_payment_pending)

      schedule = current["schedule"]

      result =
        if is_map(schedule) do
          owned_schedule!(schedule)
          phase = current_phase!(schedule)

          api().update_subscription_schedule(
            schedule["id"],
            %{
              phases: [phase_params(phase, period_end(current))],
              end_behavior: "cancel",
              proration_behavior: "none",
              metadata: %{
                surface: "comma",
                purpose: "cancel",
                comma_subscription_id: attrs.subscription_id
              }
            },
            write_opts(attrs.idempotency_key)
          )
        else
          api().update_subscription(
            attrs.subscription_id,
            %{cancel_at_period_end: true},
            write_opts(attrs.idempotency_key)
          )
        end

      case result do
        {:ok, _} ->
          %{
            id: attrs.subscription_id,
            provider: "stripe",
            effect: "cancellation_scheduled",
            effective_at: period_end(current)
          }

        {:error, reason} ->
          repo().rollback(reason)
      end
    end)
  end

  def reconcile(id, current) do
    case local_operation(id) do
      nil ->
        {:ok, current}

      operation ->
        with {:ok, _} <- resume(id, operation, nil), do: retrieve(id)
    end
  end

  defp reserve(attrs) do
    owned(attrs, fn current, local ->
      metadata = Metadata.object(local)
      operation = metadata["change_operation"]

      if operation do
        if operation["kind"] == "downgrade" or operation["key"] == attrs.idempotency_key,
          do: %{operation: operation},
          else: repo().rollback(:subscription_payment_pending)
      else
        if current["status"] != "active", do: repo().rollback(:subscription_payment_pending)
        {item, plan} = current_plan!(current)
        {:ok, target} = target_plan(attrs)
        same_period!(plan, target)
        purchasable_target!(plan, target)
        if current["pending_update"], do: repo().rollback(:subscription_payment_pending)

        if attrs[:current_price_id] != plan.provider_price_id or
             attrs[:period_end] != period_end(current),
           do: repo().rollback(:subscription_quote_changed)

        cond do
          target.grant_credits > plan.grant_credits ->
            require_paid_tier!(attrs.subscription_id, plan.grant_credits, attrs[:proration_date])

            period_start =
              current["current_period_start"] ||
                get_in(current, ["items", "data", Access.at(0), "current_period_start"])

            if not is_integer(attrs[:proration_date]) or attrs.proration_date < period_start or
                 attrs.proration_date > System.system_time(:second),
               do: repo().rollback(:subscription_quote_changed)

            schedule = current["schedule"]
            if is_map(schedule), do: owned_schedule!(schedule)

            downgrade =
              if is_map(schedule) and schedule["end_behavior"] != "cancel", do: schedule["id"]

            operation = %{
              "kind" => "upgrade",
              "key" => attrs.idempotency_key,
              "target_price_id" => target.provider_price_id,
              "current_price_id" => plan.provider_price_id,
              "period_end" => period_end(current),
              "schedule_id" => downgrade,
              "created_at" => System.system_time(:second),
              "params" => %{
                "metadata" => %{"comma_upgrade_key" => attrs.idempotency_key},
                "items" => [%{"id" => item["id"], "price" => target.provider_price_id}],
                "payment_behavior" => "pending_if_incomplete",
                "proration_behavior" => "always_invoice",
                "proration_date" => attrs.proration_date,
                "expand" => ["latest_invoice"]
              }
            }

            save_operation(attrs.subscription_id, operation)
            %{operation: operation}

          target.grant_credits == plan.grant_credits ->
            release_downgrade(current, attrs.idempotency_key)
            %{id: attrs.subscription_id, provider: "stripe", effect: "kept_current"}

          true ->
            if current["cancel_at_period_end"] == true or not is_nil(current["cancel_at"]),
              do: repo().rollback(:subscription_renewal_cancelled)

            operation = %{
              "kind" => "downgrade",
              "key" => attrs.idempotency_key,
              "target_price_id" => target.provider_price_id,
              "current_price_id" => plan.provider_price_id,
              "period_end" => period_end(current)
            }

            save_operation(attrs.subscription_id, operation)
            %{operation: operation}
        end
      end
    end)
  end

  defp resume(id, %{"kind" => "downgrade"} = operation, _return_url) do
    [[account]] =
      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT billing_account_id FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1",
        [id]
      ).rows

    result =
      repo().transaction(fn ->
        Ecto.Adapters.SQL.query!(
          repo(),
          "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
          [account]
        )

        Ecto.Adapters.SQL.query!(
          repo(),
          "SELECT id FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1 FOR UPDATE",
          [id]
        )

        if (local_operation(id) || %{})["key"] != operation["key"],
          do: repo().rollback(:subscription_quote_changed)

        with {:ok, current} <- retrieve(id),
             :ok <- unchanged_quote(current, operation),
             {:ok, target} <- target_plan(%{provider_price_id: operation["target_price_id"]}) do
          result = schedule_downgrade(current, target, operation["key"])
          save_operation(id, nil)
          result
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    if result == {:error, :subscription_quote_changed},
      do: persist_operation(id, nil, operation["key"])

    result
  end

  defp resume(id, operation, return_url) do
    if operation["invoice_id"] do
      finish(id, operation, return_url)
    else
      with {:ok, current} <- retrieve(id),
           :ok <- release_operation_schedule(current, operation),
           {:ok, current} <- retrieve(id),
           :ok <- unchanged_quote(current, operation),
           {:ok, invoice_id} <- execute_upgrade(id, current, operation) do
        operation = Map.put(operation, "invoice_id", invoice_id)
        persist_operation(id, operation, operation["key"])
        finish(id, operation, return_url)
      else
        {:error, :subscription_quote_changed} = error ->
          persist_operation(id, nil, operation["key"])
          error

        {:error, _} = error ->
          error
      end
    end
  end

  defp execute_upgrade(id, current, operation) do
    latest_id = object_id(current["latest_invoice"])
    latest = if latest_id, do: api().retrieve_invoice(latest_id, %{}, opts()), else: {:ok, %{}}

    case latest do
      {:ok, invoice} ->
        if BillingStripe.Events.billing_metadata(invoice)["comma_upgrade_key"] == operation["key"] and
             invoice["billing_reason"] == "subscription_update" do
          {:ok, invoice["id"]}
        else
          if System.system_time(:second) - operation["created_at"] >= 23 * 3600 do
            {:error, :stripe_upgrade_result_unknown}
          else
            with {:ok, updated} <-
                   api().update_subscription(
                     id,
                     operation["params"],
                     write_opts(operation["key"] <> ":upgrade")
                   ) do
              {:ok, object_id(updated["latest_invoice"])}
            end
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(id, operation, return_url) do
    with {:ok, current} <- retrieve(id),
         {:ok, invoice} <- api().retrieve_invoice(operation["invoice_id"], %{}, opts()) do
      cond do
        invoice["status"] == "paid" and current_price_id(current) == operation["target_price_id"] ->
          persist_operation(id, nil, operation["key"])
          {:ok, %{id: id, provider: "stripe", effect: "upgraded", url: return_url}}

        invoice["status"] in ["void", "uncollectible"] ->
          persist_operation(id, nil, operation["key"])
          {:ok, %{id: id, provider: "stripe", effect: "upgrade_failed"}}

        invoice["status"] == "paid" and period_end(current) != operation["period_end"] ->
          persist_operation(id, nil, operation["key"])
          {:ok, %{id: id, provider: "stripe", effect: "upgraded", url: return_url}}

        true ->
          {:ok,
           %{
             id: id,
             provider: "stripe",
             effect: "payment_required",
             url: invoice["hosted_invoice_url"]
           }}
      end
    end
  end

  defp unchanged_quote(current, operation) do
    if current_price_id(current) in [operation["current_price_id"], operation["target_price_id"]] and
         period_end(current) == operation["period_end"],
       do: :ok,
       else: {:error, :subscription_quote_changed}
  end

  defp release_operation_schedule(_current, %{"schedule_id" => nil}), do: :ok

  defp release_operation_schedule(current, operation) do
    case current["schedule"] do
      nil ->
        :ok

      %{"id" => id} = schedule ->
        cond do
          get_in(schedule, ["metadata", "surface"]) != "comma" ->
            {:error, :subscription_schedule_not_comma}

          id != operation["schedule_id"] ->
            {:error, :subscription_schedule_changed}

          true ->
            release(id, operation["key"] <> ":release")
        end
    end
  end

  defp release_downgrade(current, key) do
    case current["schedule"] do
      nil ->
        :ok

      schedule ->
        owned_schedule!(schedule)

        if schedule["end_behavior"] != "cancel" do
          case release(schedule["id"], key <> ":release") do
            :ok -> :ok
            {:error, reason} -> repo().rollback(reason)
          end
        end
    end
  end

  defp schedule_downgrade(current, target, key) do
    schedule =
      case current["schedule"] do
        nil ->
          case api().create_subscription_schedule(
                 %{from_subscription: current["id"]},
                 write_opts(key <> ":schedule")
               ) do
            {:ok, schedule} -> schedule
            {:error, reason} -> repo().rollback(reason)
          end

        schedule ->
          if get_in(schedule, ["metadata", "surface"]) == "comma" do
            schedule
          else
            # Only the original create response can establish ownership of an
            # attached Schedule whose configuration response was lost.
            case api().create_subscription_schedule(
                   %{from_subscription: current["id"]},
                   write_opts(key <> ":schedule")
                 ) do
              {:ok, original} ->
                if original["id"] == schedule["id"],
                  do: schedule,
                  else: repo().rollback(:subscription_schedule_not_comma)

              _ ->
                repo().rollback(:subscription_schedule_not_comma)
            end
          end
      end

    if schedule["end_behavior"] == "cancel", do: repo().rollback(:subscription_renewal_cancelled)
    phase = current_phase!(schedule)
    ends = period_end(current)
    {_, current_plan} = current_plan!(current)
    interval = current_plan.billing_period

    params = %{
      end_behavior: "release",
      proration_behavior: "none",
      metadata: %{surface: "comma", purpose: "downgrade", comma_subscription_id: current["id"]},
      phases: [
        phase_params(phase, ends),
        %{
          start_date: ends,
          duration: %{interval: interval, interval_count: 1},
          items: [%{price: target.provider_price_id, quantity: 1}],
          proration_behavior: "none",
          billing_cycle_anchor: "automatic"
        }
      ]
    }

    case api().update_subscription_schedule(schedule["id"], params, write_opts(key <> ":target")) do
      {:ok, _} ->
        %{
          id: current["id"],
          provider: "stripe",
          effect: "downgrade_scheduled",
          effective_at: ends
        }

      {:error, reason} ->
        repo().rollback(reason)
    end
  end

  defp phase_params(phase, ends),
    do: %{
      start_date: phase["start_date"],
      end_date: ends,
      items:
        Enum.map(phase["items"], &%{price: object_id(&1["price"]), quantity: &1["quantity"] || 1}),
      proration_behavior: "none",
      billing_cycle_anchor: "automatic"
    }

  defp current_phase!(schedule),
    do:
      Enum.find(
        schedule["phases"],
        &(&1["start_date"] == schedule["current_phase"]["start_date"])
      ) || raise("Stripe current phase missing")

  defp owned_schedule!(schedule) do
    if get_in(schedule, ["metadata", "surface"]) != "comma",
      do: repo().rollback(:subscription_schedule_not_comma)
  end

  defp require_paid_tier!(id, tier, at) when is_integer(at) do
    rows =
      Ecto.Adapters.SQL.query!(
        repo(),
        """
        SELECT c.source_metadata FROM billing_subscription_cycles c
        JOIN billing_subscriptions s ON s.id = c.subscription_id
        WHERE s.source_type = 'stripe_subscription' AND s.source_id = $1
          AND c.period_start <= $2 AND c.period_end > $2
        LIMIT 1
        """,
        [id, DateTime.from_unix!(at)]
      ).rows

    funded =
      Enum.any?(rows, fn [raw] ->
        sources = Metadata.object(raw)["payment_sources"] || %{}

        Enum.any?(sources, fn {_invoice, source} ->
          source["target_tier"] == tier and is_binary(source["payment_intent_id"])
        end)
      end)

    if not funded, do: repo().rollback(:stripe_prior_payment_not_recorded)
  end

  defp require_paid_tier!(_id, _tier, _at), do: repo().rollback(:subscription_quote_changed)

  defp current_plan!(current) do
    case get_in(current, ["items", "data"]) do
      [item] ->
        case BillingCommerce.get_provider_plan(%{
               surface: "comma",
               provider: "stripe",
               provider_price_id: object_id(item["price"])
             }) do
          {:ok, plan} -> {item, plan}
          {:error, reason} -> repo().rollback(reason)
        end

      _ ->
        repo().rollback(:stripe_subscription_item_unsupported)
    end
  end

  defp same_period!(plan, target),
    do:
      if(plan.billing_period != target.billing_period,
        do: repo().rollback(:subscription_billing_period_change_unavailable)
      )

  defp purchasable_target!(current, target) do
    if current.provider_price_id != target.provider_price_id and
         target.provider_metadata["comma_purchasable"] != true,
       do: repo().rollback(:plan_not_purchasable)
  end

  defp target_plan(attrs),
    do:
      BillingCommerce.get_provider_plan(%{
        surface: "comma",
        provider: "stripe",
        provider_price_id: attrs.provider_price_id
      })

  defp current_price_id(current),
    do: get_in(current, ["items", "data", Access.at(0), "price"]) |> object_id()

  defp period_end(current),
    do:
      current["current_period_end"] ||
        get_in(current, ["items", "data", Access.at(0), "current_period_end"])

  defp object_id(%{"id" => id}), do: id
  defp object_id(id), do: id

  defp release(id, key) do
    case api().release_subscription_schedule(id, %{preserve_cancel_date: true}, write_opts(key)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retrieve(id),
    do: api().retrieve_subscription(id, %{expand: ["schedule", "items.data.price"]}, opts())

  defp owned(attrs, action) do
    repo().transaction(fn ->
      account = attrs.billing_account_id

      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
        [account]
      )

      [[metadata]] =
        Ecto.Adapters.SQL.query!(
          repo(),
          "SELECT source_metadata FROM billing_subscriptions WHERE billing_account_id = $1 AND source_type = 'stripe_subscription' AND source_id = $2 FOR UPDATE",
          [account, attrs.subscription_id]
        ).rows

      current =
        case retrieve(attrs.subscription_id) do
          {:ok, current} -> current
          {:error, reason} -> repo().rollback(reason)
        end

      if object_id(current["customer"]) != attrs.customer_id,
        do: repo().rollback(:stripe_customer_mismatch)

      action.(current, metadata)
    end)
  end

  defp local_operation(id) do
    case Ecto.Adapters.SQL.query!(
           repo(),
           "SELECT source_metadata FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1",
           [id]
         ).rows do
      [[metadata]] -> Metadata.object(metadata)["change_operation"]
      [] -> nil
    end
  end

  defp persist_operation(id, operation, expected_key) do
    repo().transaction(fn ->
      [[account]] =
        Ecto.Adapters.SQL.query!(
          repo(),
          "SELECT billing_account_id FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1",
          [id]
        ).rows

      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT id FROM billing_accounts WHERE id = $1 FOR UPDATE",
        [account]
      )

      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT id FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1 FOR UPDATE",
        [id]
      )

      if (local_operation(id) || %{})["key"] == expected_key, do: save_operation(id, operation)
    end)
  end

  defp save_operation(id, operation) do
    [[raw]] =
      Ecto.Adapters.SQL.query!(
        repo(),
        "SELECT source_metadata FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $1",
        [id]
      ).rows

    metadata = Metadata.object(raw)

    metadata =
      if operation,
        do: Map.put(metadata, "change_operation", operation),
        else: Map.delete(metadata, "change_operation")

    Ecto.Adapters.SQL.query!(
      repo(),
      "UPDATE billing_subscriptions SET source_metadata = $2 WHERE source_type = 'stripe_subscription' AND source_id = $1",
      [id, metadata]
    )
  end

  defp repo, do: Application.fetch_env!(:billing_stripe, :repo)
  defp api, do: Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)

  defp opts,
    do: [api_key: Application.fetch_env!(:billing_stripe, :secret_key), response_as: :map]

  defp write_opts(key), do: Keyword.put(opts(), :idempotency_key, key)
end
