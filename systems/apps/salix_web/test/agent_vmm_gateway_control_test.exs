defmodule SalixWeb.AgentVMMGatewayControlTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias SalixStore.{AgentVMM, Compute, PersonalMeshProto, Repo}

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @secret String.duplicate("control-", 4)
  @token String.duplicate("enroll-", 4)
  @connection_epoch "9223372036854775808"

  setup do
    previous = Application.get_env(:salix_web, :agent_vmm_gateway_control_secret)
    previous_signer = Application.get_env(:salix_store, :personal_mesh_registry_receipt_signer)
    previous_managed = Application.get_env(:salix_store, :agent_vmm_managed_trust_signing)
    Application.put_env(:salix_web, :agent_vmm_gateway_control_secret, @secret)
    {_receipt_public, receipt_private} = keypair()

    Application.put_env(:salix_store, :personal_mesh_registry_receipt_signer, fn payload ->
      {"registry-key", sign(payload, receipt_private)}
    end)

    {managed_public, managed_private} = keypair()

    Application.put_env(:salix_store, :agent_vmm_managed_trust_signing, %{
      authority_prefix: "salix-managed",
      key_id: "managed-key",
      key_revision: 1,
      public_key: compress_public_key(managed_public),
      signer: &sign(&1, managed_private)
    })

    Repo.query!(
      "TRUNCATE agent_vmm_route_capabilities, agent_vmm_membership_credentials, agent_vmm_trust_anchors, agent_vmm_audit_events, agent_vmm_sessions, agent_vmm_registrations, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    {:ok, _} =
      AgentVMM.create_registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        enrollment_token: @token
      })

    {:ok, _} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "Agent VMM",
        region: "local",
        capabilities: ["runtime_exec"],
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    {:ok, _} =
      Compute.create_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: "pool"
      })

    {:ok, _} =
      Compute.create_provider_binding(%{
        id: "binding",
        pool_id: "pool",
        environment_id: "environment",
        provider: "agent_vmm",
        provider_ref: "registration"
      })

    on_exit(fn ->
      put_or_delete_env(:salix_web, :agent_vmm_gateway_control_secret, previous)
      put_or_delete_env(:salix_store, :personal_mesh_registry_receipt_signer, previous_signer)
      put_or_delete_env(:salix_store, :agent_vmm_managed_trust_signing, previous_managed)
    end)

    :ok
  end

  test "one-time enrollment, credential auth, and opaque connection fencing" do
    enroll = %{
      "protocolVersion" => "remote.v1",
      "registrationId" => "registration",
      "enrollmentToken" => Base.encode64(@token),
      "supportedFeatures" => ["session-v1"],
      "deviceIdentity" => %{
        "deviceId" => "device",
        "rootPublicKey" => Base.encode64(:binary.copy(<<1>>, 33)),
        "rootKeyRevision" => "1",
        "signatureSuite" => "SIGNATURE_SUITE_P256_SHA256"
      }
    }

    response = request("/v1/compute/enroll", %{"request_b64" => encode_json(enroll)})
    assert response.status == 200
    envelope = response.resp_body |> Jason.decode!() |> Map.fetch!("response_b64")
    enrollment_response = envelope |> Base.decode64!() |> Jason.decode!()
    credential = Map.fetch!(enrollment_response, "credential")

    assert enrollment_response["trustAnchor"]["authority"]["authorityClass"] ==
             "AUTHORITY_CLASS_MANAGED_CONTROLLER"

    assert enrollment_response["membershipCredential"]["subjectDeviceId"] == "device"

    rejected = request("/v1/compute/enroll", %{"request_b64" => encode_json(enroll)})
    assert rejected.status == 403
    assert Jason.decode!(rejected.resp_body)["reason"] == "invalid_enrollment"

    assert request("/v1/compute/authenticate", %{
             "registration_id" => "registration",
             "credential_b64" => credential
           }).status == 200

    rejected_credential =
      request("/v1/compute/authenticate", %{
        "registration_id" => "registration",
        "credential_b64" => Base.encode64("wrong credential")
      })

    assert rejected_credential.status == 401

    assert Jason.decode!(rejected_credential.resp_body)["error"] ==
             "registration_credential_rejected"

    hello = %{
      "registrationId" => "registration",
      "connectionEpoch" => "7",
      "inventoryWatermark" => "4",
      "inventory" => []
    }

    assert request("/v1/compute/connections/observe", %{"hello_b64" => encode_json(hello)}).status ==
             200

    binding = Repo.one!(Compute.ProviderBinding)
    assert binding.observation["gateway_instance_id"] == "gateway-a"
    assert binding.observation["connection_epoch"] == "7"

    replacement = put_in(hello["connectionEpoch"], "2")

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" => encode_json(replacement)
           }).status == 200

    assert Repo.one!(Compute.ProviderBinding).observation["connection_epoch"] == "2"

    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond) |> Integer.to_string()

    observation = %{
      "sequence" => "2",
      "observedUnixMillis" => now,
      "protocolVersion" => "1",
      "hostApiVersion" => "host.v1",
      "supportedFeatures" => [],
      "capacity" => %{},
      "health" => %{"status" => "healthy", "components" => []},
      "usage" => %{"stale" => false},
      "inventoryWatermark" => "4",
      "inventoryObservedUnixMillis" => now
    }

    renewal = %{"connectionEpoch" => "2", "observation" => observation}

    assert request("/v1/compute/connections/observation", %{
             "registration_id" => "registration",
             "renewal_b64" => encode_json(renewal)
           }).status == 200

    stored = Repo.get!(AgentVMM.RegistrationObservation, "registration")
    assert stored.observation_sequence == 2
    assert stored.health_status == "healthy"

    assert request("/v1/compute/connections/observation", %{
             "registration_id" => "registration",
             "renewal_b64" => encode_json(renewal)
           }).status == 409

    assert request("/v1/compute/connections/observation", %{
             "registration_id" => "registration",
             "renewal_b64" => encode_json(put_in(renewal["connectionEpoch"], "7"))
           }).status == 409

    oversized_observation =
      renewal
      |> put_in(["observation", "sequence"], "3")
      |> put_in(["observation", "supportedFeatures"], Enum.map(1..65, &"feature-#{&1}"))

    assert request("/v1/compute/connections/observation", %{
             "registration_id" => "registration",
             "renewal_b64" => encode_json(oversized_observation)
           }).status == 422

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" => encode_json(replacement)
           }).status == 409

    assert request("/v1/compute/commands/claim", %{
             "registration_id" => "registration",
             "connection_epoch" => "2"
           }).status == 204

    for invalid <- ["0", "01", "18446744073709551616", 3] do
      invalid_hello = put_in(hello["connectionEpoch"], invalid)

      assert request("/v1/compute/connections/observe", %{
               "hello_b64" => encode_json(invalid_hello)
             }).status == 422
    end
  end

  test "managed enrollment reports a finite signer failure without consuming the token" do
    Application.delete_env(:salix_store, :agent_vmm_managed_trust_signing)

    enroll = %{
      "protocolVersion" => "remote.v1",
      "registrationId" => "registration",
      "enrollmentToken" => Base.encode64(@token),
      "supportedFeatures" => ["session-v1"],
      "deviceIdentity" => %{
        "deviceId" => "device",
        "rootPublicKey" => Base.encode64(:binary.copy(<<1>>, 33)),
        "rootKeyRevision" => "1",
        "signatureSuite" => "SIGNATURE_SUITE_P256_SHA256"
      }
    }

    first = request("/v1/compute/enroll", %{"request_b64" => encode_json(enroll)})
    second = request("/v1/compute/enroll", %{"request_b64" => encode_json(enroll)})

    assert first.status == 403
    assert second.status == 403
    assert Jason.decode!(first.resp_body)["reason"] == "managed_trust_signer_unavailable"
    assert Jason.decode!(second.resp_body)["reason"] == "managed_trust_signer_unavailable"
  end

  test "workload auth requires both secret and an explicit gateway identity" do
    conn =
      conn(:post, "/v1/compute/authenticate", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", @secret)
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))

    assert conn.status == 401
  end

  test "registration authentication reports a transient database fault as unavailable" do
    Repo.query!("ALTER TABLE agent_vmm_registrations RENAME TO agent_vmm_registrations_tmp")

    on_exit(fn ->
      Repo.query!("ALTER TABLE agent_vmm_registrations_tmp RENAME TO agent_vmm_registrations")
    end)

    response =
      request("/v1/compute/authenticate", %{
        "registration_id" => "registration",
        "credential_b64" => Base.encode64("credential")
      })

    assert response.status == 503

    assert Jason.decode!(response.resp_body)["error"] ==
             "registration_authentication_unavailable"
  end

  test "stale host inventory cannot revive an allocation after Environment drain" do
    Repo.update_all(AgentVMM.Registration,
      set: [status: "ready", desired_enabled: true]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "8",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "draining-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded")

    assert {:ok, _environment} =
             Compute.update_environment_intent(environment.id, environment.revision, %{
               desired_state: "draining"
             })

    assert Repo.get!(Compute.Allocation, allocation.id).status == "draining"

    hello = %{
      "registrationId" => "registration",
      "connectionEpoch" => "9",
      "inventoryWatermark" => "1",
      "inventory" => [
        %{"allocationId" => allocation.id, "revision" => "1", "state" => "ALLOCATION_STATE_READY"}
      ]
    }

    assert request("/v1/compute/connections/observe", %{"hello_b64" => encode_json(hello)}).status ==
             200

    stale = Repo.get!(Compute.Allocation, allocation.id)
    assert stale.status == "draining"
    assert stale.operation_outcome == "succeeded"

    release = claim_command!("9")
    assert Map.has_key?(release, "releaseAllocation")
    assert release["releaseAllocation"]["allocationId"] == allocation.id
  end

  test "a released allocation remains admissible without being revived" do
    Repo.update_all(AgentVMM.Registration,
      set: [status: "ready", desired_enabled: true]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "10",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "released-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, allocation} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "ready", "succeeded")

    {:ok, _released} =
      Compute.observe_allocation(allocation.id, allocation.revision, 1, "released", "succeeded")

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-b", %{
               "connectionEpoch" => "11",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => 3,
                   "state" => "ALLOCATION_STATE_RETAINED"
                 }
               ]
             })

    assert Repo.get!(Compute.Allocation, allocation.id).status == "released"

    assert Repo.get!(Compute.ProviderBinding, "binding").observation["admission"] ==
             "accepting"
  end

  test "a released allocation is terminal for workload, observation, reconciliation, and claim" do
    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "12",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "terminal-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
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
        id: "terminal-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: environment.generation
      })

    {:ok, released} =
      Compute.observe_allocation(
        allocation.id,
        allocation.revision,
        allocation.generation,
        "released",
        "succeeded"
      )

    assert {:error, :allocation_released} =
             Compute.create_workload(%{
               id: "revived-workload",
               environment_id: environment.id,
               allocation_id: released.id,
               kind: "external_worker",
               generation: environment.generation
             })

    assert {:error, :allocation_released} =
             Compute.observe_allocation(
               released.id,
               released.revision,
               released.generation,
               "ready",
               "succeeded"
             )

    assert {:error, :allocation_released} =
             SalixEnv.ComputeProviders.AgentVMM.reconcile(released, workload)

    assert {:error, :allocation_released} =
             Compute.enqueue_command(%{
               id: "terminal-command",
               allocation_id: released.id,
               workload_id: workload.id,
               request_id: "terminal-command",
               kind: "observe",
               classification: "read_only",
               target_generation: released.generation,
               target_revision: released.revision,
               payload: %{"workload_generation" => workload.generation},
               deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
             })

    now = DateTime.utc_now()

    assert {1, nil} =
             Repo.insert_all(Compute.Command, [
               %{
                 id: "mixed-version-terminal-command",
                 allocation_id: released.id,
                 workload_id: workload.id,
                 request_id: "mixed-version-terminal-command",
                 operation_id: "mixed-version-terminal-command",
                 target_ref: workload.id,
                 kind: "observe",
                 classification: "read_only",
                 target_generation: released.generation,
                 target_revision: released.revision,
                 connection_epoch: "12",
                 status: "pending",
                 outcome: "pending",
                 payload: %{
                   "workload_generation" => workload.generation,
                   "command_json" => %{"commandId" => "mixed-version-terminal-command"}
                 },
                 evidence: %{},
                 deadline_at: DateTime.add(now, 60, :second),
                 release_incarnation: nil,
                 next_attempt_at: nil,
                 attempt_count: 0,
                 created_at: now,
                 updated_at: now
               }
             ])

    assert request("/v1/compute/commands/claim", %{
             "registration_id" => "registration",
             "connection_epoch" => "12"
           }).status == 204

    assert Repo.get!(Compute.Command, "mixed-version-terminal-command").status == "pending"
  end

  test "discarded inventory settles only an existing exact release obligation" do
    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "14",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "discarded-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
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
        id: "discarded-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: environment.generation
      })

    assert {:ok, _} = Compute.stop_workload(workload.id, workload.revision, "terminal")
    draining = Repo.get!(Compute.Allocation, allocation.id)
    Repo.delete_all(from(c in Compute.Command, where: c.allocation_id == ^allocation.id))

    discarded_inventory = fn epoch, watermark ->
      request("/v1/compute/connections/observe", %{
        "hello_b64" =>
          encode_json(%{
            "registrationId" => "registration",
            "connectionEpoch" => epoch,
            "inventoryWatermark" => watermark,
            "inventory" => [
              %{
                "allocationId" => allocation.id,
                "revision" => "9",
                "state" => "ALLOCATION_STATE_DISCARDED"
              }
            ]
          })
      })
    end

    assert discarded_inventory.("15", 1).status == 422
    assert Repo.get!(Compute.Allocation, allocation.id).status == "draining"
    refute Repo.get_by(Compute.Command, allocation_id: allocation.id)

    assert {:ok, :inserted} =
             Compute.backfill_release_obligation(allocation.id, DateTime.utc_now())

    obligation = Repo.get_by!(Compute.Command, allocation_id: allocation.id)
    assert obligation.target_revision == draining.revision
    assert discarded_inventory.("16", 1).status == 200

    released = Repo.get!(Compute.Allocation, allocation.id)
    settled = Repo.get!(Compute.Command, obligation.id)
    assert released.status == "released"
    assert settled.status == "succeeded"
    assert settled.evidence["reason"] == "authoritative_inventory_discarded"
  end

  test "same-generation stop remains immediately claimable after retained inventory" do
    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "17",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "retained-terminal-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
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
        id: "retained-terminal-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: environment.generation
      })

    assert {:ok, _} = Compute.stop_workload(workload.id, workload.revision, "terminal")
    obligation = Repo.get_by!(Compute.Command, allocation_id: allocation.id)

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" =>
               encode_json(%{
                 "registrationId" => "registration",
                 "connectionEpoch" => "18",
                 "inventoryWatermark" => 1,
                 "inventory" => [
                   %{
                     "allocationId" => allocation.id,
                     "revision" => "8",
                     "state" => "ALLOCATION_STATE_RETAINED"
                   }
                 ]
               })
           }).status == 200

    retained = Repo.get!(Compute.Allocation, allocation.id)
    synchronized = Repo.get!(Compute.Command, obligation.id)
    assert retained.status == "draining"
    assert retained.provider_observation["allocation_state"] == "retained"
    assert synchronized.target_revision == retained.revision

    claimed = claim_command!("18")
    assert claimed["commandId"] == obligation.id
    assert Map.has_key?(claimed, "releaseAllocation")
  end

  test "identical authoritative inventory advances only connection observation" do
    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-bootstrap", %{
               "connectionEpoch" => "20",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "stable-inventory-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: environment.generation
      })

    {:ok, allocation} =
      Compute.observe_allocation(
        allocation.id,
        allocation.revision,
        allocation.generation,
        "ready",
        "succeeded",
        %{"allocation_revision" => 7, "allocation_state" => "ready"},
        merge_provider_observation: true
      )

    inventory = [
      %{
        "allocationId" => allocation.id,
        "revision" => "7",
        "state" => "ALLOCATION_STATE_READY"
      }
    ]

    for {epoch, watermark} <- [{"21", "1"}, {"22", "2"}] do
      assert request("/v1/compute/connections/observe", %{
               "hello_b64" =>
                 encode_json(%{
                   "registrationId" => "registration",
                   "connectionEpoch" => epoch,
                   "inventoryWatermark" => watermark,
                   "inventory" => inventory
                 })
             }).status == 200

      assert Repo.get!(Compute.Allocation, allocation.id).revision == allocation.revision
      binding = Repo.get!(Compute.ProviderBinding, "binding")
      assert binding.observation["connection_epoch"] == epoch
      assert binding.observation["inventory_watermark"] == String.to_integer(watermark)
    end

    changed = put_in(hd(inventory)["revision"], "8")

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" =>
               encode_json(%{
                 "registrationId" => "registration",
                 "connectionEpoch" => "23",
                 "inventoryWatermark" => "3",
                 "inventory" => [changed]
               })
           }).status == 200

    assert Repo.get!(Compute.Allocation, allocation.id).revision == allocation.revision + 1
  end

  test "a pending ensure cannot be claimed after its workload stops" do
    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => @connection_epoch,
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "stopped-ensure-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: environment.generation
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "stopped-ensure-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: resource_v2_spec(),
        generation: environment.generation
      })

    assert {:ok, %{outcome: :pending, command: command}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(allocation, workload, [])

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [generation: workload.generation + 1]
    )

    assert request("/v1/compute/commands/claim", %{
             "registration_id" => "registration",
             "connection_epoch" => @connection_epoch
           }).status == 204

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [generation: workload.generation]
    )

    assert {:ok, _stopped} = Compute.stop_workload(workload.id, workload.revision, "terminal")

    release = claim_command!()
    assert Map.has_key?(release, "releaseAllocation")
    assert release["commandId"] != command.id

    assert Repo.get!(Compute.Command, command.id).status == "pending"
  end

  test "a retired allocation obligation retries and releases only its exact reservation" do
    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-bootstrap", %{
               "connectionEpoch" => "30",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "terminal-release-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: environment.generation
      })

    {:ok, allocation} =
      Compute.observe_allocation(
        allocation.id,
        allocation.revision,
        allocation.generation,
        "ready",
        "succeeded",
        %{"allocation_revision" => 4, "allocation_state" => "ready"},
        merge_provider_observation: true
      )

    {:ok, workload} =
      Compute.create_workload(%{
        id: "terminal-release-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: environment.generation
      })

    assert {:ok, _stopped} = Compute.stop_workload(workload.id, workload.revision, "terminal")

    obligation =
      Repo.get_by!(Compute.Command,
        allocation_id: allocation.id,
        kind: "allocation.release"
      )

    assert obligation.workload_id == nil

    assert obligation.release_incarnation ==
             Compute.release_incarnation(allocation.id, allocation.generation)

    environment = Repo.get!(Compute.Environment, environment.id)

    assert {:ok, _draining_environment} =
             Compute.update_environment_intent(environment.id, environment.revision, %{
               desired_state: "draining"
             })

    environment = Repo.get!(Compute.Environment, environment.id)

    assert {:ok, ready_environment} =
             Compute.update_environment_intent(environment.id, environment.revision, %{
               desired_state: "ready"
             })

    {:ok, replacement} =
      Compute.allocate(%{
        id: "replacement-allocation",
        environment_id: ready_environment.id,
        provider_binding_id: "binding",
        generation: ready_environment.generation
      })

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
      set: [
        allocation_id: replacement.id,
        desired_state: "ready",
        observed_state: "ready",
        generation: ready_environment.generation
      ]
    )

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" =>
               encode_json(%{
                 "registrationId" => "registration",
                 "connectionEpoch" => "31",
                 "inventoryWatermark" => "1",
                 "inventory" => [
                   %{
                     "allocationId" => allocation.id,
                     "revision" => "5",
                     "state" => "ALLOCATION_STATE_RETAINED"
                   }
                 ]
               })
           }).status == 200

    retired = Repo.get!(Compute.Allocation, allocation.id)
    assert retired.status == "draining"
    assert retired.generation < ready_environment.generation

    Repo.update_all(from(c in Compute.Command, where: c.id == ^obligation.id),
      set: [deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    settle_at = DateTime.utc_now()

    assert {:ok, %{settled: 1}} =
             AgentVMM.settle_expired_commands(32, settle_at)

    assert {:ok, %{release_retries: 1}} =
             AgentVMM.settle_expired_commands(32, DateTime.add(settle_at, 6, :second))

    refreshed = Repo.get!(Compute.Command, obligation.id)

    assert refreshed.id == obligation.id
    assert refreshed.request_id == obligation.request_id
    assert refreshed.release_incarnation == obligation.release_incarnation
    assert refreshed.workload_id == nil
    assert refreshed.status == "pending"
    assert DateTime.compare(refreshed.deadline_at, DateTime.utc_now()) == :gt
    assert refreshed.target_generation == retired.generation
    assert refreshed.target_revision == retired.revision

    release_command = claim_command!("31")
    assert release_command["commandId"] == refreshed.id

    claimed = Repo.get!(Compute.Command, refreshed.id)
    assert claimed.status == "admitted"
    assert claimed.allocation_id == allocation.id
    assert claimed.target_generation == allocation.generation

    assert commit_command(release_command, "COMMAND_OUTCOME_SUCCEEDED").status == 200

    settled = Repo.get!(Compute.Command, refreshed.id)
    released = Repo.get!(Compute.Allocation, allocation.id)
    current = Repo.get!(Compute.Allocation, replacement.id)
    current_workload = Repo.get!(Compute.Workload, workload.id)

    assert settled.status == "succeeded"
    assert released.status == "released"
    assert released.generation == allocation.generation
    assert current.status == replacement.status
    assert current.generation == ready_environment.generation
    assert current_workload.allocation_id == current.id

    assert Repo.aggregate(
             from(c in Compute.Command,
               where: c.allocation_id == ^retired.id and c.kind == "allocation.release"
             ),
             :count
           ) == 1
  end

  test "revoked registration cannot re-observe its binding or claim pending work" do
    Repo.update_all(AgentVMM.Registration,
      set: [status: "ready", desired_enabled: true]
    )

    hello = %{
      "registrationId" => "registration",
      "connectionEpoch" => "7",
      "inventoryWatermark" => "1",
      "inventory" => []
    }

    assert request("/v1/compute/connections/observe", %{"hello_b64" => encode_json(hello)}).status ==
             200

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "revoked-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "revoked-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: resource_v2_spec(),
        capability_requirements: ["runtime_exec"],
        generation: 1
      })

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(allocation, workload, [])

    registration = Repo.get!(AgentVMM.Registration, "registration")

    assert {:ok, revoked} =
             AgentVMM.revoke_registration("tenant", registration.id, registration.revision)

    assert revoked.status == "revoked"
    assert Repo.get!(Compute.ProviderBinding, "binding").status == "revoked"

    reconnect = put_in(hello["connectionEpoch"], "8")

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" => encode_json(reconnect)
           }).status == 422

    assert Repo.get!(Compute.ProviderBinding, "binding").status == "revoked"

    assert request("/v1/compute/commands/claim", %{
             "registration_id" => "registration",
             "connection_epoch" => "7"
           }).status == 204

    assert Repo.all(Compute.Command) |> Enum.map(& &1.status) |> Enum.uniq() == ["pending"]

    assert Repo.all(Compute.Command) |> Enum.map(& &1.kind) |> Enum.sort() ==
             ["allocation.ensure", "allocation.release"]
  end

  test "allocation and Workload session close and reopen through the real control API" do
    Repo.update_all(AgentVMM.Registration,
      set: [status: "ready", desired_enabled: true]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: resource_v2_spec(),
        capability_requirements: ["runtime_exec"],
        generation: 1
      })

    hello = %{
      "registrationId" => "registration",
      "connectionEpoch" => @connection_epoch,
      "inventoryWatermark" => "1",
      "inventory" => []
    }

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" => encode_json(hello)
           }).status == 200

    assert Repo.get!(Compute.ProviderBinding, "binding").observation["connection_epoch"] ==
             @connection_epoch

    {:ok, credential} =
      Compute.WorkloadCredential.issue(workload.id, nil, ["runtime"], 300)

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(allocation, workload, [])

    ensure = claim_command!()
    assert ensure["connectionEpoch"] == @connection_epoch
    assert ensure["ensureAllocation"]["allocationId"] == allocation.id
    assert commit_command(ensure, "COMMAND_OUTCOME_SUCCEEDED").status == 200
    assert Repo.get!(Compute.Allocation, allocation.id).status == "ready"

    refreshed_epoch = "9223372036854775809"

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" =>
               encode_json(%{
                 hello
                 | "connectionEpoch" => refreshed_epoch,
                   "inventoryWatermark" => "2",
                   "inventory" => [
                     %{
                       "allocationId" => allocation.id,
                       "revision" => "5",
                       "state" => "ALLOCATION_STATE_READY"
                     }
                   ]
               })
           }).status == 200

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.bootstrap(allocation, workload, credential, [])

    open = claim_command!(refreshed_epoch)
    assert open["connectionEpoch"] == refreshed_epoch
    assert open["openSession"]["allocationGeneration"] == 1
    assert commit_command(open, "COMMAND_OUTCOME_SUCCEEDED").status == 200

    session_expires_unix_millis =
      Repo.get!(Compute.Command, open["commandId"]).evidence["result"]["sessionReady"][
        "expiresUnixMillis"
      ]

    Repo.update_all(Compute.Command,
      set: [deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.bootstrap(allocation, workload, credential, [])

    assert Repo.get!(Compute.Command, open["commandId"]).status == "succeeded"

    header = %{
      "registrationId" => "registration",
      "allocationId" => allocation.id,
      "allocationGeneration" => "1",
      "connectionEpoch" => refreshed_epoch,
      "tunnelNonce" => "host-tunnel-nonce",
      "expiresUnixMillis" => session_expires_unix_millis
    }

    assert request("/v1/compute/sessions/ready", %{"header_b64" => encode_json(header)}).status ==
             200

    assert {:ok, session} = AgentVMM.current_host_session_for_workload(workload.id)
    assert session.runtime_instance_id == "runtime:" <> workload.id
    assert session.connection_epoch == refreshed_epoch

    assert request("/v1/compute/connections/disconnected", %{
             "registration_id" => "registration",
             "connection_epoch" => refreshed_epoch
           }).status == 200

    reconnected_epoch = "9223372036854775810"

    assert request("/v1/compute/connections/observe", %{
             "hello_b64" =>
               encode_json(%{
                 hello
                 | "connectionEpoch" => reconnected_epoch,
                   "inventoryWatermark" => "3",
                   "inventory" => [
                     %{
                       "allocationId" => allocation.id,
                       "revision" => "6",
                       "state" => "ALLOCATION_STATE_READY"
                     }
                   ]
               })
           }).status == 200

    reconnected = Repo.get!(Compute.Allocation, allocation.id)

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.bootstrap(
               reconnected,
               workload,
               credential,
               []
             )

    reopened = claim_command!(reconnected_epoch)
    assert reopened["openSession"]["allocationGeneration"] == 1
    refute reopened["commandId"] == open["commandId"]
  end

  test "expired replayable command is reissued with a fresh attempt through the control API" do
    Repo.update_all(AgentVMM.Registration,
      set: [status: "ready", desired_enabled: true]
    )

    assert {:ok, :ok} =
             AgentVMM.observe_registration("registration", "gateway-a", %{
               "connectionEpoch" => @connection_epoch,
               "inventoryWatermark" => 1,
               "inventory" => []
             })

    environment = Repo.get!(Compute.Environment, "environment")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "retry-allocation",
        environment_id: environment.id,
        provider_binding_id: "binding",
        generation: 1
      })

    {:ok, workload} =
      Compute.create_workload(%{
        id: "retry-workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        spec: resource_v2_spec(),
        capability_requirements: ["runtime_exec"],
        generation: 1
      })

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(allocation, workload, [])

    first = claim_command!()
    first_id = first["commandId"]

    Repo.update_all(Compute.Command,
      set: [deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, %{settled: 1, more?: false}} =
             AgentVMM.settle_expired_commands(32, DateTime.utc_now())

    assert {:ok, %{outcome: :pending}} =
             SalixEnv.ComputeProviders.AgentVMM.allocate(allocation, workload, [])

    retry = claim_command!()
    refute retry["commandId"] == first_id
    assert Repo.get(Compute.Command, first_id) == nil
    assert commit_command(first, "COMMAND_OUTCOME_SUCCEEDED").status != 200
    assert Repo.get!(Compute.Command, retry["commandId"]).status == "admitted"
  end

  test "registry mutations terminate at the gateway control API and return signed protobuf snapshots" do
    {root_public_uncompressed, root_private} = keypair()
    root_public = compress_public_key(root_public_uncompressed)
    root_b64 = Base.encode64(root_public)
    created_at = DateTime.utc_now()
    expires_at = DateTime.add(created_at, 600, :second)
    expires = DateTime.to_iso8601(expires_at)

    descriptor_canonical =
      PersonalMeshProto.personal_mesh_descriptor_signing_input(%{
        mesh_id: "mesh",
        genesis_device_id: "device",
        genesis_root_public_key: root_public,
        registry_audience: "registry-test",
        policy_epoch: 1,
        created_at: created_at
      })

    canonical_membership = %{
      mesh_id: "mesh",
      device_id: "device",
      root_public_key: root_public,
      root_key_revision: 1,
      permissions: [1, 2],
      state: 2,
      joined_at_revision: 1,
      revoked_at_revision: nil,
      operation_digest: <<>>,
      signatures: []
    }

    operation_canonical =
      PersonalMeshProto.registry_operation_signing_input(%{
        operation_id: "genesis-operation",
        kind: "genesis",
        mesh_id: "mesh",
        expected_revision: 0,
        policy_epoch: 1,
        issuer_device_id: "device",
        issuer_root_key_revision: 1,
        canonical_membership: canonical_membership,
        invite_id: nil,
        expires_at: expires_at,
        nonce: <<>>
      })

    descriptor = %{
      "meshId" => "mesh",
      "genesisDeviceId" => "device",
      "genesisRootPublicKey" => root_b64,
      "registryAudience" => "registry-test",
      "policyEpoch" => "1",
      "createdAt" => DateTime.to_iso8601(created_at),
      "genesisSignature" => Base.encode64(sign(descriptor_canonical, root_private))
    }

    operation = %{
      "operationId" => "genesis-operation",
      "kind" => "REGISTRY_OPERATION_KIND_GENESIS",
      "meshId" => "mesh",
      "policyEpoch" => "1",
      "issuerDeviceId" => "device",
      "issuerRootKeyRevision" => "1",
      "membership" => %{
        "meshId" => "mesh",
        "deviceId" => "device",
        "rootPublicKey" => root_b64,
        "rootKeyRevision" => "1",
        "permissions" => [
          "MESH_PERMISSION_USE_SERVICES",
          "MESH_PERMISSION_MANAGE_MEMBERS"
        ],
        "state" => "MESH_MEMBERSHIP_STATE_ACTIVE",
        "joinedAtRevision" => "1"
      },
      "expiresAt" => expires,
      "signature" => Base.encode64(sign(operation_canonical, root_private))
    }

    tampered_operation =
      put_in(operation, ["membership", "permissions"], ["MESH_PERMISSION_MANAGE_MEMBERS"])

    assert request("/v1/compute/registry/create", %{
             "request_json_b64" =>
               encode_json(%{"meshDescriptor" => descriptor, "genesis" => tampered_operation})
           }).status == 422

    response =
      request("/v1/compute/registry/create", %{
        "request_json_b64" =>
          encode_json(%{"meshDescriptor" => descriptor, "genesis" => operation})
      })

    assert response.status == 200

    assert response.resp_body
           |> Jason.decode!()
           |> Map.fetch!("response_b64")
           |> Base.decode64!()
           |> byte_size() > 64

    snapshot =
      request("/v1/compute/registry/snapshot", %{
        "request_json_b64" => encode_json(%{"meshId" => "mesh", "minimumRevision" => "1"})
      })

    assert snapshot.status == 200

    endpoint_canonical =
      PersonalMeshProto.endpoint_observation_signing_input(%{
        device_id: "device",
        root_key_revision: 1,
        endpoint_node_id: "iroh-node",
        generation: 1,
        supported_alpns: ["agent-vmm/service-tunnel/1"],
        feature_set: ["direct"],
        observed_addresses_digest: <<>>,
        expires_at: expires_at
      })

    observation = %{
      "deviceId" => "device",
      "rootKeyRevision" => "1",
      "endpointNodeId" => Base.encode64("iroh-node"),
      "endpointGeneration" => "1",
      "supportedAlpns" => ["agent-vmm/service-tunnel/1"],
      "featureSet" => ["direct"],
      "expiresAt" => expires,
      "deviceSignature" => Base.encode64(sign(endpoint_canonical, root_private))
    }

    assert request("/v1/compute/registry/endpoint", %{
             "request_json_b64" =>
               encode_json(%{
                 "meshId" => "mesh",
                 "expectedRevision" => "1",
                 "observation" => observation
               })
           }).status == 200

    endpoints =
      request("/v1/compute/registry/endpoints", %{
        "request_json_b64" => encode_json(%{"meshId" => "mesh", "expectedRevision" => "1"})
      })

    assert endpoints.status == 200

    endpoint_projection =
      endpoints.resp_body
      |> Jason.decode!()
      |> Map.fetch!("response_b64")
      |> Base.decode64!()
      |> Jason.decode!()

    assert endpoint_projection["meshRevision"] == 1
    assert endpoint_projection["observations"] == [observation]
  end

  defp request(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", @secret)
    |> put_req_header("x-agent-vmm-gateway-instance", "gateway-a")
    |> SalixWeb.Router.call(SalixWeb.Router.init([]))
  end

  defp claim_command!(epoch \\ @connection_epoch) do
    response =
      request("/v1/compute/commands/claim", %{
        "registration_id" => "registration",
        "connection_epoch" => epoch
      })

    assert response.status == 200
    response.resp_body |> Jason.decode!() |> Map.fetch!("command_json")
  end

  defp commit_command(command, outcome) do
    result =
      cond do
        is_map(command["ensureAllocation"]) ->
          %{
            "allocation" => %{
              "allocationId" => command["ensureAllocation"]["allocationId"],
              "revision" => "5",
              "state" => "ALLOCATION_STATE_READY"
            }
          }

        is_map(command["releaseAllocation"]) ->
          %{
            "allocation" => %{
              "allocationId" => command["releaseAllocation"]["allocationId"],
              "revision" => "6",
              "state" => "ALLOCATION_STATE_DISCARDED"
            }
          }

        is_map(command["openSession"]) ->
          %{
            "sessionReady" => %{
              "allocationId" => command["openSession"]["allocationId"],
              "allocationGeneration" =>
                Integer.to_string(command["openSession"]["allocationGeneration"]),
              "tunnelNonce" => "host-tunnel-nonce",
              "expiresUnixMillis" => Integer.to_string(System.system_time(:millisecond) + 300_000)
            }
          }

        true ->
          %{}
      end

    request("/v1/compute/commands/commit", %{
      "registration_id" => "registration",
      "transcript" => %{
        "result" =>
          %{
            "commandId" => command["commandId"],
            "connectionEpoch" => command["connectionEpoch"],
            "outcome" => outcome
          }
          |> Map.merge(result),
        "evidence" => %{
          "commandId" => command["commandId"],
          "connectionEpoch" => command["connectionEpoch"],
          "stage" => "EXECUTION_STAGE_FINISHED"
        }
      }
    })
  end

  defp encode_json(value), do: value |> Jason.encode!() |> Base.encode64()

  defp resource_v2_spec do
    %{
      "resources" => %{
        "cpu_max_millis" => 1_000,
        "memory_max_bytes" => 536_870_912,
        "pid_max" => 512,
        "writable_quota_bytes" => 2_147_483_648
      }
    }
  end

  defp keypair, do: :crypto.generate_key(:ecdh, :secp256r1)

  defp compress_public_key(<<4, x::binary-size(32), y::binary-size(32)>>) do
    prefix = if rem(:binary.decode_unsigned(y), 2) == 0, do: 2, else: 3
    <<prefix, x::binary>>
  end

  defp sign(payload, private) do
    der = :crypto.sign(:ecdsa, :sha256, payload, [private, :secp256r1])
    <<0x30, _size, 0x02, r_size, rest::binary>> = der
    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest
    r = pad32(r)
    s_value = :binary.decode_unsigned(s)
    s_value = min(s_value, @p256_order - s_value)
    r <> pad32(:binary.encode_unsigned(s_value))
  end

  defp pad32(<<0, rest::binary>>), do: pad32(rest)
  defp pad32(value), do: :binary.copy(<<0>>, 32 - byte_size(value)) <> value

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
