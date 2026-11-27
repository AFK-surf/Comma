defmodule SalixIM.LarkSuiteTriageTest do
  @moduledoc """
  Feishu and Lark group triage end to end: a verified callback through
  `SalixIM.ProviderHTTP` (Feishu) or `SalixIM.LarkInbound` (Lark), the debounce
  batch, `SalixIM.LarkSuiteTriage.Worker.process_once/1`, and the provider
  writes, against a local Plug standing in for the open platform. The model is
  a test evaluator.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.{LarkInbound, LarkSuiteTriage, LarkThreads, ProviderHTTP}
  alias SalixIM.LarkSuiteTriage.Worker
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Keys, Repo}
  alias SalixStore.LarkSuiteTriage, as: Store

  @bot "ou_bot"
  @chat "oc_rd"

  defmodule Platform do
    @moduledoc false
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{routes: %{}, requests: []} end, name: __MODULE__)

    def route(path, data), do: Agent.update(__MODULE__, &put_in(&1, [:routes, path], data))

    def requests(path),
      do:
        Agent.get(__MODULE__, &Enum.filter(Enum.reverse(&1.requests), fn r -> r.path == path end))

    def writes,
      do:
        Agent.get(
          __MODULE__,
          &Enum.filter(Enum.reverse(&1.requests), fn r -> r.method == "POST" end)
        )

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      path = String.replace_prefix(conn.request_path, "/open-apis", "")

      request = %{
        method: conn.method,
        path: path,
        body: if(raw == "", do: nil, else: Jason.decode!(raw))
      }

      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})

      {status, body} =
        case Agent.get(__MODULE__, &Map.get(&1.routes, path)) do
          nil -> {400, %{"code" => 232_011, "msg" => "no access"}}
          data -> {200, %{"code" => 0, "msg" => "success", "data" => data}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  # The model: what the test put under `:lark_triage_test_decision`, a
  # function of the request and the archive identity.
  defmodule Evaluator do
    @moduledoc false
    def evaluate(request, identity) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :lark_triage_test_owner),
        {:evaluated, request, identity}
      )

      SystemsRuntime.fetch_env!(:salix_im, :lark_triage_test_decision).(request, identity)
    end
  end

  defmodule NoWorker do
    @moduledoc false
    def delegate(_batch, _connect, _decision), do: {:error, :worker_unavailable}
  end

  defmodule Delegator do
    @moduledoc false
    def delegate(batch, _connect, decision) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :lark_triage_test_owner),
        {:delegated, batch.id, decision}
      )

      {:ok, "cnv1_triage_task"}
    end
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    Repo.query!(
      "TRUNCATE lark_suite_triage_sources, lark_suite_triage_chats, lark_suite_triage_batches"
    )

    keys = [
      :lark_api_base_url,
      :feishu_api_base_url,
      :lark_triage_test_owner,
      :lark_triage_test_decision
    ]

    previous = for key <- keys, do: {key, SystemsRuntime.get_env(:salix_im, key)}

    start_supervised!(Platform)
    port = BanditServer.start!(fn p -> {Bandit, plug: Platform, port: p} end)
    base = "http://127.0.0.1:#{port}/open-apis"
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, base)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, base)
    SystemsRuntime.put_env(:salix_im, :lark_triage_test_owner, SystemsRuntime.Proc.self())
    SalixIM.Provider.Lark.API.reset_token_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:salix_im, key)
        {key, value} -> SystemsRuntime.put_env(:salix_im, key, value)
      end)

      SalixIM.Provider.Lark.API.reset_token_cache()
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    connects =
      Map.new(~w(feishu lark), fn provider ->
        connect = %{
          "provider" => provider,
          "tenant_id" => tenant,
          "group_id" => group,
          "connect_id" => "con_#{provider}_#{suffix}",
          "app_id" => "cli_#{provider}_#{suffix}",
          "app_name" => "研发助手",
          "app_secret" => "secret",
          "tenant_access_token" => "t-triage",
          "bot_open_id" => @bot,
          "events" => "socket",
          "status" => "connected",
          "created_at" => 1,
          "updated_at" => 1
        }

        {:ok, _created} =
          CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)

        {:ok, _source} =
          Store.upsert_source(%{
            tenant_id: tenant,
            provider: provider,
            connect_id: connect["connect_id"],
            group_id: group,
            router_agent_id: "agt_router_#{suffix}",
            enabled: true
          })

        {:ok, _chat} =
          Store.add_or_enable_chat(%{
            tenant_id: tenant,
            provider: provider,
            connect_id: connect["connect_id"],
            group_id: group,
            chat_id: @chat,
            chat_name: "研发群"
          })

        {provider, connect}
      end)

    Platform.route("/contact/v3/users/ou_alice", %{"user" => %{"name" => "王小明"}})

    {:ok, connects: connects, tenant: tenant}
  end

  defp decide(fun), do: SystemsRuntime.put_env(:salix_im, :lark_triage_test_decision, fun)

  defp envelope(id, opts \\ []) do
    message =
      %{
        "message_id" => id,
        "chat_id" => Keyword.get(opts, :chat, @chat),
        "chat_type" => "group",
        "message_type" => "text",
        "create_time" => "1795080000000",
        "content" => Jason.encode!(%{"text" => Keyword.get(opts, :text, "部署失败了，谁知道原因？")}),
        "mentions" => Keyword.get(opts, :mentions, [])
      }
      |> then(&if(t = opts[:thread], do: Map.put(&1, "thread_id", t), else: &1))

    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => "ev_" <> id,
        "event_type" => "im.message.receive_v1",
        "tenant_key" => "tk",
        "app_id" => "cli"
      },
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => Keyword.get(opts, :sender, "ou_alice")},
          "sender_type" => "user"
        },
        "message" => message
      }
    }
  end

  defp deliver("lark", connect, envelope), do: LarkInbound.handle_socket_event(connect, envelope)

  defp deliver("feishu", connect, envelope),
    do: ProviderHTTP.handle_feishu_socket_event(connect, envelope)

  defp batches,
    do:
      Repo.query!(
        "SELECT provider, message_ids, state FROM lark_suite_triage_batches ORDER BY inserted_at"
      ).rows

  # Past the debounce window of every batch the test made.
  defp later, do: [now: DateTime.add(SystemsClock.utc_now(), 60, :second)]

  defp run(opts \\ []),
    do: Worker.process_once(Keyword.merge(later() ++ [evaluator: Evaluator], opts))

  for provider <- ~w(feishu lark) do
    @provider provider

    test "#{provider}: only ambient messages of a watched chat are triaged", %{connects: connects} do
      connect = connects[@provider]
      mention = [%{"key" => "@_user_1", "id" => %{"open_id" => @bot}, "name" => "研发助手"}]

      assert {:ok, _ack} = deliver(@provider, connect, envelope("om_ambient"))
      # Addressed to the bot: the Router's, not triage's.
      _ =
        deliver(
          @provider,
          connect,
          envelope("om_mention", mentions: mention, text: "@_user_1 帮看下")
        )

      # A chat nobody watches.
      assert {:ok, _ack} = deliver(@provider, connect, envelope("om_other", chat: "oc_other"))

      assert [[@provider, ["om_ambient"], "collecting"]] = batches()
    end

    test "#{provider}: a reply goes in the thread of the newest message and joins it",
         %{connects: connects} do
      connect = connects[@provider]

      Platform.route("/im/v1/messages/om_2", %{
        "items" => [%{"message_id" => "om_2", "chat_id" => @chat}]
      })

      Platform.route("/im/v1/messages/om_2/reply", %{
        "message_id" => "om_bot_reply",
        "chat_id" => @chat,
        "thread_id" => "omt_new"
      })

      decide(fn request, _identity ->
        assert [%{"sender_name" => "王小明", "text" => "部署失败了，谁知道原因？"}, _] = request["messages"]
        {:ok, %{"kind" => "reply", "text" => "看起来是镜像拉取超时，重试即可。"}}
      end)

      assert {:ok, _ack} = deliver(@provider, connect, envelope("om_1"))
      assert {:ok, _ack} = deliver(@provider, connect, envelope("om_2", text: "日志在这"))

      assert [{_id, "applied"}] = run()
      assert_received {:evaluated, _request, identity}
      assert identity.session_id =~ "lark_suite_triage:#{connect["connect_id"]}:ltb_"

      assert [%{body: body}] = Platform.requests("/im/v1/messages/om_2/reply")
      assert body["reply_in_thread"] == true
      assert is_binary(body["uuid"])

      # The bot's thread now reaches the Router, not triage.
      joined? =
        case @provider do
          "lark" ->
            LarkThreads.joined?(connect, @chat, "omt_new")

          "feishu" ->
            SalixIM.ProviderConnects.feishu_thread_participating?(connect, @chat, "omt_new")
        end

      assert joined?
      # Its delivery to the Router fails here (no Router Group in this test):
      # what matters is that triage did not take it.
      _ = deliver(@provider, connect, envelope("om_3", thread: "omt_new"))
      assert [[_, _, "applied"]] = batches()
    end

    test "#{provider}: a reaction marks the newest message; silence writes nothing",
         %{connects: connects} do
      connect = connects[@provider]
      Platform.route("/im/v1/messages/om_1/reactions", %{"reaction_id" => "r1"})

      decide(fn _request, _identity ->
        {:ok, %{"kind" => "reaction", "emoji_type" => "thumbsup"}}
      end)

      deliver(@provider, connect, envelope("om_1"))
      assert [{_id, "applied"}] = run()

      assert [%{body: %{"reaction_type" => %{"emoji_type" => "THUMBSUP"}}}] =
               Platform.requests("/im/v1/messages/om_1/reactions")

      decide(fn _request, _identity ->
        {:ok, %{"kind" => "silence", "reason_code" => "already_handled"}}
      end)

      deliver(@provider, connect, envelope("om_9", thread: "omt_quiet"))
      writes = length(Platform.writes())
      assert [{_id, "applied"}] = run()
      assert length(Platform.writes()) == writes
    end
  end

  test "a person writing again while the model thinks makes the batch stale", %{
    connects: connects
  } do
    connect = connects["lark"]
    deliver("lark", connect, envelope("om_1"))

    decide(fn _request, _identity ->
      # The second message reaches Lark during the evaluation.
      {:ok, _ack} = deliver("lark", connect, envelope("om_2"))
      {:ok, %{"kind" => "reply", "text" => "回复"}}
    end)

    assert [{_id, "stale"}] = run()
    assert Platform.writes() == []

    # The newer batch is evaluated on its own.
    decide(fn _request, _identity ->
      {:ok, %{"kind" => "silence", "reason_code" => "no_useful_addition"}}
    end)

    assert [{_id, "applied"}] = run()
  end

  test "a chat paused while the model thinks gets no reaction", %{
    connects: connects,
    tenant: tenant
  } do
    connect = connects["feishu"]
    deliver("feishu", connect, envelope("om_1"))

    decide(fn _request, _identity ->
      {:ok, _chat} = Store.set_chat_enabled(tenant, "feishu", connect["connect_id"], @chat, false)
      {:ok, %{"kind" => "reaction", "emoji_type" => "OK"}}
    end)

    assert [{_id, "stale"}] = run()
    assert Platform.writes() == []

    # A paused chat collects nothing more.
    deliver("feishu", connect, envelope("om_2"))
    assert [[_, _, "stale"]] = batches()
  end

  test "a delegation creates a Task, and without a Task agent nothing is sent", %{
    connects: connects
  } do
    connect = connects["lark"]

    decide(fn _request, _identity ->
      {:ok, %{"kind" => "delegate", "task_title" => "排查部署失败", "task_prompt" => "查镜像拉取超时"}}
    end)

    deliver("lark", connect, envelope("om_1"))
    assert [{id, "applied"}] = run(task_delegator: Delegator)
    assert_received {:delegated, ^id, %{task_title: "排查部署失败"}}

    deliver("lark", connect, envelope("om_2", thread: "omt_2"))
    assert [{_id, "applied"}] = run(task_delegator: NoWorker)
    assert Platform.writes() == []

    assert [["cnv1_triage_task", nil], [nil, "worker_unavailable"]] =
             Repo.query!(
               "SELECT task_conversation_id, reason_code FROM lark_suite_triage_batches ORDER BY inserted_at"
             ).rows
  end

  test "an owner-only connect is never triaged", %{connects: connects} do
    connect = Map.merge(connects["lark"], %{"owner_only" => true, "owner_open_id" => "ou_alice"})

    assert :ok =
             LarkSuiteTriage.observe_ambient(
               "lark",
               connect,
               envelope("om_1")["event"]["message"],
               %{
                 "sender_type" => "user",
                 "sender_id" => %{"open_id" => "ou_alice"}
               }
             )

    assert batches() == []
  end

  test "message_text extracts readable text from interactive cards and falls back to [interactive]" do
    card_v2 = %{
      "message_type" => "interactive",
      "content" =>
        Jason.encode!(%{
          "header" => %{"title" => %{"tag" => "plain_text", "content" => "线上告警：支付超时"}},
          "elements" => [
            %{"tag" => "markdown", "content" => "P99 延迟超过 5s"},
            %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "请研发排查"}}
          ]
        })
    }

    extracted = LarkSuiteTriage.message_text(card_v2)
    assert extracted =~ "线上告警：支付超时"
    assert extracted =~ "P99 延迟超过 5s"
    assert extracted =~ "请研发排查"

    webhook_card = %{
      "message_type" => "interactive",
      "content" =>
        Jason.encode!(%{
          "title" => "工单通知",
          "elements" => [
            [%{"tag" => "text", "text" => "客户反馈无法登录"}]
          ]
        })
    }

    assert LarkSuiteTriage.message_text(webhook_card) =~ "工单通知"
    assert LarkSuiteTriage.message_text(webhook_card) =~ "客户反馈无法登录"

    empty_card = %{"message_type" => "interactive", "content" => Jason.encode!(%{})}
    assert LarkSuiteTriage.message_text(empty_card) == "[interactive]"
  end

  for provider <- ~w(feishu lark) do
    @provider provider

    test "#{provider}: evaluation includes bounded redacted recent_context and team_context, and degrades on history failure",
         %{connects: connects, tenant: tenant} do
      connect = connects[@provider]
      group_id = connect["group_id"]

      {:ok, _group} =
        CasRecord.create(Keys.ctl_group(group_id), %{
          "group_id" => group_id,
          "tenant_id" => tenant,
          "name" => "研发效能组",
          "description" => "负责 CI/CD 与发布平台排查",
          "router_conversation_id" => "cnv1_router_#{group_id}",
          "router_agent_id" => "agt_router"
        })

      history =
        for i <- 1..12 do
          %{
            "message_id" => "om_hist_#{i}",
            "create_time" => Integer.to_string(1_795_079_000_000 + i * 1_000),
            "sender" => %{"name" => "同事#{i}", "sender_type" => "user"},
            "text" =>
              if(i == 12,
                do: "token Bearer sk-secret-999 " <> String.duplicate("x", 600),
                else: "历史消息 #{i}"
              )
          }
        end ++
          [
            %{
              "message_id" => "om_cur_1",
              "create_time" => "1795080000000",
              "sender" => %{"name" => "王小明", "sender_type" => "user"},
              "text" => "当前消息"
            }
          ]

      provider_call = fn _prov, _agent_id, _conn, op, params ->
        case op do
          "get_chat_history" ->
            assert params["chat_id"] == @chat
            {:ok, %{"messages" => history}}

          "get_user" ->
            {:ok, %{"user" => %{"name" => "王小明"}}}

          _ ->
            {:error, :unexpected}
        end
      end

      decide(fn _request, _identity ->
        {:ok, %{"kind" => "silence", "reason_code" => "ambient_chatter"}}
      end)

      assert {:ok, _ack} = deliver(@provider, connect, envelope("om_cur_1", text: "当前消息"))
      assert [{_id, "applied"}] = run(provider_call: provider_call)
      assert_received {:evaluated, request, _identity}

      assert is_list(request["recent_context"])
      assert length(request["recent_context"]) == 10
      refute Enum.any?(request["recent_context"], &(&1["message_id"] == "om_cur_1"))
      last_ctx = List.last(request["recent_context"])
      assert last_ctx["message_id"] == "om_hist_12"
      refute last_ctx["text"] =~ "sk-secret-999"
      assert last_ctx["text"] =~ "[Bearer-credential withheld]"
      assert byte_size(last_ctx["text"]) <= 500
      assert request["team_context"] == %{"name" => "研发效能组", "description" => "负责 CI/CD 与发布平台排查"}

      # History failure degrades gracefully to empty list without failing evaluation.
      failing_call = fn _prov, _agent_id, _conn, op, _params ->
        case op do
          "get_chat_history" -> {:error, :timeout}
          "get_user" -> {:ok, %{"user" => %{"name" => "王小明"}}}
          _ -> {:error, :unexpected}
        end
      end

      assert {:ok, _ack} = deliver(@provider, connect, envelope("om_cur_2", text: "第二条"))
      assert [{_id, "applied"}] = run(provider_call: failing_call)
      assert_received {:evaluated, request2, _identity}
      assert request2["recent_context"] == []
    end
  end
end
