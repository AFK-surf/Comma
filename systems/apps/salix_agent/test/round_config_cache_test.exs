defmodule SalixAgent.RoundConfigCacheTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: true
  alias SalixAgent.RoundConfigCache, as: Cache

  defp without_refresh_floor do
    previous = SystemsRuntime.get_env(:salix_agent, :round_config_refresh_min_age_ms)
    SystemsRuntime.put_env(:salix_agent, :round_config_refresh_min_age_ms, 0)

    on_exit(fn ->
      case previous do
        nil -> SystemsRuntime.delete_env(:salix_agent, :round_config_refresh_min_age_ms)
        value -> SystemsRuntime.put_env(:salix_agent, :round_config_refresh_min_age_ms, value)
      end
    end)
  end

  test "a warm round does not wait or duplicate a refresh, and only boundaries install results" do
    without_refresh_floor()
    owner = SystemsRuntime.Proc.self()

    build = fn ->
      SystemsRuntime.Proc.send(owner, {:refresh_started, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        {:finish, result} -> result
      end
    end

    assert {:ok, :v1, cache} = Cache.begin_round(%Cache{current: :v1}, build)
    assert_receive {:refresh_started, pid}

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    assert {:ok, :v1, same} = Cache.begin_round(cache, build)
    assert same.task.ref == cache.task.ref
    refute_receive {:refresh_started, _}, 20

    SystemsRuntime.Proc.send(pid, {:finish, {:ok, :v2}})
    assert_receive {ref, {:ok, :v2}}
    ready = Cache.completed(cache, ref, {:ok, :v2})
    assert ready.current == :v1
    assert {:ok, :v2, next} = Cache.begin_round(ready, build)
    assert_receive {:refresh_started, next_pid}
    refute next_pid == pid
    Cache.stop(next)
    refute SystemsRuntime.Proc.alive?(next_pid)
  end

  test "invalidation drops the snapshot and the refresh in flight, then rebuilds once" do
    assert {:ok, :old, cache} =
             Cache.begin_round(%Cache{current: :old}, fn ->
               SystemsRuntime.Proc.receive do
                 :never -> {:ok, :never}
               end
             end)

    refresh_pid = cache.task.pid
    assert %Cache{current: nil, task: nil, result: nil} = invalidated = Cache.invalidate(cache)
    refute SystemsRuntime.Proc.alive?(refresh_pid)
    refute_receive {:DOWN, _, :process, ^refresh_pid, _}, 20

    assert {:ok, :rebuilt, next} = Cache.begin_round(invalidated, fn -> {:ok, :rebuilt} end)
    assert next.current == :rebuilt
    assert next.task == nil
    assert %Cache{current: nil} = Cache.invalidate(%Cache{})
  end
end
