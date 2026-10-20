defmodule SalixWeb.CloudVMActivityTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  alias SalixStore.{Compute, Ids, Repo}

  setup do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, record, :created} =
             Compute.ensure_group_workload(ready_record(tenant_id, group_id))

    {:ok, group_id: group_id, record: record}
  end

  test "nine concurrent begins commit one ledger and nine finishes remove their union", %{
    group_id: group_id
  } do
    operation_ids = Enum.map(1..9, &"read-#{&1}")

    results =
      concurrent(9, fn index ->
        SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "read",
          operation_id: "read-#{index}",
          mutating?: false
        )
      end)

    assert Enum.sort(results) == Enum.map(operation_ids, &{:ok, &1})

    assert {:ok, record} = Compute.group_workload(group_id)
    assert record["active_operation_count"] == 9
    assert Map.keys(record["active_operations"]) |> Enum.sort() == operation_ids

    assert Enum.all?(
             concurrent(operation_ids, fn operation_id ->
               SalixWeb.ComputeProviders.Cloudflare.finish_operation(
                 group_id,
                 operation_id,
                 "completed",
                 %{ok: true}
               )
             end),
             &(&1 == :ok)
           )

    assert {:ok, record} = Compute.group_workload(group_id)
    assert record["active_operation_count"] == 0
    assert record["active_operations"] == %{}
  end

  test "a committed drain rejects a later mutating begin after commit", %{group_id: group_id} do
    assert {:ok, snapshot} = Compute.group_workload(group_id)

    draining =
      snapshot
      |> Map.delete(:etag)
      |> Map.put("rollout_state", "draining")
      |> Map.put("worker_release_id", "release-draining")

    assert {:ok, %{"rollout_state" => "draining"}, _previous} =
             Compute.update_group_workload(group_id, fn _current -> draining end)

    assert {:error,
            {:vm_rolling_update,
             %{"rollout_id" => "release-draining", "active_operation_count" => 0}}} =
             SalixWeb.ComputeProviders.Cloudflare.begin_operation(group_id, "write",
               operation_id: "after-drain",
               mutating?: true
             )

    assert {:ok, %{"active_operation_count" => 0, "active_operations" => %{}}} =
             Compute.group_workload(group_id)
  end

  test "begin waits for the durable transaction and survives caller exit", %{
    group_id: group,
    record: record
  } do
    parent = SystemsRuntime.Proc.self()

    holder =
      SystemsRuntime.Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM compute_workloads WHERE id = $1 FOR UPDATE", [
            record["workload_id"]
          ])

          SystemsRuntime.Proc.send(parent, :locked)

          SystemsRuntime.Proc.receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :locked

    caller =
      SystemsRuntime.Task.async(fn ->
        result =
          SalixWeb.ComputeProviders.Cloudflare.begin_operation(group, "read",
            operation_id: "durable",
            mutating?: false
          )

        SystemsRuntime.Proc.send(parent, {:began, result})
        result
      end)

    refute_receive {:began, _}, 50
    SystemsRuntime.Proc.send(holder.pid, :commit)
    assert {:ok, :ok} = SystemsRuntime.Task.await(holder, :infinity)
    assert {:ok, "durable"} = SystemsRuntime.Task.await(caller, :infinity)
    assert {:ok, stored} = Compute.group_workload(group)
    assert Map.has_key?(stored["active_operations"], "durable")

    assert {:ok, "durable"} =
             SalixWeb.ComputeProviders.Cloudflare.begin_operation(group, "read",
               operation_id: "durable",
               mutating?: false
             )

    assert {:ok, %{"active_operation_count" => 1}} = Compute.group_workload(group)
  end

  defp concurrent(count, fun) when is_integer(count),
    do: concurrent(Enum.to_list(1..count), fun)

  defp concurrent(items, fun) do
    parent = SystemsRuntime.Proc.self()

    tasks =
      Enum.map(items, fn item ->
        SystemsRuntime.Task.async(fn ->
          SystemsRuntime.Proc.send(parent, {:ready, SystemsRuntime.Proc.self()})

          SystemsRuntime.Proc.receive do
            :go -> fun.(item)
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:ready, pid}
        pid
      end)

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &SystemsRuntime.Task.await(&1, :infinity))
  end

  defp ready_record(tenant_id, group_id) do
    %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "schema_version" => 1,
      "provider" => "cloudflare",
      "provider_resource_name" => "cloud-vm-#{group_id}",
      "provider_resource_id" => "sandbox-#{group_id}",
      "env_id" => "env-#{group_id}",
      "device_id" => "device-#{group_id}",
      "connector_id" => "connector-#{group_id}",
      "alias" => "cloud-vm",
      "status" => "ready",
      "rollout_state" => "ready",
      "ready_at" => SystemsClock.system_time(:millisecond),
      "active_operation_count" => 0,
      "active_operations" => %{}
    }
  end
end
