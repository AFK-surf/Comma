defmodule SalixWeb.CloudVMActivityTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Compute, Ids, Repo}

  setup do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    assert {:ok, record, :created} =
             Compute.ensure_group_workload(ready_record(tenant_id, group_id))

    {:ok, group_id: group_id, record: record}
  end

  test "archive observations survive operation retirement and retain only bounded summaries", %{
    group_id: group
  } do
    alias SalixWeb.CloudVM.ArchiveDiagnostics

    for i <- 1..10 do
      :ok =
        ArchiveDiagnostics.observe(group, "archive-#{i}", "export", %{
          "connector_outcome" => "exported",
          "pack_ms" => i,
          "total_ms" => i * 2,
          "source_url" => "secret-url",
          "command" => "private command"
        })

      await_observation(fn ->
        {:ok, records} = ArchiveDiagnostics.list(group)
        Enum.any?(records, &(&1["operation"] == "archive-#{i}"))
      end)
    end

    assert {:ok, records} = ArchiveDiagnostics.list(group)
    assert length(records) == 8

    assert Enum.all?(
             records,
             &(not Map.has_key?(&1, "source_url") and not Map.has_key?(&1, "command"))
           )

    assert {:error, :archive_operation_not_found} =
             SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group, "archive-1")

    assert {:ok, %{"observation" => true, "diagnostics" => [summary]}} =
             SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group, "archive-10")

    assert summary["pack_ms"] == 10

    assert {:error, _} =
             SalixWeb.ComputeProviders.Cloudflare.cancel_archive_operation(group, "archive-10")

    :ok =
      ArchiveDiagnostics.observe(group, "archive-10", "export", %{
        "outcome" => "ok",
        "salix_duration_ms" => 100,
        "pack_ms" => -5
      })

    await_observation(fn ->
      {:ok, rs} = ArchiveDiagnostics.list(group)
      Enum.any?(rs, &(&1["operation"] == "archive-10" and &1["salix_duration_ms"] == 100))
    end)

    assert {:ok, %{"observation" => true, "diagnostics" => [summary]}} =
             SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group, "archive-10")

    assert summary["pack_ms"] == 10
    assert summary["connector_outcome"] == "exported"
    assert summary["outcome"] == "ok"
    assert {:ok, record} = Compute.group_workload(group)
    assert record["status"] == "ready"
    assert record["active_operation_count"] == 0
  end

  defp await_observation(check, attempts \\ 100)

  defp await_observation(check, attempts) when attempts > 0 do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_observation(check, attempts - 1)
        )
  end

  defp await_observation(_, 0), do: flunk("archive observation was not stored")

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
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM compute_workloads WHERE id = $1 FOR UPDATE", [
            record["workload_id"]
          ])

          send(parent, :locked)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :locked, 1_000

    caller =
      Task.async(fn ->
        result =
          SalixWeb.ComputeProviders.Cloudflare.begin_operation(group, "read",
            operation_id: "durable",
            mutating?: false
          )

        send(parent, {:began, result})
        result
      end)

    refute_receive {:began, _}, 50
    send(holder.pid, :commit)
    assert {:ok, :ok} = Task.await(holder)
    assert {:ok, "durable"} = Task.await(caller)
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
    parent = self()

    tasks =
      Enum.map(items, fn item ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.(item)
          end
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:ready, pid}, 1_000
        pid
      end)

    Enum.each(pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
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
      "ready_at" => System.system_time(:millisecond),
      "active_operation_count" => 0,
      "active_operations" => %{}
    }
  end
end
