defmodule SalixWeb.CloudVM.FleetMetrics do
  @moduledoc """
  The Group Cloud VM fleet gauges: `salix.vm.records{provider,state}` and
  `salix.vm.transitional.oldest_age.seconds{provider,state}` (`Salix.Telemetry`).

  One aggregate read (`SalixStore.Compute.group_workload_fleet/0`), published
  by `SalixEnv.ComputeReconciler` once a minute per node on its sweep tick.
  Record statuses are summed under the `state` label they normalize to before
  anything is published, so two statuses that share a label do not overwrite
  each other, and every provider and label gets a value, 0 when no record
  stands there, so a gauge that stood at 1 falls back.
  """

  require Logger

  alias SalixStore.Compute

  @providers ~w(cloudflare agent_vmm)

  @doc "Publish the fleet gauges. `:ok`, or the read's error (the gauges keep their last values)."
  @spec emit(keyword()) :: :ok | {:error, term()}
  def emit(opts \\ []) do
    with {:ok, rows} <- Compute.group_workload_fleet() do
      now = Keyword.get(opts, :now, SystemsClock.system_time(:millisecond))

      by_label =
        Enum.reduce(rows, %{}, fn row, acc ->
          key = {provider_tag(row.provider), Salix.Telemetry.vm_state_tag(row.status)}

          Map.update(acc, key, {row.count, row.oldest_ms}, fn {count, oldest} ->
            {count + row.count, min_ms(oldest, row.oldest_ms)}
          end)
        end)

      providers = Enum.uniq(@providers ++ Enum.map(Map.keys(by_label), &elem(&1, 0)))

      for provider <- providers, state <- Salix.Telemetry.vm_states() do
        {count, _oldest} = Map.get(by_label, {provider, state}, {0, nil})

        SystemsRuntime.Telemetry.execute(
          [:salix, :vm, :fleet, :records],
          %{count: count},
          %{provider: provider, state: state}
        )
      end

      for provider <- providers, state <- Salix.Telemetry.vm_transitional_states() do
        age_seconds =
          case Map.get(by_label, {provider, state}) do
            {_count, oldest} when is_integer(oldest) -> max(now - oldest, 0) / 1_000
            _ -> 0
          end

        SystemsRuntime.Telemetry.execute(
          [:salix, :vm, :fleet, :oldest_age],
          %{age_seconds: age_seconds},
          %{provider: provider, state: state}
        )
      end

      :ok
    end
  rescue
    exception ->
      Logger.warning("Cloud VM fleet metrics skipped",
        stage: :fleet_metrics,
        exception: inspect(exception.__struct__)
      )

      {:error, :unavailable}
  end

  defp provider_tag(provider) when provider in @providers, do: provider
  defp provider_tag(_provider), do: "other"

  defp min_ms(nil, other), do: other
  defp min_ms(value, nil), do: value
  defp min_ms(value, other), do: min(value, other)
end
