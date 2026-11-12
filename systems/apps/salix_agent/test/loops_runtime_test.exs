defmodule SalixAgent.LoopsRuntimeTest do
  @moduledoc """
  Background Loops against the real spinfoam child: a Loop compiled with the
  BPF toolchain is created, adopted onto this node, wakes its Session through
  `agent.notify`, checkpoints, exits, restarts from its checkpoint, receives
  and acks events, is refused a capability outside the allowlist, and is unloaded when
  its Agent's Server goes away. Fixtures are compiled by the Host's embedded
  compiler; skipped where the pinned binary is absent.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, Fleet, InternalSession, InternalSessionStore, Loops}
  alias SalixAgent.Loops.Host
  alias SalixAgent.SpinfoamFixture
  alias SalixAgent.LLM.Mock
  alias SalixStore.Loops, as: Store
  alias SalixStore.S3.Fake

  @moduletag :spinfoam
  @moduletag skip:
               if(SpinfoamFixture.available?(),
                 do: false,
                 else: "spinfoam binary unavailable"
               )

  setup tags do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Fake)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SalixAgent.TestSupport.configure_control_fixtures!()

    if SystemsRuntime.Proc.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)

    case start_supervised(Mock) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Mock.script([])
    SalixStore.Repo.query!("TRUNCATE agent_loops, agent_loop_acks")

    assert %{available: true} = await(fn -> Host.status() end, &match?(%{available: true}, &1))

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, prev_store)
      restore(:salix_agent, :llm, prev_llm)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    role = if tags[:router], do: "router", else: "worker"
    agent = SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => role})

    session_id =
      if tags[:router], do: agent["router_session_id"], else: SalixStore.Ids.new_session_id()

    {:ok, _} = SalixAgent.TestSupport.SessionFixture.commit(agent_id, session_id, [])
    {:ok, _server} = Fleet.ensure_started(agent_id, create: false)
    :ok = Fleet.await_ownership_installed(agent_id)

    {:ok,
     agent_id: agent_id,
     session_id: session_id,
     ctx: %{agent_id: agent_id, session_id: session_id, role: role}}
  end

  test "a compiled Loop selects and checkpoints a source without requesting a model decision", %{
    ctx: ctx
  } do
    SalixAgent.DecideFixture.start_provider()
    loop = create_loop!(ctx, SalixAgent.Decide.example_program(:loop))
    assert_receive {:decision_request, "/v1/systemone", _, _}

    checkpoint =
      await(
        fn -> Loops.get_checkpoint(loop["loop_id"]) end,
        &(&1 == {:ok, %{"source" => "meetings"}})
      )

    assert checkpoint == {:ok, %{"source" => "meetings"}}, inspect(Store.get(loop["loop_id"]))

    assert {:ok, %{"status" => "active"}} = Store.get(loop["loop_id"])
    assert session_messages(ctx) == []
    assert {:ok, _} = Loops.pause(ctx.agent_id, loop["loop_id"])
  end

  test "accepted events survive guest replacement and stale acknowledgements cannot discard them",
       %{ctx: ctx} do
    loop = create_loop!(ctx, SpinfoamFixture.event_program())
    id = loop["loop_id"]
    assert is_binary(await(fn -> Host.object_for_loop(id) end, &is_binary/1))
    {:ok, original} = Store.get(id)
    :ok = SalixAgent.Loops.Reconciler.release_loop(ctx.agent_id, id)

    event = %{
      "event_id" => "retained",
      "topic" => "mail",
      "payload" => %{"message_id" => "mail-1"}
    }

    assert {:ok, %{"accepted" => true}} =
             Store.admit_event(
               original,
               event,
               SystemsClock.system_time(:millisecond),
               32,
               900_000
             )

    assert {:ok, receipt} = Store.get(id)
    assert receipt["pending_events"]["retained"]["payload"] == event["payload"]

    # A replacement incarnation must reject a completion from the retired guest.
    assert {:ok, newer} = Loops.begin_incarnation(id, Atom.to_string(node()), "replacement-test")
    assert newer["incarnation"] > original["incarnation"]
    assert {:error, :stale_incarnation} = Loops.ack_event(id, original["incarnation"], "retained")
    refute Store.acked?(id, "retained")

    SalixAgent.Loops.Reconciler.adopt(ctx.agent_id)
    assert await(fn -> Store.acked?(id, "retained") end, & &1)
    assert {:ok, settled} = Store.get(id)
    assert settled["pending_events"] == %{}
    assert {:ok, %{"duplicate" => true}} = Loops.send_event(ctx.agent_id, id, event)
  end

  test "stopping the Agents ends their adoptions and releases what those loaded", %{ctx: ctx} do
    loop = create_loop!(ctx, SpinfoamFixture.event_program())
    assert is_binary(await(fn -> Host.object_for_loop(loop["loop_id"]) end, &is_binary/1))
    :ok = SalixAgent.Loops.Reconciler.release_loop(ctx.agent_id, loop["loop_id"])

    # One adoption running and one waiting for it, as the Agents stop.
    SalixAgent.Loops.Reconciler.adopt(ctx.agent_id)
    SalixAgent.Loops.Reconciler.adopt(ctx.agent_id)
    SalixAgent.TestSupport.stop_all_agents()

    state = :sys.get_state(SalixAgent.Loops.Reconciler)
    assert state.inflight == %{}
    assert MapSet.size(state.pending) == 0
    assert Host.loop_objects() == %{}
  end

  test "an adoption that outlasts the budget fails the cleanup" do
    reconciler = SalixAgent.Loops.Reconciler
    # No Agent of this id exists: the adoption the test's own Agent may have in
    # flight would otherwise take its pending mark when it ends.
    agent_id = "agt-never-adopted-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    :sys.replace_state(reconciler, &%{&1 | pending: MapSet.put(&1.pending, agent_id)})

    try do
      assert_raise RuntimeError, ~r/#{agent_id}/, fn ->
        SalixAgent.TestSupport.await_adoptions(1)
      end
    after
      :sys.replace_state(reconciler, &%{&1 | pending: MapSet.delete(&1.pending, agent_id)})
    end
  end

  defp create_loop!(ctx, program, config \\ %{}) do
    elf = SpinfoamFixture.compile!(program)
    path = "/loops/#{SystemsRuntime.Proc.unique_integer([:positive])}.elf"
    {:ok, event} = AgentWorkspace.prepare_write(ctx.agent_id, path, elf)
    {:ok, _} = AgentWorkspace.seed_operation(ctx.agent_id, "runtime-test:" <> path, %{}, [event])

    {:ok, loop} =
      Loops.create(ctx, %{
        "path" => path,
        "name" => "test loop",
        "config" => config
      })

    loop
  end

  defp session_messages(ctx) do
    case InternalSessionStore.read(ctx.agent_id, ctx.session_id) do
      {:ok, session} -> InternalSession.get(session, :messages)
      _ -> []
    end
  end

  defp message_with_source(ctx, source_id) do
    Enum.find(session_messages(ctx), fn message ->
      to_string(message[:source_message_id] || message["source_message_id"] || "") == source_id
    end)
  end

  defp await(fun, pred, retries \\ 1200) do
    value = fun.()

    cond do
      pred.(value) -> value
      retries == 0 -> value
      true -> SystemsRuntime.Proc.sleep(25) && await(fun, pred, retries - 1)
    end
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  test "a loop wakes its session through agent.notify and the wake is deduplicated", %{ctx: ctx} do
    loop =
      create_loop!(ctx, SpinfoamFixture.notify_once_program("cond-1"))

    loop_id = loop["loop_id"]

    object_id = await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1)
    assert is_binary(object_id)

    message = await(fn -> message_with_source(ctx, "loop:#{loop_id}:cond-1") end, &(&1 != nil))
    assert message, "the loop's notification never reached the session"
    content = to_string(message[:content] || message["content"])
    assert content =~ "threshold crossed"
    assert content =~ "Background loop test loop"

    {:ok, shown} = Loops.get(ctx.agent_id, loop_id)
    assert shown["status"] == "active"
    assert shown["incarnation"] == 1
    assert get_in(shown, ["runtime", "state"]) in ["running", "starting"]

    {:ok, record} = Store.get(loop_id)
    assert record["notify_window_count"] == 1

    assert Enum.count(
             session_messages(ctx),
             &(to_string(&1[:source_message_id] || "") =~ "loop:#{loop_id}:")
           ) == 1
  end

  test "a checkpoint written through loop.state.put is passed back as config.state on reload", %{
    ctx: ctx
  } do
    loop =
      create_loop!(ctx, SpinfoamFixture.checkpoint_program())

    loop_id = loop["loop_id"]

    first = await(fn -> elem(Store.get(loop_id), 1) end, &(&1["status"] == "paused"))
    assert first["exit_code"] == 1
    assert first["checkpoint"] == %{"counter" => 1}

    assert {:ok, %{"status" => "active"}} = Loops.resume(ctx.agent_id, loop_id)

    second =
      await(
        fn -> elem(Store.get(loop_id), 1) end,
        &(&1["status"] == "paused" and &1["exit_code"] == 2)
      )

    assert second["checkpoint"] == %{"counter" => 2}
    # resume retires the old incarnation, adoption records the new load
    assert second["incarnation"] == 3
  end

  test "a loop runs env.exec on the environment and reports its output", %{ctx: ctx} do
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, SalixAgent.LoopEnvDispatchFixture)
    on_exit(fn -> restore(:salix_agent, :env_dispatch, previous) end)
    SalixAgent.LoopEnvDispatchFixture.register()

    loop = create_loop!(ctx, SpinfoamFixture.exec_program("df -h /"))
    loop_id = loop["loop_id"]

    assert_receive {:loop_env_exec, agent_id, %{device_id: "dev-1", environment_id: "env-1"},
                    "df -h /", %{"description" => "loop exec"}}

    assert agent_id == ctx.agent_id

    message = await(fn -> message_with_source(ctx, "loop:#{loop_id}:exec-done") end, &(&1 != nil))
    assert message != nil
    content = to_string(message[:content] || message["content"])
    assert content =~ "ran: df -h /"
    assert content =~ "\"exit_code\":0"
    assert {:ok, %{"status" => "active"}} = Store.get(loop_id)
  end

  test "a capability outside the loop allowlist is refused and never reaches the tool dispatcher",
       %{ctx: ctx} do
    loop = create_loop!(ctx, SpinfoamFixture.denied_program())
    loop_id = loop["loop_id"]

    record = await(fn -> elem(Store.get(loop_id), 1) end, &(&1["status"] == "paused"))
    # SF_DENIED: spinfoam itself refuses a name outside the allowlist it was
    # loaded with (fs.write_file here) before any host.call is issued; the
    # host's own allowlist check is the second line of defence (loops_test.exs).
    assert record["exit_code"] == -4
  end

  test "events reach the guest, are acked, and duplicates are reported", %{ctx: ctx} do
    loop =
      create_loop!(ctx, SpinfoamFixture.event_program())

    loop_id = loop["loop_id"]
    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))

    event = %{"topic" => "deploy", "payload" => %{"kind" => "deploy"}, "event_id" => "e1"}

    assert {:ok, %{"accepted" => true, "duplicate" => false}} =
             Loops.send_event(ctx.agent_id, loop_id, event)

    assert await(fn -> Store.acked?(loop_id, "e1") end, & &1)
    assert await(fn -> message_with_source(ctx, "loop:#{loop_id}:evt") end, &(&1 != nil))

    assert {:ok, %{"duplicate" => true}} = Loops.send_event(ctx.agent_id, loop_id, event)

    assert {:error, {:invalid_event, "topic"}} =
             Loops.send_event(ctx.agent_id, loop_id, %{"payload" => %{}})
  end

  test "a release that arrives during an adoption unloads what the adoption loads", %{ctx: ctx} do
    alias SalixAgent.Loops.Reconciler

    loop_id = create_loop!(ctx, SpinfoamFixture.event_program())["loop_id"]
    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))
    :ok = Reconciler.release_loop(ctx.agent_id, loop_id)

    # The Reconciler starts the adoption task before it takes the release.
    Reconciler.adopt(ctx.agent_id)
    :ok = Reconciler.release(ctx.agent_id)

    assert await(fn -> :sys.get_state(Reconciler).inflight end, &(&1 == %{})) == %{}
    assert is_nil(Host.object_for_loop(loop_id))
  end

  test "a replaced Server keeps the object an adoption loads while the old one goes down", %{
    ctx: ctx
  } do
    alias SalixAgent.Loops.Reconciler

    loop_id = create_loop!(ctx, SpinfoamFixture.idle_program())["loop_id"]
    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))
    :ok = Reconciler.release_loop(ctx.agent_id, loop_id)
    {:ok, released} = Store.get(loop_id)

    # The Reconciler takes, in order: an adoption, the old Server's exit and
    # the new Server's adoption.
    :ok = :sys.suspend(Reconciler)
    Reconciler.adopt(ctx.agent_id)
    :ok = Fleet.stop_existing(ctx.agent_id)
    {:ok, _server} = Fleet.ensure_started(ctx.agent_id, create: false)
    :ok = :sys.resume(Reconciler)
    :ok = Fleet.await_ownership_installed(ctx.agent_id)

    assert await(fn -> :sys.get_state(Reconciler).inflight end, &(&1 == %{})) == %{}
    object_id = Host.object_for_loop(loop_id)
    assert is_binary(object_id)
    {:ok, record} = Store.get(loop_id)
    assert record["object_id"] == object_id
    assert record["incarnation"] == released["incarnation"] + 1
  end

  test "an adoption after the Server stopped loads nothing", %{ctx: ctx} do
    alias SalixAgent.Loops.Reconciler

    loop_id = create_loop!(ctx, SpinfoamFixture.idle_program())["loop_id"]
    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))
    :ok = Reconciler.release_loop(ctx.agent_id, loop_id)

    # The Reconciler takes the adoption after the Server is gone; the
    # ownership cell still names this node.
    :ok = :sys.suspend(Reconciler)
    Reconciler.adopt(ctx.agent_id)
    :ok = Fleet.stop_existing(ctx.agent_id)
    :ok = :sys.resume(Reconciler)

    assert await(fn -> :sys.get_state(Reconciler).inflight end, &(&1 == %{})) == %{}
    assert is_nil(Host.object_for_loop(loop_id))
  end

  test "pause unloads the object, resume reloads it at a new incarnation", %{ctx: ctx} do
    loop =
      create_loop!(ctx, SpinfoamFixture.notify_once_program("p"))

    loop_id = loop["loop_id"]
    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))

    assert {:ok, %{"status" => "paused", "paused_by" => "user"}} =
             Loops.pause(ctx.agent_id, loop_id)

    assert is_nil(Host.object_for_loop(loop_id))

    assert {:ok, %{"status" => "active"}} = Loops.resume(ctx.agent_id, loop_id)
    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))
    {:ok, record} = Store.get(loop_id)
    assert record["incarnation"] == 3

    assert :ok = Loops.delete(ctx.agent_id, loop_id)
    assert is_nil(Host.object_for_loop(loop_id))
    assert {:error, :not_found} = Store.get(loop_id)
  end

  test "an active loop keeps its agent resident past the park timeout and still notifies", %{
    ctx: ctx
  } do
    # Create the active Loop before starting the short idle grace. Compiling
    # its fixture can exceed 300 ms, when an empty Server may correctly stop.
    loop = create_loop!(ctx, SpinfoamFixture.delayed_notify_program(1_500, "late"))
    loop_id = loop["loop_id"]

    :ok = Fleet.stop_existing(ctx.agent_id)
    {:ok, server} = Fleet.ensure_started(ctx.agent_id, create: false, park_ms: 300)
    :ok = Fleet.await_ownership_installed(ctx.agent_id)

    # An adoption from before the restart can load an object that the release
    # of the old Server then replaces: take the object once adoption settled.
    {object_id, _inflight} =
      await(
        fn ->
          {Host.object_for_loop(loop_id), :sys.get_state(SalixAgent.Loops.Reconciler).inflight}
        end,
        &match?({object, inflight} when is_binary(object) and inflight == %{}, &1)
      )

    # Without Loop retention, this Server stops before the guest's timer fires.
    assert is_binary(object_id)

    message = await(fn -> message_with_source(ctx, "loop:#{loop_id}:late") end, &(&1 != nil))
    assert message, "the loop's delayed notification never reached the session"
    assert SystemsRuntime.Proc.alive?(server)
    assert [{^server, _}] = Registry.lookup(SalixAgent.Registry, ctx.agent_id)
    assert Host.object_for_loop(loop_id) == object_id

    {:ok, record} = Store.get(loop_id)
    assert record["status"] == "active"
    assert record["object_id"] == object_id
  end

  for observe_after_recovery <- [false, true] do
    test "server stop unloads its native object with recovery observed #{if observe_after_recovery, do: "before", else: "after"} cleanup",
         %{ctx: ctx} do
      loop = create_loop!(ctx, SpinfoamFixture.idle_program())
      loop_id = loop["loop_id"]
      old_object = await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1)
      assert is_binary(old_object)
      old_ref = Map.fetch!(Host.loop_objects(), old_object)
      assert [{old_owner, _}] = Registry.lookup(SalixAgent.Registry, ctx.agent_id)

      :ok = Fleet.stop_existing(ctx.agent_id)
      refute SystemsRuntime.Proc.alive?(old_owner)

      unless unquote(observe_after_recovery), do: assert_object_unloaded(old_object)

      # A periodic sweep may already have recovered the active Loop. Drive
      # the same recovery explicitly without requiring a transient nil mapping.
      SystemsRuntime.Proc.send(SalixAgent.Loops.Reconciler, :sweep)
      :sys.get_state(SalixAgent.Loops.Reconciler)

      new_object =
        await(
          fn -> Host.object_for_loop(loop_id) end,
          &(is_binary(&1) and &1 != old_object)
        )

      assert is_binary(new_object) and new_object != old_object
      assert_object_unloaded(old_object)
      refute Map.has_key?(Host.loop_objects(), old_object)
      assert [{new_owner, _}] = Registry.lookup(SalixAgent.Registry, ctx.agent_id)
      refute new_owner == old_owner

      record = await(fn -> elem(Store.get(loop_id), 1) end, &(&1["object_id"] == new_object))
      assert record["status"] == "active"
      assert record["incarnation"] == old_ref.incarnation + 1
      assert record["object_id"] == new_object

      # A late terminal callback from the released incarnation cannot pause
      # the replacement or clear its native object identity.
      :ok =
        SalixAgent.Loops.Reconciler.object_terminal(old_ref, old_object, %{
          "state" => "exited",
          "outcome" => %{"exit_code" => 0}
        })

      assert {:ok, retained} = Store.get(loop_id)

      assert Map.take(retained, ~w(status incarnation object_id)) ==
               Map.take(record, ~w(status incarnation object_id))
    end
  end

  # The clock-driven span of the outage is in `loops_agent_outage_test.exs`.
  test "a Loop whose Agent read misses reloads when the Agent is back and reaches the Worker", %{
    ctx: ctx
  } do
    loop_id = stranded_event_loop!(ctx)
    before = hide_agent!(ctx.agent_id)

    assert {:error, :not_found} = Fleet.ensure_started(ctx.agent_id, create: false)

    sweep()
    assert %{"status" => "active", "paused_by" => nil} = elem(Store.get(loop_id), 1)

    restore_agent!(ctx.agent_id)
    sweep()

    assert is_binary(await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1))
    assert %{"status" => "active", "incarnation" => incarnation} = elem(Store.get(loop_id), 1)
    assert incarnation > before["incarnation"]

    event = %{"topic" => "deploy", "payload" => %{"kind" => "deploy"}, "event_id" => "after"}

    assert {:ok, %{"accepted" => true}} = Loops.send_event(ctx.agent_id, loop_id, event)
    assert await(fn -> message_with_source(ctx, "loop:#{loop_id}:evt") end, &(&1 != nil))
    refute message_with_source(ctx, "loop:#{loop_id}:lifecycle:undeliverable")
  end

  # An Agent Server gone with its node, as during a Pod replacement.
  defp stranded_event_loop!(ctx) do
    loop_id = create_loop!(ctx, SpinfoamFixture.event_program())["loop_id"]
    object = await(fn -> Host.object_for_loop(loop_id) end, &is_binary/1)
    :ok = Fleet.stop_existing(ctx.agent_id)
    assert_object_unloaded(object)
    loop_id
  end

  # The Agent row absent from the online store, while its Sessions remain.
  defp hide_agent!(agent_id) do
    {:ok, loop} =
      SalixStore.Repo.transaction(fn ->
        SalixStore.Repo.query!("SET LOCAL session_replication_role = replica")

        SalixStore.Repo.query!(
          "CREATE TABLE IF NOT EXISTS hidden_salix_agents (LIKE salix_agents)"
        )

        SalixStore.Repo.query!(
          "INSERT INTO hidden_salix_agents SELECT * FROM salix_agents WHERE agent_id = $1",
          [agent_id]
        )

        SalixStore.Repo.query!("DELETE FROM salix_agents WHERE agent_id = $1", [agent_id])
        {:ok, [record]} = Store.list_active_stranded([], 1)
        record
      end)

    on_exit(fn -> SalixStore.Repo.query!("DROP TABLE IF EXISTS hidden_salix_agents") end)
    loop
  end

  defp restore_agent!(agent_id) do
    SalixStore.Repo.query!(
      "INSERT INTO salix_agents SELECT * FROM hidden_salix_agents WHERE agent_id = $1",
      [agent_id]
    )
  end

  defp sweep do
    SystemsRuntime.Proc.send(SalixAgent.Loops.Reconciler, :sweep)
    :sys.get_state(SalixAgent.Loops.Reconciler)
  end

  defp assert_object_unloaded(object_id) do
    assert {:error, %{"kind" => "OBJECT_NOT_FOUND"}} =
             await(
               fn -> Host.object_get(object_id) end,
               &match?({:error, %{"kind" => "OBJECT_NOT_FOUND"}}, &1)
             )
  end
end
