defmodule SalixIM.PrivateChatStatusTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.Salix"]
  alias SalixIM.{PrivateChatStatus, PrivateChatStatusActor, TelegramStatusTransport}
  alias SalixStore.{CasRecord, Keys}

  defmodule Runtime do
    use Agent
    @behaviour SalixIM.Ports.SessionActivity
    @behaviour SalixIM.Ports.AgentDelivery
    @behaviour SalixIM.PrivateChatStatusPlacement

    def start_link(parent),
      do:
        Agent.start_link(
          fn ->
            %{
              parent: parent,
              activity: {:ok, %{"state" => "stopped"}},
              subscribers: MapSet.new(),
              owner?: true
            }
          end,
          name: __MODULE__
        )

    def get(_agent, _session), do: Agent.get(__MODULE__, & &1.activity)

    def put(activity) do
      Agent.update(__MODULE__, &Map.put(&1, :activity, activity))

      for {pid, a, s} <- Agent.get(__MODULE__, & &1.subscribers),
          do: SystemsRuntime.Proc.send(pid, {:session_activity_updated, a, s})
    end

    def subscribe(a, s) do
      pid = SystemsRuntime.Proc.self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscribers, fn set -> MapSet.put(set, {pid, a, s}) end)
      )
    end

    def unsubscribe(a, s) do
      pid = SystemsRuntime.Proc.self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscribers, fn set -> MapSet.delete(set, {pid, a, s}) end)
      )
    end

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      SystemsRuntime.Proc.send(
        Agent.get(__MODULE__, & &1.parent),
        {:delivered, agent, payload, opts}
      )

      put(
        {:ok,
         %{
           "state" => "active",
           "status" => "is thinking...",
           "_active_source_message_ids" => [opts[:source_message_id]]
         }}
      )

      {:ok, :queued}
    end

    def get_session(_, _, _), do: {:error, :not_supported}
    def get_session_messages(_, _), do: {:error, :not_supported}
    def ensure_started(a, c, m), do: PrivateChatStatus.ensure_local(a, c, m)
    def local_owner?(_), do: Agent.get(__MODULE__, & &1.owner?)
    def lose_owner, do: Agent.update(__MODULE__, &Map.put(&1, :owner?, false))
  end

  defmodule API do
    use Agent
    import Plug.Conn

    def start_link(parent),
      do: Agent.start_link(fn -> %{parent: parent, responses: %{}} end, name: __MODULE__)

    def respond(method, code),
      do: Agent.update(__MODULE__, &put_in(&1, [:responses, method], code))

    def init(opts), do: opts

    def call(conn, _) do
      {:ok, raw, conn} = read_body(conn)
      method = List.last(conn.path_info)
      {parent, code} = Agent.get(__MODULE__, &{&1.parent, Map.get(&1.responses, method, 200)})
      SystemsRuntime.Proc.send(parent, {:api, method, Jason.decode!(raw)})

      body =
        if code == 200,
          do: %{"ok" => true, "result" => true},
          else: %{
            "ok" => false,
            "error_code" => code,
            "description" => "private-error",
            "parameters" => %{"retry_after" => 1}
          }

      body =
        cond do
          method == "getconfig" and code == 200 -> %{"ret" => 0, "typing_ticket" => "wx-ticket"}
          method == "sendtyping" and code == 200 -> %{"ret" => 0}
          true -> body
        end

      type =
        if method in ["getconfig", "sendtyping"],
          do: "application/octet-stream",
          else: "application/json"

      conn |> put_resp_content_type(type) |> send_resp(code, Jason.encode!(body))
    end
  end

  defmodule SignalAccount do
    @moduledoc false

    def send_typing(account_id, peer, action) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:salix_im, :signal_test_pid),
        {:signal_typing, account_id, peer, action}
      )

      {:ok, %{"timestamp" => 1}}
    end
  end

  setup context do
    SalixStore.S3.Fake.reset()
    start_supervised!({Runtime, SystemsRuntime.Proc.self()})
    start_supervised!({API, SystemsRuntime.Proc.self()})
    start_supervised!({Registry, keys: :unique, name: SalixIM.PrivateChatStatusRegistry})

    start_supervised!(
      {DynamicSupervisor, name: SalixIM.PrivateChatStatusFleetSup, strategy: :one_for_one}
    )

    start_supervised!(
      {SystemsRuntime.TaskSupervisor, name: SalixIM.PrivateChatStatusTaskSupervisor},
      id: SalixIM.PrivateChatStatusTaskSupervisor
    )

    port = SalixIM.TestSupport.BanditServer.start!(fn port -> {Bandit, plug: API, port: port} end)

    env = %{
      private_chat_status: true,
      telegram_api_base_url: "http://127.0.0.1:#{port}",
      wechat_api_base_url: "http://127.0.0.1:#{port}",
      session_activity_mod: Runtime,
      agent_delivery_mod: Runtime,
      private_chat_status_placement: Runtime,
      signal_account_mod: SignalAccount,
      signal_test_pid: SystemsRuntime.Proc.self(),
      imessage_photon: [
        enabled: true,
        project_id: "pho_prj_status",
        api_key: "pho_sk_status",
        webhook_secret: "whsec_c3RhdHVz",
        base_url: "http://127.0.0.1:#{port}"
      ]
    }

    previous = Map.new(env, fn {k, _} -> {k, SystemsRuntime.get_env(:salix_im, k)} end)
    Enum.each(env, fn {k, v} -> SystemsRuntime.put_env(:salix_im, k, v) end)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if is_nil(v),
          do: SystemsRuntime.delete_env(:salix_im, k),
          else: SystemsRuntime.put_env(:salix_im, k, v)
      end)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    router =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "role" => "router"
      })

    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})

    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "tg-status",
      "provider" => "telegram",
      "managed_by" => "comma_product",
      "managed_peer_id" => "123456",
      "status" => "connected",
      "bot_token" => "test-token"
    }

    connect =
      if context[:wechat] do
        Map.merge(connect, %{
          "provider" => "wechat",
          "connect_id" => "wx-status",
          "wechat_id" => "wx-peer",
          "bot_user_id" => "wx-bot",
          "base_url" => "http://127.0.0.1:#{port}",
          "token" => "wx-token",
          "latest_context_token" => "wx-context"
        })
      else
        connect
      end

    connect =
      if context[:signal] do
        connect
        |> Map.drop(~w(managed_by managed_peer_id bot_token))
        |> Map.merge(%{
          "provider" => "signal",
          "connect_id" => "sg-status",
          "signal_bindings" => [
            %{
              "binding_id" => "sgb-peer",
              "account_id" => "sg-account",
              "kind" => "user",
              "peer" => "sg-peer"
            }
          ]
        })
      else
        connect
      end

    connect =
      if context[:imessage] do
        connect
        |> Map.drop(~w(bot_token))
        |> Map.merge(%{
          "provider" => "imessage",
          "connect_id" => "im-status",
          "runtime_mode" => context[:imessage],
          "relay_id" => "photon:pho_prj_status",
          "managed_peer_id" => "+15550100",
          "managed_chat_id" => "pho_spc_status",
          "bot_user_id" => "pho_usr_line"
        })
      else
        connect
      end

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group_id, connect["connect_id"]), connect)

    target = %{
      "provider" => "telegram",
      "connect_id" => connect["connect_id"],
      "chat_id" => "123456",
      "chat_type" => "private",
      "message_thread_id" => "7"
    }

    target =
      if context[:wechat],
        do: %{
          "provider" => "wechat",
          "connect_id" => connect["connect_id"],
          "wechat_id" => "wx-peer"
        },
        else: target

    target =
      if context[:signal],
        do: %{
          "provider" => "signal",
          "connect_id" => connect["connect_id"],
          "chat_id" => "sg-peer",
          "chat_type" => "private"
        },
        else: target

    target =
      if context[:imessage],
        do: %{
          "provider" => "imessage",
          "connect_id" => connect["connect_id"],
          "chat_id" => "pho_spc_status",
          "chat_type" => "private"
        },
        else: target

    %{
      connect: connect,
      target: target,
      agent_id: agent_id,
      session_id: router["router_session_id"],
      source: "im_provider:#{connect["provider"]}:#{connect["connect_id"]}:42"
    }
  end

  test "only current accepted source IDs can project; private drafts and errors never leak", c do
    activity =
      active(c, "is thinking...")
      |> Map.put("_participant_realtime", %{"draft" => %{"text" => "private thought"}})

    assert PrivateChatStatusActor.project(activity, [c.source]) ==
             {:thinking, "Comma is thinking..."}

    assert PrivateChatStatusActor.project(activity, ["foreign"]) == :idle
    assert PrivateChatStatusActor.project(%{"state" => "stopped"}, [c.source]) == :idle

    assert {:error, text} =
             PrivateChatStatusActor.project(
               Map.merge(activity, %{
                 "state" => "error",
                 "status" => "private error",
                 "issue" => "secret"
               }),
               [c.source]
             )

    refute text =~ "private"
    refute text =~ "secret"

    assert :waiting =
             PrivateChatStatusActor.project(
               Map.merge(activity, %{"status" => "is waiting...", "wait" => %{}}),
               [c.source]
             )
  end

  test "real Router ingress activates status but receipt replay never redelivers", c do
    update = %{
      "update_id" => 42,
      "message" => %{
        "message_id" => 9,
        "message_thread_id" => 7,
        "text" => "Hello",
        "chat" => %{"id" => 123_456, "type" => "private"},
        "from" => %{"id" => 123_456, "first_name" => "Test"}
      }
    }

    assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_telegram_update(c.connect, update)
    settle_receive({:delivered, _, _, opts})
    assert opts[:source_message_id] == c.source
    settle_receive({:api, "sendChatAction", _})
    settle_refute_receive({:api, "sendRichMessageDraft", _}, 30)
    assert {:ok, :duplicate} = SalixIM.ProviderHTTP.handle_telegram_update(c.connect, update)
    settle_refute_receive({:delivered, _, _, _}, 100)
  end

  test "typing follows thinking/tool/composing and is silent during wait/end", c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    settle_receive({:api, "sendChatAction", _})

    for status <- ["is executing a tool...", "is composing a message..."] do
      Runtime.put({:ok, active(c, status)})
      settle_receive({:api, "sendChatAction", _})
    end

    Runtime.put({:ok, Map.merge(active(c, "is waiting..."), %{"wait" => %{}})})
    # Wait until the actor has observed the wait, then inspect future requests.
    SystemsClock.sleep(60)
    flush_typing()
    settle_refute_receive({:api, _, _}, 60)
    Runtime.put({:ok, active(c, "is thinking...")})
    settle_receive({:api, "sendChatAction", _})
    Runtime.put({:ok, %{"state" => "stopped"}})
    flush_typing()
    settle_refute_receive({:api, "sendRichMessageDraft", _}, 100)
  end

  test "a missing presentation supervisor cannot fail actual replies", c do
    stop_supervised!(SalixIM.PrivateChatStatusTaskSupervisor)

    assert :ok =
             PrivateChatStatus.record_inbound(
               c.connect["group_id"],
               c.target,
               c.source,
               c.agent_id,
               c.session_id
             )

    assert {:ok, _} =
             SalixIM.Provider.Telegram.call(c.agent_id, c.connect, "telegram.send_message", %{
               "chat_id" => "123456",
               "text" => "Still delivered"
             })

    settle_receive({:api, "sendMessage", %{"text" => "Still delivered", "parse_mode" => "HTML"}})
    settle_refute_receive({:api, _, _}, 50)
  end

  @tag wechat: true
  test "WeChat never types for another peer or a revoked connection", c do
    assert {:error, :revoked} =
             SalixIM.WeChatStatusTransport.send(
               c.connect,
               %{c.target | "wechat_id" => "other"},
               :typing,
               nil,
               ""
             )

    settle_refute_receive({:api, _, _}, 30)
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "thinking")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    settle_receive({:api, "sendtyping", %{"status" => 1}})

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(c.connect["group_id"], c.connect["connect_id"]),
        &Map.put(&1, "disabled_at", 123)
      )

    monitor = SystemsRuntime.Proc.monitor(pid)
    settle_receive({:DOWN, ^monitor, :process, ^pid, :normal})
    settle_refute_receive({:api, "sendtyping", %{"status" => 2}}, 50)
  end

  @tag wechat: true
  test "WeChat typing rejection cannot fail accepted Router input", c do
    API.respond("getconfig", 403)

    update = %{
      "message_id" => "42",
      "message_type" => 1,
      "from_user_id" => "wx-peer",
      "context_token" => "wx-context",
      "text" => "Hello"
    }

    assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_wechat_update(c.connect, update)
    settle_receive({:delivered, _, _, _})
    settle_receive({:api, "getconfig", _})
    settle_refute_receive({:api, "sendtyping", _}, 100)
  end

  @tag signal: true
  test "Signal Router ingress types from the account bound to the private chat", c do
    Runtime.put({:ok, active(c, "thinking")})

    assert :ok =
             PrivateChatStatus.record_inbound(
               c.connect["group_id"],
               c.target,
               c.source,
               c.agent_id,
               c.session_id
             )

    settle_receive({:signal_typing, "sg-account", "sg-peer", :started})
  end

  @tag imessage: "photon"
  test "Photon iMessage types from the assigned line in the bound Space and stops after", c do
    Runtime.put({:ok, active(c, "is thinking...")})

    assert :ok =
             PrivateChatStatus.record_inbound(
               c.connect["group_id"],
               c.target,
               c.source,
               c.agent_id,
               c.session_id
             )

    settle_receive({:api, "typing", %{"senderId" => "pho_usr_line", "typing" => true}})
    Runtime.put({:ok, %{"state" => "stopped"}})
    settle_receive({:api, "typing", %{"typing" => false}})

    # Another Space is not this connect's chat; a rate limit waits instead of failing.
    refute SalixIM.IMessageStatusTransport.authorized?(
             c.connect,
             Map.put(c.target, "chat_id", "pho_spc_other")
           )

    API.respond("typing", 429)

    assert {:error, {:retry_after, _}} =
             SalixIM.IMessageStatusTransport.send(c.connect, c.target, :typing, nil, "")
  end

  @tag imessage: "product_relay"
  test "the relay iMessage transport has no typing indicator", c do
    Runtime.put({:ok, active(c, "is thinking...")})

    assert :ok =
             PrivateChatStatus.record_inbound(
               c.connect["group_id"],
               c.target,
               c.source,
               c.agent_id,
               c.session_id
             )

    settle_refute_receive({:api, "typing", _}, 100)
  end

  defp start_actor(c, refresh_ms \\ 20),
    do:
      start_supervised!(
        {PrivateChatStatusActor,
         agent_id: c.agent_id, connect: c.connect, metadata: c.target, refresh_ms: refresh_ms}
      )

  defp active(c, status),
    do: %{"state" => "active", "status" => status, "_active_source_message_ids" => [c.source]}

  defp flush_typing do
    SystemsRuntime.Proc.receive do
      {:api, "sendChatAction", _} -> flush_typing()
      {:api, "sendtyping", %{"status" => 1}} -> flush_typing()
    after
      0 -> :ok
    end
  end
end
