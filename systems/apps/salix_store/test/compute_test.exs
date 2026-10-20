defmodule SalixStore.ComputeTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

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

  # The application's settlement sweeper settles every due Agent VMM Command
  # in the database whenever its timer fires; these tests drive
  # `AgentVMM.settle_expired_commands/2` themselves and assert what each call
  # settles, so a sweep between two of those calls would take their Commands.
  # A sweep already under way finishes first.
  setup_all do
    case SystemsRuntime.Proc.whereis(SalixStore.AgentVMMSettlementSweeper) do
      pid when SystemsRuntime.Proc.is_process(pid) ->
        :ok = :sys.suspend(pid, :infinity)
        on_exit(fn -> if SystemsRuntime.Proc.alive?(pid), do: :sys.resume(pid, :infinity) end)

      nil ->
        :ok
    end

    :ok
  end

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

  test "disposable reset advances only the exact stopped carrier generation and retains unknown claims" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    target = "cf-standard-1:reset-owner"

    {:ok, _, :created} =
      Compute.ensure_group_workload(%{
        "tenant_id" => tenant,
        "group_id" => group,
        "provider" => "cloudflare",
        "provider_resource_id" => "reset-owner",
        "provider_resource_name" => "reset-owner",
        "provider_spec" => %{"profile_key" => "cf-standard-1"},
        "status" => "waking",
        "archive" => %{"operation" => "saved-source"},
        "wake_operation_id" => "old-wake"
      })

    {:ok, opened} = Compute.prepare_cloudflare_control(group, target, :open)
    {:ok, "unknown"} = Compute.begin_cloudflare_gateway_attempt(group, "unknown", :normal, target)

    for n <- 1..62 do
      assert {:ok, _} =
               Compute.begin_cloudflare_gateway_attempt(group, "managed-#{n}", :normal, target, %{
                 "action" => "import"
               })
    end

    {:ok, "other"} =
      Compute.begin_cloudflare_gateway_attempt(group, "other", :normal, "cf-standard-2:other")

    assert {:error, :cloudflare_gateway_attempt_limit} =
             Compute.begin_cloudflare_gateway_attempt(group, "full", :normal, target, %{
               "action" => "observe"
             })

    {:ok, _, _} =
      Compute.update_group_workload(group, fn current ->
        Map.put(current, "provider_migration", %{
          "phase" => "preparing",
          "operation" => "provider-cutover"
        })
      end)

    {:ok, migrating} = Compute.group_workload(group)

    assert {:error, :provider_migration_in_progress} =
             Compute.begin_cloudflare_discard(group, migrating)

    assert {:ok, ^migrating} = Compute.group_workload(group)
    {:ok, _, _} = Compute.update_group_workload(group, &Map.delete(&1, "provider_migration"))
    {:ok, before} = Compute.group_workload(group)
    {:ok, resetting} = Compute.begin_cloudflare_discard(group, before)
    control = resetting["cloudflare_control"]
    assert control["sealed"]
    assert control["revision"] > opened["revision"]
    assert resetting["generation"] == before["generation"]

    assert {:error, :cloudflare_discard_in_progress} =
             Compute.prepare_cloudflare_control(
               group,
               target,
               :seal,
               Map.take(before, ~w(workload_id generation))
             )

    assert {:error, :cloudflare_discard_in_progress} =
             Compute.begin_cloudflare_gateway_attempt(
               group,
               "competing-destroy",
               :archive,
               target,
               %{
                 "action" => "destroy",
                 "expected_owner" => Map.take(before, ~w(workload_id generation))
               }
             )

    assert {:ok, ^resetting} = Compute.group_workload(group)

    assert {:error, :cloudflare_discard_target_changed} =
             Compute.begin_cloudflare_discard(group, before)

    terminal =
      Map.merge(control, %{
        "claim_id" => control["operation_id"],
        "action" => "destroy",
        "outcome" => "completed"
      })

    observation = %{
      "running" => false,
      "managed_commands_settled" => true,
      "control" => Map.merge(control, %{"pending" => nil, "last_terminal" => terminal})
    }

    assert {:error, :cloudflare_discard_unconfirmed} =
             Compute.finish_cloudflare_discard(
               group,
               resetting,
               Map.put(observation, "running", true)
             )

    assert {:error, :cloudflare_discard_unconfirmed} =
             Compute.finish_cloudflare_discard(
               group,
               resetting,
               put_in(observation, ["control", "last_terminal", "claim_id"], "another-destroy")
             )

    {:ok, discarded} = Compute.finish_cloudflare_discard(group, resetting, observation)
    assert discarded["generation"] == before["generation"] + 1
    assert discarded["last_discarded_generation"] == before["generation"]
    assert discarded["status"] == "archived"
    assert discarded["archive"] == nil
    assert discarded["archive_previous"] == before["archive"]
    assert discarded["active_operations"]["unknown"] == before["active_operations"]["unknown"]
    assert discarded["active_operations"]["other"] == before["active_operations"]["other"]
    assert Map.keys(discarded["active_operations"]) |> Enum.sort() == ["other", "unknown"]
    assert discarded["workload_id"] == before["workload_id"]

    assert {:error, :cloudflare_discard_target_changed} =
             Compute.finish_cloudflare_discard(group, resetting, observation)

    {:ok, next_control} = Compute.prepare_cloudflare_control(group, target, :open)
    assert next_control["generation"] == discarded["generation"]

    old_owner = Map.take(before, ~w(workload_id generation))

    assert {:error, :stale_generation} =
             Compute.prepare_cloudflare_control(group, target, :seal, old_owner)

    assert {:error, :stale_generation} =
             Compute.begin_cloudflare_gateway_attempt(group, "late-import", :normal, target, %{
               "action" => "import",
               "expected_owner" => old_owner
             })

    assert {:ok, "new-observe"} =
             Compute.begin_cloudflare_gateway_attempt(group, "new-observe", :normal, target, %{
               "action" => "observe"
             })

    assert :ok = Compute.settle_cloudflare_terminal(group, target, observation)
    {:ok, current} = Compute.group_workload(group)
    assert current["active_operations"]["new-observe"]["generation"] == next_control["generation"]
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
        SystemsRuntime.Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL lock_timeout = '5s'")
            Repo.query!(migration.backfill_sql())
            Repo.query!(migration.backfill_gateway_claims_sql())
          end)
        end)

      assert SystemsRuntime.Task.yield(task, 100) == nil
      Postgrex.query!(lock_connection, "COMMIT", [])
      assert {:ok, {:ok, _}} = SystemsRuntime.Task.yield(task, 5_000)

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
               kind: "meeting_runtime"
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

  test "a Group's Cloud VM on an Agent VMM Host is the station image on the tenant's own Host" do
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "group-host",
        tenant_id: tenant,
        group_id: group,
        device_id: "host-device",
        enrollment_token: String.duplicate("h", 32)
      })

    facts = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "provider" => "agent_vmm",
      "provider_resource_id" => registration.id,
      "provider_resource_name" => "cloud-vm-resource",
      "provider_spec" => %{"profile_key" => "vmm-station-1"},
      "env_id" => "cloud-vm-env",
      "device_id" => "cloud-vm-device",
      "connector_id" => "cloud-vm-connector",
      "status" => "creating",
      "created_at" => 1234
    }

    # A Host that is not connected cannot take the Group's Cloud VM yet.
    assert {:error, :provider_unavailable} = Compute.ensure_group_workload(facts)
    refute Repo.exists?(from(w in Compute.Workload, where: w.template_key == "station.default"))

    # The Host connects: its hello made its Project's binding available.
    connection = %{"connection_epoch" => "41", "gateway_instance_id" => "gateway-a"}
    connect_host!(tenant, registration.id, connection)

    assert {:ok, record, :created} = Compute.ensure_group_workload(facts)
    assert record["provider"] == "agent_vmm"
    assert record["device_id"] == "cloud-vm-device"
    assert {:ok, ^record, :existing} = Compute.ensure_group_workload(facts)

    workload = Repo.get!(Compute.Workload, record["workload_id"])
    assert workload.template_key == "station.default"
    assert workload.spec["group_default"] == true
    assert workload.spec["runtime_artifact"]["class"] == "station"
    assert workload.runtime_revision == workload.spec["runtime_artifact"]["manifest_digest"]
    assert {:ok, %{"class" => "station"}} = RuntimeBundleCatalog.image_for_workload(workload)

    allocation = Repo.get!(Compute.Allocation, workload.allocation_id)
    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
    assert {binding.provider, binding.provider_ref} == {"agent_vmm", registration.id}
    assert binding.status == "available"
    assert binding.observation == connection

    # The station connects only while the Group still names this Host and profile.
    resource = %{"name" => "cloud-vm-resource", "profile_key" => "vmm-station-1"}

    assert :admitted =
             Compute.with_group_provider(group, "agent_vmm", resource, fn -> :admitted end)

    assert {:error, :managed_provider_changed} =
             Compute.with_group_provider(group, "cloudflare", resource, fn -> :admitted end)

    other_group = SalixStore.Ids.new_group_id(SalixStore.Ids.new_tenant_id())

    assert {:error, :agent_vmm_registration_not_found} =
             Compute.ensure_group_workload(%{
               facts
               | "tenant_id" => SalixStore.Ids.tenant_id_from_group!(other_group),
                 "group_id" => other_group
             })
  end

  # A Host whose current connection made its Project Environment's binding available.
  defp connect_host!(tenant, registration_id, observation) do
    {:ok, pool} =
      Compute.create_pool(%{
        id: "host-pool-" <> registration_id,
        tenant_id: tenant,
        name: "Host",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "host-project-" <> registration_id,
        tenant_id: tenant,
        owner_type: "project",
        owner_id: "project-" <> registration_id,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "host-binding-" <> registration_id,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration_id
      })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration_id),
      set: [status: "ready", desired_enabled: true]
    )

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "available", observation: observation]
    )
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

  test "agent vmm managed pool owns per-workload isolation limits" do
    {:ok, pool} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")
    policy = pool.capacity["agent_vmm_remote_policy"]

    per_environment = policy["per_environment_limits"]

    for key <- RuntimeBundleCatalog.keys() do
      assert {:ok, template} = RuntimeBundleCatalog.resolve(key, root: @runtime_bundle_root)
      assert resource_contract_within?(template.resources, per_environment)
    end

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

    # The enrolled Host of environment-a is not connected yet. environment-b
    # has no Host in its scope at all.
    for {environment_id, reason} <- [
          {"environment-a", :node_offline},
          {"environment-b", :capacity_unavailable}
        ] do
      assert {:error, ^reason} =
               Compute.place_workload(%{
                 tenant_id: "tenant",
                 allocation_id: "unobserved-#{environment_id}",
                 workload_id: "unobserved-workload-#{environment_id}",
                 environment_id: environment_id,
                 kind: "meeting_runtime"
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
               kind: "meeting_runtime"
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
               kind: "meeting_runtime"
             })

    assert placed.allocation.provider_binding_id == binding.id

    assert {:ok, _totals} = AgentVMM.mark_connection_lost(registration.id, "gateway", "1")

    assert {:error, :node_offline} =
             Compute.place_workload(%{
               tenant_id: "tenant",
               allocation_id: "disconnected-allocation",
               workload_id: "disconnected-workload",
               environment_id: "environment-a",
               kind: "meeting_runtime"
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
               kind: "meeting_runtime",
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

  test "side effects become unknown while read and desired-state commands remain replayable" do
    fixture = ready_fixture()
    deadline = DateTime.add(SystemsClock.utc_now(), 60, :second)

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
               expires_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
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
               expires_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
             })

    assert Repo.get(Compute.Grant, "cross-environment-grant") == nil
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
               kind: "meeting_runtime"
             })

    assert Repo.get(Compute.Allocation, "stale-policy-allocation") == nil
    assert Repo.get(Compute.Allocation, "policy-allocation") == nil
    assert Repo.get(Compute.Workload, "policy-workload") == nil
  end

  test "provider binding rejects a registration owned by another tenant" do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

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
             Compute.refresh_due_release_obligation(command.id, SystemsClock.utc_now())

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
            deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
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
    assert DateTime.compare(restored.next_attempt_at, SystemsClock.utc_now()) in [:lt, :eq]
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
            deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
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
                   deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second)
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
      now = SystemsClock.utc_now()

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

    [[now]] = Repo.query!("SELECT clock_timestamp()").rows

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
            deadline_at: DateTime.add(SystemsClock.utc_now(), 300, :second),
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

        Repo.get!(Compute.Command, command.id)
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
    input = %{"environment_id" => fixture.environment.id, "kind" => "meeting_runtime"}

    attrs = %{
      tenant_id: "tenant",
      environment_id: fixture.environment.id,
      kind: "meeting_runtime",
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
                 kind: "meeting_runtime",
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

  test "Shell deletion closes admission and retains allocation authority until exact data cleanup" do
    fixture = compute_fixture()

    assert {:ok, workload} =
             Compute.create_workload(%{
               id: "shell",
               environment_id: fixture.environment.id,
               allocation_id: fixture.allocation.id,
               kind: "shell",
               template_key: "shell.default",
               generation: 1
             })

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [status: "ready", provider_observation: %{"allocation_revision" => 7}]
    )

    alias SalixStore.ComputeWorkloadDeletion, as: Deletion
    now = SystemsClock.utc_now()

    Repo.insert!(%AgentVMM.RegistrationObservation{
      registration_id: "registration",
      gateway_instance_id: "gateway",
      connection_epoch: "1",
      observation_sequence: 1,
      observed_at: now,
      received_at: now,
      protocol_version: "1",
      host_api_version: "1",
      health_status: "healthy",
      supported_features: ["allocation-disposal-v1"],
      capacity: %{},
      usage: %{},
      health_components: %{},
      inventory_watermark: 0,
      inventory_observed_at: now
    })

    assert {:error, :not_found} =
             Deletion.start("other", "project", workload.id, 1, 1, "request", fn -> :ok end)

    assert {:error, :not_found} =
             Deletion.start("tenant", "project", workload.id, 1, 1, "request", fn ->
               {:error, :revoked}
             end)

    assert {:error, :revision_conflict} =
             Deletion.start("tenant", "project", workload.id, 1, 2, "request", fn -> :ok end)

    assert {:ok, deleting} =
             Deletion.start("tenant", "project", workload.id, 1, 1, "request", fn -> :ok end)

    assert deleting.desired_state == "draining"
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"

    assert {:ok, replay} =
             Deletion.start("tenant", "project", workload.id, 1, 1, "request", fn -> :ok end)

    assert replay.deletion == deleting.deletion

    Repo.update_all(
      from(o in AgentVMM.RegistrationObservation, where: o.registration_id == "registration"),
      set: [disconnected_at: SystemsClock.utc_now()]
    )

    assert {:ok, %{command: pending}} = Deletion.advance(fixture.allocation, deleting)
    waiting = Repo.get!(Compute.Workload, workload.id)
    assert waiting.deletion["error"] == "original_device_offline"
    assert waiting.deletion["registration_id"] == "registration"
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"

    Repo.update_all(
      from(o in AgentVMM.RegistrationObservation, where: o.registration_id == "registration"),
      set: [disconnected_at: nil]
    )

    assert {:ok, %{command: command}} = Deletion.advance(fixture.allocation, waiting)
    assert command.id == pending.id
    assert Repo.get!(Compute.Workload, workload.id).deletion["error"] == nil
    assert {:ok, claimed} = AgentVMM.claim_registration_command("registration", "gateway", "1")
    assert claimed.id == command.id
    assert claimed.kind == "allocation.dispose"
    assert claimed.payload["command_json"]["disposeAllocation"]["expectedGeneration"] == 1

    evidence = %{
      "result" => %{
        "allocation" => %{
          "allocationId" => "allocation",
          "state" => "ALLOCATION_STATE_RETAINED",
          "generation" => "1",
          "revision" => "7"
        }
      }
    }

    assert {:error, :invalid_host_result} =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway",
               "1",
               command.id,
               "succeeded",
               evidence
             )

    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "ready"
    evidence = put_in(evidence, ["result", "allocation", "state"], "ALLOCATION_STATE_DISCARDED")

    assert :ok =
             AgentVMM.commit_registration_result(
               "registration",
               "gateway",
               "1",
               command.id,
               "succeeded",
               evidence
             )

    completed = Repo.get!(Compute.Workload, workload.id)
    assert completed.deletion["phase"] == "complete"
    assert completed.desired_state == "stopped"
    assert Repo.get!(Compute.Allocation, fixture.allocation.id).status == "released"

    assert {:ok, replay} =
             Deletion.start("tenant", "project", workload.id, 1, 1, "request", fn -> :ok end)

    assert replay.id == workload.id
  end

  test "Shell deletion rejects a shared allocation and business-owned workloads" do
    fixture = ready_fixture()
    alias SalixStore.ComputeWorkloadDeletion, as: Deletion

    assert {:error, :business_owner_required} =
             Deletion.start("tenant", "project", fixture.workload.id, 1, 1, "request", fn ->
               :ok
             end)

    assert {:ok, shell} =
             Compute.create_workload(%{
               id: "shell",
               environment_id: fixture.environment.id,
               allocation_id: fixture.allocation.id,
               kind: "shell",
               template_key: "shell.default",
               generation: 1
             })

    assert {:error, :shared_allocation} =
             Deletion.start("tenant", "project", shell.id, 1, 1, "request", fn -> :ok end)

    assert Repo.get!(Compute.Workload, shell.id).desired_state == "ready"
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
        kind: "meeting_runtime",
        generation: 1
      })

    Map.merge(fixture, %{allocation: allocation, workload: workload})
  end

  test "expired authorization fences authentication, existing connections, enable and placement before sweeping" do
    fixture = compute_fixture()
    credential = "original-credential"

    Repo.update_all(AgentVMM.Registration,
      set: [
        credential_hash: :crypto.hash(:sha256, credential),
        authorization_expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)
      ]
    )

    registration = Repo.get!(AgentVMM.Registration, "registration")

    assert {:error, :unauthorized} =
             AgentVMM.authenticate_registration(registration.id, credential)

    assert {:error, :unauthorized} =
             AgentVMM.claim_registration_command(registration.id, "gateway", "1")

    assert {:error, :revision_conflict} =
             AgentVMM.configure_registration(registration.id, registration.revision, true)

    assert {:error, :registration_inactive} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    assert {:error, :provider_unavailable} =
             Compute.allocate(%{
               id: "late-allocation",
               environment_id: fixture.environment.id,
               provider_binding_id: fixture.binding.id,
               generation: 1
             })

    assert {:ok, %{retired: 1}} = AgentVMM.expire_authorizations()
    expired = Repo.get!(AgentVMM.Registration, registration.id)
    assert expired.status == "revoked"

    assert {:error, :revision_conflict} =
             AgentVMM.configure_registration(expired.id, expired.revision, true)
  end

  test "authenticated contact renews seven days without depending on the disposable health projection" do
    compute_fixture()
    now = SystemsClock.utc_now()

    Repo.update_all(AgentVMM.Registration,
      set: [authorization_expires_at: DateTime.add(now, 60, :second)]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    registration = Repo.get!(AgentVMM.Registration, "registration")
    assert DateTime.diff(registration.authorization_expires_at, now) >= 7 * 86_400
    assert is_nil(Repo.get(AgentVMM.RegistrationObservation, registration.id))

    assert {:ok, %{retired: 0}} =
             AgentVMM.expire_authorizations(32, DateTime.add(now, 7 * 86_400 - 1, :second))

    assert {:ok, %{retired: 1}} =
             AgentVMM.expire_authorizations(32, DateTime.add(now, 7 * 86_400 + 1, :second))
  end

  test "cloud retirement preserves unknown work, business owners and physical evidence across bounded pages" do
    fixture = compute_fixture()

    {:ok, shell} =
      Compute.create_workload(%{
        id: "retired-shell",
        environment_id: "environment",
        allocation_id: fixture.allocation.id,
        kind: "shell",
        template_key: "shell.default",
        generation: 1
      })

    {:ok, business_allocation} =
      Compute.allocate(%{
        id: "business-allocation",
        environment_id: "environment",
        provider_binding_id: fixture.binding.id,
        generation: 1
      })

    {:ok, business} =
      Compute.create_workload(%{
        id: "retired-business",
        environment_id: "environment",
        allocation_id: business_allocation.id,
        kind: "meeting_runtime",
        owner_ref: %{"kind" => "meeting", "id" => "business-owner"},
        generation: 1
      })

    Repo.query!(
      "UPDATE compute_allocations SET operation_outcome='unknown_outcome' WHERE id=$1",
      [fixture.allocation.id]
    )

    deadline = DateTime.add(SystemsClock.utc_now(), 60, :second)

    {:ok, command} =
      Compute.enqueue_command(%{
        id: "sent-unknown",
        allocation_id: fixture.allocation.id,
        workload_id: shell.id,
        request_id: "sent-unknown",
        kind: "runtime.exec",
        classification: "side_effecting",
        target_generation: 1,
        target_revision: fixture.allocation.revision,
        deadline_at: deadline,
        payload: %{}
      })

    Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
      set: [status: "unknown_outcome", delivery_started_at: SystemsClock.utc_now()]
    )

    assert {:ok, _} = Compute.stop_workload(shell.id, shell.revision, "offline")

    release =
      Repo.get_by!(Compute.Command,
        release_incarnation: Compute.release_incarnation(fixture.allocation.id, 1)
      )

    release_evidence = %{"reason" => "lost_host_result", "original" => true}

    Repo.update_all(from(c in Compute.Command, where: c.id == ^release.id),
      set: [
        status: "unknown_outcome",
        outcome: "unknown_outcome",
        evidence: release_evidence,
        delivery_started_at: SystemsClock.utc_now(),
        next_attempt_at: DateTime.add(SystemsClock.utc_now(), -1, :second)
      ]
    )

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^fixture.allocation.id),
      set: [operation_outcome: "unknown_outcome"]
    )

    registration = Repo.get!(AgentVMM.Registration, "registration")

    assert {:ok, _} =
             AgentVMM.revoke_registration("tenant", registration.id, registration.revision)

    assert {:ok, %{after_id: cursor}} = SalixStore.ComputeWorkloadDeletion.retire_revoked(4)
    assert cursor.level == :workload
    assert cursor.w in [business.id, shell.id]
    assert {:ok, _} = SalixStore.ComputeWorkloadDeletion.retire_revoked(32, cursor)
    retired = Repo.get!(Compute.Workload, shell.id)
    assert retired.deletion["phase"] == "cloud_retired"
    assert retired.deletion["local_data_deleted"] == false
    assert retired.observed_state == shell.observed_state
    assert Repo.get!(Compute.Command, command.id).status == "unknown_outcome"
    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)
    assert allocation.operation_outcome == "unknown_outcome"
    assert {:ok, %{release_retries: 0, release_settled: 0}} = AgentVMM.settle_expired_commands()
    preserved = Repo.get!(Compute.Command, release.id)
    assert preserved.status == "unknown_outcome"
    assert preserved.outcome == "unknown_outcome"
    assert preserved.evidence == release_evidence
    assert is_nil(preserved.next_attempt_at)

    assert allocation.provider_observation["cloud_retired"]
    assert allocation.provider_observation["data_deleted"] != true
    surviving = Repo.get!(Compute.Workload, business.id)
    assert is_nil(surviving.deletion)
    assert surviving.owner_ref == business.owner_ref
    assert surviving.observed_state == business.observed_state
    assert {:ok, %{after_id: ""}} = SalixStore.ComputeWorkloadDeletion.retire_revoked()
    assert Repo.get!(Compute.Workload, shell.id).revision == retired.revision
    assert Repo.get!(Compute.Workload, business.id).revision == surviving.revision
    assert Repo.get!(Compute.Allocation, allocation.id).revision == allocation.revision
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
