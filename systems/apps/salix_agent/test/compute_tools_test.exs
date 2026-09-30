defmodule SalixAgent.ComputeToolsTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.Compute, as: ComputeTools
  alias SalixStore.{Compute, Repo}

  defmodule Adapter do
    def dispatch_workload(operation, args, workload_id) do
      {:ok,
       %{
         "operation" => operation,
         "args" => args,
         "workload_id" => workload_id,
         "transport" => "typed"
       }}
    end

    def call_workload(operation, args, workload_id) do
      {:ok,
       %{
         "operation" => to_string(operation),
         "args" => args,
         "workload_id" => workload_id
       }}
    end
  end

  defmodule MustNotRunAdapter do
    def call_workload(_, _, _), do: raise("disabled tool reached the runtime adapter")

    def dispatch_workload(_, _, _),
      do: raise("unauthorized credential reached the runtime adapter")
  end

  defmodule OAuthStore do
    def agent_oauth_context("agent"), do: {:ok, %{tenant: "tenant", group_id: "group"}}

    def bindings_for_group("group") do
      {:ok, [%{"provider" => "github", "alias" => "github", "connection_id" => "compute-oauth"}]}
    end
  end

  setup do
    Repo.query!(
      "TRUNCATE compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool-tools",
        tenant_id: "tenant",
        name: "tools",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment-tools",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-tools",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: "registration-tools"
      })

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation-tools",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload-tools",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: 1
      })

    {:ok, grant} =
      Compute.issue_grant(%{
        id: "grant-tools",
        tenant_id: "tenant",
        environment_id: environment.id,
        workload_id: workload.id,
        principal_type: "agent",
        principal_id: "agent",
        permissions: ["workspace", "service_route", "runtime"],
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      })

    %{environment: environment, workload: workload, grant: grant}
  end

  test "registers one compute family and dispatches the authorized Workload", context do
    names = Enum.map(ComputeTools.defs(), &elem(&1, 0))
    assert length(names) == 14
    assert Enum.uniq(names) == names

    assert Enum.all?(
             names,
             &(String.starts_with?(&1, "compute.") or String.starts_with?(&1, "process."))
           )

    assert Enum.all?(names, &(SalixAgent.Tools.find_entry(&1) != nil))

    entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.workspace.stat"))

    result =
      elem(entry, 3).(%{"path" => "src/main.rs"}, %{
        tenant_id: "tenant",
        agent_id: "agent",
        environment_id: context.environment.id,
        workload_grant_id: context.grant.id,
        compute_adapter: Adapter,
        plugin_projection: %{},
        tool_call_id: "workspace-stat-1"
      })
      |> Jason.decode!()

    assert result["workload_id"] == context.workload.id

    exec_entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.exec"))

    exec_result =
      elem(exec_entry, 3).(%{"command" => ["printf", "ok"]}, %{
        tenant_id: "tenant",
        agent_id: "agent",
        environment_id: context.environment.id,
        workload_grant_id: context.grant.id,
        compute_adapter: Adapter,
        plugin_projection: %{},
        tool_call_id: "compute-exec-1"
      })
      |> Jason.decode!()

    assert exec_result["operation"] == "compute.exec"
    assert exec_result["transport"] == "typed"

    process_entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "process.start"))

    process_result =
      elem(process_entry, 3).(%{"command" => ["sh"]}, %{
        tenant_id: "tenant",
        agent_id: "agent",
        environment_id: context.environment.id,
        workload_grant_id: context.grant.id,
        compute_adapter: Adapter,
        plugin_projection: %{},
        tool_call_id: "process-start-1"
      })
      |> Jason.decode!()

    assert Regex.match?(~r/\Atps_[A-Za-z0-9_-]{43}\z/, process_result["args"]["request_id"])

    build_entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.build.run"))

    build_result =
      elem(build_entry, 3).(
        %{
          "dockerfile_path" => "Dockerfile",
          "image" => "comma/test:latest",
          "context_base64" => "Y29udGV4dA=="
        },
        %{
          tenant_id: "tenant",
          agent_id: "agent",
          environment_id: context.environment.id,
          workload_grant_id: context.grant.id,
          compute_adapter: Adapter,
          plugin_projection: %{},
          tool_call_id: "compute-build-1"
        }
      )
      |> Jason.decode!()

    assert build_result["operation"] == "compute.build.run"
    assert build_result["transport"] == "typed"
  end

  test "runtime execution requires the runtime_exec grant", context do
    {:ok, grant} =
      Compute.issue_grant(%{
        id: "grant-tools-workspace-only",
        tenant_id: "tenant",
        environment_id: context.environment.id,
        workload_id: context.workload.id,
        principal_type: "agent",
        principal_id: "agent",
        permissions: ["workspace", "service_route"],
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      })

    exec_entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.exec"))

    assert_raise RuntimeError,
                 ~r/unauthorized/,
                 fn ->
                   elem(exec_entry, 3).(%{"command" => ["printf", "blocked"]}, %{
                     tenant_id: "tenant",
                     agent_id: "agent",
                     environment_id: context.environment.id,
                     workload_grant_id: grant.id,
                     compute_adapter: MustNotRunAdapter,
                     plugin_projection: %{},
                     tool_call_id: "compute-exec-blocked"
                   })
                 end

    build_entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.build.run"))

    assert_raise RuntimeError,
                 ~r/unauthorized/,
                 fn ->
                   elem(build_entry, 3).(
                     %{
                       "dockerfile_path" => "Dockerfile",
                       "image" => "comma/test:blocked",
                       "context_base64" => "Y29udGV4dA=="
                     },
                     %{
                       tenant_id: "tenant",
                       agent_id: "agent",
                       environment_id: context.environment.id,
                       workload_grant_id: grant.id,
                       compute_adapter: MustNotRunAdapter,
                       plugin_projection: %{},
                       tool_call_id: "compute-build-blocked"
                     }
                   )
                 end
  end

  test "exec and process start resolve group OAuth references only for the authorized workload",
       context do
    previous = Application.get_env(:salix_agent, :oauth_store_mod)
    Application.put_env(:salix_agent, :oauth_store_mod, OAuthStore)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :oauth_store_mod, previous),
        else: Application.delete_env(:salix_agent, :oauth_store_mod)
    end)

    :ok =
      SalixStore.OAuth.put("compute-oauth", %{
        "access_token" => "test-oauth-token",
        "status" => "active"
      })

    ctx = %{
      tenant_id: "tenant",
      agent_id: "agent",
      environment_id: context.environment.id,
      workload_grant_id: context.grant.id,
      compute_adapter: Adapter,
      plugin_projection: %{},
      tool_call_id: "oauth-compute-call"
    }

    ref = %{
      "env_var" => "GH_TOKEN",
      "provider" => "github",
      "alias" => "github",
      "value" => "access_token"
    }

    for name <- ["compute.exec", "process.start"] do
      entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == name))
      args = %{"command" => ["gh", "api", "user"], "credential_env" => [ref]}
      result = elem(entry, 3).(args, ctx) |> Jason.decode!()
      assert result["workload_id"] == context.workload.id
      assert result["args"]["env"] == ["GH_TOKEN=test-oauth-token"]
      refute Map.has_key?(result["args"], "credential_env")

      assert_raise RuntimeError, ~r/not bound to this agent group/, fn ->
        elem(entry, 3).(
          put_in(args, ["credential_env"], [%{ref | "alias" => "other-group"}]),
          %{ctx | compute_adapter: MustNotRunAdapter}
        )
      end

      next = elem(entry, 3).(%{"command" => ["true"]}, ctx) |> Jason.decode!()
      refute Map.has_key?(next["args"], "env")
    end

    :ok = Compute.revoke_grant("tenant", context.grant.id, 1)
    entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.exec"))

    assert_raise RuntimeError, ~r/revoked/, fn ->
      elem(entry, 3).(
        %{"command" => ["true"], "credential_env" => [ref]},
        %{ctx | compute_adapter: MustNotRunAdapter}
      )
    end
  end

  test "plugin visibility never invokes or revokes a resource", context do
    projection = %{
      "revision" => 1,
      "disabled_tool_prefixes" => ["compute."],
      "allowed_tool_prefixes" => [],
      "allowed_tools" => [],
      "disabled_tools" => []
    }

    entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.workspace.stat"))

    assert_raise RuntimeError, ~r/admission is disabled/, fn ->
      elem(entry, 3).(%{"path" => "."}, %{
        tenant_id: "tenant",
        agent_id: "agent",
        environment_id: context.environment.id,
        workload_grant_id: context.grant.id,
        compute_adapter: MustNotRunAdapter,
        plugin_projection: projection
      })
    end

    assert Repo.get!(Compute.Environment, context.environment.id).desired_state == "ready"
  end

  test "revoked stable grant fails before Provider dispatch", context do
    assert :ok = Compute.revoke_grant("tenant", context.grant.id, 1)
    entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.workspace.stat"))

    assert_raise RuntimeError, ~r/revoked/, fn ->
      elem(entry, 3).(%{"path" => "."}, %{
        tenant_id: "tenant",
        agent_id: "agent",
        environment_id: context.environment.id,
        workload_grant_id: context.grant.id,
        compute_adapter: MustNotRunAdapter,
        plugin_projection: %{}
      })
    end
  end

  test "workflow restart re-resolves stable intent and rejects a stale Workload generation",
       context do
    entry = Enum.find(ComputeTools.defs(), &(elem(&1, 0) == "compute.workspace.stat"))

    durable_workflow_context = %{
      tenant_id: "tenant",
      agent_id: "agent",
      environment_id: context.environment.id,
      workload_grant_id: context.grant.id,
      compute_adapter: Adapter,
      plugin_projection: %{}
    }

    assert elem(entry, 3).(%{"path" => "."}, durable_workflow_context) =~ context.workload.id

    # The next invocation represents a restarted Workflow actor: it has only
    # stable Environment/grant intent and must resolve authority again.
    assert {:ok, _draining} =
             Compute.update_environment_intent(context.environment.id, 1, %{
               desired_state: "draining"
             })

    assert_raise RuntimeError, ~r/stale_generation|revoked/, fn ->
      elem(entry, 3).(
        %{"path" => "."},
        Map.put(durable_workflow_context, :compute_adapter, MustNotRunAdapter)
      )
    end
  end
end
