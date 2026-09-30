defmodule SalixAgent.RoundConfigCacheTest do
  use ExUnit.Case, async: true
  alias SalixAgent.RoundConfigCache, as: Cache

  defp without_refresh_floor do
    previous = Application.get_env(:salix_agent, :round_config_refresh_min_age_ms)
    Application.put_env(:salix_agent, :round_config_refresh_min_age_ms, 0)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:salix_agent, :round_config_refresh_min_age_ms)
        value -> Application.put_env(:salix_agent, :round_config_refresh_min_age_ms, value)
      end
    end)
  end

  test "a warm round does not wait or duplicate a refresh, and only boundaries install results" do
    without_refresh_floor()
    owner = self()

    build = fn ->
      send(owner, {:refresh_started, self()})

      receive do
        {:finish, result} -> result
      end
    end

    assert {:ok, :v1, cache} = Cache.begin_round(%Cache{current: :v1}, build)
    assert_receive {:refresh_started, pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert {:ok, :v1, same} = Cache.begin_round(cache, build)
    assert same.task.ref == cache.task.ref
    refute_receive {:refresh_started, _}, 20

    send(pid, {:finish, {:ok, :v2}})
    assert_receive {ref, {:ok, :v2}}
    ready = Cache.completed(cache, ref, {:ok, :v2})
    assert ready.current == :v1
    assert {:ok, :v2, next} = Cache.begin_round(ready, build)
    assert_receive {:refresh_started, next_pid}
    refute next_pid == pid
    Cache.stop(next)
    refute Process.alive?(next_pid)
  end

  test "a snapshot younger than the refresh floor is reused without a refresh" do
    owner = self()
    build = fn -> send(owner, :refresh_started) && {:ok, :fresh} end

    # Installed at this boundary: no refresh at the same or the next one.
    assert {:ok, :initial, cache} = Cache.begin_round(%Cache{}, fn -> {:ok, :initial} end)
    assert {:ok, :initial, same} = Cache.begin_round(cache, build)
    assert same.task == nil
    refute_receive :refresh_started, 20

    # Older than the floor: the boundary refreshes in the background again.
    aged = %{same | built_at_ms: System.monotonic_time(:millisecond) - 60_000}
    assert {:ok, :initial, refreshing} = Cache.begin_round(aged, build)
    assert_receive :refresh_started
    assert %Task{} = refreshing.task
    Cache.stop(refreshing)
  end

  test "initialization waits once; failure leaves no usable snapshot" do
    assert {:error, :unavailable, %Cache{current: nil, task: nil}} =
             Cache.begin_round(%Cache{}, fn -> {:error, :unavailable} end)

    assert {:ok, :initial, cache} = Cache.begin_round(%Cache{}, fn -> {:ok, :initial} end)
    assert cache.current == :initial
    # The boundary that built the snapshot does not also refresh it.
    assert cache.task == nil
    refute_receive {_ref, {:ok, :initial}}, 20
    Cache.stop(cache)
  end

  test "invalidation drops the snapshot and the refresh in flight, then rebuilds once" do
    assert {:ok, :old, cache} =
             Cache.begin_round(%Cache{current: :old}, fn ->
               receive do
                 :never -> {:ok, :never}
               end
             end)

    refresh_pid = cache.task.pid
    assert %Cache{current: nil, task: nil, result: nil} = invalidated = Cache.invalidate(cache)
    refute Process.alive?(refresh_pid)
    refute_receive {:DOWN, _, :process, ^refresh_pid, _}, 20

    assert {:ok, :rebuilt, next} = Cache.begin_round(invalidated, fn -> {:ok, :rebuilt} end)
    assert next.current == :rebuilt
    assert next.task == nil
    assert %Cache{current: nil} = Cache.invalidate(%Cache{})
  end

  test "a failed refresh retains the old snapshot and retries at the next boundary" do
    assert {:ok, :old, cache} =
             Cache.begin_round(%Cache{current: :old}, fn -> {:error, :unavailable} end)

    assert_receive {ref, {:error, :unavailable}}
    failed = Cache.completed(cache, ref, {:error, :unavailable})
    assert {:ok, :old, next} = Cache.begin_round(failed, fn -> {:ok, :recovered} end)
    assert_receive {next_ref, {:ok, :recovered}}
    ready = Cache.completed(next, next_ref, {:ok, :recovered})
    assert {:ok, :recovered, final} = Cache.begin_round(ready, fn -> {:ok, :recovered} end)
    Cache.stop(final)
  end

  test "a task DOWN retains configuration and does not wedge the single flight" do
    assert {:ok, :old, cache} =
             Cache.begin_round(%Cache{current: :old}, fn ->
               receive do
                 :never -> {:ok, :never}
               end
             end)

    Process.exit(cache.task.pid, :kill)
    assert_receive {:DOWN, ref, :process, _, :killed}
    failed = Cache.down(cache, ref, :killed)
    assert {:ok, :old, next} = Cache.begin_round(failed, fn -> {:ok, :new} end)
    Cache.stop(next)
  end
end
