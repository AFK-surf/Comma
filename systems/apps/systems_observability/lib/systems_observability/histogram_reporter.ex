defmodule SystemsObservability.HistogramReporter do
  @moduledoc false
  use GenServer

  alias Telemetry.Metrics.Distribution
  alias TelemetryMetricsPrometheus.Core.Exporter

  @shards 16
  @max_series 8_192
  @max_cas_attempts 32

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def scrape(reporter) do
    %{metrics: metrics, series_table: series_table, shard_table: shard_table, shards: shards} =
      GenServer.call(reporter, :scrape_config)

    time_series =
      series_table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn {{metric_id, labels}, series_id}, acc ->
        metric = Map.fetch!(metrics, metric_id)
        aggregation = aggregate(metric, series_id, shard_table, shards)

        Map.update(
          acc,
          metric.name,
          [{{metric.name, labels}, aggregation}],
          &[{{metric.name, labels}, aggregation} | &1]
        )
      end)

    metrics
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> then(&Exporter.export(time_series, &1))
  end

  def stats(reporter), do: GenServer.call(reporter, :stats)

  @impl true
  def init(opts) do
    metrics = Keyword.fetch!(opts, :metrics)
    shards = Keyword.get(opts, :shards, @shards)
    series_limit = Keyword.get(opts, :max_series, @max_series)

    unless is_integer(shards) and shards > 0 do
      raise ArgumentError, ":shards must be a positive integer"
    end

    unless is_integer(series_limit) and series_limit > 0 do
      raise ArgumentError, ":max_series must be a positive integer"
    end

    unless Enum.all?(metrics, &match?(%Distribution{}, &1)) do
      raise ArgumentError, "HistogramReporter accepts only distribution metrics"
    end

    series_table = :ets.new(:systems_observability_histogram_series, table_options())
    shard_table = :ets.new(:systems_observability_histogram_shards, table_options())
    stats_table = :ets.new(:systems_observability_histogram_stats, table_options())

    :ets.insert(stats_table, [
      {:reserved_series, 0},
      {:dropped_series, 0},
      {:dropped_updates, 0},
      {:invalid_events, 0}
    ])

    owner = self()

    {metric_map, handlers} =
      metrics
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, []}, fn {metric, metric_id}, {metric_map, handlers} ->
        handler_id = {__MODULE__, owner, metric.name}

        config = %{
          buckets: Keyword.fetch!(metric.reporter_options, :buckets),
          handler_id: handler_id,
          keep: metric.keep,
          max_series: series_limit,
          measurement: metric.measurement,
          metric_id: metric_id,
          series_table: series_table,
          shard_table: shard_table,
          shards: shards,
          stats_table: stats_table,
          tags: metric.tags,
          tag_values: metric.tag_values
        }

        :ok =
          :telemetry.attach(
            handler_id,
            metric.event_name,
            &__MODULE__.handle_event/4,
            config
          )

        {Map.put(metric_map, metric_id, metric), [handler_id | handlers]}
      end)

    {:ok,
     %{
       handlers: handlers,
       metrics: metric_map,
       series_limit: series_limit,
       series_table: series_table,
       shard_table: shard_table,
       shards: shards,
       stats_table: stats_table
     }}
  end

  @impl true
  def handle_call(:scrape_config, _from, state) do
    {:reply, Map.take(state, [:metrics, :series_table, :shard_table, :shards]), state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      dropped_series: counter(state.stats_table, :dropped_series),
      dropped_updates: counter(state.stats_table, :dropped_updates),
      invalid_events: counter(state.stats_table, :invalid_events),
      series: :ets.info(state.series_table, :size),
      series_limit: state.series_limit,
      shard_entries: :ets.info(state.shard_table, :size),
      shards: state.shards
    }

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handlers, &:telemetry.detach/1)
    :ok
  end

  @doc false
  def handle_event(_event, measurements, metadata, config) do
    if :ets.info(config.series_table) == :undefined do
      :telemetry.detach(config.handler_id)
    else
      record(measurements, metadata, config)
    end

    :ok
  rescue
    _exception ->
      invalid_event(config)
  catch
    _kind, _reason ->
      invalid_event(config)
  end

  defp record(measurements, metadata, config) do
    with true <- keep?(config.keep, measurements, metadata),
         {:ok, measurement} <- measurement(config.measurement, measurements, metadata),
         {:ok, labels} <- labels(config.tags, config.tag_values, metadata),
         {:ok, series_id} <- series(config, labels) do
      shard = :erlang.phash2(self(), config.shards)
      bucket = bucket_index(measurement, config.buckets)
      update_shard(config, series_id, shard, bucket, measurement, @max_cas_attempts)
    else
      false -> :ok
      {:error, :series_limit} -> :ok
      {:error, _reason} -> invalid_event(config)
    end
  end

  defp keep?(nil, _measurements, _metadata), do: true
  defp keep?(fun, _measurements, metadata) when is_function(fun, 1), do: fun.(metadata)

  defp keep?(fun, measurements, metadata) when is_function(fun, 2),
    do: fun.(metadata, measurements)

  defp measurement(key, measurements, _metadata) when is_atom(key),
    do: number(Map.get(measurements, key))

  defp measurement(fun, measurements, _metadata) when is_function(fun, 1),
    do: number(fun.(measurements))

  defp measurement(fun, measurements, metadata) when is_function(fun, 2),
    do: number(fun.(measurements, metadata))

  defp measurement(_measurement, _measurements, _metadata), do: {:error, :measurement}

  defp number(value) when is_number(value), do: {:ok, value}
  defp number(_value), do: {:error, :measurement}

  defp labels(tags, tag_values, metadata) do
    values = tag_values.(metadata)

    if is_map(values) do
      Enum.reduce_while(tags, {:ok, %{}}, fn tag, {:ok, labels} ->
        with {:ok, value} <- Map.fetch(values, tag),
             implementation when not is_nil(implementation) <- String.Chars.impl_for(value) do
          {:cont, {:ok, Map.put(labels, tag, to_string(value))}}
        else
          _error -> {:halt, {:error, :labels}}
        end
      end)
    else
      {:error, :labels}
    end
  end

  defp series(config, labels) do
    key = {config.metric_id, labels}

    case :ets.lookup(config.series_table, key) do
      [{^key, series_id}] ->
        {:ok, series_id}

      [] ->
        create_series(config, key)
    end
  end

  defp create_series(config, key) do
    reserved = :ets.update_counter(config.stats_table, :reserved_series, {2, 1})

    cond do
      reserved > config.max_series ->
        :ets.update_counter(config.stats_table, :reserved_series, {2, -1})

        case :ets.lookup(config.series_table, key) do
          [{^key, series_id}] -> {:ok, series_id}
          [] -> drop_series(config)
        end

      true ->
        series_id = :erlang.unique_integer([:positive, :monotonic])

        if :ets.insert_new(config.series_table, {key, series_id}) do
          initialize_shards(config, series_id)
          {:ok, series_id}
        else
          :ets.update_counter(config.stats_table, :reserved_series, {2, -1})

          case :ets.lookup(config.series_table, key) do
            [{^key, existing_id}] -> {:ok, existing_id}
            [] -> {:error, :series_race}
          end
        end
    end
  end

  defp initialize_shards(config, series_id) do
    zeros = List.duplicate(0, length(config.buckets) + 1) |> List.to_tuple()

    Enum.each(0..(config.shards - 1), fn shard ->
      row_id = row_id(series_id, shard, config.shards)
      :ets.insert_new(config.shard_table, {row_id, series_id, shard, 0, zeros, 0, 0})
    end)
  end

  defp update_shard(config, _series_id, _shard, _bucket, _measurement, 0) do
    increment(config.stats_table, :dropped_updates)
  end

  defp update_shard(config, series_id, shard, bucket, measurement, attempts) do
    row_id = row_id(series_id, shard, config.shards)

    case :ets.lookup(config.shard_table, row_id) do
      [{^row_id, ^series_id, ^shard, version, bins, count, sum}] ->
        updated_bins = put_elem(bins, bucket, elem(bins, bucket) + 1)

        replacement =
          {row_id, series_id, shard, version + 1, updated_bins, count + 1, sum + measurement}

        match_spec = [
          {{row_id, series_id, shard, version, :"$1", :"$2", :"$3"}, [], [{:const, replacement}]}
        ]

        case :ets.select_replace(config.shard_table, match_spec) do
          1 -> :ok
          0 -> update_shard(config, series_id, shard, bucket, measurement, attempts - 1)
        end

      [] ->
        bins = List.duplicate(0, length(config.buckets) + 1) |> List.to_tuple()
        bins = put_elem(bins, bucket, 1)

        if :ets.insert_new(
             config.shard_table,
             {row_id, series_id, shard, 1, bins, 1, measurement}
           ) do
          :ok
        else
          update_shard(config, series_id, shard, bucket, measurement, attempts - 1)
        end
    end
  end

  defp aggregate(metric, series_id, shard_table, shards) do
    buckets = Keyword.fetch!(metric.reporter_options, :buckets)
    empty_bins = List.duplicate(0, length(buckets) + 1)

    {bins, count, sum} =
      Enum.reduce(0..(shards - 1), {empty_bins, 0, 0}, fn shard, {bins, count, sum} ->
        row_id = row_id(series_id, shard, shards)

        case :ets.lookup(shard_table, row_id) do
          [{^row_id, ^series_id, ^shard, _version, shard_bins, shard_count, shard_sum}] ->
            merged_bins =
              Enum.zip_with(bins, Tuple.to_list(shard_bins), fn left, right -> left + right end)

            {merged_bins, count + shard_count, sum + shard_sum}

          [] ->
            {bins, count, sum}
        end
      end)

    {cumulative, _} =
      Enum.map_reduce(bins, 0, fn value, running ->
        running = running + value
        {running, running}
      end)

    upper_bounds = Enum.map(buckets, &to_string/1) ++ ["+Inf"]
    {Enum.zip(upper_bounds, cumulative), count, sum}
  end

  defp bucket_index(measurement, buckets) do
    Enum.find_index(buckets, &(measurement <= &1)) || length(buckets)
  end

  defp drop_series(config) do
    increment(config.stats_table, :dropped_series)
    {:error, :series_limit}
  end

  defp invalid_event(config) do
    increment(config.stats_table, :invalid_events)
    :ok
  rescue
    _ -> :ok
  end

  defp increment(table, key) do
    :ets.update_counter(table, key, {2, 1}, {key, 0})
    :ok
  end

  defp counter(table, key), do: :ets.lookup_element(table, key, 2)

  defp row_id(series_id, shard, shards), do: series_id * shards + shard

  defp table_options,
    do: [:set, :public, read_concurrency: true, write_concurrency: true]
end
