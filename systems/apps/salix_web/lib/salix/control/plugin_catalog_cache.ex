defmodule Salix.Control.PluginCatalogCache do
  @moduledoc """
  Node-local cache of group plugin catalogs.

  S3 remains the durable source of truth. Each node caches the catalogs that
  its own callers read, in one ETS table owned by this process, so a cache
  hit needs no message to another process or node.

  Catalog writes invalidate the entry on the writing node before they return,
  then on every other ring node through one bounded multicall. A node that
  misses an invalidation (unreachable, or not yet upgraded) serves its entry
  for at most 60 seconds (`@ttl_ms`), after which the next read loads it again.

  A read can start loading before an invalidation and finish after it. Each
  entry keeps the group and tenant generations that were current when its
  load started, and a read serves an entry only while both are unchanged.
  An invalidation increments the generation, so such a late load is never
  served.
  """

  use GenServer

  alias SalixCluster.Ring

  @table __MODULE__
  @ttl_ms 60_000
  @invalidate_timeout_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(tenant_id, group_id) do
    key = {:catalog, tenant_id, group_id}
    generations = generations(tenant_id, group_id)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, ^generations, expires_at, snapshot}] when expires_at > now ->
        {:ok, snapshot}

      _stale_or_absent ->
        with {:ok, snapshot} <- Salix.Control.Plugins.load_group_catalog(tenant_id, group_id) do
          :ets.insert(@table, {key, generations, now + @ttl_ms, snapshot})
          {:ok, snapshot}
        end
    end
  end

  @spec invalidate_group(String.t()) :: :ok
  def invalidate_group(group_id), do: invalidate(:invalidate_group_local, [group_id])

  @spec invalidate_tenant(String.t()) :: :ok
  def invalidate_tenant(tenant_id), do: invalidate(:invalidate_tenant_local, [tenant_id])

  @doc false
  def invalidate_group_local(group_id) do
    :ets.update_counter(@table, {:group_generation, group_id}, 1, {nil, 0})
    :ets.match_delete(@table, {{:catalog, :_, group_id}, :_, :_, :_})
    :ok
  end

  @doc false
  def invalidate_tenant_local(tenant_id) do
    :ets.update_counter(@table, {:tenant_generation, tenant_id}, 1, {nil, 0})
    :ets.match_delete(@table, {{:catalog, tenant_id, :_}, :_, :_, :_})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  # Expired entries are only replaced when their group is read again. The
  # sweep removes the others so memory follows the groups read recently.
  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:catalog, :_, :_}, :_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @ttl_ms)

  defp generations(tenant_id, group_id),
    do: {counter({:group_generation, group_id}), counter({:tenant_generation, tenant_id})}

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  # Invalidate locally first so the writer reads its own write. Remote
  # failures are bounded by the entry freshness, not retried here.
  defp invalidate(function, args) do
    :ok = apply(__MODULE__, function, args)
    _ = :erpc.multicall(remote_nodes(), __MODULE__, function, args, @invalidate_timeout_ms)
    :ok
  end

  defp remote_nodes do
    Ring.nodes() -- [node()]
  catch
    :exit, _reason -> []
  end
end
