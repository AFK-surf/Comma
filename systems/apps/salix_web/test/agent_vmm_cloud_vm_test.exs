defmodule SalixWeb.AgentVMMCloudVMTest do
  use SystemsClock.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SalixEnv.ComputeReconciler
  alias SalixStore.{AgentVMM, Repo}
  alias SalixStore.Compute, as: GroupCompute
  alias SalixWeb.CloudVM.RuntimeLifecycle
  alias SalixWeb.ComputeProviders.Cloudflare

  # The Host's container, as SalixEnv.ComputeProviders.AgentVMM drives it.
  defmodule FakeVMM do
    def reconcile(_allocation, workload, _opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:vmm, :reconcile, workload.id})
      Process.get(:vmm_result, {:ok, %{outcome: :succeeded, observation: %{}}})
    end

    def stop_container(_allocation, workload, operation) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:vmm, :stop, workload.id, operation})
      {:ok, :stopped}
    end
  end

  # The container's station, over its connection to Salix.
  defmodule FakeStation do
    def connected?(_rec), do: Process.get(:station_connected, true)

    def request(_rec, method, params, _timeout) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:station, method, params})

      cond do
        not Process.get(:station_connected, true) -> {:error, :disconnected}
        reply = Process.get({:station, method}) -> reply
        method == "cloud_runtime_quiesce" -> {:ok, %{"quiet" => true, "continued" => false}}
        method == "cloud_runtime_release" -> {:ok, %{"released" => true}}
        true -> {:ok, %{"resumed" => true}}
      end
    end
  end

  @fakes [vmm: FakeVMM, station: FakeStation]

  setup do
    Repo.query!(
      "TRUNCATE compute_reconciler_claims, compute_reconciler_cursors, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    registration_id =
      "host-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

    {:ok, _registration} =
      AgentVMM.create_registration(%{
        id: registration_id,
        tenant_id: tenant,
        group_id: group,
        device_id: "host-device",
        enrollment_token: String.duplicate("h", 32)
      })

    connect_host!(tenant, registration_id)

    {:ok, rec, :created} =
      GroupCompute.ensure_group_workload(%{
        "tenant_id" => tenant,
        "group_id" => group,
        "provider" => "agent_vmm",
        "provider_resource_id" => registration_id,
        "provider_resource_name" => SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group),
        "provider_spec" => %{"profile_key" => "vmm-station-1"},
        "env_id" => SalixStore.RuntimeIds.cloud_vm_env_id(group),
        "device_id" => SalixStore.RuntimeIds.cloud_vm_device_id(group),
        "connector_id" => "cloud-vm-connector",
        "alias" => "cloud-vm",
        "status" => "creating",
        "created_at" => SystemsClock.system_time(:millisecond)
      })

    %{group: group, workload_id: rec["workload_id"]}
  end

  test "an idle VM sleeps by stopping its container and wakes by starting it", ctx do
    # Created: the Host runs the container, and the VM is ready.
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    assert %{"status" => "ready", "ready_at" => ready_at} = record(ctx)
    assert is_integer(ready_at)

    # Connected and busy within the idle window: nothing to do.
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    refute_received {:vmm, :reconcile, _}
    refute_received {:station, _, _}

    # Idle: the station parks quiet and releases itself, then the container stops.
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 0)
    assert_received {:station, "cloud_runtime_quiesce", %{"token" => token}}
    assert_received {:station, "cloud_runtime_release", %{"token" => ^token}}
    assert_received {:vmm, :stop, _, ^token}
    assert %{"status" => "archived"} = asleep = record(ctx)
    refute Map.has_key?(asleep, "archive_operation_id")

    # Asleep, nothing wakes it by itself.
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 0)
    refute_received {:vmm, _, _}

    # Work for the VM wakes it; callers retry while it starts.
    assert {:error, :runtime_waking} = Cloudflare.begin_operation(ctx.group, "exec")
    assert {:error, :runtime_waking} = RuntimeLifecycle.wake(ctx.group)
    assert {:error, {:vm_waking, _}} = Cloudflare.wake_if_archived(ctx.group)
    assert is_integer(record(ctx)["wake_requested_at"])

    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    assert %{"status" => "ready"} = awake = record(ctx)
    refute Map.has_key?(awake, "wake_requested_at")

    # Ready again, operations are admitted and counted toward its activity.
    assert {:ok, operation} = Cloudflare.begin_operation(ctx.group, "exec")
    assert record(ctx)["active_operation_count"] == 1
    assert :ok = Cloudflare.finish_operation(ctx.group, operation, "succeeded", %{})
  end

  test "a busy or unreachable station keeps its VM ready", ctx do
    assert {:ok, _} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert %{"status" => "ready"} = record(ctx)

    Process.put(
      {:station, "cloud_runtime_quiesce"},
      {:error, "cloud_runtime_quiesce: runtime is not quiet"}
    )

    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 0)
    assert_received {:station, "cloud_runtime_quiesce", %{"token" => token}}
    assert_received {:station, "cloud_runtime_resume", %{"token" => ^token}}
    refute_received {:vmm, :stop, _, _}
    assert %{"status" => "ready", "archive_retry_at" => retry_at} = record(ctx)
    assert retry_at > SystemsClock.system_time(:millisecond)

    # Without its station, the Host shows whether the container still runs.
    Process.put(:station_connected, false)
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    refute_received {:vmm, :stop, _, _}
    assert %{"status" => "ready"} = record(ctx)
  end

  defp reconcile(ctx, opts) do
    workload = Repo.get!(GroupCompute.Workload, ctx.workload_id)
    ComputeReconciler.reconcile_workload(workload.id, workload.generation, @fakes ++ opts)
  end

  defp record(ctx) do
    {:ok, rec} = GroupCompute.group_workload(ctx.group)
    rec
  end

  # The Host's current connection made its Project Environment's binding available.
  defp connect_host!(tenant, registration_id) do
    {:ok, pool} =
      GroupCompute.create_pool(%{
        id: "host-pool-" <> registration_id,
        tenant_id: tenant,
        name: "Host",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      GroupCompute.create_environment(%{
        id: "host-project-" <> registration_id,
        tenant_id: tenant,
        owner_type: "project",
        owner_id: "project-" <> registration_id,
        pool_id: pool.id
      })

    {:ok, binding} =
      GroupCompute.create_provider_binding(%{
        id: "host-binding-" <> registration_id,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration_id
      })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration_id),
      set: [status: "ready", desired_enabled: true]
    )

    Repo.update_all(from(b in GroupCompute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "available", observation: %{"connection_epoch" => "7"}]
    )
  end
end
