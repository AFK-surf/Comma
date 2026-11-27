defmodule SalixIM.LarkDailyBriefSourceTest do
  @moduledoc """
  The daily brief's Lark source and surface (`SalixIM.LarkDailyBriefSource`,
  `SalixIM.LarkDailyBriefSurface`). A local Plug stands in for the open
  platform and a module for the message mirror.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.{LarkDailyBriefSource, LarkDailyBriefSurface}
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Keys}

  @provider "lark"
  @api SalixIM.Provider.Lark.API
  @base_key :lark_api_base_url
  @ledger SalixStore.LarkMirrorBackfillLedger
  @containers "lark_mirror_containers"
  @reader_keys [:lark_message_record_mod, :lark_message_record_reader_mod]
  @applink "https://applink.larksuite.com"

  @after_us 1_786_924_800_000_000
  @before_us 1_787_011_200_000_000

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

    def paths, do: Agent.get(__MODULE__, &Enum.map(Enum.reverse(&1.requests), fn r -> r.path end))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      path = String.replace_prefix(conn.request_path, "/open-apis", "")

      request = %{
        path: path,
        query: conn.query_params,
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

  defmodule Mirror do
    @moduledoc false
    def enabled?, do: true
    def record_batch(_rows), do: :ok

    def search(scope, opts) do
      note({:search, scope, opts})

      {:ok,
       %{
         messages: [
           row("om_root", 1_786_930_000_000_000, %{
             "actor_id" => "ou_bob",
             "content" =>
               Jason.encode!(%{
                 "content" => [[%{"tag" => "at", "user_id" => "ou_alice"}, %{"tag" => "text"}]]
               }),
             "text" => "@Alice 报价？"
           }),
           row("om_reply", 1_786_930_100_000_000, %{
             "root_id" => "om_root",
             "actor_id" => "ou_alice"
           }),
           row("om_bot", 1_786_930_200_000_000, %{
             "actor_kind" => "app",
             "actor_id" => "cli_bot",
             "content" =>
               Jason.encode!(%{
                 "elements" => [
                   %{"tag" => "markdown", "content" => ~s(<at id="ou_carol"></at> 部署好了)}
                 ]
               })
           })
         ],
         next_cursor: {1_786_930_200_000_000, "om_bot"},
         has_more?: true
       }}
    end

    def messages(scope, chat_id, ids) do
      note({:messages, scope, chat_id, ids})
      {:ok, [row("om_root", 1_786_900_000_000_000, %{"actor_id" => "ou_bob"})]}
    end

    def thread_participation(scope, actor_id, threads) do
      note({:participation, scope, actor_id, threads})
      {:ok, Enum.filter(threads, &(elem(&1, 1) == "om_root"))}
    end

    def actor_chat_counts(scope, actors, chats, after_us) do
      note({:counts, scope, actors, chats, after_us})
      {:ok, [{"oc_public", "ou_alice", 3}, {"oc_other", "ou_alice", 9}]}
    end

    defp note(message),
      do:
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_owner),
          {:mirror, message}
        )

    defp row(id, at_us, overrides) do
      Map.merge(
        %{
          "tenant_id" => "",
          "app_id" => "",
          "chat_id" => "oc_public",
          "message_id" => id,
          "create_time_us" => at_us,
          "version" => at_us * 2,
          "root_id" => "",
          "parent_id" => "",
          "thread_id" => "",
          "chat_type" => "group",
          "message_type" => "text",
          "actor_kind" => "user",
          "actor_id" => "",
          "actor_label" => "",
          "text" => "deployed",
          "content" => "",
          "file_count" => 0
        },
        overrides
      )
    end
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    keys =
      [
        @base_key,
        :daily_brief_test_owner,
        :lark_message_record_mod,
        :lark_message_record_reader_mod
      ] ++ @reader_keys

    previous = for key <- Enum.uniq(keys), do: {key, SystemsRuntime.get_env(:salix_im, key)}

    start_supervised!(Platform)
    port = BanditServer.start!(fn p -> {Bandit, plug: Platform, port: p} end)
    SystemsRuntime.put_env(:salix_im, @base_key, "http://127.0.0.1:#{port}/open-apis")
    Enum.each(@reader_keys, &SystemsRuntime.put_env(:salix_im, &1, Mirror))
    SystemsRuntime.put_env(:salix_im, :daily_brief_test_owner, SystemsRuntime.Proc.self())
    @api.reset_token_cache()

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    connect = %{
      "provider" => @provider,
      "tenant_id" => "tenant-brief-#{suffix}",
      "group_id" => "group-brief-#{suffix}",
      "connect_id" => "connect-brief-#{suffix}",
      "app_id" => "cli_brief_#{suffix}",
      "app_secret" => "secret",
      "tenant_access_token" => "t-brief",
      "created_at" => 1,
      "updated_at" => 1
    }

    {:ok, _created} =
      CasRecord.create(Keys.ctl_im_connect(connect["group_id"], connect["connect_id"]), connect)

    scope = %{"tenant_id" => connect["tenant_id"], "app_id" => connect["app_id"]}

    container = %{
      "container_type" => "chat",
      "container_id" => "oc_public",
      "chat_id" => "oc_public"
    }

    :ok = @ledger.upsert_containers(scope, [container])

    :ok =
      @ledger.commit_page(scope, container, %{
        "oldest_us" => @after_us - 1,
        "observed_us" => @before_us,
        "page_token" => nil,
        "exhausted" => true
      })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:salix_im, key)
        {key, value} -> SystemsRuntime.put_env(:salix_im, key, value)
      end)

      @api.reset_token_cache()

      SalixStore.Repo.query!("DELETE FROM #{@containers} WHERE tenant_id = $1", [
        connect["tenant_id"]
      ])
    end)

    chats()

    {:ok,
     scope: scope,
     source: %{
       tenant_id: connect["tenant_id"],
       group_id: connect["group_id"],
       connect_id: connect["connect_id"],
       provider: @provider
     }}
  end

  # The bot is in a public group, a private group, an external group, a
  # dissolved group, and a group whose details say it is external.
  defp chats do
    Platform.route("/im/v1/chats", %{
      "items" => [
        %{"chat_id" => "oc_public", "name" => "产品"},
        %{"chat_id" => "oc_private", "name" => "薪酬"},
        %{"chat_id" => "oc_external", "name" => "客户群", "external" => true},
        %{"chat_id" => "oc_gone", "name" => "旧群", "chat_status" => "dissolved"},
        %{"chat_id" => "oc_shared", "name" => "合作"}
      ],
      "has_more" => false
    })

    Platform.route("/im/v1/chats/oc_public", info("产品", "public"))
    Platform.route("/im/v1/chats/oc_private", info("薪酬", "private"))
    Platform.route("/im/v1/chats/oc_external", info("客户群", "public", true))

    Platform.route(
      "/im/v1/chats/oc_gone",
      Map.put(info("旧群", "public"), "chat_status", "dissolved")
    )

    Platform.route("/im/v1/chats/oc_shared", info("合作", "public", true))

    for chat <- ~w(oc_public oc_private oc_external oc_gone oc_shared),
        do: Platform.route("/im/v1/chats/#{chat}/members/is_in_chat", %{"is_in_chat" => true})
  end

  defp info(name, type, external \\ false),
    do: %{"name" => name, "chat_mode" => "group", "chat_type" => type, "external" => external}

  defp window(source, chat),
    do:
      Map.merge(source, %{
        channel_id: chat,
        after_us: @after_us,
        before_us: @before_us,
        limit: 200
      })

  test "only internal public groups the bot is in are readable", ctx do
    assert {:ok, %{channels: [%{id: "oc_public", name: "产品"}], complete?: true, gaps: gaps}} =
             LarkDailyBriefSource.channels(Map.put(ctx.source, :member_open_ids, ["ou_alice"]))

    # Lark shows the bot none of a member's own chats.
    assert gaps == %{"ou_alice" => %{channels: [], complete?: true}}
    # A dissolved or listed-external group is dropped before its details are read.
    refute "/im/v1/chats/oc_gone" in Platform.paths()
    refute "/im/v1/chats/oc_external" in Platform.paths()
  end

  test "a window reads the mirror of a readable group only", ctx do
    assert {:ok, %{messages: [root, reply, bot], has_more?: true, next_cursor: cursor}} =
             LarkDailyBriefSource.read_window(window(ctx.source, "oc_public"))

    assert_received {:mirror, {:search, scope, opts}}
    assert scope == ctx.scope
    assert opts[:chat_id] == "oc_public" and opts[:sort_dir] == :asc
    assert opts[:after_us] == @after_us and opts[:before_us] == @before_us

    assert %{channel_id: "oc_public", ts: "om_root", thread_ts: nil, actor_id: "ou_bob"} = root
    assert root.at_us == 1_786_930_000_000_000
    assert root.mentions == ["ou_alice"]
    assert %{ts: "om_reply", thread_ts: "om_root", actor_kind: "user"} = reply
    assert bot.actor_kind == "bot"
    # A card names who it mentions inline in its Markdown.
    assert bot.mentions == ["ou_carol"]
    assert cursor == %{ts_us: 1_786_930_200_000_000, message_id: "om_bot"}

    # The cursor continues the same read.
    assert {:ok, _page} =
             LarkDailyBriefSource.read_window(
               Map.put(window(ctx.source, "oc_public"), :cursor, cursor)
             )

    assert_received {:mirror, {:search, _scope, next}}
    assert next[:cursor_ts_us] == 1_786_930_200_000_000 and next[:cursor_message_id] == "om_bot"
  end

  test "a private or external group is never read", ctx do
    for chat <- ~w(oc_private oc_shared oc_gone) do
      assert LarkDailyBriefSource.read_window(window(ctx.source, chat)) ==
               {:error, :channel_ineligible}

      assert LarkDailyBriefSource.messages(
               Map.merge(ctx.source, %{channel_id: chat, ts: ["om_1"]})
             ) ==
               {:error, :channel_ineligible}
    end

    refute_received {:mirror, _read}
  end

  test "a group the history walk has not reached fails closed", ctx do
    # A public group the bot joined after the last walk: nothing is known of its history.
    Platform.route("/im/v1/chats/oc_new", info("新群", "public"))
    Platform.route("/im/v1/chats/oc_new/members/is_in_chat", %{"is_in_chat" => true})

    assert LarkDailyBriefSource.read_window(window(ctx.source, "oc_new")) ==
             {:error, :source_unavailable}

    refute_received {:mirror, _read}
  end

  test "another tenant's request reads nothing", ctx do
    assert LarkDailyBriefSource.read_window(%{
             window(ctx.source, "oc_public")
             | tenant_id: "other"
           }) ==
             {:error, :source_unavailable}

    assert LarkDailyBriefSource.channels(%{ctx.source | tenant_id: "other"}) ==
             {:error, :source_unavailable}
  end

  test "member threads and channel activity are counts and ids only", ctx do
    threads = [
      %{channel_id: "oc_public", thread_ts: "om_root"},
      %{channel_id: "oc_public", thread_ts: "om_other"}
    ]

    assert {:ok, %{threads: [%{channel_id: "oc_public", thread_ts: "om_root"}], complete?: true}} =
             LarkDailyBriefSource.member_threads(
               Map.merge(ctx.source, %{open_id: "ou_alice", threads: threads})
             )

    assert {:ok,
            %{
              "ou_alice" => [
                %{channel_id: "oc_other", count: 9},
                %{channel_id: "oc_public", count: 3}
              ]
            }} =
             LarkDailyBriefSource.active_channels(
               Map.merge(ctx.source, %{
                 open_ids: ["ou_alice"],
                 channel_ids: ["oc_public", "oc_other"],
                 after_us: 0
               })
             )
  end

  test "people resolve by email; frozen and resigned people do not", ctx do
    Platform.route("/contact/v3/users/batch_get_id", %{
      "user_list" => [
        %{"email" => "alice@acme.test", "user_id" => "ou_alice"},
        %{"email" => "frank@acme.test", "user_id" => "ou_frank"},
        %{"email" => "carol@acme.test"}
      ]
    })

    Platform.route("/contact/v3/users/ou_alice", %{
      "user" => %{
        "name" => "Alice",
        "en_name" => "Alice Wu",
        "status" => %{"is_activated" => true}
      }
    })

    Platform.route("/contact/v3/users/ou_frank", %{
      "user" => %{"name" => "Frank", "status" => %{"is_frozen" => true}}
    })

    assert {:ok, found} =
             LarkDailyBriefSource.lookup_members(
               Map.put(ctx.source, :emails, [
                 "Alice@acme.test",
                 "frank@acme.test",
                 "carol@acme.test"
               ])
             )

    assert Map.keys(found) == ["alice@acme.test"]

    assert %{open_id: "ou_alice", names: ["Alice", "Alice Wu"], timezone: tz} =
             found["alice@acme.test"]

    assert tz == LarkDailyBriefSource.provider().default_timezone

    assert {:ok, %{"ou_alice" => "Alice"}} =
             LarkDailyBriefSource.user_names(
               Map.put(ctx.source, :user_ids, ["ou_alice", "C_SLACK"])
             )
  end

  test "links open the message's group, for readable groups only", ctx do
    assert {:ok, links} =
             LarkDailyBriefSource.permalinks(
               Map.put(ctx.source, :messages, [
                 %{channel_id: "oc_public", ts: "om_root"},
                 %{channel_id: "oc_private", ts: "om_secret"}
               ])
             )

    assert links == %{
             {"oc_public", "om_root"} => @applink <> "/client/chat/open?openChatId=oc_public"
           }
  end

  test "a member's brief goes to their open id; the team brief only to a readable group", ctx do
    Platform.route("/im/v1/messages", %{"message_id" => "om_sent", "chat_id" => "oc_dm"})
    card = %{"elements" => [%{"tag" => "markdown", "content" => "hi"}]}

    assert {:ok, %{channel_id: "oc_dm", ts: "om_sent"}} =
             LarkDailyBriefSurface.post(Map.merge(ctx.source, %{open_id: "ou_alice", card: card}))

    assert [sent] = Platform.requests("/im/v1/messages")
    assert sent.query == %{"receive_id_type" => "open_id"}
    assert sent.body["receive_id"] == "ou_alice" and sent.body["msg_type"] == "interactive"
    assert Jason.decode!(sent.body["content"]) == card

    assert LarkDailyBriefSurface.post(
             Map.merge(ctx.source, %{channel_id: "oc_private", card: card})
           ) ==
             {:error, :channel_ineligible}

    assert length(Platform.requests("/im/v1/messages")) == 1

    assert {:ok, %{ts: "om_sent"}} =
             LarkDailyBriefSurface.post(
               Map.merge(ctx.source, %{channel_id: "oc_public", card: card})
             )

    assert [_dm, team] = Platform.requests("/im/v1/messages")

    assert team.query == %{"receive_id_type" => "chat_id"} and
             team.body["receive_id"] == "oc_public"
  end
end
