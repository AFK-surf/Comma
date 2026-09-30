defmodule SalixStore.AgentVMMAdminProjectionContractTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SalixStore.{AgentVMM, AgentVMMAdminProjection, AgentVMMInstallations, Compute, Repo}

  setup do
    Repo.query!("""
    TRUNCATE agent_vmm_sessions, agent_vmm_audit_events, agent_vmm_install_operations,
      compute_commands, compute_runtime_instances, compute_workloads, compute_allocations,
      compute_provider_bindings, compute_environments, compute_pools,
      agent_vmm_registrations CASCADE
    """)

    :ok
  end

  test "the source graph keeps registration, compute, runtime, and command states distinct" do
    fixture = source_graph_fixture()

    assert fixture.registration.status == "ready"
    assert fixture.registration.desired_enabled
    assert fixture.binding.status == "available"
    assert fixture.allocation.status == "ready"
    assert fixture.allocation.operation_outcome == "succeeded"
    assert fixture.workload.desired_state == "ready"
    assert fixture.workload.observed_state == "draining"
    assert fixture.runtime.status == "connected"
    assert fixture.runtime.readiness == "pending"
    assert fixture.failed_command.status == "failed"
    assert fixture.unknown_command.status == "unknown_outcome"

    assert {:ok, owner_projection} = Compute.project("tenant-a", "project", "project-a", 10)
    assert Enum.map(owner_projection.environments, & &1.id) == [fixture.environment.id]
    assert Enum.map(owner_projection.allocations, & &1.id) == [fixture.allocation.id]
    assert Enum.map(owner_projection.workloads, & &1.id) == [fixture.workload.id]
    assert Enum.map(owner_projection.runtimes, & &1.id) == [fixture.runtime.id]

    assert {:ok, empty} = Compute.project("tenant-b", "project", "project-a", 10)
    assert empty.environments == []
    assert empty.allocations == []
    assert empty.workloads == []
    assert empty.runtimes == []
  end

  test "the admin DTO is tenant fenced, complete, and secret free" do
    tenant_a = source_graph_fixture("a", "tenant-a", "shared-device")
    _tenant_b = source_graph_fixture("b", "tenant-b", "shared-device")
    now = DateTime.utc_now()

    Repo.insert!(%Compute.ReconcilerClaim{
      id: "agent_vmm:#{tenant_a.workload.id}:#{tenant_a.workload.generation}",
      provider: "agent_vmm",
      workload_id: tenant_a.workload.id,
      generation: tenant_a.workload.generation,
      claim_token: "admin-projection-test",
      attempt_count: 1,
      last_error: %{
        "kind" => "provider_error",
        "code" => "resource_capacity_exhausted",
        "stage" => "import_admission",
        "resource" => "storage_headroom",
        "message" => "Guest storage headroom is unavailable.",
        "available_bytes" => 1_073_741_824,
        "required_bytes" => 2_147_483_648,
        "internal_detail" => "projection-secret"
      },
      created_at: now,
      updated_at: now
    })

    {2, _} =
      Repo.update_all(
        from(c in Compute.Command,
          where: c.id in [^tenant_a.failed_command.id, ^tenant_a.unknown_command.id]
        ),
        set: [
          payload: %{"secret" => "payload-secret"},
          evidence: %{"secret" => "evidence-secret"}
        ]
      )

    assert {:ok, %{nodes: [node], next_cursor: nil}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["id"] == tenant_a.registration.id
    assert node["device_id"] == "shared-device"
    assert node["connection"]["status"] == "connected"
    assert node["work"]["workloads"] == 1
    assert node["work"]["draining"] == 1
    assert node["operations"]["failed"] == 1
    assert node["operations"]["unknown_outcome"] == 1
    assert node["issue"] == "command_unknown_outcome"

    assert {:ok, %{operations: operations}} =
             AgentVMMAdminProjection.page_operations("tenant-a", tenant_a.registration.id)

    assert {:ok, %{workloads: [workload]}} =
             AgentVMMAdminProjection.page_workloads("tenant-a", tenant_a.registration.id)

    assert workload["id"] == tenant_a.workload.id

    assert workload["reconcile_error"] == %{
             "code" => "resource_capacity_exhausted",
             "stage" => "import_admission",
             "resource" => "storage_headroom",
             "message" => "Guest storage headroom is unavailable.",
             "available_bytes" => 1_073_741_824,
             "required_bytes" => 2_147_483_648
           }

    assert {:ok, %{activity: [activity | _]}} =
             AgentVMMAdminProjection.page_activity("tenant-a", tenant_a.registration.id)

    assert activity["subject"] == "registration"

    encoded =
      Jason.encode!(%{
        node: node,
        operations: operations,
        workloads: [workload],
        activity: activity
      })

    refute encoded =~ "payload-secret"
    refute encoded =~ "evidence-secret"
    refute encoded =~ "enrollment_token"
    refute encoded =~ "credential"
    refute encoded =~ "payload"
    refute encoded =~ "evidence"
    refute encoded =~ "projection-secret"

    assert {:error, :not_found} =
             AgentVMMAdminProjection.get_node("tenant-b", tenant_a.registration.id)

    assert {:error, :not_found} =
             AgentVMMAdminProjection.page_operations("tenant-b", tenant_a.registration.id)
  end

  test "node pages use a stable query bound as registrations grow" do
    source_graph_fixture("one", "tenant-a")

    small_count =
      query_count(fn -> AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 50) end)

    source_graph_fixture("two", "tenant-a")
    source_graph_fixture("three", "tenant-a")

    large_count =
      query_count(fn -> AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 50) end)

    assert small_count == large_count
    assert large_count <= 7
  end

  test "overview ready and attention counts use the same issue semantics as node rows" do
    fixture = source_graph_fixture("summary", "tenant-a")

    assert {:ok, %{"total" => 1, "ready" => 0, "needs_attention" => 1}} =
             AgentVMMAdminProjection.overview("tenant-a")

    Repo.update_all(
      from(c in Compute.Command,
        where: c.id in [^fixture.failed_command.id, ^fixture.unknown_command.id]
      ),
      set: [status: "committed", outcome: "succeeded"]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [observed_state: "ready"]
    )

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^fixture.runtime.id),
      set: [readiness: "ready"]
    )

    assert {:ok, %{nodes: [node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["status"] == "ready"
    assert is_nil(node["issue"])

    assert {:ok, %{"total" => 1, "ready" => 1, "needs_attention" => 0}} =
             AgentVMMAdminProjection.overview("tenant-a")
  end

  test "node keyset cursor and non-live connection states remain explicit" do
    first = source_graph_fixture("first", "tenant-a")
    second = source_graph_fixture("second", "tenant-a")

    {1, _} =
      Repo.update_all(
        from(b in Compute.ProviderBinding, where: b.id == ^first.binding.id),
        set: [status: "unavailable"]
      )

    assert {:ok, %{nodes: [page_one], next_cursor: cursor}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 1)

    assert is_map(cursor)

    assert {:ok, %{nodes: [page_two]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, cursor, 1)

    assert MapSet.new([page_one["id"], page_two["id"]]) ==
             MapSet.new([first.registration.id, second.registration.id])

    stale = if page_one["id"] == first.registration.id, do: page_one, else: page_two
    assert stale["connection"]["status"] == "connected"
  end

  test "an exact disconnect and a stale runtime generation remain explicit" do
    fixture = source_graph_fixture("disconnect", "tenant-a")

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^fixture.runtime.id),
      set: [generation: 0]
    )

    converge_fixture!(fixture)

    assert {:ok, %{workloads: [workload]}} =
             AgentVMMAdminProjection.page_workloads("tenant-a", fixture.registration.id)

    assert workload["generation_consistency"] == "mismatch"
    assert is_nil(workload["runtime_status"])

    assert {:ok, %{nodes: [mismatched_node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert mismatched_node["work"]["runtimes"] == 0
    assert mismatched_node["work"]["runtime_generation_mismatch"] == 1
    assert mismatched_node["issue"] == "runtime_not_ready"

    assert {:ok, %{"ready" => 0, "needs_attention" => 1}} =
             AgentVMMAdminProjection.overview("tenant-a")

    assert {:ok, _} =
             AgentVMM.mark_connection_lost(fixture.registration.id, "gateway-disconnect", "1")

    assert {:ok, %{nodes: [node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["connection"]["status"] == "disconnected"

    assert {:ok, %{nodes: [_]}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "disconnected"},
               nil,
               10
             )

    assert {:ok, %{nodes: []}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "stale"},
               nil,
               10
             )

    allocation = Repo.get!(Compute.Allocation, fixture.allocation.id)

    assert {:ok, :ok} =
             AgentVMM.observe_registration(fixture.registration.id, "gateway-reconnected", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 2,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => Integer.to_string(allocation.revision),
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    now = DateTime.add(DateTime.utc_now(), 1, :second)

    Repo.insert!(%AgentVMM.Session{
      id: "session-reconnected",
      registration_id: fixture.registration.id,
      runtime_instance_id: fixture.runtime.id,
      allocation_id: allocation.id,
      allocation_generation: 2,
      connection_epoch: "2",
      gateway_instance_id: "gateway-reconnected",
      status: "ready",
      expires_at: DateTime.add(now, 60, :second),
      updated_at: now
    })

    assert {:ok, %{nodes: [reconnected]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert reconnected["connection"]["status"] == "not_reported"

    assert {:ok, %{nodes: []}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "disconnected"},
               nil,
               10
             )
  end

  test "current observations reject stale fences, duplicates, invalid payloads, and expire by freshness" do
    fixture = source_graph_fixture("observation", "tenant-a")

    assert {:ok, :ok} =
             AgentVMM.settle_registration_observation(
               fixture.registration.id,
               "gateway-observation",
               "1",
               observation_fixture(2, %{
                 "health" => %{
                   "status" => "degraded",
                   "issue" => "host_degraded",
                   "message" => "/private/path: raw host exception",
                   "components" => [%{"component" => "network", "status" => "degraded"}]
                 }
               })
             )

    assert {:ok, %{nodes: [node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["connection"]["status"] == "connected"
    assert node["connection"]["health"]["status"] == "degraded"
    assert node["connection"]["health"]["message"] == "Host health is degraded."
    refute inspect(node) =~ "/private/path"
    assert node["issue"] == "command_unknown_outcome"

    assert {:error, :stale_observation} =
             AgentVMM.settle_registration_observation(
               fixture.registration.id,
               "gateway-observation",
               "1",
               observation_fixture(2)
             )

    assert {:error, :stale_connection} =
             AgentVMM.settle_registration_observation(
               fixture.registration.id,
               "old-gateway",
               "1",
               observation_fixture(3)
             )

    assert {:error, :invalid_observation} =
             AgentVMM.settle_registration_observation(
               fixture.registration.id,
               "gateway-observation",
               "1",
               observation_fixture(3, %{"health" => %{"status" => "ready"}})
             )

    Repo.update_all(
      from(o in AgentVMM.RegistrationObservation,
        where: o.registration_id == ^fixture.registration.id
      ),
      set: [received_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert {:ok, %{nodes: [stale]}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "stale"},
               nil,
               10
             )

    assert stale["connection"]["status"] == "stale"
    assert stale["issue"] == "command_unknown_outcome"
  end

  test "reconcile error projection admits only the finite public contract" do
    valid = %{
      "code" => "resource_capacity_exhausted",
      "stage" => "import_admission",
      "resource" => "storage_headroom",
      "message" => "Guest storage headroom is unavailable.",
      "available_bytes" => 1,
      "required_bytes" => 9_223_372_036_854_775_808
    }

    assert AgentVMM.project_reconcile_error(valid) ==
             Map.drop(valid, ["required_bytes"])

    refute AgentVMM.project_reconcile_error(%{valid | "code" => "attacker_chosen_reason"})
    refute AgentVMM.project_reconcile_error(%{valid | "stage" => "attacker_stage"})
    refute AgentVMM.project_reconcile_error(%{valid | "resource" => "private_path"})
    refute AgentVMM.project_reconcile_error(%{valid | "stage" => "image_import"})
  end

  test "disconnect serializes on the registration observation owner" do
    fixture = source_graph_fixture("disconnect-lock", "tenant-a")
    parent = self()

    owner =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(r in AgentVMM.Registration,
              where: r.id == ^fixture.registration.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, :registration_locked)

          receive do
            :release_registration -> :ok
          end
        end)
      end)

    assert_receive :registration_locked

    disconnect =
      Task.async(fn ->
        result =
          AgentVMM.mark_connection_lost(
            fixture.registration.id,
            "gateway-disconnect-lock",
            "1"
          )

        send(parent, {:disconnect_settled, result})
        result
      end)

    refute_receive {:disconnect_settled, _result}, 100
    send(owner.pid, :release_registration)
    assert {:ok, :ok} = Task.await(owner)
    assert_receive {:disconnect_settled, {:ok, _totals}}, 1_000
    assert {:ok, _totals} = Task.await(disconnect)

    observation = Repo.get!(AgentVMM.RegistrationObservation, fixture.registration.id)
    assert %DateTime{} = observation.disconnected_at
  end

  test "an available binding without a current observation is not ready" do
    fixture = source_graph_fixture("unreported", "tenant-a")
    converge_fixture!(fixture)

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^fixture.binding.id),
      set: [status: "available", observation: %{}]
    )

    Repo.delete_all(
      from(o in AgentVMM.RegistrationObservation,
        where: o.registration_id == ^fixture.registration.id
      )
    )

    assert {:ok, %{nodes: [node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["connection"]["status"] == "not_reported"
    assert node["issue"] == "observation_missing"
    assert node["status"] == "unknown"

    assert {:ok, %{nodes: []}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "stale"},
               nil,
               10
             )

    assert {:ok, %{nodes: [_]}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "not_reported"},
               nil,
               10
             )

    assert {:ok, %{"ready" => 0, "needs_attention" => 1}} =
             AgentVMMAdminProjection.overview("tenant-a")
  end

  test "overview binding existence is fenced through the environment tenant" do
    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration-tenant-a-only",
        tenant_id: "tenant-a",
        group_id: "group-a",
        device_id: "device-a-only",
        enrollment_token: String.duplicate("a", 32)
      })

    {1, _} =
      Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
        set: [status: "ready", desired_enabled: true]
      )

    tenant_b = source_graph_fixture("foreign", "tenant-b")

    {:ok, foreign_environment} =
      Compute.create_environment(%{
        id: "environment-foreign-reference",
        tenant_id: "tenant-b",
        owner_type: "project",
        owner_id: "project-foreign-reference",
        pool_id: tenant_b.binding.pool_id
      })

    now = DateTime.utc_now()

    Repo.insert!(%Compute.ProviderBinding{
      id: "binding-foreign-reference",
      pool_id: tenant_b.binding.pool_id,
      environment_id: foreign_environment.id,
      provider: "agent_vmm",
      provider_ref: registration.id,
      status: "available",
      generation: 1,
      revision: 1,
      observation: %{},
      updated_at: now
    })

    assert {:ok, %{"total" => 1, "ready" => 0, "needs_attention" => 1}} =
             AgentVMMAdminProjection.overview("tenant-a")

    assert {:ok, %{nodes: [node]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert node["issue"] == "observation_missing"
  end

  test "fleet ordering puts a failed node before a converged node" do
    failed = source_graph_fixture("failed-rank", "tenant-a")
    healthy = source_graph_fixture("healthy-rank", "tenant-a")

    Repo.update_all(from(c in Compute.Command, where: c.id == ^failed.unknown_command.id),
      set: [status: "committed", outcome: "succeeded"]
    )

    converge_fixture!(healthy)

    assert {:ok, %{nodes: [first | _]}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    assert first["id"] == failed.registration.id
    assert first["issue"] == "command_failed"
  end

  test "fleet filters cover admission, connection, work, issue, and updated time" do
    fixture = source_graph_fixture("filters", "tenant-a")
    before_update = DateTime.add(fixture.registration.updated_at, -1, :second)
    after_update = DateTime.add(fixture.registration.updated_at, 1, :second)

    for filters <- [
          %{"desired_enabled" => "true"},
          %{"connection" => "connected"},
          %{"work" => "draining"},
          %{"issue" => "command_unknown_outcome"},
          %{"updated_from" => DateTime.to_iso8601(before_update)},
          %{"updated_to" => DateTime.to_iso8601(after_update)}
        ] do
      assert {:ok, %{nodes: [%{"id" => id}]}} =
               AgentVMMAdminProjection.page_nodes("tenant-a", filters, nil, 10)

      assert id == fixture.registration.id
    end

    assert {:ok, %{nodes: []}} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"updated_from" => DateTime.to_iso8601(after_update)},
               nil,
               10
             )

    assert {:error, :invalid_query} =
             AgentVMMAdminProjection.page_nodes(
               "tenant-a",
               %{"connection" => "unknown"},
               nil,
               10
             )
  end

  test "draining work is attributed through its allocation when registrations share an environment" do
    owner = source_graph_fixture("owner", "tenant-a")

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration-peer",
        tenant_id: "tenant-a",
        group_id: "shared-group",
        device_id: "device-peer",
        enrollment_token: String.duplicate("p", 32)
      })

    {1, _} =
      Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^registration.id),
        set: [status: "ready", desired_enabled: true]
      )

    {:ok, peer_binding} =
      Compute.create_provider_binding(%{
        id: "binding-peer",
        pool_id: owner.binding.pool_id,
        environment_id: owner.environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    assert {:ok, %{nodes: nodes}} =
             AgentVMMAdminProjection.page_nodes("tenant-a", %{}, nil, 10)

    owner_node = Enum.find(nodes, &(&1["id"] == owner.registration.id))
    peer_node = Enum.find(nodes, &(&1["id"] == registration.id))

    assert owner_node["work"]["draining"] == 1
    assert peer_node["work"]["draining"] == 0
    assert peer_node["issue"] != "workload_not_converged"
    assert peer_binding.environment_id == owner.environment.id
  end

  defp source_graph_fixture(suffix \\ "a", tenant_id \\ "tenant-a", device_id \\ nil) do
    device_id = device_id || "device-#{suffix}"

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool-#{suffix}",
        tenant_id: tenant_id,
        name: "agent-vmm-#{suffix}",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]},
        capabilities: ["runtime_exec"]
      })

    {:ok, environment} =
      Compute.create_environment(%{
        id: "environment-#{suffix}",
        tenant_id: tenant_id,
        owner_type: "project",
        owner_id: "project-#{suffix}",
        pool_id: pool.id
      })

    {:ok, registration} =
      AgentVMM.create_registration(%{
        id: "registration-#{suffix}",
        tenant_id: tenant_id,
        group_id: "shared-group",
        device_id: device_id,
        enrollment_token: String.duplicate("e", 32)
      })

    {1, _} =
      Repo.update_all(
        from(r in AgentVMM.Registration, where: r.id == ^registration.id),
        set: [status: "ready", desired_enabled: true]
      )

    registration = Repo.get!(AgentVMM.Registration, registration.id)

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-#{suffix}",
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: registration.id,
        generation: 1
      })

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway-#{suffix}", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => [],
               "observation" => observation_fixture(1)
             })

    binding = Repo.get!(Compute.ProviderBinding, binding.id)

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation-#{suffix}",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    {:ok, allocation} = Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload-#{suffix}",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "external_worker",
        generation: 1
      })

    {:ok, workload} = Compute.observe_workload(workload.id, 1, 1, "draining")

    {:ok, runtime} =
      Compute.observe_runtime(%{
        id: "runtime-#{suffix}",
        workload_id: workload.id,
        allocation_id: allocation.id,
        generation: 1,
        connection_epoch: "1"
      })

    {1, _} =
      Repo.update_all(
        from(r in Compute.RuntimeInstance, where: r.id == ^runtime.id),
        set: [readiness: "pending"]
      )

    failed_command = enqueue_command!("command-failed-#{suffix}", allocation, workload)
    unknown_command = enqueue_command!("command-unknown-#{suffix}", allocation, workload)

    {1, _} =
      Repo.update_all(from(c in Compute.Command, where: c.id == ^failed_command.id),
        set: [status: "failed", outcome: "failed"]
      )

    {1, _} =
      Repo.update_all(from(c in Compute.Command, where: c.id == ^unknown_command.id),
        set: [status: "unknown_outcome", outcome: "unknown"]
      )

    now = DateTime.utc_now()

    Repo.insert!(%AgentVMMInstallations.Operation{
      id: "install-#{suffix}",
      tenant_id: tenant_id,
      group_id: "shared-group",
      surface: "comma",
      scope_key: "project-#{suffix}",
      client_request_id: "request-#{suffix}",
      provider: "agent_vmm",
      environment_id: environment.id,
      delivery_target_type: "project",
      delivery_target_id: "project-#{suffix}",
      registration_id: registration.id,
      authorization_status: "handed_off",
      ticket_generation: 1,
      ticket_secret_hash: :crypto.hash(:sha256, "ticket-#{suffix}-#{tenant_id}"),
      ticket_status: "consumed",
      ticket_expires_at: DateTime.add(now, 60, :second),
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%AgentVMM.Session{
      id: "session-#{suffix}",
      registration_id: registration.id,
      runtime_instance_id: runtime.id,
      allocation_id: allocation.id,
      allocation_generation: 1,
      connection_epoch: "1",
      gateway_instance_id: "gateway-#{suffix}",
      status: "ready",
      expires_at: DateTime.add(now, 60, :second),
      updated_at: now
    })

    %{
      registration: registration,
      environment: environment,
      binding: binding,
      allocation: allocation,
      workload: workload,
      runtime: Repo.get!(Compute.RuntimeInstance, runtime.id),
      failed_command: Repo.get!(Compute.Command, failed_command.id),
      unknown_command: Repo.get!(Compute.Command, unknown_command.id)
    }
  end

  defp observation_fixture(sequence, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    Map.merge(
      %{
        "sequence" => Integer.to_string(sequence),
        "observedUnixMillis" => Integer.to_string(now),
        "protocolVersion" => "1",
        "hostApiVersion" => "host.v1",
        "connectorRelease" => "test",
        "supportedFeatures" => ["connection-epoch-v1"],
        "capacity" => %{
          "perEnvironmentLimits" => %{},
          "maxEgressMode" => "EGRESS_MODE_DENY_ALL"
        },
        "health" => %{"status" => "healthy", "components" => []},
        "usage" => %{"stale" => false},
        "inventoryWatermark" => "0",
        "inventoryObservedUnixMillis" => Integer.to_string(now)
      },
      overrides
    )
  end

  defp enqueue_command!(id, allocation, workload) do
    {:ok, command} =
      Compute.enqueue_command(%{
        id: id,
        allocation_id: allocation.id,
        workload_id: workload.id,
        request_id: id,
        kind: "observe",
        classification: "read_only",
        target_generation: allocation.generation,
        target_revision: allocation.revision,
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    command
  end

  defp converge_fixture!(fixture) do
    Repo.update_all(
      from(c in Compute.Command,
        where: c.id in [^fixture.failed_command.id, ^fixture.unknown_command.id]
      ),
      set: [status: "committed", outcome: "succeeded"]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^fixture.workload.id),
      set: [observed_state: "ready"]
    )

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.id == ^fixture.runtime.id),
      set: [readiness: "ready"]
    )
  end

  defp query_count(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = "agent-vmm-admin-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma, :repo, :query],
        fn _event, _measurements, metadata, {pid, message_ref} ->
          if self() == pid and metadata[:repo] == Repo, do: send(pid, message_ref)
        end,
        {test_pid, ref}
      )

    try do
      assert {:ok, _result} = fun.()
      drain_query_count(ref, 0)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_count(ref, count) do
    receive do
      ^ref -> drain_query_count(ref, count + 1)
    after
      0 -> count
    end
  end
end
