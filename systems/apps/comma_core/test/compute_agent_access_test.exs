defmodule Comma.ComputeAgentAccessTest do
  use SystemsClock.Case, async: false
  import Ecto.Query
  alias SalixStore.{Compute, Ids, Keys, Repo, S3}
  alias SalixAgent.Tools.Compute, as: Tools

  defmodule Runtime do
    def dispatch_workload(op, args, id),
      do: {:ok, %{"operation" => op, "args" => args, "workload_id" => id}}

    def call_workload(op, args, id), do: dispatch_workload(to_string(op), args, id)
  end

  setup do
    SalixStore.RepoTestSetup.ensure!()
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    workspace = "wsp_" <> SystemsRuntime.Proc.uuid()

    Comma.Repo.insert!(%Comma.Data.User{
      id: "usr_compute_test",
      normalized_email: "compute@example.test"
    })

    Comma.Repo.insert!(%Comma.Data.Workspace{
      id: workspace,
      name: "Test",
      salix_tenant_id: tenant,
      salix_group_id: group,
      group_generation: "test-generation",
      salix_router_agent_id: Ids.new_agent_id(group),
      salix_worker_agent_id: Ids.new_agent_id(group),
      billing_owner_id: "billing-test",
      status: "active",
      owner_user_id: "usr_compute_test"
    })

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool-test",
        tenant_id: tenant,
        name: "Test",
        region: "local",
        capabilities: ["runtime_exec", "runtime_process"],
        provider_policy: %{"providers" => ["cloudflare"]}
      })

    {:ok, env} =
      Compute.create_environment(%{
        id: "env-test",
        tenant_id: tenant,
        owner_type: "project",
        owner_id: workspace,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-test",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: "test"
      })

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation-test",
        environment_id: env.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, _} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")
    %{tenant: tenant, group: group, workspace: workspace, env: env, allocation: allocation}
  end

  defp agent(c, role) do
    id = Ids.new_agent_id(c.group)

    record = %{
      "agent_id" => id,
      "tenant_id" => c.tenant,
      "group_id" => c.group,
      "role" => role,
      "heartbeat_schedule_id" => "test",
      "router_session_id" => Ids.new_session_id()
    }

    {:ok, _} = S3.put(Keys.ctl_agent(id), Jason.encode!(record))

    %{
      role: role,
      agent_id: id,
      tenant_id: c.tenant,
      group_id: c.group,
      runtime_kind: :internal,
      session_id: Ids.new_session_id(),
      tool_call_id: "call-test",
      compute_adapter: Runtime
    }
  end

  defp shell(c, id) do
    {:ok, w} =
      Compute.create_workload(%{
        id: id,
        name: id,
        environment_id: c.env.id,
        allocation_id: c.allocation.id,
        kind: "shell",
        generation: 1,
        template_key: "shell.default",
        capability_requirements: ["runtime_exec", "runtime_process"]
      })

    w
  end

  defp call(name, args, ctx) do
    entry = Enum.find(Tools.defs(), &(elem(&1, 0) == name))
    elem(entry, 3).(args, ctx)
  end

  defp execute(name, args, ctx) do
    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize_static(ctx.role, :internal, ctx)
      )

    [result] = SalixAgent.Tools.execute([%{id: "integration-call", name: name, args: args}], ctx)
    result
  end

  test "Router and Worker discover and explicitly select shared Shells without grants", c do
    shell(c, "shell-a")
    shell(c, "shell-b")

    for role <- ["router", "worker"] do
      ctx = agent(c, role)
      page_result = execute("compute.workloads.list", %{}, ctx)
      refute page_result.error
      page = Jason.decode!(page_result.content)
      assert Enum.map(page["workloads"], & &1["workload_id"]) == ["shell-a", "shell-b"]
      assert hd(page["workloads"])["capabilities"] == ["runtime_exec", "runtime_process"]

      for id <- ["shell-b", "shell-a"] do
        execution = execute("process.start", %{"workload_id" => id, "command" => ["true"]}, ctx)
        refute execution.error
        result = Jason.decode!(execution.content)

        assert result["workload_id"] == id
        refute Map.has_key?(result["args"], "workload_id")
      end

      failure = execute("process.list", %{}, ctx)
      assert failure.error_class == "workload_target_required"
      public = SalixAgent.VisibleReplyPolicy.label_result(failure)
      assert public.diagnostic_visibility == "user_reportable"
      assert public.public_summary =~ "workload_id"

      assert {:tool_failure, _, "workload_target_required", "user_reportable", _, []} =
               call("process.list", %{}, ctx)

      assert {:tool_failure, _, "compute_grant_required", _, _, []} =
               call("compute.service.export", %{"workload_id" => "shell-a"}, ctx)
    end

    assert Repo.aggregate(Compute.Grant, :count) == 0
  end

  test "discovery is bounded and disabled or private carriers cannot be selected", c do
    ctx = agent(c, "worker")
    for i <- 1..21, do: shell(c, "shell-" <> String.pad_leading(to_string(i), 2, "0"))
    first = call("compute.workloads.list", %{}, ctx) |> Jason.decode!()
    assert length(first["workloads"]) == 20

    second =
      call("compute.workloads.list", %{"after_id" => first["next_cursor"]}, ctx)
      |> Jason.decode!()

    assert Enum.map(second["workloads"], & &1["workload_id"]) == ["shell-21"]
    assert second["next_cursor"] == nil

    Repo.update_all(from(w in Compute.Workload, where: w.id == "shell-01"),
      set: [desired_state: "stopped"]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == "shell-02"),
      set: [kind: "meeting_runtime"]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == "shell-03"),
      set: [deletion: %{"phase" => "requested"}]
    )

    for id <- ["shell-01", "shell-02", "shell-03"] do
      assert {:tool_failure, _, "workload_not_available", _, _, []} =
               call("process.list", %{"workload_id" => id}, ctx)
    end

    Repo.update_all(from(e in Compute.Environment, where: e.id == ^c.env.id),
      set: [desired_state: "draining"]
    )

    assert Jason.decode!(call("compute.workloads.list", %{}, ctx))["workloads"] == []

    assert {:tool_failure, _, "workload_not_available", _, _, []} =
             call("process.list", %{"workload_id" => "shell-21"}, ctx)
  end

  test "fresh membership and project ownership fence every invocation", c do
    ctx = agent(c, "worker")
    shell(c, "shell-a")

    assert {:tool_failure, _, "compute_workspace_unavailable", _, _, []} =
             call("process.list", %{"workload_id" => "shell-a"}, %{
               ctx
               | group_id: Ids.new_group_id(c.tenant)
             })

    assert {:tool_failure, _, "compute_workspace_unavailable", _, _, []} =
             call("process.list", %{"workload_id" => "shell-a"}, %{
               ctx
               | tenant_id: Ids.new_tenant_id()
             })

    Repo.update_all(from(e in Compute.Environment, where: e.id == ^c.env.id),
      set: [owner_id: "other-workspace"]
    )

    assert {:tool_failure, _, "workload_not_available", _, _, []} =
             call("process.list", %{"workload_id" => "shell-a"}, ctx)

    assert Jason.decode!(call("compute.workloads.list", %{}, ctx))["workloads"] == []

    Repo.update_all(from(e in Compute.Environment, where: e.id == ^c.env.id),
      set: [owner_id: c.workspace, generation: 2]
    )

    assert {:tool_failure, _, "workload_not_available", _, _, []} =
             call("process.list", %{"workload_id" => "shell-a"}, ctx)

    :ok = S3.delete(Keys.ctl_agent(ctx.agent_id))

    assert {:tool_failure, _, "compute_workspace_unavailable", _, _, []} =
             call("compute.workloads.list", %{}, ctx)
  end
end
