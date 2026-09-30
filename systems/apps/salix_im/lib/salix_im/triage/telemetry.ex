defmodule SalixIM.Triage.Telemetry do
  @moduledoc """
  Finite, content-free telemetry for the BFT-native Triage pipeline.

  This module is observational only. It normalizes every label before emitting
  and never lets telemetry handler failure change a business return value.
  """

  import Telemetry.Metrics

  @event [:salix, :triage, :phase, :stop]
  @recovery_event [:salix, :triage, :recovery, :status]
  @clickhouse_batch_event [:salix, :triage, :clickhouse_etl, :batch]
  @clickhouse_row_event [:salix, :triage, :clickhouse_etl, :row]
  @phases ~w(accept seal fence evaluation tool_call terminal recovery replay intake_index other)
  @outcomes ~w(ok error timeout unavailable conflict rejected skipped unknown other)
  @source_modes ~w(callback historical patrol system other)
  @surfaces ~w(bft system other)
  @recovery_lanes ~w(buckets fences other)
  @duration_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]

  @doc "Prometheus-owned definitions for every native-Triage telemetry event."
  def metrics do
    phase_options = [
      event_name: @event,
      tags: [:phase, :outcome, :source_mode, :surface],
      tag_values: &phase_tags/1
    ]

    [
      counter("salix.triage.phases.total", phase_options),
      distribution(
        "salix.triage.phase.duration.seconds",
        phase_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @duration_buckets]
          ]
      ),
      last_value("salix.triage.recovery.backlog",
        event_name: @recovery_event,
        measurement: :backlog,
        tags: [:lane],
        tag_values: &recovery_lane_tags/1
      ),
      sum("salix.triage.recovery.record_errors.total",
        event_name: @recovery_event,
        measurement: :record_errors,
        tags: [:lane, :outcome],
        tag_values: &recovery_tags/1,
        reporter_options: [prometheus_type: :counter]
      ),
      # Which patrol batches completed, failed, or stopped for confirmed ineligible authority?
      # `inactive` counts successful suspensions once. It does not prove missing messages.
      # Check current bot membership and channel authority separately.
      counter("salix.triage.clickhouse.etl.batches.total",
        event_name: @clickhouse_batch_event,
        tags: [:outcome],
        tag_values: &clickhouse_batch_tags/1
      ),
      sum("salix.triage.clickhouse.etl.rows.total",
        event_name: @clickhouse_row_event,
        measurement: :count,
        tags: [:outcome],
        tag_values: &clickhouse_row_tags/1,
        reporter_options: [prometheus_type: :counter]
      )
    ]
  end

  @spec start() :: integer()
  def start, do: System.monotonic_time()

  @spec emit(term(), term(), term(), term(), integer()) :: :ok
  def emit(phase, outcome, source_mode, surface, started_at) do
    measurements = %{duration: elapsed(started_at)}

    metadata = %{
      phase: finite(phase, @phases),
      outcome: finite(outcome, @outcomes),
      source_mode: normalize_source_mode(source_mode),
      surface: finite(surface, @surfaces)
    }

    safe_execute(@event, measurements, metadata)
  end

  @spec observe(term(), term(), term(), (-> result)) :: result when result: term()
  def observe(phase, source_mode, surface, fun) when is_function(fun, 0) do
    started_at = start()

    try do
      result = fun.()
      emit(phase, outcome(result), source_mode, surface, started_at)
      result
    rescue
      error ->
        emit(phase, :error, source_mode, surface, started_at)
        reraise(error, __STACKTRACE__)
    catch
      kind, reason ->
        emit(phase, :error, source_mode, surface, started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Emits one content-free ClickHouse patrol settlement and its row counts."
  @spec emit_clickhouse_batch(:ok | :error | :inactive, map()) :: :ok
  def emit_clickhouse_batch(outcome, counts)
      when outcome in [:ok, :error, :inactive] and is_map(counts) do
    safe_execute(@clickhouse_batch_event, %{count: 1}, %{outcome: Atom.to_string(outcome)})

    for row_outcome <- [:created, :duplicate, :ineligible],
        count = Map.get(counts, row_outcome, 0),
        is_integer(count) and count > 0 do
      safe_execute(
        @clickhouse_row_event,
        %{count: count},
        %{outcome: Atom.to_string(row_outcome)}
      )
    end

    :ok
  end

  def emit_clickhouse_batch(_outcome, _counts), do: :ok

  @spec emit_recovery_status(term(), term(), term(), term()) :: :ok
  def emit_recovery_status(lane, outcome, backlog, record_errors \\ 0) do
    measurements = %{
      backlog: normalize_backlog(backlog),
      record_errors: normalize_count(record_errors)
    }

    metadata = %{
      lane: finite(lane, @recovery_lanes),
      outcome: finite(outcome, @outcomes)
    }

    safe_execute(@recovery_event, measurements, metadata)
  end

  defp safe_execute(event, measurements, metadata) do
    try do
      :telemetry.execute(event, measurements, metadata)
    rescue
      _handler_failure -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp phase_tags(metadata) do
    %{
      phase: finite(metadata[:phase], @phases),
      outcome: finite(metadata[:outcome], @outcomes),
      source_mode: normalize_source_mode(metadata[:source_mode]),
      surface: finite(metadata[:surface], @surfaces)
    }
  end

  defp recovery_lane_tags(metadata),
    do: %{lane: finite(metadata[:lane], @recovery_lanes)}

  defp recovery_tags(metadata) do
    %{
      lane: finite(metadata[:lane], @recovery_lanes),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp elapsed(started_at) when is_integer(started_at),
    do: max(0, System.monotonic_time() - started_at)

  defp elapsed(_started_at), do: 0

  defp normalize_backlog(value) when value in [0, 1], do: value
  defp normalize_backlog(true), do: 1
  defp normalize_backlog(_value), do: 0

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_value), do: 0

  defp outcome(result) when result in [:ok, :business_result], do: "ok"
  defp outcome({:ok, _value}), do: "ok"
  defp outcome({:ok, _first, _second}), do: "ok"
  defp outcome({:error, :timeout}), do: "timeout"
  defp outcome({:error, :unavailable}), do: "unavailable"
  defp outcome({:error, :conflict}), do: "conflict"
  defp outcome({:error, _reason}), do: "error"

  defp outcome(result) when is_tuple(result) and tuple_size(result) > 0 do
    case elem(result, 0) do
      :ok -> "ok"
      :error -> "error"
      _other -> "unknown"
    end
  end

  # A shape this module does not recognize is not a success. Labelling it "ok"
  # made every unclassified return read as a healthy run on the dashboard.
  defp outcome(_result), do: "unknown"

  defp normalize_source_mode(value)
       when value in [:callback, "callback"],
       do: "callback"

  defp normalize_source_mode(value)
       when value in [
              :historical,
              "historical",
              :historical_thread_reenactment,
              "historical_thread_reenactment"
            ],
       do: "historical"

  defp normalize_source_mode(value)
       when value in [
              :patrol,
              "patrol",
              :clickhouse_etl,
              "clickhouse_etl",
              :periodic_patrol,
              "periodic_patrol",
              :scheduled_recheck,
              "scheduled_recheck"
            ],
       do: "patrol"

  defp normalize_source_mode(value) when value in [:system, "system"], do: "system"
  defp normalize_source_mode(value), do: finite(value, @source_modes)

  defp clickhouse_batch_tags(metadata),
    do: %{outcome: finite(metadata[:outcome], ~w(ok error inactive))}

  defp clickhouse_row_tags(metadata),
    do: %{outcome: finite(metadata[:outcome], ~w(created duplicate ineligible))}

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
