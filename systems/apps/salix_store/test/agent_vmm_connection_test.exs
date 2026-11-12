defmodule SalixStore.AgentVMMConnectionTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixStore"]

  import Ecto.Query
  import ExUnit.CaptureLog
  alias SalixStore.{AgentVMM, AgentVMMSettlementSweeper, Compute, Repo}

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_audit_events, agent_vmm_sessions, compute_commands, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    {:ok, registration} =
      SalixStore.AgentVMMFixtures.registration(%{
        id: "registration",
        tenant_id: "tenant",
        group_id: "group",
        device_id: "device",
        credential: String.duplicate("a", 32)
      })

    Repo.update_all(AgentVMM.Registration, set: [status: "ready", desired_enabled: true])

    {:ok, pool} =
      Compute.create_pool(%{
        id: "pool",
        tenant_id: "tenant",
        name: "default",
        region: "local",
        provider_policy: %{"providers" => ["agent_vmm"]}
      })

    %{registration: registration, pool: pool}
  end

  test "empty-inventory connection work does not grow with the Host's environments", context do
    for n <- 1..64, do: environment!(context.pool, "environment-#{n}")

    {result, hello_cost} = query_cost(fn -> hello("1") end)
    assert result == {:ok, :ok}
    assert hello_cost.max_written <= 1
    assert hello_cost.queries < 20

    {result, disconnect_cost} =
      query_cost(fn ->
        AgentVMM.mark_connection_lost(context.registration.id, "gateway", "1")
      end)

    assert match?({:ok, _}, result)
    assert disconnect_cost.queries < 20
    assert disconnect_cost.max_written <= 1
  end

  test "retained binding observations cannot grant a replaced Host fence", context do
    {allocation, workload} = workload!(context.pool)
    command!(allocation, workload, "read", "read_only")
    assert {:ok, :ok} = hello("2")

    # The cutover preserves old projections; they are no longer connection authority.
    Repo.update_all(Compute.ProviderBinding,
      set: [
        status: "available",
        observation: %{
          "gateway_instance_id" => "gateway",
          "connection_epoch" => "1",
          "admission" => "accepting"
        }
      ]
    )

    assert {:error, :stale_connection} =
             AgentVMM.claim_registration_command(context.registration.id, "gateway", "1")

    assert {:ok, _command} =
             AgentVMM.claim_registration_command(context.registration.id, "gateway", "2")
  end

  test "the existing worker settles unexpired commands from a disconnected fence", context do
    {allocation, workload} = workload!(context.pool)

    for {id, classification} <- [{"effect", "side_effecting"}, {"read", "read_only"}] do
      command!(allocation, workload, id, classification)

      assert {:ok, _} =
               AgentVMM.claim_registration_command(context.registration.id, "gateway", "1")
    end

    before = Repo.all(from(c in Compute.Command, where: c.id in ["effect", "read"]))
    assert {:ok, _} = AgentVMM.mark_connection_lost(context.registration.id, "gateway", "1")

    # A retained in-flight row needs settlement even though its deadline is still in the future.
    for command <- before do
      Repo.update_all(from(c in Compute.Command, where: c.id == ^command.id),
        set: [status: command.status, outcome: command.outcome]
      )
    end

    {:ok, state} = AgentVMMSettlementSweeper.init(interval_ms: 3_600_000)
    assert {:noreply, _state} = AgentVMMSettlementSweeper.handle_info(:sweep, state)
    assert Repo.get!(Compute.Command, "effect").status == "unknown_outcome"
    assert Repo.get!(Compute.Command, "read").status == "pending"

    for command <- before do
      settled = Repo.get!(Compute.Command, command.id)
      assert settled.request_id == command.request_id
      assert settled.evidence == command.evidence
      assert settled.deadline_at == command.deadline_at
      assert DateTime.compare(settled.deadline_at, SystemsClock.utc_now()) == :gt
    end
  end

  test "a pass whose query fails leaves the sweeper running and retries after the interval" do
    {:ok, state} = AgentVMMSettlementSweeper.init(interval_ms: 60_000)
    settle_receive(:sweep)

    # The retirement page query raises on this cursor, as it raised on a pool queue timeout.
    failing = put_elem(state, 1, %{level: :registration, r: 1, b: "", a: "", w: ""})

    log =
      capture_log(fn ->
        assert {:noreply, ^failing} = AgentVMMSettlementSweeper.handle_info(:sweep, failing)
      end)

    assert log =~ "Agent VMM settlement sweep failed"
    settle_refute_receive(:sweep, 59_999)
    settle_receive(:sweep)
  end

  test "in-flight pages advance past healthy commands to a replaced fence", context do
    {allocation, workload} = workload!(context.pool)
    command!(allocation, workload, "zz-stale", "side_effecting")
    assert {:ok, _} = AgentVMM.claim_registration_command(context.registration.id, "gateway", "1")
    assert {:ok, :ok} = hello("2")

    for n <- 1..64 do
      command!(allocation, workload, "healthy-#{n}", "read_only")

      assert {:ok, _} =
               AgentVMM.claim_registration_command(context.registration.id, "gateway", "2")
    end

    assert {:ok, %{scanned: 32, settled: 0, cursor: cursor}} =
             AgentVMM.settle_disconnected_commands(32)

    assert {:ok, %{scanned: 32, settled: 0, cursor: cursor}} =
             AgentVMM.settle_disconnected_commands(32, cursor)

    assert {:ok, %{scanned: 1, settled: 1, cursor: nil}} =
             AgentVMM.settle_disconnected_commands(32, cursor)

    assert Repo.get!(Compute.Command, "zz-stale").status == "unknown_outcome"
    assert Repo.aggregate(from(c in Compute.Command, where: c.status == "admitted"), :count) == 64
  end

  test "the Admin create decision follows the current registration connection", context do
    {environment, _binding} = environment!(context.pool, "environment")
    assert {:ok, :ok} = hello("1")

    assert {:ok, %{"environments" => [projection]}} =
             SalixStore.AgentVMMAdminProjection.get_node("tenant", context.registration.id)

    assert projection["id"] == environment.id
    assert projection["desired_state"] == "ready"
    assert projection["binding_status"] == "available"
    assert projection["observed_state"] == "ready"

    assert {:ok, %{environments: [environment]}} =
             Compute.project("tenant", "project", "environment")

    assert environment.observed_state == "ready"

    assert {:ok, _} = AgentVMM.mark_connection_lost(context.registration.id, "gateway", "1")

    assert {:ok, %{"environments" => [projection]}} =
             SalixStore.AgentVMMAdminProjection.get_node("tenant", context.registration.id)

    assert projection["binding_status"] == "unavailable"
    assert projection["observed_state"] == "pending"

    assert {:ok, %{environments: [environment]}} =
             Compute.project("tenant", "project", "environment")

    assert environment.observed_state == "pending"
  end

  test "reenabled Hosts remain discoverable without reviving drained work", context do
    {allocation, workload} = workload!(context.pool)

    record = %{
      "provider" => "agent_vmm",
      "workload_id" => workload.id,
      "generation" => workload.generation,
      "provider_resource_id" => context.registration.id
    }

    assert :ok = SalixStore.ComputeGroupStation.admit_record(record)

    assert {:error, :vmm_station_not_authorized} =
             SalixStore.ComputeGroupStation.admit_record(%{
               record
               | "generation" => workload.generation + 1
             })

    registration = Repo.get!(AgentVMM.Registration, context.registration.id)

    assert {:ok, disabled} =
             AgentVMM.configure_registration(registration.id, registration.revision, false)

    assert {:ok, _} =
             AgentVMM.configure_registration(registration.id, disabled.revision, true)

    assert {:ok, :ok} = hello("2")

    assert {:ok, {_registration, _environment, _binding}} =
             SalixStore.ComputeGroupStation.placement("tenant", "group")

    assert {:error, :vmm_station_not_authorized} =
             SalixStore.ComputeGroupStation.admit_record(record)

    assert Repo.get!(Compute.Allocation, allocation.id).status == "draining"
    assert Repo.get!(Compute.Workload, workload.id).desired_state == "draining"
  end

  defp environment!(pool, id) do
    {:ok, environment} =
      Compute.create_environment(%{
        id: id,
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: id,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-#{id}",
        pool_id: pool.id,
        environment_id: id,
        provider: "agent_vmm",
        provider_ref: "registration"
      })

    {environment, binding}
  end

  defp workload!(pool) do
    {environment, binding} = environment!(pool, "environment")
    assert {:ok, :ok} = hello("1")

    {:ok, allocation} =
      Compute.allocate(%{
        id: "allocation",
        environment_id: environment.id,
        provider_binding_id: binding.id,
        generation: 1
      })

    Repo.update_all(Compute.Allocation, set: [status: "ready"])

    {:ok, workload} =
      Compute.create_workload(%{
        id: "workload",
        environment_id: environment.id,
        allocation_id: allocation.id,
        kind: "shell",
        template_key: "shell.default",
        generation: 1
      })

    {Repo.get!(Compute.Allocation, allocation.id), workload}
  end

  defp command!(allocation, workload, id, classification) do
    {:ok, command} =
      Compute.enqueue_command(%{
        id: id,
        allocation_id: allocation.id,
        workload_id: workload.id,
        request_id: id,
        kind: "test.read",
        classification: classification,
        target_generation: allocation.generation,
        target_revision: allocation.revision,
        payload: %{
          "workload_generation" => workload.generation,
          "command_json" => %{"commandId" => id}
        },
        deadline_at: DateTime.add(SystemsClock.utc_now(), 300, :second)
      })

    command
  end

  defp hello(epoch),
    do:
      AgentVMM.observe_registration("registration", "gateway", %{
        "connectionEpoch" => epoch,
        "inventoryWatermark" => 0,
        "inventory" => []
      })

  defp query_cost(fun) do
    caller = self()
    handler = "vmm-connection-cost"

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == caller, do: send(caller, {:connection_query, metadata.result})
      end,
      nil
    )

    try do
      {fun.(), collect_cost(%{queries: 0, max_written: 0})}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect_cost(cost) do
    receive do
      {:connection_query, result} ->
        written =
          case result do
            {:ok, %{command: command, num_rows: count}}
            when command in [:insert, :update, :delete] ->
              count

            _ ->
              0
          end

        collect_cost(%{queries: cost.queries + 1, max_written: max(cost.max_written, written)})
    after
      0 -> cost
    end
  end
end
