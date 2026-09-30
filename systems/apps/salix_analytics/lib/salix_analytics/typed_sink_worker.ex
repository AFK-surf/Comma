defmodule SalixAnalytics.TypedSinkWorker do
  @moduledoc """
  Bounded, mockable typed usage sink.

  Synchronous delivery uses `insert/2`. Reporting and LLM usage producers use
  separate ETS buffers. LLM delivery retains failed rows until retry or shutdown.
  There is no disk spill. Crashes, overflow, and shutdown timeout can lose rows.
  """

  use GenServer

  @default_timeout 5_000
  @default_batch_size 100
  @default_flush_ms 50
  @default_max_buffer 1_000

  def child_spec(opts) do
    %{id: opts[:name] || __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 30_000}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Bounded ack path for billable facts. Callers wait for sink confirmation."
  def insert(rows, opts \\ []) when is_list(rows) do
    server = opts[:server] || __MODULE__
    timeout = opts[:timeout] || @default_timeout
    GenServer.call(server, {:insert, rows}, timeout)
  end

  @doc """
  Nonblocking, best-effort reporting admission. The server must be a local name.

  Each row tries one slot in a fixed-size ETS ring. An occupied slot drops the
  new row, including during concurrent admission. A multi-row call can accept
  some rows and return `{:error, :queue_full}` for others. Do not retry reporting.
  Worker or node failure can lose the buffer. Shutdown rejects new admissions.
  """
  def enqueue(rows, opts \\ []) when is_list(rows) do
    table = opts[:server] || __MODULE__
    [{:accepting, true}] = :ets.lookup(table, :accepting)
    [{:capacity, capacity}] = :ets.lookup(table, :capacity)

    Enum.reduce(rows, :ok, fn row, result ->
      index = :ets.update_counter(table, :sequence, {2, 1})

      entry = {rem(index, capacity), index, row}

      if :ets.insert_new(table, entry) do
        if :ets.lookup(table, :accepting) == [{:accepting, true}] do
          result
        else
          :ets.delete_object(table, entry)
          {:error, :unavailable}
        end
      else
        :ets.update_counter(table, :dropped, {2, 1})
        {:error, :queue_full}
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    sink =
      opts[:sink] ||
        Application.get_env(:salix_analytics, :typed_sink, SalixAnalytics.Sink.ClickHouseTyped)

    Process.flag(:trap_exit, true)
    table = opts[:name] || __MODULE__
    capacity = opts[:max_buffer] || @default_max_buffer
    true = is_atom(table) and is_integer(capacity) and capacity > 0
    :ets.new(table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(table, [{:capacity, capacity}, {:sequence, 0}, {:dropped, 0}, {:accepting, true}])
    flush_ms = opts[:flush_ms] || @default_flush_ms
    Process.send_after(self(), :flush, flush_ms)

    {:ok,
     %{
       sink: sink,
       table: table,
       sink_name: if(opts[:sink_name] == "llm_usage", do: "llm_usage", else: "reporting"),
       retry_on_error: opts[:retry_on_error] == true,
       batch_size: opts[:batch_size] || @default_batch_size,
       flush_ms: flush_ms
     }}
  end

  @impl true
  def handle_call({:insert, rows}, _from, state) do
    started = System.monotonic_time()
    result = state.sink.insert(rows)
    outcome = if match?({:error, _}, result), do: "error", else: "ok"

    rows
    |> Enum.map(&(Map.get(&1, "surface") || Map.get(&1, :surface) || "other"))
    |> Enum.uniq()
    |> Enum.take(5)
    |> Enum.each(fn surface ->
      :telemetry.execute(
        [:billing, :operation, :stop],
        %{duration: System.monotonic_time() - started},
        %{
          surface: normalize_surface(surface),
          operation: "billable_insert",
          provider: "clickhouse",
          outcome: outcome
        }
      )
    end)

    {:reply, result, state}
  end

  @impl true
  def handle_info(:flush, state) do
    # No producer sends mailbox messages or runs telemetry handlers. The timer
    # bounds wakeups even while ClickHouse or a telemetry handler is blocked.
    dropped = :ets.update_counter(state.table, :dropped, {2, 0})

    if dropped > 0 do
      :ets.update_counter(state.table, :dropped, {2, -dropped})
      emit(:queue_full, %{value: dropped}, %{sink: state.sink_name})
      emit(:drop, %{value: dropped}, %{sink: state.sink_name})
    end

    entries = entries(state)
    emit(:queue, %{depth: length(entries)}, %{sink: state.sink_name})
    result = flush_entries(Enum.take(entries, state.batch_size), state)
    emit(:queue, %{depth: length(entries(state))}, %{sink: state.sink_name})

    delay =
      if state.retry_on_error and match?({:error, _}, result),
        do: max(state.flush_ms, 1_000),
        else: state.flush_ms

    Process.send_after(self(), :flush, delay)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.insert(state.table, {:accepting, false})
    # One final attempt per batch. The supervisor enforces the 30-second budget.
    entries(state) |> Enum.chunk_every(state.batch_size) |> Enum.each(&flush_entries(&1, state))
    remaining = length(entries(state))
    if remaining > 0, do: emit(:drop, %{value: remaining}, %{sink: state.sink_name})
    :ok
  end

  defp entries(state) do
    :ets.select(state.table, [{{:"$1", :"$2", :"$3"}, [], [:"$_"]}])
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp flush_entries([], _state), do: :ok

  defp flush_entries(entries, state) do
    started = System.monotonic_time()
    result = safe_insert(state.sink, Enum.map(entries, &elem(&1, 2)))
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    emit(:flush, %{duration: System.monotonic_time() - started}, %{
      sink: state.sink_name,
      outcome: outcome
    })

    if outcome == "ok" or not state.retry_on_error do
      Enum.each(entries, &:ets.delete_object(state.table, &1))
      if outcome == "error", do: emit(:drop, %{value: length(entries)}, %{sink: state.sink_name})
    end

    result
  end

  defp safe_insert(sink, rows) do
    sink.insert(rows)
  rescue
    _ -> {:error, :write_failed}
  catch
    _, _ -> {:error, :write_failed}
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:salix, :reporting, event], measurements, metadata)
  end

  defp normalize_surface(value) when value in ["bridge", "bft", :bridge, :bft], do: "bft"
  defp normalize_surface(value) when value in ["comma", :comma], do: "comma"
  defp normalize_surface(value) when value in ["salix", :salix], do: "salix"
  defp normalize_surface(value) when value in ["system", :system], do: "system"
  defp normalize_surface(_value), do: "other"
end
