defmodule SalixStore.ComputeMigrationTest do
  use ExUnit.Case, async: false
  alias SalixStore.{Compute, ComputeMigration, Ids, Keys, Repo, S3}
  @marker "group_compute_authority_v1"

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [@marker])

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous)

      Repo.query!(
        "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, now(), '{\"phase\":\"complete\"}') ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence",
        [@marker]
      )
    end)

    :ok
  end

  test "bounded handoff preserves identity, archive and accepted activity, then admits new writes" do
    tenant = Ids.new_tenant_id()
    facts = Enum.map(1..21, fn index -> source(tenant, index) end)

    for fact <- facts,
        do: assert({:ok, _} = S3.put(Keys.ctl_vm(fact["group_id"]), Jason.encode!(fact)))

    assert {:error, :group_compute_handoff_pending} = Compute.ensure_group_workload(hd(facts))
    assert :unmanaged = Compute.group_provider_ownership(tenant, hd(facts)["group_id"])

    assert {:error, :group_workload_unavailable} =
             Compute.group_provider_ownership(Ids.new_tenant_id(), hd(facts)["group_id"])

    assert :ok =
             Compute.group_provider_mutation_admission(
               tenant,
               hd(facts)["group_id"],
               hd(facts)["device_id"]
             )

    assert {:ok, %{items: items, next_cursor: next}} = ComputeMigration.inspect_page()
    assert length(items) == 20
    assert is_binary(next)
    assert Enum.all?(items, &(&1.result == :ready))
    assert {:ok, %{"phase" => "blocked"}} = ComputeMigration.state()

    assert {:ok, %{processed: 20, next_cursor: cursor}} = ComputeMigration.transfer_page()
    assert is_binary(cursor)

    assert {:error, :group_workload_unavailable} =
             Compute.group_provider_ownership(tenant, hd(facts)["group_id"])

    assert {:error, :group_workload_unavailable} =
             Compute.group_provider_mutation_admission(
               tenant,
               hd(facts)["group_id"],
               hd(facts)["device_id"]
             )

    assert {:error, :group_compute_handoff_pending} =
             Compute.page_group_workloads(tenant_id: tenant)

    assert {:error, :group_compute_handoff_pending} =
             Compute.group_workload(hd(facts)["group_id"])

    assert {:error, :stale_group_compute_cursor} = ComputeMigration.transfer_page("not-the-page")
    assert {:ok, %{processed: 1, next_cursor: nil}} = ComputeMigration.transfer_page(cursor)
    assert :ok = ComputeMigration.ensure_open()

    assert {:ok, %{records: records, next_cursor: nil}} =
             Compute.page_group_workloads(tenant_id: tenant)

    assert length(records) == 21

    for fact <- facts do
      assert {:ok, imported} = Compute.group_workload(fact["group_id"])
      assert {:managed, ^imported} = Compute.group_provider_ownership(tenant, fact["group_id"])

      assert Map.take(imported, Map.keys(fact) -- ["schema_version"]) ==
               Map.delete(fact, "schema_version")

      assert {:ok, %{body: body}} = S3.get(Keys.ctl_vm(fact["group_id"]))
      assert Jason.decode!(body) == fact
    end

    first = hd(facts)
    assert {:ok, before} = Compute.group_workload(first["group_id"])

    assert {:ok, _, _} =
             Compute.update_group_workload(
               first["group_id"],
               &Map.put(&1, "last_error", "new-writer")
             )

    assert {:ok, %{processed: 0, next_cursor: nil}} = ComputeMigration.transfer_page(cursor)
    assert {:ok, after_retry} = Compute.group_workload(first["group_id"])
    assert after_retry["workload_id"] == before["workload_id"]
    assert after_retry["last_error"] == "new-writer"
  end

  test "handoff preserves an existing Cloudflare allocation and its owned facts without provider mutation" do
    record =
      source(Ids.new_tenant_id(), 1)
      |> Map.put("provider", "cloudflare")
      |> Map.put("status", "ready")

    key = Keys.ctl_vm(record["group_id"])
    assert {:ok, _} = S3.put(key, Jason.encode!(record))
    assert {:ok, %{processed: 1, next_cursor: nil}} = ComputeMigration.transfer_page()
    assert :ok = ComputeMigration.ensure_open()
    assert {:ok, imported} = Compute.group_workload(record["group_id"])

    assert Map.take(imported, Map.keys(record) -- ["schema_version", "active_operation_count"]) ==
             Map.drop(record, ["schema_version", "active_operation_count"])

    assert {:ok, %{body: body}} = S3.get(key)
    assert Jason.decode!(body) == record
  end

  test "unknown durable fields and accepted transitions fail closed without partial page admission" do
    record = source(Ids.new_tenant_id(), 1)
    key = Keys.ctl_vm(record["group_id"])
    invalid = Map.put(record, "owned_files", %{"path" => "must-survive"})
    assert {:ok, _} = S3.put(key, Jason.encode!(invalid))
    assert {:ok, %{items: [%{result: :blocked}]}} = ComputeMigration.inspect_page()

    assert {:error,
            {:group_compute_import_failed, ^key, {:unmapped_group_fields, ["owned_files"]}}} =
             ComputeMigration.transfer_page()

    assert {:error, :group_compute_handoff_pending} = ComputeMigration.ensure_open()
    assert {:ok, %{body: body}} = S3.get(key)
    assert Jason.decode!(body) == invalid

    assert {:error, :accepted_transition_requires_resolution} =
             ComputeMigration.normalize(
               Map.put(record, "active_operation", %{"kind" => "archive"})
             )

    assert {:error, :legacy_lifecycle_conversion_required} =
             ComputeMigration.normalize(Map.put(record, "coordinator_version", 2))

    assert {:ok, _} = S3.put(key, Jason.encode!(record))
    assert {:ok, %{processed: 1, next_cursor: nil}} = ComputeMigration.transfer_page()
  end

  test "v2 absence and generation remain explicit without recreating or replaying a completed teardown" do
    original = source(Ids.new_tenant_id(), 1)

    legacy =
      Map.merge(original, %{
        "coordinator_version" => 2,
        "revision" => 9,
        "status" => "absent",
        "lifecycle" => %{
          "availability" => "unavailable",
          "residency" => "absent",
          "generation" => 2,
          "provider" => "cloudflare",
          "provider_resource_id" => original["provider_resource_id"],
          "workspace_dir" => "/workspace"
        },
        "last_completed_operation" => %{
          "phase" => "completed",
          "kind" => "teardown",
          "disposition" => "destroy_source"
        }
      })

    assert {:ok, _} = S3.put(Keys.ctl_vm(legacy["group_id"]), Jason.encode!(legacy))
    assert {:ok, %{processed: 1, next_cursor: nil}} = ComputeMigration.transfer_page()
    assert {:ok, imported} = Compute.group_workload(legacy["group_id"])
    assert imported["status"] == "absent"
    assert imported["workspace_dir"] == "/workspace"
    assert get_in(imported, ["provider_spec", "migration_provenance", "generation"]) == 2
    assert imported["archive"] == legacy["archive"]
    assert imported["active_operations"] == legacy["active_operations"]
  end

  defp source(tenant, index) do
    group = Ids.new_group_id(tenant)

    %{
      "schema_version" => 1,
      "tenant_id" => tenant,
      "group_id" => group,
      "provider" => "cloudflare",
      "provider_resource_id" => "resource-#{index}",
      "provider_resource_name" => "resource-#{index}",
      "status" => "archived",
      "created_at" => 100,
      "device_id" => "device-#{index}",
      "env_id" => "env-#{index}",
      "connector_id" => "connector-#{index}",
      "archive" => %{"type" => "connector_tar_gz", "ref" => "archive-#{index}"},
      "runtime_targets" => %{"codex" => %{"device_runtime_id" => "runtime-#{index}"}},
      "last_metered_at" => 90,
      "active_operations" => %{
        "exec-#{index}" => %{"state" => "unknown", "idempotency_class" => "non_idempotent"}
      },
      "active_operation_count" => 1
    }
  end
end
