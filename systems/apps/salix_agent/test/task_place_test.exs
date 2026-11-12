defmodule SalixAgent.TaskPlaceTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.TaskPlace
  alias SalixStore.{Ids, RuntimeIds, S3}

  # The Group can have a Cloud VM, unless a test says not.
  defmodule VM do
    @moduledoc false
    @behaviour SalixAgent.CloudVM

    def available?(_tenant_id, _group_id),
      do: SystemsRuntime.get_env(:salix_agent, :cloud_vm_available, true)

    defdelegate ensure_provisioning(agent), to: SalixAgent.CloudVM.None
    defdelegate mark_agent_settled(agent_id), to: SalixAgent.CloudVM.None
    defdelegate start(agent_id, worker_id, budget_ms), to: SalixAgent.CloudVM.None
  end

  setup do
    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group)
    previous = SystemsRuntime.get_env(:salix_agent, :cloud_vm_mod)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, VM)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :cloud_vm_mod)

      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_available)
    end)

    %{tenant: tenant, group: group}
  end

  defmodule SandboxesOn do
    @moduledoc false
    def enabled?, do: true
  end

  test "a sandbox is a default place where sandboxes are set up; where the Cloud VM is retired, it is not one",
       %{tenant: tenant, group: group} do
    assert TaskPlace.valid?(TaskPlace.sandbox())
    # Set at once, not at each Task: a sandbox needs sandboxes set up.
    assert {:error, :sandbox_unavailable} = TaskPlace.put(tenant, group, %{kind: "sandbox"})

    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)
    end)

    assert {:ok, %{"kind" => "sandbox"}} = TaskPlace.put(tenant, group, %{kind: "sandbox"})
    assert {:ok, %{"kind" => "sandbox"}} = TaskPlace.get(group)

    # Sandboxes set up, the Cloud VM not retired: both are places.
    assert {:ok, %{"kind" => "cloud_vm"}} = TaskPlace.put(tenant, group, TaskPlace.cloud_vm())

    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)
    assert {:error, :cloud_vm_retired} = TaskPlace.put(tenant, group, TaskPlace.cloud_vm())
    assert {:ok, %{"kind" => "sandbox"}} = TaskPlace.put(tenant, group, TaskPlace.sandbox())
  end

  test "a Group created where sandboxes are set up takes no Cloud VM as its default place",
       %{tenant: tenant, group: group} do
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SandboxesOn)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod) end)

    SalixAgent.TestSupport.create_control_group!(group, %{"cloud_vm_retired" => true})

    assert {:error, :cloud_vm_retired} = TaskPlace.put(tenant, group, TaskPlace.cloud_vm())
    assert {:ok, %{"kind" => "sandbox"}} = TaskPlace.put(tenant, group, TaskPlace.sandbox())
  end

  test "a Group's default place: set, checked, kept by a derived default, and cleared", %{
    tenant: tenant,
    group: group
  } do
    assert {:ok, nil} = TaskPlace.get(group)

    # The Cloud VM only while the Group can have one.
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_available, false)
    assert {:error, :cloud_vm_disabled} = TaskPlace.put(tenant, group, TaskPlace.cloud_vm())
    SystemsRuntime.delete_env(:salix_agent, :cloud_vm_available)
    assert {:ok, %{"kind" => "cloud_vm"}} = TaskPlace.put(tenant, group, %{kind: "cloud_vm"})

    # The Group's own Cloud VM station is named as the Cloud VM.
    vm_station = %{"kind" => "station", "device_id" => RuntimeIds.cloud_vm_device_id(group)}
    assert {:error, :use_cloud_vm_kind} = TaskPlace.put(tenant, group, vm_station)
    assert {:error, :invalid_task_place} = TaskPlace.put(tenant, group, %{"kind" => "elsewhere"})

    station = %{"kind" => "station", "device_id" => "device-1"}
    assert {:ok, ^station} = TaskPlace.put(tenant, group, station)

    # Another Tenant's Group is not found.
    other = SalixAgent.TestSupport.new_tenant_id()
    assert {:error, :not_found} = TaskPlace.put(other, group, TaskPlace.salix())

    # A derived default does not replace one people chose, Salix included.
    assert {:ok, ^station} = TaskPlace.put_new(tenant, group, TaskPlace.cloud_vm())
    assert {:ok, %{"kind" => "salix"}} = TaskPlace.put(tenant, group, TaskPlace.salix())
    assert {:ok, %{"kind" => "salix"}} = TaskPlace.put_new(tenant, group, TaskPlace.cloud_vm())

    assert {:ok, nil} = TaskPlace.put(tenant, group, nil)
    assert {:ok, nil} = TaskPlace.get(group)
    assert {:ok, %{"kind" => "cloud_vm"}} = TaskPlace.put_new(tenant, group, TaskPlace.cloud_vm())
  end
end
