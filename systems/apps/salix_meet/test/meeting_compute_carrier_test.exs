defmodule SalixMeet.MeetingComputeCarrierTest do
  use ExUnit.Case, async: false

  alias SalixMeet.MeetingComputeCarrier
  alias SalixStore.{Compute, ComputeRuntimeCarrier, Repo}

  setup do
    SalixStore.RepoTestSetup.ensure!()
    previous = Application.get_env(:salix_store, :compute_workload_credential_secret)

    Application.put_env(
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
        do: Application.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: Application.delete_env(:salix_store, :compute_workload_credential_secret)
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
