defmodule SalixAgent.AgentControlExternalBindingTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Control
  alias SalixStore.{AgentVMM, Compute, Ids, Keys, Repo, RuntimeIds, S3}

  defmodule ConnectedEnvironment do
    @behaviour SalixAgent.RuntimeEnvironment

    def resolve_external_runtime_binding(config, _tenant_id, _group_id),
      do: {:ok, %{"device_runtime_id" => config["device_runtime_id"]}}

    def external_runtime_binding_status(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "status" => Application.get_env(:salix_agent, :test_connected_status, "ready"),
         "device_runtime_id" => config["device_runtime_id"]
       }}
    end
  end

  setup do
    Repo.query!(
      "TRUNCATE compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    previous_store = Application.get_env(:salix_store, :s3_backend)
    previous_environment = Application.get_env(:salix_agent, :runtime_environment_mod)
    previous_connected_status = Application.get_env(:salix_agent, :test_connected_status)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :runtime_environment_mod, ConnectedEnvironment)
    Application.put_env(:salix_agent, :test_connected_status, "ready")
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous_store)
      restore(:salix_agent, :runtime_environment_mod, previous_environment)
      restore(:salix_agent, :test_connected_status, previous_connected_status)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)

    agent =
      SalixAgent.TestSupport.create_legacy_control_agent!(agent_id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "role" => "worker",
        "runtime_config" => connected_binding(group_id, 0)
      })

    %{agent: agent, tenant_id: tenant_id, group_id: group_id}
  end

  test "one CAS orders Connected to Compute and rejects delayed or conflicting commands", ctx do
    connected_1 = connected_binding(ctx.group_id, 1)

    assert {:ok, first} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               connected_1
             )

    assert first["runtime_config"]["binding_revision"] == 1

    workload = compute_fixture(ctx.tenant_id, ctx.group_id, "project")
    compute_2 = compute_binding(workload.id, "project", 2)

    assert {:ok, second} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               compute_2
             )

    assert second["runtime_config"] == compute_2

    # A superseded command terminates by revision alone. Its old target may
    # disappear after the newer binding commits and must not be revalidated.
    Application.put_env(:salix_agent, :test_connected_status, "missing")

    assert {:ok, superseded} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               connected_1
             )

    assert superseded["runtime_config"] == compute_2

    assert {:error, :binding_revision_conflict} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               compute_binding(workload.id, "project-other", 2)
             )

    assert {:ok, idempotent} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               compute_2
             )

    assert idempotent["runtime_config"] == compute_2
  end

  test "concurrent Router rebind decisions have one CAS winner and stale replay cannot replace it",
       ctx do
    id = ctx.agent["agent_id"]
    assert {:ok, _} = Control.claim_configuration(id, ctx.tenant_id)

    calls =
      for provider <- ["pi", "claude"] do
        Task.async(fn ->
          Control.rebind_external_worker(
            id,
            ctx.tenant_id,
            Map.drop(connected_binding(ctx.group_id, 1, provider), ["binding_revision"]),
            0,
            provider
          )
        end)
      end

    results = Enum.map(calls, &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{result: :applied}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :binding_conflict}, &1)) == 1
    assert {:ok, winner} = Control.get(id)
    assert winner["runtime_config"]["binding_revision"] == 1

    assert {:error, :binding_conflict} =
             Control.rebind_external_worker(
               id,
               ctx.tenant_id,
               Map.drop(connected_binding(ctx.group_id, 1), ["binding_revision"]),
               0,
               "stale"
             )

    assert {:ok, ^winner} = Control.get(id)
  end

  test "generic update preserves revised envelopes but cannot replace them", ctx do
    binding = connected_binding(ctx.group_id, 1)

    assert {:ok, _} =
             Control.apply_external_worker_binding(ctx.agent["agent_id"], ctx.tenant_id, binding)

    assert {:ok, _} = Control.claim_configuration(ctx.agent["agent_id"], ctx.tenant_id)

    assert {:ok, renamed} =
             Control.configure(ctx.agent["agent_id"], %{"name" => "renamed"}, ctx.tenant_id)

    assert renamed["runtime_config"] == binding

    assert {:error, {:bad_request, "external worker binding must use revision CAS"}} =
             Control.configure(
               ctx.agent["agent_id"],
               %{"runtime_config" => connected_binding(ctx.group_id, 2)},
               ctx.tenant_id
             )
  end

  test "Claude is admitted for both Connected and Compute", ctx do
    binding = connected_binding(ctx.group_id, 1, "claude")

    assert {:ok, revised} =
             Control.apply_external_worker_binding(ctx.agent["agent_id"], ctx.tenant_id, binding)

    assert revised["runtime_config"] == binding

    workload = compute_fixture(ctx.tenant_id, ctx.group_id, "claude-project", "claude")

    assert {:ok, compute_revised} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               compute_binding(workload.id, "claude-project", 2, "claude")
             )

    assert compute_revised["runtime_config"]["runtime_spec"] == %{"provider" => "claude"}
  end

  test "compute apply rejects same-tenant cross-project and registration-group targets", ctx do
    other_project = compute_fixture(ctx.tenant_id, ctx.group_id, "project-b")

    assert {:error, :scope_mismatch} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               compute_binding(other_project.id, "project-a", 1)
             )

    wrong_group = compute_fixture(ctx.tenant_id, Ids.new_group_id(ctx.tenant_id), "project-c")

    assert {:error, :scope_mismatch} =
             Control.apply_external_worker_binding(
               ctx.agent["agent_id"],
               ctx.tenant_id,
               compute_binding(wrong_group.id, "project-c", 1)
             )
  end

  test "router and meeting records cannot enter the external binding CAS", ctx do
    for role <- ~w(router meeting) do
      key = Keys.ctl_agent(ctx.agent["agent_id"])
      assert {:ok, %{body: body, etag: etag}} = S3.get(key)
      record = body |> Jason.decode!() |> Map.put("role", role)
      assert {:ok, _} = S3.put(key, Jason.encode!(record), if_match: etag)

      assert {:error, :external_binding_role_mismatch} =
               Control.apply_external_worker_binding(
                 ctx.agent["agent_id"],
                 ctx.tenant_id,
                 connected_binding(ctx.group_id, 1)
               )

      assert {:ok, %{body: unchanged_body}} = S3.get(key)
      unchanged = Jason.decode!(unchanged_body)
      assert unchanged["role"] == role
      assert unchanged["runtime_config"]["binding_revision"] == nil
    end
  end

  defp connected_binding(group_id, revision, provider \\ "codex") do
    device_id = "device"
    runtime_id = "runtime"

    binding = %{
      "kind" => "connected_runtime",
      "provider" => provider,
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" => RuntimeIds.device_runtime_id(device_id, provider, runtime_id)
    }

    if revision > 0 do
      Map.merge(binding, %{
        "owner_scope" => %{"type" => "group", "id" => group_id},
        "binding_revision" => revision
      })
    else
      binding
    end
  end

  defp compute_binding(workload_id, project_id, revision, provider \\ "codex") do
    %{
      "kind" => "compute_workload",
      "workload_id" => workload_id,
      "runtime_spec" => %{"provider" => provider},
      "owner_scope" => %{"type" => "project", "id" => project_id},
      "binding_revision" => revision
    }
  end

  defp compute_fixture(tenant_id, group_id, project_id, provider \\ "codex") do
    suffix = System.unique_integer([:positive])
    now = DateTime.utc_now()

    pool =
      Repo.insert!(%Compute.Pool{
        id: "pool-#{suffix}",
        tenant_id: tenant_id,
        name: "pool-#{suffix}",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: [],
        capacity: %{},
        quota: %{},
        status: "active",
        revision: 1,
        created_at: now,
        updated_at: now
      })

    environment =
      Repo.insert!(%Compute.Environment{
        id: "environment-#{suffix}",
        tenant_id: tenant_id,
        owner_type: "project",
        owner_id: project_id,
        pool_id: pool.id,
        desired_state: "ready",
        observed_state: "ready",
        generation: 1,
        revision: 1,
        retention: %{"mode" => "retain"},
        inventory_watermark: 1,
        created_at: now,
        updated_at: now
      })

    registration =
      Repo.insert!(%AgentVMM.Registration{
        id: "registration-#{suffix}",
        tenant_id: tenant_id,
        group_id: group_id,
        device_id: "device-#{suffix}",
        status: "ready",
        revision: 1,
        policy_revision: 1,
        desired_enabled: true,
        next_controller_sequence: 1,
        created_at: now,
        updated_at: now
      })

    provider_binding =
      Repo.insert!(%Compute.ProviderBinding{
        id: "binding-#{suffix}",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        status: "available",
        generation: 1,
        revision: 1,
        observation: %{},
        updated_at: now
      })

    allocation =
      Repo.insert!(%Compute.Allocation{
        id: "allocation-#{suffix}",
        environment_id: environment.id,
        provider_binding_id: provider_binding.id,
        status: "ready",
        operation_outcome: "succeeded",
        generation: 1,
        provider_observation: %{},
        revision: 1,
        created_at: now,
        updated_at: now
      })

    Repo.insert!(%Compute.Workload{
      id: "workload-#{suffix}",
      environment_id: environment.id,
      allocation_id: allocation.id,
      kind: "external_worker",
      spec: %{},
      template_key: "external.#{provider}",
      runtime_revision: "runtime",
      capability_requirements: [],
      desired_state: "ready",
      observed_state: "ready",
      generation: 1,
      revision: 1,
      created_at: now,
      updated_at: now
    })
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
