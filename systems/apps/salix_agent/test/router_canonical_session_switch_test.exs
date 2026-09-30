defmodule SalixAgent.RouterCanonicalSessionSwitchTest do
  use ExUnit.Case, async: false

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
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, previous_backend)
      Application.delete_env(:salix_agent, :router_session_start_test_barrier)
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
    original_clock = :sys.get_state(monitor).clock
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000_000)
    :sys.replace_state(monitor, &%{&1 | clock: fn -> :atomics.get(clock, 1) end})
    on_exit(fn -> :sys.replace_state(monitor, &%{&1 | clock: original_clock}) end)

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
    refute Process.alive?(old_actor)

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

  test "retired recovery targets neither retry nor mask another target failure", ctx do
    agent_id = ctx.agent["agent_id"]

    assert {:ok, %{"router_session_id" => current}} =
             AgentActor.switch_router_session(
               agent_id,
               ctx.agent["tenant_id"],
               ctx.old_session_id
             )

    retired = %{runtime: :internal, session_id: ctx.old_session_id}
    canonical = %{runtime: :internal, session_id: current}
    assert :ok = AgentActor.wake_targets_after_commit(agent_id, [retired, canonical])

    assert {:error, {:retired_router_session, ^current}} =
             AgentActor.wake_targets(agent_id, [retired])

    for targets <- [[retired, :invalid], [:invalid, retired]] do
      assert {:error, {:invalid_wake_target, :invalid}} =
               AgentActor.wake_targets_after_commit(agent_id, targets)
    end
  end

  test "recovery removes retired candidates without deleting readable session history", ctx do
    agent_id = ctx.agent["agent_id"]

    assert {:ok, _} =
             AgentActor.switch_router_session(
               agent_id,
               ctx.agent["tenant_id"],
               ctx.old_session_id
             )

    assert {:ok, before} = SalixAgent.TestSupport.SessionData.read(agent_id, ctx.old_session_id)

    # A pre-cutover writer can leave a candidate after the canonical switch.
    assert {:ok, _} =
             SalixAgent.SessionWorkIndex.mark(
               agent_id,
               :internal,
               ctx.old_session_id,
               ["unacked_queue_item"]
             )

    summary = SalixAgent.SessionWorkRecovery.sweep(session_work_max_keys: 100)
    assert summary.cleaned == 1
    assert summary.failed == 0
    assert {:ok, []} = SalixAgent.SessionWorkIndex.list(agent_id)
    assert {:ok, ^before} = SalixAgent.TestSupport.SessionData.read(agent_id, ctx.old_session_id)
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

  test "a landed switch with an ambiguous acknowledgement refreshes the live owner", context do
    assert_landed_ambiguous_switch(context, :ambiguous_after)
  end

  test "a landed switch followed by a conditional retry 412 refreshes the live owner", context do
    assert_landed_ambiguous_switch(context, :precondition_after)
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
      Task.async(fn ->
        AgentActor.stage_delivery(agent_id, %{
          source_message_id: "admitted-before-cutover",
          payload: %{content: "finish before the old runtime is retired"}
        })
      end)

    assert eventually(&S3.Fake.paused?/0)

    assert {:ok, router_actor} = AgentActor.ensure_started(agent)

    switch =
      Task.async(fn ->
        AgentActor.switch_router_session(agent_id, agent["tenant_id"], old_session_id)
      end)

    assert eventually(fn -> :sys.get_state(router_actor).switch_pending != nil end)
    assert Task.yield(switch, 50) == nil

    assert {:error, :router_session_switching} =
             AgentRoleActor.admit_canonical_session(router_actor, old_session_id)

    # A delivery that arrives during the switch is refused by the role actor
    # itself. It must not start a staging task that the switch then waits for.
    stage_sup = Process.whereis(SalixAgent.AgentStageTaskSup)
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
    assert_receive {:trace_delivered, ^stage_sup, ^trace_ref}, 1_000
    refute_received {:trace, ^stage_sup, :receive, {:"$gen_call", _from, _start_request}}

    :ok = S3.Fake.release_pause()
    assert {:ok, :committed, _targets} = Task.await(delivery, 5_000)
    assert {:ok, %{"router_session_id" => new_session_id}} = Task.await(switch, 5_000)

    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, old_session_id)
             ) == []
           end)

    assert {:error, {:retired_router_session, ^new_session_id}} =
             InternalSessionFleet.ensure_started(agent_id, old_session_id, process_on_init: false)
  end

  test "canonical read and recovery actor start are serialized with cutover", %{
    agent: agent,
    old_session_id: old_session_id
  } do
    agent_id = agent["agent_id"]
    test_pid = self()
    barrier_ref = make_ref()

    assert :ok =
             SalixAgent.Fleet.stop(InternalSessionActor.key(agent_id, old_session_id))

    Application.put_env(
      :salix_agent,
      :router_session_start_test_barrier,
      fn ^agent_id, ^old_session_id ->
        send(test_pid, {:router_start_read_complete, self(), barrier_ref})

        receive do
          {:release_router_start, ^barrier_ref} -> :ok
        end
      end
    )

    recovery_start =
      Task.async(fn ->
        InternalSessionFleet.ensure_started(agent_id, old_session_id, process_on_init: true)
      end)

    assert_receive {:router_start_read_complete, router_actor, ^barrier_ref}, 1_000

    switch =
      Task.async(fn ->
        AgentActor.switch_router_session(agent_id, agent["tenant_id"], old_session_id)
      end)

    assert eventually(fn -> switch_queued?(router_actor, old_session_id) end)
    assert Task.yield(switch, 50) == nil

    assert {:ok, before_release} = SalixAgent.Control.get_record(agent_id)
    assert before_release["router_session_id"] == old_session_id

    assert Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, old_session_id)
           ) ==
             []

    send(router_actor, {:release_router_start, barrier_ref})

    assert {:ok, recovered_actor} = Task.await(recovery_start, 5_000)
    assert {:ok, %{"router_session_id" => new_session_id}} = Task.await(switch, 5_000)
    refute Process.alive?(recovered_actor)

    # The retired actor is dead once the switch returns, but Registry drops
    # its entry asynchronously (partition :EXIT handling), and lookup/2 does
    # not filter dead pids. Poll instead of asserting the first read.
    assert eventually(fn ->
             Registry.lookup(
               SalixAgent.Registry,
               InternalSessionActor.key(agent_id, old_session_id)
             ) == []
           end)

    assert {:error, {:retired_router_session, ^new_session_id}} =
             InternalSessionFleet.ensure_started(agent_id, old_session_id, process_on_init: true)
  end

  test "a stale live owner refreshes from the durable canonical record", %{
    agent: agent,
    old_session_id: old_session_id
  } do
    assert {:ok, router_actor} = AgentActor.ensure_started(agent)

    externally_selected_session_id = SalixStore.Ids.new_session_id()

    assert {:ok, _fresh} =
             InternalSessionStore.prepare_create(
               agent["agent_id"],
               externally_selected_session_id
             )

    assert {:ok, _updated} =
             SalixAgent.AgentControl.switch_router_session_record(
               agent["agent_id"],
               old_session_id,
               externally_selected_session_id
             )

    assert {:error, {:stale_router_session, ^externally_selected_session_id}} =
             AgentActor.switch_router_session(
               agent["agent_id"],
               agent["tenant_id"],
               old_session_id
             )

    refreshed = :sys.get_state(router_actor)

    assert {:ok, ^externally_selected_session_id} =
             RuntimeIds.persisted_router_session_id(refreshed.agent)
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

  test "canonical actor start through the Router owner waits out an in-flight root claim", %{
    agent: agent,
    old_session_id: old_session_id
  } do
    # Review blocker repro (round 3): the Router-owned start path used a bare
    # DynamicSupervisor.start_child, bypassing the claim-await boundary. An
    # actor started while the root Server's claim was still in flight (cell
    # absent) legacy-pinned epoch 0 and its first durable control write came
    # back {:error, :fenced} forever — valid recovery work rejected. Every
    # path now creates session actors through Fleet.start_session_actor, so
    # the start waits for the installed claim and binds to it.
    agent_id = agent["agent_id"]

    # Retire the setup's live runtime so this node's cell is absent again.
    :ok = SalixAgent.Fleet.stop_existing(agent_id)
    assert eventually(fn -> not SalixAgent.Fleet.running?(agent_id) end)
    :ok = SalixAgent.OwnershipCell.clear(agent_id)

    # The canonical session was last advanced under epoch 2's ownership.
    :ok = SalixAgent.OwnershipCell.install(agent_id, 2)

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(agent_id, old_session_id, [
               %{"type" => "status", "session_id" => old_session_id, "status" => "idle"}
             ])

    :ok = SalixAgent.OwnershipCell.clear(agent_id)

    # A root Server is registered with its claim still in flight: root
    # Registry key taken, ownership cell absent.
    parent = self()

    standin =
      spawn_link(fn ->
        {:ok, _} = Registry.register(SalixAgent.Registry, agent_id, nil)
        send(parent, :standin_registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :standin_registered, 1_000

    task =
      Task.async(fn ->
        InternalSessionFleet.ensure_started(agent_id, old_session_id, process_on_init: false)
      end)

    # The reviewer's failing wait assertion: without the shared start
    # boundary this returned a legacy-pinned actor within ~100ms.
    assert Task.yield(task, 150) == nil

    # The claim lands at epoch 3; the waiting start must bind to it.
    :ok = SalixAgent.OwnershipCell.install(agent_id, 3)
    assert {:ok, actor} = Task.await(task, 2_000)

    # Its first durable control write proceeds under epoch 3 — not fenced.
    # (The call also serializes behind the actor's generation-binding
    # continue, so the frozen-value assertion below is race-free.)
    assert {:ok, :committed} =
             InternalSessionActor.stage_control(
               actor,
               %{
                 payload: %{
                   kind: "session_update",
                   session_id: old_session_id,
                   name: "renamed under epoch 3"
                 }
               },
               5_000
             )

    key = InternalSessionActor.key(agent_id, old_session_id)
    assert [{^actor, %{runtime_epoch: 3}}] = Registry.lookup(SalixAgent.Registry, key)

    assert {:ok, state} = SalixAgent.TestSupport.SessionData.read(agent_id, old_session_id)
    assert state.runtime_epoch == 3
    assert state.name == "renamed under epoch 3"

    send(standin, :done)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp switch_queued?(router_actor, old_session_id) do
    case Process.info(router_actor, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", _from, {:switch_canonical_session, ^old_session_id}} -> true
          _other -> false
        end)

      nil ->
        false
    end
  end

  defp assert_landed_ambiguous_switch(
         %{agent: agent, old_session_id: old_session_id},
         fault
       ) do
    agent_id = agent["agent_id"]
    key = Keys.ctl_agent(agent_id)
    :ok = S3.Fake.set_fault({fault, :put, key})

    assert {:ok, %{"router_session_id" => new_session_id}} =
             AgentActor.switch_router_session(
               agent_id,
               agent["tenant_id"],
               old_session_id
             )

    assert {:ok, durable_agent} = SalixAgent.Control.get_record(agent_id)
    assert durable_agent["router_session_id"] == new_session_id

    assert {:ok, router_actor} = AgentActor.ensure_started(agent)

    owner_state = :sys.get_state(router_actor)

    assert {:ok, ^new_session_id} =
             RuntimeIds.persisted_router_session_id(owner_state.agent)

    source_message_id = "post-settlement-#{fault}"

    assert {:ok, :committed, _targets} =
             AgentActor.stage_delivery(agent_id, %{
               source_message_id: source_message_id,
               payload: %{content: "route through the settled canonical session"}
             })

    assert {:ok, new_session} = SalixAgent.TestSupport.SessionData.read(agent_id, new_session_id)
    assert MapSet.member?(new_session.input_dedupe, source_message_id)

    assert {:ok, old_session} = SalixAgent.TestSupport.SessionData.read(agent_id, old_session_id)
    refute MapSet.member?(old_session.input_dedupe, source_message_id)
  end
end
