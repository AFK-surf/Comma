defmodule BridgeForTeams.Cache do
  @moduledoc """
  Node-local ETS cache (design §1: replaces Redis for cache; read-mostly config
  via `:persistent_term`). Owns its ETS table; started in the supervision tree.

  Entries are stored as `{key, value, expires_at_ms | :infinity}`. Reads are
  served directly from ETS (no GenServer round-trip) and lazily evict expired
  entries; the owning GenServer also sweeps periodically.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  @doc "Start the cache table owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetch a cached value."
  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, :infinity}] ->
        {:ok, value}

      [{^key, value, expires_at}] ->
        if now_ms() < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :error
        end

      [] ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Put a value with an optional ttl. Options:

    * `:ttl` — time-to-live in milliseconds (defaults to no expiry).
  """
  @spec put(term(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    expires_at =
      case Keyword.get(opts, :ttl) do
        nil -> :infinity
        ttl when is_integer(ttl) and ttl > 0 -> now_ms() + ttl
        _ -> :infinity
      end

    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc "Delete a cached value."
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep_expired do
    now = now_ms()
    # Match-delete every entry whose finite expiry is in the past.
    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:andalso, {:"/=", :"$1", :infinity}, {:<, :"$1", now}}], [true]}
    ])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
