defmodule SalixIM.SlackHistoryReaderTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  import Plug.Conn

  alias SalixIM.SlackHistoryReader
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Keys, SlackMirrorBackfillLedger}

  # Preserve the normalization/bounds/authority scenarios against the archive
  # seam. The separate mirror integration suite forbids history HTTP outright.
  defmodule Mirror do
    def history(scope, opts), do: read("history", scope, nil, opts)
    def replies(scope, root, opts), do: read("replies", scope, root, opts)

    defp read(kind, scope, root, opts) do
      query =
        opts
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

      query = Map.put(query, "channel", scope["channel_id"])
      query = if root, do: Map.put(query, "ts", root), else: query
      handler = SystemsRuntime.fetch_env!(:salix_im, :slack_history_test_handler)

      {_, _, body} =
        handler.(%Plug.Conn{request_path: "/api/conversations." <> kind, query_params: query})

      if body["ok"] do
        cursor = get_in(body, ["response_metadata", "next_cursor"])
        cursor = if cursor in [nil, ""], do: nil, else: cursor
        {:ok, %{messages: body["messages"], next_cursor: cursor, has_more?: not is_nil(cursor)}}
      else
        {:error, :unavailable}
      end
    end
  end

  defmodule SlackLoopback do
    use Plug.Builder

    plug(:dispatch)

    defp dispatch(conn, _opts) do
      conn = fetch_query_params(conn)
      handler = SystemsRuntime.fetch_env!(:salix_im, :slack_history_test_handler)
      {status, headers, body} = handler.(conn)

      headers
      |> Enum.reduce(conn, fn {key, value}, acc -> put_resp_header(acc, key, value) end)
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    previous_base_url = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)
    previous_handler = SystemsRuntime.get_env(:salix_im, :slack_history_test_handler)
    previous_reader = SystemsRuntime.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
    previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    port = BanditServer.start!(fn port -> {Bandit, plug: SlackLoopback, port: port} end)
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    connect = %{
      "provider" => "slack",
      "tenant_id" => "tenant-history-#{suffix}",
      "group_id" => "group-history-#{suffix}",
      "connect_id" => "connect-history-#{suffix}",
      "connect_generation" => "generation-1",
      "workspace_id" => "T_HISTORY",
      "app_id" => "A_HISTORY",
      "bot_token" => "xoxb-history-test",
      "oauth_completed_at" => 1,
      "created_at" => 1,
      "updated_at" => 1
    }

    {:ok, _created} =
      CasRecord.create(Keys.ctl_im_connect(connect["group_id"], connect["connect_id"]), connect)

    scope = Map.take(connect, ~w(tenant_id workspace_id)) |> Map.put("channel_id", "C_HISTORY")
    {:ok, _} = SlackMirrorBackfillLedger.claim_channel(scope, 120_000)

    :ok =
      SlackMirrorBackfillLedger.lower_watermark(
        scope,
        1_786_924_800_000_000,
        1_787_529_600_000_000
      )

    owner = SystemsRuntime.Proc.self()
    SystemsRuntime.put_env(:salix_im, :slack_history_test_handler, success_handler(owner))

    on_exit(fn ->
      restore_env(:salix_im, :slack_api_base_url, previous_base_url)
      restore_env(:salix_im, :slack_history_test_handler, previous_handler)
      restore_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous_reader)
      restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)

      SalixStore.Repo.query!("DELETE FROM slack_mirror_channel_watermarks WHERE tenant_id = $1", [
        connect["tenant_id"]
      ])
    end)

    {:ok, connect: connect}
  end

  test "returns one bounded normalized page only after source and channel post-fences", ctx do
    assert {:ok, authority} = SlackHistoryReader.source_authority(identity_request(ctx.connect))
    assert authority.workspace_id == "T_HISTORY"
    assert authority.app_id == "A_HISTORY"
    assert authority.channel.visibility == "public"
    assert authority.channel.is_member == true
    assert byte_size(authority.channel.authority_revision) == 64

    request = page_request(ctx.connect, authority.channel.authority_revision)
    assert {:ok, page} = SlackHistoryReader.read_page(request)

    assert page.channel_id == "C_HISTORY"
    assert page.stream_kind == "history"
    assert page.page_ordinal == 0
    assert page.request_cursor == nil
    assert page.next_cursor == "1787227200.000001"
    assert page.stream_complete == false
    assert page.accepted_connect_generation == "generation-1"
    assert page.accepted_channel_authority_revision == authority.channel.authority_revision
    assert byte_size(page.response_sha256) == 64

    assert [message] = page.messages
    assert message["actor_id"] == "U_HISTORY"
    assert message["actor_kind"] == "user"
    assert message["observable_version"] == "edited:1787227201.000001"

    assert message["file_metadata"] == [
             %{"id" => "F1", "mimetype" => "text/plain", "name" => "plan.txt", "size" => 12}
           ]

    settle_receive({:slack_history_request, "/api/conversations.history", query})
    assert query["limit"] == "15"
    assert query["oldest"] == "1786924800.000000"
    assert query["latest"] == "1787529599.999999"
    assert query["inclusive"] == "true"
  end

  test "fails closed before history transport for a shared public channel", ctx do
    owner = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_im, :slack_history_test_handler, fn conn ->
      SystemsRuntime.Proc.send(owner, {:shared_channel_request, conn.request_path})
      {status, headers, body} = success_response(conn)

      if conn.request_path == "/api/conversations.info" do
        {status, headers, put_in(body, ["channel", "is_ext_shared"], true)}
      else
        {status, headers, body}
      end
    end)

    assert SlackHistoryReader.source_authority(identity_request(ctx.connect)) ==
             {:error, :channel_ineligible}

    settle_receive({:shared_channel_request, "/api/conversations.info"})
    settle_refute_receive({:shared_channel_request, _other_path}, 50)
  end

  test "fails closed before history transport when the bot membership is absent", ctx do
    owner = SystemsRuntime.Proc.self()

    Enum.each([false, nil], fn membership ->
      SystemsRuntime.put_env(:salix_im, :slack_history_test_handler, fn conn ->
        SystemsRuntime.Proc.send(owner, {:membership_request, membership, conn.request_path})
        {status, headers, body} = success_response(conn)

        if conn.request_path == "/api/conversations.info" do
          channel =
            if is_nil(membership),
              do: Map.delete(body["channel"], "is_member"),
              else: put_in(body, ["channel", "is_member"], membership)["channel"]

          {status, headers, put_in(body, ["channel"], channel)}
        else
          {status, headers, body}
        end
      end)

      assert SlackHistoryReader.source_authority(identity_request(ctx.connect)) ==
               {:error, :channel_ineligible}

      settle_receive({:membership_request, ^membership, "/api/conversations.info"})
      settle_refute_receive({:membership_request, ^membership, _other_path}, 50)
    end)
  end

  test "discards an archive response when the connect generation changes in flight",
       ctx do
    owner = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(:salix_im, :slack_history_test_handler, fn conn ->
      if conn.request_path == "/api/conversations.history" do
        SystemsRuntime.Proc.send(owner, {:history_blocked, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :release_history -> success_response(conn)
        end
      else
        success_response(conn)
      end
    end)

    assert {:ok, authority} = SlackHistoryReader.source_authority(identity_request(ctx.connect))
    request = page_request(ctx.connect, authority.channel.authority_revision)
    task = SystemsRuntime.Task.async(fn -> SlackHistoryReader.read_page(request) end)

    settle_receive({:history_blocked, provider_process})
    key = Keys.ctl_im_connect(ctx.connect["group_id"], ctx.connect["connect_id"])

    assert {:ok, _rotated} =
             CasRecord.update(key, fn connect ->
               connect
               |> Map.put("connect_generation", "generation-2")
               |> Map.put("bot_token", "xoxb-history-test-rotated")
             end)

    SystemsRuntime.Proc.send(provider_process, :release_history)
    assert settled_await(task) == {:error, :stale_source}
  end

  test "reads replies only for an explicit root and advances after the durable reply", ctx do
    owner = SystemsRuntime.Proc.self()
    SystemsRuntime.put_env(:salix_im, :slack_history_test_handler, success_handler(owner))

    assert {:ok, authority} = SlackHistoryReader.source_authority(identity_request(ctx.connect))

    request =
      ctx.connect
      |> page_request(authority.channel.authority_revision)
      |> Map.merge(%{
        stream_kind: "replies",
        root_ts: "1787000000.000001",
        resume_boundary: "1787227200.000001"
      })

    assert {:ok, page} = SlackHistoryReader.read_page(request)
    assert page.stream_kind == "replies"
    assert page.root_ts == "1787000000.000001"
    assert [%{"thread_ts" => "1787000000.000001"}] = page.messages

    settle_receive({:slack_history_request, "/api/conversations.replies", query})
    assert query["ts"] == "1787000000.000001"
    assert query["limit"] == "15"
    assert query["oldest"] == "1787227200.000002"
    assert query["latest"] == "1787529599.999999"
  end

  defp identity_request(connect) do
    %{
      tenant_id: connect["tenant_id"],
      group_id: connect["group_id"],
      connect_id: connect["connect_id"],
      channel_id: "C_HISTORY"
    }
  end

  defp page_request(connect, authority_revision) do
    identity_request(connect)
    |> Map.merge(%{
      expected_connect_generation: connect["connect_generation"],
      expected_workspace_id: connect["workspace_id"],
      expected_app_id: connect["app_id"],
      expected_channel_authority_revision: authority_revision,
      stream_kind: "history",
      root_ts: "",
      page_ordinal: 0,
      cursor: nil,
      range_start: ~U[2026-08-17 00:00:00Z],
      range_end: ~U[2026-08-24 00:00:00Z]
    })
  end

  defp success_handler(owner) do
    fn conn ->
      response = success_response(conn)

      SystemsRuntime.Proc.send(
        owner,
        {:slack_history_request, conn.request_path, conn.query_params}
      )

      response
    end
  end

  defp success_response(%Plug.Conn{request_path: "/api/conversations.info"}) do
    {200, [],
     %{
       "ok" => true,
       "channel" => %{
         "id" => "C_HISTORY",
         "is_member" => true,
         "name" => "history",
         "is_private" => false,
         "is_archived" => false,
         "is_shared" => false,
         "is_ext_shared" => false,
         "is_org_shared" => false
       }
     }}
  end

  defp success_response(%Plug.Conn{request_path: "/api/conversations.history"}) do
    {200, [],
     %{
       "ok" => true,
       "messages" => [
         %{
           "ts" => "1787227200.000001",
           "user" => "U_HISTORY",
           "text" => "Atlas launch approved",
           "edited" => %{"ts" => "1787227201.000001"},
           "reply_count" => 0,
           "files" => [
             %{
               "id" => "F1",
               "name" => "plan.txt",
               "mimetype" => "text/plain",
               "size" => 12,
               "url_private" => "https://private.example.invalid/never-returned"
             }
           ]
         }
       ],
       "response_metadata" => %{"next_cursor" => "1787227200.000001"}
     }}
  end

  defp success_response(%Plug.Conn{request_path: "/api/conversations.replies"}) do
    {200, [],
     %{
       "ok" => true,
       "messages" => [
         %{
           "ts" => "1787000000.000001",
           "user" => "U_HISTORY_ROOT",
           "text" => "Changed parent view returned by replies",
           "reply_count" => 2
         },
         %{
           "ts" => "1787227200.000002",
           "thread_ts" => "1787000000.000001",
           "user" => "U_HISTORY_REPLY",
           "text" => "Decision recorded"
         }
       ],
       "response_metadata" => %{"next_cursor" => ""}
     }}
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
