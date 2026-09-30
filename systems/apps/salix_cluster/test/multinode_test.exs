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
  use ExUnit.Case, async: false

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
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
      Application.put_env(:salix_store, :s3_endpoint, multinode_s3_endpoint())
      Application.put_env(:salix_store, :s3_bucket, "salix-test")
      # The schedules table is shared with the peer through the same control
      # Postgres; truncate so a sweep only sees this test's definitions.
      SalixStore.Repo.query!("TRUNCATE schedules, schedule_runs")
      {:ok, agent: "mn-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"}
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
        if Process.alive?(root), do: :sys.resume(root)

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

  test "a remapped peer delivers to the still-leased owner without stealing its lease", ctx do
    if ctx[:skip] do
      skip()
    else
      peer = ctx.node

      agent_id =
        Enum.find_value(1..10_000, fn _ ->
          id = SalixAgent.TestSupport.new_agent_id()
          if SalixCluster.Ring.owner(id) == peer, do: id
        end)

      assert is_binary(agent_id)
      SalixAgent.TestSupport.create_control_agent!(agent_id)
      assert {:ok, _owned} = Agent.claim(agent_id, to_string(node()), State)

      on_exit(fn -> SalixAgent.Fleet.stop(agent_id) end)
      assert SalixCluster.Ring.owner(agent_id) == peer

      assert {:ok, pid} =
               :erpc.call(peer, SalixCluster.Placement, :ensure_started, [
                 agent_id,
                 [create: false]
               ])

      assert node(pid) == node()

      session_id = Ids.new_session_id()

      assert {:ok, :created} =
               :erpc.call(peer, SalixAgent, :deliver, [
                 agent_id,
                 %{session_id: session_id, content: "rolling owner delivery"},
                 [source_message_id: "rolling-owner-input", no_wake: true]
               ])

      assert {:ok, session} = SalixAgent.TestSupport.SessionData.read(agent_id, session_id)

      assert Enum.any?(
               session.input_queue,
               &(get_in(&1, ["payload", "content"]) == "rolling owner delivery")
             )

      assert {:ok, head} = Agent.peek(agent_id)
      assert head.owner_node == to_string(node())
    end
  end

  defmodule LostNotification do
    def notify_conversation(_, _), do: :ok
  end

  for path <- [:notification, :queued_consumer] do
    @tag :conversation_owner_routing
    @tag routing_path: path
    test "#{path} admits on the remote owner despite a local role actor", ctx do
      unless ctx[:skip] do
        peer = ctx.node
        group = group_owned_by(node())
        agent_id = agent_owned_by(group, peer)
        tenant = Ids.tenant_id_from_group!(group)
        SalixAgent.TestSupport.create_control_group!(group, %{"router_agent_id" => agent_id})

        agent =
          SalixAgent.TestSupport.create_control_agent!(agent_id, %{
            "tenant_id" => tenant,
            "group_id" => group,
            "role" => "router"
          })

        session_id = agent["router_session_id"]
        previous = Application.get_env(:salix_agent, :conversation_source_mod)

        remote_previous =
          :erpc.call(peer, Application, :get_env, [:salix_agent, :conversation_source_mod])

        delivery = Application.get_env(:salix_im, :agent_delivery_mod)
        conversation_placement = Application.get_env(:salix_im, :conversation_placement)

        Application.put_env(
          :salix_im,
          :conversation_placement,
          SalixIM.ConversationPlacement.LocalFleet
        )

        Application.put_env(:salix_im, :agent_delivery_mod, LostNotification)
        Application.put_env(:salix_agent, :conversation_source_mod, nil)
        :erpc.call(peer, Application, :put_env, [:salix_agent, :conversation_source_mod, nil])

        on_exit(fn ->
          for key <- [
                SalixAgent.InternalSessionActor.key(agent_id, session_id),
                SalixAgent.AgentActor.key(agent_id),
                agent_id
              ] do
            SalixAgent.Fleet.stop(key)
            :erpc.call(peer, SalixAgent.Fleet, :stop, [key])
          end

          restore_env(:salix_agent, :conversation_source_mod, previous)
          restore_env(:salix_im, :agent_delivery_mod, delivery)
          restore_env(:salix_im, :conversation_placement, conversation_placement)
          restore_remote_env(peer, :salix_agent, :conversation_source_mod, remote_previous)
        end)

        {:ok, conversation} = SalixIM.RouterConversationInput.ensure(group)

        {:ok, root} =
          SalixAgent.Placement.ensure_started(agent_id, create: false, startup_mode: :passive)

        assert node(root) == peer

        {:ok, _} =
          :erpc.call(peer, SalixAgent.InternalSessionFleet, :ensure_started, [
            agent_id,
            session_id,
            [process_on_init: false]
          ])

        {:ok, local_actor} = SalixAgent.AgentActor.ensure_started(agent)
        refute SalixAgent.Fleet.server_running?(agent_id)
        assert node(local_actor) == node()

        assert {:error, {:agent_owner_remote, ^peer}} =
                 SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id,
                   process_on_init: false
                 )

        {:ok, message} =
          SalixIM.RouterConversationInput.append_provider_input(group, "remote-owner-input", %{
            content: "Admit this once on the remote owner",
            role: "user",
            no_wake: true
          })

        source = %{
          group_id: group,
          conversation_id: conversation["conversation_id"],
          participant_id: conversation["router_participant_id"]
        }

        Application.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)

        :erpc.call(peer, Application, :put_env, [
          :salix_agent,
          :conversation_source_mod,
          SalixIM.ConversationSource
        ])

        for _ <- 1..3 do
          case ctx.routing_path do
            :notification ->
              assert :ok = SalixAgent.AgentActor.notify_conversation(agent_id, source)

            :queued_consumer ->
              GenServer.cast(local_actor, {:conversation_source, source})
          end
        end

        assert eventually(
                 fn ->
                   case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
                     {:ok, session} ->
                       progress =
                         SalixAgent.InternalSession.conversation_sources(session)[
                           source.participant_id
                         ]

                       is_map(progress) and progress["seq"] == message["seq"]

                     _ ->
                       false
                   end
                 end,
                 200
               )

        {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
        progress = SalixAgent.InternalSession.conversation_sources(session)[source.participant_id]
        refute progress["last_rejection"]
        assert length(SalixAgent.InternalSession.export(session).input_queue) == 1
        assert SalixAgent.InternalSession.input_dedupe_member?(session, "remote-owner-input")
        refute SalixAgent.Fleet.server_running?(agent_id)
      end
    end
  end

  test "two nodes append one Task command for the same scheduled window", %{} = ctx do
    if ctx[:skip] do
      skip()
    else
      previous_placement = Application.get_env(:salix_im, :conversation_placement)

      on_exit(fn ->
        restore_env(:salix_im, :conversation_placement, previous_placement)
      end)

      run_task_schedule_concurrency(ctx)
    end
  end

  test "group collection placement starts its owner on the ring peer", %{} = ctx do
    if ctx[:skip], do: skip(), else: run_group_collection_placement(ctx)
  end

  test "group list invalidations cross independent conversation and group owner placement",
       %{} =
         ctx do
    if ctx[:skip], do: skip(), else: run_cross_owner_group_list_invalidations(ctx)
  end

  test "participant realtime snapshot crosses independent agent and conversation owners",
       %{} = ctx do
    if ctx[:skip], do: skip(), else: run_cross_owner_participant_realtime(ctx)
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
    Application.put_env(
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

    local = Task.async(fn -> Schedules.run_once(now: due) end)

    remote =
      Task.async(fn ->
        :erpc.call(peer_node, Schedules, :run_once, [[now: due]], 30_000)
      end)

    results = [Task.await(local, 30_000), Task.await(remote, 30_000)]

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

  defp run_cross_owner_group_list_invalidations(%{node: peer_node}) do
    previous_local = Application.get_env(:salix_im, :conversation_placement)

    previous_peer =
      :erpc.call(peer_node, Application, :get_env, [:salix_im, :conversation_placement])

    on_exit(fn ->
      restore_env(:salix_im, :conversation_placement, previous_local)
      restore_remote_env(peer_node, :salix_im, :conversation_placement, previous_peer)
    end)

    Application.put_env(
      :salix_im,
      :conversation_placement,
      SalixCluster.ConversationPlacement
    )

    :ok =
      :erpc.call(peer_node, Application, :put_env, [
        :salix_im,
        :conversation_placement,
        SalixCluster.ConversationPlacement
      ])

    placements = [
      {peer_node, Node.self()},
      {Node.self(), peer_node}
    ]

    Enum.each(placements, fn {group_owner, conversation_owner} ->
      group_id = group_owned_by(group_owner)
      conversation_id = conversation_owned_by(group_id, conversation_owner)
      user_id = "cross-owner-user"

      SalixAgent.TestSupport.create_control_group!(group_id, %{
        "name" => "Cross-owner Group Task SSE"
      })

      assert {:ok, %{"owner_pid" => group_owner_pid, "version" => initial_version}} =
               ConversationServer.subscribe_group_conversation_list(
                 group_id,
                 "agent_task",
                 self()
               )

      assert node(group_owner_pid) == group_owner

      assert_registry_owner(
        peer_node,
        ConversationGroupActor.key(group_id),
        group_owner_pid,
        group_owner
      )

      assert {:ok, %{"conversation_id" => ^conversation_id}} =
               SalixIM.ConversationInput.create_group_conversation_with_id(
                 group_id,
                 conversation_id,
                 %{
                   "kind" => "agent_task",
                   "title" => "Cross-owner Task",
                   "status" => "active",
                   "participants" => [
                     %{"actor_type" => "user", "user_id" => user_id}
                   ]
                 }
               )

      assert {:ok, %{"owner_pid" => conversation_owner_pid}} =
               ConversationServer.subscribe_group_conversation(
                 group_id,
                 conversation_id,
                 self()
               )

      assert node(conversation_owner_pid) == conversation_owner

      assert_registry_owner(
        peer_node,
        SalixIM.ConversationActor.key(group_id, conversation_id),
        conversation_owner_pid,
        conversation_owner
      )

      assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                      ^conversation_id, created_version},
                     2_000

      assert created_version != initial_version

      assert {:ok, %{"status" => "completed"}} =
               ConversationServer.update_group_conversation(group_id, conversation_id, %{
                 "status" => "completed"
               })

      assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                      ^conversation_id, updated_version},
                     2_000

      assert updated_version != created_version

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_message(
                 group_id,
                 conversation_id,
                 %{
                   "actor_type" => "user",
                   "user_id" => user_id,
                   "client_request_id" => "cross-owner-task-follow-up",
                   "content" => "Follow up across owners"
                 }
               )

      assert_receive {:group_conversation_list_invalidated, ^group_id, "agent_task",
                      ^conversation_id, message_version},
                     2_000

      assert message_version != updated_version

      if group_owner == peer_node and conversation_owner == Node.self() do
        assert Node.disconnect(peer_node)

        try do
          assert eventually(fn -> peer_node not in SalixCluster.Ring.nodes() end)

          assert {:ok, %{"status" => "failed"}} =
                   ConversationServer.update_group_conversation(group_id, conversation_id, %{
                     "status" => "failed"
                   })

          assert {:ok, %{"status" => "failed"}} =
                   Conversations.get_group_conversation(group_id, conversation_id)
        after
          _ = Node.connect(peer_node)
        end

        assert eventually(fn ->
                 peer_node in SalixCluster.Ring.nodes() and
                   SalixCluster.Ring.owner("conversation-group:" <> group_id) == peer_node
               end)

        assert {:ok, %{"resync_required" => true, "owner_pid" => reconnected_owner}} =
                 ConversationServer.subscribe_group_conversation_list(
                   group_id,
                   "agent_task",
                   self()
                 )

        assert node(reconnected_owner) == peer_node

        assert {:ok, %{"data" => reloaded}} =
                 Conversations.list_group_conversations(group_id,
                   kind: "agent_task",
                   limit: 10
                 )

        assert Enum.find(reloaded, &(&1["conversation_id"] == conversation_id))["status"] ==
                 "failed"
      end
    end)
  end

  defp run_cross_owner_participant_realtime(%{node: peer_node}) do
    previous_local_conversation_placement =
      Application.get_env(:salix_im, :conversation_placement)

    previous_peer_conversation_placement =
      :erpc.call(peer_node, Application, :get_env, [:salix_im, :conversation_placement])

    previous_local_session_activity =
      Application.get_env(:salix_im, :session_activity_mod)

    on_exit(fn ->
      restore_env(
        :salix_im,
        :conversation_placement,
        previous_local_conversation_placement
      )

      restore_env(:salix_im, :session_activity_mod, previous_local_session_activity)

      restore_remote_env(
        peer_node,
        :salix_im,
        :conversation_placement,
        previous_peer_conversation_placement
      )
    end)

    Application.put_env(
      :salix_im,
      :conversation_placement,
      SalixCluster.ConversationPlacement
    )

    Application.put_env(
      :salix_im,
      :session_activity_mod,
      Salix.Bindings.IMSessionActivity
    )

    :ok =
      :erpc.call(peer_node, Application, :put_env, [
        :salix_im,
        :conversation_placement,
        SalixCluster.ConversationPlacement
      ])

    group_id = group_owned_by(Node.self())
    conversation_id = conversation_owned_by(group_id, Node.self())
    tenant_id = Ids.tenant_id_from_group!(group_id)
    agent_id = agent_owned_by(group_id, peer_node)
    requested_session_id = Ids.new_session_id()
    now = System.system_time(:millisecond)

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "name" => "Cross-owner Participant realtime",
      "router_agent_id" => agent_id
    })

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Cross-owner Router",
      "role" => "router"
    })

    assert {:ok, agent_owner_pid} =
             SalixAgent.Placement.ensure_started(agent_id,
               create: false,
               startup_mode: :passive
             )

    assert node(agent_owner_pid) == peer_node

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             SalixIM.ConversationInput.create_group_conversation_with_id(
               group_id,
               conversation_id,
               %{
                 "kind" => "user_chat",
                 "title" => "Cross-owner Participant realtime",
                 "participants" => [
                   %{
                     "actor_type" => "user",
                     "user_id" => "cross-owner-user",
                     "state" => "active",
                     "notification_filter" => %{
                       "messages" => "all",
                       "statuses" => "none"
                     },
                     "created_at" => now,
                     "updated_at" => now
                   },
                   %{
                     "actor_type" => "agent",
                     "agent_id" => agent_id,
                     "agent_name" => "Cross-owner Router",
                     "role_label" => "router",
                     "state" => "active",
                     "notification_filter" => %{
                       "messages" => "none",
                       "statuses" => "none"
                     },
                     "payload" => %{"session_id" => requested_session_id},
                     "created_at" => now,
                     "updated_at" => now
                   }
                 ]
               }
             )

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))
    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    assert is_map(user_participant)
    assert is_map(agent_participant)
    session_id = get_in(agent_participant, ["payload", "session_id"])
    assert Ids.valid_session_id?(session_id)

    assert {:ok, _session} =
             SalixAgent.InternalSessionStore.prepare_create(agent_id, session_id, %{
               "status" => "active",
               "activity_status" => "thinking"
             })

    user_participant_id = user_participant["participant_id"]
    agent_participant_id = agent_participant["participant_id"]

    assert {:ok, %{"state" => "stopped"}} =
             Salix.Bindings.IMSessionActivity.get(agent_id, session_id)

    assert {:ok, %{"inserted" => true, "message_id" => source_message_id}} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => "cross-owner-user",
                 "participant_id" => user_participant_id,
                 "client_request_id" => "cross-owner-participant-source",
                 "content" => "Show the remote Participant status"
               }
             )

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               source_message_id,
               user_participant_id
             )

    response_identity =
      "rsp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    scope = %{
      "version" => 1,
      "provider" => "internal",
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "conversation_kind" => "user_chat",
      "participant_id" => agent_participant_id,
      "source_actor_type" => "user",
      "response_identity" => response_identity,
      "source_message_ids" => [source_identity],
      "source_messages" => [
        %{
          "source_message_id" => source_identity,
          "message_id" => source_message_id
        }
      ]
    }

    assert {:ok, %{"owner_pid" => participant_owner}} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               agent_participant_id,
               self()
             )

    assert node(participant_owner) == Node.self()

    assert :ok =
             :erpc.call(peer_node, SalixAgent.ActivityEvent, :thinking, [
               agent_id,
               session_id,
               "Cross-node thinking",
               scope
             ])

    assert :ok =
             :erpc.call(peer_node, SalixAgent.VisibleReply, :publish_delta, [
               agent_id,
               session_id,
               scope,
               "Cross-node draft",
               "Cross-node draft"
             ])

    assert_receive {:conversation_participant_status_changed, ^group_id, ^conversation_id,
                    ^agent_participant_id},
                   2_000

    assert {:ok,
            %{
              "activity" => %{"state" => "stopped"},
              "presentation_activity" => %{
                "status" => "running",
                "summary" => "Cross-node thinking"
              },
              "draft" => %{
                "response_key" => ^response_identity,
                "text" => "Cross-node draft"
              }
            }} =
             ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               agent_participant_id
             )
  end

  # ---- distribution helpers ----

  defp ensure_distribution do
    if Node.alive?() do
      :ok
    else
      name = :"salix_main_#{System.unique_integer([:positive])}@127.0.0.1"

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
    name = :"salix_peer_#{System.unique_integer([:positive])}"
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
    repo_config = Application.get_env(:salix_store, SalixStore.Repo)
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp multinode_s3_endpoint do
    System.get_env("SALIX_CLUSTER_TEST_S3_ENDPOINT", "http://127.0.0.1:19000")
  end

  defp restore_remote_env(node, app, key, nil),
    do: :erpc.call(node, Application, :delete_env, [app, key])

  defp restore_remote_env(node, app, key, value),
    do: :erpc.call(node, Application, :put_env, [app, key, value])

  defp group_owned_by(owner) do
    Enum.find_value(1..10_000, fn _idx ->
      tenant_id = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant_id)
      if SalixCluster.Ring.owner("conversation-group:" <> group_id) == owner, do: group_id
    end) || flunk("no conversation group id mapped to #{inspect(owner)}")
  end

  defp conversation_owned_by(group_id, owner) do
    Enum.find_value(1..10_000, fn _idx ->
      conversation_id = Ids.new_conversation_id()

      if SalixCluster.Ring.owner(group_id <> ":" <> conversation_id) == owner,
        do: conversation_id
    end) || flunk("no conversation id in #{group_id} mapped to #{inspect(owner)}")
  end

  defp agent_owned_by(group_id, owner) do
    Enum.find_value(1..10_000, fn _idx ->
      agent_id = Ids.new_agent_id(group_id)
      if SalixCluster.Ring.owner(agent_id) == owner, do: agent_id
    end) || flunk("no agent id in #{group_id} mapped to #{inspect(owner)}")
  end

  defp assert_registry_owner(peer_node, key, owner_pid, owner_node) do
    local = Registry.lookup(SalixIM.ConversationRegistry, key)

    remote =
      :erpc.call(peer_node, Registry, :lookup, [SalixIM.ConversationRegistry, key])

    if owner_node == Node.self() do
      assert [{^owner_pid, _value}] = local
      assert [] = remote
    else
      assert [] = local
      assert [{^owner_pid, _value}] = remote
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp skip, do: ExUnit.configure(exclude: [])
end
