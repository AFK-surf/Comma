defmodule SystemsObservability.EctoHandler do
  @moduledoc false
  use GenServer

  require OpenTelemetry.Tracer

  @events [
    [:bridge_for_teams, :repo, :query],
    [:billing_core, :repo, :query],
    [:comma, :repo, :query],
    [:salix_store, :repo, :query]
  ]

  @span_name "comma.db.query"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    # This handler owns both the metric and trace boundary. Detach the upstream
    # integration defensively so a hot upgrade or duplicate setup cannot retain
    # its URL, source, statement, or exception-bearing spans.
    Enum.each(@events, &:telemetry.detach({OpentelemetryEcto, &1}))
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(__MODULE__)
  end

  def handle_event(event, measurements, metadata, _config) do
    try do
      {component, repo} = identity(event)

      normalized = %{
        component: component,
        repo: repo,
        operation: operation(metadata),
        outcome: if(match?({:error, _}, metadata[:result]), do: "error", else: "ok")
      }

      measurements =
        measurements
        |> Map.put(:duration, measurements[:total_time] || measurements[:query_time] || 0)
        |> Map.put_new(:queue_time, 0)

      :telemetry.execute([:comma_system, :db, :query], measurements, normalized)
      record_span(measurements, normalized)
    rescue
      _exception -> handler_failure()
    catch
      _kind, _reason -> handler_failure()
    end
  end

  defp identity([:bridge_for_teams | _]), do: {"bridge_for_teams", "bft"}
  defp identity([:billing_core | _]), do: {"billing", "billing"}
  defp identity([:comma | _]), do: {"comma_product", "comma"}
  defp identity([:salix_store | _]), do: {"salix", "salix"}

  defp operation(%{source: "schema_migrations"}), do: "transaction"

  defp operation(%{query: query}) when is_binary(query) do
    case query
         |> String.trim_leading()
         |> String.split(" ", parts: 2)
         |> hd()
         |> String.upcase() do
      value when value in ~w(BEGIN COMMIT ROLLBACK) -> "transaction"
      _ -> "query"
    end
  end

  defp operation(_metadata), do: "other"

  defp record_span(measurements, attributes) do
    end_time = :opentelemetry.timestamp()
    duration = finite_duration(measurements[:duration])
    parent_token = attach_propagated_parent()

    try do
      span =
        OpenTelemetry.Tracer.start_span(@span_name, %{
          start_time: end_time - duration,
          attributes: Map.new(attributes, fn {key, value} -> {to_string(key), value} end),
          kind: :client
        })

      if attributes.outcome == "error" do
        OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, ""))
      end

      OpenTelemetry.Span.end_span(span, end_time)
      :ok
    after
      detach_parent(parent_token)
    end
  end

  defp finite_duration(value) when is_integer(value) and value >= 0, do: value
  defp finite_duration(_value), do: 0

  defp attach_propagated_parent do
    parent_context =
      case OpentelemetryProcessPropagator.fetch_ctx(self()) do
        :undefined -> OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers")
        context -> context
      end

    if parent_context == :undefined do
      :undefined
    else
      OpenTelemetry.Ctx.attach(parent_context)
    end
  end

  defp detach_parent(:undefined), do: :ok
  defp detach_parent(nil), do: :ok
  defp detach_parent(token), do: OpenTelemetry.Ctx.detach(token)

  defp handler_failure do
    :telemetry.execute(
      [:systems_observability, :handler, :failure],
      %{},
      %{reason: "invalid_measurement"}
    )

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
