defmodule SalixIM.TaskExecutionTest do
  use ExUnit.Case, async: false

  alias SalixIM.{Conversations, ConversationServer, Provider, RouterConversationInput}
  alias SalixStore.{CasRecord, Ids, Keys}

  defmodule Owner do
    def authorize_owner(group, user) do
      if Application.get_env(:salix_im, :task_execution_test_owner) == {group, user},
        do: :ok,
        else: {:error, :not_owner}
    end

    def conversation_members(group, conversation, "comma_user|" <> user = principal) do
      with {:ok, rec} <- SalixIM.GroupDirectory.get_group(group),
           {:ok, ^conversation} <- SalixIM.ConversationIds.group_router(rec),
           :ok <- authorize_owner(group, user),
           do: [principal],
           else: (_ -> nil)
    end

    def conversation_members(_, _, _), do: nil

    def direct_members(group, connect, [peer], "comma_user|" <> user = principal) do
      if authorize_owner(group, user) == :ok and
           Application.get_env(:salix_im, :task_execution_test_link) == {connect, peer},
         do: [principal]
    end

    def direct_members(_, _, _, _), do: nil
  end

  defmodule Delivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    # Every delivery is reported to the test. Only the agent a test explicitly
    # names is also handed to the real runtime, so a test that wants a Session
    # activated gets one without every other test paying for a round.
    def deliver(agent_id, payload, opts) do
      send(
        Application.fetch_env!(:salix_im, :task_execution_test_pid),
        {:delivered, agent_id, payload}
      )

      if agent_id == Application.get_env(:salix_im, :task_execution_test_runtime_agent),
        do: SalixAgent.deliver(agent_id, payload, opts),
        else: {:ok, %{}}
    end
  end

  # Captures the tools the round actually offered the model.
  defmodule CaptureLLM do
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(_messages, tools, _on_delta, _opts) do
      send(Application.fetch_env!(:salix_im, :task_execution_test_pid), {:offered_tools, tools})

      {:assistant, "done",
       [%{id: "task-execution-end-turn", name: "end_turn", args: %{"outcome" => "done"}}]}
    end
  end

  defmodule ProviderAppStore do
    def get_feishu_tenant_app(_tenant),
      do: {:ok, %{"app_id" => "cli1", "app_secret" => "test-secret"}}
  end

  # The schedule application adds only the ordinary command envelope here.
  # Task identity, participants, source protection and delivery use real owners.
  defmodule TaskCreate do
    def create_task_conversation(group, router, worker, attrs) do
      with {:ok, id} <-
             SalixIM.ConversationServer.reserve_task_conversation_id(group, router, worker, attrs) do
        # Model a durable grant written before the operation split, at the same
        # persistence boundary. The command still uses normal source protection.
        attrs =
          if Application.get_env(:salix_im, :task_execution_test_legacy_grant, false) do
            update_in(attrs, ["source_refs", "task_execution", "requests"], fn requests ->
              Enum.map(requests, &Map.put(&1, "api", "slack.post_message"))
            end)
          else
            attrs
          end

        SalixIM.TaskConversationInput.create_with_id(
          group,
          id,
          router,
          worker,
          attrs
          |> Map.put("schedule", %{"schedule_id" => nil, "command" => attrs["content"]})
          |> Map.put("initial_message_attrs", %{
            "kind" => "message",
            "actor_type" => "agent",
            "agent_id" => router,
            "content" => attrs["content"],
            "client_request_id" => "delegate-task-" <> id,
            "metadata" => %{"message_type" => "task_command"}
          })
        )
      end
    end
  end

  defmodule TelegramAPI do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {:ok, raw, conn} = read_body(conn)

      body =
        if String.starts_with?(conn.request_path, "/api/"),
          do: URI.decode_query(raw),
          else: Jason.decode!(raw)

      response =
        cond do
          conn.request_path == "/api/conversations.info" ->
            %{
              "ok" => true,
              "channel" => %{"id" => "C1", "is_private" => false, "is_member" => true}
            }

          conn.request_path == "/api/conversations.members" ->
            %{"ok" => true, "members" => ["U1"]}

          conn.request_path == "/api/chat.postMessage" ->
            send(Application.fetch_env!(:salix_im, :task_execution_test_pid), {:slack, body})
            %{"ok" => true, "channel" => body["channel"], "ts" => "123.456"}

          conn.request_path == "/open-apis/im/v1/messages" ->
            send(
              Application.fetch_env!(:salix_im, :task_execution_test_pid),
              {:feishu, body, conn.query_string}
            )

            %{"code" => 0, "data" => %{"message_id" => "om1"}}

          true ->
            send(Application.fetch_env!(:salix_im, :task_execution_test_pid), {:telegram, body})
            %{"ok" => true, "result" => %{"message_id" => 42}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    overrides = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_im, :conversation_placement, SalixIM.ConversationPlacement.LocalFleet},
      {:salix_im, :agent_delivery_mod, Delivery},
      {:salix_im, :task_create_mod, TaskCreate},
      {:salix_im, :task_execution_owner_mod, Owner},
      {:salix_im, :provider_app_store_mod, ProviderAppStore},
      {:salix_im, :meeting_preparation_authority_mod, nil},
      {:salix_im, :protected_source_ref_contracts,
       [
         SalixIM.TaskExecution,
         SalixIM.TaskContinuation,
         SalixIM.TaskReplySource,
         SalixIM.IFCSourceRefs
       ]},
      {:salix_im, :task_execution_test_pid, self()},
      {:salix_agent, :im_provider_mod, Provider},
      {:salix_agent, :ifc_facts_mod, SalixIM.IFC.Facts},
      {:salix_agent, :llm, CaptureLLM}
    ]

    previous =
      Enum.map(overrides, fn {app, key, _} -> {app, key, Application.get_env(app, key)} end)

    for {app, key, val} <- overrides, do: Application.put_env(app, key, val)
    old_api = Application.get_env(:salix_im, :telegram_api_base_url)
    old_slack_api = Application.get_env(:salix_im, :slack_api_base_url)
    old_feishu_api = Application.get_env(:salix_im, :feishu_api_base_url)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn p -> {Bandit, plug: TelegramAPI, port: p} end)

    Application.put_env(:salix_im, :telegram_api_base_url, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- [
            {:salix_im, :telegram_api_base_url, old_api},
            {:salix_im, :slack_api_base_url, old_slack_api},
            {:salix_im, :feishu_api_base_url, old_feishu_api} | previous
          ] do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end

      Application.delete_env(:salix_im, :task_execution_test_owner)
      Application.delete_env(:salix_im, :task_execution_test_link)
      Application.delete_env(:salix_im, :task_execution_test_runtime_agent)
      Application.delete_env(:salix_im, :task_execution_test_legacy_grant)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _} =
      CasRecord.update(Keys.ctl_group(group), &Map.put(&1, "router_agent_id", router["agent_id"]))

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Worker",
        "role" => "worker"
      })

    user = "usr_task_execution_owner"
    Application.put_env(:salix_im, :task_execution_test_owner, {group, user})
    connect = Ids.new_connect_id()

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(group, connect), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "connect_id" => connect,
        "provider" => "telegram",
        "status" => "connected",
        "bot_token" => "test-token",
        "bot_user_id" => "bot1",
        "managed_by" => "comma_product",
        "managed_peer_id" => "123"
      })

    %{
      tenant: tenant,
      group: group,
      router: router["agent_id"],
      worker: worker["agent_id"],
      user: user,
      connect: connect
    }
  end

  test "Comma owner request creates a Task whose Worker discovers and removes the exact Telegram keyboard",
       f do
    {task, context} = create_task(f)
    assert {:ok, connects} = Provider.list_connects(f.worker, context)
    assert Enum.any?(connects, &(&1["connect_id"] == f.connect))
    assert {:ok, %{"apis" => [api]}} = Provider.provider_manual("telegram", f.worker, context)
    assert api["name"] == "telegram.remove_reply_keyboard"

    assert {:ok, %{"message_id" => 42}} = remove_keyboard(f, context)

    assert_receive {:telegram,
                    %{"chat_id" => "123", "reply_markup" => %{"remove_keyboard" => true}}}

    assert {:error, _} = remove_keyboard(f, context, %{"chat_id" => "other"})
    assert {:error, _} = remove_keyboard(f, context, %{"message_thread_id" => 7})
    assert {:error, _} = remove_keyboard(f, %{})
    refute_receive {:telegram, _}, 20

    {:ok, record} = Conversations.get_group_conversation_record(f.group, task["conversation_id"])
    assert record["owner_user_id"] == f.user
    assert get_in(record, ["source_refs", "task_execution", "requester_id"]) == f.user
  end

  test "IFC enforce checks the real Comma request, the delegated operation and the Worker report",
       f do
    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "ifc", %{"mode" => "enforce"}))

    SalixIM.IFC.Projection.observe_direct(
      %{tenant_id: f.tenant, group_id: f.group, connect_id: f.connect},
      "123",
      "123"
    )

    Application.put_env(:salix_im, :task_execution_test_link, {f.connect, "123"})

    {task, context} = create_task(f, %{}, :enforce)
    ctx = runtime_context(f, context, "worker", :enforce)
    request_ref = SalixAgent.IFC.input_ref(1)
    [original] = ctx.ifc["items"]
    assert original["integrity"] == "data"
    assert ctx.ifc["requester"] == nil

    result =
      execute(
        ctx,
        "im_api.telegram.remove_reply_keyboard",
        %{
          "connect_id" => f.connect,
          "chat_id" => "123",
          "text" => "测试键盘已移除。"
        },
        %{"request" => request_ref, "sources" => [request_ref]}
      )

    refute result.error, inspect(result)
    assert result.status == "completed", inspect(result)
    assert_receive {:telegram, %{"reply_markup" => %{"remove_keyboard" => true}}}
    assert ctx.ifc["items"] == [original]

    Application.delete_env(:salix_im, :task_execution_test_link)

    unlinked =
      execute(
        ctx,
        "im_api.telegram.remove_reply_keyboard",
        %{"connect_id" => f.connect, "chat_id" => "123", "text" => "unlinked"},
        %{"request" => request_ref, "sources" => [request_ref]}
      )

    assert unlinked.error or unlinked.status == "guidance", inspect(unlinked)
    refute_receive {:telegram, _}, 20
    Application.put_env(:salix_im, :task_execution_test_link, {f.connect, "123"})

    refused =
      execute(
        ctx,
        "im_api.telegram.send_message",
        %{
          "connect_id" => f.connect,
          "chat_id" => "123",
          "text" => "ungranted"
        },
        %{"request" => request_ref, "sources" => []}
      )

    assert refused.error or refused.status == "guidance", inspect(refused)
    refute_receive {:telegram, _}, 20

    report =
      execute(
        ctx,
        "im_api.internal.send_message",
        %{
          "connect_id" => "internal",
          "conversation_id" => task["conversation_id"],
          "content" => [%{"type" => "text", "text" => "Telegram 已接受键盘移除请求；客户端按钮消失仍需用户确认。"}]
        },
        %{"request" => request_ref, "sources" => [request_ref]}
      )

    refute report.error, inspect(report)
    assert report.status == "completed", inspect(report)

    {:ok, messages} =
      Conversations.list_group_conversation_messages(f.group, task["conversation_id"])

    assert Enum.any?(messages, &(inspect(&1["content"]) =~ "客户端按钮消失"))

    assert {:ok, %{"status" => "active"}} =
             Conversations.get_group_conversation_record(f.group, task["conversation_id"])
  end

  for {legacy, threaded} <- [{false, true}, {true, true}, {true, false}] do
    @tag legacy_slack_grant: legacy, threaded_slack_grant: threaded
    test "Slack grant legacy=#{legacy} threaded=#{threaded} preserves its exact target", f do
      Application.put_env(:salix_im, :task_execution_test_legacy_grant, f.legacy_slack_grant)

      api =
        if f.threaded_slack_grant, do: "slack.reply_message", else: "slack.post_channel_message"

      target =
        if f.threaded_slack_grant,
          do: %{"channel" => "C1", "thread_ts" => "100.200"},
          else: %{"channel" => "C1"}

      connect = Ids.new_connect_id()

      {:ok, _} =
        CasRecord.create(Keys.ctl_im_connect(f.group, connect), %{
          "tenant_id" => f.tenant,
          "group_id" => f.group,
          "connect_id" => connect,
          "provider" => "slack",
          "workspace_id" => "T1",
          "connect_generation" => "generation1",
          "bot_token" => "xoxb-test",
          "app_id" => "A1",
          "oauth_completed_at" => 1,
          "inbound_agent_id" => f.router
        })

      {task, context} =
        create_task(f, %{
          "execution_requests" => [
            %{
              "api" => api,
              "connect_id" => connect,
              "params" => target
            }
          ]
        })

      {:ok, stored} =
        Conversations.get_group_conversation_record(f.group, task["conversation_id"])

      [stored_request] = get_in(stored, ["source_refs", "task_execution", "requests"])

      assert stored_request["api"] ==
               if(f.legacy_slack_grant, do: "slack.post_message", else: api)

      ctx = runtime_context(f, context, "worker", :off)

      args = Map.merge(target, %{"connect_id" => connect, "text" => "done"})

      result = execute(ctx, "im_api." <> api, args, %{})
      assert result.status == "completed", inspect(result)
      assert_receive {:slack, sent}
      assert Map.take(sent, ["channel", "thread_ts"]) == target

      opposite =
        if f.threaded_slack_grant, do: "slack.post_channel_message", else: "slack.reply_message"

      opposite_args =
        if f.threaded_slack_grant,
          do: Map.delete(args, "thread_ts"),
          else: Map.put(args, "thread_ts", "100.200")

      denied = execute(ctx, "im_api." <> opposite, opposite_args, %{})
      assert denied.error or denied.status == "guidance", inspect(denied)

      for params <- [
            Map.delete(args, "channel"),
            Map.put(args, "channel", "C2"),
            Map.put(args, "thread_ts", "other"),
            Map.put(args, "metadata", %{})
          ] do
        result = execute(ctx, "im_api." <> api, params, %{})
        assert result.error or result.status == "guidance", inspect(result)
      end

      refute_receive {:slack, _}, 20

      {:ok, _} =
        CasRecord.update(
          Keys.ctl_im_connect(f.group, connect),
          &Map.put(&1, "connect_generation", "generation2")
        )

      assert {:ok, manual} = Provider.provider_manual("slack", f.worker, context)
      refute Enum.any?(manual["apis"], &(&1["name"] == api))
      result = execute(ctx, "im_api." <> api, args, %{})
      assert result.error or result.status == "guidance", inspect(result)
      refute_receive {:slack, _}, 20
    end
  end

  test "delegation cannot authorize other tools, another request, or unrelated private sources",
       f do
    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "ifc", %{"mode" => "enforce"}))

    SalixIM.IFC.Projection.observe_direct(
      %{tenant_id: f.tenant, group_id: f.group, connect_id: f.connect},
      "123",
      "123"
    )

    Application.put_env(:salix_im, :task_execution_test_link, {f.connect, "123"})
    {_task, context} = create_task(f, %{}, :enforce)
    ctx = runtime_context(f, context, "worker", :enforce)
    ref = SalixAgent.IFC.input_ref(1)
    foreign_ref = "src:t-foreign"

    foreign = %{
      "ref" => foreign_ref,
      "integrity" => "data",
      "principal" => nil,
      "label" => ["agent_private"]
    }

    ctx = update_in(ctx, [:ifc, "items"], &(&1 ++ [foreign]))
    args = %{"connect_id" => f.connect, "chat_id" => "123", "text" => "PRIVATE_CANARY"}

    for declaration <- [
          %{"request" => foreign_ref, "sources" => []},
          %{"request" => ref, "sources" => [foreign_ref]},
          %{"request" => ref}
        ] do
      result = execute(ctx, "im_api.telegram.remove_reply_keyboard", args, declaration)
      assert result.error or result.status == "guidance", inspect(result)
    end

    refute_receive {:telegram, _}, 20

    assert :none =
             Provider.task_execution_request(
               "fs.write_file",
               %{"path" => "/drive/leak", "content" => "x"},
               ctx
             )

    assert :none =
             Provider.task_execution_request(
               "im_api.internal.send_message",
               %{"connect_id" => "internal", "conversation_id" => "another-task"},
               ctx
             )

    assert ctx.ifc["requester"] == nil
  end

  test "Feishu Task scope uses the existing adapter and cannot change the recipient type", f do
    connect = Ids.new_connect_id()

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(f.group, connect), %{
        "tenant_id" => f.tenant,
        "group_id" => f.group,
        "connect_id" => connect,
        "provider" => "feishu",
        "status" => "connected",
        "app_id" => "cli1",
        "tenant_key" => "tenant1",
        "tenant_access_token" => "test-token"
      })

    {_task, context} =
      create_task(f, %{
        "execution_requests" => [
          %{
            "api" => "feishu.send_text",
            "connect_id" => connect,
            "params" => %{"receive_id" => "oc1", "receive_id_type" => "chat_id"}
          }
        ]
      })

    ctx = runtime_context(f, context, "worker", :off)

    args = %{
      "connect_id" => connect,
      "receive_id" => "oc1",
      "receive_id_type" => "chat_id",
      "text" => "done"
    }

    result = execute(ctx, "im_api.feishu.send_text", args, %{})
    assert result.status == "completed", inspect(result)

    assert_receive {:feishu, %{"receive_id" => "oc1", "content" => content},
                    "receive_id_type=chat_id"}

    assert Jason.decode!(content) == %{"text" => "done"}

    for params <- [
          Map.put(args, "receive_id_type", "open_id"),
          Map.put(args, "receive_id", "oc2"),
          Map.put(args, "mention_all", true)
        ] do
      result = execute(ctx, "im_api.feishu.send_text", params, %{})
      assert result.error or result.status == "guidance", inspect(result)
    end

    refute_receive {:feishu, _, _}, 20
  end

  test "runtime configuration discovers only the grant from the current admitted envelope", f do
    {_task, context} = create_task(f)
    ctx = runtime_context(f, context, "worker", :off)

    config =
      ctx
      |> Map.put(:messages, ctx.input_messages)
      |> Map.drop([:trusted_origin, :source_message_id, :ifc, :tool_disclosure])

    for kind <- [:internal, :external],
        config <- [config, struct(SalixAgent.InternalSession.State, config)] do
      entries =
        SalixAgent.Tools.ImRouter.dynamic_disclosure_entries(Map.put(config, :runtime_kind, kind))

      assert Enum.any?(entries, &(&1["name"] == "im_api.telegram.remove_reply_keyboard"))
      refute Enum.any?(entries, &(&1["name"] == "im_api.telegram.send_message"))
    end

    # A round configuration that carries no admitted source ids of its own is
    # answered by the kernel from the transcript: with the envelope's message
    # acknowledged, no source is current and the grant it carried is gone.
    entries =
      SalixAgent.Tools.ImRouter.dynamic_disclosure_entries(
        config
        |> Map.delete(:source_message_ids)
        |> Map.put(:last_ack_message_id, 1)
      )

    refute Enum.any?(entries, &String.starts_with?(&1["name"], "im_api.telegram."))
  end

  test "a round configuration seeded from the Session handle keeps the delegated grant", f do
    {_task, context} = create_task(f)
    ctx = runtime_context(f, context, "worker", :off)

    # The transcript the Worker's Session actually holds: the delegated
    # envelope, unacknowledged.
    session =
      SalixAgent.InternalSession.open(%SalixAgent.InternalSession.State{
        agent_id: f.worker,
        session_id: ctx.session_id,
        platform: "internal",
        next_message_id: 2,
        last_ack_message_id: 0,
        messages: ctx.input_messages
      })

    session_context = SalixAgent.RoundConfig.round_session_context(session)

    assert session_context.session_id == ctx.session_id
    assert session_context.source_message_ids == ctx.source_message_ids
    assert [%{"source_message_id" => _}] = session_context.trusted_origins

    assert {:ok, %{session_config: config}} =
             SalixAgent.RoundConfig.build_round_config(f.worker, "worker", session_context)

    assert {:ok, snapshot} =
             SalixAgent.RoundConfig.build_round_snapshot(f.worker, session_context)

    assert {:ok, %{session_config: cached}} =
             SalixAgent.RoundConfig.materialize_round_snapshot(
               f.worker,
               snapshot,
               session_context
             )

    assert disclosed_tool_names(cached) == disclosed_tool_names(config)

    assert {:ok, %{session_config: next_round}} =
             SalixAgent.RoundConfig.materialize_round_snapshot(f.worker, snapshot, %{
               platform: "internal",
               source_message_ids: [],
               trusted_origins: []
             })

    refute Enum.any?(
             disclosed_tool_names(next_round),
             &String.starts_with?(&1, "im_api.telegram.")
           )

    names = disclosed_tool_names(config)
    assert "im_api.telegram.remove_reply_keyboard" in names
    refute "im_api.telegram.send_message" in names

    # The regression: a projection that keeps only the Session's identity and
    # platform drops the admitted sources, so the delegation is invisible and
    # the authorized capability disappears from the round's disclosure.
    identity_only = Map.take(session_context, [:session_id, :platform])

    assert {:ok, %{session_config: blind}} =
             SalixAgent.RoundConfig.build_round_config(f.worker, "worker", identity_only)

    refute Enum.any?(disclosed_tool_names(blind), &String.starts_with?(&1, "im_api.telegram."))
  end

  test "the Worker's activation uses the stable call envelope with Task delegation", f do
    Application.put_env(:salix_im, :task_execution_test_runtime_agent, f.worker)
    create_task(f)

    assert_receive {:offered_tools, tools}, 10_000
    assert tools == SalixAgent.ToolDisclosure.internal_llm_specs("worker")
  end

  test "Task admission rejects unsupported scopes and cannot widen an exact retry", f do
    context = router_request_context(f)
    params = task_params(f)

    call = fn args, ctx ->
      Provider.call_api(f.router, "internal", "internal.task.create", %{
        "connect_id" => "internal",
        "tool_context" => ctx,
        "params" => args
      })
    end

    for changed <- [
          put_in(params, ["execution_requests", Access.at(0), "api"], "telegram.get_chat"),
          put_in(params, ["execution_requests", Access.at(0), "params"], %{"chat_id" => "other"}),
          Map.put(
            params,
            "execution_requests",
            List.duplicate(hd(params["execution_requests"]), 21)
          ),
          Map.put(params, "schedule", %{"interval_minutes" => 5})
        ] do
      assert {:error, _} = call.(changed, context)
    end

    assert {:error, _} = call.(params, Map.put(context, "session_id", Ids.new_session_id()))
    assert {:error, _} = call.(params, Map.put(context, "source_message_ids", []))

    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "router_agent_id", f.worker))

    assert {:error, _} = call.(params, context)

    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "router_agent_id", f.router))

    Application.delete_env(:salix_im, :task_execution_test_owner)
    assert {:error, _} = call.(params, context)
    Application.put_env(:salix_im, :task_execution_test_owner, {f.group, f.user})
    assert {:ok, first} = call.(params, context)
    assert {:ok, retry} = call.(params, context)
    assert first["conversation_id"] == retry["conversation_id"]
    changed = put_in(params, ["execution_requests", Access.at(0), "api"], "telegram.send_message")
    assert {:error, _} = call.(changed, context)
    {:ok, saved} = Conversations.get_group_conversation_record(f.group, first["conversation_id"])

    assert hd(saved["source_refs"]["task_execution"]["requests"])["api"] ==
             "telegram.remove_reply_keyboard"
  end

  test "old source, different Session, revoked owner and rebound account cannot execute", f do
    {_task, context} = create_task(f)

    for changed <- [
          Map.put(context, "session_id", Ids.new_session_id()),
          Map.put(context, "source_message_id", "another-source"),
          Map.put(context, "source_message_ids", [])
        ] do
      assert {:error, _} = remove_keyboard(f, changed)
    end

    Application.delete_env(:salix_im, :task_execution_test_owner)
    assert {:error, _} = remove_keyboard(f, context)
    assert {:ok, [%{"connect_id" => "internal"}]} = Provider.list_connects(f.worker, context)
    assert {:error, :unsupported} = Provider.provider_manual("telegram", f.worker, context)
    Application.put_env(:salix_im, :task_execution_test_owner, {f.group, f.user})

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(f.group, f.connect),
        &Map.put(&1, "bot_user_id", "another-bot")
      )

    assert {:error, _} = remove_keyboard(f, context)
    refute_receive {:telegram, _}, 20
  end

  test "cancellation and generic source-ref forgery cannot keep or add execution access", f do
    {task, context} = create_task(f)
    id = task["conversation_id"]
    {:ok, record} = Conversations.get_group_conversation_record(f.group, id)
    refs = record["source_refs"]
    forged = put_in(refs, ["task_execution", "requests"], [])

    assert {:error, _} =
             ConversationServer.update_group_conversation(f.group, id, %{"source_refs" => forged})

    assert {:ok, _} =
             ConversationServer.update_group_conversation(f.group, id, %{"status" => "cancelled"})

    assert {:error, _} = remove_keyboard(f, context)
    assert {:ok, [%{"connect_id" => "internal"}]} = Provider.list_connects(f.worker, context)
    refute_receive {:telegram, _}, 20
  end

  test "ordinary Worker can report to its own Task without external execution grants", f do
    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "ifc", %{"mode" => "enforce"}))

    {task, context} = create_task(f, %{"execution_requests" => nil}, :enforce)
    ctx = runtime_context(f, context, "worker", :enforce)
    ref = SalixAgent.IFC.input_ref(1)

    args = %{
      "connect_id" => "internal",
      "conversation_id" => task["conversation_id"],
      "content" => [%{"type" => "text", "text" => "Ordinary task report"}]
    }

    assert ctx.ifc["requester"] == nil

    report =
      execute(ctx, "im_api.internal.send_message", args, %{"request" => ref, "sources" => [ref]})

    assert report.status == "completed", inspect(report)
    refute report.error

    {:ok, messages} =
      Conversations.list_group_conversation_messages(f.group, task["conversation_id"])

    assert Enum.any?(messages, &(inspect(&1["content"]) =~ "Ordinary task report"))

    # Reporting authority belongs to this assignment, never to another Task,
    # Session or effect, and never changes the persisted input's integrity.
    assert :none =
             Provider.task_execution_request(
               "im_api.internal.send_message",
               Map.put(args, "conversation_id", "another-task"),
               ctx
             )

    assert :none =
             Provider.task_execution_request("im_api.internal.send_message", args, %{
               ctx
               | session_id: "another-session"
             })

    assert :none =
             Provider.task_execution_request("im_api.internal.send_message", args, %{
               ctx
               | source_message_ids: []
             })

    assert :none =
             Provider.task_execution_request(
               "im_api.telegram.remove_reply_keyboard",
               %{"connect_id" => f.connect, "chat_id" => "123"},
               ctx
             )

    assert ctx.ifc["requester"] == nil

    foreign = %{
      "ref" => "src:t-private",
      "integrity" => "data",
      "principal" => nil,
      "label" => ["agent_private"]
    }

    private_ctx = update_in(ctx, [:ifc, "items"], &(&1 ++ [foreign]))

    denied =
      execute(
        private_ctx,
        "im_api.internal.send_message",
        Map.put(args, "content", [%{"type" => "text", "text" => "PRIVATE_REPORT_CANARY"}]),
        %{"request" => ref, "sources" => [foreign["ref"]]}
      )

    assert denied.status == "guidance", inspect(denied)

    {:ok, messages} =
      Conversations.list_group_conversation_messages(f.group, task["conversation_id"])

    refute Enum.any?(messages, &(inspect(&1["content"]) =~ "PRIVATE_REPORT_CANARY"))
  end

  test "a later delegator message can authorize a report, but a cancelled Task cannot", f do
    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "ifc", %{"mode" => "enforce"}))

    {task, _context} = create_task(f, %{"execution_requests" => nil}, :enforce)
    id = task["conversation_id"]

    assert {:ok, _} =
             ConversationServer.append_group_conversation_agent_message(
               f.group,
               id,
               f.router,
               %{
                 "content" => "Clarify the requested report",
                 "client_request_id" => Ids.new_message_id()
               }
             )

    worker = f.worker
    assert_receive {:delivered, ^worker, payload}, 2_000
    ctx = runtime_context(f, tool_context(f, worker, payload), "worker", :enforce)
    ref = SalixAgent.IFC.input_ref(1)

    args = %{
      "connect_id" => "internal",
      "conversation_id" => id,
      "content" => [%{"type" => "text", "text" => "Follow-up report"}]
    }

    assert {:ok, _, principal} =
             Provider.task_execution_request("im_api.internal.send_message", args, ctx)

    assert principal == "agent|" <> worker

    result =
      execute(ctx, "im_api.internal.send_message", args, %{"request" => ref, "sources" => [ref]})

    assert result.status == "completed", inspect(result)
    assert ctx.ifc["requester"] == nil

    assert {:ok, _} =
             ConversationServer.update_group_conversation(f.group, id, %{"status" => "cancelled"})

    assert :none = Provider.task_execution_request("im_api.internal.send_message", args, ctx)

    denied =
      execute(ctx, "im_api.internal.send_message", args, %{"request" => ref, "sources" => []})

    assert denied.status == "guidance", inspect(denied)
  end

  test "Router coordinates only its own live Task after a consumed Worker report", f do
    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "ifc", %{"mode" => "enforce"}))

    {task, _} = create_task(f, %{"execution_requests" => nil}, :enforce)
    ctx = router_report_context(f, task)
    ref = SalixAgent.IFC.input_ref(1)
    target = %{"connect_id" => "internal", "conversation_id" => task["conversation_id"]}

    args =
      Map.put(target, "content", [
        %{"type" => "text", "text" => "Please retain the evidence in this Task"}
      ])

    assert ctx.ifc["requester"] == nil

    result =
      execute(ctx, "im_api.internal.send_message", args, %{"request" => ref, "sources" => [ref]})

    assert result.status == "completed", inspect(result)

    for denied_ctx <- [Map.put(ctx, :session_id, "stale"), Map.put(ctx, :source_message_ids, [])] do
      assert :none =
               Provider.task_execution_request("im_api.internal.send_message", args, denied_ctx)
    end

    assert :none =
             Provider.task_execution_request(
               "im_api.internal.send_message",
               Map.put(args, "conversation_id", "other"),
               ctx
             )

    assert :none =
             Provider.task_execution_request("memory.write", %{"path" => "/memory/test"}, ctx)

    update = Map.put(target, "status", "ready_for_review")

    for invalid <- [Map.put(update, "status", "failed"), Map.put(update, "source_refs", %{})] do
      assert :none =
               Provider.task_execution_request(
                 "im_api.internal.update_conversation",
                 invalid,
                 ctx
               )
    end

    private = %{
      "ref" => "src:t-private",
      "label" => ["agent_private"],
      "integrity" => "data",
      "principal" => nil
    }

    tainted = update_in(ctx, [:ifc, "items"], &(&1 ++ [private]))

    denied =
      execute(tainted, "im_api.internal.send_message", args, %{
        "request" => ref,
        "sources" => [private["ref"]]
      })

    assert denied.status == "guidance", inspect(denied)

    denied_update =
      execute(tainted, "im_api.internal.update_conversation", update, %{
        "request" => ref,
        "sources" => [private["ref"]]
      })

    assert denied_update.status == "guidance", inspect(denied_update)
    assert Jason.decode!(denied_update.content)["clause"] == "flow_denied"

    assert {:ok, unchanged} =
             Conversations.get_group_conversation_record(f.group, task["conversation_id"])

    assert unchanged["status"] == task["status"]

    stale_ref =
      execute(ctx, "im_api.internal.send_message", args, %{
        "request" => "src:q-old",
        "sources" => []
      })

    assert stale_ref.status == "guidance", inspect(stale_ref)

    result =
      execute(ctx, "im_api.internal.update_conversation", update, %{
        "request" => ref,
        "sources" => [ref]
      })

    assert result.status == "completed", inspect(result)
    assert ctx.ifc["requester"] == nil
    assert Enum.all?(ctx.ifc["items"], &(&1["integrity"] == "data"))

    done = Map.put(target, "status", "completed")

    result =
      execute(ctx, "im_api.internal.update_conversation", done, %{
        "request" => ref,
        "sources" => [ref]
      })

    assert result.status == "completed", inspect(result)

    assert {:ok, completed} =
             Conversations.get_group_conversation_record(f.group, task["conversation_id"])

    assert completed["status"] == "completed"

    # The first response can be lost after the owner commits Done.
    retry =
      execute(ctx, "im_api.internal.update_conversation", done, %{
        "request" => ref,
        "sources" => [ref]
      })

    assert retry.status == "completed", inspect(retry)

    assert {:ok, %{"status" => "completed"}} =
             Conversations.get_group_conversation_record(f.group, task["conversation_id"])

    for invalid <- [
          update,
          Map.put(done, "status", "active"),
          Map.put(done, "title", "changed"),
          Map.put(done, "conversation_id", "other")
        ] do
      assert :none =
               Provider.task_execution_request(
                 "im_api.internal.update_conversation",
                 invalid,
                 ctx
               )
    end

    assert :none = Provider.task_execution_request("im_api.internal.send_message", args, ctx)
    assert :none = Provider.task_execution_request("slack.reply_message", %{}, ctx)

    for invalid_ctx <- [Map.put(ctx, :session_id, "stale"), Map.put(ctx, :source_message_ids, [])] do
      assert :none =
               Provider.task_execution_request(
                 "im_api.internal.update_conversation",
                 done,
                 invalid_ctx
               )
    end

    denied_retry =
      execute(tainted, "im_api.internal.update_conversation", done, %{
        "request" => ref,
        "sources" => [private["ref"]]
      })

    assert denied_retry.status == "guidance", inspect(denied_retry)
    assert Jason.decode!(denied_retry.content)["clause"] == "flow_denied"

    assert {:ok, _} =
             ConversationServer.update_group_conversation(f.group, task["conversation_id"], %{
               "status" => "cancelled"
             })

    assert :none = Provider.task_execution_request("im_api.internal.send_message", args, ctx)
  end

  for status <- ~w(active ready_for_review completed failed cancelled escalated) do
    @tag task_status: status
    test "Router reply after #{status} retains the Slack target and rejects private data and installation replacement",
         f do
      {task, source_ctx, connect} = slack_task(f)
      ctx = router_report_context(f, task)
      ref = SalixAgent.IFC.input_ref(1)

      # Commit the state before the notice, as happens when delivery preceded
      # the Worker's final report. Completion goes through the real IFC/provider.
      if f.task_status in ~w(ready_for_review completed) do
        update = %{
          "connect_id" => "internal",
          "conversation_id" => task["conversation_id"],
          "status" => f.task_status
        }

        result =
          execute(ctx, "im_api.internal.update_conversation", update, %{
            "request" => ref,
            "sources" => [ref]
          })

        assert result.status == "completed", inspect(result)
      else
        assert {:ok, _} =
                 ConversationServer.update_group_conversation(f.group, task["conversation_id"], %{
                   "status" => f.task_status
                 })
      end

      assert {:ok, %{"status" => status}} =
               Conversations.get_group_conversation_record(f.group, task["conversation_id"])

      assert status == f.task_status

      args = %{
        "connect_id" => connect,
        "channel" => "C1",
        "thread_ts" => "100.200",
        "text" => "Analysis complete"
      }

      assert {:ok, _, principal, label} =
               Provider.task_execution_request("im_api.slack.reply_message", args, ctx)

      assert principal == "provider_user|#{connect}|U1"
      assert label == ["space|#{connect}"]

      result =
        execute(ctx, "im_api.slack.reply_message", args, %{"request" => ref, "sources" => [ref]})

      assert result.status == "completed", inspect(result)
      assert_receive {:slack, %{"channel" => "C1", "thread_ts" => "100.200"}}, 2_000

      for invalid <- [
            Map.delete(args, "thread_ts"),
            Map.put(args, "thread_ts", "other"),
            Map.put(args, "channel", "C2"),
            Map.put(args, "metadata", %{})
          ] do
        assert :none = Provider.task_execution_request("im_api.slack.reply_message", invalid, ctx)
      end

      for invalid_ctx <- [
            Map.put(ctx, :session_id, "stale"),
            Map.put(ctx, :source_message_ids, []),
            Map.put(ctx, :agent_id, f.worker)
          ] do
        assert :none =
                 Provider.task_execution_request("im_api.slack.reply_message", args, invalid_ctx)
      end

      private = %{
        "ref" => "src:t-private",
        "label" => ["agent_private"],
        "integrity" => "data",
        "principal" => nil
      }

      tainted = update_in(ctx, [:ifc, "items"], &(&1 ++ [private]))

      denied =
        execute(tainted, "im_api.slack.reply_message", args, %{
          "request" => ref,
          "sources" => [private["ref"]]
        })

      assert denied.status == "guidance", inspect(denied)
      assert ctx.ifc["requester"] == nil

      {:ok, record} =
        Conversations.get_group_conversation_record(f.group, task["conversation_id"])

      assert get_in(record, ["source_refs", "ifc_return", "target"]) == Map.drop(args, ["text"])
      source = get_in(record, ["source_refs", "task_reply_source"])
      assert Map.take(source, ~w(connect_id channel thread_ts)) == Map.drop(args, ["text"])

      assert {:error, _} =
               ConversationServer.update_group_conversation(f.group, task["conversation_id"], %{
                 "source_refs" => Map.put(record["source_refs"], "task_reply_source", %{})
               })

      for refs <- [%{}, Map.put(record["source_refs"], "ifc_return", %{"target" => %{}})] do
        assert {:error, _} =
                 ConversationServer.update_group_conversation(f.group, task["conversation_id"], %{
                   "source_refs" => refs
                 })
      end

      assert {:error, _} =
               ConversationServer.create_group_conversation(f.group, %{
                 "kind" => "agent_task",
                 "source_refs" => %{"ifc_return" => %{}}
               })

      {:ok, scope} = SalixIM.GroupDirectory.scope_for_agent(f.router)

      for invalid <- [
            Map.put(source_ctx, :source_message_ids, []),
            put_in(source_ctx, [:trusted_origin, "source_actor_type"], "agent"),
            Map.put(source_ctx, :ifc_evidence, nil)
          ] do
        assert %{} == SalixIM.TaskContinuation.source_refs(scope, invalid, %{})
      end

      {:ok, _} =
        CasRecord.update(
          Keys.ctl_im_connect(f.group, connect),
          &Map.put(&1, "connect_generation", "replacement")
        )

      assert :none = Provider.task_execution_request("im_api.slack.reply_message", args, ctx)
    end
  end

  defp disclosed_tool_names(%{tool_disclosure: %{"tools" => tools}}),
    do: Enum.map(tools, & &1["name"])

  defp router_report_context(f, task) do
    {:ok, result} =
      ConversationServer.append_group_conversation_agent_message(
        f.group,
        task["conversation_id"],
        f.worker,
        %{
          "content" => "Worker analysis result",
          "client_request_id" => Ids.new_message_id()
        }
      )

    router = f.router
    message_id = result["message_id"]

    assert_receive {:delivered, ^router,
                    %{trusted_origin: %{"message_id" => ^message_id}} = payload},
                   2_000

    runtime_context(f, tool_context(f, router, payload), "router", :enforce)
  end

  defp slack_task(f) do
    connect = Ids.new_connect_id()

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(f.group, connect), %{
        "tenant_id" => f.tenant,
        "group_id" => f.group,
        "connect_id" => connect,
        "provider" => "slack",
        "workspace_id" => "T1",
        "connect_generation" => "generation1",
        "bot_token" => "xoxb-test",
        "app_id" => "A1",
        "oauth_completed_at" => 1,
        "inbound_agent_id" => f.router
      })

    {:ok, _} =
      CasRecord.update(Keys.ctl_group(f.group), &Map.put(&1, "ifc", %{"mode" => "enforce"}))

    source = "im_provider:slack:#{connect}:event1"
    principal = "provider_user|#{connect}|U1"

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "agent_group_id" => f.group,
      "source_message_id" => source,
      "ifc" => %{
        "integrity" => "command",
        "principal" => principal,
        "label" => ["space|#{connect}"],
        "placement" => "internal"
      },
      "provider_context" => %{
        "connect_id" => connect,
        "channel_id" => "C1",
        "thread_ts" => "100.200",
        "user_id" => "U1"
      }
    }

    input = %{
      id: 1,
      role: "user",
      content: "Analyze the videos",
      source_message_id: source,
      trusted_origin: origin
    }

    base = runtime_context(f, router_request_context(f), "router", :enforce)

    ctx = %{
      base
      | trusted_origin: origin,
        source_message_id: source,
        source_message_ids: [source],
        input_messages: [input],
        ifc:
          SalixAgent.IFC.Context.build(%{messages: [input]},
            source_message_id: source,
            source_message_ids: [source],
            trusted_origin: origin
          )
    }

    ref = SalixAgent.IFC.input_ref(1)
    params = Map.merge(task_params(f), %{"execution_requests" => nil, "connect_id" => "internal"})

    result =
      execute(ctx, "im_api.internal.task.create", params, %{"request" => ref, "sources" => [ref]})

    assert result.status == "completed", inspect(result)
    task = Jason.decode!(result.content)
    {task, Map.put(ctx, :ifc_evidence, %{"requester" => principal}), connect}
  end

  defp create_task(f, extra \\ %{}, mode \\ :off) do
    context = router_request_context(f)
    router = f.router
    params = Map.merge(task_params(f), extra)

    task =
      if mode == :enforce do
        ctx = runtime_context(f, context, "router", mode)
        ref = SalixAgent.IFC.input_ref(1)

        result =
          execute(
            ctx,
            "im_api.internal.task.create",
            Map.put(params, "connect_id", "internal"),
            %{"request" => ref, "sources" => [ref]}
          )

        refute result.error, inspect(result)
        assert result.status == "completed", inspect(result)
        Jason.decode!(result.content)
      else
        assert {:ok, result} =
                 Provider.call_api(router, "internal", "internal.task.create", %{
                   "connect_id" => "internal",
                   "tool_context" => context,
                   "params" => params
                 })

        result
      end

    worker = f.worker
    assert_receive {:delivered, ^worker, worker_payload}, 2_000
    {task, tool_context(f, worker, worker_payload)}
  end

  defp runtime_context(f, context, role, mode) do
    origin = context["trusted_origin"]

    {:ok, message} =
      Conversations.get_group_conversation_message(
        f.group,
        origin["conversation_id"],
        origin["message_id"]
      )

    input = %{
      id: 1,
      role: "user",
      content: message["content"],
      source_message_id: context["source_message_id"],
      trusted_origin: origin
    }

    ctx =
      %{
        agent_id: context["agent_id"],
        session_id: context["session_id"],
        tenant_id: f.tenant,
        group_id: f.group,
        role: role,
        runtime_kind: :internal,
        trusted_origin: origin,
        source_message_id: context["source_message_id"],
        source_message_ids: context["source_message_ids"],
        ifc_mode: mode,
        input_messages: [input],
        ifc:
          SalixAgent.IFC.Context.build(%{messages: [input]},
            source_message_id: context["source_message_id"],
            source_message_ids: context["source_message_ids"],
            trusted_origin: origin
          )
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, SalixAgent.ToolDisclosure.materialize(role, :internal, ctx))
  end

  defp execute(ctx, name, args, ifc) do
    [result] =
      SalixAgent.SessionToolDispatch.execute(
        [%{id: Ids.new_message_id(), name: name, args: args, ifc: ifc}],
        ctx
      )

    result
  end

  defp router_request_context(f) do
    {:ok, _} =
      RouterConversationInput.append_user_message(f.group, %{
        "user_id" => f.user,
        "content" => "清除我 Telegram 里的定位测试键盘",
        "client_request_id" => Ids.new_message_id()
      })

    router = f.router
    assert_receive {:delivered, ^router, payload}, 2_000
    tool_context(f, router, payload)
  end

  defp task_params(f) do
    %{
      "agent_id" => f.worker,
      "content" => "移除 Telegram 定位测试键盘，验证接口回执，然后报告。",
      "execution_requests" => [
        %{
          "api" => "telegram.remove_reply_keyboard",
          "connect_id" => f.connect,
          "params" => %{"chat_id" => "123"}
        }
      ]
    }
  end

  defp tool_context(f, agent, payload) do
    %{
      "agent_id" => agent,
      "tenant_id" => f.tenant,
      "group_id" => f.group,
      "session_id" => payload[:session_id],
      "trusted_origin" => payload[:trusted_origin],
      "source_message_id" => payload[:trusted_origin]["source_message_id"],
      "source_message_ids" => [payload[:trusted_origin]["source_message_id"]]
    }
  end

  defp remove_keyboard(f, context, extra \\ %{}) do
    Provider.call_api(f.worker, "telegram", "telegram.remove_reply_keyboard", %{
      "connect_id" => f.connect,
      "tool_context" => context,
      "params" => Map.merge(%{"chat_id" => "123", "text" => "测试键盘已移除。"}, extra)
    })
  end
end
