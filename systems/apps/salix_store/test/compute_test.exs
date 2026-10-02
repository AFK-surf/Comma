defmodule SalixStore.ComputeTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixStore.{
    AgentVMM,
    CloudflareProfileHandoff,
    Compute,
    Keys,
    ReleaseObligationBackfill,
    Repo,
    RuntimeBundleCatalog,
    S3
  }

  @runtime_bundle_root Path.expand("fixtures/runtime-bundle", __DIR__)

  setup do
    Repo.query!(
      "TRUNCATE external_worker_operations, external_worker_bindings, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    :ok
  end

  test "a sealed carrier settles managed calls but retains legacy and other locations" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sandbox-owner",
               "provider_resource_name" => "sandbox-owner",
               "provider_spec" => %{"profile_key" => "cf-standard-2"},
               "status" => "ready",
               "created_at" => 1_000
             })

    target = "cf-standard-2:sandbox-owner"
    assert {:ok, opened} = Compute.prepare_cloudflare_control(group, target, :open)

    assert {:ok, "legacy"} =
             Compute.begin_cloudflare_gateway_attempt(group, "legacy", :normal, target)

    assert {:ok, "managed"} =
             Compute.begin_cloudflare_gateway_attempt(group, "managed", :normal, target, %{
               "action" => "import"
             })

    assert {:error, :gateway_target_changed} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "stale-managed",
               :normal,
               "cf-standard-1:other",
               %{"action" => "import"}
             )

    assert {:ok, "other"} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "other",
               :normal,
               "cf-standard-1:other"
             )

    assert {:ok, ^opened} = Compute.prepare_cloudflare_control(group, target, :open)

    assert {:ok, _, _} =
             Compute.update_group_workload(group, fn record ->
               record
               |> Map.put("status", "archiving")
               |> Map.put("archive_operation_id", "archive-owner")
             end)

    assert {:ok, sealed} = Compute.prepare_cloudflare_control(group, target, :seal)
    assert sealed["revision"] > opened["revision"]

    observation = %{
      "control" => Map.put(sealed, "pending", %{"claim_id" => "managed"}),
      "managed_commands_settled" => true
    }

    assert {:error, :cloudflare_control_unsettled} =
             Compute.settle_cloudflare_control(group, target, observation)

    assert {:ok, %{"active_operation_count" => 3}} = Compute.group_workload(group)

    assert :ok =
             Compute.settle_cloudflare_control(
               group,
               target,
               put_in(observation, ["control", "pending"], nil)
             )

    assert {:ok, remaining} = Compute.group_workload(group)
    assert Map.keys(remaining["active_operations"]) |> Enum.sort() == ["legacy", "other"]

    assert {:error, :cloudflare_control_sealed} =
             Compute.prepare_cloudflare_control(group, target, :open)
  end

  test "terminal settlement preserves another claim and rejects mismatched command evidence" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    target = "cf-standard-2:terminal-owner"

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "terminal-owner",
               "provider_resource_name" => "terminal-owner",
               "provider_spec" => %{"profile_key" => "cf-standard-2"},
               "status" => "ready"
             })

    {:ok, control} = Compute.prepare_cloudflare_control(group, target, :open)

    for claim <- ["completed", "still-active"] do
      assert {:ok, ^claim} =
               Compute.begin_cloudflare_gateway_attempt(group, claim, :normal, target, %{
                 "action" => "import"
               })
    end

    terminal =
      control
      |> Map.put("claim_id", "completed")
      |> Map.put("action", "import")
      |> Map.put("outcome", "completed")

    mismatched = Map.put(terminal, "revision", control["revision"] + 1)

    assert :ok =
             Compute.settle_cloudflare_terminal(group, target, %{
               "control" => Map.put(control, "last_terminal", mismatched)
             })

    assert {:ok, %{"active_operation_count" => 2}} = Compute.group_workload(group)

    assert :ok =
             Compute.settle_cloudflare_terminal(group, target, %{
               "control" => Map.put(control, "last_terminal", terminal)
             })

    assert {:ok, record} = Compute.group_workload(group)
    assert Map.keys(record["active_operations"]) == ["still-active"]
  end

  test "post-rollout profile handoff converts late legacy rows and absent locations in pages" do
    migration_file =
      Application.app_dir(
        :salix_store,
        "priv/repo/migrations/20260929000100_backfill_cloudflare_group_profile.exs"
      )

    Code.require_file(migration_file)
    migration = SalixStore.Repo.Migrations.BackfillCloudflareGroupProfile
    tenant = SalixStore.Ids.new_tenant_id()
    initial_group = SalixStore.Ids.new_group_id(tenant)
    initial_resource = SalixStore.RuntimeIds.cloud_vm_provider_resource_name(initial_group)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => initial_group,
               "provider" => "cloudflare",
               "provider_resource_id" => initial_resource,
               "provider_resource_name" => initial_resource,
               "provider_spec" => %{},
               "status" => "ready",
               "created_at" => 1_000
             })

    Repo.transaction(fn ->
      Repo.query!(migration.backfill_sql())
      Repo.query!(migration.backfill_gateway_claims_sql())
    end)

    assert {:ok, initial} = Compute.group_workload(initial_group)
    assert get_in(initial, ["provider_spec", "profile_key"]) == "cf-standard-2"

    # A discard-source Group cutover names its target resource with 32 hex digits.
    # It lived in the only Sandbox namespace of its time, so it converts too.
    cutover_group = SalixStore.Ids.new_group_id(tenant)
    cutover_resource = "salix-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => cutover_group,
               "provider" => "cloudflare",
               "provider_resource_id" => cutover_resource,
               "provider_resource_name" => cutover_resource,
               "provider_spec" => %{},
               "status" => "archived",
               "created_at" => 1_000
             })

    # A location Salix did not name stays unresolved for operator repair.
    foreign_group = SalixStore.Ids.new_group_id(tenant)
    foreign_resource = "sandbox-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => foreign_group,
               "provider" => "cloudflare",
               "provider_resource_id" => foreign_resource,
               "provider_resource_name" => foreign_resource,
               "provider_spec" => %{},
               "status" => "ready",
               "created_at" => 1_000
             })

    late_groups =
      Enum.map(1..101, fn index ->
        group = SalixStore.Ids.new_group_id(tenant)
        resource = SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group)

        assert {:ok, _, :created} =
                 Compute.ensure_group_workload(%{
                   "tenant_id" => tenant,
                   "group_id" => group,
                   "provider" => "cloudflare",
                   "provider_resource_id" => resource,
                   "provider_resource_name" => resource,
                   "provider_spec" => %{},
                   "status" => if(index == 101, do: "absent", else: "ready"),
                   "created_at" => 1_000
                 })

        {group, resource}
      end)

    {claim_group, claim_resource} = hd(late_groups)

    assert {:ok, _, _} =
             Compute.update_group_workload(claim_group, fn current ->
               Map.put(current, "active_operations", %{
                 "late-start" => %{
                   "kind" => "cloudflare_gateway_attempt",
                   "state" => "pending_start",
                   "target_resource" => claim_resource
                 }
               })
             end)

    assert {:ok, %{processed: 100, next_cursor: "allocations"}} =
             CloudflareProfileHandoff.transfer_page()

    assert {:ok, %{processed: 2, next_cursor: "claims"}} =
             CloudflareProfileHandoff.transfer_page("allocations")

    assert {:ok, %{processed: 1, next_cursor: nil}} =
             CloudflareProfileHandoff.transfer_page("claims")

    assert {:ok, %{processed: 0, next_cursor: "claims"}} =
             CloudflareProfileHandoff.transfer_page()

    assert {:ok, %{processed: 0, next_cursor: nil}} =
             CloudflareProfileHandoff.transfer_page("claims")

    for {group, _resource} <- late_groups do
      assert {:ok, rec} = Compute.group_workload(group)
      assert get_in(rec, ["provider_spec", "profile_key"]) == "cf-standard-2"
    end

    assert {:ok, absent} = Compute.group_workload(elem(List.last(late_groups), 0))
    assert absent["status"] == "absent"

    assert {:ok, cutover} = Compute.group_workload(cutover_group)
    assert get_in(cutover, ["provider_spec", "profile_key"]) == "cf-standard-2"

    assert {:ok, foreign} = Compute.group_workload(foreign_group)
    refute Map.has_key?(foreign["provider_spec"] || %{}, "profile_key")

    assert {:ok, claimed} = Compute.group_workload(claim_group)

    assert get_in(claimed, ["active_operations", "late-start", "target_resource"]) ==
             "cf-standard-2:" <> claim_resource
  end

  test "legacy profile backfill waits for a locked allocation before completing" do
    migration_file =
      Application.app_dir(
        :salix_store,
        "priv/repo/migrations/20260929000100_backfill_cloudflare_group_profile.exs"
      )

    Code.require_file(migration_file)
    migration = SalixStore.Repo.Migrations.BackfillCloudflareGroupProfile
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    resource = SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => resource,
               "provider_resource_name" => resource,
               "provider_spec" => %{},
               "status" => "ready",
               "created_at" => 1_000
             })

    assert {:ok, rec} = Compute.group_workload(group)
    refute get_in(rec, ["provider_spec", "profile_key"])

    assert {:ok, _, _} =
             Compute.update_group_workload(group, fn current ->
               Map.put(current, "active_operations", %{
                 "old-start" => %{
                   "kind" => "cloudflare_gateway_attempt",
                   "state" => "pending_start",
                   "target_resource" => resource
                 }
               })
             end)

    connection_options =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])

    {:ok, lock_connection} = Postgrex.start_link(connection_options)

    try do
      Postgrex.query!(lock_connection, "BEGIN", [])

      Postgrex.query!(
        lock_connection,
        "SELECT id FROM compute_allocations WHERE id = $1 FOR UPDATE",
        [rec["allocation_id"]]
      )

      task =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL lock_timeout = '5s'")
            Repo.query!(migration.backfill_sql())
            Repo.query!(migration.backfill_gateway_claims_sql())
          end)
        end)

      assert Task.yield(task, 100) == nil
      Postgrex.query!(lock_connection, "COMMIT", [])
      assert {:ok, {:ok, _}} = Task.yield(task, 5_000)

      assert {:ok, updated} = Compute.group_workload(group)
      assert updated["provider_spec"]["profile_key"] == "cf-standard-2"

      assert get_in(updated, ["active_operations", "old-start", "target_resource"]) ==
               "cf-standard-2:" <> resource

      assert :ok =
               Compute.finish_cloudflare_gateway_starting(group, "cf-standard-2:" <> resource)

      assert {:ok, settled} = Compute.group_workload(group)
      assert settled["active_operation_count"] == 0
    after
      Postgrex.query!(lock_connection, "ROLLBACK", [])
      GenServer.stop(lock_connection)
    end
  end

  test "managed default onboarding is concurrent-idempotent, provider-fixed, and never workload-created" do
    assert {:error, :compute_pool_not_configured} = Compute.resolve_pool("tenant")

    assert {:error, :capacity_unavailable} =
             Compute.place_workload(%{
               tenant_id: "tenant",
               allocation_id: "missing-allocation",
               workload_id: "missing-workload",
               environment_id: "missing-environment",
               kind: "external_worker"
             })

    assert Repo.aggregate(Compute.Pool, :count) == 0

    pools =
      1..8
      |> Task.async_stream(
        fn _ -> Compute.ensure_managed_default_pool("tenant", "cloudflare") end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, pool}} -> pool end)

    assert pools |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(Compute.Pool, :count) == 1
    assert {:ok, resolved} = Compute.resolve_pool("tenant")
    assert resolved.id == hd(pools).id
    assert resolved.managed_key == "default"

    assert {:error, :managed_pool_provider_conflict} =
             Compute.ensure_managed_default_pool("tenant", "agent_vmm")
  end

  test "environment ensure keeps one owner on one exact pool" do
    {:ok, first_pool} = Compute.ensure_managed_default_pool("tenant", "cloudflare")

    attrs = %{
      id: "environment-first-request",
      tenant_id: "tenant",
      owner_type: "project",
      owner_id: "project",
      pool_id: first_pool.id
    }

    assert {:ok, first} = Compute.ensure_environment(attrs)
    assert {:ok, retried} = Compute.ensure_environment(%{attrs | id: "environment-retry"})
    assert retried.id == first.id

    {:ok, other_pool} =
      Compute.create_pool(%{
        id: "other-pool",
        tenant_id: "tenant",
        name: "other",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]}
      })

    assert {:error, :pool_selection_conflict} =
             Compute.ensure_environment(%{attrs | id: "environment-move", pool_id: other_pool.id})
  end

  test "group environment ownership cannot alias a project with the same id" do
    {:ok, pool} = Compute.ensure_managed_default_pool("tenant", "cloudflare")

    attrs = %{
      id: "group-environment",
      tenant_id: "tenant",
      owner_type: "group",
      owner_id: "owner",
      pool_id: pool.id
    }

    assert {:ok, group} = Compute.ensure_environment(attrs)
    assert {:ok, retry} = Compute.ensure_environment(%{attrs | id: "unused-retry-id"})
    assert retry.id == group.id

    assert {:ok, project} =
             Compute.ensure_environment(%{
               attrs
               | id: "project-environment",
                 owner_type: "project"
             })

    refute project.id == group.id
  end

  test "Group runtime retries retain archive, device, runtime targets and concurrent activity" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    facts = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "provider" => "cloudflare",
      "provider_resource_id" => "existing-sandbox",
      "env_id" => "existing-environment",
      "device_id" => "existing-device",
      "connector_id" => "existing-connector",
      "status" => "archived",
      "created_at" => 1234,
      "archive" => %{"format" => "connector_tar_gz", "key" => "owned-files"},
      "runtime_targets" => %{"codex" => %{"state" => "ready"}}
    }

    assert {:ok, first, :created} = Compute.ensure_group_workload(facts)
    assert {:ok, retry, :existing} = Compute.ensure_group_workload(facts)
    assert retry["workload_id"] == first["workload_id"]
    assert retry["archive"] == facts["archive"]
    assert retry["runtime_targets"] == facts["runtime_targets"]
    assert retry["created_at"] == 1234

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Compute.update_group_workload(group, fn current ->
            Map.update(
              current,
              "active_operations",
              %{to_string(index) => %{"state" => "active"}},
              &Map.put(&1, to_string(index), %{"state" => "active"})
            )
          end)
        end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _, _}}, &1))
    assert {:ok, current} = Compute.group_workload(group)
    assert current["active_operation_count"] == 8
    assert current["device_id"] == facts["device_id"]

    assert {:error, :identity_mismatch} =
             Compute.update_group_workload(group, &Map.put(&1, "device_id", "other"))

    assert Repo.aggregate(Compute.Workload, :count) == 1

    attrs = %{
      operation_id: "new-op",
      kind: "exec",
      mutating?: true,
      agent_id: nil,
      idempotency_class: "non_idempotent"
    }

    assert {:wake, {:error, {:vm_waking, _}}} = Compute.begin_group_operation(group, attrs)
    assert {:ok, _, _} = Compute.update_group_workload(group, &Map.put(&1, "status", "ready"))
    assert {:ok, "new-op"} = Compute.begin_group_operation(group, attrs)
    assert {:ok, "new-op"} = Compute.begin_group_operation(group, attrs)
    assert {:ok, active} = Compute.group_workload(group)
    assert active["active_operation_count"] == 9

    assert :ok =
             Compute.finish_group_operation(group, %{
               operation_id: "new-op",
               state: "succeeded",
               result: %{exit_code: 0}
             })

    assert :ok =
             Compute.finish_group_operation(group, %{
               operation_id: "new-op",
               state: "succeeded",
               result: %{exit_code: 0}
             })

    assert {:ok, finished} = Compute.group_workload(group)
    assert finished["active_operation_count"] == 8
    assert {:ok, _, _} = Compute.update_group_workload(group, &Map.put(&1, "status", "archiving"))

    assert {:error, {:vm_archiving, _}} =
             Compute.begin_group_operation(group, %{attrs | operation_id: "late-op"})
  end

  test "concurrent first use fixes one Group profile and resource" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    resource = SalixStore.RuntimeIds.cloud_vm_provider_resource_name(group)

    facts = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "provider" => "cloudflare",
      "provider_resource_id" => resource,
      "provider_resource_name" => resource,
      "provider_spec" => %{"profile_key" => "cf-standard-1"},
      "status" => "creating",
      "created_at" => System.system_time(:millisecond)
    }

    results =
      1..8
      |> Task.async_stream(fn _ -> Compute.ensure_group_workload(facts) end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == 7

    assert {:ok, %{"provider_spec" => %{"profile_key" => "cf-standard-1"}} = rec} =
             Compute.group_workload(group)

    assert rec["provider_resource_name"] == resource
    assert Repo.aggregate(Compute.Workload, :count) == 1
  end

  test "Gateway release waits for tracked calls, fences new calls, and fails closed on storage errors" do
    on_exit(fn -> S3.delete(Keys.ctl_vm_maintenance()) end)
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "container",
               "status" => "ready",
               "created_at" => 1234
             })

    assert {:ok, "gateway-old"} =
             Compute.begin_cloudflare_gateway_attempt(group, "gateway-old")

    assert {:ok, %{"active_operation_count" => 1}} = Compute.group_workload(group)

    assert {:ok, %{"maintenance_id" => "release-one"}} =
             Compute.begin_cloudflare_gateway_release("release-one", %{
               "reason" => "sandbox_image_release"
             })

    assert {:ok, %{"maintenance_id" => "release-two", "phase" => "prepared"}} =
             Compute.begin_cloudflare_gateway_release("release-two", %{
               "reason" => "sandbox_image_release"
             })

    assert {:error, {:vm_service_upgrading, %{"maintenance_id" => "release-two"}}} =
             Compute.begin_cloudflare_gateway_attempt(group, "gateway-new")

    assert {:ok, %{"active_operation_count" => 1}} = Compute.group_workload(group)

    assert {:error, :vm_maintenance_owned_by_other_release} =
             Compute.clear_cloudflare_gateway_release("release-one")

    assert :ok = Compute.finish_cloudflare_gateway_attempt(group, "gateway-old")
    assert {:ok, %{"active_operation_count" => 0}} = Compute.group_workload(group)

    assert {:error, :vm_maintenance_phase_mismatch} =
             Compute.clear_cloudflare_gateway_release("release-two", "deploying")

    assert {:ok, %{"phase" => "deploying"}} =
             Compute.mark_cloudflare_gateway_release_deploying("release-two")

    assert {:error, :vm_maintenance_phase_mismatch} =
             Compute.clear_cloudflare_gateway_release("release-two", "prepared")

    assert :ok = Compute.clear_cloudflare_gateway_release("release-two", "deploying")

    S3.Fake.set_fault({:fail, 503, :get, Keys.ctl_vm_maintenance()})

    assert {:error, {:vm_maintenance_unavailable, _}} =
             Compute.begin_cloudflare_gateway_attempt(group, "gateway-after-error")

    assert {:ok, %{"active_operation_count" => 0}} = Compute.group_workload(group)
  end

  test "standalone Gateway probe claim shares the image release fence" do
    on_exit(fn -> S3.delete(Keys.ctl_vm_maintenance()) end)
    assert {:ok, "probe-one"} = Compute.begin_cloudflare_direct_gateway_attempt("probe-one")

    assert {:ok, %{"active_direct_attempts" => %{"probe-one" => _}}} =
             Compute.begin_cloudflare_gateway_release("image-one", %{})

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_direct_gateway_attempt("probe-two")

    assert :ok = Compute.clear_cloudflare_gateway_release("image-one", "prepared")

    assert {:ok, %{"enabled" => false, "active_direct_attempts" => %{"probe-one" => _}}} =
             Compute.cloudflare_gateway_release_status()

    assert {:ok, %{"maintenance_id" => "image-two"}} =
             Compute.begin_cloudflare_gateway_release("image-two", %{})

    assert {:error, :direct_gateway_attempts_pending} =
             Compute.mark_cloudflare_gateway_release_deploying("image-two")

    assert :ok = Compute.finish_cloudflare_direct_gateway_attempt("probe-one")
    assert :ok = Compute.clear_cloudflare_gateway_release("image-two", "prepared")
  end

  test "ready Sandbox settles only its coalesced pending start claim" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sandbox-one",
               "status" => "ready"
             })

    assert {:ok, "first"} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "first",
               :normal,
               "cf-standard-2:sandbox-one"
             )

    assert :ok =
             Compute.mark_cloudflare_gateway_starting(group, "first", "cf-standard-2:sandbox-one")

    assert {:ok, "repeat"} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "repeat",
               :normal,
               "cf-standard-2:sandbox-one"
             )

    assert :ok =
             Compute.mark_cloudflare_gateway_starting(
               group,
               "repeat",
               "cf-standard-2:sandbox-one"
             )

    assert {:ok, "other"} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "other",
               :normal,
               "cf-standard-1:sandbox-one"
             )

    assert :ok =
             Compute.mark_cloudflare_gateway_starting(group, "other", "cf-standard-1:sandbox-one")

    assert {:ok, %{"active_operation_count" => 2}} = Compute.group_workload(group)

    assert :ok = Compute.finish_cloudflare_gateway_starting(group, "cf-standard-2:sandbox-one")
    assert {:ok, %{"active_operation_count" => 1}} = Compute.group_workload(group)
    assert :ok = Compute.finish_cloudflare_gateway_starting(group, "cf-standard-1:sandbox-one")
    assert {:ok, %{"active_operation_count" => 0}} = Compute.group_workload(group)
  end

  test "a prepared image fence admits only the owned archiving Workload's archive calls" do
    on_exit(fn -> S3.delete(Keys.ctl_vm_maintenance()) end)
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => group,
               "provider" => "cloudflare",
               "provider_resource_id" => "sandbox-one",
               "provider_resource_name" => "sandbox-one",
               "provider_spec" => %{"profile_key" => "cf-standard-2"},
               "status" => "archiving",
               "created_at" => 1234
             })

    archived_group = SalixStore.Ids.new_group_id(tenant)

    assert {:ok, _, :created} =
             Compute.ensure_group_workload(%{
               "tenant_id" => tenant,
               "group_id" => archived_group,
               "provider" => "cloudflare",
               "provider_resource_id" => "saved-sandbox",
               "provider_resource_name" => "saved-sandbox",
               "provider_spec" => %{"profile_key" => "cf-standard-2"},
               "status" => "archived",
               "archive" => %{
                 "type" => "connector_tar_gz_chunks",
                 "storage" => "salix_s3",
                 "operation" => "saved-archive",
                 "byte_size" => 1,
                 "chunk_count" => 1
               },
               "connector_archive" => %{
                 "type" => "connector_tar_gz_chunks",
                 "storage" => "salix_s3",
                 "operation" => "saved-archive",
                 "byte_size" => 1,
                 "chunk_count" => 1
               }
             })

    assert {:ok, %{"phase" => "prepared"}} =
             Compute.begin_cloudflare_gateway_release("image-archive", %{
               "reason" => "sandbox_image_release"
             })

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_gateway_attempt(group, "ordinary", :normal)

    assert {:ok, "archive"} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "archive",
               :archive,
               "cf-standard-2:sandbox-one"
             )

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "wrong-archive",
               :archive,
               "cf-standard-1:sandbox-one"
             )

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_gateway_attempt(
               archived_group,
               "wrong-sandbox",
               :archive,
               "cf-standard-1:saved-sandbox"
             )

    assert {:ok, "finish-saved-archive"} =
             Compute.begin_cloudflare_gateway_attempt(
               archived_group,
               "finish-saved-archive",
               :archive,
               "cf-standard-2:saved-sandbox"
             )

    assert :ok = Compute.finish_cloudflare_gateway_attempt(group, "archive")
    assert :ok = Compute.finish_cloudflare_gateway_attempt(archived_group, "finish-saved-archive")

    assert {:ok, %{"phase" => "deploying"}} =
             Compute.mark_cloudflare_gateway_release_deploying("image-archive")

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_gateway_attempt(group, "late-archive", :archive)

    assert {:error, {:vm_service_upgrading, _}} =
             Compute.begin_cloudflare_gateway_attempt(
               archived_group,
               "late-saved-archive",
               :archive,
               "cf-standard-2:saved-sandbox"
             )

    assert :ok = Compute.clear_cloudflare_gateway_release("image-archive", "deploying")
  end

  test "new image release takes over an unfinished deploy without opening the fence" do
    on_exit(fn -> S3.delete(Keys.ctl_vm_maintenance()) end)

    assert {:ok, %{"phase" => "prepared"}} =
             Compute.begin_cloudflare_gateway_release("image-old", %{
               "reason" => "sandbox_image_release"
             })

    assert {:ok, %{"phase" => "deploying"}} =
             Compute.mark_cloudflare_gateway_release_deploying("image-old")

    assert {:ok,
            %{
              "enabled" => true,
              "phase" => "deploying",
              "maintenance_id" => "image-new",
              "superseded_maintenance_id" => "image-old"
            }} =
             Compute.begin_cloudflare_gateway_release("image-new", %{
               "reason" => "sandbox_image_release"
             })

    assert {:error, :vm_maintenance_owned_by_other_release} =
             Compute.clear_cloudflare_gateway_release("image-old", "deploying")

    assert :ok = Compute.clear_cloudflare_gateway_release("image-new", "deploying")
  end

  test "agent vmm managed pool owns per-workload isolation limits" do
    {:ok, pool} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")
    policy = pool.capacity["agent_vmm_remote_policy"]
    refute Map.has_key?(policy, "max_environments")

    per_environment = policy["per_environment_limits"]

    for key <- RuntimeBundleCatalog.keys() do
      assert {:ok, template} = RuntimeBundleCatalog.resolve(key, root: @runtime_bundle_root)
      assert resource_contract_within?(template.resources, per_environment)
    end

    refute Map.has_key?(policy, "aggregate_limits")

    {:ok, environment} =
      Compute.ensure_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    assert {:ok, %{policy: ^policy, revision: 1}} =
             Compute.agent_vmm_remote_policy(environment.id)
  end

  test "agent vmm managed pool removes retired aggregate and compute reservations" do
    {:ok, _pool} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")

    {1, _} =
      Repo.update_all(
        Compute.Pool,
        set: [
          capacity: %{
            "agent_vmm_remote_policy" => %{
              "max_environments" => 1,
              "aggregate_limits" => %{"cpu_millis" => 1},
              "per_environment_limits" => %{"cpu_millis" => 1, "memory_bytes" => 1}
            }
          }
        ]
      )

    assert {:ok, converged} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")
    assert converged.revision == 2
    refute Map.has_key?(converged.capacity["agent_vmm_remote_policy"], "max_environments")
    refute Map.has_key?(converged.capacity["agent_vmm_remote_policy"], "aggregate_limits")

    refute Map.has_key?(
             converged.capacity["agent_vmm_remote_policy"]["per_environment_limits"],
             "cpu_millis"
           )
  end

  test "Agent VMM placement requires current observation and exact environment scope" do
    {:ok, pool} =
      Compute.create_pool(%{
        id: "scoped-pool",
        tenant_id: "tenant",
        name: "scoped",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    for {id, owner} <- [{"environment-a", "project-a"}, {"environment-b", "project-b"}] do
      assert {:ok, _environment} =
               Compute.create_environment(%{
                 id: id,
                 tenant_id: "tenant",
                 owner_type: "project",
                 owner_id: owner,
                 pool_id: pool.id
               })
    end

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "scoped-registration",
        tenant_id: "tenant",
        group_id: "group-a",
        device_id: "device-a",
        enrollment_token: String.duplicate("s", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "scoped-binding",
        pool_id: pool.id,
        environment_id: "environment-a",
        provider: "agent_vmm",
        provider_ref: registration.id
      })

    assert binding.status == "disabled"

    for environment_id <- ["environment-a", "environment-b"] do
      assert {:error, :capacity_unavailable} =
               Compute.place_workload(%{
                 tenant_id: "tenant",
                 allocation_id: "unobserved-#{environment_id}",
                 workload_id: "unobserved-workload-#{environment_id}",
                 environment_id: environment_id,
                 kind: "external_worker"
               })
    end

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    assert {:error, :capacity_unavailable} =
             Compute.place_workload(%{
               tenant_id: "tenant",
               allocation_id: "cross-environment-allocation",
               workload_id: "cross-environment-workload",
               environment_id: "environment-b",
               kind: "external_worker"
             })

    assert {:error, :provider_unavailable} =
             Compute.allocate(%{
               id: "cross-environment-direct-allocation",
               environment_id: "environment-b",
               provider_binding_id: binding.id,
               generation: 1
             })

    assert {:ok, placed} =
             Compute.place_workload(%{
               tenant_id: "tenant",
               allocation_id: "scoped-allocation",
               workload_id: "scoped-workload",
               environment_id: "environment-a",
               kind: "external_worker"
             })

    assert placed.allocation.provider_binding_id == binding.id
  end

  test "compatibility reader stays open until the Environment-scope gate is enabled" do
    previous =
      Application.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)
      else
        Application.put_env(
          :salix_store,
          :agent_vmm_environment_scoped_bindings_enabled,
          previous
        )
      end
    end)

    {:ok, pool} =
      Compute.create_pool(%{
        id: "rollout-pool",
        tenant_id: "tenant",
        name: "rollout",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    for environment_id <- ["rollout-a", "rollout-b"] do
      {:ok, _environment} =
        Compute.create_environment(%{
          id: environment_id,
          tenant_id: "tenant",
          owner_type: "project",
          owner_id: environment_id,
          pool_id: pool.id
        })
    end

    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Compute.ProviderBinding, [
        %{
          id: "legacy-unscoped-binding",
          pool_id: pool.id,
          environment_id: nil,
          provider: "agent_vmm",
          provider_ref: "legacy-registration",
          status: "available",
          generation: 1,
          revision: 1,
          observation: %{},
          updated_at: now
        }
      ])

    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, false)

    assert {:error, :environment_scope_rollout_pending} =
             Compute.create_provider_binding(%{
               id: "premature-scoped-binding",
               pool_id: pool.id,
               environment_id: "rollout-a",
               provider: "agent_vmm",
               provider_ref: "premature-registration"
             })

    assert {:ok, _allocation} =
             Compute.allocate(%{
               id: "compatibility-allocation",
               environment_id: "rollout-a",
               provider_binding_id: "legacy-unscoped-binding",
               generation: 1
             })

    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    enrollment_token = :crypto.strong_rand_bytes(32)

    assert {:ok, _registration} =
             AgentVMM.create_registration(%{
               id: "scoped-registration",
               tenant_id: "tenant",
               group_id: "group",
               device_id: "device",
               enrollment_token: enrollment_token
             })

    assert {:ok, %Compute.ProviderBinding{environment_id: "rollout-a"}} =
             Compute.create_provider_binding(%{
               id: "scoped-binding",
               pool_id: pool.id,
               environment_id: "rollout-a",
               provider: "agent_vmm",
               provider_ref: "scoped-registration"
             })

    assert {:error, :provider_unavailable} =
             Compute.allocate(%{
               id: "strict-allocation",
               environment_id: "rollout-b",
               provider_binding_id: "legacy-unscoped-binding",
               generation: 1
             })
  end

  test "single-writer state machine fences CAS, generation, and stale Provider completion" do
    fixture = compute_fixture()

    assert {:error, :stale_generation} =
             Compute.observe_allocation(fixture.allocation.id, 1, 2, "ready", "succeeded")

    assert {:ok, ready} =
             Compute.observe_allocation(fixture.allocation.id, 1, 1, "ready", "succeeded", %{
               "capacity_class" => "small"
             })

    assert ready.revision == 2

    assert {:ok, workload} =
             Compute.create_workload(%{
               id: "workload",
               environment_id: fixture.environment.id,
               allocation_id: ready.id,
               kind: "external_worker",
               spec: %{"runtime" => "codex"},
               capability_requirements: ["runtime_exec"],
               generation: 1
             })

    assert {:ok, runtime} =
             Compute.observe_runtime(%{
               id: "runtime",
               workload_id: workload.id,
               allocation_id: ready.id,
               generation: 1,
               connection_epoch: "1"
             })

    assert runtime.readiness == "catching_up"
    assert {:ok, caught_up} = Compute.complete_runtime_catch_up(runtime.id, 1, "1")
    assert caught_up.readiness == "ready"
    assert caught_up.caught_up_epoch == "1"

    assert {:ok, retried} =
             Compute.observe_runtime(%{
               id: runtime.id,
               workload_id: workload.id,
               allocation_id: ready.id,
               generation: 1,
               connection_epoch: "1"
             })

    assert retried.readiness == "ready"
    assert retried.caught_up_epoch == "1"

    runtime
    |> Ecto.Changeset.change(status: "disconnected", readiness: "pending")
    |> Repo.update!()

    assert {:ok, same_epoch_recovered} =
             Compute.observe_runtime(%{
               id: runtime.id,
               workload_id: workload.id,
               allocation_id: ready.id,
               generation: 1,
               connection_epoch: "1"
             })

    assert same_epoch_recovered.status == "connected"
    assert same_epoch_recovered.readiness == "catching_up"
    assert same_epoch_recovered.caught_up_epoch == "0"

    assert {:ok, _same_epoch_ready} =
             Compute.complete_runtime_catch_up(
               same_epoch_recovered.id,
               same_epoch_recovered.revision,
               "1"
             )

    assert {:ok, reconnected} =
             Compute.observe_runtime(%{
               id: runtime.id,
               workload_id: workload.id,
               allocation_id: ready.id,
               generation: 1,
               connection_epoch: "9"
             })

    assert {:ok, _reconnected} =
             Compute.complete_runtime_catch_up(reconnected.id, reconnected.revision, "9")

    assert {:ok, opaque_reconnected} =
             Compute.observe_runtime(%{
               id: runtime.id,
               workload_id: workload.id,
               allocation_id: ready.id,
               generation: 1,
               connection_epoch: "2"
             })

    assert opaque_reconnected.readiness == "catching_up"
    assert Repo.get!(Compute.RuntimeInstance, runtime.id).connection_epoch == "2"

    Repo.update_all(Compute.Workload, set: [generation: 2])

    current_environment = Repo.get!(Compute.Environment, fixture.environment.id)

    assert {:ok, retained} =
             Compute.update_environment_intent(
               fixture.environment.id,
               current_environment.revision,
               %{
                 retention: %{"mode" => "release_on_stop"}
               }
             )

    assert retained.generation == 1

    assert {:ok, draining} =
             Compute.update_environment_intent(retained.id, retained.revision, %{
               desired_state: "draining"
             })

    assert draining.generation == 2
    assert Repo.get!(Compute.Allocation, ready.id).status == "draining"
    assert Repo.get!(Compute.Workload, workload.id).desired_state == "draining"
    assert Repo.get!(Compute.RuntimeInstance, caught_up.id).generation == 1

    assert {:error, :stale_generation} =
             Compute.observe_allocation(ready.id, ready.revision, 1, "ready", "succeeded")
  end

  test "entity-owned allocation observations preserve independent runtime facts" do
    fixture = compute_fixture()

    assert {:ok, observed} =
             Compute.observe_allocation(
               fixture.allocation.id,
               fixture.allocation.revision,
               fixture.environment.generation,
               "ready",
               "succeeded",
               %{
                 "allocation_revision" => 1,
                 "imported_reference" => "comma.local/runtime/image@sha256:abc",
                 "current_container" => %{"id" => "container-1", "state" => "running"},
                 "container_status" => "running"
               }
             )

    assert {:ok, refreshed} =
             Compute.observe_allocation(
               observed.id,
               observed.revision,
               observed.generation,
               "ready",
               "succeeded",
               %{"allocation_revision" => 2, "allocation_state" => "ready"},
               merge_provider_observation: true
             )

    assert refreshed.provider_observation["allocation_revision"] == 2
    assert refreshed.provider_observation["allocation_state"] == "ready"

    assert refreshed.provider_observation["imported_reference"] ==
             "comma.local/runtime/image@sha256:abc"

    assert refreshed.provider_observation["current_container"] == %{
             "id" => "container-1",
             "state" => "running"
           }

    assert refreshed.provider_observation["container_status"] == "running"
  end

  test "exact allocation facts remove obsolete provider projections" do
    fixture = compute_fixture()

    assert {:ok, observed} =
             Compute.observe_allocation(
               fixture.allocation.id,
               fixture.allocation.revision,
               fixture.environment.generation,
               "ready",
               "succeeded",
               %{"health" => "sleeping", "current_container" => %{}}
             )

    assert {:ok, refreshed} =
             Compute.observe_allocation_facts(
               observed.id,
               observed.revision,
               observed.generation,
               %{"container_status" => "absent", "health" => "ready"},
               ["health"]
             )

    refute Map.has_key?(refreshed.provider_observation, "health")
    assert refreshed.provider_observation["current_container"] == %{}
    assert refreshed.provider_observation["container_status"] == "absent"
  end

  test "outbound Workload credentials are short-lived, scoped, and contain no Provider authority" do
    assert {:ok, credential} =
             Compute.WorkloadCredential.issue(
               "workload",
               "runtime-instance",
               ["runtime", "workspace"],
               60
             )

    token = credential["token"]

    assert {:ok, claims} =
             Compute.WorkloadCredential.verify(token, "workload", "runtime")

    assert claims["runtime_instance_id"] == "runtime-instance"
    refute Map.has_key?(claims, "provider")
    refute Map.has_key?(claims, "registration_id")
    refute Map.has_key?(claims, "lease_id")
    refute Map.has_key?(claims, "endpoint")

    assert {:error, :invalid_workload_credential} =
             Compute.WorkloadCredential.verify(token, "other-workload", "runtime")

    assert {:error, :invalid_workload_credential} =
             Compute.WorkloadCredential.verify(token, "workload", "hosting")

    refute inspect(Map.drop(credential, ["token"])) =~ token
  end

  test "side effects become unknown while read and desired-state commands remain replayable" do
    fixture = ready_fixture()
    deadline = DateTime.add(DateTime.utc_now(), 60, :second)

    for {id, class} <- [
          {"side", "side_effecting"},
          {"read", "read_only"},
          {"desired", "desired_state"}
        ] do
      assert {:ok, _} =
               Compute.enqueue_command(%{
                 id: id,
                 allocation_id: fixture.allocation.id,
                 request_id: id,
                 kind: id,
                 classification: class,
                 target_generation: 1,
                 target_revision: fixture.allocation.revision,
                 deadline_at: deadline
               })
    end

    assert {:ok, claimed} = Compute.claim_commands(fixture.binding.id, 1)
    assert length(claimed) == 3

    assert {:ok, %{unknown_outcome: 1, pending: 2}} =
             Compute.mark_provider_connection_lost(fixture.binding.id)

    assert Repo.get!(Compute.Command, "side").status == "unknown_outcome"
    assert Repo.get!(Compute.Command, "read").status == "pending"
    assert Repo.get!(Compute.Command, "desired").status == "pending"
  end

  test "expired admitted work settles without a disconnect callback or reconnect" do
    fixture = ready_fixture()
    deadline = DateTime.add(DateTime.utc_now(), 60, :second)

    for {id, class} <- [
          {"expired-side", "side_effecting"},
          {"expired-read", "read_only"},
          {"expired-desired", "desired_state"}
        ] do
      assert {:ok, _} =
               Compute.enqueue_command(%{
                 id: id,
                 allocation_id: fixture.allocation.id,
                 request_id: id,
                 kind: id,
                 classification: class,
                 target_generation: 1,
                 target_revision: fixture.allocation.revision,
                 deadline_at: deadline
               })
    end

    assert {:ok, claimed} = Compute.claim_commands(fixture.binding.id, 1)
    assert length(claimed) == 3

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)
    Repo.update_all(Compute.Command, set: [deadline_at: expired_at])

    assert {:ok, %{settled: 3, more?: false}} =
             AgentVMM.settle_expired_commands(32, DateTime.utc_now())

    assert Repo.get!(Compute.Command, "expired-side").status == "unknown_outcome"
    assert Repo.get!(Compute.Command, "expired-side").outcome == "unknown"
    assert Repo.get!(Compute.Command, "expired-read").status == "failed"
    assert Repo.get!(Compute.Command, "expired-read").outcome == "failed"
    assert Repo.get!(Compute.Command, "expired-desired").status == "failed"
    assert Repo.get!(Compute.Command, "expired-desired").outcome == "failed"

    retry_deadline = DateTime.add(DateTime.utc_now(), 60, :second)

    assert {:ok, retry} =
             Compute.enqueue_command(%{
               id: "retry-expired-desired",
               allocation_id: fixture.allocation.id,
               request_id: "expired-desired",
               kind: "expired-desired",
               classification: "desired_state",
               target_generation: 1,
               target_revision: fixture.allocation.revision,
               deadline_at: retry_deadline
             })

    assert retry.id == "retry-expired-desired"
    assert retry.status == "pending"
    assert Repo.get(Compute.Command, "expired-desired") == nil
    assert {:ok, [claimed_retry]} = Compute.claim_commands(fixture.binding.id, 1)
    assert claimed_retry.id == retry.id
  end

  test "expired pending replayable work can be issued as a fresh attempt" do
    fixture = ready_fixture()
    deadline = DateTime.add(DateTime.utc_now(), 60, :second)

    assert {:ok, _} =
             Compute.enqueue_command(%{
               id: "expired-pending",
               allocation_id: fixture.allocation.id,
               request_id: "stable-request",
               kind: "observe",
               classification: "read_only",
               target_generation: 1,
               target_revision: fixture.allocation.revision,
               deadline_at: deadline
             })

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(Compute.Command, set: [deadline_at: expired_at])

    assert {:ok, %{settled: 1, more?: false}} =
             AgentVMM.settle_expired_commands(32, DateTime.utc_now())

    assert Repo.get!(Compute.Command, "expired-pending").status == "failed"

    assert {:ok, retry} =
             Compute.enqueue_command(%{
               id: "retry-expired-pending",
               allocation_id: fixture.allocation.id,
               request_id: "stable-request",
               kind: "observe",
               classification: "read_only",
               target_generation: 1,
               target_revision: fixture.allocation.revision,
               deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert retry.id == "retry-expired-pending"
    assert retry.status == "pending"
    assert Repo.get(Compute.Command, "expired-pending") == nil
    assert {:ok, [claimed_retry]} = Compute.claim_commands(fixture.binding.id, 1)
    assert claimed_retry.id == retry.id
  end

  test "grants and bounded owner projection are scoped and revision fenced" do
    fixture = compute_fixture()

    assert {:ok, grant} =
             Compute.issue_grant(%{
               id: "grant",
               tenant_id: "tenant",
               environment_id: fixture.environment.id,
               principal_type: "agent",
               principal_id: "agent",
               permissions: ["runtime", "workspace"],
               expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert :ok = Compute.revoke_grant("tenant", grant.id, 1)
    assert {:error, :revision_conflict} = Compute.revoke_grant("tenant", grant.id, 1)

    assert {:ok, projection} = Compute.project("tenant", "project", "project", 10)
    assert Enum.map(projection.environments, & &1.id) == [fixture.environment.id]
    assert Enum.map(projection.allocations, & &1.id) == [fixture.allocation.id]

    assert {:ok, empty} = Compute.project("tenant", "project", "other", 10)
    assert empty.environments == []
    assert empty.allocations == []
  end

  test "workload grants follow an advanced workload on its current allocation" do
    fixture = ready_fixture()

    assert {:ok, grant} =
             Compute.issue_grant(%{
               id: "workload-grant",
               tenant_id: "tenant",
               environment_id: fixture.environment.id,
               workload_id: fixture.workload.id,
               principal_type: "agent",
               principal_id: "agent",
               permissions: ["runtime"],
               expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    Repo.update_all(Compute.Workload, set: [generation: 2])

    assert {:ok, %Compute.Workload{generation: 2}} =
             Compute.authorize_workload_grant(
               "tenant",
               grant.id,
               fixture.environment.id,
               "agent",
               "runtime"
             )
  end

  test "work activity is a bounded provider-scoped projection" do
    fixture = ready_fixture()

    assert {:ok, idle} = Compute.work_activity("tenant", "registration")

    assert idle == %{
             "activity" => "idle",
             "active_operation_count" => 0,
             "workload_count" => 0
           }

    Repo.update_all(Compute.Workload, set: [observed_state: "ready"])

    assert {:ok, active} =
             Compute.enqueue_command(%{
               id: "activity-command",
               allocation_id: fixture.allocation.id,
               workload_id: fixture.workload.id,
               request_id: "activity-request",
               kind: "compute.exec",
               classification: "side_effecting",
               target_generation: 1,
               target_revision: fixture.allocation.revision,
               deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert active.status == "pending"
    assert {:ok, projection} = Compute.work_activity("tenant", "registration")
    assert projection["activity"] == "idle"
    assert projection["active_operation_count"] == 0
    assert projection["workload_count"] == 1

    assert {:ok, _claimed} = Compute.claim_commands(fixture.binding.id, 1)
    assert {:ok, executing} = Compute.work_activity("tenant", "registration")
    assert executing["activity"] == "active"
    assert executing["active_operation_count"] == 1

    assert {:error, :invalid_provider_binding} =
             Compute.work_activity("other-tenant", "registration")

    assert {:error, :invalid_provider_binding} =
             Compute.work_activity("tenant", "missing-registration")
  end

  test "External Worker binding accepts only two tagged variants and rejects Provider identity" do
    fixture = ready_fixture()

    assert {:ok, %{source_kind: "connected_runtime"}} =
             Compute.put_external_worker_binding(
               %{id: "connected", tenant_id: "tenant", agent_id: "agent-connected"},
               %{
                 "kind" => "connected_runtime",
                 "device_runtime_id" => "runtime-device",
                 "runtime_spec" => %{"runtime" => "codex"}
               }
             )

    assert {:ok, %{source_kind: "compute_workload"}} =
             Compute.put_external_worker_binding(
               %{id: "compute", tenant_id: "tenant", agent_id: "agent-compute"},
               %{
                 "kind" => "compute_workload",
                 "workload_id" => fixture.workload.id,
                 "runtime_spec" => %{"provider" => "codex", "model" => "gpt-5"}
               }
             )

    assert {:error, :unknown_field} =
             Compute.validate_external_worker_binding(%{
               "kind" => "compute_workload",
               "workload_id" => fixture.workload.id,
               "provider" => "agent_vmm"
             })

    assert {:error, :provider_native_identity} =
             Compute.validate_external_worker_binding(%{
               "kind" => "compute_workload",
               "workload_id" => fixture.workload.id,
               "runtime_spec" => %{"endpoint" => "private.example"}
             })

    assert {:error, :invalid_compute_workload} =
             Compute.validate_external_worker_binding(%{
               "kind" => "compute_workload",
               "workload_id" => fixture.workload.id,
               "device_runtime_id" => "also-present"
             })
  end

  test "pool reassignment and workload-scoped grants fail closed across tenant boundaries" do
    fixture = ready_fixture()

    {:ok, foreign_pool} =
      Compute.create_pool(%{
        id: "foreign-pool",
        tenant_id: "foreign-tenant",
        name: "foreign",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    current_environment = Repo.get!(Compute.Environment, fixture.environment.id)

    assert {:error, :scope_mismatch} =
             Compute.update_environment_intent(
               fixture.environment.id,
               current_environment.revision,
               %{
                 pool_id: foreign_pool.id
               }
             )

    assert {:error, :pool_not_found} =
             Compute.update_environment_intent(
               fixture.environment.id,
               current_environment.revision,
               %{
                 pool_id: "missing-pool"
               }
             )

    environment = Repo.get!(Compute.Environment, fixture.environment.id)
    assert environment.pool_id == fixture.pool.id
    assert environment.revision == current_environment.revision

    {:ok, other_environment} =
      Compute.create_environment(%{
        id: "other-environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "other-project",
        pool_id: fixture.pool.id
      })

    assert {:error, :scope_mismatch} =
             Compute.issue_grant(%{
               id: "cross-environment-grant",
               tenant_id: "tenant",
               environment_id: other_environment.id,
               workload_id: fixture.workload.id,
               principal_type: "agent",
               principal_id: "agent",
               permissions: ["runtime"],
               expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert Repo.get(Compute.Grant, "cross-environment-grant") == nil
  end

  test "workload placement rejects unsupported pool capabilities before allocating" do
    fixture = compute_fixture()

    assert {:error, :unsupported_capability} =
             Compute.place_workload(%{
               tenant_id: fixture.environment.tenant_id,
               allocation_id: "unsupported-allocation",
               workload_id: "unsupported-workload",
               environment_id: fixture.environment.id,
               kind: "service",
               capability_requirements: ["service_public_http"]
             })

    assert Repo.get(Compute.Allocation, "unsupported-allocation") == nil
    assert Repo.get(Compute.Workload, "unsupported-workload") == nil
  end

  test "provider policy rejects disallowed bindings and excludes stale bindings after update" do
    {:ok, pool} =
      Compute.create_pool(%{
        id: "policy-pool",
        tenant_id: "tenant",
        name: "policy",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]},
        capabilities: ["runtime_exec"]
      })

    assert {:error, :provider_not_allowed} =
             Compute.create_provider_binding(%{
               id: "disallowed-binding",
               pool_id: pool.id,
               provider: "agent_vmm"
             })

    assert Repo.get(Compute.ProviderBinding, "disallowed-binding") == nil

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "allowed-binding",
        pool_id: pool.id,
        provider: "cloudflare"
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "policy-environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "policy-project",
        pool_id: pool.id
      })

    assert {:ok, _pool} =
             Compute.update_pool(pool.id, pool.revision, %{
               provider_policy: %{"providers" => ["agent_vmm"]}
             })

    assert {:error, :provider_unavailable} =
             Compute.allocate(%{
               id: "stale-policy-allocation",
               environment_id: environment.id,
               provider_binding_id: binding.id,
               generation: environment.generation
             })

    assert {:error, :capacity_unavailable} =
             Compute.place_workload(%{
               tenant_id: environment.tenant_id,
               allocation_id: "policy-allocation",
               workload_id: "policy-workload",
               environment_id: environment.id,
               kind: "external_worker"
             })

    assert Repo.get(Compute.Allocation, "stale-policy-allocation") == nil
    assert Repo.get(Compute.Allocation, "policy-allocation") == nil
    assert Repo.get(Compute.Workload, "policy-workload") == nil
  end

  test "provider binding rejects a registration owned by another tenant" do
    suffix = System.unique_integer([:positive])

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "cross-tenant-registration-#{suffix}",
        tenant_id: "tenant-b",
        group_id: "group-b",
        device_id: "device-b-#{suffix}",
        enrollment_token: String.duplicate("b", 32)
      })

    {:ok, pool} =
      Compute.create_pool(%{
        id: "cross-tenant-pool-#{suffix}",
        tenant_id: "tenant-a",
        name: "cross-tenant-#{suffix}",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "cross-tenant-environment-#{suffix}",
        tenant_id: "tenant-a",
        owner_type: "project",
        owner_id: "cross-tenant-project-#{suffix}",
        pool_id: pool.id
      })

    assert {:error, :provider_scope_mismatch} =
             Compute.create_provider_binding(%{
               id: "cross-tenant-binding-#{suffix}",
               pool_id: pool.id,
               environment_id: environment.id,
               provider: "agent_vmm",
               provider_ref: registration.id
             })

    refute Repo.get(Compute.ProviderBinding, "cross-tenant-binding-#{suffix}")
  end

  test "workload placement rejects an environment from another tenant" do
    fixture = compute_fixture()

    assert {:error, :tenant_scope_mismatch} =
             Compute.place_workload(%{
               tenant_id: "foreign-tenant",
               allocation_id: "cross-tenant-allocation",
               workload_id: "cross-tenant-workload",
               environment_id: fixture.environment.id,
               kind: "service",
               capability_requirements: ["runtime_exec"]
             })

    assert Repo.get(Compute.Allocation, "cross-tenant-allocation") == nil
    assert Repo.get(Compute.Workload, "cross-tenant-workload") == nil
  end

  test "pool policy and capabilities reject duplicate or unknown values" do
    base = %{
      id: "invalid-policy-pool",
      tenant_id: "tenant",
      name: "invalid",
      region: "local"
    }

    assert {:error, :invalid_provider_policy} =
             Compute.create_pool(
               Map.put(base, :provider_policy, %{"providers" => ["agent_vmm", "agent_vmm"]})
             )

    assert {:error, :invalid_capability} =
             Compute.create_pool(
               base
               |> Map.put(:id, "invalid-capability-pool")
               |> Map.put(:provider_policy, %{"providers" => ["agent_vmm"]})
               |> Map.put(:capabilities, ["runtime_exec", "runtime_exec"])
             )
  end

  test "stopping a workload survives Host ready inventory and releases its allocation" do
    fixture = ready_fixture()

    assert {:ok, stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    incarnation = Compute.release_incarnation(allocation.id, allocation.generation)
    command = Repo.get_by!(Compute.Command, release_incarnation: incarnation)

    assert stopped.desired_state == "stopped"
    assert allocation.status == "draining"
    assert command.workload_id == nil
    assert command.request_id == incarnation
    assert command.target_generation == allocation.generation
    assert command.target_revision == allocation.revision

    assert {:ok, ^stopped} = Compute.stop_workload(stopped.id, stopped.revision, "duplicate")

    assert Repo.aggregate(
             from(c in Compute.Command,
               where: c.allocation_id == ^allocation.id and c.kind == "allocation.release"
             ),
             :count
           ) == 1

    assert {:ok, :ok} =
             AgentVMM.observe_registration(fixture.binding.provider_ref, "gateway", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "7",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(Compute.Allocation, allocation.id).status == "draining"

    environment = Repo.get!(Compute.Environment, fixture.environment.id)

    assert {:ok, _draining_environment} =
             Compute.update_environment_intent(environment.id, environment.revision, %{
               desired_state: "draining"
             })

    current_allocation = Repo.get!(Compute.Allocation, allocation.id)
    current_command = Repo.get!(Compute.Command, command.id)
    assert current_allocation.status == "draining"
    assert current_command.id == command.id
    assert current_command.request_id == command.request_id
    assert current_command.target_revision == current_allocation.revision

    assert {:ok, :reissued} =
             Compute.refresh_due_release_obligation(command.id, DateTime.utc_now())

    command_id = command.id

    assert {:ok, %{id: ^command_id, payload: payload}} =
             AgentVMM.claim_registration_command(fixture.binding.provider_ref, "gateway", "2")

    assert payload["command_json"]["releaseAllocation"]["expectedRevision"] == 7

    assert :ok =
             AgentVMM.commit_registration_result(
               fixture.binding.provider_ref,
               "gateway",
               "2",
               command.id,
               "succeeded",
               %{
                 "result" => %{
                   "allocation" => %{"allocationId" => allocation.id, "revision" => "8"}
                 }
               }
             )

    assert Repo.get!(Compute.Allocation, allocation.id).status == "released"
  end

  test "a release command insert conflict rolls back the draining transition" do
    fixture = ready_fixture()
    command_id = "release:#{fixture.allocation.id}:#{fixture.allocation.generation}"

    assert {:ok, _conflict} =
             Compute.enqueue_command(%{
               id: command_id,
               allocation_id: fixture.allocation.id,
               workload_id: fixture.workload.id,
               request_id: "unrelated-command",
               kind: "observe",
               classification: "read_only",
               target_generation: fixture.allocation.generation,
               target_revision: fixture.allocation.revision,
               deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    assert {:error, :release_obligation_conflict} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert Repo.get!(Compute.Workload, fixture.workload.id).desired_state == "ready"
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"

    refute Repo.get_by(Compute.Command,
             release_incarnation: Compute.release_incarnation("allocation", 1)
           )
  end

  test "one-time release backfill inserts missing rows and adopts a single legacy identity" do
    fixture = ready_fixture()

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "draining"]
    )

    assert %{inserted: 1, issues: [], done?: true} =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    assert %{audited: 1, issues: [], done?: true} =
             ReleaseObligationBackfill.audit_page(nil, 100)

    Repo.delete_all(Compute.Command)
    Repo.update_all(Compute.Allocation, set: [status: "ready"])

    # Simulate a row stored before the expand migration. New writes are already
    # fenced by the NOT VALID constraint; only stored legacy rows need adoption.
    Repo.query!(
      "ALTER TABLE compute_commands DROP CONSTRAINT compute_commands_release_owner_shape"
    )

    legacy_result =
      try do
        result =
          Compute.enqueue_command(%{
            id: "legacy-release-attempt",
            allocation_id: fixture.allocation.id,
            workload_id: fixture.workload.id,
            request_id: "legacy-workload-release",
            kind: "allocation.release",
            classification: "desired_state",
            target_generation: fixture.allocation.generation,
            target_revision: fixture.allocation.revision,
            deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
          })

        case result do
          {:ok, command} ->
            Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
              set: [status: "succeeded", outcome: "succeeded"]
            )

          _ ->
            :ok
        end

        result
      after
        Repo.query!("""
        ALTER TABLE compute_commands
        ADD CONSTRAINT compute_commands_release_owner_shape
        CHECK (
          kind <> 'allocation.release'
          OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
        ) NOT VALID
        """)
      end

    assert {:ok, legacy} = legacy_result

    # Backfill covers every stored release command, including a succeeded
    # legacy command whose allocation is already terminal. It must repair the
    # owner shape without inventing a second release attempt.
    assert %{adopted: 1, issues: [], done?: true} =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    adopted = Repo.get!(Compute.Command, legacy.id)
    assert adopted.id == legacy.id
    assert adopted.request_id == legacy.request_id
    assert adopted.workload_id == nil
    assert adopted.release_incarnation == Compute.release_incarnation("allocation", 1)
    assert Repo.aggregate(Compute.Command, :count) == 1
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "released"

    assert %{audited: 1, issues: [], done?: true} =
             ReleaseObligationBackfill.audit_page(nil, 100)

    # The final zero-issue audit is strong enough for the later online
    # constraint validation. Roll the validation back so this test does not
    # mutate the shared migration contract for other test modules.
    assert {:error, :validated} =
             Repo.transaction(fn ->
               Repo.query!(
                 "ALTER TABLE compute_commands VALIDATE CONSTRAINT compute_commands_release_owner_shape"
               )

               assert [[true]] =
                        Repo.query!("""
                        SELECT convalidated
                        FROM pg_constraint
                        WHERE conname = 'compute_commands_release_owner_shape'
                        """).rows

               Repo.rollback(:validated)
             end)
  end

  test "release backfill restores one cancelled obligation to the due owner without reminting" do
    fixture = ready_fixture()

    assert {:ok, _} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    command = Repo.get_by!(Compute.Command, kind: "allocation.release")

    Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
      set: [status: "cancelled", outcome: "cancelled", next_attempt_at: nil]
    )

    assert %{restored: 1, issues: []} =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    restored = Repo.get!(Compute.Command, command.id)
    assert restored.id == command.id
    assert restored.request_id == command.request_id
    assert restored.status == "failed"
    assert restored.outcome == "failed"
    assert DateTime.compare(restored.next_attempt_at, DateTime.utc_now()) in [:lt, :eq]
    assert %{issues: []} = ReleaseObligationBackfill.audit_page(nil, 100)
  end

  test "release backfill and audit reject stale succeeded release evidence" do
    fixture = ready_fixture()

    assert {:ok, _} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    command = Repo.get_by!(Compute.Command, kind: "allocation.release")

    Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
      set: [status: "succeeded", outcome: "succeeded"]
    )

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      inc: [revision: 1]
    )

    assert %{issues: [%{reason: :invalid_release_obligation}]} =
             ReleaseObligationBackfill.audit_page(nil, 100)

    assert %{issues: [%{reason: :stale_succeeded_release_obligation}]} =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "draining"
  end

  test "a new drain adopts one exact mixed-version release row in place" do
    fixture = ready_fixture()

    Repo.query!(
      "ALTER TABLE compute_commands DROP CONSTRAINT compute_commands_release_owner_shape"
    )

    legacy =
      try do
        {:ok, command} =
          Compute.enqueue_command(%{
            id: "legacy-drain-release",
            allocation_id: fixture.allocation.id,
            workload_id: fixture.workload.id,
            request_id: "stable-legacy-request",
            kind: "allocation.release",
            classification: "desired_state",
            target_generation: fixture.allocation.generation,
            target_revision: fixture.allocation.revision,
            deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
          })

        command
      after
        Repo.query!("""
        ALTER TABLE compute_commands
        ADD CONSTRAINT compute_commands_release_owner_shape
        CHECK (
          kind <> 'allocation.release'
          OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
        ) NOT VALID
        """)
      end

    assert {:ok, _} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    adopted = Repo.get!(Compute.Command, legacy.id)
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert Repo.aggregate(Compute.Command, :count) == 1
    assert adopted.id == legacy.id
    assert adopted.request_id == legacy.request_id
    assert adopted.workload_id == nil

    assert adopted.release_incarnation ==
             Compute.release_incarnation(allocation.id, allocation.generation)

    assert adopted.target_revision == allocation.revision
  end

  test "a new drain rolls back when mixed-version release ownership is ambiguous" do
    fixture = ready_fixture()

    Repo.query!(
      "ALTER TABLE compute_commands DROP CONSTRAINT compute_commands_release_owner_shape"
    )

    try do
      for suffix <- ["a", "b"] do
        assert {:ok, _} =
                 Compute.enqueue_command(%{
                   id: "legacy-ambiguous-release-#{suffix}",
                   allocation_id: fixture.allocation.id,
                   workload_id: fixture.workload.id,
                   request_id: "legacy-ambiguous-request-#{suffix}",
                   kind: "allocation.release",
                   classification: "desired_state",
                   target_generation: fixture.allocation.generation,
                   target_revision: fixture.allocation.revision,
                   deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
                 })
      end
    after
      Repo.query!("""
      ALTER TABLE compute_commands
      ADD CONSTRAINT compute_commands_release_owner_shape
      CHECK (
        kind <> 'allocation.release'
        OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
      ) NOT VALID
      """)
    end

    assert {:error, :release_obligation_conflict} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert Repo.get!(Compute.Workload, fixture.workload.id).desired_state == "ready"
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"
    assert Repo.aggregate(Compute.Command, :count) == 2

    Repo.delete!(Repo.get!(Compute.Command, "legacy-ambiguous-release-b"))

    Repo.query!(
      "ALTER TABLE compute_commands DROP CONSTRAINT compute_commands_release_owner_shape"
    )

    try do
      Repo.update_all(
        from(c in Compute.Command, where: c.id == "legacy-ambiguous-release-a"),
        set: [target_generation: fixture.allocation.generation + 1]
      )
    after
      Repo.query!("""
      ALTER TABLE compute_commands
      ADD CONSTRAINT compute_commands_release_owner_shape
      CHECK (
        kind <> 'allocation.release'
        OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
      ) NOT VALID
      """)
    end

    assert {:error, :release_obligation_conflict} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"
  end

  test "release backfill audits failed allocations and fails closed on duplicate legacy rows" do
    fixture = ready_fixture()

    Repo.query!(
      "ALTER TABLE compute_commands DROP CONSTRAINT compute_commands_release_owner_shape"
    )

    try do
      now = DateTime.utc_now()

      base = %{
        allocation_id: fixture.allocation.id,
        workload_id: fixture.workload.id,
        operation_id: "legacy-failed-release",
        target_ref: fixture.workload.id,
        kind: "allocation.release",
        classification: "desired_state",
        target_generation: fixture.allocation.generation,
        target_revision: fixture.allocation.revision,
        connection_epoch: "0",
        status: "failed",
        outcome: "failed",
        payload: %{},
        evidence: %{},
        deadline_at: DateTime.add(now, 60, :second),
        release_incarnation: nil,
        next_attempt_at: nil,
        attempt_count: 0,
        created_at: now,
        updated_at: now
      }

      Repo.insert_all(Compute.Command, [
        Map.merge(base, %{id: "legacy-failed-release", request_id: "legacy-failed-release"}),
        Map.merge(base, %{
          id: "legacy-duplicate-release",
          request_id: "legacy-duplicate-release",
          operation_id: "legacy-duplicate-release"
        })
      ])
    after
      Repo.query!("""
      ALTER TABLE compute_commands
      ADD CONSTRAINT compute_commands_release_owner_shape
      CHECK (
        kind <> 'allocation.release'
        OR (release_incarnation IS NOT NULL AND workload_id IS NULL)
      ) NOT VALID
      """)
    end

    Repo.update_all(Compute.Allocation, set: [status: "failed"])

    assert %{issues: [%{reason: :duplicate_release_obligations}]} =
             ReleaseObligationBackfill.audit_page(nil, 100)

    assert %{issues: [%{reason: :duplicate_release_obligations}]} =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    Repo.delete!(Repo.get!(Compute.Command, "legacy-duplicate-release"))

    assert %{adopted: 1, issues: []} =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    repaired = Repo.get!(Compute.Command, "legacy-failed-release")
    assert repaired.status == "failed"
    assert repaired.workload_id == nil
    assert repaired.release_incarnation == Compute.release_incarnation("allocation", 1)
    assert %{issues: []} = ReleaseObligationBackfill.audit_page(nil, 100)
  end

  test "release retry selects its bounded due owner row independently of unrelated history" do
    fixture = ready_fixture()

    assert {:ok, _stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "terminal")

    release = Repo.get_by!(Compute.Command, kind: "allocation.release")
    now = DateTime.utc_now()

    assert {:error, :release_requires_commit} =
             AgentVMM.record_result(release.id, "succeeded", %{"bypass" => true})

    assert {:error, :release_requires_commit} =
             Compute.record_command_result(
               release.id,
               ["pending"],
               "succeeded",
               %{"bypass" => true}
             )

    assert Repo.get!(Compute.Command, release.id).status == "pending"

    unrelated =
      for number <- 1..96 do
        id = "unrelated-failed-#{number}"

        %{
          id: id,
          allocation_id: fixture.allocation.id,
          workload_id: fixture.workload.id,
          request_id: id,
          operation_id: id,
          target_ref: fixture.workload.id,
          kind: "observe",
          classification: "read_only",
          target_generation: release.target_generation,
          target_revision: release.target_revision,
          connection_epoch: "1",
          status: "failed",
          outcome: "failed",
          payload: %{},
          evidence: %{},
          deadline_at: DateTime.add(now, -1, :second),
          next_attempt_at: nil,
          attempt_count: 0,
          created_at: now,
          updated_at: now
        }
      end

    assert {96, nil} = Repo.insert_all(Compute.Command, unrelated)

    Repo.update_all(from(c in Compute.Command, where: c.id == ^release.id),
      set: [deadline_at: DateTime.add(now, -1, :second)]
    )

    assert {:ok, %{settled: 1, release_retries: 0}} =
             AgentVMM.settle_expired_commands(32, now)

    assert {:ok, %{settled: 0, release_retries: 1, release_blocked: 0}} =
             AgentVMM.settle_expired_commands(32, DateTime.add(now, 6, :second))

    retried = Repo.get!(Compute.Command, release.id)
    assert retried.id == release.id
    assert retried.request_id == release.request_id
    assert retried.attempt_count == 1
    assert Repo.aggregate(from(c in Compute.Command, where: c.kind == "observe"), :count) == 96
  end

  test "only Agent VMM writes and owns allocation release obligations" do
    agent = ready_fixture()

    assert {:ok, _} =
             Compute.stop_workload(agent.workload.id, agent.workload.revision, "terminal")

    agent_release = Repo.get_by!(Compute.Command, kind: "allocation.release")
    now = DateTime.utc_now()

    Repo.update_all(from(c in Compute.Command, where: c.id == ^agent_release.id),
      set: [
        status: "failed",
        outcome: "failed",
        next_attempt_at: DateTime.add(now, -1, :second)
      ]
    )

    Repo.update_all(from(p in Compute.Pool, where: p.id == ^agent.pool.id),
      set: [provider_policy: %{"providers" => ["agent_vmm", "cloudflare"]}]
    )

    {:ok, environment} =
      Compute.create_environment(%{
        id: "non-agent-environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "non-agent-project",
        pool_id: agent.pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "non-agent-binding",
        pool_id: agent.pool.id,
        environment_id: environment.id,
        provider: "cloudflare",
        provider_ref: "cloudflare-provider",
        generation: environment.generation
      })

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "available"]
    )

    {:ok, allocation} =
      Compute.allocate(%{
        id: "non-agent-allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: environment.generation
      })

    {:ok, allocation} =
      Compute.observe_allocation(
        allocation.id,
        allocation.revision,
        allocation.generation,
        "ready",
        "succeeded"
      )

    {:ok, workload} =
      Compute.create_workload(%{
        id: "non-agent-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: environment.generation
      })

    assert {:ok, _} = Compute.stop_workload(workload.id, workload.revision, "terminal")

    refute Repo.get_by(Compute.Command,
             allocation_id: allocation.id,
             kind: "allocation.release"
           )

    # A mixed-version/non-product row can be the first Command owner row, but
    # point validation clears its due marker so it cannot permanently starve
    # the following legal Agent VMM obligation.
    non_agent_incarnation = Compute.release_incarnation(allocation.id, allocation.generation)

    non_agent_row =
      agent_release
      |> Map.take(Compute.Command.__schema__(:fields))
      |> Map.merge(%{
        id: "non-agent-release",
        allocation_id: allocation.id,
        workload_id: nil,
        request_id: non_agent_incarnation,
        operation_id: "non-agent-release",
        target_ref: allocation.id,
        target_generation: allocation.generation,
        target_revision: Repo.get!(Compute.Allocation, allocation.id).revision,
        status: "failed",
        outcome: "failed",
        release_incarnation: non_agent_incarnation,
        next_attempt_at: DateTime.add(now, -2, :second),
        created_at: DateTime.add(now, -2, :second),
        updated_at: DateTime.add(now, -2, :second)
      })

    assert {1, nil} = Repo.insert_all(Compute.Command, [non_agent_row])

    assert %{
             issues: [
               %{
                 allocation_id: "non-agent-allocation",
                 reason: :unsupported_provider_release_obligation
               }
             ]
           } =
             ReleaseObligationBackfill.audit_page(nil, 100)

    assert %{
             issues: [
               %{
                 allocation_id: "non-agent-allocation",
                 reason: :unsupported_provider_release_obligation
               }
             ]
           } =
             ReleaseObligationBackfill.backfill_page(nil, 100)

    assert {:ok, %{release_retries: 0, release_blocked: 1, more?: true}} =
             AgentVMM.settle_expired_commands(1, now)

    blocked = Repo.get!(Compute.Command, "non-agent-release")
    assert blocked.status == "failed"
    assert blocked.next_attempt_at == nil
    assert blocked.evidence["reason"] == "unsupported_provider"
    assert Repo.get!(Compute.Command, agent_release.id).status == "failed"

    assert {:ok, %{release_retries: 1, release_blocked: 0}} =
             AgentVMM.settle_expired_commands(1, DateTime.add(now, 1, :second))

    assert Repo.get!(Compute.Command, agent_release.id).status == "pending"
  end

  test "removing run-capacity waits preserves command identity, deadlines and storage actions" do
    %{environment: environment, allocation: allocation} = compute_fixture()

    {:ok, workload} =
      Compute.create_workload(%{
        id: "migration-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "shell",
        template_key: "shell.default",
        generation: 1
      })

    Code.require_file(
      "../priv/repo/migrations/20260916000100_remove_workload_run_capacity_queue.exs",
      __DIR__
    )

    version = 20_260_916_000_100
    migration = SalixStore.Repo.Migrations.RemoveWorkloadRunCapacityQueue

    migrate = fn ->
      Repo.query!("DELETE FROM salix_schema_migrations WHERE version = $1", [version])
      Ecto.Migrator.up(Repo, version, migration, strict_version_order: false, log: false)
    end

    Repo.query!(
      "ALTER TABLE compute_provider_bindings ADD COLUMN capacity_event_epoch bigint NOT NULL DEFAULT 0"
    )

    Repo.query!("""
    CREATE TABLE compute_capacity_queue (
      command_id text, workload_id text, generation bigint, reason text, status text
    )
    """)

    on_exit(fn ->
      if Repo.query!("SELECT to_regclass('compute_capacity_queue')").rows != [[nil]],
        do: migrate.()
    end)

    now = DateTime.utc_now()

    commands =
      for {id, deadline, generation} <- [
            {"waiting", DateTime.add(now, 300, :second), 1},
            {"expired", DateTime.add(now, -1, :second), 1},
            {"stale", DateTime.add(now, 300, :second), 2}
          ] do
        {:ok, command} =
          Compute.enqueue_command(%{
            id: id,
            request_id: id,
            allocation_id: allocation.id,
            workload_id: workload.id,
            kind: "allocation.ensure",
            classification: "desired_state",
            target_generation: 1,
            target_revision: allocation.revision,
            deadline_at: DateTime.add(now, 300, :second),
            payload: %{"accepted" => id}
          })

        Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
          set: [
            status: "failed",
            outcome: "failed",
            deadline_at: deadline,
            evidence: %{
              "result" => %{
                "reason" => "ERROR_REASON_CAPACITY_EXHAUSTED",
                "capacityDimension" => "CAPACITY_DIMENSION_RUN_SLOT"
              }
            }
          ]
        )

        Repo.query!(
          "INSERT INTO compute_capacity_queue VALUES ($1, $2, $3, 'queued_run_slot', 'queued')",
          [command.id, workload.id, generation]
        )

        command
      end

    for {generation, resource} <- [{1, "run_slot"}, {2, "storage_headroom"}] do
      Repo.insert!(%Compute.ReconcilerClaim{
        id: "claim-#{generation}",
        provider: "agent_vmm",
        workload_id: workload.id,
        generation: generation,
        claim_token: "parked",
        attempt_count: 1,
        last_error: %{"kind" => "action_required", "resource" => resource},
        created_at: now,
        updated_at: now
      })
    end

    assert :ok = migrate.()
    [waiting, expired, stale] = commands
    resumed = Repo.get!(Compute.Command, waiting.id)
    assert resumed.status == "pending"
    assert resumed.request_id == waiting.request_id
    assert resumed.deadline_at == waiting.deadline_at
    assert resumed.payload == waiting.payload
    assert Repo.get!(Compute.Command, expired.id).status == "failed"
    assert Repo.get!(Compute.Command, stale.id).status == "failed"
    claim = Repo.get!(Compute.ReconcilerClaim, "claim-1")
    assert claim.last_error == nil
    assert %DateTime{} = claim.next_retry_at
    storage = Repo.get!(Compute.ReconcilerClaim, "claim-2")
    assert storage.last_error["resource"] == "storage_headroom"
    assert storage.next_retry_at == nil
  end

  test "one creation request commits one placement under concurrency and keeps deliberate additional work" do
    fixture = compute_fixture()
    input = %{"environment_id" => fixture.environment.id, "kind" => "external_worker"}

    attrs = %{
      tenant_id: "tenant",
      environment_id: fixture.environment.id,
      kind: "external_worker",
      capability_requirements: ["runtime_exec"],
      creation_request_scope: "comma:project",
      creation_request_id: "same-intent",
      creation_request_input: input
    }

    results =
      1..8
      |> Task.async_stream(
        fn i ->
          Compute.place_requested_workload(
            Map.merge(attrs, %{
              allocation_id: "request-allocation-#{i}",
              workload_id: "request-workload-#{i}"
            })
          )
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, {:ok, placed}} -> placed end)

    assert results |> Enum.map(& &1.workload.id) |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(Compute.Workload, :count) == 1
    assert Repo.aggregate(Compute.Allocation, :count) == 2

    assert {:error, :idempotency_conflict} =
             Compute.place_requested_workload(
               Map.merge(attrs, %{
                 allocation_id: "conflicting-allocation",
                 workload_id: "conflicting-workload",
                 creation_request_input: Map.put(input, "kind", "shell")
               })
             )

    assert {:error, :not_found} =
             Compute.requested_workload("other-tenant", "comma:project", "same-intent")

    assert {:ok, another} =
             Compute.place_requested_workload(
               Map.merge(attrs, %{
                 allocation_id: "additional-allocation",
                 workload_id: "additional-workload",
                 creation_request_id: "another-intent"
               })
             )

    assert another.workload.id != hd(results).workload.id
    # Read retries do not re-place after a provider becomes unavailable.
    Repo.update_all(Compute.ProviderBinding, set: [status: "disabled"])

    assert {:ok, recovered} =
             Compute.place_requested_workload(
               Map.merge(attrs, %{
                 allocation_id: "retry-allocation",
                 workload_id: "retry-workload"
               })
             )

    assert recovered.workload.id == hd(results).workload.id
    assert Repo.aggregate(Compute.Allocation, :count) == 3
  end

  test "workload pages stay within the exact owner and include resources after the first page" do
    fixture = ready_fixture()

    for i <- 1..101 do
      assert {:ok, allocation} =
               Compute.allocate(%{
                 id: "page-allocation-#{i}",
                 environment_id: fixture.environment.id,
                 provider_binding_id: fixture.binding.id,
                 generation: 1
               })

      assert {:ok, _} =
               Compute.create_workload(%{
                 id: "page-workload-#{String.pad_leading(to_string(i), 3, "0")}",
                 environment_id: fixture.environment.id,
                 allocation_id: allocation.id,
                 kind: "external_worker",
                 generation: 1
               })
    end

    assert :ok =
             Compute.environment_in_scope("tenant", "project", "project", fixture.environment.id)

    assert {:error, :not_found} =
             Compute.environment_in_scope("tenant", "project", "other", fixture.environment.id)

    assert {:ok, first} = Compute.project_page("tenant", "project", "project", %{limit: 100})
    assert length(first.workloads) == 100

    assert {:ok, second} =
             Compute.project_page("tenant", "project", "project", %{
               limit: 100,
               workload_after: first.next_workload_cursor
             })

    assert length(second.workloads) == 2
    assert second.next_workload_cursor == nil
    assert first.environments == second.environments

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(first.workloads, & &1.id)),
             MapSet.new(Enum.map(second.workloads, & &1.id))
           )

    assert {:ok, other} = Compute.project_page("tenant", "project", "other", %{limit: 100})
    assert other.workloads == []

    assert {:error, :invalid} =
             Compute.project_page("tenant", "project", "project", %{limit: 101})
  end

  defp ready_fixture do
    fixture = compute_fixture()

    {:ok, allocation} =
      Compute.observe_allocation(fixture.allocation.id, 1, 1, "ready", "succeeded")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: fixture.environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: 1
      })

    Map.merge(fixture, %{allocation: allocation, workload: workload})
  end

  defp compute_fixture do
    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "default",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: String.duplicate("a", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    binding = Repo.get!(Compute.ProviderBinding, binding.id)

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    %{pool: pool, environment: environment, binding: binding, allocation: allocation}
  end

  defp resource_contract_within?(requested, ceiling) do
    requested["pid_max"] <= ceiling["pids"] and
      requested["writable_quota_bytes"] <= ceiling["disk_bytes"]
  end
end
