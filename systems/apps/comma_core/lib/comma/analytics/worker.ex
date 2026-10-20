defmodule Comma.Analytics.Worker do
  @moduledoc """
  One bounded analytics exporter per Comma pod. Queue loss never changes a business result.

  The queue has 1,000 volatile slots. There is no shutdown delivery guarantee.
  Each attempt covers at most 100 observations and lasts at most 15 seconds.
  The SDK handles HTTP encoding; this worker bounds retries and caller admission.
  """
  use SystemsRuntime.Server

  @capacity 1_000
  @batch_size 100

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  def enqueue(entry) do
    index = SystemsRuntime.ETS.update_counter(__MODULE__, :sequence, {2, 1})

    row =
      {rem(index, @capacity), index,
       Map.put(entry, :queued_at, SystemsClock.monotonic_time(:second))}

    if SystemsRuntime.ETS.insert_new(__MODULE__, row),
      do: :ok,
      else: SystemsRuntime.ETS.update_counter(__MODULE__, :dropped, {2, 1})
  rescue
    _ -> :ok
  end

  @impl true
  def init(opts) do
    SystemsRuntime.ETS.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    SystemsRuntime.ETS.insert(__MODULE__, [{:sequence, 0}, {:dropped, 0}])

    SystemsClock.send_after(
      SystemsRuntime.Proc.self(),
      :flush,
      Keyword.get(opts, :flush_ms, 1_000)
    )

    {:ok, %{attempt: 0, batch: nil}}
  end

  @impl true
  def handle_info(:flush, state) do
    entries = state.batch || next_batch()

    result =
      Comma.Analytics.Export.attempt(fn ->
        Comma.Analytics.Export.entries(Enum.map(entries, &elem(&1, 2)))
      end)

    attempt = state.attempt + 1
    discard? = result == :ok or result == {:error, :rejected} or attempt >= 3
    if discard?, do: Enum.each(entries, &SystemsRuntime.ETS.delete_object(__MODULE__, &1))
    dropped = SystemsRuntime.ETS.update_counter(__MODULE__, :dropped, {2, 0})
    SystemsRuntime.ETS.update_counter(__MODULE__, :dropped, {2, -dropped})
    lost = if discard? and result != :ok, do: length(entries), else: 0
    emit(length(entries), dropped + lost, result)

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

  defp next_batch do
    SystemsRuntime.ETS.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [:"$_"]}])
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(@batch_size)
  end

  defp emit(count, dropped, result) do
    ages =
      SystemsRuntime.ETS.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [:"$3"]}])
      |> Enum.map(&(SystemsClock.monotonic_time(:second) - &1.queued_at))

    SystemsRuntime.Telemetry.execute(
      [:comma_product, :analytics, :export],
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
