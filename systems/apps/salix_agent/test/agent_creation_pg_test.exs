defmodule SalixAgent.AgentCreationPGTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{AgentWorkspace, Control, InternalSession, TestSupport}
  alias SalixAgent.InternalSessionStore.PG
  alias SalixStore.{Agent, AgentPGStore, Ids, Keys, Repo, S3}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    on_exit(fn ->
      TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    source = TestSupport.create_control_agent!(TestSupport.new_agent_id())
    target_id = Ids.new_agent_id(source["group_id"])

    attrs = %{
      "group_id" => source["group_id"],
      "role" => "worker",
      "fork_from" => source["agent_id"]
    }

    {:ok, source: source, target_id: target_id, attrs: attrs}
  end

  test "copy and seed complete before concurrent ensure, read, list or claim may succeed", ctx do
    source_session = Ids.new_session_id()
    assert {:ok, source_head} = AgentPGStore.peek(ctx.source["agent_id"])
    assert {:ok, _} = PG.create(ctx.source["agent_id"], source_session, source_head.epoch)

    target_session =
      SalixAgent.InternalAgentRuntime.derive_fork_target_id(
        source_session,
        "clone-" <> ctx.target_id <> "-" <> source_session
      )

    S3.Fake.set_fault({:pause, :get, Keys.agent_workspace_state(ctx.source["agent_id"])})
    parent = SystemsRuntime.Proc.self()

    creation =
      SystemsRuntime.Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          SystemsRuntime.Proc.send(parent, {:creation_backend, backend_pid})
          Control.create_owned_preallocated(ctx.attrs, ctx.source["tenant_id"], ctx.target_id)
        end)
      end)

    settle_receive({:creation_backend, backend_pid})
    S3.Fake.await_pause()
    assert_unpublished(ctx)

    {:ok, blocker} =
      Postgrex.start_link(
        Repo.config()
        |> Keyword.take([:hostname, :port, :username, :password, :database])
      )

    try do
      Postgrex.query!(blocker, "BEGIN", [])

      Postgrex.query!(
        blocker,
        "INSERT INTO salix_sessions (agent_id,session_id,birth_kind,revision) VALUES ($1,$2,'internal',0)",
        [ctx.target_id, target_session]
      )

      S3.Fake.release_pause()
      assert wait_for_lock(backend_pid)
      assert_unpublished(ctx)
      Postgrex.query!(blocker, "ROLLBACK", [])
      assert {:ok, created} = settled_await(creation)
      assert created["agent_id"] == ctx.target_id
      assert {:ok, %{state: seeded}} = PG.read(ctx.target_id, target_session)
      assert InternalSession.get(seeded, :source_session_id) == source_session
      assert {:ok, _} = Control.get_record(ctx.target_id)

      assert {:ok, _} =
               Control.create_owned_preallocated(
                 ctx.attrs,
                 ctx.source["tenant_id"],
                 ctx.target_id
               )
    after
      Postgrex.query!(blocker, "ROLLBACK", [])
      GenServer.stop(blocker)
    end
  end

  test "failed copy removes only its unpublished Agent and never confirms it to another ensure",
       ctx do
    assert {:ok, write} =
             AgentWorkspace.prepare_write(ctx.source["agent_id"], "/kept.txt", "source")

    assert {:ok, :seeded} =
             AgentWorkspace.seed_operation(ctx.source["agent_id"], "source", :seeded, [write])

    S3.Fake.set_fault({:pause, :put, Keys.agent_workspace_state(ctx.target_id)})

    creation =
      SystemsRuntime.Task.async(fn ->
        Control.create_owned_preallocated(ctx.attrs, ctx.source["tenant_id"], ctx.target_id)
      end)

    S3.Fake.await_pause()
    assert_unpublished(ctx)
    S3.Fake.fail_pause(503)
    assert {:error, {:http, 503}} = settled_await(creation)

    assert {:ok, %{rows: [[0]]}} =
             Repo.query("SELECT count(*) FROM salix_agents WHERE agent_id=$1", [ctx.target_id])

    assert {:ok, "source"} = AgentWorkspace.read(ctx.source["agent_id"], "/kept.txt")

    assert {:ok, _} =
             Control.create_owned_preallocated(ctx.attrs, ctx.source["tenant_id"], ctx.target_id)

    assert {:ok, "source"} = AgentWorkspace.read(ctx.target_id, "/kept.txt")
  end

  test "cleanup removes full created Session rows and fences a late frozen seed", ctx do
    config = Map.merge(ctx.source, %{"agent_id" => ctx.target_id, "name" => "Target"})

    assert {:ok, original} =
             AgentPGStore.begin_create(ctx.target_id, "creator", SalixAgent.State, config)

    state = InternalSession.new(ctx.target_id, Ids.new_session_id())
    assert {:ok, seed} = PG.prepare_created_seed(original, state)
    assert {:ok, _} = PG.seed_created(seed)
    assert {:ok, _} = PG.settle_created(seed)
    assert {:ok, cleanup} = AgentPGStore.begin_cleanup(original)
    assert {:error, :fenced} = PG.seed_created(seed)
    assert :ok = AgentPGStore.cleanup_created(cleanup, &PG.delete_created_session!/2)

    assert {:ok, replacement} =
             AgentPGStore.begin_create(ctx.target_id, "creator", SalixAgent.State, config)

    assert {:error, :fenced} = PG.settle_created(seed)
    assert :ok = AgentPGStore.publish_created(replacement)
  end

  defp assert_unpublished(ctx) do
    assert {:error, :unavailable} =
             Control.create_owned_preallocated(ctx.attrs, ctx.source["tenant_id"], ctx.target_id)

    assert {:error, :not_found} = Control.get_record(ctx.target_id)

    assert {:ok, %{items: items}} =
             Control.page_agents(ctx.source["tenant_id"], ctx.source["group_id"])

    refute Enum.any?(items, &(&1["agent_id"] == ctx.target_id))

    assert {:error, :not_found} =
             Agent.claim(ctx.target_id, to_string(node()), SalixAgent.State, steal: true)
  end

  defp wait_for_lock(backend_pid) do
    settle_until(fn ->
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid]).rows ==
        [["Lock"]]
    end)
  end
end
