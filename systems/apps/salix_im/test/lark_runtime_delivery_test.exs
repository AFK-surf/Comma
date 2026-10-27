defmodule SalixIM.LarkRuntimeDeliveryTest do
  @moduledoc """
  What the runtime sends to Lark by itself: the Task card of a Task a person
  asked for in Lark, and a Conversation message for a Lark chat. Lark is a
  recording stub of its OpenAPI; the Conversations, their participants and
  the Router are the real ones.
  """
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:lark_mirror_outbox, :feishu_mirror_outbox]
  use SystemsClock.Test, scope: ["Elixir.Salix"]

  alias SalixIM.{ConversationSeedInput, ConversationServer, Conversations, ProviderConnects}
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{Ids, Keys}

  import SalixIM.TestSupport.ProviderFixture,
    only: [create_control_agent: 2, create_slack_task!: 4, call: 5]

  @token "lark-verification-token"

  defmodule API do
    @moduledoc """
    A recording stub of the Lark OpenAPI. A test says which chat a message is
    in and, when it needs to, what Lark answers to a reply.
    """
    use Elixir.Agent
    import Plug.Conn
    alias SystemsRuntime.Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{requests: [], messages: %{}, reply: nil} end, name: __MODULE__)

    @doc "The chat each message is in: `%{message_id => chat_id}`."
    def messages(messages), do: Agent.update(__MODULE__, &%{&1 | messages: messages})

    @doc "What Lark answers to a reply: `fun.(request)` gives `{status, body}`."
    def reply_with(fun), do: Agent.update(__MODULE__, &%{&1 | reply: fun})

    @doc "The requests of one kind, oldest first."
    def requests(kind) do
      __MODULE__
      |> Agent.get(& &1.requests)
      |> Enum.reverse()
      |> Enum.filter(&(&1.kind == kind))
    end

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)
      ["open-apis" | path] = conn.path_info

      params =
        case Jason.decode(raw) do
          {:ok, %{} = body} -> body
          _not_json -> %{}
        end

      {kind, message_id} = kind(conn.method, path)
      request = %{kind: kind, message_id: message_id, params: params, raw: raw}
      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})

      {status, body} = answer(kind, request, Agent.get(__MODULE__, & &1))

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp kind("POST", ["auth", "v3", "tenant_access_token", "internal"]), do: {:token, nil}
    defp kind("GET", ["bot", "v3", "info"]), do: {:bot, nil}
    defp kind("GET", ["im", "v1", "messages", id]), do: {:get_message, id}
    defp kind("POST", ["im", "v1", "messages", id, "reply"]), do: {:reply, id}
    defp kind("PATCH", ["im", "v1", "messages", id]), do: {:patch_card, id}
    defp kind("POST", ["im", "v1", "messages"]), do: {:message, nil}
    defp kind("POST", ["im", "v1", "files"]), do: {:file_upload, nil}
    defp kind(_method, _path), do: {:other, nil}

    defp answer(:token, _request, _state),
      do: {200, %{"code" => 0, "tenant_access_token" => "t-lark", "expire" => 7200}}

    defp answer(:bot, _request, _state),
      do: {200, %{"code" => 0, "bot" => %{"open_id" => "ou_bot", "app_name" => "Bridge"}}}

    defp answer(:get_message, %{message_id: id}, state) do
      case state.messages do
        %{^id => chat_id} ->
          {200, ok(%{"items" => [%{"message_id" => id, "chat_id" => chat_id}]})}

        _unknown ->
          {400, %{"code" => 230_001, "msg" => "message not found"}}
      end
    end

    defp answer(:reply, request, %{reply: reply}) when is_function(reply, 1), do: reply.(request)

    defp answer(:reply, %{message_id: id, params: params}, state) do
      sent = %{
        "message_id" => "om_reply_" <> id,
        "chat_id" => Map.get(state.messages, id, "oc_task"),
        "msg_type" => params["msg_type"]
      }

      {200,
       ok(if(params["reply_in_thread"], do: Map.put(sent, "thread_id", "omt_" <> id), else: sent))}
    end

    defp answer(:message, %{params: params}, _state),
      do: {200, ok(%{"message_id" => "om_sent", "chat_id" => params["receive_id"]})}

    defp answer(:file_upload, _request, _state), do: {200, ok(%{"file_key" => "file-key-1"})}
    defp answer(:patch_card, _request, _state), do: {200, ok(%{})}
    defp answer(:other, _request, _state), do: {404, %{"code" => 404, "msg" => "not found"}}

    defp ok(data), do: %{"code" => 0, "msg" => "ok", "data" => data}
  end

  defmodule RouterLLM do
    @moduledoc """
    The Router's model: it creates one Task for the message that holds the
    marker, and publishes no card by itself.
    """
    @behaviour SalixAgent.LLM

    def configure(config), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :config}, config)
    def clear, do: SystemsRuntime.PersistentTerm.erase({__MODULE__, :config})

    @impl true
    def complete(messages, _tools) do
      config = SystemsRuntime.PersistentTerm.get({__MODULE__, :config})
      contents = Enum.map(messages, &to_string(Map.get(&1, :content) || &1["content"] || ""))

      cond do
        not Enum.any?(contents, &String.contains?(&1, config.marker)) ->
          {:final, "Worker acknowledged the Task."}

        Enum.any?(messages, &created_task?/1) ->
          {:final, "Task created."}

        true ->
          {:assistant, "",
           [
             %{
               id: "router-task-create",
               name: "call",
               args: %{
                 "tool" => "im_api.internal.task.create",
                 "params" => %{
                   "runs_on" => %{"kind" => "default"},
                   "connect_id" => "internal",
                   "agent_id" => config.worker_id,
                   "content" => "Prepare a short repository health report.",
                   "title" => "Repository health report"
                 }
               }
             }
           ]}
      end
    end

    @impl true
    def complete_stream(messages, tools, _on_delta), do: complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, _on_delta, _opts), do: complete(messages, tools)

    # The result of the create call is in the Session: as a tool row, or as
    # the runtime message of a call that completed in the background.
    defp created_task?(message) do
      role = Map.get(message, :role) || message["role"]

      ids = [
        Map.get(message, :tool_call_id) || message["tool_call_id"],
        Map.get(message, :source_tool_call_id) || message["source_tool_call_id"]
      ]

      role in ["tool", "runtime"] and "router-task-create" in ids
    end
  end

  setup do
    {:ok, base} = SalixIM.TestSupport.ProviderFixture.native_setup()
    previous = SystemsRuntime.get_env(:salix_im, :lark_api_base_url)

    start_supervised!(API)

    SystemsRuntime.put_env(
      :salix_im,
      :lark_api_base_url,
      BanditServer.serve!(API) <> "/open-apis"
    )

    SalixIM.Provider.Lark.API.reset_token_cache()
    on_exit(fn -> restore(:salix_im, :lark_api_base_url, previous) end)

    app_id = "cli_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, connect} =
      ProviderConnects.create_lark_im_connect(base[:tenant], base[:group_id], %{
        "app_id" => app_id,
        "app_secret" => "lark-app-secret",
        "verification_token" => @token
      })

    %{
      tenant: base[:tenant],
      group_id: base[:group_id],
      router_id: base[:agent_id],
      app_id: app_id,
      connect_id: connect["connect_id"]
    }
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp eventually(fun), do: settle_until(fun)

  defp card_participant!(group_id, conversation_id) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id,
               limit: 100
             )

    assert participant =
             Enum.find(participants, fn participant ->
               participant["provider"] == "lark" and
                 get_in(participant, ["payload", "projection"]) == "lark_task_card"
             end)

    participant
  end

  defp card_message_id(group_id, conversation_id),
    do: card_participant!(group_id, conversation_id)["payload"]["card_message_id"]

  defp card(request), do: Jason.decode!(request.params["content"])

  defp card_status(card),
    do: get_in(card, ["header", "text_tag_list", Access.at(0), "text", "content"])

  defp card_text(card), do: Enum.map(get_in(card, ["body", "elements"]) || [], & &1["content"])

  # The `uuid` `lark.send_message` gives Lark for one operation and target.
  defp send_uuid(api, target, operation_ref) do
    digest =
      :crypto.hash(:sha256, Enum.join([api, target, operation_ref], "\0"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    "bft_" <> digest
  end

  defp seed_conversation!(group_id, agent_id) do
    now = SystemsClock.system_time(:millisecond)
    conversation_id = Ids.new_conversation_id()

    participant = fn attrs ->
      Map.merge(attrs, %{
        "state" => "active",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"},
        "created_at" => now,
        "updated_at" => now
      })
    end

    assert {:ok, seed} =
             ConversationSeedInput.prepare(group_id, conversation_id, %{
               "conversation" => %{
                 "kind" => "user_chat",
                 "title" => "Conversation",
                 "status" => "active",
                 "activity_status" => "idle",
                 "participants" => [
                   participant.(%{"actor_type" => "user", "user_id" => "current"}),
                   participant.(%{
                     "actor_type" => "agent",
                     "agent_id" => agent_id,
                     "role_label" => "agent"
                   })
                 ],
                 "created_at" => now,
                 "updated_at" => now
               },
               "messages" => []
             })

    assert {:ok, _seeded} =
             ConversationServer.seed_group_conversation_transcript(
               group_id,
               conversation_id,
               seed
             )

    conversation_id
  end

  # One pending delivery of a Conversation message to a Lark chat, as the
  # Conversation owner writes it. The participant's owner is held until
  # `deliver!/4`, so the test sees the one delivery it asked for.
  defp put_delivery!(ctx, conversation_id, payload, attrs) do
    group_id = ctx.group_id

    assert {:ok, participant} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "provider",
                 "provider" => "lark",
                 "target_key" => "lark-" <> Ids.new_participant_id(),
                 "role_label" => "delivery_target",
                 "payload" => payload,
                 "state" => "active",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               }
             )

    participant_id = participant["participant_id"]

    {:ok, sender} =
      ConversationServer.ensure_group_conversation_user_participant(group_id, conversation_id, %{
        "user_id" => "delivery-fixture"
      })

    owner = participant_owner(group_id, conversation_id, participant_id)
    :ok = SystemsRuntime.Server.suspend(owner, :infinity)

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(owner), do: SystemsRuntime.Server.resume(owner, :infinity)
    end)

    {:ok, message} =
      ConversationServer.append_group_conversation_message(group_id, conversation_id, %{
        "participant_id" => sender["participant_id"],
        "actor_type" => "user",
        "user_id" => "delivery-fixture",
        "content" => attrs["message_content"],
        "delivery_filter" => %{"participant_ids" => [participant_id]}
      })

    message_id = message["message_id"]
    delivery_id = Enum.join([group_id, conversation_id, message_id, participant_id], ":")
    now = SystemsClock.system_time(:millisecond)

    delivery =
      Map.merge(attrs, %{
        "delivery_id" => delivery_id,
        "status" => "pending",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "message_seq" => message["seq"],
        "participant_id" => participant_id,
        "participant_actor_type" => "provider",
        "participant_provider" => "lark",
        "participant_payload" => payload,
        "message_created_at" => now,
        "created_at" => now,
        "updated_at" => now
      })

    key =
      Keys.ctl_group_conversation_participant_delivery_state(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      )

    assert {:ok, _} = SalixStore.S3.put(key, Jason.encode!(delivery), if_none_match: "*")
    {participant_id, message_id}
  end

  defp participant_owner(group_id, conversation_id, participant_id) do
    [{owner, _}] =
      SystemsRuntime.Registry.lookup(
        SalixIM.ConversationRegistry,
        SalixIM.ConversationParticipantActor.key(group_id, conversation_id, participant_id)
      )

    owner
  end

  defp delivery(group_id, conversation_id, participant_id, message_id) do
    case Conversations.group_conversation_delivery_status(group_id, conversation_id,
           participant_id: participant_id,
           message_id: message_id,
           limit: 1
         ) do
      {:ok, %{"deliveries" => [delivery]}} -> delivery
      _none -> nil
    end
  end

  # Lets the participant's owner run the delivery, and waits for its status.
  defp deliver!(ctx, conversation_id, {participant_id, message_id}, status) do
    group_id = ctx.group_id
    owner = participant_owner(group_id, conversation_id, participant_id)
    SystemsRuntime.Server.resume(owner, :infinity)
    assert :ok = ConversationServer.wake_participant(group_id, conversation_id, participant_id)

    assert eventually(fn ->
             match?(
               %{"status" => ^status},
               delivery(group_id, conversation_id, participant_id, message_id)
             )
           end)

    delivery(group_id, conversation_id, participant_id, message_id)
  end

  defp seed_agent_file!(agent_id, path, body) do
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent_id, path, body)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "lark-delivery-test-seed:#{SystemsRuntime.Proc.unique_integer([:positive])}",
               %{},
               [event]
             )

    {:ok, entry} = SalixAgent.AgentWorkspace.entry(agent_id, path)
    entry["ref"]
  end

  describe "the Task card" do
    test "the Router's card answers the source once and follows the Task", ctx do
      {conversation_id, worker_id} =
        create_slack_task!(ctx.tenant, ctx.group_id, ctx.router_id, "Build the launch report")

      API.messages(%{"om_source" => "oc_task"})

      params = %{
        "conversation_id" => conversation_id,
        "chat_id" => "oc_task",
        "message_id" => "om_source"
      }

      assert {:ok, %{"delivery_status" => "queued", "task_id" => task_id}} =
               call(ctx.router_id, "lark", "lark.post_task_card", ctx.connect_id, params)

      assert eventually(fn -> length(API.requests(:reply)) == 1 end)
      [reply] = API.requests(:reply)
      initial = card(reply)

      assert reply.message_id == "om_source"
      assert reply.params["msg_type"] == "interactive"
      # In a group the card goes into the thread of the source message.
      assert reply.params["reply_in_thread"] == true
      assert "ctc_" <> _ = reply.params["uuid"]
      assert initial["config"]["update_multi"] == true
      assert get_in(initial, ["header", "title", "content"]) == "Build the launch report"
      assert card_status(initial) == "Work in progress"

      assert eventually(fn ->
               card_message_id(ctx.group_id, conversation_id) == "om_reply_om_source"
             end)

      # Publishing again finds the card: there is one per Task and source.
      assert {:ok, %{"delivery_status" => "exists", "task_id" => ^task_id}} =
               call(ctx.router_id, "lark", "lark.post_task_card", ctx.connect_id, params)

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 ctx.group_id,
                 conversation_id,
                 worker_id,
                 %{
                   "content" => "Drafted **the data** section.",
                   "client_request_id" => "lark-task-card-progress"
                 }
               )

      # The Worker's progress is written to the same card.
      assert eventually(fn ->
               case List.last(API.requests(:patch_card)) do
                 %{message_id: "om_reply_om_source"} = patch ->
                   List.last(card_text(card(patch))) == "Drafted **the data** section."

                 _none ->
                   false
               end
             end)

      assert {:ok, %{"status" => "ready_for_review"}} =
               ConversationServer.update_group_conversation(ctx.group_id, conversation_id, %{
                 "status" => "ready_for_review"
               })

      assert eventually(fn ->
               case List.last(API.requests(:patch_card)) do
                 %{} = patch ->
                   card_status(card(patch)) == "Ready for review" and
                     get_in(card(patch), ["header", "template"]) == "green"

                 _none ->
                   false
               end
             end)

      assert length(API.requests(:reply)) == 1
      assert Enum.all?(API.requests(:patch_card), &(&1.message_id == "om_reply_om_source"))

      # The card is the bot's answer: its thread is one the bot answers in.
      {:ok, connect} =
        ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect_id, "lark")

      assert SalixIM.LarkThreads.joined?(connect, "oc_task", "omt_om_source")
      refute SalixIM.LarkThreads.joined?(connect, "oc_task", "omt_other")
    end

    test "a card in a private chat opens no thread", ctx do
      {conversation_id, _worker_id} =
        create_slack_task!(ctx.tenant, ctx.group_id, ctx.router_id, "Answer in private")

      API.messages(%{"om_dm" => "oc_private"})

      assert {:ok, %{"delivery_status" => "queued"}} =
               call(ctx.router_id, "lark", "lark.post_task_card", ctx.connect_id, %{
                 "conversation_id" => conversation_id,
                 "chat_id" => "oc_private",
                 "message_id" => "om_dm",
                 "chat_type" => "p2p"
               })

      assert eventually(fn -> length(API.requests(:reply)) == 1 end)

      assert [%{message_id: "om_dm", params: %{"reply_in_thread" => false}}] =
               API.requests(:reply)

      # A private chat has no thread to mark.
      {:ok, connect} =
        ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect_id, "lark")

      refute SalixIM.LarkThreads.joined?(connect, "oc_private", "omt_om_dm")
    end

    test "a post with an unknown outcome is sent again with its uuid, and posts one card", ctx do
      {conversation_id, worker_id} =
        create_slack_task!(ctx.tenant, ctx.group_id, ctx.router_id, "Settle an unknown post")

      API.messages(%{"om_source" => "oc_task"})
      {:ok, replies} = SystemsRuntime.Agent.start_link(fn -> 0 end)

      API.reply_with(fn _request ->
        case SystemsRuntime.Agent.get_and_update(replies, &{&1 + 1, &1 + 1}) do
          1 ->
            {503, %{"message" => "upstream timeout"}}

          _later ->
            {200,
             %{
               "code" => 0,
               "msg" => "ok",
               "data" => %{"message_id" => "om_card", "chat_id" => "oc_task"}
             }}
        end
      end)

      assert {:ok, %{"delivery_status" => "queued"}} =
               call(ctx.router_id, "lark", "lark.post_task_card", ctx.connect_id, %{
                 "conversation_id" => conversation_id,
                 "chat_id" => "oc_task",
                 "message_id" => "om_source"
               })

      assert eventually(fn -> card_message_id(ctx.group_id, conversation_id) == "om_card" end)

      # Lark sends one message per uuid, so the same request cannot post twice.
      [first, again] = API.requests(:reply)
      assert first.params["uuid"] == again.params["uuid"]

      assert {:ok, %{"inserted" => true}} =
               ConversationServer.append_group_conversation_agent_message(
                 ctx.group_id,
                 conversation_id,
                 worker_id,
                 %{"content" => "Progress after the repeat.", "client_request_id" => "repeated"}
               )

      assert eventually(fn ->
               Enum.any?(API.requests(:patch_card), fn patch ->
                 patch.message_id == "om_card" and
                   List.last(card_text(card(patch))) == "Progress after the repeat."
               end)
             end)

      assert length(API.requests(:reply)) == 2
    end

    test "a card is refused for a message of another chat, and for anyone but the Router",
         ctx do
      {conversation_id, worker_id} =
        create_slack_task!(ctx.tenant, ctx.group_id, ctx.router_id, "Reject a foreign source")

      API.messages(%{"om_elsewhere" => "oc_private", "om_source" => "oc_public"})

      assert {:error, "message_id does not belong to chat_id"} =
               call(ctx.router_id, "lark", "lark.post_task_card", ctx.connect_id, %{
                 "conversation_id" => conversation_id,
                 "chat_id" => "oc_public",
                 "message_id" => "om_elsewhere"
               })

      assert {:error, "conversation_id, chat_id and message_id are required"} =
               call(ctx.router_id, "lark", "lark.post_task_card", ctx.connect_id, %{
                 "conversation_id" => conversation_id
               })

      # The Worker of the Task has no Lark connect to publish with.
      assert {:error, _refused} =
               call(worker_id, "lark", "lark.post_task_card", ctx.connect_id, %{
                 "conversation_id" => conversation_id,
                 "chat_id" => "oc_public",
                 "message_id" => "om_source"
               })

      assert {:ok, %{"participants" => participants}} =
               Conversations.list_group_conversation_participants(ctx.group_id, conversation_id)

      refute Enum.any?(participants, &(&1["provider"] == "lark"))
      assert API.requests(:reply) == []
    end

    test "a Task a person asked for in Lark gets its card without the Router asking", ctx do
      previous = %{
        task: SystemsRuntime.get_env(:salix_im, :task_create_mod),
        provider: SystemsRuntime.get_env(:salix_agent, :im_provider_mod),
        llm: SystemsRuntime.get_env(:salix_agent, :llm)
      }

      on_exit(fn ->
        RouterLLM.clear()
        restore(:salix_im, :task_create_mod, previous.task)
        restore(:salix_agent, :im_provider_mod, previous.provider)
        restore(:salix_agent, :llm, previous.llm)
      end)

      {:ok, worker} =
        create_control_agent(
          %{"name" => "Lark card worker", "group_id" => ctx.group_id, "role" => "worker"},
          ctx.tenant
        )

      marker = "LARK_TASK_CARD_#{SystemsRuntime.Proc.unique_integer([:positive])}"
      RouterLLM.configure(%{marker: marker, worker_id: worker["agent_id"]})
      SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
      SystemsRuntime.put_env(:salix_agent, :llm, RouterLLM)

      # The request is a message of a thread: the card answers the root of it.
      API.messages(%{"om_root" => "oc_card", "om_request" => "oc_card"})

      envelope = %{
        "schema" => "2.0",
        "header" => %{
          "event_id" => "evt_request",
          "event_type" => "im.message.receive_v1",
          "token" => @token,
          "tenant_key" => "tenant_key_1"
        },
        "event" => %{
          "sender" => %{"sender_id" => %{"open_id" => "ou_requester"}, "sender_type" => "user"},
          "message" => %{
            "message_id" => "om_request",
            "root_id" => "om_root",
            "chat_id" => "oc_card",
            "chat_type" => "group",
            "message_type" => "text",
            "mentions" => [
              %{"key" => "@_user_1", "id" => %{"open_id" => "ou_bot"}, "name" => "Bridge"}
            ],
            "content" => Jason.encode!(%{"text" => "@_user_1 delegate #{marker}"})
          }
        }
      }

      assert {:ok, %{"ok" => true, "status" => "queued"}} =
               SalixIM.ProviderHTTP.handle_lark_request(
                 ctx.app_id,
                 envelope,
                 [],
                 Jason.encode!(envelope)
               )

      assert eventually(fn ->
               Enum.any?(API.requests(:reply), &(&1.params["msg_type"] == "interactive"))
             end)

      assert [reply] =
               Enum.filter(API.requests(:reply), &(&1.params["msg_type"] == "interactive"))

      assert reply.message_id == "om_root"
      assert reply.params["reply_in_thread"] == true
      assert get_in(card(reply), ["header", "title", "content"]) == "Repository health report"

      assert {:ok, %{"data" => conversations}} =
               Conversations.list_group_conversations(ctx.group_id, limit: 100)

      assert [task] = Enum.filter(conversations, &(&1["kind"] == "agent_task"))
      assert task["created_by_agent_id"] == ctx.router_id

      assert eventually(fn ->
               card_message_id(ctx.group_id, task["conversation_id"]) == "om_reply_om_root"
             end)

      # The card was the bot's only answer. The person goes on under it and
      # does not mention the bot: the message is for the Router. A message of
      # another thread of the chat, without a mention, is not.
      follow_up = fn message_id, thread_id ->
        envelope
        |> put_in(["header", "event_id"], "evt_" <> message_id)
        |> update_in(["event", "message"], fn message ->
          message
          |> Map.merge(%{"message_id" => message_id, "thread_id" => thread_id})
          |> Map.put("mentions", [])
          |> Map.put("content", Jason.encode!(%{"text" => "and the dependencies?"}))
        end)
      end

      in_card_thread = follow_up.("om_under_card", "omt_om_root")

      assert {:ok, %{"ok" => true, "status" => "queued"}} =
               SalixIM.ProviderHTTP.handle_lark_request(
                 ctx.app_id,
                 in_card_thread,
                 [],
                 Jason.encode!(in_card_thread)
               )

      elsewhere = follow_up.("om_elsewhere", "omt_another")

      assert {:ok, answer} =
               SalixIM.ProviderHTTP.handle_lark_request(
                 ctx.app_id,
                 elsewhere,
                 [],
                 Jason.encode!(elsewhere)
               )

      refute Map.has_key?(answer, "status")
    end
  end

  describe "a Conversation message for a Lark chat" do
    test "the text answers the root message, with the uuid of its delivery", ctx do
      conversation_id = seed_conversation!(ctx.group_id, ctx.router_id)
      API.messages(%{"om_root" => "oc_meeting"})

      payload = %{
        "connect_id" => ctx.connect_id,
        "chat_id" => "oc_meeting",
        "root_message_id" => "om_root",
        "mentions" => %{"mode" => "all", "users" => []}
      }

      target =
        put_delivery!(ctx, conversation_id, payload, %{
          "operation_ref" => "calendar-notify-1",
          "message_content" => [%{"type" => "text", "text" => "Meeting starts now"}],
          # The mentions of this message replace those of the participant.
          "message_metadata" => %{
            "delivery_mentions" => %{
              "mode" => "users",
              "users" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
            }
          }
        })

      delivered = deliver!(ctx, conversation_id, target, "delivered")

      assert %{"text" => %{"message" => %{"message_id" => "om_reply_om_root"}}, "files" => []} =
               delivered["delivery"]["delivery_result"]

      assert [reply] = API.requests(:reply)
      assert reply.message_id == "om_root"
      assert reply.params["msg_type"] == "post"
      assert reply.params["reply_in_thread"] == true

      assert reply.params["uuid"] ==
               send_uuid("lark.send_message", "om_root", "calendar-notify-1")

      assert reply.params["content"] =~ ~s("user_id":"ou_alice")
      refute reply.params["content"] =~ ~s("user_id":"all")

      # The thread is now one the bot answered in, as after a send of the Agent.
      {:ok, connect} =
        ProviderConnects.get_active_connect_by_id(ctx.group_id, ctx.connect_id, "lark")

      assert SalixIM.LarkThreads.joined?(connect, "oc_meeting", "omt_om_root")
    end

    test "without a message to answer the text is a new message of the chat", ctx do
      conversation_id = seed_conversation!(ctx.group_id, ctx.router_id)
      payload = %{"connect_id" => ctx.connect_id, "chat_id" => "oc_notice"}

      target =
        put_delivery!(ctx, conversation_id, payload, %{
          "operation_ref" => "notice-1",
          "message_content" => [%{"type" => "text", "text" => "The report is ready"}]
        })

      deliver!(ctx, conversation_id, target, "delivered")

      assert [%{params: %{"receive_id" => "oc_notice", "uuid" => uuid}}] = API.requests(:message)
      assert uuid == send_uuid("lark.send_message", "oc_notice", "notice-1")
      assert API.requests(:reply) == []
    end

    test "a send with an unknown outcome is unknown, and is not sent again", ctx do
      conversation_id = seed_conversation!(ctx.group_id, ctx.router_id)
      API.messages(%{"om_root" => "oc_unknown"})
      API.reply_with(fn _request -> {503, %{"message" => "upstream timeout"}} end)

      payload = %{
        "connect_id" => ctx.connect_id,
        "chat_id" => "oc_unknown",
        "root_message_id" => "om_root"
      }

      {participant_id, _message_id} =
        target =
        put_delivery!(ctx, conversation_id, payload, %{
          "operation_ref" => "calendar-notify-unknown",
          "message_content" => [%{"type" => "text", "text" => "Meeting starts now"}]
        })

      unknown = deliver!(ctx, conversation_id, target, "unknown")
      assert unknown["delivery"]["last_error"] =~ "write outcome unknown"
      assert length(API.requests(:reply)) == 1

      assert :ok =
               ConversationServer.wake_participant(ctx.group_id, conversation_id, participant_id)

      assert length(API.requests(:reply)) == 1
    end

    test "a file goes out as its own message, from the bytes that were queued", ctx do
      conversation_id = seed_conversation!(ctx.group_id, ctx.router_id)
      path = "/attachments/transcript.txt"
      blob_ref = seed_agent_file!(ctx.router_id, path, "MEETING-TRANSCRIPT")
      seed_agent_file!(ctx.router_id, path, "CHANGED-AFTER-QUEUE")
      API.messages(%{"om_root" => "oc_meeting"})

      payload = %{
        "connect_id" => ctx.connect_id,
        "chat_id" => "oc_meeting",
        "root_message_id" => "om_root"
      }

      file = %{"type" => "file", "path" => path, "title" => "transcript.txt"}

      target =
        put_delivery!(ctx, conversation_id, payload, %{
          "operation_ref" => "meeting-transcript",
          "source_agent_id" => ctx.router_id,
          "message_content" => [Map.put(file, "blob_ref", blob_ref)]
        })

      delivered = deliver!(ctx, conversation_id, target, "delivered")

      # No placeholder text goes with the file.
      assert %{"text" => nil, "files" => [%{"file_message" => %{}}]} =
               delivered["delivery"]["delivery_result"]

      assert [upload] = API.requests(:file_upload)
      assert upload.raw =~ "MEETING-TRANSCRIPT"
      refute upload.raw =~ "CHANGED-AFTER-QUEUE"

      assert [reply] = API.requests(:reply)
      assert reply.message_id == "om_root"
      assert reply.params["msg_type"] == "file"
      assert Jason.decode!(reply.params["content"]) == %{"file_key" => "file-key-1"}

      assert reply.params["uuid"] ==
               send_uuid("lark.send_message.file", "om_root", "meeting-transcript:file:0")

      # Text and a file in one message are refused before anything is sent.
      mixed =
        put_delivery!(ctx, conversation_id, payload, %{
          "operation_ref" => "meeting-mixed",
          "source_agent_id" => ctx.router_id,
          "message_content" => [
            %{"type" => "text", "text" => "The transcript"},
            Map.put(file, "blob_ref", blob_ref)
          ]
        })

      deliver!(ctx, conversation_id, mixed, "failed")
      assert length(API.requests(:reply)) == 1
    end
  end
end
