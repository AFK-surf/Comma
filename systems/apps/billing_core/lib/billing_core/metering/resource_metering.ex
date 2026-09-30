defmodule BillingCore.ResourceMetering do
  @moduledoc """
  VM/storage resource metering seam.

  Callers pass already-attributed facts. The seam writes the typed analytics row
  first through a mockable sink, then charges through the shared charge engine.
  Missing owners are reported as unattributed rows and are not charged.
  """

  alias BillingCore.Charges

  def meter_vm_interval(attrs), do: meter(:vm, attrs)
  def meter_storage_sample(attrs), do: meter(:storage, attrs)

  defp meter(kind, attrs) do
    row = typed_row(kind, attrs)
    _ = shadow_fee_control(kind, attrs)

    with {:ok, _} <- sink(attrs).insert([row]) do
      cond do
        owner_present?(attrs) and billable_meter?(kind, attrs) ->
          charge(kind, attrs)

        owner_present?(attrs) ->
          uncharged_result(:pending_pricing, row, attrs)

        true ->
          uncharged_result(:unattributed, row, attrs)
      end
    end
  end

  defp uncharged_result(status, row, %{state: %BillingCore.State{} = state}),
    do: {status, row, state}

  defp uncharged_result(status, row, _attrs), do: {status, row}

  defp charge(kind, %{state: %BillingCore.State{}} = attrs) do
    attrs
    |> Map.put(:resource_kind, kind)
    |> Charges.charge_meter_event()
  end

  defp charge(kind, attrs) do
    context = common(attrs)
    quantity = attrs[:quantity] || attrs[:duration_seconds] || attrs[:byte_seconds] || 0

    attrs
    |> Map.put(:resource_kind, to_string(kind))
    |> Map.put(:billing_account_id, context.billing_account_id)
    |> Map.put(:surface, context.surface)
    |> Map.put(:product_owner_type, context.product_owner_type)
    |> Map.put(:product_owner_id, context.product_owner_id)
    |> Map.put(:tenant_id, context.tenant_id)
    |> Map.put(:group_id, context.group_id)
    |> Map.put(:actor_type, context.actor_type)
    |> Map.put(:entrypoint, attrs[:entrypoint] || default_entrypoint(kind))
    |> Map.put(:quantity, quantity)
    |> Map.put(:component, default_component(kind))
    |> Map.put(:meter_unit, default_meter_unit(kind))
    |> BillingCore.RepoCharges.charge_meter_event()
  end

  defp typed_row(:vm, attrs) do
    SalixAnalytics.VMUsageEvent.build(
      common(attrs)
      |> Map.merge(%{
        source_key: attrs[:source_key],
        entrypoint: attrs[:entrypoint] || "cloud_vm_sweeper",
        provider: attrs[:provider],
        sku: attrs[:sku],
        duration_seconds: attrs[:quantity] || attrs[:duration_seconds] || 0,
        charge_status: if(owner_present?(attrs), do: "unrated", else: "unattributed"),
        interval_start:
          attrs[:interval_start] || attrs[:started_at] || timestamp_ms(attrs[:interval_start_ms]),
        interval_end:
          attrs[:interval_end] || attrs[:ended_at] || timestamp_ms(attrs[:interval_end_ms]),
        env_id: attrs[:env_id],
        sprite_name: attrs[:sprite_name],
        quality: attrs[:quality] || []
      })
    )
  end

  defp typed_row(:storage, attrs) do
    SalixAnalytics.StorageUsageEvent.build(
      common(attrs)
      |> Map.merge(%{
        source_key: attrs[:source_key],
        entrypoint: attrs[:entrypoint] || "storage_snapshot",
        provider: attrs[:provider],
        sku: attrs[:sku],
        storage_tier: attrs[:storage_tier] || attrs[:sku],
        byte_seconds: attrs[:quantity] || attrs[:byte_seconds] || 0,
        bytes: attrs[:bytes] || 0,
        object_count: attrs[:object_count] || 0,
        bucket: attrs[:bucket],
        prefix: attrs[:prefix],
        sample_window_seconds: attrs[:sample_window_seconds] || 0,
        tier_source: attrs[:tier_source],
        tier_cache_hit: attrs[:tier_cache_hit] || false,
        charge_status: storage_charge_status(attrs),
        quality: attrs[:quality] || []
      })
    )
  end

  defp common(attrs) do
    owner = attrs[:owner_snapshot] || %{}

    billing_account_id =
      owner["billing_account_id"] || owner[:billing_account_id] || attrs[:billing_account_id]

    %{
      source: attrs[:source] || "billing_core",
      source_key: attrs[:source_key],
      surface: owner["surface"] || owner[:surface] || attrs[:surface] || "unknown",
      billing_account_id:
        if(present?(billing_account_id), do: billing_account_id, else: "unattributed"),
      product_owner_type:
        owner["product_owner_type"] || owner[:product_owner_type] || attrs[:product_owner_type] ||
          "unknown",
      product_owner_id:
        owner["product_owner_id"] || owner[:product_owner_id] || attrs[:product_owner_id] ||
          "unknown",
      tenant_id:
        owner["salix_tenant_id"] || owner[:salix_tenant_id] || attrs[:tenant_id] || "unknown",
      group_id:
        owner["salix_group_id"] || owner[:salix_group_id] || attrs[:group_id] || "unknown",
      actor_type: attrs[:actor_type] || "system"
    }
  end

  defp owner_present?(attrs) do
    owner = attrs[:owner_snapshot] || %{}

    present?(
      attrs[:billing_account_id] || owner["billing_account_id"] || owner[:billing_account_id]
    )
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp billable_meter?(:storage, attrs) do
    present?(attrs[:storage_tier] || attrs[:sku]) and
      (attrs[:storage_tier] || attrs[:sku]) != "unknown"
  end

  defp billable_meter?(_kind, _attrs), do: true

  defp storage_charge_status(attrs) do
    cond do
      not owner_present?(attrs) -> "unattributed"
      billable_meter?(:storage, attrs) -> "unrated"
      true -> "pending_pricing"
    end
  end

  defp timestamp_ms(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)
  defp timestamp_ms(value), do: value

  defp sink(attrs),
    do:
      attrs[:typed_sink] ||
        Application.get_env(:billing_core, :typed_sink, SalixAnalytics.TypedSinkWorker)

  defp shadow_fee_control(kind, attrs) do
    context =
      attrs
      |> common()
      |> Map.put(:entrypoint, attrs[:entrypoint] || default_entrypoint(kind))
      |> Map.put(:source_key, "fee:#{kind}:#{attrs[:source_key]}")

    if not owner_present?(attrs) do
      :ok
    else
      BillingCore.FeeControl.check_cached(%{
        billing_account_id: context.billing_account_id,
        provider: attrs[:provider],
        sku: attrs[:sku],
        repo: attrs[:repo],
        sql_runner: attrs[:sql_runner],
        estimated_credits: attrs[:estimated_credits] || 0,
        balance_snapshot: attrs[:balance_snapshot] || 0,
        typed_sink: attrs[:fee_control_typed_sink] || attrs[:typed_sink],
        row_context: context,
        source: "resource_metering",
        source_key: context.source_key,
        force_refresh: attrs[:force_refresh] || fee_env(:force_refresh),
        probe: attrs[:probe],
        probe_rate: attrs[:probe_rate] || fee_env(:probe_rate)
      })
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp default_entrypoint(:vm), do: "cloud_vm_sweeper"
  defp default_entrypoint(:storage), do: "storage_snapshot"
  defp default_component(:vm), do: :runtime
  defp default_component(:storage), do: :byte_second
  defp default_meter_unit(:vm), do: :second
  defp default_meter_unit(:storage), do: :byte_second

  defp fee_env(key), do: Application.get_env(:billing_core, :fee_control, []) |> Keyword.get(key)
end
