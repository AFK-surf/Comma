defmodule BillingCore.VoiceMetering do
  @moduledoc """
  Voice call metering seam (docs/messaging-voice.md).

  `SalixVoice.CallActor` calls `charge/1` once when a call ends, with the
  Group billing owner snapshot and two components: GPT-Live `model_seconds`
  and `carrier_seconds`. The charge uses the shared engine with
  `resource_kind: "voice"` and the idempotency key
  `voice:<carrier>:<carrier call ID>`, so a retry never charges twice.

  GPT-Live duration uses the catalog's per-second rate. Signal and direct
  WebSocket transport have no carrier charge. Other carriers remain pending
  until their own rate is available. A call without a billing owner is not charged.
  """

  require Logger

  @doc """
  Charge one ended call. Returns the engine result, or `{:unattributed, attrs}`
  when the owner snapshot names no billing account.
  """
  @spec charge(map()) :: term()
  def charge(attrs) when is_map(attrs) do
    owner = stringify(attrs[:owner_snapshot] || %{})
    account_id = owner["billing_account_id"]
    components = Enum.filter(attrs[:components] || [], &(quantity(&1) > 0))

    cond do
      not present?(account_id) ->
        {:unattributed, Map.take(attrs, [:source_key, :group_id, :tenant_id])}

      components == [] ->
        :ok

      true ->
        BillingCore.RepoCharges.charge_meter_event(%{
          repo: attrs[:repo],
          sql_runner: attrs[:sql_runner],
          resource_kind: "voice",
          billing_account_id: account_id,
          source_key: attrs[:source_key],
          provider: attrs[:provider],
          sku: attrs[:sku],
          metered_at: attrs[:metered_at] || DateTime.utc_now(),
          meter_components: Enum.map(components, &component/1),
          owner_snapshot: owner,
          surface: owner["surface"] || "unknown",
          product_owner_type: owner["product_owner_type"] || "unknown",
          product_owner_id: owner["product_owner_id"] || "unknown",
          tenant_id: owner["salix_tenant_id"] || attrs[:tenant_id],
          group_id: owner["salix_group_id"] || attrs[:group_id],
          entrypoint: "voice_call",
          actor_type: "system",
          carrier: attrs[:carrier],
          key_id: attrs[:key_id]
        })
        |> tap(&log_failure(&1, attrs))
    end
  end

  defp component(component) do
    %{
      component: component[:component],
      meter_unit: component[:meter_unit] || :second,
      quantity: quantity(component)
    }
  end

  defp quantity(%{quantity: quantity}) when is_integer(quantity) and quantity > 0, do: quantity
  defp quantity(_component), do: 0

  defp log_failure({:error, reason}, attrs),
    do:
      Logger.error(
        "voice charge failed source_key=#{attrs[:source_key]} reason=#{inspect(reason)}"
      )

  defp log_failure(_result, _attrs), do: :ok

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_value), do: %{}

  defp present?(value), do: is_binary(value) and value != ""
end
