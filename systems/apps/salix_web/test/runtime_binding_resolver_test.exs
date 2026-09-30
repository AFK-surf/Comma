defmodule SalixAgent.RuntimeBindingResolverTest do
  use ExUnit.Case, async: false

  alias SalixAgent.RuntimeBindingResolver
  alias SalixStore.{AgentVMM, Compute, Ids, Repo}
  require Ecto.Query

  defmodule ConnectedEnvironment do
    @behaviour SalixAgent.RuntimeEnvironment
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "device_runtime_id" => config["device_runtime_id"],
         "connector_run_id" => "connector-run",
         "connection_generation" => 7
       }}
    end

    def external_runtime_binding_status(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "status" => "ready",
         "device_runtime_id" => config["device_runtime_id"],
         "connector_run_id" => "connector-run"
       }}
    end
  end

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_route_capabilities, agent_vmm_membership_credentials, agent_vmm_trust_anchors, agent_vmm_audit_events, agent_vmm_sessions, agent_vmm_registrations, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    previous = %{
      environment: Application.get_env(:salix_agent, :runtime_environment_mod)
    }

    Application.put_env(:salix_agent, :runtime_environment_mod, ConnectedEnvironment)

    on_exit(fn ->
      restore(:salix_agent, :runtime_environment_mod, previous.environment)
    end)

    :ok
  end

  test "Connected Device and current Compute carriers resolve to the same External Worker contract" do
    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    connected = %{
      "kind" => "connected_runtime",
      "device_runtime_id" => "device-runtime",
      "provider" => "codex"
    }

    assert {:ok, connected_target} = RuntimeBindingResolver.resolve(connected, tenant, group)
    assert connected_target["stable_target_id"] == "device-runtime"
    assert connected_target["connection_epoch"] == 7

    assert {:error, :group_workload_unavailable} =
             RuntimeBindingResolver.resolve(connected, "tenant", "group")

    for carrier <- ~w(cloudflare agent_vmm) do
      fixture = compute_fixture(carrier)

      binding = %{
        "kind" => "compute_workload",
        "workload_id" => fixture.workload.id,
        "runtime_spec" => %{"provider" => "codex"}
      }

      assert {:ok, target} = RuntimeBindingResolver.resolve(binding, "tenant", "group")
      assert target["stable_target_id"] == fixture.workload.id
      assert target["connection_epoch"] == "1"
    end
  end

  test "a reconnect epoch is unavailable until catch-up" do
    fixture = compute_fixture("agent_vmm")

    assert {:ok, reconnecting} =
             Compute.observe_runtime(%{
               id: fixture.runtime.id,
               workload_id: fixture.workload.id,
               allocation_id: fixture.allocation.id,
               generation: 1,
               connection_epoch: "2"
             })

    binding = %{
      "kind" => "compute_workload",
      "workload_id" => fixture.workload.id,
      "runtime_spec" => %{"provider" => "codex"}
    }

    assert {:error, :runtime_catching_up} =
             RuntimeBindingResolver.resolve(binding, "tenant", "group")

    assert {:ok, _} =
             Compute.complete_runtime_catch_up(reconnecting.id, reconnecting.revision, "2")

    assert {:ok, target} = RuntimeBindingResolver.resolve(binding, "tenant", "group")
    assert target["runtime_instance_id"] == fixture.runtime.id
    assert target["connection_epoch"] == "2"
  end

  test "a route or runtime instance cannot replace the binding's stable identity" do
    for binding <- [
          %{"kind" => "connected_runtime", "connector_run_id" => "connector-run"},
          %{"kind" => "compute_workload", "runtime_instance_id" => "runtime-instance"},
          %{"kind" => "compute_workload", "workload_id" => ""}
        ] do
      assert {:error, {:bad_request, _}} =
               RuntimeBindingResolver.resolve(binding, "tenant", "group")
    end
  end

  test "a runtime bundle generation advances independently of its placement generation" do
    fixture = compute_fixture("agent_vmm")

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
        set: [generation: 2]
      )

    {1, _} =
      Repo.update_all(
        Ecto.Query.from(r in Compute.RuntimeInstance, where: r.id == ^fixture.runtime.id),
        set: [generation: 2]
      )

    binding = %{
      "kind" => "compute_workload",
      "workload_id" => fixture.workload.id,
      "runtime_spec" => %{"provider" => "pi"}
    }

    assert {:ok, target} = RuntimeBindingResolver.resolve(binding, "tenant", "group")
    assert target["stable_target_id"] == fixture.workload.id
    assert target["runtime_instance_id"] == fixture.runtime.id

    assert Repo.get!(Compute.Environment, fixture.allocation.environment_id).generation == 1
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).generation == 1
  end

  test "a scoped Compute binding rejects another Project in the same tenant" do
    fixture = compute_fixture("agent_vmm")

    Repo.update_all(
      Ecto.Query.from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [template_key: "external.codex"]
    )

    binding = %{
      "kind" => "compute_workload",
      "workload_id" => fixture.workload.id,
      "runtime_spec" => %{"provider" => "codex"},
      "owner_scope" => %{"type" => "project", "id" => "other-project"},
      "binding_revision" => 1
    }

    assert {:error, :binding_scope_mismatch} =
             RuntimeBindingResolver.resolve(binding, "tenant", "group")

    binding = put_in(binding, ["owner_scope", "id"], "agent_vmm-project")
    assert {:ok, target} = RuntimeBindingResolver.resolve(binding, "tenant", "group")
    assert target["workload_id"] == fixture.workload.id
  end

  defp compute_fixture(carrier) do
    {:ok, pool} =
      Compute.create_pool(%{
        id: carrier <> "-pool",
        tenant_id: "tenant",
        name: carrier,
        region: "local",
        provider_policy: %{"providers" => [carrier]}
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: carrier <> "-environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: carrier <> "-project",
        pool_id: pool.id
      })

    {:ok, environment} =
      Compute.reconcile_inventory(environment.id, environment.revision, 1, "ready")

    provider_ref =
      if carrier == "agent_vmm" do
        {:ok, registration} =
          AgentVMM.create_registration(%{
            id: carrier <> "-registration",
            tenant_id: "tenant",
            group_id: "group",
            device_id: "device",
            enrollment_token: String.duplicate("r", 32)
          })

        Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])
        registration.id
      else
        carrier <> "-private-ref"
      end

    binding_attrs = %{
      id: carrier <> "-binding",
      pool_id: pool.id,
      provider: carrier,
      provider_ref: provider_ref
    }

    binding_attrs =
      if carrier == "agent_vmm",
        do: Map.put(binding_attrs, :environment_id, environment.id),
        else: binding_attrs

    {:ok, provider_binding} = Compute.create_provider_binding(binding_attrs)

    if carrier == "agent_vmm" do
      assert {:ok, :ok} =
               AgentVMM.observe_registration(provider_ref, "gateway", %{
                 "connectionEpoch" => "1",
                 "inventoryWatermark" => 0,
                 "inventory" => []
               })
    end

    {:ok, allocation} =
      Compute.allocate(%{
        id: carrier <> "-allocation",
        environment_id: environment.id,
        provider_binding_id: provider_binding.id,
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded", %{
        "current_container" => %{
          "id" => carrier <> "-container",
          "instance_id" => carrier <> "-instance"
        },
        "container_status" => "running"
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: carrier <> "-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: 1
      })

    {:ok, workload} = Compute.observe_workload(workload.id, workload.revision, 1, "ready")

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: carrier <> "-runtime",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")
    %{allocation: allocation, workload: workload, runtime: runtime}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
