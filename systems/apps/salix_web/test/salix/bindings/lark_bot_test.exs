defmodule Salix.Bindings.LarkBotTest do
  @moduledoc """
  The Lark app's bot in a Lark video meeting, from the invitation event to the
  summary in the inviter's private chat, with Lark's OpenAPI faked. A Feishu
  app's bot goes the same way through the Feishu ingress.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  require SystemsClock

  alias Salix.Control
  alias Salix.Bindings.MeetingCopilot
  alias SalixAgent.AgentControl
  alias SalixIM.{LarkInbound, ProviderHTTP}
  alias SalixMeet.{CalendarAutojoin, Delivery, JoinDispatch, LarkBot, Runtime, Store}
  alias SalixStore.{CasRecord, Keys}

  defmodule FakeLark do
    @moduledoc "Lark as far as the bot needs it. A test scripts the answers of `bots/*`."
    use Agent
    import Plug.Conn

    def start_link(_opts), do: Agent.start_link(fn -> initial() end, name: __MODULE__)
    defp initial, do: %{requests: [], join: [], events: []}

    def script(key, answers), do: Agent.update(__MODULE__, &Map.put(&1, key, answers))
    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def requests(suffix),
      do: Enum.filter(requests(), &String.ends_with?(&1.path, suffix))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      path = "/" <> Enum.join(conn.path_info, "/")
      # Slack's Web API takes a form, Lark's OpenAPI JSON.
      body =
        cond do
          raw == "" -> %{}
          String.starts_with?(raw, "{") -> Jason.decode!(raw)
          true -> URI.decode_query(raw)
        end

      request = %{path: path, body: body, query: conn.query_params}
      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})

      case path do
        # A Slack Canvas downloads as the document it was created with.
        "/files/" <> _canvas_id ->
          send_resp(conn, 200, canvas_document())

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(answer(path, request)))
      end
    end

    defp canvas_document do
      case List.last(requests("/api/canvases.create")) do
        %{body: %{"document_content" => content}} -> Jason.decode!(content)["markdown"]
        _ -> ""
      end
    end

    defp answer("/open-apis/auth/v3/tenant_access_token/internal", _request),
      do: %{"code" => 0, "tenant_access_token" => "t-bot", "expire" => 7200}

    defp answer("/open-apis/im/v1/messages", request),
      do: %{
        "code" => 0,
        "data" => %{
          "message_id" => "om_notice_" <> request.body["receive_id"],
          "chat_id" => "oc_dm_" <> request.body["receive_id"]
        }
      }

    defp answer("/open-apis/vc/v1/bots/join", _request), do: next(:join, joined())
    defp answer("/open-apis/vc/v1/bots/events", _request), do: next(:events, no_events())
    defp answer("/open-apis/vc/v1/bots/message", _request), do: %{"code" => 0, "data" => %{}}

    # The meeting as the app reads it after the end: its Minutes.
    defp answer("/open-apis/vc/v1/meetings/7001", _request),
      do: %{"code" => 0, "data" => %{"meeting" => %{"id" => "7001", "topic" => "Weekly sync"}}}

    defp answer("/open-apis/vc/v1/meetings/7001/recording", _request),
      do: %{
        "code" => 0,
        "data" => %{"recording" => %{"url" => "https://sample.larksuite.com/minutes/obcn7001"}}
      }

    # The model: it answers only a whole request.
    defp answer("/open-apis/chat/completions", request) do
      asked? = List.last(request.body["messages"])["content"] =~ "帮我总结"
      say = if asked?, do: "今天定了周五发布", else: ""

      %{
        "id" => "completion",
        "object" => "chat.completion",
        "model" => "gpt-test",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => Jason.encode!(%{"say" => say})}
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }
    end

    # Slack, for a Meeting whose notices go to a Slack channel: the first
    # message starts the Meeting's thread.
    defp answer("/api/chat.postMessage", request) do
      ts = if request.body["thread_ts"] in [nil, ""], do: "111.222", else: "111.333"

      message =
        case request.body["blocks"] do
          blocks when is_binary(blocks) and blocks != "" ->
            %{"text" => request.body["text"], "blocks" => Jason.decode!(blocks)}

          _ ->
            %{"text" => request.body["text"]}
        end

      %{"ok" => true, "channel" => request.body["channel"], "ts" => ts, "message" => message}
    end

    defp answer("/api/auth.test", _request),
      do: %{"ok" => true, "user_id" => "UBOT", "bot_id" => "BBOT", "team_id" => "T1"}

    defp answer("/api/conversations.info", request),
      do: %{
        "ok" => true,
        "channel" => %{
          "id" => request.body["channel"] || request.query["channel"],
          "is_member" => true
        }
      }

    defp answer("/api/canvases.create", _request), do: %{"ok" => true, "canvas_id" => "CAN1"}

    defp answer("/api/files.info", request) do
      file = to_string(request.body["file"])

      %{
        "ok" => true,
        "file" => %{
          "id" => file,
          "permalink" => "https://w.slack.com/files/" <> file,
          "url_private_download" =>
            SystemsRuntime.get_env(:salix_im, :slack_files_base_url) <> "/files/" <> file
        }
      }
    end

    defp answer("/api/" <> _method, _request), do: %{"ok" => true}

    defp answer(_path, _request), do: %{"code" => 99_991_400, "msg" => "not faked"}

    defp next(key, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.fetch!(state, key) do
          [answer | rest] -> {answer, Map.put(state, key, rest)}
          [] -> {default, state}
        end
      end)
    end

    def joined(id \\ "7001"),
      do: %{"code" => 0, "data" => %{"meeting" => %{"id" => id, "meeting_no" => "123456789"}}}

    def no_events, do: %{"code" => 0, "data" => %{"events" => [], "has_more" => false}}
    def refused(code, msg), do: %{"code" => code, "msg" => msg}
  end

  defmodule RecordingCopilot do
    @moduledoc false
    @behaviour SalixMeet.Ports.Copilot

    @impl true
    def maybe_speak(meeting_id) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :copilot_test_pid),
        {:copilot, meeting_id}
      )

      :ok
    end
  end

  defmodule RecordingDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.LarkDirectDelivery
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def records, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def post_text(_connect, target, text, _mentions, operation_ref) do
      Agent.update(__MODULE__, &[%{target: target, text: text, ref: operation_ref} | &1])
      {:ok, %{"operation_ref" => operation_ref}}
    end

    @impl true
    def post_file(_agent_id, _connect, _target, _path, _blob_ref, _operation_ref),
      do: {:error, :not_expected}
  end

  defmodule RecordingFeishuDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuDirectDelivery
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def records, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def post_text(_connect, target, text, _mentions, operation_ref) do
      Agent.update(__MODULE__, &[%{target: target, text: text, ref: operation_ref} | &1])
      {:ok, %{"operation_ref" => operation_ref}}
    end

    @impl true
    def post_file(_agent_id, _connect, _target, _path, _blob_ref, _operation_ref),
      do: {:error, :not_expected}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      delivery: SystemsRuntime.get_env(:salix_im, :lark_direct_delivery_mod),
      feishu_delivery: SystemsRuntime.get_env(:salix_im, :feishu_direct_delivery_mod),
      base: SystemsRuntime.get_env(:salix_im, :lark_api_base_url),
      feishu_base: SystemsRuntime.get_env(:salix_im, :feishu_api_base_url),
      bot: SystemsRuntime.get_env(:salix_im, :lark_meeting_bot_mod),
      router_summary: SystemsRuntime.get_env(:salix_meet, :router_summary_mod),
      provider: SystemsRuntime.get_env(:salix_meet, :provider_mod),
      copilot_mod: SystemsRuntime.get_env(:salix_meet, :copilot_mod),
      copilot_test_pid: SystemsRuntime.get_env(:salix_meet, :copilot_test_pid),
      copilot_enabled: SystemsRuntime.get_env(:salix_meet, :copilot_enabled),
      skip_metering: SystemsRuntime.get_env(:salix_web, :meeting_summary_skip_metering)
    }

    SystemsRuntime.put_env(:salix_meet, :copilot_mod, RecordingCopilot)
    SystemsRuntime.put_env(:salix_meet, :copilot_test_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    start_supervised!(FakeLark)
    start_supervised!(RecordingDelivery)
    start_supervised!(RecordingFeishuDelivery)
    SystemsRuntime.put_env(:salix_im, :lark_direct_delivery_mod, RecordingDelivery)
    SystemsRuntime.put_env(:salix_im, :feishu_direct_delivery_mod, RecordingFeishuDelivery)
    SystemsRuntime.put_env(:salix_im, :lark_meeting_bot_mod, LarkBot)
    SystemsRuntime.delete_env(:salix_meet, :router_summary_mod)
    SystemsRuntime.put_env(:salix_meet, :provider_mod, SalixMeet.ProviderDispatcher)

    bandit =
      start_supervised!({Bandit, plug: FakeLark, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SalixIM.Provider.Lark.API.reset_token_cache()
    SalixIM.Provider.Feishu.API.reset_token_cache()

    assert {:ok, %{"tenant_id" => tenant_id}} = Control.create_tenant(%{"name" => "Lark bot"})

    assert {:ok, %{"group_id" => group_id}} =
             Control.create_group(%{"name" => "Lark bot group"}, tenant_id)

    assert {:ok, %{"agent_id" => router_id}} =
             AgentControl.create(
               %{"group_id" => group_id, "name" => "Router", "role" => "router"},
               tenant_id
             )

    assert {:ok, _group} =
             Control.update_group(group_id, %{"router_agent_id" => router_id}, tenant_id)

    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "lark-bot-connect",
      "provider" => "lark",
      "status" => "connected",
      "events" => "socket",
      "app_id" => "cli_bot",
      "app_secret" => "secret",
      "bot_open_id" => "ou_bot"
    }

    assert {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group_id, "lark-bot-connect"), connect)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_im, :lark_direct_delivery_mod, previous.delivery)
      restore_env(:salix_im, :lark_api_base_url, previous.base)
      restore_env(:salix_im, :feishu_direct_delivery_mod, previous.feishu_delivery)
      restore_env(:salix_im, :feishu_api_base_url, previous.feishu_base)
      SalixIM.Provider.Feishu.API.reset_token_cache()
      restore_env(:salix_im, :lark_meeting_bot_mod, previous.bot)
      restore_env(:salix_meet, :router_summary_mod, previous.router_summary)
      restore_env(:salix_meet, :provider_mod, previous.provider)
      restore_env(:salix_meet, :copilot_mod, previous.copilot_mod)
      restore_env(:salix_meet, :copilot_test_pid, previous.copilot_test_pid)
      restore_env(:salix_meet, :copilot_enabled, previous.copilot_enabled)
      restore_env(:salix_web, :meeting_summary_skip_metering, previous.skip_metering)
      SalixIM.Provider.Lark.API.reset_token_cache()
    end)

    {:ok, connect: connect, tenant_id: tenant_id, group_id: group_id, port: port}
  end

  test "an invited bot joins, reads the meeting, and sends the inviter the summary", %{
    connect: connect
  } do
    assert {:ok, %{"ok" => true}} = LarkInbound.handle_socket_event(connect, invitation("call-1"))

    assert [%{body: join}] = FakeLark.requests("/bots/join")

    assert join == %{
             "join_type" => 1,
             "join_identify" => %{"meeting_no" => "123456789"},
             "call_id" => "call-1"
           }

    # The inviter's private chat is the only place status goes.
    assert [%{body: %{"receive_id" => "ou_ann", "content" => notice}}] =
             FakeLark.requests("/im/v1/messages")

    assert notice =~ "Joining the Lark meeting"

    id = meeting_id!()
    state = state!(id)
    assert state["status"] == "active"
    assert state["provider"] == "lark"
    assert state["runtime_source"] == "lark_bot"
    assert state["lark_bot"]["meeting_id"] == "7001"
    assert state["lark_ref"]["chat_id"] == "oc_dm_ou_ann"
    assert state["lark_ref"]["chat_type"] == "p2p"
    assert [%{text: "Joined the Lark meeting."}] = RecordingDelivery.records()

    # Lark resends a sentence as it grows: the latest text stands.
    FakeLark.script(:events, [
      events(
        [
          transcript("e1", "s1", "Ann", "Ship"),
          transcript("e2", "s1", "Ann", "Ship it on Friday"),
          transcript("e3", "s2", "Bob", "Agreed"),
          chat("e4", "Bob", "see the doc")
        ],
        "cursor-1"
      )
    ])

    assert :ok = LarkBot.poll(id)
    state = state!(id)

    assert Enum.map(state["captions"], &{&1["speaker"], &1["text"]}) == [
             {"Ann", "Ship it on Friday"},
             {"Bob", "Agreed"}
           ]

    assert [%{"sender" => "Bob", "text" => "see the doc", "direction" => "incoming"}] =
             state["chats"]

    assert state["lark_bot"]["page_token"] == "cursor-1"
    assert is_integer(state["lark_bot"]["confirmed_at"])

    # The next read goes on from the cursor, and a later revision still replaces.
    FakeLark.script(:events, [
      events([transcript("e5", "s2", "Bob", "Agreed, Friday")], "cursor-2"),
      FakeLark.refused(120_004, "bot is not in meeting")
    ])

    assert :ok = LarkBot.poll(id)
    assert List.last(FakeLark.requests("/bots/events")).query["page_token"] == "cursor-1"

    assert Enum.map(state!(id)["captions"], & &1["text"]) == [
             "Ship it on Friday",
             "Agreed, Friday"
           ]

    # A host removed the bot, or the meeting is over: there is no ended event.
    assert :ok = LarkBot.poll(id)
    assert state!(id)["status"] == "done"

    assert :published = Delivery.deliver_one(id, node: "lark-bot", now: 1_000)
    texts = Enum.map(RecordingDelivery.records(), & &1.text)
    assert "Left the meeting. Preparing the summary…" in texts
    assert Enum.any?(texts, &String.starts_with?(&1, "Meeting summary: Weekly sync"))

    # No files: Lark keeps its own Minutes.
    refute Enum.any?(texts, &(&1 =~ ~r/transcript|audio/i))
    assert Enum.all?(RecordingDelivery.records(), &(&1.target["chat_id"] == "oc_dm_ou_ann"))
    assert get_in(state!(id), ["delivery", "status"]) == "published"
  end

  test "the leader reads a live meeting, and a process lost with its node comes back", %{
    connect: connect
  } do
    FakeLark.script(:events, [
      events([transcript("e1", "s1", "Ann", "Heard by the leader")], "c1")
    ])

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()

    settle_until(fn -> state!(id)["captions"] != [] end)
    assert [%{"text" => "Heard by the leader"}] = state!(id)["captions"]

    [{pid, _}] = SystemsRuntime.Registry.lookup(SalixMeet.Registry, id)
    :ok = SystemsRuntime.DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
    settle_until(fn -> SystemsRuntime.Registry.lookup(SalixMeet.Registry, id) == [] end)

    assert :skipped = Delivery.deliver_one(id, node: "lark-bot")
    assert [{_pid, _}] = SystemsRuntime.Registry.lookup(SalixMeet.Registry, id)
  end

  test "the leader gives the copilot what it read, and the answer reaches the meeting", %{
    connect: connect
  } do
    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()
    settle_receive({:copilot, ^id})

    assert {:ok, _} = Runtime.send_chat(id, "周五发布")
    assert {:ok, _} = Runtime.send_chat(id, "周五发布")

    assert [%{body: first}, %{body: second}] = FakeLark.requests("/bots/message")
    assert %{"meeting_id" => "7001", "msg_type" => "text", "content" => "周五发布"} = first
    assert first["uuid"] == second["uuid"]
  end

  test "a sentence that grows after the copilot read it reaches the model and gets its answer", %{
    connect: connect,
    port: port
  } do
    # This test drives the rounds of the leader itself.
    SystemsRuntime.put_env(:salix_meet, :copilot_enabled, false)
    SystemsRuntime.put_env(:salix_web, :meeting_summary_skip_metering, true)

    SalixAgent.TestSupport.configure_platform_tier!(
      "summary",
      "http://127.0.0.1:#{port}/open-apis",
      "gpt-test"
    )

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()

    round = fn items, token ->
      FakeLark.script(:events, [events(items, token)])
      assert :ok = LarkBot.poll(id)
      SystemsClock.sleep(5_000)
      assert :ok = MeetingCopilot.maybe_speak(id)
    end

    round.([transcript("e1", "s1", "Ann", "Comma")], "c1")
    assert [_first] = FakeLark.requests("/chat/completions")
    assert FakeLark.requests("/bots/message") == []

    round.([transcript("e2", "s1", "Ann", "Comma，帮我总结")], "c2")
    assert [_first, %{body: %{"messages" => messages}}] = FakeLark.requests("/chat/completions")
    assert List.last(messages)["content"] =~ "Ann: Comma，帮我总结"

    assert [%{body: %{"content" => "今天定了周五发布", "meeting_id" => "7001"}}] =
             FakeLark.requests("/bots/message")

    # The answer comes back as chat. It starts no turn, and the sentence is not read again.
    round.([chat("e3", "bot", "今天定了周五发布")], "c3")
    assert length(FakeLark.requests("/chat/completions")) == 2
    assert length(FakeLark.requests("/bots/message")) == 1
  end

  test "the bot's own message comes back as outgoing, and a repeat is not a revision", %{
    connect: connect
  } do
    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()

    FakeLark.script(:events, [
      events(
        [
          transcript("e1", "s1", "Ann", "Cirno, 什么时候发布"),
          chat("e2", "bot", "周五发布"),
          chat("e3", "Ann", "收到")
        ],
        "c1"
      ),
      events([], "c2")
    ])

    assert :ok = LarkBot.poll(id)
    state = state!(id)

    assert Enum.map(state["chats"], &{&1["text"], &1["direction"]}) == [
             {"周五发布", "outgoing"},
             {"收到", "incoming"}
           ]

    assert [%{"revised_at" => revised_at}] = state["captions"]
    SystemsClock.sleep(5_000)

    FakeLark.script(:events, [
      events([transcript("e4", "s1", "Ann", "Cirno, 什么时候发布")], "c3")
    ])

    assert :ok = LarkBot.poll(id)
    assert [%{"revised_at" => ^revised_at}] = state!(id)["captions"]

    FakeLark.script(:events, [
      events([transcript("e5", "s1", "Ann", "Cirno, 什么时候发布呢")], "c4")
    ])

    assert :ok = LarkBot.poll(id)
    assert [%{"revised_at" => later}] = state!(id)["captions"]
    assert later > revised_at
  end

  test "the same invitation sent again joins once", %{connect: connect} do
    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    # Somebody else invites the bot into the meeting it is already in.
    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-2", "ou_bob"))

    assert [_one] = FakeLark.requests("/bots/join")
    assert {:ok, [_id]} = Store.list()
  end

  test "meetings of one connect run side by side, each with its own target", %{connect: connect} do
    FakeLark.script(:join, [FakeLark.joined("7001"), FakeLark.joined("7002")])

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))

    other =
      invitation("call-2", "ou_bob")
      |> put_in(["event", "meeting"], %{"id" => 7002, "meeting_no" => "987654321", "topic" => "B"})

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, other)

    assert {:ok, ids} = Store.list()
    states = Enum.map(ids, &state!/1)
    assert Enum.sort(Enum.map(states, & &1["lark_bot"]["meeting_id"])) == ["7001", "7002"]

    assert Enum.sort(Enum.map(states, & &1["lark_ref"]["chat_id"])) ==
             ["oc_dm_ou_ann", "oc_dm_ou_bob"]

    assert Enum.all?(states, &(&1["status"] == "active"))
  end

  test "the ended event ends the meeting, and the bot can be invited back", %{connect: connect} do
    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()

    FakeLark.script(:events, [events([transcript("e1", "s1", "Ann", "Last words")], "c1")])

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, ended())
    state = state!(id)
    assert state["status"] == "done"
    assert [%{"text" => "Last words"}] = state["captions"]

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, ended())

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-2"))
    assert [_first, _second] = FakeLark.requests("/bots/join")
    assert {:ok, [_, _]} = Store.list()
  end

  test "a refused join tells the inviter and fails the meeting", %{connect: connect} do
    FakeLark.script(:join, [FakeLark.refused(121_003, "no permission")])

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))

    assert state!(meeting_id!())["status"] == "failed"
    assert [%{text: text}] = RecordingDelivery.records()
    assert text =~ "Could not join the meeting"
    assert text =~ "121003"
  end

  test "a bot waiting to be admitted is not taken for one that left", %{connect: connect} do
    FakeLark.script(:events, [FakeLark.refused(10_005, "bot is not in meeting")])

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()

    assert :ok = LarkBot.poll(id)
    assert state!(id)["status"] == "active"
  end

  test "a read Lark fails says nothing about the meeting", %{connect: connect} do
    FakeLark.script(:events, [FakeLark.refused(99_991_400, "rate limit")])

    assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
    id = meeting_id!()

    assert {:error, _} = LarkBot.poll(id)
    assert state!(id)["status"] == "active"
  end

  test "one person's bot takes invitations from its owner only", %{connect: connect} do
    connect = Map.merge(connect, %{"owner_only" => true, "owner_open_id" => "ou_owner"})

    assert {:ok, %{"ok" => true}} = LarkInbound.handle_socket_event(connect, invitation("call-1"))

    assert FakeLark.requests("/bots/join") == []
    assert {:ok, []} = Store.list()
  end

  test "a Feishu app's bot joins a Feishu meeting and sends the inviter the summary", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    assert {:ok, _app} =
             Control.Tenants.put_feishu_tenant_app(tenant_id, %{
               "app_id" => "cli_feishu_bot",
               "app_secret" => "secret"
             })

    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "feishu-bot-connect",
      "provider" => "feishu",
      "status" => "connected",
      "events" => "socket",
      "app_id" => "cli_feishu_bot",
      "bot_open_id" => "ou_bot"
    }

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, "feishu-bot-connect"), connect)

    assert {:ok, %{ok: true}} =
             ProviderHTTP.handle_feishu_socket_event(connect, invitation("call-1"))

    assert [%{body: %{"join_identify" => %{"meeting_no" => "123456789"}}}] =
             FakeLark.requests("/bots/join")

    assert [%{body: %{"receive_id" => "ou_ann", "content" => notice}}] =
             FakeLark.requests("/im/v1/messages")

    assert notice =~ "正在加入飞书会议"

    id = meeting_id!()
    state = state!(id)
    assert state["status"] == "active"
    assert state["provider"] == "feishu"
    assert state["runtime_source"] == "lark_bot"
    assert state["meet_url"] == "https://vc.feishu.cn/j/123456789"
    assert state["feishu_ref"]["chat_id"] == "oc_dm_ou_ann"
    assert [%{text: "已加入飞书会议。"}] = RecordingFeishuDelivery.records()

    # Feishu answers a bot that is out of the meeting as Lark does.
    FakeLark.script(:events, [
      events([transcript("e1", "s1", "Ann", "周五发布")], "cursor-1"),
      FakeLark.refused(120_004, "bot is not in meeting")
    ])

    assert :ok = LarkBot.poll(id)
    assert [%{"text" => "周五发布"}] = state!(id)["captions"]
    assert :ok = LarkBot.poll(id)
    assert state!(id)["status"] == "done"

    assert :published = Delivery.deliver_one(id, node: "feishu-bot", now: 1_000)
    texts = Enum.map(RecordingFeishuDelivery.records(), & &1.text)
    assert "已离开会议，正在整理摘要…" in texts
    assert Enum.all?(RecordingFeishuDelivery.records(), &(&1.target["chat_id"] == "oc_dm_ou_ann"))
    assert RecordingDelivery.records() == []
  end

  test "one person's Feishu bot takes invitations from its owner only", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => "feishu-owner-connect",
      "provider" => "feishu",
      "status" => "connected",
      "events" => "socket",
      "app_id" => "cli_feishu_owner",
      "owner_only" => true,
      "owner_open_id" => "ou_owner"
    }

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_im_connect(group_id, "feishu-owner-connect"), connect)

    assert {:ok, %{ignored: true}} =
             ProviderHTTP.handle_feishu_socket_event(connect, invitation("call-1"))

    assert FakeLark.requests("/bots/join") == []
    assert {:ok, []} = Store.list()
  end

  describe "a calendar meeting with a Lark link" do
    setup %{connect: connect} do
      {:ok, id: calendar_meeting!(connect)}
    end

    test "waits for the start, tells the chat once what the host must change, then joins", %{
      id: id,
      connect: connect
    } do
      FakeLark.script(:join, [
        FakeLark.refused(121_014, "meeting not started"),
        FakeLark.refused(121_016, "ai summary off"),
        FakeLark.joined()
      ])

      # Not started: pending again, and no attempt is spent.
      assert {:error, {:join_deferred, :lark_meeting_not_started}} = JoinDispatch.run(id)
      assert %{"status" => "pending", "attempt_count" => 0} = state!(id)["join_dispatch"]
      assert {:ok, %{"join_requested_at" => nil}, _etag} = Store.get(id)

      # Refused by the meeting's settings: the chat hears why, once.
      assert {:error, {:join_deferred, {:lark_meeting_blocked, "ai_summary_off"}}} =
               JoinDispatch.run(id)

      assert [%{text: blocked, target: %{"chat_id" => "oc_team"}}] = RecordingDelivery.records()
      assert blocked =~ "turn on AI Summary"

      # Asked again only after a while, and silently.
      assert {:error, {:join_deferred, _}} = JoinDispatch.run(id)
      assert [_, _] = FakeLark.requests("/bots/join")

      {:ok, _doc, _etag} =
        Store.update_state_retrying(id, &put_in(&1, ["lark_bot", "retry_at"], 0))

      assert {:ok, _joined_at} = JoinDispatch.run(id)

      assert [_, _, %{body: join}] = FakeLark.requests("/bots/join")
      assert join == %{"join_type" => 1, "join_identify" => %{"meeting_no" => "123456789"}}

      state = state!(id)
      assert state["status"] == "active"
      assert state["lark_bot"]["meeting_id"] == "7001"
      assert state["join_dispatch"]["status"] == "dispatched"

      assert Enum.map(RecordingDelivery.records(), & &1.text) == [
               blocked,
               "Joined the Lark meeting."
             ]

      # A person who invites the bot into the same meeting makes no second Meeting.
      assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-9"))
      assert {:ok, [^id]} = Store.list()
      assert [_, _, _] = FakeLark.requests("/bots/join")

      # The minutes go to the chat, with the meeting's Lark Minutes.
      FakeLark.script(:events, [
        events([transcript("e1", "s1", "Ann", "Ship it")], "c1"),
        FakeLark.refused(120_004, "bot is not in meeting")
      ])

      assert :ok = LarkBot.poll(id)
      assert :ok = LarkBot.poll(id)
      assert :published = Delivery.deliver_one(id, node: "lark-bot", now: 1_000)

      summary =
        Enum.find(RecordingDelivery.records(), &String.starts_with?(&1.text, "Meeting summary"))

      assert summary.text =~ "Lark Minutes: https://sample.larksuite.com/minutes/obcn7001"
      assert Enum.all?(RecordingDelivery.records(), &(&1.target["chat_id"] == "oc_team"))
    end

    test "a meeting that ended or does not exist is given up", %{id: id} do
      FakeLark.script(:join, [FakeLark.refused(121_004, "meeting ended")])

      assert {:error, {:join_abandoned, {:lark_meeting_unavailable, 121_004}}} =
               JoinDispatch.run(id)

      state = state!(id)
      assert state["join_dispatch"]["status"] == "abandoned"
      assert is_integer(state["calendar_autojoin_abandoned_at"])
      assert state["status"] == "provisioning"
      assert RecordingDelivery.records() == []
    end

    test "a meeting the bot is in through an invitation is not joined again", %{
      id: id,
      connect: connect
    } do
      assert {:ok, _} = LarkInbound.handle_socket_event(connect, invitation("call-1"))
      assert [_invited] = FakeLark.requests("/bots/join")

      assert {:error, {:join_abandoned, :lark_meeting_joined}} = JoinDispatch.run(id)
      assert [_invited] = FakeLark.requests("/bots/join")
    end
  end

  describe "a Google calendar meeting with a Lark link whose notices go to Slack" do
    defmodule GoogleCalendar do
      @moduledoc "The Group's Google calendar, as the enrollment's occurrence port lists it."
      @behaviour SalixMeet.Ports.CalendarOccurrences

      @impl true
      def list(_group, _t0_ms, _t1_ms),
        do: {:ok, SystemsRuntime.get_env(:salix_meet, :lark_bot_test_events, [])}

      @impl true
      def revalidate(_group, _event), do: :ok
    end

    setup %{port: port} do
      previous = %{
        calendar: SystemsRuntime.get_env(:salix_meet, :calendar_occurrences_mod),
        slack: SystemsRuntime.get_env(:salix_im, :slack_api_base_url),
        slack_files: SystemsRuntime.get_env(:salix_im, :slack_files_base_url)
      }

      SystemsRuntime.put_env(:salix_meet, :calendar_occurrences_mod, GoogleCalendar)
      SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
      SystemsRuntime.put_env(:salix_im, :slack_files_base_url, "http://127.0.0.1:#{port}")

      on_exit(fn ->
        restore_env(:salix_meet, :calendar_occurrences_mod, previous.calendar)
        restore_env(:salix_im, :slack_api_base_url, previous.slack)
        restore_env(:salix_im, :slack_files_base_url, previous.slack_files)
        SystemsRuntime.delete_env(:salix_meet, :lark_bot_test_events)
      end)

      :ok
    end

    test "the Lark bot joins by number, and status and the summary with its Minutes go to the Slack thread",
         %{connect: lark, tenant_id: tenant_id, group_id: group_id} do
      assert {:ok, _} =
               CasRecord.create(Keys.ctl_im_connect(group_id, "slack-connect"), %{
                 "tenant_id" => tenant_id,
                 "group_id" => group_id,
                 "connect_id" => "slack-connect",
                 "provider" => "slack",
                 "workspace_id" => "T1",
                 "bot_token" => "xoxb-test",
                 "oauth_completed_at" => 1
               })

      # The enrollment of settings whose destination is the Slack bot, in a
      # Group that also has a Lark bot (`Salix.Bindings.MeetingEnrollment`).
      group = %{
        "provider" => "slack",
        "mode" => "join",
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "connect_id" => "slack-connect",
        "workspace_id" => "T1",
        "channel_id" => "C-meet",
        "calendar_id" => "cal-google",
        "lark_join" => %{"lark" => lark["connect_id"]}
      }

      now = SystemsClock.system_time(:millisecond)
      start_ms = now + 60_000

      SystemsRuntime.put_env(:salix_meet, :lark_bot_test_events, [
        %{
          "event_id" => "evt-lark",
          "calendar_id" => "cal-google",
          "calendar_item_id" => "item-lark",
          "occurrence_ref" => %{
            "calendar_id" => "cal-google",
            "scheduling_link_id" => "link-lark",
            "recurrence_key" => %{"kind" => "single"}
          },
          "meeting_plan_id" => "plan-lark",
          "start_ms" => start_ms,
          "end_ms" => start_ms + 1_800_000,
          "meet_url" => "https://vc-sg.larksuite.com/j/987654321",
          "title" => "Customer sync"
        }
      ])

      FakeLark.script(:join, [FakeLark.refused(121_014, "meeting not started"), FakeLark.joined()])

      assert [{^group_id, 1}] = CalendarAutojoin.scan_once([group], now: now)

      # The meeting has not started: the pass skips it, no error, and no
      # attempt is spent.
      assert [%{action: :skipped, reason: {:join_deferred, :lark_meeting_not_started}, mid: id}] =
               CalendarAutojoin.join_sweep([group], now: now, group_bounded: true)

      assert %{"status" => "pending", "attempt_count" => 0} = state!(id)["join_dispatch"]

      # A Slack Meeting in the channel's thread, joined by the Lark bot.
      state = state!(id)
      assert state["provider"] == "slack"
      assert state["slack_ref"] == %{"channel_id" => "C-meet", "thread_ts" => "111.222"}
      assert state["runtime_source"] == "lark_bot"

      assert %{
               "connect_id" => "lark-bot-connect",
               "provider" => "lark",
               "meeting_no" => "987654321"
             } =
               state["lark_bot"]

      # The next pass joins it.
      assert [%{action: :joined, mid: ^id}] =
               CalendarAutojoin.join_sweep([group], now: now + 60_000, group_bounded: true)

      assert [_, %{body: join}] = FakeLark.requests("/bots/join")
      assert join == %{"join_type" => 1, "join_identify" => %{"meeting_no" => "987654321"}}
      assert state!(id)["lark_bot"]["meeting_id"] == "7001"

      posts = FakeLark.requests("/api/chat.postMessage")
      assert [%{body: %{"channel" => "C-meet", "text" => root}} | replies] = posts
      assert root =~ "Joining Customer sync"

      assert Enum.any?(
               replies,
               &(&1.body["thread_ts"] == "111.222" and &1.body["text"] =~ "Joined the meeting")
             )

      # Lark posts nothing: the destination is Slack.
      assert RecordingDelivery.records() == []

      # The meeting ends: the summary goes to the thread with the Lark Minutes.
      FakeLark.script(:events, [
        events([transcript("e1", "s1", "Ann", "Ship it")], "c1"),
        FakeLark.refused(120_004, "bot is not in meeting")
      ])

      assert :ok = LarkBot.poll(id)
      assert :ok = LarkBot.poll(id)
      assert :published = Delivery.deliver_one(id, node: "lark-bot", now: 1_000)

      assert Enum.any?(FakeLark.requests("/api/chat.postMessage"), fn %{body: body} ->
               posted = "#{body["text"]} #{body["blocks"]}"

               body["thread_ts"] == "111.222" and posted =~ "Lark Minutes" and
                 posted =~ "https://sample.larksuite.com/minutes/obcn7001"
             end)

      assert RecordingDelivery.records() == []
    end
  end

  # A Meeting as `SalixMeet.CalendarAutojoin` creates it for a Lark link whose
  # notices go to a Lark chat.
  defp calendar_meeting!(connect) do
    id = "mtg-" <> (12 |> SystemsRuntime.Proc.random_bytes() |> Base.encode16(case: :lower))
    now = SystemsClock.system_time(:second)

    {:ok, agent} = Runtime.start_for_group(connect["tenant_id"], connect["group_id"])

    {:ok, state} =
      SalixMeet.MeetingState.new_lark(id, agent, %{
        "tenant_id" => connect["tenant_id"],
        "group_id" => connect["group_id"],
        "connect_id" => connect["connect_id"],
        "lark_ref" => %{
          "chat_id" => "oc_team",
          "chat_type" => "group",
          "thread_id" => "",
          "root_message_id" => "",
          "trigger_message_id" => "om_root"
        },
        "meet_url" => "https://vc.larksuite.com/j/123456789",
        "title" => "Weekly sync",
        "bot_name" => "Cirno",
        "caption_language" => "English",
        "start_at" => now,
        "end_at" => now + 3_600,
        "runtime_source" => "lark_bot",
        "source" => %{"kind" => "calendar"}
      })

    state =
      Map.put(state, "lark_bot", %{
        "connect_id" => connect["connect_id"],
        "provider" => "lark",
        "meeting_no" => "123456789"
      })

    {:ok, _doc, _etag} = Store.create_once(id, state: state)
    id
  end

  defp invitation(call_id, inviter \\ "ou_ann") do
    %{
      "header" => %{
        "event_type" => "vc.bot.meeting_invited_v1",
        "event_id" => "ev-" <> call_id,
        "tenant_key" => "tk"
      },
      "event" => %{
        "meeting" => %{"id" => 7001, "meeting_no" => "123456789", "topic" => "Weekly sync"},
        "inviter" => %{"id" => %{"open_id" => inviter, "union_id" => "on_x"}},
        "call_id" => call_id
      }
    }
  end

  defp ended do
    %{
      "header" => %{"event_type" => "vc.bot.meeting_ended_v1", "event_id" => "ev-ended"},
      "event" => %{"meeting" => %{"id" => 7001}}
    }
  end

  defp events(items, token) do
    %{"code" => 0, "data" => %{"events" => items, "has_more" => false, "page_token" => token}}
  end

  defp transcript(event_id, sentence_id, speaker, text) do
    %{
      "event_id" => event_id,
      "event_type" => "transcript_received",
      "payload" => %{
        "transcript_received_items" => [
          %{
            "sentence_id" => sentence_id,
            "text" => text,
            "start_time_ms" => "1793770000000",
            "speaker" => %{"id" => "ou_" <> speaker, "user_name" => speaker}
          }
        ]
      }
    }
  end

  defp chat(event_id, sender, text) do
    %{
      "event_id" => event_id,
      "event_type" => "chat_received",
      "payload" => %{
        "chat_received_items" => [
          %{
            "content" => text,
            "send_time" => "1793770001000",
            "operator" => %{"id" => "ou_" <> sender, "user_name" => sender}
          }
        ]
      }
    }
  end

  defp meeting_id! do
    assert {:ok, [id]} = Store.list()
    id
  end

  defp state!(id) do
    assert {:ok, %{"state" => state}, _etag} = Store.get(id)
    state
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
