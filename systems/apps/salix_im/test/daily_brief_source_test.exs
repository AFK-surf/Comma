defmodule SalixIM.DailyBriefSourceTest do
  use SystemsClock.Case, async: false

  import Plug.Conn

  alias SalixIM.DailyBriefSource
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Keys, SlackMirrorBackfillLedger}

  defmodule Mirror do
    def latest_states(scope, keys) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:mirror_states, scope, keys})

      rows = [
        row("1786930000.000100", %{"actor_id" => "U_BOB", "text" => "<@U_ALICE> quote?"}),
        row("1786930000.000200", %{"deleted" => true, "text" => ""}),
        row("1786930000.000300", %{"actor_kind" => "bot", "actor_id" => "B_DEPLOY"})
      ]

      {:ok,
       rows |> Enum.filter(&(&1["message_ts_us"] in keys)) |> Map.new(&{&1["message_ts_us"], &1})}
    end

    defp row(ts, overrides) do
      [seconds, micros] = String.split(ts, ".")

      Map.merge(
        %{
          "channel_id" => "C_PUBLIC",
          "message_ts" => ts,
          "message_ts_us" => String.to_integer(seconds) * 1_000_000 + String.to_integer(micros),
          "thread_ts" => "",
          "deleted" => false,
          "actor_kind" => "user",
          "subtype" => "",
          "text" => "deployed"
        },
        overrides
      )
    end

    def search(scope, opts) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:mirror_search, scope, opts})
      SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_search).(opts)
    end

    def thread_participation(scope, actor_id, threads) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:mirror_participation, scope, actor_id, threads})
      {:ok, Enum.filter(threads, &(elem(&1, 1) in ["1.0", "5.0"]))}
    end

    def actor_channel_counts(scope, actors, channels, after_us) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:mirror_counts, scope, actors, channels, after_us})
      {:ok, [{"C_PUBLIC", "U_ALICE", 3}, {"C_OTHER", "U_ALICE", 12}, {"C_PUBLIC", "U_BOB", 7}]}
    end
  end

  defmodule SlackLoopback do
    use Plug.Builder

    plug(Plug.Parsers, parsers: [:urlencoded])
    plug(:dispatch)

    defp dispatch(conn, _opts) do
      conn = fetch_query_params(conn)
      owner = SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_owner)
      SystemsRuntime.Proc.send(owner, {:slack, conn.request_path, conn.params})

      body =
        SystemsRuntime.fetch_env!(:salix_im, :daily_brief_test_slack).(
          conn.request_path,
          conn.params
        )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  @after_us 1_786_924_800_000_000
  @before_us 1_787_011_200_000_000

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    previous =
      for key <- [
            :slack_api_base_url,
            :slack_triage_clickhouse_reader_mod,
            :slack_message_mirror_mod,
            :daily_brief_test_owner,
            :daily_brief_test_slack,
            :daily_brief_test_search
          ],
          do: {key, SystemsRuntime.get_env(:salix_im, key)}

    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :daily_brief_test_owner, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_im, :daily_brief_test_slack, &slack/2)
    SystemsRuntime.put_env(:salix_im, :daily_brief_test_search, fn _opts -> {:ok, page([])} end)
    port = BanditServer.start!(fn port -> {Bandit, plug: SlackLoopback, port: port} end)
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    connect = %{
      "provider" => "slack",
      "tenant_id" => "tenant-brief-#{suffix}",
      "group_id" => "group-brief-#{suffix}",
      "connect_id" => "connect-brief-#{suffix}",
      "connect_generation" => "generation-1",
      "workspace_id" => "T_BRIEF",
      "app_id" => "A_BRIEF",
      "bot_token" => "xoxb-brief-test",
      "oauth_completed_at" => 1,
      "created_at" => 1,
      "updated_at" => 1
    }

    {:ok, _created} =
      CasRecord.create(Keys.ctl_im_connect(connect["group_id"], connect["connect_id"]), connect)

    scope = Map.take(connect, ~w(tenant_id workspace_id)) |> Map.put("channel_id", "C_PUBLIC")
    {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 120_000)
    :ok = SlackMirrorBackfillLedger.lower_watermark(scope, @after_us - 1, @before_us)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> SystemsRuntime.delete_env(:salix_im, key)
        {key, value} -> SystemsRuntime.put_env(:salix_im, key, value)
      end)

      SalixStore.Repo.query!("DELETE FROM slack_mirror_channel_watermarks WHERE tenant_id = $1", [
        connect["tenant_id"]
      ])
    end)

    {:ok,
     source: %{
       tenant_id: connect["tenant_id"],
       group_id: connect["group_id"],
       connect_id: connect["connect_id"]
     }}
  end

  test "lists only public unshared bot channels and each member's gap", ctx do
    assert {:ok, result} =
             DailyBriefSource.channels(Map.put(ctx.source, :member_slack_ids, ["U_ALICE"]))

    assert result.channels == [%{id: "C_PUBLIC", name: "public"}]
    assert result.complete?

    assert result.gaps["U_ALICE"] == %{
             channels: [%{id: "C_NOBOT", name: "nobot"}],
             complete?: true
           }

    assert_received {:slack, "/api/users.conversations", %{"user" => "U_ALICE"}}
  end

  test "reads a public channel's window from the mirror", ctx do
    SystemsRuntime.put_env(:salix_im, :daily_brief_test_search, fn _opts ->
      {:ok,
       page([
         %{
           "type" => "message",
           "channel" => "C_PUBLIC",
           "ts" => "1786930000.000100",
           "user" => "U_BOB",
           "text" => "<@U_ALICE> can you send the quote?"
         },
         %{
           "type" => "message",
           "channel" => "C_PUBLIC",
           "ts" => "1786930000.000200",
           "bot_id" => "B_DEPLOY",
           "subtype" => "bot_message",
           "text" => "deployed"
         }
       ])}
    end)

    assert {:ok, %{messages: [message, bot], has_more?: false}} =
             DailyBriefSource.read_window(window(ctx.source, "C_PUBLIC"))

    assert message == %{
             channel_id: "C_PUBLIC",
             ts: "1786930000.000100",
             thread_ts: nil,
             actor_kind: "user",
             actor_id: "U_BOB",
             subtype: nil,
             text: "<@U_ALICE> can you send the quote?",
             reactions: []
           }

    assert bot.actor_kind == "bot"
    assert bot.actor_id == "B_DEPLOY"

    assert_received {:mirror_search, %{"tenant_id" => _, "workspace_id" => "T_BRIEF"}, opts}
    assert opts[:channel_id] == "C_PUBLIC"
    assert opts[:after_us] == @after_us
    assert opts[:before_us] == @before_us
  end

  test "reads named messages of a readable channel, without deleted ones", ctx do
    request =
      Map.merge(ctx.source, %{
        channel_id: "C_PUBLIC",
        ts: ["1786930000.000300", "1786930000.000100", "1786930000.000200", "1786930000.000900"]
      })

    assert {:ok, %{messages: [message, bot]}} = DailyBriefSource.messages(request)

    assert message == %{
             channel_id: "C_PUBLIC",
             ts: "1786930000.000100",
             thread_ts: nil,
             actor_kind: "user",
             actor_id: "U_BOB",
             subtype: nil,
             text: "<@U_ALICE> quote?"
           }

    assert bot.actor_kind == "bot"

    assert_received {:mirror_states, %{"channel_id" => "C_PUBLIC", "workspace_id" => "T_BRIEF"},
                     keys}

    assert 1_786_930_000_000_100 in keys

    assert {:error, :channel_ineligible} =
             DailyBriefSource.messages(%{request | channel_id: "C_PRIVATE"})

    assert {:error, :invalid_request} =
             DailyBriefSource.messages(%{request | ts: ["not-a-ts"]})
  end

  test "never reads a private, shared, or direct conversation", ctx do
    for channel <- ["C_PRIVATE", "C_SHARED", "D_DIRECT"] do
      assert DailyBriefSource.read_window(window(ctx.source, channel)) ==
               {:error, :channel_ineligible}
    end

    refute_received {:mirror_search, _scope, _opts}
  end

  test "reports an uncovered window instead of reading a partial archive", ctx do
    request = %{window(ctx.source, "C_PUBLIC") | after_us: @after_us - 86_400_000_000}

    assert DailyBriefSource.read_window(request) == {:error, :source_unavailable}
    refute_received {:mirror_search, _scope, _opts}
  end

  test "names the given threads the member wrote in, in one read", ctx do
    threads = [
      %{channel_id: "C_PUBLIC", thread_ts: "1.0"},
      %{channel_id: "C_PUBLIC", thread_ts: "3.0"},
      %{channel_id: "C_OTHER", thread_ts: "5.0"},
      %{channel_id: "C_PUBLIC", thread_ts: "1.0"}
    ]

    assert {:ok, %{threads: found, complete?: true}} =
             DailyBriefSource.member_threads(
               Map.merge(ctx.source, %{slack_user_id: "U_ALICE", threads: threads})
             )

    assert found == [
             %{channel_id: "C_PUBLIC", thread_ts: "1.0"},
             %{channel_id: "C_OTHER", thread_ts: "5.0"}
           ]

    assert_received {:mirror_participation, _scope, "U_ALICE",
                     [{"C_PUBLIC", "1.0"}, {"C_PUBLIC", "3.0"}, {"C_OTHER", "5.0"}]}

    refute_received {:mirror_search, _scope, _opts}
  end

  test "reads nothing when the window has no threads", ctx do
    assert {:ok, %{threads: [], complete?: true}} =
             DailyBriefSource.member_threads(
               Map.merge(ctx.source, %{slack_user_id: "U_ALICE", threads: []})
             )

    refute_received {:mirror_participation, _scope, _actor, _threads}
  end

  test "refuses more threads than one read takes", ctx do
    threads = for n <- 1..501, do: %{channel_id: "C_PUBLIC", thread_ts: "#{n}.0"}

    assert DailyBriefSource.member_threads(
             Map.merge(ctx.source, %{slack_user_id: "U_ALICE", threads: threads})
           ) == {:error, :invalid_request}
  end

  test "counts each member's recent messages per channel, most first", ctx do
    assert {:ok, active} =
             DailyBriefSource.active_channels(
               Map.merge(ctx.source, %{
                 slack_user_ids: ["U_ALICE", "U_BOB"],
                 channel_ids: ["C_PUBLIC", "C_OTHER"],
                 after_us: @after_us
               })
             )

    assert active == %{
             "U_ALICE" => [
               %{channel_id: "C_OTHER", count: 12},
               %{channel_id: "C_PUBLIC", count: 3}
             ],
             "U_BOB" => [%{channel_id: "C_PUBLIC", count: 7}]
           }

    assert_received {:mirror_counts, _scope, ["U_ALICE", "U_BOB"], ["C_PUBLIC", "C_OTHER"],
                     @after_us}
  end

  test "rejects a connect from another tenant", ctx do
    assert DailyBriefSource.read_window(%{window(ctx.source, "C_PUBLIC") | tenant_id: "other"}) ==
             {:error, :source_unavailable}
  end

  defp window(source, channel_id),
    do:
      Map.merge(source, %{
        channel_id: channel_id,
        after_us: @after_us,
        before_us: @before_us,
        limit: 50
      })

  defp page(messages), do: %{messages: messages, next_cursor: nil, has_more?: false}

  defp slack("/api/users.conversations", %{"user" => "U_ALICE"}) do
    %{
      "ok" => true,
      "channels" => [
        channel("C_PUBLIC", "public"),
        channel("C_NOBOT", "nobot", %{"is_member" => false}),
        channel("C_SHARED", "shared", %{"is_ext_shared" => true})
      ],
      "response_metadata" => %{"next_cursor" => ""}
    }
  end

  defp slack("/api/users.conversations", _params) do
    %{
      "ok" => true,
      "channels" =>
        Enum.map(
          [
            channel("C_PUBLIC", "public"),
            channel("C_PRIVATE", "private", %{"is_private" => true}),
            channel("C_SHARED", "shared", %{"is_shared" => true})
          ],
          &Map.delete(&1, "is_member")
        ),
      "response_metadata" => %{"next_cursor" => ""}
    }
  end

  defp slack("/api/conversations.info", %{"channel" => "C_PRIVATE"}),
    do: %{"ok" => true, "channel" => channel("C_PRIVATE", "private", %{"is_private" => true})}

  defp slack("/api/conversations.info", %{"channel" => "C_SHARED"}),
    do: %{"ok" => true, "channel" => channel("C_SHARED", "shared", %{"is_shared" => true})}

  defp slack("/api/conversations.info", %{"channel" => "D_DIRECT"}),
    do: %{"ok" => true, "channel" => %{"id" => "D_DIRECT", "is_im" => true, "user" => "U_BOB"}}

  defp slack("/api/conversations.info", %{"channel" => id}),
    do: %{"ok" => true, "channel" => channel(id, "public")}

  defp channel(id, name, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "is_member" => true,
        "is_private" => false,
        "is_archived" => false,
        "is_shared" => false,
        "is_ext_shared" => false,
        "is_org_shared" => false
      },
      overrides
    )
  end
end
