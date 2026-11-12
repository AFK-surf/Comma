defmodule SystemsObservability.Metrics do
  @moduledoc """
  The VM-local metric definition composition root.

  A counter, sum or distribution may list label maps in
  `reporter_options: [zero_series: [...]]`: the reporters expose each series
  at 0 from their start, before its first event. GMP takes a counter's first
  sample as its zero point, so without one the first event after a restart
  is no increase. A gauge has none: 0 would be a value it never had.
  """

  alias Telemetry.Metrics.{Counter, Distribution, Sum}

  @allowed_labels ~w(component surface endpoint route method status_class provider profile model_key operation outcome result repo queue state kind sink reason trigger transport mode phase source_mode lane variant)a

  def enabled_metrics(subsystems) do
    SystemsObservability.Telemetry.metrics()
    |> Kernel.++(domain_metrics(subsystems))
    |> validate_unique!()
    |> validate_labels!()
    |> validate_histograms!()
    |> validate_zero_series!()
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

  defp validate_zero_series!(metrics) do
    Enum.each(metrics, fn metric ->
      case Keyword.get(metric.reporter_options, :zero_series, []) do
        [] ->
          :ok

        series ->
          tags = Enum.sort(metric.tags)

          valid? =
            metric.__struct__ in [Counter, Sum, Distribution] and
              is_list(series) and
              Enum.all?(series, fn labels ->
                is_map(labels) and Enum.sort(Map.keys(labels)) == tags and
                  Enum.all?(Map.values(labels), &is_binary/1)
              end)

          unless valid? do
            raise ArgumentError,
                  "metric #{inspect(metric.name)} declares zero_series that are not " <>
                    "string label maps of its tags on a counter, sum or distribution"
          end
      end
    end)

    metrics
  end
end
