defmodule SalixAgent.ServerRuntimeOwnershipTest do
  @moduledoc """
  Root-Server side of runtime ownership: the claim installs
  the node-local ownership cell; a fenced Server aborts the agent's session
  actors (killing their in-flight work) instead of only stopping itself; and
  the park boundary renews the lease while session work is busy but still
  passivates under idle-but-registered actors.

  The stand-in session actor is a GenServer answering `:busy?` from a
  settable flag, so both branches of the busy probe are exercised with
  instant replies (the timeout→busy branch of `busy?/1` is its own
  documented, conservative fallback).
  """
  use ExUnit.Case, async: false

  alias SalixStore.Agent
  alias SalixAgent.{Fleet, OwnershipCell, Server, State}

  defmodule FakeSessionActor do
    use GenServer

    def start_link({key, busy, parent}),
      do: GenServer.start_link(__MODULE__, {key, busy, nil, parent})

    def start_link({key, busy, epoch, parent}),
      do: GenServer.start_link(__MODULE__, {key, busy, epoch, parent})

    def set_busy(pid, busy), do: GenServer.call(pid, {:set_busy, busy})

    @impl true
    def init({key, busy, epoch, parent}) do
      value = if is_integer(epoch), do: %{runtime_epoch: epoch}, else: nil
      {:ok, _} = Registry.register(SalixAgent.Registry, key, value)
      send(parent, {:registered, key})
      {:ok, %{busy: busy}}
    end

    @impl true
    def handle_call(:busy?, _from, state), do: {:reply, state.busy, state}
    def handle_call({:set_busy, busy}, _from, state), do: {:reply, :ok, %{state | busy: busy}}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  defp start_fake_session_actor!(agent_id, session_id, busy, epoch \\ nil) do
    key = {:internal_session, agent_id, session_id}

    child = %{
      id: {:fake_session, session_id},
      start: {FakeSessionActor, :start_link, [{key, busy, epoch, self()}]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(SalixAgent.FleetSup, child)
    assert_receive {:registered, ^key}, 1_000
    pid
  end

  test "claiming the root installs the node-local ownership cell", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    {:ok, _pid} = Fleet.ensure_started(a, create: false)
    {_, owned} = Server.info(a)

    assert OwnershipCell.fetch(a) == {:ok, owned.epoch}
  end

  test "a fenced Server aborts the agent's session actors, not just itself", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    {:ok, server} = Fleet.ensure_started(a, create: false)
    _ = Server.info(a)

    fake = start_fake_session_actor!(a, "ses1_0000000000000000801", false)
    fake_ref = Process.monitor(fake)
    server_ref = Process.monitor(server)

    # Another node steals the root (epoch bump); our Server's next cycle
    # observes the fence and must take the whole local runtime down with it.
    {:ok, _thief} = Agent.claim(a, "thief-node", State, steal: true)
    Server.wake(server)

    assert_receive {:DOWN, ^server_ref, :process, ^server, server_reason}, 2_000
    assert server_reason in [:normal, :shutdown]
    assert_receive {:DOWN, ^fake_ref, :process, ^fake, _fake_reason}, 2_000

    assert OwnershipCell.fetch(a) == :fenced
    assert eventually(fn -> not Fleet.running?(a) end)
  end

  test "a delayed takeover nudge for a superseded epoch does not kill a newer runtime", %{
    agent: a
  } do
    # Review finding: abort must honor "only runtime at or below the
    # observed epoch is superseded". A nudge about epoch 2 arriving after
    # this node re-claimed at epoch 3 leaves the epoch-3 runtime intact and
    # stops only work items frozen at or below the evidence.
    :ok = OwnershipCell.install(a, 3)

    stale = start_fake_session_actor!(a, "ses1_0000000000000000806", false, 1)
    current = start_fake_session_actor!(a, "ses1_0000000000000000807", false, 3)
    stale_ref = Process.monitor(stale)
    current_ref = Process.monitor(current)

    :ok = Fleet.abort_agent_runtime(a, 2, :superseded)

    assert_receive {:DOWN, ^stale_ref, :process, ^stale, _}, 2_000
    refute_receive {:DOWN, ^current_ref, :process, ^current, _}, 200
    assert OwnershipCell.fetch(a) == {:ok, 3}

    # Evidence at (or above) the current claim supersedes the whole runtime.
    # (The bounded-lifecycle clear of the fenced residue races async Registry
    # cleanup here; the deterministic clear is asserted in
    # runtime_epoch_fence_test.)
    :ok = Fleet.abort_agent_runtime(a, 3, :superseded)
    assert_receive {:DOWN, ^current_ref, :process, ^current, _}, 2_000
    assert OwnershipCell.fetch(a) in [:fenced, :absent]
  end

  test "full teardown is epoch-conditional at the kill boundary", %{agent: a} do
    # Review blocker repro: the full-abort branch must not blanket-stop
    # everything it finds at teardown time — an actor frozen ABOVE the
    # fenced bound belongs to a claim racing in during the teardown and
    # survives; only work at or below the bound dies.
    :ok = OwnershipCell.fence(a, 2)

    superseded = start_fake_session_actor!(a, "ses1_0000000000000000808", false, 1)
    newer = start_fake_session_actor!(a, "ses1_0000000000000000809", false, 3)
    superseded_ref = Process.monitor(superseded)
    newer_ref = Process.monitor(newer)

    :ok = Fleet.abort_agent_runtime(a, 2, :superseded)

    assert_receive {:DOWN, ^superseded_ref, :process, ^superseded, _}, 2_000
    refute_receive {:DOWN, ^newer_ref, :process, ^newer, _}, 200
  end

  test "an abort decided on stale evidence cannot kill a Server whose claim lands above the bound",
       %{agent: a} do
    # Review blocker repro (round 3): fence old-epoch evidence, pause the
    # Server's root-claim PUT mid-flight, run the superseded-runtime abort
    # while the claim is in the air, then let the PUT land. The claim lands
    # durably at a newer epoch — the already-issued stop must NOT kill its
    # Server. The kill decision is a message the Server itself evaluates
    # (`Server.stop_if_at_or_below/3`), so it linearizes in the Server's
    # mailbox behind the claim's completion and is refused.
    SalixAgent.TestSupport.create_control_agent!(a)

    # Advance the durable epoch so the next claim lands above the evidence.
    {:ok, owned0} = Agent.claim(a, to_string(node()), State)
    _ = Agent.release(owned0)
    stale_epoch = owned0.epoch

    :ok = SalixStore.S3.Fake.set_fault({:pause, :put, SalixStore.Keys.agent_state(a)})
    {:ok, server} = Fleet.ensure_started(a, create: false, startup_mode: :passive)
    server_ref = Process.monitor(server)
    assert eventually(fn -> SalixStore.S3.Fake.paused?() end)

    abort = Task.async(fn -> Fleet.abort_agent_runtime(a, stale_epoch, :superseded) end)
    # Give the abort time to queue its conditional stop behind the parked claim.
    Process.sleep(150)
    :ok = SalixStore.S3.Fake.release_pause()

    assert Task.await(abort, 10_000) == :ok
    refute_receive {:DOWN, ^server_ref, :process, ^server, _}, 300
    assert Process.alive?(server)

    assert {:parked, owned} = Server.info(server)
    assert owned.epoch > stale_epoch
    assert OwnershipCell.fetch(a) == {:ok, owned.epoch}

    # The refused abort left the valid lease with its renewal owner intact.
    assert Fleet.server_running?(a)
  end

  test "a supervisor-restarted internal actor waits out an in-flight claim before committing",
       %{agent: a} do
    # Review blocker repro (round 4): `restart: :transient` means an
    # abnormal actor exit makes DynamicSupervisor re-run the retained
    # child_spec directly — no call-site boundary. The generation binding
    # is therefore the actor's own first act (init → handle_continue), so
    # the automatic replacement waits out the in-flight root claim and
    # binds to it, instead of legacy-pinning epoch 0 and fencing valid
    # recovery work.
    session = "ses1_0000000000000000810"

    :ok = OwnershipCell.install(a, 2)

    {:ok, actor} =
      Fleet.start_session_actor(SalixAgent.InternalSessionActor,
        agent_id: a,
        session_id: session,
        process_on_init: false
      )

    # Durably stamp the session under epoch 2 through the actor itself.
    assert {:ok, :committed} =
             SalixAgent.InternalSessionActor.stage_control(
               actor,
               %{payload: %{kind: "session_update", session_id: session, name: "seeded"}},
               5_000
             )

    # The runtime moves off this shape: cell absent, root claim in flight
    # (root Registry key held by a stand-in mid-claim).
    :ok = OwnershipCell.clear(a)
    parent = self()

    standin =
      spawn_link(fn ->
        {:ok, _} = Registry.register(SalixAgent.Registry, a, nil)
        send(parent, :standin_registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :standin_registered, 1_000

    # Abnormal exit → automatic supervisor restart.
    ref = Process.monitor(actor)
    Process.exit(actor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^actor, :killed}, 1_000

    key = SalixAgent.InternalSessionActor.key(a, session)

    assert eventually(fn ->
             case Registry.lookup(SalixAgent.Registry, key) do
               [{pid, _}] -> pid != actor
               [] -> false
             end
           end)

    [{replacement, _}] = Registry.lookup(SalixAgent.Registry, key)

    # Registry publishes the pid before init opens its residency gate. The
    # supervisor replies only after init, without waiting for claim binding.
    assert Enum.any?(DynamicSupervisor.which_children(SalixAgent.FleetSup), fn
             {_, pid, _, _} -> pid == replacement
           end)

    task =
      Task.async(fn ->
        SalixAgent.InternalSessionActor.stage_control(
          replacement,
          %{payload: %{kind: "session_update", session_id: session, name: "after restart"}},
          5_000
        )
      end)

    # On the pre-fix head this returned {:error, :fenced} immediately (the
    # replacement legacy-pinned 0 against the epoch-2 stamp). Now the write
    # queues behind the replacement's generation binding.
    assert Task.yield(task, 150) == nil

    :ok = OwnershipCell.install(a, 3)
    assert {:ok, :committed} = Task.await(task, 2_000)

    assert [{^replacement, %{runtime_epoch: 3}}] = Registry.lookup(SalixAgent.Registry, key)
    assert {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, session)
    assert state.runtime_epoch == 3
    assert state.name == "after restart"

    send(standin, :done)
  end

  test "a command for a rootless-restarted unbound actor waits out a later in-flight claim",
       %{agent: a} do
    # Review blocker repro (round 5): an idle actor that outlives a
    # passivated root Server and crashes during the rootless interval gets
    # a replacement whose binding continue finds nothing to wait for —
    # legitimately registered but UNBOUND (nil Registry value). The
    # caller-side funnel must not mistake that for "already frozen": when
    # later work starts a new root Server, a command that skipped the wait
    # would reach the unbound replacement mid-claim and freeze it at
    # legacy 0, fencing valid recovery work.
    session = "ses1_0000000000000000812"

    :ok = OwnershipCell.install(a, 2)

    {:ok, actor} =
      Fleet.start_session_actor(SalixAgent.InternalSessionActor,
        agent_id: a,
        session_id: session,
        process_on_init: false
      )

    assert {:ok, :committed} =
             SalixAgent.InternalSessionActor.stage_control(
               actor,
               %{payload: %{kind: "session_update", session_id: session, name: "seeded"}},
               5_000
             )

    # Root passivated: released claim, cleared cell, no root Registry key.
    :ok = OwnershipCell.clear(a)

    # Idle crash during the rootless interval → automatic restart with no
    # Server present: the replacement completes its continue unbound.
    ref = Process.monitor(actor)
    Process.exit(actor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^actor, :killed}, 1_000

    key = SalixAgent.InternalSessionActor.key(a, session)

    assert eventually(fn ->
             case Registry.lookup(SalixAgent.Registry, key) do
               [{pid, _}] -> pid != actor
               [] -> false
             end
           end)

    [{replacement, _}] = Registry.lookup(SalixAgent.Registry, key)
    # Sync past the binding continue, then pin down the state the fix keys
    # on: registered but unbound.
    _ = SalixAgent.InternalSessionActor.busy?(replacement, 1_000)
    assert [{^replacement, nil}] = Registry.lookup(SalixAgent.Registry, key)

    # Later work: a new root Server is mid-claim (root key registered,
    # cell still absent).
    parent = self()

    standin =
      spawn_link(fn ->
        {:ok, _} = Registry.register(SalixAgent.Registry, a, nil)
        send(parent, :standin_registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :standin_registered, 1_000

    task =
      Task.async(fn ->
        {:ok, pid} =
          Fleet.start_session_actor(SalixAgent.InternalSessionActor,
            agent_id: a,
            session_id: session,
            process_on_init: false
          )

        SalixAgent.InternalSessionActor.stage_control(
          pid,
          %{payload: %{kind: "session_update", session_id: session, name: "after claim"}},
          5_000
        )
      end)

    # On the pre-fix head the funnel skipped the wait for the registered
    # key and the write returned {:error, :fenced} before the claim
    # landed. Now the unbound state waits like a fresh start.
    assert Task.yield(task, 150) == nil

    :ok = OwnershipCell.install(a, 3)
    assert {:ok, :committed} = Task.await(task, 2_000)

    assert [{^replacement, %{runtime_epoch: 3}}] = Registry.lookup(SalixAgent.Registry, key)
    assert {:ok, state} = SalixAgent.TestSupport.SessionData.read(a, session)
    assert state.runtime_epoch == 3
    assert state.name == "after claim"

    send(standin, :done)
  end

  test "a supervisor-restarted external actor binds its generation to the installed claim",
       %{agent: a} do
    # Same round-4 contract for the external actor type: the replacement's
    # binding runs in its own handle_continue, waits out the in-flight
    # claim, and freezes the installed epoch.
    session = "ses1_0000000000000000811"

    :ok = OwnershipCell.install(a, 2)

    {:ok, actor} =
      Fleet.start_session_actor(SalixAgent.ExternalSessionActor,
        agent_id: a,
        session_id: session,
        process_on_init: false
      )

    # busy? serializes behind the binding continue: frozen at 2.
    _ = SalixAgent.ExternalSessionActor.busy?(actor, 1_000)
    key = SalixAgent.ExternalSessionActor.key(a, session)
    assert [{^actor, %{runtime_epoch: 2}}] = Registry.lookup(SalixAgent.Registry, key)

    :ok = OwnershipCell.clear(a)
    parent = self()

    standin =
      spawn_link(fn ->
        {:ok, _} = Registry.register(SalixAgent.Registry, a, nil)
        send(parent, :standin_registered)

        receive do
          :done -> :ok
        end
      end)

    assert_receive :standin_registered, 1_000

    ref = Process.monitor(actor)
    Process.exit(actor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^actor, :killed}, 1_000

    assert eventually(fn ->
             case Registry.lookup(SalixAgent.Registry, key) do
               [{pid, _}] -> pid != actor
               [] -> false
             end
           end)

    [{replacement, _}] = Registry.lookup(SalixAgent.Registry, key)
    :ok = OwnershipCell.install(a, 3)
    _ = SalixAgent.ExternalSessionActor.busy?(replacement, 1_000)

    assert [{^replacement, %{runtime_epoch: 3}}] = Registry.lookup(SalixAgent.Registry, key)

    send(standin, :done)
  end

  test "fault-injection restarts do not exhaust the shared test FleetSup", %{agent: a} do
    # Several ownership cases deliberately crash :transient children. OTP's
    # production default collapses a supervisor after the fourth restart in
    # five seconds, so those independent test failures need an isolated test
    # restart budget instead of sharing the production circuit breaker.
    fleet = Process.whereis(SalixAgent.FleetSup)
    :ok = OwnershipCell.install(a, 2)

    for suffix <- 813..816 do
      session = "ses1_0000000000000000#{suffix}"

      {:ok, actor} =
        Fleet.start_session_actor(SalixAgent.ExternalSessionActor,
          agent_id: a,
          session_id: session,
          process_on_init: false
        )

      key = SalixAgent.ExternalSessionActor.key(a, session)
      _ = SalixAgent.ExternalSessionActor.busy?(actor, 1_000)

      ref = Process.monitor(actor)
      Process.exit(actor, :kill)
      assert_receive {:DOWN, ^ref, :process, ^actor, :killed}, 1_000

      assert eventually(fn ->
               case Registry.lookup(SalixAgent.Registry, key) do
                 [{replacement, _}] -> replacement != actor
                 [] -> false
               end
             end)

      :ok = Fleet.stop(key)
    end

    assert Process.whereis(SalixAgent.FleetSup) == fleet
    assert Process.alive?(fleet)
  end

  test "running? counts session actors without a root Server", %{agent: a} do
    refute Fleet.running?(a)
    fake = start_fake_session_actor!(a, "ses1_0000000000000000802", false)

    assert Fleet.running?(a)
    refute Registry.lookup(SalixAgent.Registry, a) != []

    _ = DynamicSupervisor.terminate_child(SalixAgent.FleetSup, fake)
    assert eventually(fn -> not Fleet.running?(a) end)
  end

  test "session_work_busy? reflects the actors' own busy answer", %{agent: a} do
    refute Fleet.session_work_busy?(a)

    fake = start_fake_session_actor!(a, "ses1_0000000000000000803", false)
    refute Fleet.session_work_busy?(a)

    :ok = FakeSessionActor.set_busy(fake, true)
    assert Fleet.session_work_busy?(a)

    _ = DynamicSupervisor.terminate_child(SalixAgent.FleetSup, fake)
    assert eventually(fn -> not Fleet.session_work_busy?(a) end)
  end

  test "the park boundary renews instead of releasing while session work is busy", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    fake = start_fake_session_actor!(a, "ses1_0000000000000000804", true)

    {:ok, pid} =
      Server.start_link(
        agent_id: a,
        node_id: to_string(node()),
        sm: State,
        startup_mode: :passive,
        park_ms: 60_000,
        lease_ttl_ms: 3_000,
        lease_guard_ms: 100
      )

    assert {:parked, owned} = Server.info(pid)
    original_until = owned.head.lease_until
    assert OwnershipCell.fetch(a) == {:ok, owned.epoch}

    # Well past the original lease_until, the busy session actor must have
    # kept the Server renewing: still parked, still the durable owner, lease
    # extended — never released, never expired.
    Process.sleep(3_500)

    assert {:parked, renewed} = Server.info(pid)
    assert renewed.head.lease_until > original_until
    assert {:ok, head} = Agent.peek(a)
    assert head.owner_node == to_string(node())
    refute Agent.lease_expired?(head)

    # Once the session settles to idle, the next park expiry passivates and
    # releases — idle-but-registered actors do not hold the lease.
    :ok = FakeSessionActor.set_busy(fake, false)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000

    assert {:ok, released} = Agent.peek(a)
    assert released.owner_node == nil
  end

  test "an idle registered session actor does not hold the lease", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    _fake = start_fake_session_actor!(a, "ses1_0000000000000000805", false)

    {:ok, pid} =
      Server.start_link(
        agent_id: a,
        node_id: to_string(node()),
        sm: State,
        startup_mode: :passive,
        park_ms: 100,
        lease_ttl_ms: 3_000,
        lease_guard_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {:ok, head} = Agent.peek(a)
    assert head.owner_node == nil
  end

  test "passivation still releases promptly when no session actors exist", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)

    {:ok, pid} =
      Server.start_link(
        agent_id: a,
        node_id: to_string(node()),
        sm: State,
        startup_mode: :passive,
        park_ms: 100,
        lease_ttl_ms: 3_000,
        lease_guard_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    assert {:ok, head} = Agent.peek(a)
    assert head.owner_node == nil
  end
end
