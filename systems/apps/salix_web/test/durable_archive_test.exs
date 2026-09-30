defmodule SalixWeb.CloudVM.DurableArchiveTest do
  use ExUnit.Case, async: false

  alias SalixStore.S3
  alias SalixStore.Compute
  alias SalixWeb.CloudVM.{ArchiveGC, DurableArchive}
  alias SalixWeb.MockCloudflareGateway
  alias SalixEnv.VM.Providers.Cloudflare.Client

  setup do
    old_backend = Application.get_env(:salix_store, :s3_backend)
    old_r2 = Application.get_env(:salix_web, :cloud_vm_archive_r2)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(:salix_web, :cloud_vm_archive_r2, %{
      "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      "bucket" => "test-archive",
      "access_key_id" => "testaccess",
      "secret_access_key" => "testsecret"
    })

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      if old_backend,
        do: Application.put_env(:salix_store, :s3_backend, old_backend),
        else: Application.delete_env(:salix_store, :s3_backend)

      if old_r2,
        do: Application.put_env(:salix_web, :cloud_vm_archive_r2, old_r2),
        else: Application.delete_env(:salix_web, :cloud_vm_archive_r2)
    end)

    :ok
  end

  test "restore refuses a missing second chunk before reporting completion" do
    group_id = "group-owned"
    operation = "archive-owned"
    first = :binary.copy(<<1>>, 4 * 1024 * 1024)
    second = <<2, 3, 4>>

    archive = %{
      "type" => "connector_tar_gz_chunks",
      "storage" => "salix_s3",
      "operation" => operation,
      "byte_size" => byte_size(first) + byte_size(second),
      "chunk_size" => byte_size(first),
      "chunk_count" => 2,
      "sessions" => 1
    }

    assert {:ok, _} = S3.put(DurableArchive.chunk_key(group_id, operation, 0), first)
    assert {:ok, _} = S3.put(DurableArchive.chunk_key(group_id, operation, 1), second)

    assert :ok =
             DurableArchive.read_chunks(archive, group_id, fn offset, data ->
               assert {offset, byte_size(data)} in [{0, byte_size(first)}, {byte_size(first), 3}]
               :ok
             end)

    assert :ok = S3.delete(DurableArchive.chunk_key(group_id, operation, 1))

    assert {:error, :not_found} =
             DurableArchive.read_chunks(archive, group_id, fn _, _ -> :ok end)
  end

  test "GC deletes only a retired generation and keeps the current archive after retirement" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "gc-sandbox",
               "status" => "archived",
               "archive" => %{"type" => "connector_tar_gz_chunks", "operation" => "current"},
               "archive_gc_operations" => ["retired"]
             })

    old_key = DurableArchive.chunk_key(group, "retired", 0)
    current_key = DurableArchive.chunk_key(group, "current", 0)

    for index <- 0..51 do
      assert {:ok, _} = S3.put(DurableArchive.chunk_key(group, "retired", index), "old")
    end

    assert {:ok, _} = S3.put(current_key, "current")

    :ok = SalixStore.S3.Fake.set_fault({:ambiguous_after, :delete, old_key})
    assert {:error, {:ambiguous, :injected}} = ArchiveGC.run_once()
    assert {:ok, %{"archive_gc_operations" => ["retired"]}} = Compute.group_workload(group)
    assert {:ok, :partial} = ArchiveGC.run_once()
    assert :ok = ArchiveGC.run_once()
    assert {:error, :not_found} = S3.get(old_key)
    assert {:ok, %{body: "current"}} = S3.get(current_key)
    assert {:ok, %{"archive_gc_operations" => []}} = Compute.group_workload(group)

    assert :ok = Compute.retire_group_workload(group)
    assert :idle = ArchiveGC.run_once()
    assert {:ok, %{body: "current"}} = S3.get(current_key)
  end

  test "a lost finish response resumes from the restored receipt without replaying parts" do
    gateway = start_supervised!(MockCloudflareGateway)
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = "group-owned"
    operation = "restore-once"
    data = "archive-body"

    archive = %{
      "type" => "connector_tar_gz_chunks",
      "storage" => "salix_s3",
      "operation" => operation,
      "byte_size" => byte_size(data),
      "chunk_size" => 4 * 1024 * 1024,
      "chunk_count" => 1,
      "sessions" => 0
    }

    assert {:ok, _} = S3.put(DurableArchive.chunk_key(group, operation, 0), data)
    assert :ok = DurableArchive.restore(client, "sandbox-owned", group, archive)
    assert :ok = DurableArchive.restore(client, "sandbox-owned", group, archive)

    actions =
      MockCloudflareGateway.calls(gateway)
      |> Enum.filter(&(&1.op == :migration_import))
      |> Enum.map(& &1.body["action"])

    assert actions == ["status", "part", "finish", "status"]
  end

  test "a partially restored target is replaced before retrying the retained archive" do
    gateway = start_supervised!(MockCloudflareGateway)
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = "group-owned"
    operation = "restore-after-partial"
    data = "archive-body"

    archive = %{
      "type" => "connector_tar_gz_chunks",
      "storage" => "salix_s3",
      "operation" => operation,
      "byte_size" => byte_size(data),
      "chunk_size" => 4 * 1024 * 1024,
      "chunk_count" => 1,
      "sessions" => 0
    }

    assert {:ok, _} = S3.put(DurableArchive.chunk_key(group, operation, 0), data)
    :ok = MockCloudflareGateway.set_import(gateway, "sandbox-owned", %{"phase" => "restoring"})

    assert {:ok, %{attachment: nil}} =
             SalixWeb.ComputeProviders.Cloudflare.ensure(
               %{"provider_resource_id" => "sandbox-owned", "group_id" => group},
               %{},
               client: client,
               archive: archive,
               attach: false
             )

    ops = MockCloudflareGateway.calls(gateway) |> Enum.map(& &1.op)

    assert ops == [
             :ensure,
             :migration_import,
             :destroy,
             :ensure,
             :migration_import,
             :migration_import,
             :migration_import,
             :readyz
           ]
  end

  test "Connector export uses signed R2 parts without relaying bytes through Salix" do
    gateway = start_supervised!(MockCloudflareGateway)
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = "group-owned"
    operation = "round-trip"
    data = :crypto.strong_rand_bytes(4 * 1024 * 1024 + 17)
    :ok = MockCloudflareGateway.set_export(gateway, "source", operation, data, 1)

    assert {:ok, %{"storage" => "r2", "chunk_count" => 2, "byte_size" => bytes, "sessions" => 1}} =
             DurableArchive.export(client, "source", group, operation)

    assert bytes == byte_size(data)
    assert {:error, :not_found} = S3.get(DurableArchive.chunk_key(group, operation, 0))

    direct_parts =
      MockCloudflareGateway.calls(gateway)
      |> Enum.filter(&(&1.op == :archive_export && &1.body["method"] == "PUT"))
      |> Enum.sort_by(& &1.body["offset"])
      |> Enum.map(& &1.body["offset"])

    assert direct_parts == [0, 4 * 1024 * 1024]
  end

  test "zstd archive streams directly to R2 and restores with one Connector request" do
    r2 = Application.fetch_env!(:salix_web, :cloud_vm_archive_r2)
    Application.put_env(:salix_web, :cloud_vm_archive_r2, Map.put(r2, "zstd_enabled", true))
    gateway = start_supervised!(MockCloudflareGateway)
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = diagnostics_group()
    operation = "zstd-round-trip"
    data = :crypto.strong_rand_bytes(4 * 1024 * 1024 + 17)
    :ok = MockCloudflareGateway.set_export(gateway, "source", operation, data, 0)

    assert {:ok, %{"type" => "connector_tar_zst_chunks", "storage" => "r2"} = archive} =
             DurableArchive.export(client, "source", group, operation)

    assert DurableArchive.valid_manifest?(archive)
    assert :ok = DurableArchive.restore(client, "target", group, archive)
    await_diagnostics(group, operation, ["export", "restore"])

    assert {:ok, %{"observation" => true, "diagnostics" => summaries}} =
             SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group, operation)

    assert Enum.all?(summaries, &is_integer(&1["salix_duration_ms"]))

    calls = MockCloudflareGateway.calls(gateway)

    assert Enum.any?(calls, fn call ->
             call.op == :archive_export and call.body["method"] == "POST" and
               call.body["format"] == "tar_zst"
           end)

    refute Enum.any?(calls, fn call ->
             call.op == :archive_export and call.body["method"] == "PUT"
           end)

    assert Enum.map(Enum.filter(calls, &(&1.op == :migration_import)), & &1.body["action"]) ==
             ["status", "stream"]

    assert {:error, :transfer_callback_failed} =
             DurableArchive.restore(client, "target-with-callback", group, archive,
               on_transfer_complete: fn -> {:error, :transfer_callback_failed} end
             )
  end

  test "old Connector falls back only on unsupported direct transfer" do
    gateway = start_supervised!({MockCloudflareGateway, fail_ops: [:archive_direct]})
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = "group-owned"
    operation = "old-connector"
    data = "retained legacy archive"
    :ok = MockCloudflareGateway.set_export(gateway, "source", operation, data)

    assert {:ok, %{"storage" => "salix_s3", "byte_size" => bytes}} =
             DurableArchive.export(client, "source", group, operation)

    assert bytes == byte_size(data)
    assert {:ok, %{body: ^data}} = S3.get(DurableArchive.chunk_key(group, operation, 0))

    assert Enum.any?(MockCloudflareGateway.calls(gateway), fn call ->
             call.op == :archive_export and call.body["method"] == "PUT"
           end)
  end

  test "cancelled export stops before writing a Salix archive chunk" do
    gateway = start_supervised!(MockCloudflareGateway)
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = diagnostics_group()
    operation = "cancel-owned"
    :ok = MockCloudflareGateway.set_export(gateway, "source", operation, "user data")

    assert {:error, :archive_cancelled} =
             DurableArchive.export(client, "source", group, operation, fn _ ->
               {:error, :archive_cancel_requested}
             end)

    assert Enum.any?(MockCloudflareGateway.calls(gateway), fn call ->
             call.op == :archive_export and call.body["method"] == "DELETE" and
               call.body["operation"] == operation
           end)

    assert {:error, :not_found} = S3.get(DurableArchive.chunk_key(group, operation, 0))
    await_diagnostics(group, operation, ["export"])

    assert {:ok, %{"observation" => true, "diagnostics" => [summary]}} =
             SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group, operation)

    assert summary["outcome"] == "cancelled"
  end

  test "diagnostic saturation cannot block archive, restore or Connector control" do
    r2 = Application.fetch_env!(:salix_web, :cloud_vm_archive_r2)
    Application.put_env(:salix_web, :cloud_vm_archive_r2, Map.put(r2, "zstd_enabled", true))
    pool = SalixWeb.CloudVM.ArchiveDiagnosticsSupervisor
    await_diagnostics_idle(pool)

    blockers =
      for _ <- 1..4 do
        {:ok, pid} =
          Task.Supervisor.start_child(pool, fn ->
            receive do
              :release -> :ok
            end
          end)

        on_exit(fn -> Task.Supervisor.terminate_child(pool, pid) end)
        pid
      end

    assert length(blockers) == 4
    assert {:error, :max_children} = Task.Supervisor.start_child(pool, fn -> :ok end)
    caller = self()

    assert {:ok, _} =
             Task.Supervisor.start_child(SalixWeb.ConnectorControlTaskSupervisor, fn ->
               send(caller, :control_available)
             end)

    assert_receive :control_available

    gateway = start_supervised!(MockCloudflareGateway)
    client = Client.new(base_url: MockCloudflareGateway.base_url(gateway), secret: "test-secret")
    group = diagnostics_group()
    operation = "observation-saturated"
    :ok = MockCloudflareGateway.set_export(gateway, "source", operation, "owned-data", 0)
    assert {:ok, archive} = DurableArchive.export(client, "source", group, operation)
    assert :ok = DurableArchive.restore(client, "target", group, archive)
    assert {:ok, []} = SalixWeb.CloudVM.ArchiveDiagnostics.list(group)
  end

  test "archive status reports the exact operation and commit cannot be cancelled" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    operation = "archive-owned"

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sandbox-owned",
               "status" => "archiving",
               "archive_reason" => "idle_committing",
               "archive_operation_id" => operation,
               "archive_progress" => %{
                 "phase" => "transferring",
                 "uploaded_bytes" => 4_194_304,
                 "total_bytes" => 8_388_608
               }
             })

    assert {:ok, %{"operation" => ^operation, "progress" => %{"uploaded_bytes" => 4_194_304}}} =
             SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group, operation)

    assert {:error, :archive_commit_recovery_required} =
             SalixWeb.ComputeProviders.Cloudflare.cancel_archive_operation(group, operation)

    assert {:ok, rec} = Compute.group_workload(group)
    assert rec["status"] == "archiving"
    assert rec["archive_cancel_requested"] == nil
  end

  defp await_diagnostics_idle(pool, attempts \\ 200)

  defp await_diagnostics_idle(pool, attempts) when attempts > 0 do
    if Task.Supervisor.children(pool) == [] do
      :ok
    else
      Process.sleep(10)
      await_diagnostics_idle(pool, attempts - 1)
    end
  end

  defp await_diagnostics_idle(_, 0), do: flunk("previous diagnostic tasks did not settle")

  defp diagnostics_group do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    {:ok, _, :created} =
      Compute.ensure_group_workload(%{
        "tenant_id" => tenant,
        "group_id" => group,
        "provider" => "cloudflare",
        "status" => "ready",
        "provider_resource_name" => "diagnostics-only"
      })

    group
  end

  defp await_diagnostics(group, operation, directions, attempts \\ 100)

  defp await_diagnostics(group, operation, directions, attempts) when attempts > 0 do
    {:ok, records} = SalixWeb.CloudVM.ArchiveDiagnostics.list(group)

    if Enum.all?(directions, fn direction ->
         Enum.any?(
           records,
           &(&1["operation"] == operation and &1["direction"] == direction and
               is_integer(&1["salix_duration_ms"]))
         )
       end),
       do: :ok,
       else:
         (
           Process.sleep(10)
           await_diagnostics(group, operation, directions, attempts - 1)
         )
  end

  defp await_diagnostics(_, _, _, 0), do: flunk("archive diagnostics were not stored")
end
