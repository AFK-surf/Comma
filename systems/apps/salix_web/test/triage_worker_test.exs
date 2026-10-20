defmodule Salix.Bindings.TriageWorkerTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias SalixAgent.{AgentManagement, Control}
  alias SalixStore.{Ids, S3}

  setup do
    old = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)

    SystemsRuntime.put_env(
      :salix_agent,
      :agent_management_ports,
      AgentManagement.Ports.Standalone
    )

    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{"role" => "router"})

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if old,
        do: SystemsRuntime.put_env(:salix_agent, :agent_management_ports, old),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_management_ports)
    end)

    %{group: group, router: router, tenant: tenant}
  end

  test "configuration and intake share one binding and reject stale or foreign selection", ctx do
    %{group: group, router: router, tenant: tenant} = ctx
    router_id = router["agent_id"]
    original = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group)["agent_id"]

    assert {:ok, _} =
             Salix.Bindings.TriageWorker.configure(group, router_id, original, 0, %{
               "actor_user_id" => "admin",
               "request_id" => "initial"
             })

    assert {:ok, %{"revision" => 1}} = Salix.Bindings.TriageWorker.get(group)
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group)
    worker_id = worker["agent_id"]
    audit = %{"actor_user_id" => "project-admin", "request_id" => "change-1"}

    assert {:ok, binding} =
             Salix.Bindings.TriageWorker.configure(group, router_id, worker_id, 1, audit)

    assert binding["previous_worker_agent_id"] == original
    assert binding["actor_user_id"] == "project-admin"
    assert {:ok, ^worker_id} = Salix.Bindings.TriageWorker.ensure(group, router_id)

    assert {:ok, ^binding} =
             Salix.Bindings.TriageWorker.configure(group, router_id, worker_id, 1, audit)

    assert {:error, :triage_worker_conflict} =
             Salix.Bindings.TriageWorker.configure(group, router_id, original, 1, %{
               audit
               | "request_id" => "stale"
             })

    foreign =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, Ids.new_group_id(tenant))

    assert {:error, :triage_worker_unavailable} =
             Salix.Bindings.TriageWorker.configure(
               group,
               router_id,
               foreign["agent_id"],
               2,
               audit
             )

    assert {:ok, _} = Control.archive_permanently(worker_id, tenant)

    assert {:error, :triage_worker_unavailable} =
             Salix.Bindings.TriageWorker.ensure(group, router_id)

    assert {:ok, ^binding} = Salix.Bindings.TriageWorker.get(group)

    assert {:ok, %{"worker_agent_id" => nil, "source" => "unassigned"}} =
             Salix.Bindings.TriageWorker.configure(group, router_id, nil, 2, %{
               audit
               | "request_id" => "reset"
             })
  end
end
