defmodule SalixIM.SlackHistoryMirrorTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  alias SalixIM.{SlackHistoryReader, SlackMessageMirror}
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Keys, SlackMirrorBackfillLedger}

  defmodule AuthorityOnly do
    use Plug.Builder
    plug(:dispatch)

    defp dispatch(conn, _) do
      send(
        Application.fetch_env!(:salix_im, :history_mirror_test_owner),
        {:slack_http, conn.request_path}
      )

      body =
        if conn.request_path == "/api/conversations.info" do
          %{
            "ok" => true,
            "channel" => %{
              "id" => "C1",
              "name" => "general",
              "is_member" => true,
              "is_private" => false,
              "is_archived" => false,
              "is_shared" => false,
              "is_ext_shared" => false,
              "is_org_shared" => false
            }
          }
        else
          %{"ok" => false, "error" => "history_http_forbidden"}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  defmodule Mirror do
    def history(scope, opts), do: read(:history, scope, nil, opts)
    def replies(scope, root, opts), do: read(:replies, scope, root, opts)

    defp read(kind, scope, root, opts) do
      send(
        Application.fetch_env!(:salix_im, :history_mirror_test_owner),
        {:mirror_read, kind, scope, root, opts}
      )

      Application.fetch_env!(:salix_im, :history_mirror_test_read).(kind, scope, root, opts)
    end
  end

  setup do
    keys = [
      :slack_api_base_url,
      :slack_triage_clickhouse_reader_mod,
      :slack_message_mirror_mod,
      :history_mirror_test_owner,
      :history_mirror_test_read
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:salix_im, &1)})
    previous_s3_backend = Application.fetch_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    on_exit(fn ->
      case previous_s3_backend do
        {:ok, backend} -> Application.put_env(:salix_store, :s3_backend, backend)
        :error -> Application.delete_env(:salix_store, :s3_backend)
      end
    end)

    :ok = SalixStore.S3.Fake.reset()
    port = BanditServer.start!(fn port -> {Bandit, plug: AuthorityOnly, port: port} end)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Mirror)
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :history_mirror_test_owner, self())

    Application.put_env(:salix_im, :history_mirror_test_read, fn _, _, _, _ ->
      {:ok,
       %{
         messages: [%{"ts" => "1787227200.000001", "user" => "U1", "text" => "Archived decision"}],
         next_cursor: nil,
         has_more?: false
       }}
    end)

    suffix = System.unique_integer([:positive])

    connect = %{
      "provider" => "slack",
      "tenant_id" => "mirror-tenant-#{suffix}",
      "group_id" => "mirror-group-#{suffix}",
      "connect_id" => "mirror-connect-#{suffix}",
      "connect_generation" => "g1",
      "workspace_id" => "T1",
      "app_id" => "A1",
      "bot_token" => "test-token",
      "oauth_completed_at" => 1,
      "created_at" => 1,
      "updated_at" => 1
    }

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(connect["group_id"], connect["connect_id"]), connect)

    scope = Map.take(connect, ~w(tenant_id workspace_id)) |> Map.put("channel_id", "C1")
    {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 120_000)

    :ok =
      SlackMirrorBackfillLedger.lower_watermark(
        scope,
        1_786_924_800_000_000,
        1_787_529_600_000_000
      )

    identity = %{
      tenant_id: connect["tenant_id"],
      group_id: connect["group_id"],
      connect_id: connect["connect_id"],
      channel_id: "C1"
    }

    {:ok, authority} = SlackHistoryReader.source_authority(identity)

    request =
      Map.merge(identity, %{
        expected_connect_generation: "g1",
        expected_workspace_id: "T1",
        expected_app_id: "A1",
        expected_channel_authority_revision: authority.channel.authority_revision,
        stream_kind: "history",
        root_ts: "",
        page_ordinal: 0,
        cursor: nil,
        range_start: ~U[2026-08-17 00:00:00Z],
        range_end: ~U[2026-08-24 00:00:00Z]
      })

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:salix_im, key),
          else: Application.put_env(:salix_im, key, value)
      end)

      SalixStore.Repo.query!("DELETE FROM slack_mirror_channel_watermarks WHERE tenant_id = $1", [
        connect["tenant_id"]
      ])
    end)

    {:ok, request: request, scope: scope, connect: connect}
  end

  test "onboarding reads archived messages, never Slack history HTTP", ctx do
    assert {:ok, page} = SlackHistoryReader.read_page(ctx.request)
    assert [%{"text" => "Archived decision"}] = page.messages
    assert page.stream_complete
    assert_receive {:mirror_read, :history, scope, nil, opts}
    assert scope == ctx.scope
    assert opts[:limit] == 15
    assert opts[:oldest] == "1786924800.000000"
    assert opts[:latest] == "1787529599.999999"
    refute_receive {:slack_http, "/api/conversations.history"}
    refute_receive {:slack_http, "/api/conversations.replies"}
  end

  test "disabled mirror and failed reads never fall back to Slack", ctx do
    Application.put_env(:salix_im, :slack_message_mirror_mod, SlackMessageMirror.Noop)
    assert {:error, :source_unavailable} = SlackHistoryReader.read_page(ctx.request)
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)

    Application.put_env(:salix_im, :history_mirror_test_read, fn _, _, _, _ ->
      {:error, :unavailable}
    end)

    assert {:error, :source_unavailable} = SlackHistoryReader.read_page(ctx.request)
    refute_receive {:slack_http, "/api/conversations.history"}
  end

  test "unwarmed range is not admitted as a complete empty history", ctx do
    request = %{ctx.request | range_start: ~U[2026-08-16 00:00:00Z]}
    assert {:error, :source_unavailable} = SlackHistoryReader.read_page(request)
    refute_receive {:mirror_read, _, _, _, _}
    refute_receive {:slack_http, "/api/conversations.history"}
  end

  test "reply pages use archive root and durable timestamp bounds", ctx do
    request =
      Map.merge(ctx.request, %{
        stream_kind: "replies",
        root_ts: "1787000000.000001",
        resume_boundary: "1787227100.000001"
      })

    assert {:ok, _} = SlackHistoryReader.read_page(request)
    assert_receive {:mirror_read, :replies, _, "1787000000.000001", opts}
    assert opts[:oldest] == "1787227100.000002"
    refute_receive {:slack_http, "/api/conversations.replies"}
  end

  test "missing channel coverage is unavailable, while a covered empty range is complete", ctx do
    Application.put_env(:salix_im, :history_mirror_test_read, fn _, _, _, _ ->
      {:ok, %{messages: [], next_cursor: nil, has_more?: false}}
    end)

    assert {:ok, %{messages: [], stream_complete: true}} =
             SlackHistoryReader.read_page(ctx.request)

    SalixStore.Repo.query!("DELETE FROM slack_mirror_channel_watermarks WHERE tenant_id = $1", [
      ctx.connect["tenant_id"]
    ])

    assert {:error, :source_unavailable} = SlackHistoryReader.read_page(ctx.request)
    refute_receive {:slack_http, "/api/conversations.history"}
  end

  test "an inconsistent archive cursor cannot declare the stream complete", ctx do
    Application.put_env(:salix_im, :history_mirror_test_read, fn _, _, _, _ ->
      {:ok, %{messages: [], next_cursor: nil, has_more?: true}}
    end)

    assert {:error, :invalid_provider_page} = SlackHistoryReader.read_page(ctx.request)
  end

  test "connect rotation during archive query discards its response", ctx do
    Application.put_env(:salix_im, :history_mirror_test_read, fn _, _, _, _ ->
      {:ok, _} =
        CasRecord.update(
          Keys.ctl_im_connect(ctx.connect["group_id"], ctx.connect["connect_id"]),
          &Map.put(&1, "connect_generation", "g2")
        )

      {:ok, %{messages: [], next_cursor: nil, has_more?: false}}
    end)

    assert {:error, :stale_source} = SlackHistoryReader.read_page(ctx.request)
  end

  @tag skip: is_nil(System.get_env("SALIX_TEST_CLICKHOUSE_URL"))
  test "real ClickHouse archive feeds onboarding parents and replies without Slack history",
       ctx do
    url = System.fetch_env!("SALIX_TEST_CLICKHOUSE_URL")
    database = "onboarding_mirror_test_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:salix_analytics, :clickhouse)
    Application.put_env(:salix_analytics, :clickhouse, base_url: url, table: "#{database}.events")

    on_exit(fn ->
      Req.post!(url, body: "DROP DATABASE IF EXISTS #{database}")

      if is_nil(previous),
        do: Application.delete_env(:salix_analytics, :clickhouse),
        else: Application.put_env(:salix_analytics, :clickhouse, previous)
    end)

    versions = [
      20_260_831_000_001,
      20_260_901_000_001,
      20_260_901_000_002,
      20_260_901_000_003,
      20_260_902_000_001,
      20_260_902_000_002,
      20_260_902_000_003,
      20_260_902_000_004,
      20_260_902_000_005,
      20_260_903_000_001
    ]

    assert {:ok, _} = SalixAnalytics.Migrations.migrate_versions(versions)
    Application.put_env(:salix_im, :slack_message_mirror_mod, SalixAnalytics.SlackMirror)

    Application.put_env(
      :salix_im,
      :slack_triage_clickhouse_reader_mod,
      SalixAnalytics.SlackMirror.Reader
    )

    root = %{
      "ts" => "1787227200.000001",
      "user" => "U1",
      "text" => "Archived parent",
      "reply_count" => 0
    }

    reply = %{
      "ts" => "1787227201.000001",
      "thread_ts" => root["ts"],
      "user" => "U2",
      "text" => "Archived reply"
    }

    rows =
      Enum.map([root, reply], fn message ->
        {:ok, row} = SalixIM.SlackMessageMirror.Row.from_history(ctx.connect, "C1", message)
        # Keep the low-millisecond formatter regression deterministic.
        Map.put(row, "ingest_at", "2026-09-02 05:38:41.042")
      end)

    assert :ok = SalixAnalytics.SlackMirror.record_batch(rows)

    assert {:ok, %{messages: [parent], stream_complete: true}} =
             SlackHistoryReader.read_page(ctx.request)

    assert parent["text"] == "Archived parent"
    assert parent["reply_count"] == 1
    request = Map.merge(ctx.request, %{stream_kind: "replies", root_ts: root["ts"]})

    assert {:ok, %{messages: [%{"text" => "Archived reply"}], stream_complete: true}} =
             SlackHistoryReader.read_page(request)

    refute_receive {:slack_http, "/api/conversations.history"}
    refute_receive {:slack_http, "/api/conversations.replies"}
  end
end
