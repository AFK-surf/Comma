defmodule SalixStore.ComputeRuntimeCarrierTest do
  use SystemsClock.Case, async: false
  import Ecto.Query

  alias SalixStore.{Compute, ComputeRuntimeCarrier, Crypto, Repo}
  alias SalixWeb.ComputeRuntimeSocket

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret)

    SystemsRuntime.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("s", 40)
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    Repo.query!(
      "TRUNCATE compute_runtime_inputs, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "carrier",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]},
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

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: "cloudflare"
      })

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "meeting_runtime",
        capability_requirements: ["runtime_exec"],
        generation: 1
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")

    {:ok, credential} =
      Compute.WorkloadCredential.issue_for_runtime(workload.id, runtime.id, ["runtime"], 60)

    %{workload: workload, runtime: runtime, credential: credential}
  end

  test "opens one feature-negotiated carrier and advances its durable kind cursor", fixture do
    {:ok, bootstrap} =
      Compute.WorkloadCredential.issue_for_runtime(
        fixture.workload.id,
        fixture.runtime.id,
        ["bootstrap"],
        60
      )

    handshake = %{
      "protocol_version" => 1,
      "supported_features" => [
        "runtime.input.v1",
        "runtime.event.v1",
        "runtime.auth.v1",
        "runtime.execution.v1",
        "runtime.future.v9"
      ],
      "input_cursor" => "",
      "event_cursor" => ""
    }

    assert {:error, :required_runtime_feature_missing} =
             Compute.open_runtime_carrier(
               bootstrap["token"],
               Map.put(handshake, "supported_features", ["runtime.event.v1"])
             )

    assert {:ok, opened} =
             Compute.open_runtime_carrier(bootstrap["token"], handshake)

    assert opened.features == [
             "runtime.input.v1",
             "runtime.event.v1",
             "runtime.execution.v1",
             "runtime.auth.v1"
           ]

    assert opened.input_cursor == ""
    assert opened.event_cursor == ""
    refute Map.has_key?(opened.credential, "expires_at")

    assert %{status: "connected", readiness: "ready"} =
             Repo.get!(Compute.RuntimeInstance, fixture.runtime.id)

    assert {:ok, reopened} =
             Compute.open_runtime_carrier(opened.credential["token"], handshake)

    assert reopened.credential["token"] == opened.credential["token"]

    assert {:ok, _} =
             submit(fixture.runtime, "1", %{
               "dispatch_id" => "handshake-input",
               "runtime_capability_token" => opened.credential["token"]
             })

    assert {:ok, [input]} =
             ComputeRuntimeCarrier.claim_inputs(
               fixture.runtime.id,
               "1",
               nil,
               1
             )

    assert {:ok, _} =
             ComputeRuntimeCarrier.ack(
               input["id"],
               fixture.runtime.id,
               "1"
             )

    assert Repo.get!(Compute.RuntimeInstance, fixture.runtime.id).event_cursor == input["id"]
  end

  @tag :runtime_recovery
  test "late bootstrap cannot restore a retired execution identity", fixture do
    {:ok, stale} =
      Compute.WorkloadCredential.issue_for_runtime(
        fixture.workload.id,
        fixture.runtime.id,
        ["bootstrap"],
        60
      )

    assert {:ok, _} =
             Compute.prepare_runtime_bootstrap(%{
               id: fixture.runtime.id,
               workload_id: fixture.workload.id,
               allocation_id: fixture.runtime.allocation_id,
               generation: 1,
               connection_epoch: "2"
             })

    {:ok, current} =
      Compute.WorkloadCredential.issue_for_runtime(
        fixture.workload.id,
        fixture.runtime.id,
        ["bootstrap"],
        60
      )

    assert {:ok, _} = Compute.open_runtime_carrier(current["token"], handshake())
    assert {:error, :stale_epoch} = Compute.open_runtime_carrier(stale["token"], handshake())

    assert %{connection_epoch: "2", bootstrap_consumed_epoch: "2", readiness: "ready"} =
             Repo.get!(Compute.RuntimeInstance, fixture.runtime.id)
  end

  @tag :runtime_recovery
  test "same execution reconnect preserves unacknowledged input and bootstrap consumption",
       fixture do
    {:ok, bootstrap} =
      Compute.WorkloadCredential.issue_for_runtime(
        fixture.workload.id,
        fixture.runtime.id,
        ["bootstrap"],
        60
      )

    assert {:ok, opened} = Compute.open_runtime_carrier(bootstrap["token"], handshake())

    assert {:ok, _} =
             submit(fixture.runtime, "1", %{
               "dispatch_id" => "lost-ack",
               "runtime_capability_token" => opened.credential["token"]
             })

    assert {:ok, [input]} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 1)
    assert {:ok, _} = Compute.mark_provider_connection_lost("binding")

    assert %{status: "connected", readiness: "ready"} =
             Repo.get!(Compute.RuntimeInstance, fixture.runtime.id)

    assert {:ok, resumed} = Compute.open_runtime_carrier(opened.credential["token"], handshake())
    assert resumed.runtime.connection_epoch == "1"
    assert resumed.runtime.bootstrap_consumed_epoch == "1"
    assert Repo.get!(ComputeRuntimeCarrier.Input, input["id"]).status == "in_flight"
    assert {:ok, _} = ComputeRuntimeCarrier.ack(input["id"], fixture.runtime.id, "1")
    assert {:ok, []} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 1)
  end

  @tag :runtime_recovery
  test "replacement does not replay an input whose execution is unresolved", fixture do
    assert {:ok, _} =
             submit(fixture.runtime, "1", %{
               "dispatch_id" => "unknown-execution",
               "runtime_capability_token" => fixture.credential["token"]
             })

    assert {:ok, [input]} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 1)

    assert {:error, :runtime_execution_unresolved} =
             Compute.prepare_runtime_bootstrap(%{
               id: fixture.runtime.id,
               workload_id: fixture.workload.id,
               allocation_id: fixture.runtime.allocation_id,
               generation: 1,
               connection_epoch: "2"
             })

    assert Repo.get!(Compute.RuntimeInstance, fixture.runtime.id).connection_epoch == "1"
    assert Repo.get!(ComputeRuntimeCarrier.Input, input["id"]).status == "in_flight"
  end

  defp handshake do
    %{
      "protocol_version" => 1,
      "supported_features" => [
        "runtime.input.v1",
        "runtime.event.v1",
        "runtime.auth.v1",
        "runtime.execution.v1"
      ],
      "input_cursor" => "",
      "event_cursor" => ""
    }
  end

  test "requires caught-up current epoch and persists before acknowledging; retries are idempotent",
       fixture do
    payload = %{
      "dispatch_id" => "dispatch-1",
      "runtime_capability_token" => fixture.credential["token"],
      "session_id" => "session",
      "input_messages" => [%{"role" => "user", "content" => "run"}]
    }

    assert {:ok, first} = submit(fixture.runtime, "1", payload)
    assert first["accepted"] == true
    assert first["input_status"] == "pending"
    assert Repo.aggregate(ComputeRuntimeCarrier.Input, :count, :id) == 1

    assert {:ok, second} = submit(fixture.runtime, "1", payload)
    assert second["dispatch_id"] == first["dispatch_id"]
    assert Repo.aggregate(ComputeRuntimeCarrier.Input, :count, :id) == 1

    assert {:error, :dispatch_id_conflict} =
             submit(fixture.runtime, "1", Map.put(payload, "session_id", "different-session"))

    assert {:error, :stale_runtime_capability} =
             submit(fixture.runtime, "2", payload)
  end

  test "old epoch cannot acknowledge a current input", fixture do
    payload = %{
      "dispatch_id" => "dispatch-2",
      "runtime_capability_token" => fixture.credential["token"]
    }

    assert {:ok, _} = submit(fixture.runtime, "1", payload)

    {:ok, reconnected} =
      Compute.observe_runtime(%{
        id: fixture.runtime.id,
        workload_id: fixture.workload.id,
        allocation_id: fixture.runtime.allocation_id,
        generation: fixture.workload.generation,
        connection_epoch: "2"
      })

    {:ok, _reconnected} =
      Compute.complete_runtime_catch_up(reconnected.id, reconnected.revision, "2")

    assert {:error, :invalid_workload_credential} =
             Compute.WorkloadCredential.verify_for_runtime(
               fixture.credential["token"],
               fixture.workload.id,
               fixture.runtime.id,
               fixture.workload.generation,
               "runtime"
             )

    assert {:error, :stale_runtime_input} =
             ComputeRuntimeCarrier.ack(
               "compute-input-" <> hash_for("dispatch-2"),
               fixture.runtime.id,
               "1"
             )

    assert Repo.get_by(ComputeRuntimeCarrier.Input, source_dispatch_id: "dispatch-2").status ==
             "pending"
  end

  @tag :workload_update
  test "workload update retains new inputs while replaying and settling already claimed work",
       fixture do
    attrs = fn id ->
      %{"dispatch_id" => id, "runtime_capability_token" => fixture.credential["token"]}
    end

    assert {:ok, _} = submit(fixture.runtime, "1", attrs.("before-update"))
    assert {:ok, [claimed]} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 10)

    Repo.update_all(Compute.Workload, set: [runtime_update: %{"phase" => "draining"}])
    assert {:ok, _} = submit(fixture.runtime, "1", attrs.("during-update"))

    assert {:ok, [replayed]} =
             ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 10)

    assert replayed["id"] == claimed["id"]
    assert {:ok, _} = ComputeRuntimeCarrier.ack(claimed["id"], fixture.runtime.id, "1")
    assert {:ok, []} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 10)

    assert {:ok, _} =
             Compute.prepare_runtime_bootstrap(%{
               id: fixture.runtime.id,
               workload_id: fixture.workload.id,
               allocation_id: fixture.runtime.allocation_id,
               generation: 1,
               connection_epoch: "2"
             })

    assert {:error, _} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 10)

    assert {:ok, runtime} =
             Compute.observe_runtime(%{
               id: fixture.runtime.id,
               workload_id: fixture.workload.id,
               allocation_id: fixture.runtime.allocation_id,
               generation: 1,
               connection_epoch: "2"
             })

    assert {:ok, _} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "2")
    Repo.update_all(Compute.Workload, set: [runtime_update: %{"phase" => "complete"}])
    assert {:ok, [pending]} = ComputeRuntimeCarrier.claim_inputs(runtime.id, "2", nil, 10)
    assert pending["dispatch_id"] == "during-update"
    assert Repo.get!(ComputeRuntimeCarrier.Input, claimed["id"]).status == "acked"
  end

  test "scopes a caller dispatch id to its workload", fixture do
    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation-2",
        environment_id: "environment",
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, allocation} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload-2",
        environment_id: "environment",
        allocation_id: allocation.id,
        kind: "meeting_runtime",
        capability_requirements: ["runtime_exec"],
        generation: 1
      })

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime-2",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {:ok, runtime} = Compute.complete_runtime_catch_up(runtime.id, runtime.revision, "1")

    {:ok, credential} =
      Compute.WorkloadCredential.issue_for_runtime(workload.id, runtime.id, ["runtime"], 60)

    first_payload = %{
      "dispatch_id" => "same-caller-id",
      "runtime_capability_token" => fixture.credential["token"]
    }

    second_payload = %{
      "dispatch_id" => "same-caller-id",
      "runtime_capability_token" => credential["token"]
    }

    assert {:ok, _} = submit(fixture.runtime, "1", first_payload)
    assert {:ok, _} = submit(runtime, "1", second_payload)
    assert Repo.aggregate(ComputeRuntimeCarrier.Input, :count, :id) == 2

    assert {:error, :stale_runtime_input} =
             ComputeRuntimeCarrier.ack(
               "compute-input-" <> hash_for("same-caller-id"),
               fixture.runtime.id,
               "1"
             )

    assert {:ok, [claimed]} =
             ComputeRuntimeCarrier.claim_inputs(
               fixture.runtime.id,
               "1",
               nil,
               1
             )

    assert claimed["dispatch_id"] == "same-caller-id"

    assert {:ok, first_ack} =
             ComputeRuntimeCarrier.ack(
               claimed["id"],
               fixture.runtime.id,
               "1"
             )

    assert first_ack.runtime_instance_id == fixture.runtime.id

    assert {:ok, [claimed]} =
             ComputeRuntimeCarrier.claim_inputs(
               runtime.id,
               "1",
               nil,
               1
             )

    assert claimed["dispatch_id"] == "same-caller-id"

    assert {:ok, second_ack} =
             ComputeRuntimeCarrier.ack(
               claimed["id"],
               runtime.id,
               "1"
             )

    assert second_ack.runtime_instance_id == runtime.id
  end

  test "a deletion fence rejects new frames while previously accepted pending inputs can settle",
       fixture do
    payload = %{
      "dispatch_id" => "accepted-before-delete",
      "runtime_capability_token" => fixture.credential["token"],
      "session_id" => "session"
    }

    assert {:ok, _} = submit(fixture.runtime, "1", payload)

    from(w in Compute.Workload, where: w.id == ^fixture.workload.id)
    |> Repo.update_all(
      set: [
        desired_state: "draining",
        deletion: %{"phase" => "settling_work", "request_id" => "delete"}
      ]
    )

    assert {:error, :stale_runtime_capability} =
             submit(fixture.runtime, "1", Map.put(payload, "dispatch_id", "after-delete"))

    assert Repo.aggregate(ComputeRuntimeCarrier.Input, :count, :id) == 1

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^fixture.runtime.id),
      set: [status: "disconnected", readiness: "catching_up", caught_up_epoch: "0"]
    )

    assert {:ok, resumed} = Compute.open_runtime_carrier(fixture.credential["token"], handshake())
    assert resumed.runtime.id == fixture.runtime.id
    assert resumed.runtime.status == "connected"
    assert resumed.runtime.caught_up_epoch == "1"

    assert {:error, _} =
             Compute.WorkloadCredential.verify_for_runtime(
               fixture.credential["token"],
               fixture.workload.id,
               fixture.runtime.id,
               1,
               "runtime"
             )

    assert {:ok, [claimed]} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 32)

    assert {:ok, [replayed]} =
             ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 32)

    assert replayed["id"] == claimed["id"]
    assert {:ok, settled} = ComputeRuntimeCarrier.ack(claimed["id"], fixture.runtime.id, "1")
    assert settled.status == "acked"

    assert {:ok, []} = ComputeRuntimeCarrier.claim_inputs(fixture.runtime.id, "1", nil, 32)
  end

  test "a terminal stop revokes runtime admission before accepting no further frames", fixture do
    payload = %{
      "dispatch_id" => "terminal-dispatch",
      "runtime_capability_token" => fixture.credential["token"]
    }

    assert {:ok, _} = submit(fixture.runtime, "1", payload)

    assert {:ok, stopped} =
             Compute.stop_workload(fixture.workload.id, fixture.workload.revision, "done")

    assert stopped.desired_state == "stopped"

    runtime = Repo.get!(Compute.RuntimeInstance, fixture.runtime.id)
    assert runtime.status == "closed"
    assert runtime.readiness == "pending"

    assert {:error, :invalid_workload_credential} =
             Compute.WorkloadCredential.verify_for_runtime(
               fixture.credential["token"],
               fixture.workload.id,
               fixture.runtime.id,
               fixture.workload.generation,
               "runtime"
             )

    assert {:error, :stale_runtime_capability} =
             submit(fixture.runtime, "1", payload)
  end

  test "accepts bounded product prompts larger than the legacy 128 KiB limit", fixture do
    payload = %{
      "dispatch_id" => "large-product-prompt",
      "runtime_capability_token" => fixture.credential["token"],
      "system_prompt" => String.duplicate("p", 256 * 1024)
    }

    assert {:ok, _} = submit(fixture.runtime, "1", payload)

    assert {:error, :runtime_input_too_large} =
             submit(
               fixture.runtime,
               "1",
               Map.merge(payload, %{
                 "dispatch_id" => "oversized-product-prompt",
                 "system_prompt" => String.duplicate("p", 4 * 1024 * 1024)
               })
             )
  end

  defp hash_for(dispatch_id) do
    :crypto.hash(:sha256, fixture_workload_id() <> ":1:" <> dispatch_id)
    |> Base.encode16(case: :lower)
  end

  defp submit(runtime, epoch, payload) do
    ComputeRuntimeCarrier.submit(runtime.id, epoch, payload)
  end

  defp fixture_workload_id, do: "workload"
end
