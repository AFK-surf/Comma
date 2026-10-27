defmodule SalixMeet.MeetingComputeCarrierTest do
  use SystemsClock.Case, async: false

  alias SalixMeet.MeetingComputeCarrier
  alias SalixStore.{Compute, ComputeRuntimeCarrier, Repo}

  setup do
    SalixStore.RepoTestSetup.ensure!()
    previous = SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret)

    SystemsRuntime.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("m", 40)
    )

    Repo.query!(
      "TRUNCATE compute_runtime_inputs, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    tenant_id = "meeting-tenant"
    meeting_id = "meeting-1"

    {:ok, pool} =
      Compute.create_pool(%{
        id: "meeting-pool",
        tenant_id: tenant_id,
        name: "meeting",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]},
        capabilities: ["runtime_exec", "runtime_process"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "meeting-environment",
        tenant_id: tenant_id,
        owner_type: "project",
        owner_id: "meeting-project",
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "meeting-binding",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: "meeting-provider"
      })

    {:ok, allocation} =
      Compute.allocate(%{
        id: "meeting-allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    identity =
      :crypto.hash(:sha256, tenant_id <> ":" <> meeting_id) |> Base.encode16(case: :lower)

    workload_id = "meeting_workload_" <> identity

    {:ok, workload} =
      Compute.create_workload(%{
        id: workload_id,
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "meeting_runtime",
        template_key: "meeting.meetnative",
        capability_requirements: ["runtime_exec", "runtime_process"],
        generation: 1
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "meeting-runtime",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    %{environment: environment, runtime: runtime, workload: workload, tenant_id: tenant_id}
  end

  test "dispatches typed join through the current caught-up runtime", fixture do
    payload = %{
      "tenant_id" => fixture.tenant_id,
      "compute_environment_id" => fixture.environment.id,
      "meeting_id" => "meeting-1",
      "attempt" => "1",
      "runtime_token" => "meeting-business-token"
    }

    assert {:ok, %{"accepted" => true, "frame_type" => "meeting.join"}} =
             MeetingComputeCarrier.join(payload)

    input =
      Repo.get_by!(ComputeRuntimeCarrier.Input,
        source_dispatch_id: "meeting.join:meeting-1:1",
        workload_id: fixture.workload.id
      )

    assert input.runtime_instance_id == fixture.runtime.id
    assert input.connection_epoch == "1"
    assert input.payload["frame_type"] == "meeting.join"
    assert input.payload["payload"]["runtime_token"] == "meeting-business-token"

    assert Repo.get!(Compute.Workload, fixture.workload.id).owner_ref ==
             %{"kind" => "meeting", "id" => "meeting-1"}

    assert {:ok, %{"accepted" => true}} =
             MeetingComputeCarrier.join(
               Map.merge(payload, %{
                 "join_dispatch_generation" => "replacement-claim",
                 "runtime_target" => %{"source" => "compute_workload"},
                 "runtime_rejections" => [%{"source" => "connected_runtime"}]
               })
             )

    assert Repo.aggregate(ComputeRuntimeCarrier.Input, :count, :id) == 1

    assert {:error, :meeting_join_already_accepted} =
             MeetingComputeCarrier.release_unaccepted(payload)

    assert {:ok, :unavailable} = MeetingComputeCarrier.session_status(payload)
  end

  test "a retryable join failure keeps its Workload, and watchdog terminal state stops it",
       fixture do
    alias SalixMeet.Store
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    if is_nil(Process.whereis(SalixStore.S3.Fake)), do: start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3) end)
    now = SystemsClock.system_time(:millisecond)

    {:ok, _, _} =
      Store.create_once("meeting-1",
        state: %{
          "tenant_id" => fixture.tenant_id,
          "runtime_source" => "compute_workload",
          "workload_id" => fixture.workload.id,
          "compute_environment_id" => fixture.environment.id,
          "status" => "joining",
          "end_at" => div(now, 1000) - Store.watchdog_cutoff_s() - 1
        }
      )

    {:ok, :claimed, _, _, _} =
      Store.claim_join_dispatch("meeting-1", %{"generation" => "first", "claimed_by" => "test"})

    assert {:ok, _, _} = Store.checkpoint_join_dispatch("meeting-1", "first", {:failed, :timeout})
    assert Repo.get!(Compute.Workload, fixture.workload.id).desired_state == "ready"
    {:ok, generation} = Store.claim_watchdog_probe("meeting-1", "test")
    assert {:ok, _, _} = Store.mark_runtime_lost("meeting-1", generation: generation)
    assert Repo.get!(Compute.Workload, fixture.workload.id).desired_state == "stopped"
  end

  test "terminal stops the workload and stale frames are rejected", fixture do
    payload = %{
      "tenant_id" => fixture.tenant_id,
      "compute_environment_id" => fixture.environment.id,
      "meeting_id" => "meeting-1",
      "attempt" => "1"
    }

    assert {:ok, %{"accepted" => true}} = MeetingComputeCarrier.join(payload)

    assert {:ok, stopped} =
             MeetingComputeCarrier.terminal(Map.put(payload, "workload_id", fixture.workload.id))

    assert stopped.business_terminal_owned_by == "SalixMeet.Meeting"
    assert stopped.workload.desired_state == "stopped"
    assert {:error, :meeting_workload_terminal} = MeetingComputeCarrier.join(payload)

    assert {:ok, :not_found} =
             MeetingComputeCarrier.terminal(%{
               "tenant_id" => fixture.tenant_id,
               "meeting_id" => "never-started"
             })

    assert Repo.aggregate(Compute.Workload, :count) == 1
  end

  test "an existing Meeting Workload keeps its original Environment and provider binding",
       fixture do
    {:ok, other} =
      Compute.create_environment(%{
        id: "another-meeting-environment",
        tenant_id: fixture.tenant_id,
        owner_type: "project",
        owner_id: "another-project",
        pool_id: fixture.environment.pool_id
      })

    payload = %{
      "tenant_id" => fixture.tenant_id,
      "meeting_id" => "meeting-1",
      "compute_environment_id" => other.id
    }

    assert {:error, :meeting_workload_placement_conflict} =
             MeetingComputeCarrier.ensure_workload(payload)

    assert {:error, :meeting_workload_placement_conflict} =
             MeetingComputeCarrier.ensure_workload(
               %{payload | "compute_environment_id" => fixture.environment.id}
               |> Map.put("compute_provider_binding_id", "another-binding")
             )

    assert Repo.get!(Compute.Workload, fixture.workload.id).environment_id ==
             fixture.environment.id

    assert Repo.aggregate(Compute.Workload, :count) == 1
    refute Repo.exists?(ComputeRuntimeCarrier.Input)
  end

  test "Compute cleanup failure keeps the terminal commit and later delivery retries it",
       fixture do
    alias SalixMeet.Store
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    if is_nil(Process.whereis(SalixStore.S3.Fake)), do: start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3) end)

    {:ok, _, etag} =
      Store.create_once("meeting-1",
        state: %{
          "tenant_id" => fixture.tenant_id,
          "runtime_source" => "compute_workload",
          "workload_id" => fixture.workload.id,
          "status" => "active"
        }
      )

    # Compute owns an in-progress transition and cannot take this stop yet.
    Repo.update_all(Compute.Workload, set: [desired_state: "draining"])

    assert {:ok, %{"state" => %{"status" => "done"}}, _} =
             Store.update_state("meeting-1", etag, &Map.put(&1, "status", "done"))

    assert {:ok, :delivery, _, _, _} = Store.claim_terminal_work("meeting-1", "delivery")
    assert Repo.get!(Compute.Workload, fixture.workload.id).desired_state == "draining"
    Repo.update_all(Compute.Workload, set: [desired_state: "ready"])
    assert {:error, :not_claimable} = Store.claim_terminal_work("meeting-1", "delivery")
    assert Repo.get!(Compute.Workload, fixture.workload.id).desired_state == "stopped"
  end

  test "assigns each chat message its own durable dispatch identity", fixture do
    base = %{
      "tenant_id" => fixture.tenant_id,
      "compute_environment_id" => fixture.environment.id,
      "meeting_id" => "meeting-1",
      "attempt" => "1"
    }

    first_payload = Map.merge(base, %{"message_id" => "message-1", "text" => "first"})
    second_payload = Map.merge(base, %{"message_id" => "message-2", "text" => "second"})

    assert {:ok, %{"accepted" => true}} = MeetingComputeCarrier.send_chat(first_payload)
    assert {:ok, %{"accepted" => true}} = MeetingComputeCarrier.send_chat(second_payload)

    assert Repo.aggregate(ComputeRuntimeCarrier.Input, :count, :id) == 2

    first =
      Repo.get_by!(ComputeRuntimeCarrier.Input,
        source_dispatch_id: "meeting.chat:meeting-1:1:message-1",
        workload_id: fixture.workload.id
      )

    second =
      Repo.get_by!(ComputeRuntimeCarrier.Input,
        source_dispatch_id: "meeting.chat:meeting-1:1:message-2",
        workload_id: fixture.workload.id
      )

    assert first.payload["payload"]["text"] == "first"
    assert second.payload["payload"]["text"] == "second"

    assert {:ok, %{"accepted" => true}} = MeetingComputeCarrier.send_chat(first_payload)

    assert {:error, :dispatch_id_conflict} =
             MeetingComputeCarrier.send_chat(%{first_payload | "text" => "changed"})
  end
end
