defmodule SystemsObservability.Telemetry do
  @moduledoc "Common VM-local telemetry metrics."
  import Telemetry.Metrics

  alias SystemsObservability.Classifier

  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]

  def metrics do
    http_options = [
      event_name: [:comma_system, :http, :stop],
      tags: [:endpoint, :route, :method, :status_class],
      tag_values: &http_tags/1
    ]

    db_options = [
      event_name: [:comma_system, :db, :query],
      tags: [:component, :repo, :operation, :outcome],
      tag_values: &db_tags/1
    ]

    [
      counter("comma.system.http.requests.total", http_options),
      distribution(
        "comma.system.http.duration.seconds",
        http_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @buckets]
          ]
      ),
      counter("comma.system.db.queries.total", db_options),
      distribution(
        "comma.system.db.duration.seconds",
        db_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @buckets]
          ]
      ),
      distribution("comma.system.db.pool.wait.seconds",
        event_name: [:comma_system, :db, :query],
        measurement: :queue_time,
        tags: [:component, :repo],
        tag_values: &db_pool_tags/1,
        unit: {:native, :second},
        reporter_options: [buckets: @buckets]
      )
    ] ++ runtime_metrics() ++ pipeline_metrics() ++ startup_metrics()
  end

  defp runtime_metrics do
    [
      last_value("comma.system.beam.memory.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        unit: :byte
      ),
      last_value("comma.system.beam.run.queue",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :total
      ),
      last_value("comma.system.beam.processes",
        event_name: [:vm, :system_counts],
        measurement: :process_count
      ),
      last_value("comma.system.beam.ports",
        event_name: [:vm, :system_counts],
        measurement: :port_count
      )
    ]
  end

  defp pipeline_metrics do
    reason_options = [tags: [:reason], tag_values: &reason_tags/1]

    [
      counter(
        "comma.system.telemetry.handler.failures.total",
        reason_options ++ [event_name: [:systems_observability, :handler, :failure]]
      ),
      last_value("comma.system.telemetry.series.current",
        event_name: [:systems_observability, :series, :budget],
        measurement: :value
      )
    ]
  end

  defp startup_metrics do
    [
      distribution("comma.system.startup.duration.seconds",
        event_name: [:comma_system, :startup, :stop],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: [1, 2.5, 5, 10, 30, 60, 120, 300, 600]]
      )
    ]
  end

  defp http_tags(metadata) do
    conn = metadata[:conn]
    options = metadata[:options] || []
    status = metadata[:status] || (conn && conn.status)
    method = metadata[:method] || (conn && conn.method)
    endpoint = Classifier.endpoint(metadata[:endpoint] || options[:endpoint])

    %{
      endpoint: endpoint,
      route: Classifier.route_template(endpoint, route_template(metadata[:route])),
      method: Classifier.method(method),
      status_class: Classifier.status_class(status)
    }
  end

  defp route_template(route) when is_binary(route), do: route
  defp route_template(_route), do: "unmatched"

  defp db_tags(metadata) do
    %{
      component: db_component(metadata[:component]),
      repo: Classifier.repo(metadata[:repo]),
      operation: finite(metadata[:operation], ~w(query transaction checkout other)),
      outcome: Classifier.outcome(metadata[:outcome])
    }
  end

  defp db_pool_tags(metadata), do: Map.take(db_tags(metadata), [:component, :repo])

  defp reason_tags(%{reason: reason})
       when reason in [:invalid_measurement, "invalid_measurement"],
       do: %{reason: "invalid_measurement"}

  defp reason_tags(_metadata), do: %{reason: "other"}

  defp db_component(value) do
    finite(value, ~w(bridge_for_teams billing comma_product salix other))
  end

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
