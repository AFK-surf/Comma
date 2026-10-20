defmodule SalixAgent.TaskPlaceTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.TaskPlace
  alias SalixStore.{Ids, RuntimeIds, S3}

  setup do
    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group)
    %{tenant: tenant, group: group}
  end

  test "a Group's default place: set, checked, kept by a derived default, and cleared", %{
    tenant: tenant,
    group: group
  } do
    assert {:ok, nil} = TaskPlace.get(group)

    # The Cloud VM only while the Group's Cloud VM switch is on.
    assert {:error, :cloud_vm_disabled} = TaskPlace.put(tenant, group, TaskPlace.cloud_vm())
    SalixAgent.TestSupport.create_control_group!(group, %{"cloud_vm_enabled" => true})
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
