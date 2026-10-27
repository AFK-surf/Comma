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
  @vm_events [
    [:salix, :vm, :wake, :stop],
    [:salix, :vm, :archive, :stop],
    [:salix, :vm, :fleet, :records],
    [:salix, :vm, :fleet, :oldest_age]
  ]

  setup do
    handler = "agent-vmm-cloud-vm-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        @vm_events,
        &__MODULE__.forward_vm_telemetry/4,
        SystemsRuntime.Proc.self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

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

    %{
      group: group,
      workload_id: rec["workload_id"],
      tenant: tenant,
      registration_id: registration_id
    }
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

    assert_received {:vm_telemetry, [:salix, :vm, :archive, :stop],
                     %{duration_seconds: sleep_seconds},
                     %{
                       provider: "agent_vmm",
                       profile: "vmm-station-1",
                       reason: "idle",
                       outcome: "ok"
                     }}

    assert is_number(sleep_seconds) and sleep_seconds >= 0

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

    assert_received {:vm_telemetry, [:salix, :vm, :wake, :stop],
                     %{duration_seconds: wake_seconds},
                     %{provider: "agent_vmm", profile: "vmm-station-1", outcome: "ok"}}

    assert is_number(wake_seconds) and wake_seconds >= 0

    # Ready again, operations are admitted and counted toward its activity.
    assert {:ok, operation} = Cloudflare.begin_operation(ctx.group, "exec")
    assert record(ctx)["active_operation_count"] == 1
    assert :ok = Cloudflare.finish_operation(ctx.group, operation, "succeeded", %{})
  end

  test "a busy or unreachable station keeps its VM ready", ctx do
    assert {:ok, _} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert %{"status" => "ready", "ready_at" => ready_at} = record(ctx)
    due = ready_at + 300_000

    Process.put(
      {:station, "cloud_runtime_quiesce"},
      {:error, "cloud_runtime_quiesce: runtime is not quiet"}
    )

    before = SystemsClock.system_time(:millisecond)

    assert {:ok, %{outcome: :group_reconciled}} =
             reconcile(ctx, idle_archive_ms: 300_000, now: due)

    assert_received {:station, "cloud_runtime_quiesce", %{"token" => token}}
    assert_received {:station, "cloud_runtime_resume", %{"token" => ^token}}
    refute_received {:vmm, :stop, _, _}

    assert %{"status" => "ready", "archive_retry_at" => retry_at, "archive_refusals" => 1} =
             record(ctx)

    assert retry_at >= before + 300_000

    # Nothing of the sleep began: the station refused it.
    assert_received {:vm_telemetry, [:salix, :vm, :archive, :stop], %{duration_seconds: _},
                     %{provider: "agent_vmm", reason: "idle", outcome: "refused"}}

    # Still idle by the clock, it is not asked again before the wait is over.
    assert {:ok, %{outcome: :group_reconciled}} =
             reconcile(ctx, idle_archive_ms: 300_000, now: due)

    refute_received {:station, "cloud_runtime_quiesce", _}
    assert %{"status" => "ready"} = record(ctx)

    # Refused again when the wait is over, the next wait doubles.
    before = SystemsClock.system_time(:millisecond)

    assert {:ok, %{outcome: :group_reconciled}} =
             reconcile(ctx, idle_archive_ms: 300_000, now: retry_at)

    assert_received {:station, "cloud_runtime_quiesce", _}
    assert %{"archive_retry_at" => retry_at, "archive_refusals" => 2} = record(ctx)
    assert retry_at >= before + 600_000

    # Without its station, the Host shows whether the container still runs.
    Process.put(:station_connected, false)
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    refute_received {:vmm, :stop, _, _}
    assert %{"status" => "ready"} = record(ctx)
  end

  test "after a VM restart stopped its container, the VM is reconciled until it is ready again",
       ctx do
    assert {:ok, _} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    assert %{"status" => "ready"} = record(ctx)

    # The VM restarted: its station is gone, and the Host shows the container
    # stopped. The Workload follows the container facts, as any on a Host.
    Process.put(:station_connected, false)
    workload = Repo.get!(GroupCompute.Workload, ctx.workload_id)
    allocation = Repo.get!(GroupCompute.Allocation, workload.allocation_id)

    assert {:ok, _} =
             GroupCompute.observe_allocation_facts(
               allocation.id,
               allocation.revision,
               allocation.generation,
               %{"container_status" => "stopped"},
               [],
               workload
             )

    assert %{"status" => "pending"} = record(ctx)

    # The sweep still claims it and runs the Host's container provider, which
    # has not seen the container run yet: the claim waits for its next try.
    assert ComputeReconciler.sweep() in [:more, :complete]

    assert [%{attempt_count: 1, next_retry_at: %DateTime{}}] =
             Repo.all(
               from(c in GroupCompute.ReconcilerClaim, where: c.workload_id == ^ctx.workload_id)
             )

    # While the Host starts the container again, the VM stays pending.
    Process.put(:vmm_result, {:ok, %{outcome: :pending, resource: allocation}})
    assert {:ok, %{outcome: :pending}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    assert %{"status" => "pending"} = record(ctx)

    # The container runs and is verified, and the station is back: ready.
    Process.delete(:vmm_result)
    Process.put(:station_connected, true)
    assert {:ok, _} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert_received {:vmm, :reconcile, _}
    assert %{"status" => "ready"} = record(ctx)
    assert Repo.get!(GroupCompute.Workload, ctx.workload_id).observed_state == "ready"

    # Ready with its station connected, nothing more to do.
    assert {:ok, %{outcome: :group_reconciled}} = reconcile(ctx, idle_archive_ms: 3_600_000)
    refute_received {:vmm, :reconcile, _}
  end

  test "its station's Task activity keeps a VM awake: it sleeps 5 minutes after the last Message",
       ctx do
    assert {:ok, _} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert %{"status" => "ready", "ready_at" => ready_at} = record(ctx)

    # The station was given a Task Message (SalixWeb.StationTasks) long after
    # the VM became ready.
    device = SalixStore.RuntimeIds.cloud_vm_device_id(ctx.group)
    assert :ok = Cloudflare.mark_station_activity(ctx.group, device)
    assert %{"last_station_activity_at" => activity} = record(ctx)
    assert activity >= ready_at

    assert {:ok, %{outcome: :group_reconciled}} =
             reconcile(ctx, idle_archive_ms: 300_000, now: activity + 299_999)

    refute_received {:station, "cloud_runtime_quiesce", _}
    assert %{"status" => "ready"} = record(ctx)

    assert {:ok, %{outcome: :group_reconciled}} =
             reconcile(ctx, idle_archive_ms: 300_000, now: activity + 300_000)

    assert_received {:station, "cloud_runtime_quiesce", %{"token" => token}}
    assert_received {:vmm, :stop, _, ^token}
    assert %{"status" => "archived"} = record(ctx)
  end

  test "the fleet gauges count records by state and age the oldest one still creating", ctx do
    created_at = record(ctx)["created_at"]
    now = created_at + 7 * 24 * 3_600_000

    assert :ok = SalixEnv.ComputeReconciler.emit_fleet_metrics(now: now)

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 1},
                     %{provider: "agent_vmm", state: "creating"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 0},
                     %{provider: "agent_vmm", state: "ready"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 0},
                     %{provider: "cloudflare", state: "creating"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :oldest_age], %{age_seconds: age},
                     %{provider: "agent_vmm", state: "creating"}}

    assert_in_delta age, 7 * 24 * 3600, 1

    for state <- ~w(waking archiving failed) do
      assert_received {:vm_telemetry, [:salix, :vm, :fleet, :oldest_age], %{age_seconds: 0},
                       %{provider: "agent_vmm", state: ^state}}
    end

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :oldest_age], %{age_seconds: 0},
                     %{provider: "cloudflare", state: "creating"}}

    flush_vm_telemetry()

    # Ready, the record stands in no state it should pass through.
    assert {:ok, _} = reconcile(ctx, idle_archive_ms: 3_600_000)
    assert %{"status" => "ready"} = record(ctx)
    assert :ok = SalixEnv.ComputeReconciler.emit_fleet_metrics(now: now)

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 1},
                     %{provider: "agent_vmm", state: "ready"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 0},
                     %{provider: "agent_vmm", state: "creating"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :oldest_age], %{age_seconds: 0},
                     %{provider: "agent_vmm", state: "creating"}}

    flush_vm_telemetry()

    # Statuses are summed under the label they report as: two that share
    # `other` count 2, and a named one stands by itself.
    for status <- ["billing_suspended", "stopped", "draining"] do
      group = SalixStore.Ids.new_group_id(ctx.tenant)

      {:ok, _rec, :created} =
        GroupCompute.ensure_group_workload(%{
          "tenant_id" => ctx.tenant,
          "group_id" => group,
          "provider" => "agent_vmm",
          "provider_resource_id" => ctx.registration_id,
          "provider_resource_name" =>
            SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group),
          "provider_spec" => %{"profile_key" => "vmm-station-1"},
          "env_id" => SalixStore.RuntimeIds.cloud_vm_env_id(group),
          "device_id" => SalixStore.RuntimeIds.cloud_vm_device_id(group),
          "connector_id" => "cloud-vm-connector",
          "alias" => "cloud-vm",
          "status" => status,
          "created_at" => SystemsClock.system_time(:millisecond)
        })
    end

    assert :ok = SalixEnv.ComputeReconciler.emit_fleet_metrics(now: now)

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 1},
                     %{provider: "agent_vmm", state: "billing_suspended"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 2},
                     %{provider: "agent_vmm", state: "other"}}

    assert_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 1},
                     %{provider: "agent_vmm", state: "ready"}}

    refute_received {:vm_telemetry, [:salix, :vm, :fleet, :records], %{count: 1},
                     %{provider: "agent_vmm", state: "other"}}
  end

  def forward_vm_telemetry(event, measurements, metadata, pid) do
    SystemsRuntime.Proc.send(pid, {:vm_telemetry, event, measurements, metadata})
  end

  defp flush_vm_telemetry do
    receive do
      {:vm_telemetry, _, _, _} -> flush_vm_telemetry()
    after
      0 -> :ok
    end
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
