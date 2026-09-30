defmodule SalixIM.PrivateChatStatusTest do
  use ExUnit.Case, async: false

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
          do: send(pid, {:session_activity_updated, a, s})
    end

    def subscribe(a, s) do
      pid = self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscribers, fn set -> MapSet.put(set, {pid, a, s}) end)
      )
    end

    def unsubscribe(a, s) do
      pid = self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscribers, fn set -> MapSet.delete(set, {pid, a, s}) end)
      )
    end

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      send(Agent.get(__MODULE__, & &1.parent), {:delivered, agent, payload, opts})

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
      send(parent, {:api, method, Jason.decode!(raw)})

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
      send(
        Application.get_env(:salix_im, :signal_test_pid),
        {:signal_typing, account_id, peer, action}
      )

      {:ok, %{"timestamp" => 1}}
    end
  end

  setup context do
    SalixStore.S3.Fake.reset()
    start_supervised!({Runtime, self()})
    start_supervised!({API, self()})
    start_supervised!({Registry, keys: :unique, name: SalixIM.PrivateChatStatusRegistry})

    start_supervised!(
      {DynamicSupervisor, name: SalixIM.PrivateChatStatusFleetSup, strategy: :one_for_one}
    )

    start_supervised!({Task.Supervisor, name: SalixIM.PrivateChatStatusTaskSupervisor},
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
      signal_test_pid: self()
    }

    previous = Map.new(env, fn {k, _} -> {k, Application.get_env(:salix_im, k)} end)
    Enum.each(env, fn {k, v} -> Application.put_env(:salix_im, k, v) end)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if is_nil(v),
          do: Application.delete_env(:salix_im, k),
          else: Application.put_env(:salix_im, k, v)
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

  test "HTTP adapter only permits typing and validates integer targets", c do
    assert :ok = TelegramStatusTransport.send(c.connect, c.target, :typing, 123, "")

    assert_receive {:api, "sendChatAction",
                    %{"chat_id" => 123_456, "message_thread_id" => 7, "action" => "typing"}}

    assert {:error, :unsupported} =
             TelegramStatusTransport.send(c.connect, c.target, :thinking, 123, "private text")

    refute_receive {:api, "sendRichMessageDraft", _}, 30

    for target <- [
          Map.put(c.target, "chat_id", "999"),
          Map.put(c.target, "chat_type", "group"),
          Map.put(c.target, "message_thread_id", %{})
        ] do
      assert {:error, :revoked} =
               TelegramStatusTransport.send(c.connect, target, :typing, 123, "")
    end

    refute_receive {:api, _, _}, 30
  end

  test "processing uses typing only and never publishes partial text", c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    Runtime.put({:ok, active(c, "is composing a message...")})
    refute_receive {:api, "sendRichMessageDraft", _}, 100
    refute_receive {:api, "sendMessageDraft", _}, 100
    refute_receive {:api, "editMessageText", _}, 100
    refute_receive {:api, "sendMessage", _}, 100
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
    assert_receive {:delivered, _, _, opts}
    assert opts[:source_message_id] == c.source
    assert_receive {:api, "sendChatAction", _}, 6_000
    refute_receive {:api, "sendRichMessageDraft", _}, 30
    assert {:ok, :duplicate} = SalixIM.ProviderHTTP.handle_telegram_update(c.connect, update)
    refute_receive {:delivered, _, _, _}, 100
  end

  test "typing follows thinking/tool/composing and is silent during wait/end", c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000

    for status <- ["is executing a tool...", "is composing a message..."] do
      Runtime.put({:ok, active(c, status)})
      assert_receive {:api, "sendChatAction", _}, 1_000
    end

    Runtime.put({:ok, Map.merge(active(c, "is waiting..."), %{"wait" => %{}})})
    # Wait until the actor has observed the wait, then inspect future requests.
    Process.sleep(60)
    flush_typing()
    refute_receive {:api, _, _}, 60
    Runtime.put({:ok, active(c, "is thinking...")})
    assert_receive {:api, "sendChatAction", _}, 1_000
    Runtime.put({:ok, %{"state" => "stopped"}})
    flush_typing()
    refute_receive {:api, "sendRichMessageDraft", _}, 100
  end

  test "a clarification clears status without a waiting UI and a new answer resumes thinking",
       c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000

    Runtime.put({:ok, Map.put(active(c, "is waiting..."), "wait", %{})})
    Process.sleep(60)

    assert {:ok, _} =
             SalixIM.Provider.Telegram.call(c.agent_id, c.connect, "telegram.send_message", %{
               "chat_id" => "123456",
               "message_thread_id" => "7",
               "text" => "Which meeting do you mean?"
             })

    assert_receive {:api, "sendMessage",
                    %{"text" => "Which meeting do you mean?", "parse_mode" => "HTML"}}

    Runtime.put({:ok, %{"state" => "stopped"}})
    flush_typing()
    refute_receive {:api, _, _}, 100

    newer = %{c | source: "im_provider:telegram:tg-status:43"}
    Runtime.put({:ok, active(newer, "is thinking...")})
    PrivateChatStatusActor.activate(pid, newer.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    assert_receive {:api, "sendChatAction", _}, 1_000
  end

  test "late invalidations read current activity instead of clearing a newer message", c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    newer = %{c | source: "im_provider:telegram:tg-status:43"}
    PrivateChatStatusActor.activate(pid, newer.source, c.session_id)
    Runtime.put({:ok, active(newer, "is composing a message...")})
    send(pid, {:session_activity_updated, c.agent_id, c.session_id})
    assert_receive {:api, "sendChatAction", _}, 1_000

    refute_receive {:api, "sendRichMessageDraft", _}, 60
  end

  test "revoked binding stops refresh with no terminal write to the old peer", c do
    pid = start_actor(c)
    monitor = Process.monitor(pid)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(c.connect["group_id"], c.connect["connect_id"]),
        &Map.put(&1, "disabled_at", 123)
      )

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    flush_typing()
    refute_receive {:api, _, _}, 60
  end

  test "loss of Router ownership stops the old actor", c do
    pid = start_actor(c)
    monitor = Process.monitor(pid)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    Runtime.lose_owner()
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    flush_typing()
    refute_receive {:api, _, _}, 60
  end

  test "retry_after throttles notifications as well as timer refreshes", c do
    API.respond("sendChatAction", 429)
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    for _ <- 1..100, do: send(pid, {:session_activity_updated, c.agent_id, c.session_id})
    refute_receive {:api, _, _}, 150
    assert :sys.get_state(pid).next_at > System.monotonic_time(:millisecond) + 500
  end

  test "unavailable snapshots never turn a private draft into progress", c do
    pid = start_actor(c)
    Runtime.put({:error, :unavailable})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    refute_receive {:api, _, _}, 100
    Runtime.put({:ok, active(%{c | source: "other-connect-source"}, "private progress")})
    refute_receive {:api, _, _}, 100
  end

  test "successful final reply clears the cache without adding a ready draft", c do
    pid = start_actor(c, 100)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    Runtime.put({:ok, %{"state" => "stopped"}})

    assert {:ok, _} =
             SalixIM.Provider.Telegram.call(c.agent_id, c.connect, "telegram.send_message", %{
               "chat_id" => c.target["chat_id"],
               "message_thread_id" => "7",
               "text" => "Final answer"
             })

    assert_receive {:api, "sendMessage", %{"text" => "Final answer", "parse_mode" => "HTML"}}

    flush_typing()
    refute_receive {:api, "sendRichMessageDraft", _}, 250
  end

  test "a post-reply refresh followed by stop never appends a completion draft", c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000

    assert {:ok, _} =
             SalixIM.Provider.Telegram.call(c.agent_id, c.connect, "telegram.send_message", %{
               "chat_id" => c.target["chat_id"],
               "message_thread_id" => "7",
               "text" => "Final answer"
             })

    assert_receive {:api, "sendMessage", %{"text" => "Final answer", "parse_mode" => "HTML"}}

    # The canonical runtime may remain active briefly after provider delivery.
    assert_receive {:api, "sendChatAction", _}, 1_000
    Runtime.put({:ok, %{"state" => "stopped"}})
    refute_receive {:api, "sendRichMessageDraft", _}, 100
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

    assert_receive {:api, "sendMessage", %{"text" => "Still delivered", "parse_mode" => "HTML"}}

    refute_receive {:api, _, _}, 50
  end

  test "provider rejection ends the actor instead of renewing forever", c do
    API.respond("sendChatAction", 403)
    pid = start_actor(c)
    monitor = Process.monitor(pid)
    Runtime.put({:ok, active(c, "is thinking...")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendChatAction", _}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    refute_receive {:api, _, _}, 50
  end

  test "progress HTTP outcomes scrape without private labels and broken observers are isolated",
       c do
    reporter = Module.concat(__MODULE__, Reporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    assert :ok = TelegramStatusTransport.send(c.connect, c.target, :typing, 1, "")
    API.respond("sendChatAction", 503)

    assert {:error, :unavailable} =
             TelegramStatusTransport.send(c.connect, c.target, :typing, 1, "")

    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)
    assert scrape =~ ~s(operation="private_chat_status",outcome="ok",surface="comma")
    assert scrape =~ ~s(operation="private_chat_status",outcome="unavailable",surface="comma")
    refute scrape =~ "test-token"
    refute scrape =~ "private-error"
    refute scrape =~ c.connect["group_id"]

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _, _, _, _ -> throw(:broken_observer) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    API.respond("sendChatAction", 200)
    assert :ok = TelegramStatusTransport.send(c.connect, c.target, :typing, 1, "")
  end

  @tag wechat: true
  test "WeChat Router ingress keeps typing during waits and clears completion",
       c do
    pid = start_actor(c)

    update = %{
      "message_id" => "42",
      "message_type" => 1,
      "from_user_id" => "wx-peer",
      "to_user_id" => "wx-bot",
      "context_token" => "wx-context",
      "item_list" => [%{"type" => 1, "text_item" => %{"text" => "Hello"}}]
    }

    assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_wechat_update(c.connect, update)
    assert_receive {:delivered, _, _, opts}
    assert opts[:source_message_id] == c.source

    assert_receive {:api, "getconfig",
                    %{"ilink_user_id" => "wx-peer", "context_token" => "wx-context"}},
                   2_000

    assert_receive {:api, "sendtyping",
                    %{"status" => 1, "typing_ticket" => "wx-ticket", "ilink_user_id" => "wx-peer"}},
                   2_000

    assert {:ok, :duplicate} = SalixIM.ProviderHTTP.handle_wechat_update(c.connect, update)
    refute_receive {:delivered, _, _, _}, 50

    Runtime.put(
      {:ok, Map.put(active(c, "waiting"), "wait", %{"reason" => "Waiting for image task"})}
    )

    flush_typing()
    assert_receive {:api, "sendtyping", %{"status" => 1}}, 1_000
    assert_receive {:api, "sendtyping", %{"status" => 1}}, 1_000
    refute_receive {:api, "sendtyping", %{"status" => 2}}, 60

    for terminal <- [
          Map.put(active(%{c | source: "another-source"}, "waiting"), "wait", %{}),
          %{"state" => "stopped"},
          Map.put(active(c, "failed"), "state", "error")
        ] do
      Runtime.put({:ok, terminal})
      assert_receive {:api, "sendtyping", %{"status" => 2}}, 1_000
      flush_typing()
      Runtime.put({:ok, active(c, "thinking")})
      assert_receive {:api, "sendtyping", %{"status" => 1}}, 1_000
    end

    refute_receive {:api, "getconfig", _}, 50
    monitor = Process.monitor(pid)
    Runtime.lose_owner()
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
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

    refute_receive {:api, _, _}, 30
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "thinking")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendtyping", %{"status" => 1}}, 1_000

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(c.connect["group_id"], c.connect["connect_id"]),
        &Map.put(&1, "disabled_at", 123)
      )

    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    refute_receive {:api, "sendtyping", %{"status" => 2}}, 50
  end

  @tag wechat: true
  test "WeChat clears typing when its bounded presentation lifetime ends", c do
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "thinking")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:api, "sendtyping", %{"status" => 1}}, 1_000
    :sys.replace_state(pid, &%{&1 | expires_at: System.monotonic_time(:millisecond) - 1})
    monitor = Process.monitor(pid)
    assert_receive {:api, "sendtyping", %{"status" => 2}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
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
    assert_receive {:delivered, _, _, _}
    assert_receive {:api, "getconfig", _}, 6_000
    refute_receive {:api, "sendtyping", _}, 100
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

    assert_receive {:signal_typing, "sg-account", "sg-peer", :started}, 2_000
  end

  @tag signal: true
  test "Signal typing stops with the work and never reaches a group, an unbound peer or a removed binding",
       c do
    for target <- [
          Map.put(c.target, "chat_type", "group"),
          Map.put(c.target, "chat_id", "other-peer")
        ] do
      assert {:error, :revoked} =
               SalixIM.SignalStatusTransport.send(c.connect, target, :typing, nil, "")
    end

    refute_receive {:signal_typing, _, _, _}, 30
    pid = start_actor(c)
    Runtime.put({:ok, active(c, "thinking")})
    PrivateChatStatusActor.activate(pid, c.source, c.session_id)
    assert_receive {:signal_typing, _, "sg-peer", :started}, 1_000
    Runtime.put({:ok, %{"state" => "stopped"}})
    assert_receive {:signal_typing, _, "sg-peer", :stopped}, 1_000
    Runtime.put({:ok, active(c, "thinking")})
    assert_receive {:signal_typing, _, "sg-peer", :started}, 1_000

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(c.connect["group_id"], c.connect["connect_id"]),
        &Map.put(&1, "signal_bindings", [])
      )

    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    refute_receive {:signal_typing, _, _, :stopped}, 50
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
    receive do
      {:api, "sendChatAction", _} -> flush_typing()
      {:api, "sendtyping", %{"status" => 1}} -> flush_typing()
    after
      0 -> :ok
    end
  end
end
