defmodule SalixAgent.TaskAgentTest do
  @moduledoc """
  A Group's Task agent: one Agent however many first calls race, an adopted
  Worker instead of a new one, none in a guest Tenant, and none in the lists a
  Router or product shows.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentManagement, Control, TaskAgent}
  alias SalixStore.{Ids, S3, TenantProfiles}

  setup do
    old_ports = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)

    SystemsRuntime.put_env(
      :salix_agent,
      :agent_management_ports,
      AgentManagement.Ports.Standalone
    )

    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_platform_models!()
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{"role" => "router"})

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if old_ports,
        do: SystemsRuntime.put_env(:salix_agent, :agent_management_ports, old_ports),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_management_ports)
    end)

    %{
      tenant: tenant,
      group: group,
      scope: %{tenant_id: tenant, group_id: group},
      ctx: %{agent_id: router["agent_id"], session_id: router["router_session_id"]}
    }
  end

  test "concurrent first calls make one Task agent, which the Group records", c do
    ids =
      1..8
      |> SystemsClock.async_stream(fn _ -> TaskAgent.ensure(c.scope) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, id}} -> id end)
      |> Enum.uniq()

    assert ids == [TaskAgent.id(c.group)]
    [id] = ids
    assert {:ok, ^id} = TaskAgent.get(c.group)
    assert {:ok, ^id} = AgentManagement.Ports.task_worker(c.scope)

    assert {:ok, %{items: workers}} = Control.page_workers(c.tenant, c.group, limit: 50)
    assert [%{"agent_id" => ^id, "role" => "worker"} = agent] = workers
    # Memory consultation and Task code see an ordinary visible Worker.
    assert Control.visible?(agent)
  end

  test "a Group adopts the Worker it already ran Tasks on, and makes none", c do
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(c.tenant, c.group)["agent_id"]

    assert {:ok, ^worker} = TaskAgent.ensure(c.scope, adopt: fn -> {:ok, worker} end)
    # Later calls answer the recorded Worker; the adopt function is not asked.
    assert {:ok, ^worker} = TaskAgent.ensure(c.scope, adopt: fn -> raise "asked again" end)
    assert {:ok, ^worker} = TaskAgent.ensure(c.scope)
    assert {:error, :not_found} = Control.get_record(TaskAgent.id(c.group))

    # A Worker of another Group is not adopted.
    other = Ids.new_group_id(c.tenant)
    foreign = SalixAgent.TestSupport.create_control_agent_in_group!(c.tenant, other)["agent_id"]
    SalixAgent.TestSupport.create_control_agent_in_group!(c.tenant, other, %{"role" => "router"})

    assert {:error, {:unavailable, :task_agent}} =
             TaskAgent.ensure(%{tenant_id: c.tenant, group_id: other},
               adopt: fn -> {:ok, worker} end
             )

    assert {:ok, nil} = TaskAgent.get(other)
    assert {:ok, ^foreign} = TaskAgent.adopt(c.tenant, other, foreign)
  end

  test "a guest Tenant's Group has no Task agent", c do
    guest = SalixAgent.TestSupport.new_tenant_id()
    {:ok, _profile} = TenantProfiles.put_router_only(guest, 16)
    group = Ids.new_group_id(guest)
    SalixAgent.TestSupport.create_control_group!(group)
    scope = %{tenant_id: guest, group_id: group}

    assert {:error, :guest_group} = TaskAgent.ensure(scope)
    assert {:error, :guest_group} = TaskAgent.ensure(scope, adopt: fn -> raise "asked" end)
    assert {:ok, nil} = TaskAgent.get(group)
    assert {:error, :not_found} = Control.get_record(TaskAgent.id(group))
    # Another Tenant's id is no scope for the Group.
    assert {:error, :not_found} = TaskAgent.ensure(%{c.scope | group_id: group})
  end

  test "Router management and product lists leave the Task agent out", c do
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(c.tenant, c.group)["agent_id"]
    {:ok, task_agent} = TaskAgent.ensure(c.scope)

    assert {:ok, %{"items" => items}} = AgentManagement.run(:list, %{}, c.ctx)
    assert Enum.map(items, & &1["agent_id"]) == [worker]

    for {operation, args} <- [
          get: %{"agent_id" => task_agent},
          update: %{"agent_id" => task_agent, "name" => "Renamed"},
          archive: %{"agent_id" => task_agent, "user_confirmed" => true}
        ] do
      assert {:error, %{"code" => "agent_not_found"}} =
               AgentManagement.run(operation, args, Map.put(c.ctx, :tool_call_id, "t"))
    end

    assert {:ok, %{items: listed}} =
             Control.page_agents(c.tenant, c.group, limit: 50, exclude_task_agent: true)

    refute Enum.any?(listed, &(&1["agent_id"] == task_agent))
    assert Enum.any?(listed, &(&1["agent_id"] == worker))
    assert {:ok, %{"name" => "Task agent"} = record} = Control.get_record(task_agent)
    refute Control.archived?(record)
  end
end
