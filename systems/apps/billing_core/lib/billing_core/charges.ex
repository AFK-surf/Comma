defmodule BillingCore.Charges do
  @moduledoc """
  Pure credit charging for metered events.

  `charge_meter_event/1` is idempotent by `{billing_account_id, source_key}`.
  It applies pricing, carries fractional credits in `rounding_remainders`,
  consumes active grant lots, and records unresolved events in
  `pending_meter_charges` with a one-month expiry.
  """

  alias BillingCore.{Pricing, State, Time}

  @type charge_result ::
          {:ok, map(), State.t()}
          | {:pending, map(), State.t()}
          | {:error, atom()}

  @spec charge_meter_event(map()) :: charge_result()
  def charge_meter_event(event) do
    surface =
      if is_map(event),
        do: Map.get(event, :surface) || Map.get(event, "surface") || "system",
        else: "system"

    SystemsObservability.Context.with_surface(surface, fn ->
      SystemsObservability.Trace.with_span(
        :billing,
        %{component: "billing", surface: surface, operation: "charge"},
        fn -> observe_charge(event, surface) end
      )
    end)
  end

  defp observe_charge(event, surface) do
    started = System.monotonic_time()
    result = do_charge_meter_event(event)

    BillingTelemetry.emit_operation(
      :charge,
      surface,
      charge_outcome(result),
      System.monotonic_time() - started
    )

    result
  end

  defp do_charge_meter_event(%{state: %State{} = state} = event) do
    with {:ok, normalized} <- normalize_event(event) do
      key = event_key(normalized)

      case Map.fetch(state.charged_events, key) do
        {:ok, charge} ->
          {:ok, Map.put(charge, :idempotent, true), state}

        :error ->
          charge_new_event(state, normalized, key)
      end
    end
  end

  defp do_charge_meter_event(_event), do: {:error, :missing_state}

  defp charge_outcome({:ok, _charge, _state}), do: :ok
  defp charge_outcome({:pending, _charge, _state}), do: :unavailable
  defp charge_outcome({:error, _reason}), do: :error

  defp charge_new_event(state, event, key) do
    with {:ok, pricing_components, calculated} <- price_event(state, event) do
      resource_kind = Map.get(event, :resource_kind, :meter)
      remainder_key = {event.billing_account_id, resource_kind, event.provider, event.sku}
      carried = Map.get(state.rounding_remainders, remainder_key, 0.0)
      total = calculated + carried
      charged_credits = floor(total)
      next_remainder = total - charged_credits

      entitlement_mode =
        BillingCore.Credits.active_usage_mode(
          state.grants,
          event.billing_account_id,
          event.metered_at
        )

      {grant_credits, grant_debits, grants_after, charged_credits, grace_credits, status,
       stored_remainder} =
        case entitlement_mode do
          :unlimited_metered ->
            {0, [], state.grants, 0, 0, :unlimited_metered, carried}

          :metered ->
            {grant_credits, grant_debits, grants_after} =
              consume_grants(
                state.grants,
                event.billing_account_id,
                charged_credits,
                event.metered_at
              )

            grace_credits = charged_credits - grant_credits

            {grant_credits, grant_debits, grants_after, charged_credits, grace_credits,
             charge_status(grace_credits), next_remainder}
        end

      balance_after = available_credits(grants_after, event.billing_account_id, event.metered_at)

      charge =
        event
        |> Map.take([:billing_account_id, :source_key, :provider, :sku, :quantity, :metered_at])
        |> Map.merge(%{
          status: status,
          pricing_status: :priced,
          pricing_components: pricing_components,
          credits_per_usd: 1_000_000,
          calculated_credits: calculated,
          charged_credits: charged_credits,
          grant_credits: grant_credits,
          grace_credits: grace_credits,
          balance_after: balance_after,
          balance_after_snapshot: %{
            available_credits: balance_after,
            entitlement_mode: entitlement_mode
          },
          grant_debits: grant_debits,
          entitlement_mode: entitlement_mode,
          rounding_remainder: stored_remainder,
          idempotent: false
        })

      ledger_entry = Map.merge(charge, %{ledger_key: key, inserted_at: event.metered_at})

      next_state = %{
        state
        | grants: grants_after,
          credit_ledger: [ledger_entry | state.credit_ledger],
          charged_events: Map.put(state.charged_events, key, charge),
          rounding_remainders:
            Map.put(state.rounding_remainders, remainder_key, stored_remainder),
          pending_meter_charges: Map.delete(state.pending_meter_charges, key)
      }

      with :ok <- emit_charge_event(event, charge) do
        {:ok, charge, next_state}
      end
    else
      {:error, :missing_pricing} -> pending_charge(state, event, key)
    end
  end

  defp price_event(state, %{meter_components: components} = event) when is_list(components) do
    components
    |> Enum.reduce_while({:ok, [], 0.0}, fn component, {:ok, priced, total} ->
      component = Map.merge(Map.take(event, [:resource_kind, :provider, :sku]), component)

      case Pricing.resolve_component(
             state.pricing_catalog,
             event.billing_account_id,
             Pricing.lookup_component(event, component),
             event.metered_at
           ) do
        {:ok, price} ->
          quantity = Map.fetch!(component, :quantity)
          credits = quantity_to_credits(quantity, price)

          priced_component =
            component
            |> Map.take([
              :resource_kind,
              :provider,
              :sku,
              :component,
              :name,
              :meter_unit,
              :quantity
            ])
            |> Map.merge(%{
              pricing_version: Map.get(price, :version),
              usd_micros_per_unit: Map.get(price, :usd_micros_per_unit),
              calculated_credits: credits
            })

          {:cont, {:ok, [priced_component | priced], total + credits}}

        {:error, :missing_pricing} ->
          {:halt, {:error, :missing_pricing}}
      end
    end)
    |> case do
      {:ok, priced, total} -> {:ok, Enum.reverse(priced), total}
      {:error, _} = error -> error
    end
  end

  defp price_event(state, event) do
    with {:ok, pricing} <-
           Pricing.resolve(
             state.pricing_catalog,
             event.billing_account_id,
             event.provider,
             event.sku,
             event.metered_at
           ) do
      calculated = quantity_to_credits(event.quantity, pricing)
      {:ok, [Map.merge(Map.take(event, [:provider, :sku, :quantity]), pricing)], calculated}
    end
  end

  defp quantity_to_credits(quantity, %{credits_per_unit: credits_per_unit}) do
    quantity * credits_per_unit
  end

  defp quantity_to_credits(quantity, %{usd_micros_per_unit: usd_micros_per_unit}) do
    quantity * usd_micros_per_unit * 1_000_000 / 1_000_000
  end

  defp pending_charge(state, event, key) do
    pending =
      event
      |> Map.take([
        :resource_kind,
        :billing_account_id,
        :source_key,
        :provider,
        :sku,
        :quantity,
        :metered_at,
        :meter_components
      ])
      |> Map.merge(%{
        status: :pending,
        pricing_status: :missing_pricing,
        expires_at: Time.add_one_month(event.metered_at)
      })

    next_state = %{
      state
      | pending_meter_charges: Map.put(state.pending_meter_charges, key, pending)
    }

    {:pending, pending, next_state}
  end

  defp consume_grants(grants, account_id, required, at) do
    {eligible, other} =
      Enum.split_with(grants, fn grant ->
        Map.get(grant, :billing_account_id) == account_id and
          Map.get(grant, :status, "active") == "active" and
          Map.get(grant, :remaining_credits, 0) > 0 and
          not Time.after?(at, Map.get(grant, :expires_at))
      end)

    sorted = Enum.sort_by(eligible, &grant_sort_key/1)

    {consumed, grant_debits, remaining_required, grants_after} =
      consume_sorted(sorted, required, [], [])

    {consumed, grant_debits,
     Enum.reverse(grants_after) ++ other ++ exhausted_marker(sorted, remaining_required)}
    |> normalize_grants()
  end

  defp consume_sorted([], remaining, debits, acc), do: {0, Enum.reverse(debits), remaining, acc}

  defp consume_sorted([grant | rest], remaining, debits, acc) when remaining <= 0 do
    {consumed_rest, debits_rest, remaining_rest, acc_rest} =
      consume_sorted(rest, remaining, debits, [grant | acc])

    {consumed_rest, debits_rest, remaining_rest, acc_rest}
  end

  defp consume_sorted([grant | rest], remaining, debits, acc) do
    available = Map.get(grant, :remaining_credits, 0)
    used = min(available, remaining)
    updated = Map.put(grant, :remaining_credits, available - used)
    debit = %{grant_id: Map.get(grant, :id), credits: used}

    {consumed_rest, debits_rest, remaining_rest, acc_rest} =
      consume_sorted(rest, remaining - used, [debit | debits], [updated | acc])

    {used + consumed_rest, debits_rest, remaining_rest, acc_rest}
  end

  defp exhausted_marker(_sorted, _remaining), do: []

  defp normalize_grants({consumed, grant_debits, grants}) do
    grants =
      grants
      |> Enum.reject(
        &(Map.get(&1, :remaining_credits, 0) <= 0 and Map.get(&1, :drop_when_empty, true))
      )

    {consumed, grant_debits, grants}
  end

  defp available_credits(grants, account_id, at) do
    BillingCore.Credits.available_credits(grants, account_id, at)
  end

  defp grant_sort_key(grant) do
    expires_at = Map.get(grant, :expires_at)

    expires_us =
      if expires_at, do: DateTime.to_unix(expires_at, :microsecond), else: 9_999_999_999_999_999

    priority = Map.get(grant, :priority, 0)

    {expires_us, priority}
  end

  defp charge_status(0), do: :charged
  defp charge_status(_grace), do: :grace

  defp normalize_event(event) do
    required = [:billing_account_id, :source_key, :provider, :sku, :metered_at]

    missing =
      required
      |> Enum.reject(&Map.has_key?(event, &1))

    case missing do
      [] ->
        {:ok,
         Map.take(event, [
           :resource_kind,
           :billing_account_id,
           :source_key,
           :provider,
           :sku,
           :quantity,
           :metered_at,
           :meter_components,
           :typed_sink,
           :owner_snapshot,
           :surface,
           :product_owner_type,
           :product_owner_id,
           :tenant_id,
           :group_id,
           :entrypoint,
           :actor_type,
           :carrier
         ])}

      [field | _] ->
        {:error, {:missing_field, field}}
    end
  end

  defp event_key(event), do: {event.billing_account_id, event.source_key}

  defp emit_charge_event(event, charge) do
    case charge_typed_sink(event) do
      nil ->
        :ok

      sink ->
        row =
          event
          |> charge_context()
          |> Map.merge(%{
            source: "billing_core.ledger",
            source_key: event.source_key,
            provider: event.provider,
            sku: event.sku,
            status: Atom.to_string(charge.status),
            charge_status: Atom.to_string(charge.status),
            pricing_status: "priced",
            calculated_credits: charge.calculated_credits,
            charged_credits: charge.charged_credits,
            grace_credits: charge.grace_credits,
            balance_after: charge.balance_after,
            entitlement_mode: Atom.to_string(charge.entitlement_mode),
            pricing_components: charge.pricing_components,
            credits_per_usd: charge.credits_per_usd
          })
          |> SalixAnalytics.BillingChargeEvent.build()

        safe_sink_insert(sink, [row])
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

  defp charge_context(event) do
    owner = event[:owner_snapshot] || %{}

    %{
      billing_account_id: event.billing_account_id,
      surface: owner["surface"] || owner[:surface] || event[:surface] || "unknown",
      product_owner_type:
        owner["product_owner_type"] || owner[:product_owner_type] || event[:product_owner_type] ||
          "unknown",
      product_owner_id:
        owner["product_owner_id"] || owner[:product_owner_id] || event[:product_owner_id] ||
          "unknown",
      tenant_id: owner["salix_tenant_id"] || owner[:salix_tenant_id] || event[:tenant_id],
      group_id: owner["salix_group_id"] || owner[:salix_group_id] || event[:group_id],
      entrypoint: event[:entrypoint] || "ledger_projection",
      actor_type: event[:actor_type] || "system"
    }
  end
end
