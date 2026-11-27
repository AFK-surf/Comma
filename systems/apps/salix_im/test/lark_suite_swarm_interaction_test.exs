defmodule SalixIM.LarkSuiteSwarmInteractionTest do
  @moduledoc """
  Feishu and Lark multi-swarm / bot-to-bot inbound and thread interaction rules,
  aligned with Slack:

    * explicit foreign-only mentions never wake a participating or Task-bound
      bot and do not trigger Triage on owned threads;
    * mixed mentions, `@all` broadcasts, and unmentioned replies in owned
      threads still wake the bot;
    * leaving a thread leaves a `:left` tombstone that blocks other apps/bots
      from pulling the bot back even with `@self`, while humans can still
      re-invoke it;
    * app-authored messages from peer bots carry `source_actor_type:
      "provider_system"` and `provider_context["app_authored"] == true` and
      never execute control commands;
    * a group the bot creates, and a message the bot sends into a group
      unasked, are conversations of the bot: people answer there without a
      mention until the Router leaves.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.{
    Conversations,
    LarkInbound,
    LarkThreads,
    ProviderConnects,
    ProviderHTTP,
    RouterConversationInput
  }

  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Ids, Keys, Repo}
  alias SalixStore.LarkSuiteTriage, as: TriageStore

  @bot "ou_bot_self"
  @peer_bot "ou_bot_peer"
  @human "ou_alice"
  @chat "oc_swarm_group"

  defmodule API do
    @moduledoc "Feishu's and Lark's OpenAPI, which share their paths: what the sends here need."
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      ["open-apis" | path] = conn.path_info
      SystemsRuntime.Proc.send(test_pid, {:open_api, conn.method, path, body})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(answer(conn.method, path, body)))
    end

    defp answer("POST", ["auth", "v3", "tenant_access_token", "internal"], body),
      do: %{"code" => 0, "tenant_access_token" => "t-" <> body["app_id"], "expire" => 7200}

    defp answer("POST", ["im", "v1", "chats"], _body),
      do: ok(%{"chat_id" => "oc_created", "chat_type" => "private"})

    # A message to a chat is of that chat. A topic group puts each message
    # into a thread of its own.
    defp answer("POST", ["im", "v1", "messages"], %{"receive_id" => chat_id}) do
      sent = %{"message_id" => "om_sent_" <> chat_id, "chat_id" => chat_id}

      ok(
        if String.starts_with?(chat_id, "oc_topic"),
          do: Map.put(sent, "thread_id", "omt_" <> chat_id),
          else: sent
      )
    end

    defp answer("POST", ["im", "v1", "messages", message_id, "reply"], body) do
      sent = %{"message_id" => "om_reply_" <> message_id, "chat_id" => body["chat_id"] || ""}

      ok(
        if body["reply_in_thread"] == true,
          do: Map.put(sent, "thread_id", "omt_" <> message_id),
          else: sent
      )
    end

    defp answer(_method, _path, _body), do: ok(%{})

    defp ok(data), do: %{"code" => 0, "msg" => "ok", "data" => data}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_cmd_exec = SystemsRuntime.get_env(:salix_im, :control_command_execution)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_im, :control_command_execution, :sync)

    prev_api = {
      SystemsRuntime.get_env(:salix_im, :feishu_api_base_url),
      SystemsRuntime.get_env(:salix_im, :lark_api_base_url)
    }

    api_base = BanditServer.serve!(API, SystemsRuntime.Proc.self()) <> "/open-apis"
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, api_base)
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, api_base)
    SalixIM.Provider.Feishu.API.reset_token_cache()
    SalixIM.Provider.Lark.API.reset_token_cache()
    start_supervised!(SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    Repo.query!(
      "TRUNCATE lark_suite_triage_sources, lark_suite_triage_chats, lark_suite_triage_batches"
    )

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)

      for {key, value} <-
            Enum.zip([:feishu_api_base_url, :lark_api_base_url], Tuple.to_list(prev_api)) do
        if value,
          do: SystemsRuntime.put_env(:salix_im, key, value),
          else: SystemsRuntime.delete_env(:salix_im, key)
      end

      case prev_cmd_exec do
        nil -> SystemsRuntime.delete_env(:salix_im, :control_command_execution)
        value -> SystemsRuntime.put_env(:salix_im, :control_command_execution, value)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        role: "router",
        group_id: group_id
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        role: "worker",
        group_id: group_id
      })

    _group =
      SalixAgent.TestSupport.create_control_group!(group_id, %{
        "router_agent_id" => router["agent_id"],
        "billing_owner" => %{"salix_tenant_id" => tenant_id}
      })

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    connects =
      Map.new(~w(feishu lark), fn provider ->
        connect = %{
          "provider" => provider,
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "connect_id" => "con_#{provider}_#{suffix}",
          "app_id" => "cli_#{provider}_#{suffix}",
          "app_name" => "SelfBot",
          "app_secret" => "secret",
          "bot_open_id" => @bot,
          "events" => "socket",
          "status" => "connected",
          "created_at" => 1,
          "updated_at" => 1
        }

        {:ok, _created} =
          CasRecord.create(Keys.ctl_im_connect(group_id, connect["connect_id"]), connect)

        {:ok, _source} =
          TriageStore.upsert_source(%{
            tenant_id: tenant_id,
            provider: provider,
            connect_id: connect["connect_id"],
            group_id: group_id,
            router_agent_id: router["agent_id"],
            enabled: true
          })

        {:ok, _chat} =
          TriageStore.add_or_enable_chat(%{
            tenant_id: tenant_id,
            provider: provider,
            connect_id: connect["connect_id"],
            group_id: group_id,
            chat_id: @chat,
            chat_name: "Swarm Group"
          })

        {provider, connect}
      end)

    %{
      tenant_id: tenant_id,
      group_id: group_id,
      router_id: router["agent_id"],
      worker_id: worker["agent_id"],
      connects: connects
    }
  end

  defp self_mention,
    do: %{"key" => "@_user_1", "id" => %{"open_id" => @bot}, "name" => "SelfBot"}

  defp peer_mention,
    do: %{"key" => "@_user_2", "id" => %{"open_id" => @peer_bot}, "name" => "PeerBot"}

  defp all_mention,
    do: %{"key" => "@_all", "id" => %{"open_id" => "all"}, "name" => "所有人"}

  defp envelope(message_id, opts) do
    message =
      %{
        "message_id" => message_id,
        "chat_id" => Keyword.get(opts, :chat_id, @chat),
        "chat_type" => Keyword.get(opts, :chat_type, "group"),
        "message_type" => "text",
        "create_time" => "1795080000000",
        "content" => Jason.encode!(%{"text" => Keyword.get(opts, :text, "hello")}),
        "mentions" => Keyword.get(opts, :mentions, [])
      }
      |> then(&if(t = opts[:thread_id], do: Map.put(&1, "thread_id", t), else: &1))
      |> then(&if(r = opts[:root_id], do: Map.put(&1, "root_id", r), else: &1))
      |> then(&if(p = opts[:parent_id], do: Map.put(&1, "parent_id", p), else: &1))

    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => "ev_" <> message_id,
        "event_type" => "im.message.receive_v1",
        "tenant_key" => "tk_swarm",
        "app_id" => "cli_swarm"
      },
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => Keyword.get(opts, :sender_open_id, @human)},
          "sender_type" => Keyword.get(opts, :sender_type, "user")
        },
        "message" => message
      }
    }
  end

  defp deliver("feishu", connect, env), do: ProviderHTTP.handle_feishu_socket_event(connect, env)
  defp deliver("lark", connect, env), do: LarkInbound.handle_socket_event(connect, env)

  defp join_thread("feishu", connect, chat_id, thread_id),
    do: ProviderConnects.record_feishu_thread_participation(connect, chat_id, thread_id)

  defp join_thread("lark", connect, chat_id, thread_id),
    do: LarkThreads.join(connect, chat_id, thread_id)

  defp leave_thread("feishu", connect, chat_id, thread_id),
    do: ProviderConnects.leave_feishu_thread_participation(connect, chat_id, thread_id)

  defp leave_thread("lark", connect, chat_id, thread_id),
    do: LarkThreads.leave(connect, chat_id, thread_id)

  defp thread_status("feishu", connect, chat_id, thread_id),
    do: ProviderConnects.feishu_thread_participation_status(connect, chat_id, thread_id)

  defp thread_status("lark", connect, chat_id, thread_id),
    do: LarkThreads.status(connect, chat_id, thread_id)

  defp router_inputs(group_id, provider, connect, message_id) do
    {:ok, conversation} = RouterConversationInput.ensure(group_id)

    {:ok, messages} =
      Conversations.list_group_conversation_messages(
        group_id,
        conversation["conversation_id"],
        limit: 100
      )

    source_id = "im_provider:#{provider}:#{connect["connect_id"]}:#{message_id}"

    Enum.filter(messages, fn message ->
      get_in(message, ["agent_input", :trusted_origin, "source_message_id"]) == source_id
    end)
  end

  defp triage_message_ids do
    Repo.query!("SELECT message_ids FROM lark_suite_triage_batches ORDER BY inserted_at").rows
    |> List.flatten()
  end

  defp bind_thread!(provider, ctx, connect, chat_id, thread_id) do
    {conversation_id, _worker_id} =
      SalixIM.TestSupport.ProviderFixture.create_slack_task!(
        ctx.tenant_id,
        ctx.group_id,
        ctx.router_id,
        "Bound Task"
      )

    key =
      case provider do
        "feishu" ->
          Keys.ctl_im_feishu_thread_binding(
            ctx.group_id,
            connect["connect_id"],
            chat_id,
            thread_id
          )

        "lark" ->
          Keys.ctl_im_lark_thread_binding(ctx.group_id, connect["connect_id"], chat_id, thread_id)
      end

    {:ok, _binding} =
      CasRecord.create(key, %{
        "version" => 1,
        "binding_status" => "active",
        "provider" => provider,
        "group_id" => ctx.group_id,
        "connect_id" => connect["connect_id"],
        "chat_id" => chat_id,
        "thread_id" => thread_id,
        "reply_message_id" => "om_root",
        "conversation_id" => conversation_id,
        "created_at" => 1,
        "updated_at" => 1
      })

    conversation_id
  end

  for provider <- ~w(feishu lark) do
    @provider provider

    test "#{provider}: foreign-only mention is ignored in participating and task-bound threads without triage",
         ctx do
      connect = ctx.connects[@provider]
      participating_thread = "omt_part_#{@provider}"
      bound_thread = "omt_bound_#{@provider}"

      assert :ok = join_thread(@provider, connect, @chat, participating_thread)
      task_conv_id = bind_thread!(@provider, ctx, connect, @chat, bound_thread)

      # 1. Foreign-only mention in participating thread: ignored, no Router wake, no Triage.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_foreign_part",
                   thread_id: participating_thread,
                   text: "@_user_2 please check",
                   mentions: [peer_mention()]
                 )
               )

      assert router_inputs(ctx.group_id, @provider, connect, "om_foreign_part") == []
      refute "om_foreign_part" in triage_message_ids()

      # 2. Foreign-only mention in Task-bound thread: ignored, no Task append, no Router wake, no Triage.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_foreign_bound",
                   thread_id: bound_thread,
                   text: "@_user_2 handle this",
                   mentions: [peer_mention()]
                 )
               )

      assert router_inputs(ctx.group_id, @provider, connect, "om_foreign_bound") == []

      assert {:ok, task_messages_before} =
               Conversations.list_group_conversation_messages(ctx.group_id, task_conv_id,
                 limit: 20
               )

      refute Enum.any?(
               task_messages_before,
               &(&1["source_message_id"] ==
                   "im_provider:#{@provider}:#{connect["connect_id"]}:om_foreign_bound")
             )

      refute "om_foreign_bound" in triage_message_ids()

      # Sanity check: an unmentioned message in the same bound thread DOES reach the Task.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_bound_cont",
                   thread_id: bound_thread,
                   text: "task continuation"
                 )
               )

      assert {:ok, task_messages_after} =
               Conversations.list_group_conversation_messages(ctx.group_id, task_conv_id,
                 limit: 20
               )

      assert Enum.any?(
               task_messages_after,
               &(&1["source_message_id"] ==
                   "im_provider:#{@provider}:#{connect["connect_id"]}:om_bound_cont")
             )

      # 3. Unparticipated top-level message mentioning someone else still goes to Triage.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_top_other",
                   text: "@_user_2 帮看下线上报错",
                   mentions: [peer_mention()]
                 )
               )

      assert router_inputs(ctx.group_id, @provider, connect, "om_top_other") == []
      assert "om_top_other" in triage_message_ids()

      # 4. Mixed mention (@self + @peer) in participating thread wakes Router.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_mixed",
                   thread_id: participating_thread,
                   text: "@_user_1 @_user_2 sync together",
                   mentions: [self_mention(), peer_mention()]
                 )
               )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_mixed")

      # 5. Group broadcast (@_all) in participating thread wakes Router.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_all",
                   thread_id: participating_thread,
                   text: "@_all update",
                   mentions: [all_mention()]
                 )
               )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_all")

      # 6. Unmentioned human reply and unmentioned peer bot reply in participating thread wake Router.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_human_cont",
                   thread_id: participating_thread,
                   text: "more details"
                 )
               )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_human_cont")

      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_peer_cont",
                   thread_id: participating_thread,
                   sender_open_id: @peer_bot,
                   sender_type: "app",
                   text: "peer bot follow-up"
                 )
               )

      assert [peer_cont] = router_inputs(ctx.group_id, @provider, connect, "om_peer_cont")
      origin = get_in(peer_cont, ["agent_input", :trusted_origin])
      assert origin["source_actor_type"] == "provider_system"
      assert origin["provider_context"]["app_authored"] == true
    end

    test "#{provider}: leaving a thread blocks peer bots even with @self, while humans can still re-invoke",
         ctx do
      connect = ctx.connects[@provider]
      thread_id = "omt_left_#{@provider}"

      assert :ok = join_thread(@provider, connect, @chat, thread_id)
      assert :ok = leave_thread(@provider, connect, @chat, thread_id)
      assert thread_status(@provider, connect, @chat, thread_id) == :left

      # Peer bot @-mentioning self in a :left thread is ignored and does not trigger Triage.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_peer_pull_back",
                   thread_id: thread_id,
                   sender_open_id: @peer_bot,
                   sender_type: "app",
                   text: "@_user_1 come back",
                   mentions: [self_mention()]
                 )
               )

      assert router_inputs(ctx.group_id, @provider, connect, "om_peer_pull_back") == []
      refute "om_peer_pull_back" in triage_message_ids()

      # Human @-mentioning self in the same :left thread wakes Router normally.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_human_reinvoke",
                   thread_id: thread_id,
                   sender_open_id: @human,
                   sender_type: "user",
                   text: "@_user_1 please rejoin",
                   mentions: [self_mention()]
                 )
               )

      assert [human_input] = router_inputs(ctx.group_id, @provider, connect, "om_human_reinvoke")
      origin = get_in(human_input, ["agent_input", :trusted_origin])
      assert origin["source_actor_type"] == "provider_user"
      refute Map.has_key?(origin["provider_context"], "app_authored")

      # Re-joining clears the :left tombstone.
      assert :ok = join_thread(@provider, connect, @chat, thread_id)
      assert thread_status(@provider, connect, @chat, thread_id) in [:participating, :joined]
    end

    test "#{provider}: peer bot @self in an unleft group delivers as provider_system app_authored without command authority",
         ctx do
      connect = ctx.connects[@provider]

      assert {:ok, ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_peer_cmd",
                   sender_open_id: @peer_bot,
                   sender_type: "app",
                   text: "@_user_1 <salix-command>status</salix-command>",
                   mentions: [self_mention()]
                 )
               )

      refute ack["status"] == "command" or ack[:status] == "command"

      assert [input] = router_inputs(ctx.group_id, @provider, connect, "om_peer_cmd")
      origin = get_in(input, ["agent_input", :trusted_origin])
      assert origin["source_actor_type"] == "provider_system"
      assert origin["provider_context"]["app_authored"] == true
      refute Map.has_key?(origin, "principal_ref")
    end

    test "#{provider}: people of a group the bot created answer it without a mention, until it leaves",
         ctx do
      connect = ctx.connects[@provider]
      chat = "oc_created"

      assert {:ok, %{"chat_id" => ^chat}} =
               tool(@provider, ctx, connect, "create_chat", %{
                 "name" => "合同审阅",
                 "user_ids" => [@human, "ou_other"]
               })

      # The platform tells of the bot joining the group it made, with the bot
      # or nobody as the operator: that asks for no welcome.
      for {event_id, operator} <- [{"evt_self", @bot}, {"evt_blank", ""}] do
        _ = deliver(@provider, connect, bot_added(chat, event_id, operator))

        assert router_inputs(
                 ctx.group_id,
                 @provider,
                 connect,
                 "channel_joined:#{chat}:#{event_id}"
               ) == []
      end

      # Nor does an event that names no operator in a group not marked yet:
      # the bot's own join, or a creation whose answer is still on its way.
      _ = deliver(@provider, connect, bot_added("oc_racing_or_joined", "evt_nobody", nil))

      assert router_inputs(
               ctx.group_id,
               @provider,
               connect,
               "channel_joined:oc_racing_or_joined:evt_nobody"
             ) == []

      # A person who adds the bot to another group still asks for one.
      _ = deliver(@provider, connect, bot_added("oc_elsewhere", "evt_person", @human))

      assert [_welcome] =
               router_inputs(
                 ctx.group_id,
                 @provider,
                 connect,
                 "channel_joined:oc_elsewhere:evt_person"
               )

      # The first message, unasked, with a question card that says where it is.
      origin = %{
        "provider" => @provider,
        "source_actor_type" => "provider_user",
        "provider_context" => %{
          "connect_id" => connect["connect_id"],
          "chat_id" => chat,
          "chat_type" => "group",
          "message_thread_id" => "omt_source"
        }
      }

      assert {:ok, _sent} =
               tool(
                 @provider,
                 ctx,
                 connect,
                 "send_message",
                 %{
                   "chat_id" => chat,
                   "text" => "请确认合同审阅范围",
                   "question" => %{
                     "type" => "options",
                     "options" => [%{"label" => "全部条款"}, %{"label" => "仅付款条款"}]
                   }
                 },
                 origin
               )

      assert_received {:open_api, "POST", ["im", "v1", "messages"],
                       %{"receive_id" => ^chat, "msg_type" => "interactive", "content" => content}}

      assert %{"chat_type" => "group", "thread_id" => "omt_source"} = card_where(content)

      # A person's message without a mention reaches the Router.
      _ = deliver(@provider, connect, envelope("om_flat", chat_id: chat, text: "范围是全部条款"))
      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_flat")

      # One that mentions only another person does not, nor goes to triage.
      _ =
        deliver(
          @provider,
          connect,
          envelope("om_aside",
            chat_id: chat,
            text: "@_user_2 你看下",
            mentions: [peer_mention()]
          )
        )

      assert router_inputs(ctx.group_id, @provider, connect, "om_aside") == []
      refute "om_aside" in triage_message_ids()

      # Another bot's message there does not: two bots would answer each other.
      _ =
        deliver(
          @provider,
          connect,
          envelope("om_peer_flat",
            chat_id: chat,
            sender_open_id: @peer_bot,
            sender_type: "app",
            text: "收到"
          )
        )

      assert router_inputs(ctx.group_id, @provider, connect, "om_peer_flat") == []

      # A control command needs a mention: without one it is ordinary text.
      assert {:ok, _ack} =
               deliver(
                 @provider,
                 connect,
                 envelope("om_flat_cmd",
                   chat_id: chat,
                   text: "<salix-command>status</salix-command>"
                 )
               )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_flat_cmd")
      refute_received {:open_api, "POST", ["im", "v1", "messages", "om_flat_cmd", "reply"], _body}

      # The Router leaves the group's talk: it needs a mention again.
      assert {:ok, %{"status" => "left"}} =
               tool(@provider, ctx, connect, "leave_thread", %{
                 "chat_id" => chat,
                 "thread_id" => chat
               })

      _ = deliver(@provider, connect, envelope("om_after_leave", chat_id: chat, text: "还在吗"))
      assert router_inputs(ctx.group_id, @provider, connect, "om_after_leave") == []

      _ =
        deliver(
          @provider,
          connect,
          envelope("om_mention_back",
            chat_id: chat,
            text: "@_user_1 回来",
            mentions: [self_mention()]
          )
        )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_mention_back")
    end

    test "#{provider}: a message the bot sends into a group unasked is answered by a quote or a thread under it",
         ctx do
      connect = ctx.connects[@provider]
      sent = "om_sent_" <> @chat

      assert {:ok, _sent} =
               tool(@provider, ctx, connect, "send_message", %{
                 "chat_id" => @chat,
                 "text" => "周报已出"
               })

      # Other talk of the group still needs a mention.
      _ = deliver(@provider, connect, envelope("om_chatter", text: "午饭吃什么"))
      assert router_inputs(ctx.group_id, @provider, connect, "om_chatter") == []
      assert "om_chatter" in triage_message_ids()

      # A quote reply to the bot's message, without a mention.
      _ =
        deliver(
          @provider,
          connect,
          envelope("om_quote", text: "第三项不对", root_id: sent, parent_id: sent)
        )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_quote")

      # A thread opened under it: followed from its first message, and on its own.
      opened = "omt_opened_#{@provider}"

      _ =
        deliver(
          @provider,
          connect,
          envelope("om_thread_first", text: "展开说说", thread_id: opened, root_id: sent)
        )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_thread_first")
      assert thread_status(@provider, connect, @chat, opened) in [:participating, :joined]

      _ =
        deliver(
          @provider,
          connect,
          envelope("om_thread_next", text: "还有第五项", thread_id: opened, root_id: sent)
        )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_thread_next")

      # Leaving that thread stops it, though the message it hangs on is still followed.
      assert {:ok, %{"status" => "left"}} =
               tool(@provider, ctx, connect, "leave_thread", %{
                 "chat_id" => @chat,
                 "thread_id" => opened
               })

      _ =
        deliver(
          @provider,
          connect,
          envelope("om_thread_after", text: "好的", thread_id: opened, root_id: sent)
        )

      assert router_inputs(ctx.group_id, @provider, connect, "om_thread_after") == []
      assert thread_status(@provider, connect, @chat, sent) in [:participating, :joined]
    end

    test "#{provider}: in a topic group, the topic of the bot's message is followed", ctx do
      connect = ctx.connects[@provider]
      topic_chat = "oc_topic_#{@provider}"
      topic = "omt_" <> topic_chat

      assert {:ok, _sent} =
               tool(@provider, ctx, connect, "send_message", %{
                 "chat_id" => topic_chat,
                 "text" => "本周议题"
               })

      _ =
        deliver(
          @provider,
          connect,
          envelope("om_topic_reply",
            chat_id: topic_chat,
            text: "我来跟进",
            thread_id: topic,
            root_id: "om_sent_" <> topic_chat
          )
        )

      assert [_input] = router_inputs(ctx.group_id, @provider, connect, "om_topic_reply")

      # Another topic of the group is not.
      _ =
        deliver(
          @provider,
          connect,
          envelope("om_other_topic", chat_id: topic_chat, text: "别的事", thread_id: "omt_other")
        )

      assert router_inputs(ctx.group_id, @provider, connect, "om_other_topic") == []
    end
  end

  defp tool(provider, ctx, connect, op, params, origin \\ nil) do
    SalixIM.Provider.call_api(ctx.router_id, provider, "#{provider}.#{op}", %{
      "connect_id" => connect["connect_id"],
      "params" => params,
      "tool_context" => %{"trusted_origin" => origin}
    })
  end

  defp bot_added(chat_id, event_id, operator_open_id) do
    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.chat.member.bot.added_v1",
        "tenant_key" => "tk_swarm"
      },
      "event" => %{
        "chat_id" => chat_id,
        "operator_id" => if(operator_open_id, do: %{"open_id" => operator_open_id}, else: %{}),
        "name" => "Group",
        "external" => false
      }
    }
  end

  # Where the card's button says the card is: what a press is answered with.
  defp card_where(content) do
    content
    |> Jason.decode!()
    |> get_in(["body", "elements"])
    |> Enum.find(&(&1["tag"] == "form"))
    |> Map.fetch!("elements")
    |> Enum.find(&(&1["tag"] == "button"))
    |> get_in(["behaviors", Access.at(0), "value"])
  end
end
