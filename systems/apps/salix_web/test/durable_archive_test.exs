defmodule SalixWeb.CloudVM.DurableArchiveTest do
  use SystemsClock.Case, async: false

  alias SalixStore.S3
  alias SalixStore.Compute
  alias SalixWeb.CloudVM.{ArchiveGC, DurableArchive}

  setup do
    old_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    old_r2 = SystemsRuntime.get_env(:salix_web, :cloud_vm_archive_r2)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2, %{
      "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      "bucket" => "test-archive",
      "access_key_id" => "testaccess",
      "secret_access_key" => "testsecret"
    })

    # R2 itself is the store the Gateway mock's stations write their parts to.
    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2_req,
      plug: &SalixWeb.MockCloudflareGateway.r2/1
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :cloud_vm_archive_r2_req) end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      if old_backend,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, old_backend),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)

      if old_r2,
        do: SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2, old_r2),
        else: SystemsRuntime.delete_env(:salix_web, :cloud_vm_archive_r2)
    end)

    :ok
  end

  # A station as DurableArchive reaches it: each request goes to the test
  # process, which answers from `answers` (by method) and keeps the requests.
  defp station(answers) do
    test = SystemsRuntime.Proc.self()

    fn method, params, _timeout ->
      SystemsRuntime.Proc.send(test, {:station, method, params})

      case Map.fetch(answers, method) do
        {:ok, answer} when is_function(answer, 1) -> answer.(params)
        {:ok, answer} -> answer
        :error -> {:error, "unsupported"}
      end
    end
  end

  defp zstd_archive(operation, bytes) do
    %{
      "type" => "connector_tar_zst_chunks",
      "storage" => "r2",
      "scope" => "full",
      "operation" => operation,
      "byte_size" => bytes,
      "chunk_size" => 4 * 1024 * 1024,
      "chunk_count" => div(bytes + 4 * 1024 * 1024 - 1, 4 * 1024 * 1024),
      "sessions" => 0
    }
  end

  test "a missing chunk fails verification of an archive" do
    group_id = "group-owned"
    operation = "archive-owned"
    first = :binary.copy(<<1>>, 4 * 1024 * 1024)

    archive = %{
      "type" => "connector_tar_gz_chunks",
      "storage" => "salix_s3",
      "operation" => operation,
      "byte_size" => byte_size(first) + 3,
      "chunk_size" => byte_size(first),
      "chunk_count" => 2,
      "sessions" => 1
    }

    assert {:ok, _} = S3.put(DurableArchive.chunk_key(group_id, operation, 0), first)
    assert {:ok, _} = S3.put(DurableArchive.chunk_key(group_id, operation, 1), <<2, 3, 4>>)
    assert :ok = DurableArchive.check_chunks(archive, group_id)
    assert :ok = S3.delete(DurableArchive.chunk_key(group_id, operation, 1))
    assert {:error, :not_found} = DurableArchive.check_chunks(archive, group_id)
  end

  test "archive verification stops when its owning release budget expires" do
    archive = %{
      "type" => "connector_tar_gz_chunks",
      "storage" => "salix_s3",
      "operation" => "budget-owned",
      "byte_size" => 3,
      "chunk_size" => 4 * 1024 * 1024,
      "chunk_count" => 1,
      "sessions" => 0
    }

    assert {:ok, _} = S3.put(DurableArchive.chunk_key("group-owned", "budget-owned", 0), "abc")

    assert {:error, :image_release_drain_timeout} =
             DurableArchive.check_chunks(archive, "group-owned", fn ->
               {:error, :image_release_drain_timeout}
             end)

    assert :ok = DurableArchive.check_chunks(archive, "group-owned")
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

  test "export packs the station's root straight into signed R2 parts and records the archive" do
    group = "group-owned"
    operation = "round-trip"

    call =
      station(%{
        "archive_export" => {:ok, %{"operation" => operation, "phase" => "preparing"}},
        "archive_status" =>
          {:ok, %{"operation" => operation, "phase" => "exported", "bytes" => 5, "sessions" => 2}}
      })

    assert {:ok, archive} = DurableArchive.export(call, group, operation)

    assert archive == %{
             "type" => "connector_tar_zst_chunks",
             "storage" => "r2",
             "scope" => "full",
             "operation" => operation,
             "byte_size" => 5,
             "chunk_size" => 4 * 1024 * 1024,
             "chunk_count" => 1,
             "sessions" => 2
           }

    assert_received {:station, "archive_export",
                     %{"operation" => ^operation, "scope" => "full", "transfers" => transfers}}

    assert length(transfers) == 1024

    for %{"put_url" => put, "get_url" => get} <- transfers do
      assert URI.parse(put).host == URI.parse(get).host
      assert URI.parse(put).path == URI.parse(get).path
    end

    assert {:error, :not_found} = S3.get(DurableArchive.chunk_key(group, operation, 0))
  end

  test "a failed export is terminal" do
    call =
      station(%{
        "archive_export" => {:ok, %{"phase" => "preparing"}},
        "archive_status" => {:ok, %{"phase" => "failed"}}
      })

    assert {:error, :durable_archive_export_failed} =
             DurableArchive.export(call, "group-owned", "failed-export")
  end

  test "a cancelled export asks the station to stop and writes no archive" do
    group = "group-owned"
    operation = "cancel-owned"

    call =
      station(%{
        "archive_cancel" => {:ok, %{"operation" => operation, "phase" => "cancelling"}},
        "archive_status" => {:ok, %{"operation" => operation, "phase" => "cancelled"}}
      })

    assert {:error, :archive_cancelled} =
             DurableArchive.export(call, group, operation, fn _ ->
               {:error, :archive_cancel_requested}
             end)

    assert_received {:station, "archive_cancel", %{"operation" => ^operation}}
    refute_received {:station, "archive_export", _}
  end

  # What a Container's start reads: the instruction, then the manifest its URL names.
  defp decode_restore(value), do: value |> Base.decode64!() |> Jason.decode!()

  defp manifest(group, operation) do
    {:ok, %{body: body}} = S3.get(DurableArchive.manifest_key(group, operation))
    Jason.decode!(body)
  end

  defp assert_signed_for_an_hour(url, path_end) do
    uri = URI.parse(url)
    assert uri.scheme == "https"
    assert String.ends_with?(uri.host, ".r2.cloudflarestorage.com")
    assert String.ends_with?(uri.path, path_end)
    assert %{"X-Amz-Expires" => "3600", "X-Amz-Signature" => _} = URI.decode_query(uri.query)
  end

  test "a start's restore instruction names the archive and one signed URL, of the manifest that lists its parts" do
    archive = zstd_archive("restore-owned", 5 * 1024 * 1024)

    assert {:ok, value} = DurableArchive.restore_instruction("group-owned", archive)

    assert %{"operation" => "restore-owned", "bytes" => 5_242_880, "manifest_url" => url} =
             instruction = decode_restore(value)

    assert map_size(instruction) == 3
    assert_signed_for_an_hour(url, "/group-owned/restore-owned/restore-manifest")

    # The manifest is an object next to the parts: it goes with them when the archive does.
    assert String.starts_with?(
             DurableArchive.manifest_key("group-owned", "restore-owned"),
             DurableArchive.chunk_prefix("group-owned", "restore-owned")
           )

    assert %{
             "operation" => "restore-owned",
             "bytes" => 5_242_880,
             "parts" => [
               %{"bytes" => 4_194_304, "get_url" => first},
               %{"bytes" => 1_048_576, "get_url" => second}
             ]
           } = manifest("group-owned", "restore-owned")

    assert_signed_for_an_hour(first, "/group-owned/restore-owned/0")
    assert_signed_for_an_hour(second, "/group-owned/restore-owned/1")
  end

  test "the largest archive's start value is 696 bytes, as the smallest's: its 1024 parts are in the manifest" do
    group = "grp1_2096157733236506624_2096157733236506625"
    operation = "archive-" <> String.duplicate("f", 16)
    largest = zstd_archive(operation, 4 * 1024 * 1024 * 1024)
    assert largest["chunk_count"] == 1024

    assert {:ok, value} = DurableArchive.restore_instruction(group, largest)
    assert length(manifest(group, operation)["parts"]) == 1024
    # A real Group id and operation, and R2's signed URL: the Gateway and the
    # station read at most 8 KiB.
    assert byte_size(value) == 696

    assert {:ok, smallest} = DurableArchive.restore_instruction(group, zstd_archive(operation, 1))
    assert_in_delta byte_size(smallest), byte_size(value), 16
  end

  test "an archive whose manifest cannot be written has no restore instruction" do
    SystemsRuntime.put_env(:salix_web, :cloud_vm_archive_r2_req,
      plug: fn conn -> Plug.Conn.send_resp(conn, 503, "") end
    )

    assert {:error, :r2_archive_unavailable} =
             DurableArchive.restore_instruction("group-owned", zstd_archive("restore-owned", 3))
  end

  test "an archive the retired connector wrote has no restore instruction" do
    for archive <- [
          Map.put(zstd_archive("gzip-owned", 3), "type", "connector_tar_gz_chunks"),
          Map.put(zstd_archive("s3-owned", 3), "storage", "salix_s3")
        ] do
      refute DurableArchive.restorable?(archive)

      assert {:error, :durable_archive_format_retired} =
               DurableArchive.restore_instruction("group-owned", archive)
    end
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
end
