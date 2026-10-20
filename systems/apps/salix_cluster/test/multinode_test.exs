defmodule SalixCluster.MultinodeTest do
  @moduledoc """
  Real two-node distribution test: the central safety property is that
  **S3 head-CAS fencing holds across nodes** — when a second node claims an agent,
  the first node's stale handle can no longer commit. Both nodes share the same
  MinIO bucket, so this exercises genuine cross-node CAS, not a single-VM
  simulation.

  Also checks ring-routed `ensure_started`: a delivery accepted on one node
  starts the owning Server on the ring-owner node.

  Requires BEAM distribution (epmd + a peer node). If distribution can't start in
  the environment, the whole module is skipped.
  """
  use SystemsClock.Case, async: false

  alias SalixCluster.{ConversationPlacement, Schedules, TaskSchedules}
  alias SalixIM.{ConversationGroupActor, ConversationServer, Conversations}
  alias SalixStore.{Agent, Ids, Keys}
  alias SalixAgent.State

  @moduletag :multinode

  setup_all do
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    case ensure_distribution() do
      :ok ->
        {:ok, peer, node} = start_peer()

        on_exit(fn ->
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
        end)

        configure_peer(node)
        configure_peer_task_runtime(node)
        {:ok, node: node}

      {:error, reason} ->
        # No distribution available in this environment — skip the module.
        {:ok, skip: reason}
    end
  end

  setup context do
    if context[:skip] do
      {:ok, skip: true}
    else
      # Both nodes use the real MinIO backend (shared state); fakes are per-VM.
      SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
      SystemsRuntime.put_env(:salix_store, :s3_endpoint, multinode_s3_endpoint())
      SystemsRuntime.put_env(:salix_store, :s3_bucket, "salix-test")
      # The schedules table is shared with the peer through the same control
      # Postgres; truncate so a sweep only sees this test's definitions.
      SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")

      {:ok,
       agent: "mn-#{Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false)}"}
    end
  end

  @tag :owner_retry_fix
  test "RPC refusal fences stale placement and retries on the current owner", ctx do
    unless ctx[:skip] do
      id = SalixAgent.TestSupport.new_agent_id()
      SalixAgent.TestSupport.create_control_agent!(id)
      {:ok, root} = SalixAgent.Fleet.ensure_started(id, create: false, startup_mode: :passive)
      :sys.get_state(root)
      :sys.suspend(root)
      sid = Ids.new_session_id()

      on_exit(fn ->
        if SystemsRuntime.Proc.alive?(root), do: :sys.resume(root)

        for key <- [
              SalixAgent.InternalSessionActor.key(id, sid),
              SalixAgent.AgentActor.key(id),
              id
            ] do
          SalixAgent.Fleet.stop(key)
          :erpc.call(ctx.node, SalixAgent.Fleet, :stop, [key])
        end

        SalixAgent.OwnershipCell.clear(id)
      end)

      # Hold renewal so the RPC fence must observe takeover itself.
      assert {:ok, _} = SalixAgent.OwnershipCell.fetch(id)

      {:ok, _} =
        :erpc.call(ctx.node, Agent, :claim, [id, to_string(ctx.node), State, [steal: true]])

      input = %{session_id: sid, content: "retry on the new owner"}
      opts = [source_message_id: "owner-retry-input", no_wake: true]
      assert {:ok, :created} = SalixAgent.deliver(id, input, opts)
      assert {:ok, :duplicate} = SalixAgent.deliver(id, input, opts)
      {:ok, session} = SalixAgent.InternalSessionStore.read(id, sid)
      assert length(SalixAgent.InternalSession.export(session).input_queue) == 1

      assert [] =
               Registry.lookup(SalixAgent.Registry, SalixAgent.InternalSessionActor.key(id, sid))

      assert [{remote, _}] =
               :erpc.call(ctx.node, Registry, :lookup, [
                 SalixAgent.Registry,
                 SalixAgent.InternalSessionActor.key(id, sid)
               ])

      assert node(remote) == ctx.node
    end
  end

  test "cross-node fencing: a peer claim fences the original node's handle", %{} = ctx do
    if ctx[:skip], do: skip(), else: run_fencing(ctx)
  end

  defmodule LostNotification do
    def notify_conversation(_, _), do: :ok
  end

  test "two nodes append one Task command for the same scheduled window", %{} = ctx do
    if ctx[:skip] do
      skip()
    else
      previous_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)

      on_exit(fn ->
        restore_env(:salix_im, :conversation_placement, previous_placement)
      end)

      run_task_schedule_concurrency(ctx)
    end
  end

  test "group collection placement starts its owner on the ring peer", %{} = ctx do
    if ctx[:skip], do: skip(), else: run_group_collection_placement(ctx)
  end

  defp run_fencing(%{node: node, agent: a}) do
    # Node A (this VM) creates and commits once.
    {:ok, o1} = Agent.create(a, "nodeA", State)

    {:ok, o1} =
      Agent.commit(o1, [
        %{"type" => "session_created", "session_id" => "ses1_1200000000000000001"}
      ])

    # Node B (peer) claims by stealing — a genuine cross-node head CAS.
    assert {:ok, peer_owned} =
             :erpc.call(node, Agent, :claim, [a, "nodeB", State, [steal: true]])

    assert peer_owned.epoch == 2

    # Node A's now-stale handle must be fenced on its next commit.
    assert {:error, :fenced} =
             Agent.commit(o1, [
               %{"type" => "session_created", "session_id" => "ses1_1200000000000000002"}
             ])

    # The peer (current owner) can still commit.
    assert {:ok, _} =
             :erpc.call(node, Agent, :commit, [
               peer_owned,
               [%{"type" => "session_created", "session_id" => "ses1_1200000000000000003"}],
               []
             ])
  end

  defp run_task_schedule_concurrency(%{node: peer_node}) do
    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Multinode Task Schedule"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Multinode Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Multinode Worker",
        "role" => "worker"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    assert {:ok, %{"conversation_id" => conversation_id}} =
             TaskSchedules.create_task_conversation(
               group_id,
               router["agent_id"],
               worker["agent_id"],
               %{
                 "title" => "Cross-node scheduled Task",
                 "content" => "Run this complete command once across both nodes.",
                 "client_request_id" => "multinode-task-command"
               }
             )

    assert {:ok, scheduled} =
             TaskSchedules.update_task_schedule(group_id, conversation_id, %{
               "interval_minutes" => 5
             })

    schedule_id = scheduled["schedule"]["schedule_id"]
    assert {:ok, schedule} = Schedules.get(schedule_id)
    due = Schedules.next_fire_ms(schedule)

    local = SystemsRuntime.Task.async(fn -> Schedules.run_once(now: due) end)

    remote =
      SystemsRuntime.Task.async(fn ->
        :erpc.call(peer_node, Schedules, :run_once, [[now: due]], 30_000)
      end)

    results = [
      SystemsRuntime.Task.await(local, :infinity),
      SystemsRuntime.Task.await(remote, :infinity)
    ]

    assert Enum.all?(results, fn {:ok, result} ->
             Enum.all?(result.failed, fn {id, _reason} -> id != schedule_id end)
           end)

    assert Enum.sum(for {:ok, result} <- results, do: length(result.fired)) >= 1

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert length(messages) == 2
    assert length(Enum.filter(messages, &get_in(&1, ["metadata", "task_schedule"]))) == 1
  end

  defp run_group_collection_placement(%{node: peer_node}) do
    assert peer_node in SalixCluster.Ring.nodes()
    group_id = group_owned_by(peer_node)

    assert {:ok, owner} = ConversationPlacement.ensure_group_started(group_id, [])
    assert node(owner) == peer_node

    assert [{^owner, _value}] =
             :erpc.call(peer_node, Registry, :lookup, [
               SalixIM.ConversationRegistry,
               SalixIM.ConversationGroupActor.key(group_id)
             ])

    assert :ok =
             :erpc.call(peer_node, DynamicSupervisor, :terminate_child, [
               SalixIM.ConversationFleetSup,
               owner
             ])
  end

  # ---- distribution helpers ----

  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      name = :"salix_main_#{SystemsRuntime.Proc.unique_integer([:positive])}@127.0.0.1"

      case :net_kernel.start([name, :longnames]) do
        {:ok, _} ->
          :erlang.set_cookie(Node.self(), :salix_test_cookie)
          :ok

        # Try shortnames as a fallback (some envs only allow sname).
        {:error, _} ->
          case :net_kernel.start([:salix_main, :shortnames]) do
            {:ok, _} ->
              :erlang.set_cookie(Node.self(), :salix_test_cookie)
              :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  rescue
    e -> {:error, e}
  end

  defp start_peer do
    [_, host] = String.split(to_string(Node.self()), "@")
    name = :"salix_peer_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    cookie = Atom.to_charlist(:erlang.get_cookie())
    long? = String.contains?(host, ".")

    # :peer sets the node name from name/host/longnames; pass only the cookie in
    # args (passing -name/-sname here causes a "Multiple -name" conflict).
    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: String.to_charlist(host),
        longnames: long?,
        connection: :standard_io,
        args: [~c"-setcookie", cookie]
      })

    true = Node.connect(node)
    {:ok, peer, node}
  end

  defp configure_peer(node) do
    # Make the umbrella code visible on the peer and start the storage app there.
    :erpc.call(node, :code, :add_pathsz, [:code.get_path()])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_store,
        :s3_endpoint,
        multinode_s3_endpoint()
      ])

    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :s3_region, "us-east-1"])
    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :s3_bucket, "salix-test"])
    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :s3_access_key_id, "minioadmin"])

    :ok =
      :erpc.call(node, Application, :put_env, [:salix_store, :s3_secret_access_key, "minioadmin"])

    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :s3_backend, SalixStore.S3.AWS])
    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :snowflake_worker_id, 1])

    # Schedules live in the control Postgres: mirror this node's repo config so
    # the peer's sweep reads the same schedules table (the shared-store analog
    # of pointing both nodes at one MinIO bucket). The peer boots from a bare
    # app env — without this the repo never starts there and every schedule
    # call degrades to {:error, :unavailable}.
    repo_config = SystemsRuntime.get_env(:salix_store, SalixStore.Repo)
    :ok = :erpc.call(node, Application, :put_env, [:salix_store, SalixStore.Repo, repo_config])
    :ok = :erpc.call(node, Application, :put_env, [:salix_store, :start_repo, true])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:salix_store])
    :ok
  end

  defp configure_peer_task_runtime(node) do
    :ok = :erpc.call(node, Application, :put_env, [:salix_env, :transfer_port, 0])
    :ok = :erpc.call(node, Application, :put_env, [:salix_cluster, :enabled, false])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:salix_cluster])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

    case :erpc.call(node, Supervisor, :start_child, [
           SalixCluster.Supervisor,
           {Phoenix.PubSub, name: SalixWeb.PubSub}
         ]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_agent,
        :notifiers,
        [SalixWeb.PubSubNotifier]
      ])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :salix_im,
        :conversation_placement,
        SalixIM.ConversationPlacement.LocalFleet
      ])

    :ok
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp multinode_s3_endpoint do
    System.get_env("SALIX_CLUSTER_TEST_S3_ENDPOINT", "http://127.0.0.1:19000")
  end

  defp group_owned_by(owner) do
    Enum.find_value(1..10_000, fn _idx ->
      tenant_id = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant_id)
      if SalixCluster.Ring.owner("conversation-group:" <> group_id) == owner, do: group_id
    end) || flunk("no conversation group id mapped to #{inspect(owner)}")
  end

  defp skip, do: ExUnit.configure(exclude: [])
end
