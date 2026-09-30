defmodule BridgeForTeams.Telemetry do
  @moduledoc "BFT-owned telemetry metrics and bounded emitters."
  import Telemetry.Metrics

  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  @outcomes ~w(ok error timeout unavailable conflict rejected cancelled other)
  @operation_providers %{
    mount: "other",
    sso: "feishu",
    salix_erpc: "other",
    reconcile: "other",
    projection_refresh: "other",
    environment_provision: "other",
    runner_claim: "other",
    runner_heartbeat: "other",
    artifact_sweep: "s3",
    storage_sweep: "s3",
    sourced_context_acquisition: "other",
    sourced_context_derivation: "other",
    sourced_context_preview: "other",
    sourced_context_publication: "other",
    sourced_context_grounding: "other",
    sourced_context_knowledge: "other",
    context_lifecycle: "other"
  }
  @operations @operation_providers |> Map.keys() |> Enum.map(&Atom.to_string/1)
  @providers @operation_providers |> Map.values() |> Enum.uniq() |> Kernel.++(["other"])

  def metrics do
    operation_options = [
      event_name: [:bridge_for_teams, :operation, :stop],
      tags: [:operation, :provider, :outcome],
      tag_values: &operation_tags/1
    ]

    [
      counter("bft.operations.total", operation_options),
      distribution(
        "bft.operations.duration.seconds",
        operation_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @buckets]
          ]
      ),
      counter("bft.read.cache.requests.total",
        event_name: [:bridge_for_teams, :read_cache],
        tags: [:result],
        tag_values: &cache_tags/1
      ),
      sum("bft.sweeper.scanned.total",
        event_name: [:bridge_for_teams, :sweeper, :stop],
        measurement: :value,
        tags: [:operation, :outcome],
        tag_values: &sweeper_tags/1,
        reporter_options: [prometheus_type: :counter]
      )
    ]
  end

  def emit_operation(operation, outcome, duration, metadata \\ %{}) do
    :telemetry.execute(
      [:bridge_for_teams, :operation, :stop],
      %{duration: duration},
      Map.merge(metadata, %{
        operation: operation,
        provider: Map.get(@operation_providers, operation, "other"),
        outcome: outcome
      })
    )
  end

  defp operation_tags(metadata) do
    %{
      operation: finite(metadata[:operation], @operations),
      provider: finite(metadata[:provider], @providers),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp cache_tags(metadata), do: %{result: finite(metadata[:result], ~w(hit miss other))}

  defp sweeper_tags(metadata) do
    %{
      operation: finite(metadata[:operation], ~w(artifact_sweep storage_sweep other)),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
