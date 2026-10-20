defmodule SystemsObservability.HistogramReporterTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SystemsObservability"]
  import Telemetry.Metrics

  alias SystemsObservability.HistogramReporter

  @event [:systems_observability, :test, :bounded_histogram]
  @native_event [:systems_observability, :test, :native_histogram]

  test "sustained observations stay within fixed series shards without a scrape" do
    reporter = start_reporter(max_series: 8)

    emit("ok", 1.0)
    initial = HistogramReporter.stats(reporter)

    Enum.each(1..100_000, fn _ -> emit("ok", 1.0) end)

    assert HistogramReporter.stats(reporter) == initial
    assert initial.series == 1
    assert initial.shard_entries == 16
    assert initial.dropped_updates == 0

    scrape = HistogramReporter.scrape(reporter)

    assert scrape =~
             ~s(test_bounded_duration_seconds_count{outcome="ok"} 100001)

    assert scrape =~
             ~s(test_bounded_duration_seconds_bucket{outcome="ok",le="1.0"} 100001)
  end

  test "series saturation is bounded and observable" do
    reporter = start_reporter(max_series: 1)

    emit("ok", 1.0)
    emit("overflow", 2.0)

    stats = HistogramReporter.stats(reporter)
    assert stats.series == 1
    assert stats.shard_entries == 16
    assert stats.series_limit == 1
    assert stats.dropped_series == 1

    scrape = HistogramReporter.scrape(reporter)
    assert scrape =~ ~s(outcome="ok")
    refute scrape =~ ~s(outcome="overflow")
  end

  test "non-stringable labels are rejected without poisoning later scrapes" do
    reporter = start_reporter(max_series: 8)

    emit(%{secret: "hostile"}, 1.0)

    assert %{invalid_events: 1, series: 0} = HistogramReporter.stats(reporter)

    emit("ok", 1.0)

    assert HistogramReporter.scrape(reporter) =~
             ~s(test_bounded_duration_seconds_count{outcome="ok"} 1)
  end

  test "metric unit conversion runs before bucketing and summing" do
    reporter = start_reporter([], [native_metric()])
    duration = System.convert_time_unit(2, :millisecond, :native)

    SystemsRuntime.Telemetry.execute(@native_event, %{duration: duration}, %{})

    scrape = HistogramReporter.scrape(reporter)
    assert scrape =~ ~s(test_native_duration_seconds_bucket{le="0.005"} 1)

    assert [_, sum] = Regex.run(~r/test_native_duration_seconds_sum ([^\n]+)/, scrape)
    assert_in_delta String.to_float(sum), 0.002, 1.0e-12
  end

  test "scrape performs one bounded lookup per series shard without per-series table scans" do
    reporter = start_reporter(max_series: 128)

    Enum.each(1..64, fn index -> emit("series-#{index}", 1.0) end)

    %{shard_table: shard_table} = GenServer.call(reporter, :scrape_config)

    {lookup_calls, match_object_calls} =
      trace_ets_calls(shard_table, fn -> HistogramReporter.scrape(reporter) end)

    assert lookup_calls == 64 * 16

    # `:ets.tab2list/1` may make one traced `match_object` call for the series
    # table. There must never be one full shard-table scan per series.
    assert match_object_calls <= 1
  end

  defp start_reporter(opts, metrics \\ [metric()]) do
    name = Module.concat(__MODULE__, "Reporter#{System.unique_integer([:positive])}")

    start_supervised!(
      {HistogramReporter, [name: name, metrics: metrics] ++ opts},
      id: name
    )

    name
  end

  defp metric do
    distribution("test.bounded.duration.seconds",
      event_name: @event,
      measurement: :duration,
      tags: [:outcome],
      tag_values: &Map.take(&1, [:outcome]),
      reporter_options: [buckets: [0.5, 1.0, 2.0]]
    )
  end

  defp native_metric do
    distribution("test.native.duration.seconds",
      event_name: @native_event,
      measurement: :duration,
      unit: {:native, :second},
      reporter_options: [buckets: [0.001, 0.005, 0.01]]
    )
  end

  defp emit(outcome, duration) do
    SystemsRuntime.Telemetry.execute(@event, %{duration: duration}, %{outcome: outcome})
  end

  # Counts this process's lookups in `table`, and its match_object calls: a
  # lookup elsewhere (a module that loads on first use, say) is not the
  # scrape's.
  defp trace_ets_calls(table, fun) do
    parent = SystemsRuntime.Proc.self()
    tracer = SystemsRuntime.Proc.spawn(fn -> trace_collector(parent, table, 0, 0) end)

    :erlang.trace_pattern({:ets, :lookup, 2}, true, [])
    :erlang.trace_pattern({:ets, :match_object, 2}, true, [])
    :erlang.trace(SystemsRuntime.Proc.self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
      delivered = :erlang.trace_delivered(SystemsRuntime.Proc.self())
      settle_receive({:trace_delivered, _, ^delivered})
      SystemsRuntime.Proc.send(tracer, {:counts, SystemsRuntime.Proc.self()})
      settle_receive({:trace_counts, lookup_calls, match_object_calls})
      {lookup_calls, match_object_calls}
    after
      :erlang.trace(SystemsRuntime.Proc.self(), false, [:call])
      :erlang.trace_pattern({:ets, :lookup, 2}, false, [])
      :erlang.trace_pattern({:ets, :match_object, 2}, false, [])
      SystemsRuntime.Proc.exit(tracer, :kill)
    end
  end

  defp trace_collector(parent, table, lookup_calls, match_object_calls) do
    SystemsRuntime.Proc.receive do
      {:trace, ^parent, :call, {:ets, :lookup, [^table, _key]}} ->
        trace_collector(parent, table, lookup_calls + 1, match_object_calls)

      {:trace, ^parent, :call, {:ets, :lookup, _arguments}} ->
        trace_collector(parent, table, lookup_calls, match_object_calls)

      {:trace, ^parent, :call, {:ets, :match_object, _arguments}} ->
        trace_collector(parent, table, lookup_calls, match_object_calls + 1)

      {:counts, requester} ->
        SystemsRuntime.Proc.send(requester, {:trace_counts, lookup_calls, match_object_calls})
    end
  end
end
