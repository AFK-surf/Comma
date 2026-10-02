defmodule SalixIM.RouterConversationLogTest do
  use ExUnit.Case, async: false

  alias SalixIM.{RouterConversationInput, ConversationSource}
  alias SalixAgent.{AgentActor, InternalSession, InternalSessionStore}
  alias SalixStore.{Ids, Keys, S3}

  defmodule LostNotification do
    def notify_conversation(_, _), do: :ok
  end

  defmodule ObservedLLM do
    def complete(messages, tools) do
      send(Application.fetch_env!(:salix_im, :router_delivery_test_pid), :model_request_started)
      SalixAgent.LLM.Mock.complete(messages, tools)
    end
  end

  defmodule PausedLLM do
    def complete(_messages, _tools) do
      send(
        Application.fetch_env!(:salix_im, :router_delivery_test_pid),
        {:model_computing, self()}
      )

      receive do
        :finish ->
          {:assistant, "", [%{id: "finish", name: "end_turn", args: %{"outcome" => "done"}}]}
      after
        5_000 -> {:error, :test_timeout}
      end
    end
  end

  defmodule RuntimeEnv do
    def resolve_external_runtime_binding(config, _, _),
      do:
        {:ok,
         Map.merge(config, %{
           "connector_id" => "test-connector",
           "connector_run_id" => "test-run",
           "command" => "codex"
         })}

    def external_runtime_binding_status(config, _, _),
      do:
        {:ok,
         %{
           "status" => "ready",
           "connector_run_id" => "test-run",
           "device_runtime_id" => config["device_runtime_id"]
         }}
  end

  setup tags do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    overrides = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_im, :agent_delivery_mod, LostNotification},
      {:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity},
      {:salix_im, :router_delivery_test_pid, self()},
      {:salix_agent, :conversation_source_mod, nil},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_agent, :runtime_environment_mod, RuntimeEnv}
    ]

    previous =
      for {app, key, value} <- overrides do
        old = Application.get_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    SalixStore.Repo.query!("DELETE FROM conversation_log_recovery")
    start_supervised!(S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SalixIM.TestSupport.Fleet.stop_all!()
      Enum.each(previous, fn {app, key, value} -> Application.put_env(app, key, value) end)
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "name" => "Router",
        "runtime_config" =>
          if(tags[:runtime] == "external", do: external_runtime(), else: %{"kind" => "internal"})
      })

    {:ok, _} =
      SalixStore.CasRecord.update(
        Keys.ctl_group(group),
        &Map.put(&1, "router_agent_id", agent["agent_id"])
      )

    {:ok, conversation} = RouterConversationInput.ensure(group)
    %{group: group, agent: agent, conversation: conversation}
  end

  test "repeated Router setup preserves participants without rewriting them", ctx do
    :ok = S3.Fake.reset_put_log()
    assert {:ok, repeated} = RouterConversationInput.ensure(ctx.group)
    assert repeated["router_participant_id"] == ctx.conversation["router_participant_id"]
    assert repeated["user_participant_id"] == ctx.conversation["user_participant_id"]
    refute Enum.any?(S3.Fake.put_log(), &String.contains?(&1, "/participant_states/"))

    assert {:ok, _} =
             RouterConversationInput.append_user_message(ctx.group, %{"content" => "hello"})

    assert {:ok, _, [message]} = source_batch(ctx)
    assert message["seq"] == 1

    :ok = S3.Fake.reset_put_log()
    assert {:ok, _} = RouterConversationInput.ensure(ctx.group)
    refute Enum.any?(S3.Fake.put_log(), &String.contains?(&1, "/participant_states/"))
    assert {:ok, _, [^message]} = source_batch(ctx)
  end

  test "queued consumption restarts a missing local Server without losing its own hint", ctx do
    {:ok, message} =
      RouterConversationInput.append_provider_input(ctx.group, "local-restart", %{
        content: "Keep the hint across local Server startup",
        role: "user",
        no_wake: true
      })

    {:ok, actor} = AgentActor.ensure_started(ctx.agent)
    refute SalixAgent.Fleet.server_running?(ctx.agent["agent_id"])
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    GenServer.cast(actor, {:conversation_source, source_ref(ctx)})
    session = await_source(ctx, message["seq"])
    assert InternalSession.input_dedupe_member?(session, "local-restart")
    assert length(InternalSession.export(session).input_queue) == 1
  end

  @tag :session_optimization
  test "direct-log admission and activation share a fence while model computation starts", ctx do
    Application.put_env(:salix_agent, :llm, PausedLLM)
    agent_id = ctx.agent["agent_id"]
    session_id = ctx.agent["router_session_id"]

    {:ok, actor} =
      SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    :sys.get_state(actor)

    {:ok, _} =
      RouterConversationInput.append_user_message(ctx.group, %{"content" => "combined admission"})

    {:ok, binding, [message]} = source_batch(ctx)
    {:ok, entry} = ConversationSource.entry(binding, message)
    entry = Map.put(entry, :activate_on_admission, true)
    key = Keys.agent_internal_runtime_session(agent_id, session_id)
    :ok = S3.Fake.reset_put_log()
    :ok = S3.Fake.set_fault({:pause, :put, key})
    on_exit(fn -> if Process.whereis(S3.Fake), do: S3.Fake.release_pause() end)

    admission = Task.async(fn -> SalixAgent.InternalSessionActor.stage_delivery(actor, entry) end)
    assert_receive {:model_computing, provider}, 3_000
    assert Task.yield(admission, 20) == nil
    assert {:error, :not_found} = InternalSessionStore.read(agent_id, session_id)

    :ok = S3.Fake.release_pause()
    assert {:ok, :activated} = Task.await(admission)
    {:ok, committed} = InternalSessionStore.read(agent_id, session_id)
    assert InternalSession.input_dedupe_member?(committed, entry.source_message_id)
    assert source_progress(committed)["seq"] == message["seq"]
    assert InternalSession.get(committed, :status) == :active
    assert Enum.count(S3.Fake.put_log(), &(&1 == key)) == 1

    assert {:error, :source_busy} = SalixAgent.InternalSessionActor.stage_delivery(actor, entry)
    source = source_ref(ctx)
    SalixAgent.InternalSessionActor.watch_source(agent_id, session_id, self(), source)
    :sys.get_state(actor)
    refute_receive {:retry_conversation_source, ^source}, 50
    send(provider, :finish)
    assert_receive {:retry_conversation_source, ^source}, 1_000
  end

  @tag :session_optimization
  test "a failed combined admission cancels computation without advancing the source", ctx do
    Application.put_env(:salix_agent, :llm, PausedLLM)
    agent_id = ctx.agent["agent_id"]
    session_id = ctx.agent["router_session_id"]

    {:ok, actor} =
      SalixAgent.InternalSessionFleet.ensure_started(agent_id, session_id, process_on_init: false)

    :sys.get_state(actor)

    {:ok, _} =
      RouterConversationInput.append_user_message(ctx.group, %{"content" => "failed admission"})

    {:ok, binding, [message]} = source_batch(ctx)
    {:ok, entry} = ConversationSource.entry(binding, message)
    key = Keys.agent_internal_runtime_session(agent_id, session_id)
    :ok = S3.Fake.set_fault({:pause, :put, key})
    on_exit(fn -> if Process.whereis(S3.Fake), do: S3.Fake.release_pause() end)

    admission =
      Task.async(fn ->
        SalixAgent.InternalSessionActor.stage_delivery(
          actor,
          Map.put(entry, :activate_on_admission, true)
        )
      end)

    assert_receive {:model_computing, provider}, 3_000
    monitor = Process.monitor(provider)

    assert Enum.reduce_while(1..300, false, fn _, _ ->
             if S3.Fake.paused?() do
               {:halt, true}
             else
               Process.sleep(10)
               {:cont, false}
             end
           end)

    # A competing owner commits a different revision before the held CAS.
    assert {:ok, _} = InternalSessionStore.prepare_create(agent_id, session_id)
    assert :ok = S3.Fake.release_pause()
    assert {:error, _} = Task.await(admission, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 1_000
    {:ok, committed} = InternalSessionStore.read(agent_id, session_id)
    refute source_progress(committed)
    refute InternalSession.input_dedupe_member?(committed, entry.source_message_id)
  end

  @tag runtime: "external"
  test "new external Router conversations admit through the log", ctx do
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)

    assert {:ok, _} =
             RouterConversationInput.append_user_message(
               ctx.group,
               %{"content" => [%{"type" => "text", "text" => "external input"}]}
             )

    agent_id = ctx.agent["agent_id"]
    state = await_external(agent_id, ctx.agent["router_session_id"])
    assert Enum.any?(state["input_message_queue"], &(&1["content"] == "external input"))
    assert state["conversation_sources"][ctx.conversation["router_participant_id"]]["seq"] == 1
  end

  test "reassignment from internal to external admits through the log", ctx do
    other =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        ctx.agent["tenant_id"],
        ctx.group,
        %{"role" => "router", "name" => "External", "runtime_config" => external_runtime()}
      )

    reassign(ctx, other)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)

    assert {:ok, _} =
             RouterConversationInput.append_user_message(
               ctx.group,
               %{"content" => [%{"type" => "text", "text" => "replacement external input"}]}
             )

    agent_id = other["agent_id"]
    state = await_external(agent_id, other["router_session_id"])

    assert Enum.any?(
             state["input_message_queue"],
             &(&1["content"] == "replacement external input")
           )
  end

  test "A to B to A reuses the Session without admitting the old unconsumed suffix", ctx do
    {:ok, first} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "accepted A"}]}
      )

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    await_source(ctx, first["seq"])
    Application.put_env(:salix_agent, :conversation_source_mod, nil)
    SalixAgent.TestSupport.stop_all_agents()

    {:ok, old} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "unconsumed A"}]}
      )

    other =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        ctx.agent["tenant_id"],
        ctx.group,
        %{"role" => "router", "name" => "B"}
      )

    reassign(ctx, other)

    {:ok, _} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "B input"}]}
      )

    rebound = reassign(ctx, ctx.agent)
    assert rebound["router_participant_id"] == ctx.conversation["router_participant_id"]

    {:ok, newest} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "new A"}]}
      )

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    session = await_source(ctx, newest["seq"])
    assert InternalSession.input_dedupe_member?(session, source_id(ctx, first))
    assert InternalSession.input_dedupe_member?(session, source_id(ctx, newest))
    refute InternalSession.input_dedupe_member?(session, source_id(ctx, old))
  end

  defp reassign(ctx, agent) do
    {:ok, _} =
      SalixStore.CasRecord.update(
        Keys.ctl_group(ctx.group),
        &Map.put(&1, "router_agent_id", agent["agent_id"])
      )

    {:ok, conversation} = RouterConversationInput.ensure(ctx.group)
    conversation
  end

  defp source_id(ctx, message) do
    {:ok, source} =
      SalixIM.ConversationSourceIdentity.encode(
        ctx.conversation["conversation_id"],
        message["message_id"],
        ctx.conversation["router_participant_id"],
        nil
      )

    source
  end

  defp external_runtime do
    %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => "test-device",
      "runtime_id" => "test-runtime",
      "device_runtime_id" =>
        SalixStore.RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
    }
  end

  test "lost notifications recover from the committed log without participant delivery records",
       ctx do
    S3.Fake.reset_put_log()

    {:ok, message} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{
          "content" => [%{"type" => "text", "text" => "hello"}],
          "client_request_id" => "lost-hint"
        }
      )

    refute Enum.any?(S3.Fake.put_log(), fn key ->
             String.contains?(key, "/deliveries/") or String.contains?(key, "delivery_wakeups") or
               String.contains?(key, "/outbox/")
           end)

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    for _ <- 1..3,
        do:
          assert(
            {:ok, _} =
              SalixIM.ConversationLogRecovery.sweep(System.system_time(:millisecond) + 60_000)
          )

    session = await_source(ctx, message["seq"])

    {:ok, source} =
      SalixIM.ConversationSourceIdentity.encode(
        ctx.conversation["conversation_id"],
        message["message_id"],
        ctx.conversation["router_participant_id"],
        nil
      )

    assert InternalSession.input_dedupe_member?(session, source)

    for _ <- 1..3 do
      assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    end

    assert source_progress(await_source(ctx, message["seq"]))["seq"] ==
             message["seq"]
  end

  test "reset carries the admitted frontier and admits only the new suffix", ctx do
    {:ok, first} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "before reset"}]}
      )

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    await_source(ctx, first["seq"])

    assert {:ok, updated} =
             AgentActor.switch_router_session(
               ctx.agent["agent_id"],
               ctx.agent["tenant_id"],
               ctx.agent["router_session_id"]
             )

    new_ctx = %{
      ctx
      | agent: Map.put(ctx.agent, "router_session_id", updated["router_session_id"])
    }

    new_session = await_source(new_ctx, first["seq"])

    assert source_progress(new_session)["generation"] ==
             updated["router_session_id"]

    assert MapSet.size(InternalSession.export(new_session).input_dedupe) == 0

    {:ok, second} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "after reset"}]}
      )

    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    new_session = await_source(new_ctx, second["seq"])

    {:ok, old_source} =
      SalixIM.ConversationSourceIdentity.encode(
        ctx.conversation["conversation_id"],
        first["message_id"],
        ctx.conversation["router_participant_id"],
        nil
      )

    {:ok, new_source} =
      SalixIM.ConversationSourceIdentity.encode(
        ctx.conversation["conversation_id"],
        second["message_id"],
        ctx.conversation["router_participant_id"],
        nil
      )

    refute InternalSession.input_dedupe_member?(new_session, old_source)
    assert InternalSession.input_dedupe_member?(new_session, new_source)
  end

  test "a stalled display projection does not block committed input admission", ctx do
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    S3.Fake.set_fault(
      {:pause, :put, {:prefix, Keys.ctl_group_conversation_list_prefix(ctx.group)}}
    )

    append =
      Task.async(fn ->
        SalixIM.ConversationServer.append_group_conversation_message(
          ctx.group,
          ctx.conversation["conversation_id"],
          %{
            "content" => [%{"type" => "text", "text" => "projection can wait"}],
            "delivery_filter" => %{
              "participant_ids" => [ctx.conversation["router_participant_id"]]
            }
          }
        )
      end)

    try do
      assert {:ok, message} = Task.await(append, 5_000)
      await_source(ctx, message["seq"])
      assert S3.Fake.paused?()
    after
      S3.Fake.release_pause()
    end
  end

  test "non-target records advance the frontier without becoming inputs", ctx do
    {:ok, message} =
      SalixIM.ConversationServer.append_group_conversation_message(
        ctx.group,
        ctx.conversation["conversation_id"],
        %{
          "content" => [%{"type" => "text", "text" => "record only"}],
          "delivery_filter" => %{"participant_ids" => []}
        }
      )

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    session = await_source(ctx, message["seq"])
    assert InternalSession.export(session).input_queue == []
    assert MapSet.size(InternalSession.export(session).input_dedupe) == 0
  end

  test "scan and rejection progress commit without requesting a runtime wake", ctx do
    for disposition <- [:scan, :reject] do
      assert {:ok, appended} =
               SalixIM.ConversationServer.append_group_conversation_message(
                 ctx.group,
                 ctx.conversation["conversation_id"],
                 %{
                   "content" => "Record only",
                   "delivery_filter" => %{"participant_ids" => []}
                 }
               )

      assert {:ok, message} =
               SalixIM.Conversations.get_group_conversation_message(
                 ctx.group,
                 ctx.conversation["conversation_id"],
                 appended["message_id"]
               )

      assert {:ok, binding} = ConversationSource.binding(ctx.agent["agent_id"], source_ref(ctx))

      assert {:ok, entry} =
               if(disposition == :scan,
                 do: ConversationSource.entry(binding, message),
                 else: ConversationSource.reject(binding, message, :test_rejection)
               )

      assert {:ok, :committed, []} =
               SalixAgent.AgentActor.SessionDelivery.stage(ctx.agent["agent_id"], entry)

      session = await_source(ctx, appended["seq"])
      assert InternalSession.export(session).input_queue == []
      :ok = S3.Fake.reset_read_log()

      assert {:ok, progress} =
               SalixAgent.InternalSessionActor.source_progress(
                 ctx.agent["agent_id"],
                 ctx.agent["router_session_id"],
                 ctx.conversation["router_participant_id"]
               )

      assert progress == source_progress(session)

      refute {:get,
              Keys.agent_internal_runtime_session(
                ctx.agent["agent_id"],
                ctx.agent["router_session_id"]
              )} in S3.Fake.read_log()
    end
  end

  test "recovery selects pending Conversations without visiting idle directories", ctx do
    for i <- 1..50 do
      assert {:ok, _} =
               SalixIM.ConversationInput.create_group_conversation(ctx.group, %{
                 "title" => "Idle #{i}",
                 "participants" => []
               })
    end

    for text <- ["first", "second"] do
      assert {:ok, _} =
               RouterConversationInput.append_user_message(ctx.group, %{
                 "content" => [%{"type" => "text", "text" => text}]
               })
    end

    S3.Fake.blackhole({:fail, 503, :list, Keys.ctl_group_conversations_prefix()})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, [candidate]} = SalixStore.ConversationLogRecovery.claim(8)
    assert candidate.conversation_id == ctx.conversation["conversation_id"]
    assert candidate.target_seq == 2

    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert {:ok, :pending} = ConversationSource.recover(candidate)
    await_source(ctx, 2)
    assert :ok = ConversationSource.recover(candidate)

    assert {:ok, []} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 60_000
             )
  end

  test "recovery retires an archived Worker source without replaying it", ctx do
    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        ctx.agent["tenant_id"],
        ctx.group,
        %{"role" => "worker", "name" => "Archived Worker"}
      )

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(ctx.group, %{
               "kind" => "user_chat",
               "title" => "Archived Worker input",
               "participants" => [
                 %{"actor_type" => "user", "user_id" => "current"},
                 %{"actor_type" => "agent", "agent_id" => worker["agent_id"]}
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               ctx.group,
               conversation["conversation_id"]
             )

    participant = Enum.find(participants, &(&1["agent_id"] == worker["agent_id"]))
    assert participant["state"] in [nil, "active"]

    assert {:ok, _message} =
             SalixIM.ConversationServer.append_group_conversation_message(
               ctx.group,
               conversation["conversation_id"],
               %{
                 "content" => "Pending Worker input",
                 "delivery_filter" => %{"participant_ids" => [participant["participant_id"]]}
               }
             )

    assert {:ok, [candidate]} = SalixStore.ConversationLogRecovery.claim(8)
    assert {:ok, archived} = SalixAgent.Control.delete(worker["agent_id"])
    assert is_integer(archived["archived_at"])

    assert :ok = ConversationSource.recover(candidate)

    assert {:ok, []} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 60_000
             )
  end

  test "the periodic indexed worker restores a dropped notification", ctx do
    assert {:ok, message} =
             RouterConversationInput.append_user_message(ctx.group, %{
               "content" => [%{"type" => "text", "text" => "recover without another input"}]
             })

    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    start_supervised!(SalixIM.ConversationLogRecovery)
    session = await_source(ctx, message["seq"])

    assert InternalSession.input_dedupe_member?(session, source_id(ctx, message))
  end

  test "changed source filters retain recovery after a stale completion", ctx do
    filter = fn messages ->
      SalixIM.ConversationServer.reconcile_group_conversation_agent_participants(
        ctx.group,
        ctx.conversation["conversation_id"],
        %{
          "desired" => %{
            "agent_id" => ctx.agent["agent_id"],
            "notification_filter" => %{"messages" => messages, "statuses" => "none"}
          },
          "selector" => %{"actor_type" => "agent"}
        }
      )
    end

    assert {:ok, _} = filter.("none")

    assert {:ok, message} =
             RouterConversationInput.append_user_message(ctx.group, %{
               "content" => [%{"type" => "text", "text" => "input before subscription"}]
             })

    # Router input reconciles its target. Mute explicitly before observing the
    # old recovery snapshot, then expose the suffix without another append.
    assert {:ok, _} = filter.("none")
    assert {:ok, [candidate]} = SalixStore.ConversationLogRecovery.claim(8)

    assert {:ok, _, observed} =
             SalixIM.ConversationServer.delivery_sources(
               ctx.group,
               ctx.conversation["conversation_id"]
             )

    assert {:ok, _} = filter.("all")

    assert {:ok, :pending} =
             SalixIM.ConversationServer.complete_log_recovery(
               ctx.group,
               ctx.conversation["conversation_id"],
               {candidate.target_seq, candidate.status_version},
               observed
             )

    assert {:ok, [^candidate]} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 60_000
             )

    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert {:ok, :pending} = ConversationSource.recover(candidate)
    await_source(ctx, message["seq"])
    assert :ok = ConversationSource.recover(candidate)

    # Finish recovery while muted, then expose another input without a new
    # append or a successful notification. Activation must re-register it.
    Application.put_env(:salix_im, :agent_delivery_mod, LostNotification)
    assert {:ok, _} = filter.("none")

    assert {:ok, later} =
             SalixIM.ConversationServer.append_group_conversation_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               %{
                 "content" => [%{"type" => "text", "text" => "newly exposed input"}],
                 "participant_id" => ctx.conversation["user_participant_id"],
                 "actor_type" => "user"
               }
             )

    assert {:ok, [muted]} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 120_000
             )

    assert :ok = ConversationSource.recover(muted)
    assert {:ok, _} = filter.("all")

    assert {:ok, [reopened]} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 120_000
             )

    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    assert {:ok, :pending} = ConversationSource.recover(reopened)
    session = await_source(ctx, later["seq"])

    assert InternalSession.input_dedupe_member?(session, source_id(ctx, later))
  end

  test "recovery fences a late unacknowledged status mutation before retiring its index", ctx do
    key = Keys.ctl_group_conversation_meta(ctx.group, ctx.conversation["conversation_id"])
    assert {:ok, before} = SalixStore.CasRecord.get(key)
    S3.Fake.set_fault({:pause, :put, key})
    on_exit(fn -> if S3.Fake.paused?(), do: S3.Fake.release_pause() end)

    writer =
      Task.async(fn ->
        try do
          SalixIM.ConversationServer.update_group_conversation(
            ctx.group,
            ctx.conversation["conversation_id"],
            %{"title" => "Unacknowledged title"}
          )
        catch
          :exit, reason -> {:error, reason}
        end
      end)

    assert Enum.reduce_while(1..500, false, fn _, _ ->
             if S3.Fake.paused?(),
               do: {:halt, true},
               else:
                 (
                   Process.sleep(10)
                   {:cont, false}
                 )
           end)

    assert {:ok, [candidate]} = SalixStore.ConversationLogRecovery.claim(8)
    assert candidate.status_version > (before["provider_status_version"] || 0)
    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:error, _} = Task.await(writer, 10_000)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    assert :ok = ConversationSource.recover(candidate)

    assert {:ok, []} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 60_000
             )

    S3.Fake.release_pause()
    assert {:ok, after_recovery} = SalixStore.CasRecord.get(key)
    assert after_recovery["title"] == before["title"]
    assert after_recovery["updated_at"] == before["updated_at"]
    assert after_recovery["provider_status_version"] == candidate.status_version
  end

  test "recovery publishes a prepared append after its tail write fails", ctx do
    key = Keys.ctl_group_conversation_meta(ctx.group, ctx.conversation["conversation_id"])
    S3.Fake.blackhole({:fail, 503, :put, key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:error, _} =
             RouterConversationInput.append_user_message(ctx.group, %{
               "content" => [%{"type" => "text", "text" => "prepared before owner loss"}]
             })

    assert {:ok, [candidate]} = SalixStore.ConversationLogRecovery.claim(8)
    assert candidate.target_seq == 1
    assert {:ok, %{"message_tail_seq" => 0}} = SalixStore.CasRecord.get(key)

    SalixIM.TestSupport.Fleet.stop_all!()
    S3.Fake.clear_blackhole()
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert {:ok, :pending} = ConversationSource.recover(candidate)
    session = await_source(ctx, 1)

    assert {:ok, [message]} =
             SalixIM.Conversations.list_group_conversation_messages(
               ctx.group,
               ctx.conversation["conversation_id"],
               limit: 32
             )

    assert message["seq"] == 1

    assert SalixIM.ConversationMessage.text_content(message["content"]) ==
             "prepared before owner loss"

    assert InternalSession.input_dedupe_member?(session, source_id(ctx, message))

    assert :ok = ConversationSource.recover(candidate)
  end

  test "an old recovery completion cannot remove a concurrent append", ctx do
    append = fn text ->
      RouterConversationInput.append_user_message(ctx.group, %{
        "content" => [%{"type" => "text", "text" => text}]
      })
    end

    assert {:ok, _} = append.("first")
    assert {:ok, [old]} = SalixStore.ConversationLogRecovery.claim(8)
    assert {:ok, _} = append.("second")
    assert :ok = SalixStore.ConversationLogRecovery.complete(old)

    assert {:ok, [new]} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 60_000
             )

    assert new.target_seq == 2

    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert {:ok, :pending} = ConversationSource.recover(new)
    await_source(ctx, 2)
    assert :ok = ConversationSource.recover(new)
  end

  test "existing conversations start automatically after the old tail and retain admitted work",
       ctx do
    {:ok, accepted} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "already accepted"}]}
      )

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    await_source(ctx, accepted["seq"])
    Application.put_env(:salix_agent, :conversation_source_mod, nil)
    SalixAgent.TestSupport.stop_all_agents()

    {:ok, old} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "unprocessed legacy input"}]}
      )

    key = Keys.ctl_group_conversation_meta(ctx.group, ctx.conversation["conversation_id"])

    {:ok, _} =
      SalixStore.CasRecord.update(
        key,
        &Map.drop(&1, ["log_start_seq"])
      )

    SalixIM.TestSupport.Fleet.stop_all!()

    assert {:ok, binding, []} =
             source_batch(ctx)

    assert binding.start_seq == old["seq"]

    {:ok, fresh} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "after upgrade"}]}
      )

    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    session = await_source(ctx, fresh["seq"])
    assert InternalSession.input_dedupe_member?(session, source_id(ctx, accepted))
    assert InternalSession.input_dedupe_member?(session, source_id(ctx, fresh))
    refute InternalSession.input_dedupe_member?(session, source_id(ctx, old))
  end

  test "the first new append initializes before commit and restart does not move the floor",
       ctx do
    {:ok, old} =
      RouterConversationInput.append_user_message(
        ctx.group,
        %{"content" => [%{"type" => "text", "text" => "before upgrade"}]}
      )

    key = Keys.ctl_group_conversation_meta(ctx.group, ctx.conversation["conversation_id"])

    {:ok, _} =
      SalixStore.CasRecord.update(
        key,
        &Map.drop(&1, ["log_start_seq"])
      )

    SalixIM.TestSupport.Fleet.stop_all!()

    {:ok, fresh} =
      SalixIM.ConversationServer.append_group_conversation_message(
        ctx.group,
        ctx.conversation["conversation_id"],
        %{
          "content" => [%{"type" => "text", "text" => "first new append"}],
          "delivery_filter" => %{"participant_ids" => [ctx.conversation["router_participant_id"]]}
        }
      )

    SalixIM.TestSupport.Fleet.stop_all!()

    assert {:ok, binding, [message]} =
             source_batch(ctx)

    assert binding.start_seq == old["seq"]
    assert message["message_id"] == fresh["message_id"]
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    session = await_source(ctx, fresh["seq"])
    assert InternalSession.input_dedupe_member?(session, source_id(ctx, fresh))
  end

  for runtime <- ["internal", "external"] do
    @tag worker_runtime: runtime
    test "Worker #{runtime} admits its targeted suffix and survives lost hints", ctx do
      worker =
        SalixAgent.TestSupport.create_control_agent_in_group!(
          ctx.agent["tenant_id"],
          ctx.group,
          %{
            "role" => "worker",
            "name" => "Worker",
            "runtime_config" =>
              if(ctx.worker_runtime == "external",
                do: external_runtime(),
                else: %{"kind" => "internal"}
              )
          }
        )

      assert {:ok, conversation} =
               SalixIM.ConversationInput.create_group_conversation(ctx.group, %{
                 "kind" => "user_chat",
                 "title" => "Worker input",
                 "participants" => [
                   %{"actor_type" => "user", "user_id" => "current"},
                   %{"actor_type" => "agent", "agent_id" => worker["agent_id"]}
                 ]
               })

      assert {:ok, %{"participants" => participants}} =
               SalixIM.Conversations.list_group_conversation_participants(
                 ctx.group,
                 conversation["conversation_id"]
               )

      participant = Enum.find(participants, &(&1["actor_type"] == "agent"))
      session_id = participant["payload"]["session_id"]

      ref = %{
        group_id: ctx.group,
        conversation_id: conversation["conversation_id"],
        participant_id: participant["participant_id"]
      }

      assert {:ok, message} =
               SalixIM.ConversationServer.append_group_conversation_message(
                 ctx.group,
                 conversation["conversation_id"],
                 %{
                   "content" => "Worker command",
                   "delivery_filter" => %{"participant_ids" => [participant["participant_id"]]}
                 }
               )

      Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
      assert :ok = AgentActor.notify_conversation(worker["agent_id"], ref)

      if ctx.worker_runtime == "external" do
        state = await_external(worker["agent_id"], session_id)
        assert Enum.any?(state["input_message_queue"], &(&1["content"] == "Worker command"))
      else
        worker_ctx = %{
          ctx
          | agent: Map.put(worker, "router_session_id", session_id),
            conversation:
              Map.put(conversation, "router_participant_id", participant["participant_id"])
        }

        session = await_source(worker_ctx, message["seq"])
        assert InternalSession.input_dedupe_member?(session, source_id(worker_ctx, message))
      end
    end
  end

  test "provider context and explicit redelivery preserve provenance without waking", ctx do
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "source_message_id" => "provider-first",
      "ifc" => %{"integrity" => "data", "label" => ["scope|test|channel"]}
    }

    assert {:ok, first} =
             RouterConversationInput.append_provider_input(ctx.group, "provider-first", %{
               content: "Provider context",
               role: "user",
               no_wake: true,
               trusted_origin: origin
             })

    session = await_source(ctx, first["seq"])
    assert InternalSession.input_dedupe_member?(session, "provider-first")

    assert Enum.any?(InternalSession.export(session).input_queue, fn entry ->
             entry["payload"]["trusted_origin"] == origin or entry["trusted_origin"] == origin
           end)

    request = %{
      "participant_id" => ctx.conversation["router_participant_id"],
      "message_id" => first["message_id"],
      "request_id" => "provider-replay"
    }

    assert {:ok, %{"delivery_status" => "queued"}} =
             SalixIM.ConversationServer.redeliver_group_conversation_agent_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               request
             )

    session = await_source(ctx, first["seq"] + 1)
    replay_id = "provider-first:redelivery:" <> SalixStore.Crypto.hex("provider-replay")
    assert InternalSession.input_dedupe_member?(session, replay_id)

    assert Enum.count(InternalSession.export(session).input_queue, fn entry ->
             entry["payload"]["trusted_origin"] == origin or entry["trusted_origin"] == origin
           end) == 2

    assert {:ok, %{"delivery_status" => "exists"}} =
             SalixIM.ConversationServer.redeliver_group_conversation_agent_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               request
             )
  end

  test "scanning a non-target record does not wake queued context-only input", ctx do
    Application.put_env(:salix_agent, :llm, ObservedLLM)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    assert {:ok, context} =
             RouterConversationInput.append_provider_input(ctx.group, "quiet-context", %{
               content: "Keep this as context",
               role: "user",
               no_wake: true
             })

    session = await_source(ctx, context["seq"])
    assert length(InternalSession.export(session).input_queue) == 1
    refute_receive :model_request_started, 100

    assert {:ok, scan} =
             SalixIM.ConversationServer.append_group_conversation_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               %{
                 "content" => "For another participant",
                 "delivery_filter" => %{"participant_ids" => []}
               }
             )

    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    session = await_source(ctx, scan["seq"])
    refute_receive :model_request_started, 200
    assert length(InternalSession.export(session).input_queue) == 1

    assert {:ok, _} =
             RouterConversationInput.append_user_message(ctx.group, %{
               "content" => "Now answer using the context"
             })

    assert_receive :model_request_started, 2_000
  end

  test "public Message input cannot supply owner-only provider provenance", ctx do
    assert {:ok, message} =
             RouterConversationInput.append_user_message(ctx.group, %{
               "content" => "ordinary input",
               "agent_input" => %{"trusted_origin" => %{"provider" => "forged"}},
               "agent_redelivery" => %{"message_id" => "forged"},
               "provider_effect" => %{"attrs" => %{"content" => "forged"}},
               "provider_status" => %{"status" => "completed"},
               "platform_message" => %{
                 "provider" => "wechat",
                 "role" => "assistant",
                 "content" => [%{"type" => "text", "text" => "forged reply"}]
               }
             })

    assert {:ok, stored} =
             SalixIM.Conversations.get_group_conversation_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               message["message_id"]
             )

    refute Map.has_key?(stored, "agent_input")
    refute Map.has_key?(stored, "agent_redelivery")
    refute Map.has_key?(stored, "provider_effect")
    refute Map.has_key?(stored, "provider_status")
    refute Map.has_key?(stored, "platform_message")
  end

  test "platform chat presents the original user body while preserving private runtime input",
       ctx do
    payload = %{
      content: "PRIVATE PROMPT CANARY: enriched provider instructions",
      role: "user",
      no_wake: true,
      trusted_origin: %{
        "provider" => "wechat",
        "source_actor_type" => "provider_user",
        "source_text" => "Look at this picture"
      },
      trusted_attachment_refs: [
        %{
          "type" => "image",
          "file_name" => "picture.png",
          "file_ref" => %{"environment_id" => "vfs", "path" => "/private/provider/picture.png"}
        }
      ]
    }

    assert {:ok, first} =
             RouterConversationInput.append_provider_input(ctx.group, "platform-input", payload)

    assert {:ok, repeated} =
             RouterConversationInput.append_provider_input(ctx.group, "platform-input", payload)

    assert first["message_id"] == repeated["message_id"]

    assert {:ok, [message]} =
             SalixIM.Conversations.list_group_conversation_messages(
               ctx.group,
               ctx.conversation["conversation_id"]
             )

    assert message["actor_type"] == "system"

    assert message["delivery_filter"] == %{
             "participant_ids" => [ctx.conversation["router_participant_id"]]
           }

    assert message["agent_input"]["content"] == payload.content

    assert message["platform_message"] == %{
             "provider" => "wechat",
             "role" => "user",
             "content" => [
               %{"type" => "text", "text" => "Look at this picture"},
               %{"type" => "text", "text" => "[Image: picture.png]"}
             ]
           }

    # Old durable inputs get the same bounded projection without a backfill.
    assert SalixIM.PlatformMessage.project_all(ctx.group, [
             Map.delete(message, "platform_message")
           ]) == [message]
  end

  test "Home omits Worker sends, unidentified receipts, and labelled Groups", ctx do
    connect = %{"provider" => "telegram", "connect_id" => "telegram-one"}
    sent = {:ok, %{"message_id" => 42}}
    router = %{group_id: ctx.group, agent_id: ctx.agent["agent_id"], tool_call_id: "router"}

    send_text = fn scope, text, result ->
      SalixIM.PlatformMessage.record_success(
        result,
        scope,
        connect,
        "telegram.send_message",
        %{"text" => text, "chat_id" => "123"}
      )
    end

    assert ^sent =
             send_text.(%{router | agent_id: "agt_worker", tool_call_id: "w"}, "Worker", sent)

    assert {:ok, %{}} =
             send_text.(Map.delete(router, :tool_call_id), "No receipt", {:ok, %{}})

    assert ^sent = send_text.(router, "Router", sent)
    {_input, _context} = append_wechat_input(ctx, "wechat-one", "inbound")

    [reply] = await_platform_messages(ctx)
    assert reply["platform_message"]["content"] == [%{"type" => "text", "text" => "Router"}]
    Process.sleep(100)
    assert [^reply] = await_platform_messages(ctx)

    {:ok, _} =
      SalixStore.CasRecord.update(
        Keys.ctl_group(ctx.group),
        &Map.put(&1, "ifc", %{"mode" => "audit"})
      )

    assert ^sent = send_text.(%{router | tool_call_id: "labelled"}, "Labelled", sent)
    Process.sleep(100)

    assert {:ok, messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               ctx.group,
               ctx.conversation["conversation_id"]
             )

    assert length(messages) == 2
    refute Enum.any?(messages, &Map.has_key?(&1, "platform_message"))
    assert Enum.all?(messages, &SalixIM.ConversationMessage.internal_delivery?/1)

    assert {:ok, message} =
             SalixIM.Conversations.get_group_conversation_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               reply["message_id"]
             )

    refute Map.has_key?(message, "platform_message")
  end

  test "successful platform replies are visible facts without another agent input", ctx do
    Application.put_env(:salix_agent, :llm, ObservedLLM)
    Application.put_env(:salix_agent, :conversation_source_mod, ConversationSource)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    scope = %{group_id: ctx.group, agent_id: ctx.agent["agent_id"], tool_call_id: "reply-one"}
    connect = %{"provider" => "telegram", "connect_id" => "telegram-one"}
    params = %{"text" => "Sent to Telegram", "chat_id" => "123"}
    sent = {:ok, %{"message_id" => 42}}

    {:ok, owner} =
      SalixIM.ConversationFleet.ensure_started(ctx.group, ctx.conversation["conversation_id"])

    :ok = :sys.suspend(owner)

    try do
      caller = self()

      Task.start(fn ->
        for _ <- 1..2 do
          result =
            SalixIM.PlatformMessage.record_success(
              sent,
              scope,
              connect,
              "telegram.send_message",
              params
            )

          send(caller, {:platform_send_returned, result})
        end
      end)

      # A blocked history owner cannot consume the successful send's tool budget.
      assert_receive {:platform_send_returned, ^sent}, 1_000
      assert_receive {:platform_send_returned, ^sent}, 1_000
    after
      :ok = :sys.resume(owner)
    end

    assert {:error, :timeout} =
             SalixIM.PlatformMessage.record_success(
               {:error, :timeout},
               %{scope | tool_call_id: "reply-failed"},
               connect,
               "telegram.send_message",
               params
             )

    [message] = await_platform_messages(ctx)

    assert message["platform_message"] == %{
             "provider" => "telegram",
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "Sent to Telegram"}]
           }

    assert message["delivery_filter"] == %{"participant_ids" => []}
    refute Map.has_key?(message, "agent_input")
    assert :ok = AgentActor.notify_conversation(ctx.agent["agent_id"], source_ref(ctx))
    session = await_source(ctx, message["seq"])
    assert InternalSession.export(session).input_queue == []
    refute_receive :model_request_started, 100
  end

  test "WeChat replies retain the triggering input after a newer input arrives", ctx do
    {first, context} = append_wechat_input(ctx, "wechat-one", "first")
    {later, _} = append_wechat_input(ctx, "wechat-one", "later")

    connect = %{
      "provider" => "wechat",
      "connect_id" => "wechat-one",
      "latest_context_message_id" => later["source_message_id"]
    }

    {:ok, owner} =
      SalixIM.ConversationFleet.ensure_started(ctx.group, ctx.conversation["conversation_id"])

    :ok = :sys.suspend(owner)

    try do
      # The caller's source disappears before the asynchronous history task can
      # commit. Model parameters and a newer connect cursor cannot replace it.
      record_wechat_reply(ctx, connect, context, "reply-first", %{
        "text" => "Answer to the first message",
        "reply_to_message_id" => later["message_id"]
      })
    after
      :ok = :sys.resume(owner)
    end

    [reply] = await_platform_messages(ctx)
    assert reply["reply_to_message_id"] == first["message_id"]
    assert reply["thread_root_message_id"] == first["thread_root_message_id"]
    refute reply["thread_root_message_id"] == reply["message_id"]

    assert reply["platform_message"]["content"] ==
             [%{"type" => "text", "text" => "Answer to the first message"}]

    assert reply["delivery_filter"] == %{"participant_ids" => []}
    refute Map.has_key?(reply, "agent_input")

    assert {:ok, repeated} =
             SalixIM.ConversationServer.append_platform_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               reply["platform_message"],
               reply["idempotency_key"],
               Map.take(context, ~w(source_message_id session_id))
               |> Map.put("connect_id", "wechat-one")
             )

    assert repeated["message_id"] == reply["message_id"]
    refute repeated["inserted"]
    assert [^reply] = await_platform_messages(ctx)
  end

  test "WeChat history does not guess a parent without matching committed provenance", ctx do
    {input, context} = append_wechat_input(ctx, "wechat-one", "first")
    connect = %{"provider" => "wechat", "connect_id" => "wechat-one"}
    params = %{"text" => "Visible reply", "reply_to_message_id" => input["message_id"]}

    record_wechat_reply(ctx, connect, %{}, "without-context", params)

    record_wechat_reply(
      ctx,
      %{connect | "connect_id" => "wechat-other"},
      context,
      "other-connect",
      params
    )

    missing_source = "im_provider:wechat:wechat-one:missing"

    missing_context = %{
      context
      | "source_message_id" => missing_source,
        "source_message_ids" => [missing_source],
        "trusted_origin" =>
          Map.put(context["trusted_origin"], "source_message_id", missing_source)
    }

    record_wechat_reply(ctx, connect, missing_context, "missing-input", params)

    replies = await_platform_messages(ctx, 3)
    assert Enum.all?(replies, &is_nil(&1["reply_to_message_id"]))
    assert Enum.all?(replies, &(&1["thread_root_message_id"] == &1["message_id"]))

    # The owner independently checks stored provenance, even if an internal
    # caller supplies a source hint for a different connect.
    assert {:ok, forged} =
             SalixIM.ConversationServer.append_platform_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               hd(replies)["platform_message"],
               "foreign-connect-hint",
               Map.take(context, ~w(source_message_id session_id))
               |> Map.put("connect_id", "wechat-other")
             )

    assert {:ok, message} =
             SalixIM.Conversations.get_group_conversation_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               forged["message_id"]
             )

    refute Map.has_key?(message, "reply_to_message_id")
  end

  test "retrying an older platform receipt preserves its original relation", ctx do
    {_input, context} = append_wechat_input(ctx, "wechat-one", "first")

    presentation = %{
      "provider" => "wechat",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => "Already sent"}]
    }

    assert {:ok, first} =
             SalixIM.ConversationServer.append_platform_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               presentation,
               "existing-receipt"
             )

    assert {:ok, repeated} =
             SalixIM.ConversationServer.append_platform_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               presentation,
               "existing-receipt",
               Map.take(context, ~w(source_message_id session_id))
               |> Map.put("connect_id", "wechat-one")
             )

    assert first["message_id"] == repeated["message_id"]
    refute repeated["inserted"]
    [message] = await_platform_messages(ctx)
    refute Map.has_key?(message, "reply_to_message_id")
  end

  defp append_wechat_input(ctx, connect_id, event_id) do
    source = "im_provider:wechat:" <> connect_id <> ":" <> event_id

    origin = %{
      "provider" => "wechat",
      "source_actor_type" => "provider_user",
      "source_message_id" => source,
      "agent_group_id" => ctx.group,
      "source_text" => event_id,
      "provider_context" => %{"connect_id" => connect_id}
    }

    assert {:ok, appended} =
             RouterConversationInput.append_provider_input(ctx.group, source, %{
               content: "Private runtime input: " <> event_id,
               role: "user",
               no_wake: true,
               session_id: ctx.agent["router_session_id"],
               trusted_origin: origin
             })

    assert {:ok, message} =
             SalixIM.Conversations.get_group_conversation_message(
               ctx.group,
               ctx.conversation["conversation_id"],
               appended["message_id"]
             )

    context = %{
      "source_message_id" => source,
      "source_message_ids" => [source],
      "session_id" => ctx.agent["router_session_id"],
      "trusted_origin" => origin
    }

    {message, context}
  end

  defp record_wechat_reply(ctx, connect, context, tool_call_id, params) do
    previous = Process.get(:salix_im_provider_tool_context)
    Process.put(:salix_im_provider_tool_context, context)
    sent = {:ok, %{"client_id" => tool_call_id}}

    try do
      assert ^sent =
               SalixIM.PlatformMessage.record_success(
                 sent,
                 %{
                   group_id: ctx.group,
                   agent_id: ctx.agent["agent_id"],
                   tool_call_id: tool_call_id
                 },
                 connect,
                 "wechat.reply_text",
                 params
               )
    after
      if previous,
        do: Process.put(:salix_im_provider_tool_context, previous),
        else: Process.delete(:salix_im_provider_tool_context)
    end
  end

  defp await_platform_messages(ctx, count \\ 1, attempts \\ 200)
  defp await_platform_messages(_, _, 0), do: flunk("Platform history did not commit")

  defp await_platform_messages(ctx, count, attempts) do
    case SalixIM.Conversations.list_group_conversation_messages(
           ctx.group,
           ctx.conversation["conversation_id"]
         ) do
      {:ok, messages} ->
        replies =
          Enum.filter(messages, &(get_in(&1, ["platform_message", "role"]) == "assistant"))

        if length(replies) == count do
          replies
        else
          Process.sleep(25)
          await_platform_messages(ctx, count, attempts - 1)
        end

      _ ->
        Process.sleep(25)
        await_platform_messages(ctx, count, attempts - 1)
    end
  end

  defp await_external(agent, session, attempts \\ 200)
  defp await_external(_, _, 0), do: flunk("External Session did not admit input")

  defp await_external(agent, session, attempts) do
    case SalixAgent.ExternalSessionStore.get_session_record(agent, session) do
      {:ok, %{"conversation_sources" => sources} = state} when map_size(sources) > 0 ->
        state

      _ ->
        Process.sleep(25)
        await_external(agent, session, attempts - 1)
    end
  end

  defp source_ref(ctx),
    do: %{
      group_id: ctx.group,
      conversation_id: ctx.conversation["conversation_id"],
      participant_id: ctx.conversation["router_participant_id"]
    }

  defp source_progress(session),
    do: session |> InternalSession.conversation_sources() |> Map.values() |> List.first()

  defp source_batch(ctx) do
    with {:ok, binding} <- ConversationSource.binding(ctx.agent["agent_id"], source_ref(ctx)),
         do: ConversationSource.batch(binding, nil)
  end

  defp await_source(ctx, seq, attempts \\ 200)
  defp await_source(_, _, 0), do: flunk("Router did not admit the committed suffix")

  defp await_source(ctx, seq, attempts) do
    case InternalSessionStore.read(ctx.agent["agent_id"], ctx.agent["router_session_id"]) do
      {:ok, session} ->
        if get_in(source_progress(session) || %{}, ["seq"]) == seq do
          session
        else
          Process.sleep(25)
          await_source(ctx, seq, attempts - 1)
        end

      _ ->
        Process.sleep(25)
        await_source(ctx, seq, attempts - 1)
    end
  end
end
