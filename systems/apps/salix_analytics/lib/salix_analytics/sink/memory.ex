defmodule SalixAnalytics.Sink.Memory do
  @moduledoc """
  In-memory analytics sink for tests and development. Backed by an `Agent` map
  keyed by `SalixAnalytics.Sink.dedup_key/1`, so re-inserting a row the Mirror
  already mirrored is a no-op — the same idempotency contract ClickHouse gets
  from `ReplacingMergeTree`, realized in process. `rows/0` returns the deduped,
  insertion-ordered rows for assertions.
  """
  @behaviour SalixAnalytics.Sink

  use Agent

  alias SalixAnalytics.Sink

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{order: [], by_key: %{}} end, name: __MODULE__)
  end

  @impl true
  def insert(rows) when is_list(rows) do
    Agent.update(__MODULE__, fn state ->
      Enum.reduce(rows, state, fn row, acc ->
        key = Sink.dedup_key(row)

        if Map.has_key?(acc.by_key, key) do
          acc
        else
          %{acc | order: [key | acc.order], by_key: Map.put(acc.by_key, key, row)}
        end
      end)
    end)

    {:ok, length(rows)}
  end

  @doc "All deduped rows, in insertion order."
  @spec rows() :: [Sink.row()]
  def rows do
    Agent.get(__MODULE__, fn %{order: order, by_key: by_key} ->
      order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_key, &1))
    end)
  end

  @doc "Number of distinct (deduped) rows held."
  @spec count() :: non_neg_integer()
  def count, do: Agent.get(__MODULE__, fn %{by_key: by_key} -> map_size(by_key) end)

  @doc "Drop everything (test reset)."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{order: [], by_key: %{}} end)
end
