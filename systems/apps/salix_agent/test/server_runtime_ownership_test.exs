defmodule SalixAgent.ServerRuntimeOwnershipTest do
  require SystemsRuntime.Proc

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
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
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
      SystemsRuntime.Proc.send(parent, {:registered, key})
      {:ok, %{busy: busy}}
    end

    @impl true
    def handle_call(:busy?, _from, state), do: {:reply, state.busy, state}
    def handle_call({:set_busy, busy}, _from, state), do: {:reply, :ok, %{state | busy: busy}}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp start_fake_session_actor!(agent_id, session_id, busy, epoch \\ nil) do
    key = {:internal_session, agent_id, session_id}

    child = %{
      id: {:fake_session, session_id},
      start: {FakeSessionActor, :start_link, [{key, busy, epoch, SystemsRuntime.Proc.self()}]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(SalixAgent.FleetSup, child)
    settle_receive({:registered, ^key})
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
    fake_ref = SystemsRuntime.Proc.monitor(fake)
    server_ref = SystemsRuntime.Proc.monitor(server)

    # Another node steals the root (epoch bump); our Server's next cycle
    # observes the fence and must take the whole local runtime down with it.
    {:ok, _thief} = Agent.claim(a, "thief-node", State, steal: true)
    Server.wake(server)

    settle_receive({:DOWN, ^server_ref, :process, ^server, server_reason})
    assert server_reason in [:normal, :shutdown]
    settle_receive({:DOWN, ^fake_ref, :process, ^fake, _fake_reason})
    assert OwnershipCell.fetch(a) == :fenced
    assert eventually(fn -> not Fleet.running?(a) end)
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
        lease_ttl_ms: 1_500,
        lease_guard_ms: 100
      )

    assert {:parked, owned} = Server.info(pid)
    original_until = owned.head.lease_until
    assert OwnershipCell.fetch(a) == {:ok, owned.epoch}

    # Well past the original lease_until, the busy session actor must have
    # kept the Server renewing: still parked, still the durable owner, lease
    # extended — never released, never expired.
    SystemsClock.sleep(2_000)

    assert {:parked, renewed} = Server.info(pid)
    assert renewed.head.lease_until > original_until
    assert {:ok, head} = Agent.peek(a)
    assert head.owner_node == to_string(node())
    refute Agent.lease_expired?(head)

    # Once the session settles to idle, the next park expiry passivates and
    # releases — idle-but-registered actors do not hold the lease.
    :ok = FakeSessionActor.set_busy(fake, false)
    ref = SystemsRuntime.Proc.monitor(pid)
    settle_receive({:DOWN, ^ref, :process, ^pid, :normal})
    assert {:ok, released} = Agent.peek(a)
    assert released.owner_node == nil
  end

  for {name, idle_actor?} <- [
        {"an idle registered session actor does not hold the lease", true},
        {"passivation still releases promptly when no session actors exist", false}
      ] do
    test name, %{agent: a} do
      SalixAgent.TestSupport.create_control_agent!(a)

      if unquote(idle_actor?),
        do: start_fake_session_actor!(a, "ses1_0000000000000000805", false)

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

      ref = SystemsRuntime.Proc.monitor(pid)
      settle_receive({:DOWN, ^ref, :process, ^pid, :normal})
      assert {:ok, head} = Agent.peek(a)
      assert head.owner_node == nil
    end
  end
end
