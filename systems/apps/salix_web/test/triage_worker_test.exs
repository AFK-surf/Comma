defmodule Salix.Bindings.TriageWorkerTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{AgentManagement, Control}
  alias SalixStore.{Ids, S3}

  defmodule ConnectedRuntime do
    def external_runtime_binding_status(_, _, _) do
      if observer = Application.get_env(:salix_agent, :triage_test_runtime_observer),
        do: send(observer, :runtime_status_read)

      {:ok, %{"status" => Application.fetch_env!(:salix_agent, :triage_test_runtime_status)}}
    end
  end

  setup do
    old = Application.get_env(:salix_agent, :agent_management_ports)
    Application.put_env(:salix_agent, :agent_management_ports, AgentManagement.Ports.Standalone)
    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{"role" => "router"})

    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Triage test",
        "model" => "test",
        "provider" => "mock"
      })

    _ =
      SalixAgent.TestSupport.put_tenant_agent_defaults!(tenant, %{
        "worker_template_id" => template["template_id"]
      })

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if old,
        do: Application.put_env(:salix_agent, :agent_management_ports, old),
        else: Application.delete_env(:salix_agent, :agent_management_ports)
    end)

    %{group: group, router: router, tenant: tenant}
  end

  test "unassigned Triage pauses intake without creating a Worker", %{
    group: group,
    router: router,
    tenant: tenant
  } do
    assert {:ok, before} = Control.page_workers(tenant, group, limit: 20)

    assert {:error, :triage_worker_unavailable} =
             Salix.Bindings.TriageWorker.ensure(group, router["agent_id"])

    assert {:ok, after_read} = Control.page_workers(tenant, group, limit: 20)
    assert after_read.items == before.items
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group)

    assert {:ok, _} =
             Salix.Bindings.TriageWorker.configure(
               group,
               router["agent_id"],
               worker["agent_id"],
               0,
               %{"actor_user_id" => "admin", "request_id" => "select"}
             )

    assert {:ok, cleared} =
             Salix.Bindings.TriageWorker.configure(group, router["agent_id"], nil, 1, %{
               "actor_user_id" => "admin",
               "request_id" => "clear"
             })

    assert cleared["worker_agent_id"] == nil

    assert {:error, :triage_worker_unavailable} =
             Salix.Bindings.TriageWorker.ensure(group, router["agent_id"])

    assert {:ok, ^cleared} = Salix.Bindings.TriageWorker.get(group)
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

  test "a disconnected selected runtime fails without restoring the default", ctx do
    previous = Application.get_env(:salix_agent, :runtime_environment_mod)
    Application.put_env(:salix_agent, :runtime_environment_mod, ConnectedRuntime)
    Application.put_env(:salix_agent, :triage_test_runtime_status, "ready")

    on_exit(fn ->
      Application.delete_env(:salix_agent, :triage_test_runtime_status)

      if previous,
        do: Application.put_env(:salix_agent, :runtime_environment_mod, previous),
        else: Application.delete_env(:salix_agent, :runtime_environment_mod)
    end)

    id = Ids.new_agent_id(ctx.group)

    SalixAgent.TestSupport.create_legacy_control_agent!(id, %{
      "tenant_id" => ctx.tenant,
      "group_id" => ctx.group,
      "role" => "worker",
      "runtime_config" => %{
        "kind" => "connected_runtime",
        "provider" => "codex",
        "device_id" => "device",
        "runtime_id" => "runtime",
        "device_runtime_id" =>
          SalixStore.RuntimeIds.device_runtime_id("device", "codex", "runtime")
      }
    })

    assert {:ok, binding} =
             Salix.Bindings.TriageWorker.configure(ctx.group, ctx.router["agent_id"], id, 0, %{
               "actor_user_id" => "admin",
               "request_id" => "connected"
             })

    assert {:ok, ^id} = Salix.Bindings.TriageWorker.ensure(ctx.group, ctx.router["agent_id"])
    Application.put_env(:salix_agent, :triage_test_runtime_status, "disconnected")

    assert {:error, :triage_worker_unavailable} =
             Salix.Bindings.TriageWorker.ensure(ctx.group, ctx.router["agent_id"])

    assert {:ok, ^binding} = Salix.Bindings.TriageWorker.get(ctx.group)
  end

  test "candidate pages do not fan out runtime availability reads", ctx do
    previous = Application.get_env(:salix_agent, :runtime_environment_mod)
    Application.put_env(:salix_agent, :runtime_environment_mod, ConnectedRuntime)
    Application.put_env(:salix_agent, :triage_test_runtime_status, "ready")

    on_exit(fn ->
      Application.delete_env(:salix_agent, :triage_test_runtime_observer)
      Application.delete_env(:salix_agent, :triage_test_runtime_status)

      if previous,
        do: Application.put_env(:salix_agent, :runtime_environment_mod, previous),
        else: Application.delete_env(:salix_agent, :runtime_environment_mod)
    end)

    ids =
      for n <- 1..21 do
        id = Ids.new_agent_id(ctx.group)

        SalixAgent.TestSupport.create_legacy_control_agent!(id, %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "role" => "worker",
          "name" => "Candidate #{n}",
          "runtime_config" => %{
            "kind" => "connected_runtime",
            "provider" => "codex",
            "device_id" => "device",
            "runtime_id" => "runtime",
            "device_runtime_id" =>
              SalixStore.RuntimeIds.device_runtime_id("device", "codex", "runtime")
          }
        })

        id
      end

    [selected, preview | _] = ids

    assert {:ok, _} =
             Salix.Bindings.TriageWorker.configure(
               ctx.group,
               ctx.router["agent_id"],
               selected,
               0,
               %{"actor_user_id" => "admin", "request_id" => "bounded"}
             )

    Application.put_env(:salix_agent, :triage_test_runtime_observer, self())
    assert {:ok, view} = Salix.Bindings.TriageWorker.view(ctx.group, inspect_worker_id: preview)
    assert length(view["candidates"]) in 19..20
    assert is_binary(view["next_cursor"])
    assert_received :runtime_status_read
    assert_received :runtime_status_read
    refute_received :runtime_status_read
    assert {:ok, last} = Salix.Bindings.TriageWorker.view(ctx.group, cursor: view["next_cursor"])
    assert length(last["candidates"]) in 1..2

    assert MapSet.new(Enum.map(view["candidates"] ++ last["candidates"], & &1["agent_id"])) ==
             MapSet.new(ids)

    assert_received :runtime_status_read
    refute_received :runtime_status_read
  end

  test "Triage reuses an ordinary Worker and respects owner archival", %{
    group: group,
    tenant: tenant,
    router: router
  } do
    router_id = router["agent_id"]
    worker_id = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group)["agent_id"]

    assert {:ok, _} =
             Salix.Bindings.TriageWorker.configure(group, router_id, worker_id, 0, %{
               "actor_user_id" => "admin",
               "request_id" => "choose"
             })

    assert {:ok, ^worker_id} = Salix.Bindings.TriageWorker.ensure(group, router_id)
    assert {:ok, worker} = Control.get_record(worker_id)
    assert worker["role"] == "worker"
    assert worker["runtime_config"]["kind"] == "internal"
    assert worker["group_id"] == group
    assert {:error, _} = Salix.Bindings.TriageWorker.ensure("another-group", router_id)

    ctx = %{agent_id: router_id, session_id: router["router_session_id"]}

    assert {:ok, _} =
             AgentManagement.run(
               :archive,
               %{"agent_id" => worker_id, "user_confirmed" => true},
               ctx
             )

    assert {:error, _} = Salix.Bindings.TriageWorker.ensure(group, router_id)

    assert {:ok, %{"items" => [%{"agent_id" => ^worker_id}]}} =
             AgentManagement.run(:list, %{"lifecycle" => "all"}, ctx)
  end
end
