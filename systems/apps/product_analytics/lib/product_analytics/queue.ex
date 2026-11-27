defmodule ProductAnalytics.Queue do
  @moduledoc """
  One bounded analytics export queue per product per pod. Queue loss never
  changes a business result.

  The queue has 1,000 volatile slots, held in an ETS table named like the
  queue. There is no shutdown delivery guarantee. Each attempt covers at most
  100 observations and lasts at most 15 seconds; a batch is retried at most
  three times. The product's `export` function turns the observations into
  events and sends them; it answers `:ok`, `{:error, :rejected}` (dropped now)
  or another error (retried).

  Options: `:name` (required, also the ETS table), `:export` (required),
  `:telemetry` (the event for queue measurements) and `:flush_ms`.
  """
  use SystemsRuntime.Server

  @capacity 1_000
  @batch_size 100

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Admits one observation without blocking. A full or missing queue counts or drops it."
  def enqueue(name, entry) do
    index = SystemsRuntime.ETS.update_counter(name, :sequence, {2, 1})

    row =
      {rem(index, @capacity), index,
       Map.put(entry, :queued_at, SystemsClock.monotonic_time(:second))}

    if SystemsRuntime.ETS.insert_new(name, row),
      do: :ok,
      else: SystemsRuntime.ETS.update_counter(name, :dropped, {2, 1})
  rescue
    _ -> :ok
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    SystemsRuntime.ETS.new(name, [:named_table, :public, :set, write_concurrency: true])
    SystemsRuntime.ETS.insert(name, [{:sequence, 0}, {:dropped, 0}])

    SystemsClock.send_after(
      SystemsRuntime.Proc.self(),
      :flush,
      Keyword.get(opts, :flush_ms, 1_000)
    )

    {:ok,
     %{
       name: name,
       export: Keyword.fetch!(opts, :export),
       telemetry: Keyword.get(opts, :telemetry),
       attempt: 0,
       batch: nil
     }}
  end

  @impl true
  def handle_info(:flush, state) do
    entries = state.batch || next_batch(state.name)
    result = ProductAnalytics.attempt(fn -> state.export.(Enum.map(entries, &elem(&1, 2))) end)

    attempt = state.attempt + 1
    discard? = result == :ok or result == {:error, :rejected} or attempt >= 3
    if discard?, do: Enum.each(entries, &SystemsRuntime.ETS.delete_object(state.name, &1))
    dropped = SystemsRuntime.ETS.update_counter(state.name, :dropped, {2, 0})
    SystemsRuntime.ETS.update_counter(state.name, :dropped, {2, -dropped})
    lost = if discard? and result != :ok, do: length(entries), else: 0
    emit(state, length(entries), dropped + lost, result)

    state = %{
      state
      | attempt: if(discard?, do: 0, else: attempt),
        batch: if(discard?, do: nil, else: entries)
    }

    SystemsClock.send_after(
      SystemsRuntime.Proc.self(),
      :flush,
      if(result == :ok, do: 1_000, else: 5_000)
    )

    {:noreply, state}
  end

  defp next_batch(name) do
    SystemsRuntime.ETS.select(name, [{{:"$1", :"$2", :"$3"}, [], [:"$_"]}])
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(@batch_size)
  end

  defp emit(%{telemetry: nil}, _count, _dropped, _result), do: :ok

  defp emit(state, count, dropped, result) do
    ages =
      SystemsRuntime.ETS.select(state.name, [{{:"$1", :"$2", :"$3"}, [], [:"$3"]}])
      |> Enum.map(&(SystemsClock.monotonic_time(:second) - &1.queued_at))

    SystemsRuntime.Telemetry.execute(
      state.telemetry,
      %{
        count: count,
        dropped: dropped,
        depth: length(ages),
        oldest_age_seconds: Enum.max(ages, fn -> 0 end)
      },
      %{outcome: if(result == :ok, do: "ok", else: "error")}
    )
  end
end
