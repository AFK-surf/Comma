defmodule SystemsObservability.Metrics do
  @moduledoc "The VM-local metric definition composition root."

  @allowed_labels ~w(component surface endpoint route method status_class provider profile model_key operation outcome result repo queue state kind sink reason trigger transport mode phase source_mode lane variant)a

  def enabled_metrics(subsystems) do
    SystemsObservability.Telemetry.metrics()
    |> Kernel.++(domain_metrics(subsystems))
    |> validate_unique!()
    |> validate_labels!()
    |> validate_histograms!()
  end

  defp validate_unique!(metrics) do
    duplicates =
      metrics
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, definitions} -> length(definitions) > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicates do
      [] -> metrics
      names -> raise ArgumentError, "duplicate telemetry metrics: #{inspect(names)}"
    end
  end

  defp validate_labels!(metrics) do
    Enum.each(metrics, fn metric ->
      invalid = Map.get(metric, :tags, []) -- @allowed_labels

      if invalid != [] do
        raise ArgumentError,
              "metric #{inspect(metric.name)} contains labels outside the allowlist: #{inspect(invalid)}"
      end
    end)

    metrics
  end

  defp domain_metrics(subsystems) do
    modules =
      subsystems
      |> Enum.flat_map(fn
        :alert_router ->
          [AlertRouter.Telemetry]

        :bridge_for_teams ->
          [BridgeForTeams.Telemetry, BillingTelemetry]

        :comma_product ->
          [CommaProduct.Telemetry, BillingTelemetry]

        :salix ->
          [
            Salix.Telemetry,
            SalixIM.Triage.Telemetry,
            SalixIM.SlackCommandSync,
            SalixSignal.Telemetry,
            BillingTelemetry
          ]

        _ ->
          []
      end)
      |> Enum.uniq()

    Enum.flat_map(modules, fn module ->
      if Code.ensure_loaded?(module), do: module.metrics(), else: []
    end)
  end

  defp validate_histograms!(metrics) do
    Enum.each(metrics, fn
      %Telemetry.Metrics.Distribution{name: name, reporter_options: options} ->
        buckets = options[:buckets]

        unless is_list(buckets) and buckets != [] and Enum.all?(buckets, &is_number/1) do
          raise ArgumentError, "histogram #{inspect(name)} must declare numeric buckets"
        end

      _metric ->
        :ok
    end)

    metrics
  end
end
