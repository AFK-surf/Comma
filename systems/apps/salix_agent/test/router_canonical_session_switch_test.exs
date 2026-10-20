defmodule SalixAgent.RouterCanonicalSessionSwitchTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{
    AgentActor,
    InternalSessionActor,
    InternalSessionFleet,
    AgentRoleActor,
    InternalSessionStore
  }

  alias SalixStore.{Keys, RuntimeIds, S3}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
      SystemsRuntime.delete_env(:salix_agent, :router_session_start_test_barrier)
      SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    {:ok, old_session_id} = RuntimeIds.persisted_router_session_id(agent)
    {:ok, _old_session} = InternalSessionStore.prepare_create(agent_id, old_session_id)

    {:ok, _server} = SalixAgent.Placement.ensure_started(agent_id, create: false)

    {:ok, old_actor} =
      InternalSessionFleet.ensure_started(agent_id, old_session_id, process_on_init: false)

    %{agent: agent, old_actor: old_actor, old_session_id: old_session_id}
  end

  test "durable Router admission remains observable while both actors are suspended", %{
    agent: agent,
    old_actor: session_actor,
    old_session_id: session_id
  } do
    monitor = SalixAgent.RouterRequestMonitor
    original_clock = :sys.get_state(monitor, :infinity).clock
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000_000)
    :sys.replace_state(monitor, &%{&1 | clock: fn -> :atomics.get(clock, 1) end}, :infinity)
    on_exit(fn -> :sys.replace_state(monitor, &%{&1 | clock: original_clock}, :infinity) end)

    reporter = Module.concat(__MODULE__, RouterReporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    # Admission-only seam intentionally withholds the ordinary post-commit wake:
    # the regression models a request which cannot start, without racing a round.
    assert {:ok, :committed, _targets} =
             AgentActor.stage_delivery_local(agent["agent_id"], %{
               source_message_id: "observed-user-input",
               payload: %{content: "pending user request"}
             })

    assert {:ok, stored} = SalixAgent.TestSupport.SessionData.read(agent["agent_id"], session_id)

    assert Enum.any?(
             stored.input_queue,
             &(&1["payload"]["source_message_id"] == "observed-user-input")
           )

    monitor.sample()

    assert {:ok, router_actor} = AgentActor.ensure_started(agent)
    :erlang.suspend_process(router_actor)
    :erlang.suspend_process(session_actor)

    try do
      :atomics.put(clock, 1, 1_300_001)
      monitor.sample()
      assert TelemetryMetricsPrometheus.Core.scrape(reporter) =~ "salix_router_requests_stalled 1"
    after
      :erlang.resume_process(router_actor)
      :erlang.resume_process(session_actor)
    end

    assert {:ok, _result} =
             AgentActor.switch_router_session(
               agent["agent_id"],
               agent["tenant_id"],
               session_id
             )

    monitor.sample()
    assert TelemetryMetricsPrometheus.Core.scrape(reporter) =~ "salix_router_requests_stalled 0"
  end

  test "owner switches to a fresh canonical session and retires old runtime work", %{
    agent: agent,
    old_actor: old_actor,
    old_session_id: old_session_id
  } do
    assert {:ok, result} =
             AgentActor.switch_router_session(
               agent["agent_id"],
               agent["tenant_id"],
               old_session_id
             )

    new_session_id = result["router_session_id"]
    assert new_session_id != old_session_id
    assert result["previous_session_id"] == old_session_id
    refute SystemsRuntime.Proc.alive?(old_actor)

    assert {:ok, updated} = SalixAgent.Control.get_record(agent["agent_id"])
    assert updated["router_session_id"] == new_session_id

    assert {:ok, fresh} =
             SalixAgent.TestSupport.SessionData.read(agent["agent_id"], new_session_id)

    assert fresh.messages == []
    assert fresh.async_results == []

    assert {:error, {:retired_router_session, ^new_session_id}} =
             InternalSessionFleet.wake(agent["agent_id"], old_session_id)

    assert {:error, {:retired_router_session, ^new_session_id}} =
             InternalSessionFleet.stage_delivery(agent["agent_id"], old_session_id, %{
               payload: %{
                 session_id: old_session_id,
                 source_message_id: "message-after-cutover",
                 content: "must not enter the retired session"
               }
             })

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent["agent_id"], old_session_id)
             ) == []
           end)
  end

  test "stale retry is fenced and does not rotate again", %{
    agent: agent,
    old_session_id: old_session_id
  } do
    assert {:ok, %{"router_session_id" => new_session_id}} =
             AgentActor.switch_router_session(
               agent["agent_id"],
               agent["tenant_id"],
               old_session_id
             )

    assert {:error, {:stale_router_session, ^new_session_id}} =
             AgentActor.switch_router_session(
               agent["agent_id"],
               agent["tenant_id"],
               old_session_id
             )

    assert {:ok, updated} = SalixAgent.Control.get_record(agent["agent_id"])
    assert updated["router_session_id"] == new_session_id
  end

  test "cutover waits for admitted staging and cannot restart the retired actor", %{
    agent: agent,
    old_session_id: old_session_id
  } do
    agent_id = agent["agent_id"]
    session_key = Keys.agent_internal_runtime_session(agent_id, old_session_id)
    :ok = S3.Fake.set_fault({:pause, :put, session_key})

    on_exit(fn ->
      if S3.Fake.paused?(), do: S3.Fake.release_pause()
    end)

    delivery =
      SystemsRuntime.Task.async(fn ->
        AgentActor.stage_delivery(agent_id, %{
          source_message_id: "admitted-before-cutover",
          payload: %{content: "finish before the old runtime is retired"}
        })
      end)

    assert eventually(&S3.Fake.paused?/0)

    assert {:ok, router_actor} = AgentActor.ensure_started(agent)

    switch =
      SystemsRuntime.Task.async(fn ->
        AgentActor.switch_router_session(agent_id, agent["tenant_id"], old_session_id)
      end)

    assert eventually(fn -> :sys.get_state(router_actor, :infinity).switch_pending != nil end)
    assert SystemsClock.yield(switch, 50) == nil

    assert {:error, :router_session_switching} =
             AgentRoleActor.admit_canonical_session(router_actor, old_session_id)

    # A delivery that arrives during the switch is refused by the role actor
    # itself. It must not start a staging task that the switch then waits for.
    stage_sup = SystemsRuntime.Proc.whereis(SalixAgent.AgentStageTaskSup)
    :erlang.trace(stage_sup, true, [:receive])

    try do
      assert {:error, :router_session_switching} =
               AgentRoleActor.stage_delivery(
                 router_actor,
                 %{
                   source_message_id: "arrives-during-cutover",
                   payload: %{content: "refused while the switch is pending"}
                 },
                 1_000
               )
    after
      :erlang.trace(stage_sup, false, [:receive])
    end

    trace_ref = :erlang.trace_delivered(stage_sup)
    settle_receive({:trace_delivered, ^stage_sup, ^trace_ref})
    refute_received {:trace, ^stage_sup, :receive, {:"$gen_call", _from, _start_request}}

    :ok = S3.Fake.release_pause()
    assert {:ok, :committed, _targets} = settled_await(delivery)
    assert {:ok, %{"router_session_id" => new_session_id}} = settled_await(switch)

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, old_session_id)
             ) == []
           end)

    assert {:error, {:retired_router_session, ^new_session_id}} =
             InternalSessionFleet.ensure_started(agent_id, old_session_id, process_on_init: false)
  end

  test "tenant scope and Router role fail closed", %{agent: agent, old_session_id: old_session_id} do
    wrong_tenant = SalixAgent.TestSupport.new_tenant_id()

    assert {:error, :not_found} =
             AgentActor.switch_router_session(agent["agent_id"], wrong_tenant, old_session_id)

    worker_id = SalixAgent.TestSupport.new_agent_id()
    worker = SalixAgent.TestSupport.create_control_agent!(worker_id, %{"role" => "worker"})

    assert {:error, {:unsupported_agent_role, "worker"}} =
             AgentActor.switch_router_session(
               worker["agent_id"],
               worker["tenant_id"],
               old_session_id
             )
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
