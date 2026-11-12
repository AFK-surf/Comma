defmodule SalixStore.LeaseStealFenceClockTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.{Agent, Ids}
  @sm SalixStore.TestSM

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    id = Ids.new_agent_id(group)

    config = %{
      "agent_id" => id,
      "tenant_id" => tenant,
      "group_id" => group,
      "role" => "worker",
      "name" => "Clock",
      "status" => "idle",
      "runtime_config" => %{"kind" => "internal"},
      "heartbeat_schedule_id" => Ids.new_schedule_id()
    }

    {:ok, owned} = Agent.create(id, "creator", @sm, config: config, ttl_ms: 60_000)
    {:ok, id: id, owned: owned}
  end

  test "a claimant's fast clock cannot expire the PostgreSQL lease", %{id: id, owned: old} do
    future = SystemsClock.system_time(:millisecond) + 10_000_000
    assert {:error, {:held_by, "creator", _}} = Agent.claim(id, "contender", @sm, now: future)
    SystemsClock.advance(60_001)
    assert {:ok, next} = Agent.claim(id, "contender", @sm, now: 0)
    assert next.epoch == old.epoch + 1
    assert {:error, :fenced} = Agent.commit(old, [%{op: "inc", by: 99}], now: 0)
  end

  test "concurrent claims after expiry grant one live owner", %{id: id} do
    SystemsClock.advance(60_001)

    results =
      for node_id <- ["owner-a", "owner-b"] do
        SystemsRuntime.Task.async(fn -> Agent.claim(id, node_id, @sm) end)
      end
      |> Enum.map(&settled_await/1)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, {:held_by, holder, _}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert holder == winner.node_id
    assert {:ok, committed} = Agent.commit(winner, [%{op: "inc", by: 1}])
    assert committed.state == %{counter: 1, ops: 1}
  end
end
