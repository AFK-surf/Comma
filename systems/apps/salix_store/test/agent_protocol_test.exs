defmodule SalixStore.AgentProtocolTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{Agent, Ids}
  alias SalixStore.Agent.Owned

  @sm SalixStore.TestSM

  setup do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    id = Ids.new_agent_id(group)

    record = %{
      "agent_id" => id,
      "tenant_id" => tenant,
      "group_id" => group,
      "role" => "worker",
      "name" => "Protocol",
      "status" => "idle",
      "runtime_config" => %{"kind" => "internal"},
      "heartbeat_schedule_id" => Ids.new_schedule_id()
    }

    {:ok, agent: id, config: record}
  end

  test "create requires complete configuration and rejects an existing identity", ctx do
    assert {:error, :missing_configuration} = Agent.create(ctx.agent, "node-1", @sm)

    assert {:ok, %Owned{epoch: 1, state: %{counter: 0}}} =
             Agent.create(ctx.agent, "node-1", @sm, config: ctx.config)

    assert {:error, :exists} = Agent.create(ctx.agent, "node-2", @sm, config: ctx.config)
  end

  test "commits preserve state and watermarks through a fresh owner", ctx do
    {:ok, owned} = Agent.create(ctx.agent, "node-1", @sm, config: ctx.config)
    {:ok, owned} = Agent.commit(owned, [%{op: "inc", by: 5}], hwm: 1)
    {:ok, owned} = Agent.commit(owned, [%{op: "inc", by: 3}, %{op: "set", value: 100}], hwm: 3)
    assert owned.state == %{counter: 100, ops: 3}
    assert {:ok, fresh} = Agent.claim(ctx.agent, "node-2", @sm, steal: true)
    assert fresh.state == owned.state
    assert fresh.head.message_id_hwm == 3
    assert fresh.epoch == 2
    assert {:error, :fenced} = Agent.commit(owned, [%{op: "inc", by: 99}])
  end

  test "renewal and work admission use the PostgreSQL clock", ctx do
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
    {:ok, owned} = Agent.create(ctx.agent, "node-1", @sm, config: ctx.config, ttl_ms: 60_000)
    assert :ok = Agent.verify_work_owner(owned, guard_ms: 5_000)
    SystemsClock.advance(55_000)
    assert {:error, :lease_expiring} = Agent.verify_work_owner(owned, guard_ms: 5_000)
    assert {:error, {:held_by, "node-1", _}} = Agent.claim(ctx.agent, "node-2", @sm)
    {:ok, renewed} = Agent.renew(owned)
    assert renewed.epoch == owned.epoch
    assert renewed.head.lease_until == SystemsClock.system_time(:millisecond) + 60_000
    assert :ok = Agent.verify_work_owner(renewed, guard_ms: 5_000)
    assert :ok = Agent.release(renewed)
    assert {:ok, %{owner_node: nil, lease_until: nil}} = Agent.peek(ctx.agent)
  end
end
