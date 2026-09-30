defmodule SalixStore.Inflight do
  @moduledoc """
  In-flight visibility for store operations.

  Every duration/outcome metric in the store observes only operations that
  REACHED a terminal state. An attempt that is still waiting on the backend —
  the exact failure mode of a stalled connection — is invisible to all of
  them, and a stalled pod looks "idle" instead of "stuck". This module closes
  that gap: `track/2` registers the operation in a pod-local ETS table for
  exactly as long as it runs, and `SalixStore.Inflight.Poller` periodically
  publishes per-operation gauges (current count, oldest age) from a scan of
  that table. Publication is poller-driven, never event-driven: during a stall
  there ARE no events, which is precisely when the gauges must keep moving.

  The table is created by `SalixStore.Application.start/2` and owned by the
  application master, so there is no separately crashable state holder. Rows
  are removed in an `after` block; a brutally-killed caller can still leak its
  row, so the scan drops rows whose recording process is dead — the data is
  observational, so a leaked row costs at most one stale gauge interval.
  """

  @table :salix_store_inflight

  # The fixed operation vocabulary, mirroring the operations observed by
  # `SalixStore.S3`. Every scan emits a value for each — including zero —
  # because a `last_value` gauge only moves when a measurement arrives.
  @operations ~w(store_put store_get store_list)

  @doc false
  def table, do: @table

  @doc false
  def operations, do: @operations

  @doc "Create the ETS table (idempotent). Called from the application supervisor root."
  def create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:write_concurrency, true},
        {:read_concurrency, true}
      ])
    end

    @table
  end

  @doc """
  Run `fun`, registered as an in-flight `operation` for its full duration.

  Tracking failures (a missing table in isolated test contexts) degrade to an
  untracked run. `fun` is invoked exactly once on every path — the tracking
  guards are scoped to the ETS calls alone, so an exception raised BY `fun`
  can never be mistaken for a tracking failure and re-run it.
  """
  @spec track(String.t(), (-> result)) :: result when result: term()
  def track(operation, fun) do
    case insert_row(operation) do
      {:ok, ref} ->
        try do
          fun.()
        after
          delete_row(ref)
        end

      :untracked ->
        fun.()
    end
  end

  defp insert_row(operation) do
    ref = make_ref()
    :ets.insert(@table, {ref, operation, self(), System.monotonic_time(:millisecond)})
    {:ok, ref}
  rescue
    ArgumentError -> :untracked
  end

  defp delete_row(ref) do
    :ets.delete(@table, ref)
  rescue
    # The table vanished mid-operation (application shutdown). The cleanup
    # must not replace `fun`'s result or exception with its own.
    ArgumentError -> true
  end

  @doc """
  Per-operation `{count, oldest_age_ms}` for every known operation, zero-filled.

  Rows whose recording process has died are deleted as they are encountered.
  """
  @spec snapshot(integer()) :: %{String.t() => {non_neg_integer(), non_neg_integer()}}
  def snapshot(now_ms \\ System.monotonic_time(:millisecond)) do
    snapshot_matching(now_ms, fn _pid -> true end)
  end

  @doc false
  @spec snapshot_for(pid(), integer()) :: %{
          String.t() => {non_neg_integer(), non_neg_integer()}
        }
  def snapshot_for(owner, now_ms \\ System.monotonic_time(:millisecond)) when is_pid(owner) do
    snapshot_matching(now_ms, &(&1 == owner))
  end

  defp snapshot_matching(now_ms, owner?) do
    empty = Map.new(@operations, &{&1, {0, 0}})

    :ets.tab2list(@table)
    |> Enum.reduce(empty, fn {ref, operation, pid, started_ms}, acc ->
      cond do
        not Process.alive?(pid) ->
          :ets.delete(@table, ref)
          acc

        not is_map_key(acc, operation) ->
          acc

        not owner?.(pid) ->
          acc

        true ->
          age = max(now_ms - started_ms, 0)

          Map.update!(acc, operation, fn {count, oldest} ->
            {count + 1, max(oldest, age)}
          end)
      end
    end)
  rescue
    # Table missing (isolated test contexts): report the zero-filled shape.
    ArgumentError -> Map.new(@operations, &{&1, {0, 0}})
  end

  defmodule Poller do
    @moduledoc """
    Publishes the in-flight gauges on a fixed cadence.

    One `[:salix, :store, :inflight]` event per known operation per tick,
    zero-filled, so the gauges keep reporting through a stall and fall back
    to zero after it clears.
    """

    use GenServer

    @default_interval_ms 10_000

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl true
    def init(opts) do
      interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
      schedule(interval)
      {:ok, %{interval_ms: interval}}
    end

    @impl true
    def handle_info(:publish, state) do
      publish()
      schedule(state.interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @doc false
    def publish(now_ms \\ System.monotonic_time(:millisecond)) do
      emit([:salix, :store, :inflight], SalixStore.Inflight.snapshot(now_ms))
    end

    @doc false
    def publish_for(owner, event_name, now_ms \\ System.monotonic_time(:millisecond))
        when is_pid(owner) and is_list(event_name) do
      emit(event_name, SalixStore.Inflight.snapshot_for(owner, now_ms))
    end

    defp emit(event_name, snapshot) do
      Enum.each(snapshot, fn {operation, {count, oldest_age_ms}} ->
        :telemetry.execute(
          event_name,
          %{count: count, oldest_age_seconds: oldest_age_ms / 1000},
          %{operation: operation}
        )
      end)
    end

    defp schedule(interval), do: Process.send_after(self(), :publish, interval)
  end
end
