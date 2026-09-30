defmodule BridgeForTeams.Salix.ReadCache do
  @moduledoc """
  Node-local read-through cache for Salix `:erpc` reads on dashboard render
  paths (e.g. the project sites fan-out), so bursts of refreshes don't hammer
  Salix with identical remote calls.

  A GenServer owns a public ETS table; reads and read-through fills happen in
  the caller (no GenServer round-trip), and the owner sweeps expired entries
  periodically. Entries are stored as `{key, value, expires_at_ms}`.

  Well-known keys:

    * `{:project_sites, project_id}` — `Sites.list_project_sites/2` results.

  Error results (`{:error, _}` or `:error`) are returned to the caller but
  **never cached**, so a transient Salix failure can't be pinned for a TTL.

  Fills are generation-guarded: `invalidate/1` bumps a per-key generation
  counter (a two-tuple `{{:gen, key}, n}` entry, invisible to the sweeper's
  three-tuple match) before deleting the value, and a read-through fill only
  inserts when the generation it read at miss time is still current. Without
  that, an invalidation landing between a slow filler's `fun.()` finishing and
  its insert would be silently undone — the pre-invalidation value pinned for
  a full TTL, defeating exactly the freshness signal `invalidate/1` exists
  to deliver.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  @doc "Start the cache table owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read-through fetch: return the cached value for `key` when fresh, otherwise
  run `fun` and cache its result for `ttl_ms` milliseconds.

  `fun` runs in the caller's process. Results shaped `{:error, _}` or `:error`
  are passed through uncached. When the cache table is not running the value is
  simply computed (degraded, never broken).
  """
  @spec fetch(term(), pos_integer(), (-> result)) :: result when result: term()
  def fetch(key, ttl_ms, fun) when is_integer(ttl_ms) and ttl_ms > 0 and is_function(fun, 0) do
    case lookup(key) do
      {:ok, value} ->
        :telemetry.execute([:bridge_for_teams, :read_cache], %{}, %{result: "hit"})
        value

      :miss ->
        :telemetry.execute([:bridge_for_teams, :read_cache], %{}, %{result: "miss"})
        fill(key, generation(key), ttl_ms, fun.())
    end
  end

  @doc "Drop the cached entry for `key` (next `fetch/3` recomputes)."
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    # Bump the generation FIRST, then drop the value: a filler that read the
    # old generation can no longer insert (mismatch), and a filler that just
    # inserted is deleted here — either interleaving leaves no stale entry.
    :ets.update_counter(@table, {:gen, key}, 1, {{:gen, key}, 0})
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if now_ms() < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # The per-key invalidation generation a fill must still match to insert.
  defp generation(key) do
    case :ets.lookup(@table, {:gen, key}) do
      [{{:gen, ^key}, generation}] -> generation
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # Never cache errors: a transient Salix failure must not be served for a TTL.
  defp fill(_key, _generation, _ttl_ms, {:error, _reason} = error), do: error
  defp fill(_key, _generation, _ttl_ms, :error), do: :error

  defp fill(key, generation, ttl_ms, value) do
    # An invalidate/1 that landed while `fun` ran bumped the generation: this
    # value is already stale, so return it uncached rather than pin it.
    if generation(key) == generation do
      :ets.insert(@table, {key, value, now_ms() + ttl_ms})
    end

    value
  rescue
    ArgumentError -> value
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
