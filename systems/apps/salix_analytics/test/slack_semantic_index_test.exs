defmodule SalixAnalytics.SlackSemanticIndexTest do
  use ExUnit.Case, async: false
  @moduletag :clickhouse
  alias SalixAnalytics.{SlackSemanticIndex, SlackSemanticIndexer, SlackSemanticQueue}
  alias SalixIM.Provider.Slack
  @url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")
  @scope %{"tenant_id" => "semantic-tenant", "workspace_id" => "T123", "channel_id" => "C123"}
  @queue_scope Map.merge(@scope, %{"group_id" => "test-group", "connect_id" => "test-connect"})
  @ts 1_780_000_000_000_001

  defmodule ScopeSource do
    def next(state) do
      {:ok,
       %{
         "tenant_id" => "semantic-tenant",
         "workspace_id" => "T123",
         "channel_id" => "C123",
         "group_id" => "test-group",
         "connect_id" => "test-connect"
       }, state}
    end
  end

  defmodule UnavailableScopeSource do
    def next(_state), do: {:error, :discovery_unavailable}
  end

  defmodule TwoInstallationScopes do
    def next(cursor) do
      connect = if cursor == "denied", do: "allowed", else: "denied"

      {:ok,
       %{
         "tenant_id" => "semantic-tenant",
         "workspace_id" => "T123",
         "channel_id" => "C123",
         "group_id" => "test-group",
         "connect_id" => connect
       }, connect}
    end
  end

  defmodule HTTP do
    import Plug.Conn
    def init(state), do: state

    def call(conn, state) do
      {mode, member} = Agent.get(state, &{&1.mode, &1.member})
      {:ok, body, conn} = read_body(conn)
      Agent.update(state, &%{&1 | calls: [{conn.request_path, body} | &1.calls]})
      if conn.request_path == "/embed", do: send(Agent.get(state, & &1.owner), :gpu_started)

      case conn.request_path do
        "/embed" ->
          case mode do
            :busy ->
              send_resp(conn, 429, "busy")

            :invalid ->
              json(conn, %{"embedding" => [1.0]})

            :oversized ->
              send_resp(conn, 200, String.duplicate("x", 2 * 1024 * 1024 + 1))

            :slow ->
              Process.sleep(6000)
              json(conn, vector())

            :steady_load ->
              Process.sleep(50)
              json(conn, vector())

            :media_heartbeat ->
              send(Agent.get(state, & &1.owner), {:held_live_encode, self()})

              receive do
                :release -> :ok
              after
                5000 -> raise "test did not release live encode"
              end

              json(conn, vector())

            :hold_first ->
              number =
                Agent.get(state, fn s -> Enum.count(s.calls, &(elem(&1, 0) == "/embed")) end)

              if number == 1 do
                send(Agent.get(state, & &1.owner), {:held_encode, self()})

                receive do
                  :release -> :ok
                after
                  5000 -> raise "test did not release first encode"
                end
              end

              json(conn, vector())

            :fail_second ->
              number =
                Agent.get(state, fn s -> Enum.count(s.calls, &(elem(&1, 0) == "/embed")) end)

              if number == 2, do: send_resp(conn, 503, "unavailable"), else: json(conn, vector())

            _ ->
              json(conn, vector())
          end

        "/api/conversations.info" ->
          channel = URI.decode_query(body)["channel"]

          if mode == :hold_other_channel and channel == "C999" do
            send(Agent.get(state, & &1.owner), {:held_channel_check, self()})

            receive do
              :release -> :ok
            after
              5000 -> raise "test did not release channel check"
            end
          end

          if member == :revoke_after_check, do: Agent.update(state, &%{&1 | member: false})

          json(conn, %{
            "ok" => true,
            "channel" => %{"id" => channel, "is_member" => member != false}
          })

        "/media" ->
          json(conn, %{"upload_id" => String.duplicate("a", 32)})

        "/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" when conn.method == "PUT" ->
          offset = conn |> get_req_header("x-media-offset") |> hd() |> String.to_integer()

          if mode == :upload_failure,
            do: send_resp(conn, 503, "upload failed"),
            else: json(conn, %{"offset" => offset + byte_size(body)})

        "/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" when conn.method == "DELETE" ->
          send_resp(conn, 204, "")

        "/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ->
          send(Agent.get(state, & &1.owner), :media_started)
          if mode == :media_slow, do: Process.sleep(16_000)

          if mode == :media_heartbeat do
            conn = send_chunked(conn, 200)

            Enum.reduce_while(1..60, conn, fn _, conn ->
              Process.sleep(50)

              case chunk(conn, "{\"heartbeat\":true}\n") do
                {:ok, conn} -> {:cont, conn}
                _ -> {:halt, conn}
              end
            end)
          else
            units =
              for {kind, index} <-
                    Enum.with_index(~w(image video_segment ocr_text asr_transcript document_text)) do
                %{
                  "unit" => %{
                    "content_kind" => kind,
                    "text" => "attachment #{kind}",
                    "page" => index,
                    "segment_start_ms" => 1000 * index,
                    "segment_end_ms" => 1000 * index + 500,
                    "embedding" => vector()["embedding"]
                  }
                }
              end

            terminal =
              if mode == :media_partial,
                do: %{"error" => "media_unavailable"},
                else: %{"complete" => true, "units" => 5}

            send_resp(
              conn,
              200,
              Enum.map_join(units ++ [terminal], "\n", &Jason.encode!/1) <> "\n"
            )
          end

        "/api/files.info" ->
          if mode == :file_deleted do
            json(conn, %{"ok" => false, "error" => "file_not_found"})
          else
            url =
              if mode == :wrong_file_host,
                do: "https://untrusted.invalid/file",
                else: "http://127.0.0.1:#{conn.port}/file"

            size =
              case mode do
                :oversized_file -> 512 * 1024 * 1024 + 1
                :canvas -> 5
                _ -> 12
              end

            mime = if mode == :canvas, do: "application/vnd.slack-docs", else: "video/mp4"

            json(conn, %{
              "ok" => true,
              "file" => %{
                "id" => "F123",
                "size" => size,
                "mimetype" => mime,
                "url_private_download" => url
              }
            })
          end

        "/file" ->
          send(
            Agent.get(state, & &1.owner),
            {:file_download, get_req_header(conn, "authorization")}
          )

          if mode == :file_redirect do
            conn
            |> put_resp_header("location", "http://127.0.0.1:#{conn.port}/credential-trap")
            |> send_resp(302, "")
          else
            if mode == :file_stream_error do
              conn = send_chunked(conn, 200)
              {:ok, _conn} = chunk(conn, "partial")
              raise "controlled test download abort"
            else
              send_resp(conn, 200, "source bytes")
            end
          end

        "/credential-trap" ->
          send_resp(conn, 200, "must not be reached")
      end
    end

    defp vector, do: %{"embedding" => [1.0 | List.duplicate(0.0, 255)]}

    defp json(conn, data),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(data))
  end

  defmodule FileSource do
    def extract(_scope, "F123", consumer, _opts \\ []) do
      path =
        Path.join(System.tmp_dir!(), "semantic-file-test-#{System.unique_integer([:positive])}")

      File.write!(path, "source bytes")
      if pid = Process.whereis(__MODULE__), do: send(pid, {:file_path, path})

      try do
        consumer.(path, "video/mp4")
      after
        File.rm!(path)
      end
    end
  end

  defmodule BlockingFileSource do
    def extract(_scope, _file_id, _consumer, _opts \\ []) do
      send(Process.whereis(__MODULE__), {:attachment_waiting, self()})

      receive do
        :release -> {:error, :semantic_unavailable}
      after
        10_000 -> {:error, :semantic_unavailable}
      end
    end
  end

  defmodule MixedFileSource do
    def extract(_scope, "Fbad", _consumer, _opts), do: {:error, :unsupported_attachment}

    def extract(scope, "F123", consumer, opts),
      do: FileSource.extract(scope, "F123", consumer, opts)
  end

  defmodule TwoInstallationFiles do
    def extract(%{"connect_id" => "denied"}, _, _, _), do: {:error, :attachment_inaccessible}
    def extract(scope, file, consumer, opts), do: FileSource.extract(scope, file, consumer, opts)
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    SalixStore.RepoTestSetup.ensure!()
    :ok
  end

  setup do
    SalixStore.Repo.query!("TRUNCATE slack_semantic.oban_jobs")

    SalixStore.Repo.query!(
      "TRUNCATE slack_semantic.cursors, slack_semantic.search_cursors, slack_semantic.search_sources, slack_semantic.search_components, slack_semantic.search_files, slack_semantic.search_channels, slack_semantic.search_connects, slack_semantic.search_windows, slack_mirror_source_writes"
    )

    database = "slack_semantic_test_#{System.unique_integer([:positive])}"
    sql!("CREATE DATABASE #{database}")

    for name <- ~w(20260831000001_create_slack_messages.sql
      20260901000001_create_slack_message_reactions.sql
      20260901000002_add_slack_message_actor_label.sql
      20260901000003_add_slack_message_payload.sql
      20260902000001_add_slack_mirror_component_tables.sql
      20260902000002_add_slack_pin_ts.sql
      20260902000003_add_slack_payload_search_text.sql
      20260902000004_add_slack_reaction_deltas.sql
      20260903000001_create_slack_message_event_triggers.sql
      20260905000001_create_slack_semantic_documents.sql
      20260906000001_create_slack_message_search.sql) do
      path = Application.app_dir(:salix_analytics, "priv/clickhouse/migrations/#{name}")

      path
      |> File.read!()
      |> String.replace("{{database}}", database)
      |> String.replace(~r/^\s*--.*$/m, "")
      |> String.split(";", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.each(&sql!/1)
    end

    owner = self()

    state =
      start_supervised!({Agent, fn -> %{mode: :ok, member: true, calls: [], owner: owner} end})

    server = start_supervised!({Bandit, plug: {HTTP, state}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    root = "http://127.0.0.1:#{port}"

    start_supervised!(
      {Finch,
       name: SlackSemanticIndex.HTTP,
       pools: %{default: [size: 2, count: 1, conn_opts: [transport_opts: [timeout: 1000]]]}}
    )

    settings = [
      {:salix_analytics, :clickhouse,
       [base_url: @url, database: database, table: "#{database}.events"]},
      {:salix_analytics, :slack_semantic_search,
       [
         environment: "test",
         url: root <> "/embed",
         client_id: "test",
         client_secret: "test"
       ]},
      {:salix_analytics, :slack_semantic_scope_source, ScopeSource},
      {:salix_im, :slack_semantic_reader, SlackSemanticIndex},
      {:salix_analytics, :slack_semantic_file_source, nil},
      {:salix_im, :slack_message_mirror_mod, SalixAnalytics.SlackMirror},
      {:salix_im, :slack_triage_clickhouse_reader_mod, SalixAnalytics.SlackMirror.Reader},
      {:salix_im, :slack_api_base_url, root <> "/api"}
    ]

    previous =
      Enum.map(settings, fn {app, key, _} -> {app, key, Application.get_env(app, key)} end)

    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)

    on_exit(fn ->
      sql!("DROP DATABASE IF EXISTS #{database}")

      Enum.each(previous, fn {app, key, value} ->
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end)
    end)

    %{database: database, state: state}
  end

  test "background pass indexes canonical payload text and agent reads a scoped hit", ctx do
    message!(ctx.database, %{"text" => "old writer text"})

    insert!(
      ctx.database,
      "slack_message_payloads",
      Map.merge(@scope, %{
        "event_date" => "2026-05-28",
        "message_ts_us" => @ts,
        "version" => 2,
        "text" => "deploy rollback",
        "body_text" => "Block Kit explanation"
      })
    )

    assert {:ok, %{documents: 1, chunks: 1}} = pass()
    assert {:ok, %{"messages" => [hit], "coverage" => coverage}} = tool()
    assert hit["text"] == "deploy rollback\nBlock Kit explanation"
    assert hit["channel"] == @scope["channel_id"]
    assert coverage["kind"] == "messages_and_attachments"
    assert coverage["best_effort"]
    assert {:ok, %{documents: 0}} = pass()

    for {field, other} <- [
          {"tenant_id", "other-tenant"},
          {"workspace_id", "other-workspace"},
          {"channel_id", "C999"}
        ] do
      assert {:ok, []} =
               SlackSemanticIndex.search(
                 Map.put(@scope, field, other),
                 "query",
                 @ts - 1,
                 @ts + 1,
                 10
               )
    end
  end

  test "production queues page historical work and repair a missed local offer", ctx do
    ts = System.os_time(:microsecond) - 1_000_000
    for number <- 1..21, do: current_message!(ctx.database, ts + number, "backlog #{number}")
    start_queue!()

    eventually(
      fn ->
        assert String.trim(
                 sql!(
                   "SELECT uniqExact(message_ts_us) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id=''"
                 )
               ) == "21"
      end,
      150
    )

    # This bypasses the live seam, representing an offer lost before PG insertion.
    current_message!(ctx.database, ts + 50, "arrival without a local offer")

    eventually(
      fn ->
        assert String.trim(
                 sql!(
                   "SELECT uniqExact(message_ts_us) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id=''"
                 )
               ) == "22"
      end,
      100
    )
  end

  test "historical messages and fresh edits older than fourteen days remain searchable", ctx do
    ts = System.os_time(:microsecond) - 90 * 86_400_000_000

    for number <- 1..21,
        do: current_message!(ctx.database, ts + number, "older history #{number}")

    start_queue!()

    eventually(
      fn ->
        assert String.trim(
                 sql!(
                   "SELECT uniqExact(message_ts_us) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id=''"
                 )
               ) == "21"
      end,
      150
    )

    live_message!(ts + 1, "fresh edit of an old message")

    eventually(fn ->
      assert {:ok, %{"messages" => hits}} =
               queue_tool(%{
                 "oldest" => slack_timestamp(ts),
                 "latest" => slack_timestamp(ts + 2)
               })

      assert Enum.any?(hits, &String.contains?(&1["text"], "fresh edit of an old message"))
    end)
  end

  @tag :live_semantic_gpu
  @tag skip: is_nil(System.get_env("SALIX_SEMANTIC_GPU_CONFIG"))
  @tag timeout: 480_000
  test "real GPU indexes successive live messages while history stays queued", ctx do
    # Explicit operator opt-in. Text is synthetic; an optional media path must
    # already be authorized for this origin. Never print credentials or units.
    gpu = System.fetch_env!("SALIX_SEMANTIC_GPU_CONFIG") |> File.read!() |> Jason.decode!()
    cfg = Application.fetch_env!(:salix_analytics, :slack_semantic_search)
    Agent.update(ctx.state, &Map.put(&1, :gpu_http, []))
    handler_id = {__MODULE__, :live_gpu_http, self()}

    :telemetry.attach(
      handler_id,
      [:finch, :request, :stop],
      fn _, measurements, metadata, {state, host} ->
        try do
          if metadata.request.host == host do
            {status, failure} =
              case metadata.result do
                {:ok, {_, %{status: status}}} ->
                  {status, nil}

                {:ok, %{status: status}} ->
                  {status, nil}

                {:error, error, {_, %{status: status}}} ->
                  {status, gpu_failure(error)}

                {:error, error} ->
                  {nil,
                   if(Map.get(error, :reason) in [:timeout, :closed, :econnreset, :econnrefused],
                     do: Map.get(error, :reason),
                     else: :transport
                   )}

                _ ->
                  {nil, :other}
              end

            lane =
              if metadata.request.path == "/embed" do
                case Jason.decode(IO.iodata_to_binary(metadata.request.body || "")) do
                  {:ok, %{"background" => true, "live" => true}} -> "live"
                  {:ok, %{"background" => true}} -> "history"
                  _ -> "query"
                end
              else
                "media"
              end

            sample = %{
              lane: lane,
              status: status,
              failure: failure,
              ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
            }

            Agent.update(
              state,
              &Map.update!(&1, :gpu_http, fn rows -> Enum.take([sample | rows], 2000) end)
            )
          end
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end,
      {ctx.state, URI.parse(gpu["url"]).host}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(
      :salix_analytics,
      :slack_semantic_search,
      Keyword.merge(cfg,
        url: String.trim_trailing(gpu["url"], "/") <> "/embed",
        client_id: gpu["client_id"],
        client_secret: gpu["client_secret"]
      )
    )

    ts = System.os_time(:microsecond) - 90 * 86_400_000_000

    for number <- 1..200 do
      current_message!(
        ctx.database,
        ts + number,
        String.duplicate(
          "Synthetic historical engineering note #{number}. Background indexing must yield to incoming text. ",
          16
        )
      )
    end

    start_queue!()

    history_pending = fn ->
      SalixStore.Repo.query!("""
      SELECT id FROM slack_semantic.oban_jobs
      WHERE priority=9 AND state IN ('available','scheduled','retryable','executing') LIMIT 1
      """).rows != []
    end

    eventually(fn -> assert history_pending.() end, 100)
    # One observer models the origin's documented single online-query lane.
    # New-message producers and index completion checks remain concurrent;
    # verification waiting is included in mirror-to-hit latency. No retry.
    query_probe = start_supervised!({Agent, fn -> nil end}, id: :gpu_query_probe)

    media =
      if path = System.get_env("SALIX_SEMANTIC_GPU_MEDIA") do
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)

          case SlackSemanticIndex.media(path, "audio/mp4") do
            {:ok, units} ->
              %{
                ok: true,
                units: length(units),
                elapsed_ms: System.monotonic_time(:millisecond) - started
              }

            _ ->
              %{ok: false}
          end
        end)
      end

    started = System.monotonic_time(:millisecond)

    samples =
      for number <- 1..60 do
        target = started + (number - 1) * 2000
        Process.sleep(max(target - System.monotonic_time(:millisecond), 0))
        assert history_pending.()
        timestamp = System.os_time(:microsecond)

        text =
          "Live semantic acceptance sample #{number}: the violet launch checklist is ready for review."

        begin = System.monotonic_time(:millisecond)
        live_message!(timestamp, text)

        Task.async(fn ->
          indexed =
            try do
              eventually(
                fn ->
                  assert {:ok, []} =
                           SlackSemanticIndex.missing_documents(@scope, timestamp, timestamp + 1)
                end,
                200
              )

              true
            rescue
              ExUnit.AssertionError -> false
            end

          indexed_ms = System.monotonic_time(:millisecond) - begin

          found =
            Agent.get(
              query_probe,
              fn _ ->
                case queue_tool(%{
                       "query" => text,
                       "oldest" => slack_timestamp(timestamp),
                       "latest" => slack_timestamp(timestamp + 1)
                     }) do
                  {:ok, %{"messages" => [hit]}} ->
                    hit["text"] =~ "Live semantic acceptance sample #{number}:"

                  _ ->
                    false
                end
              end,
              30_000
            )

          assert history_pending.()

          %{
            sample: number,
            indexed: indexed,
            query_ok: found,
            concurrent_media_active: not is_nil(media) and Process.alive?(media.pid),
            chars: String.length(text),
            mirror_write_to_index_ms: indexed_ms,
            mirror_write_to_hit_ms: System.monotonic_time(:millisecond) - begin
          }
        end)
      end
      |> Enum.map(&Task.await(&1, 30_000))

    ordered = Enum.sort(Enum.map(samples, & &1.mirror_write_to_hit_ms))
    p95 = Enum.at(ordered, ceil(length(ordered) * 0.95) - 1)
    p99 = Enum.at(ordered, ceil(length(ordered) * 0.99) - 1)
    media_result = if media, do: Task.await(media, 330_000)

    report = %{
      real_gpu: true,
      media: media_result,
      http: Agent.get(ctx.state, &Enum.reverse(&1.gpu_http)),
      samples: samples,
      p95_ms: p95,
      p99_ms: p99,
      interval_ms: 2000,
      history_seed_messages: 200,
      history_pending_at_end: history_pending.(),
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      history_completed_messages:
        String.trim(
          sql!(
            "SELECT count() FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id='' AND startsWith(chunks[1], 'Synthetic historical')"
          )
        )
    }

    if path = System.get_env("SALIX_SEMANTIC_GPU_REPORT"),
      do: File.write!(path, Jason.encode!(report))

    IO.puts(Jason.encode!(Map.drop(report, [:samples, :http])))
    :telemetry.detach(handler_id)
    assert Enum.all?(samples, &(&1.indexed and &1.query_ok))
    assert p95 <= 5000
    assert p99 <= 10_000

    if media do
      assert media_result.ok
      assert media_result.units > 0
      assert Enum.count(samples, & &1.concurrent_media_active) >= 30
    end
  end

  defp gpu_failure(error) do
    reason = Map.get(error, :reason)

    %{
      class: inspect(error.__struct__),
      reason: if(is_atom(reason), do: reason, else: :structured)
    }
  end

  test "a full-history key page stays bounded with a large channel and duplicate versions", ctx do
    ts = System.os_time(:microsecond) - 90 * 86_400_000_000

    sql!("""
    INSERT INTO #{ctx.database}.slack_messages
      (event_date, tenant_id, workspace_id, channel_id, message_ts_us, message_ts, version)
    SELECT today(), 'semantic-tenant', 'T123', 'C123', #{ts} + intDiv(number, 2), '', number
    FROM numbers(100000)
    """)

    assert {:ok, rows} = SlackSemanticIndex.message_page(@scope, ts + 50_000)
    timestamps = Enum.map(rows, & &1["message_ts_us"])
    assert length(timestamps) in 10..20
    assert hd(timestamps) == ts + 49_999
    assert timestamps == Enum.sort(Enum.uniq(timestamps), :desc)
    assert {:ok, next} = SlackSemanticIndex.message_page(@scope, List.last(timestamps))
    assert hd(next)["message_ts_us"] < List.last(timestamps)
  end

  test "historical key discovery and exact source reads tolerate sparse monthly partitions",
       ctx do
    # Neighboring channel keys bracket C123 in every monthly part, forcing
    # granule reads even when a part contains no matching C123 message.
    # All dates are real derivatives of the message timestamps.
    sql!("""
    INSERT INTO #{ctx.database}.slack_messages
      (event_date, tenant_id, workspace_id, channel_id, message_ts_us, message_ts, version)
    SELECT addMonths(toDate('2024-01-01'), intDiv(number, 4000)) AS day,
      'semantic-tenant', 'T123', if(number % 4000 < 2000, 'C122', 'C124'),
      toUnixTimestamp64Micro(toDateTime64(day, 6)) + number % 4000, '', 1
    FROM numbers(96000)
    """)

    message!(ctx.database, %{"text" => "target among many monthly partitions"})
    assert {:ok, [%{"message_ts_us" => @ts}]} = SlackSemanticIndex.message_page(@scope, @ts + 1)
    assert :ok = SlackSemanticIndexer.index_message(@scope, @ts)
    assert {:ok, %{"messages" => [hit]}} = tool()
    assert hit["text"] =~ "target among many monthly partitions"
  end

  test "one installation cannot consume another installation's historical file discovery", ctx do
    Application.put_env(:salix_analytics, :slack_semantic_scope_source, TwoInstallationScopes)
    Application.put_env(:salix_analytics, :slack_semantic_file_source, TwoInstallationFiles)
    ts = System.os_time(:microsecond) - 90 * 86_400_000_000

    current_message!(ctx.database, ts, "shared historical attachment", %{
      "payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})
    })

    start_queue!()

    eventually(
      fn ->
        assert String.trim(
                 sql!(
                   "SELECT count() FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id!=''"
                 )
               ) ==
                 "1"
      end,
      100
    )

    assert {:ok, %{"messages" => hits}} =
             queue_tool(
               %{
                 "oldest" => slack_timestamp(ts),
                 "latest" => slack_timestamp(ts + 1)
               },
               Map.put(@queue_scope, "connect_id", "allowed")
             )

    assert Enum.any?(hits, &(&1["file_id"] == "F123"))
  end

  test "historical page commits atomically, rejects stale advancement and survives worker restart" do
    opts =
      SlackSemanticQueue.oban_options() |> Keyword.put(:queues, []) |> Keyword.put(:plugins, [])

    start_supervised!({Oban, opts})
    assert {:ok, 0} = SlackSemanticQueue.history_cursor(@queue_scope)
    page = [%{"message_ts_us" => 30}, %{"message_ts_us" => 20}]

    # A failure on the second real Oban insert must roll back the first job
    # and the newly-created cursor. This is a disposable local test schema.
    SalixStore.Repo.query!("""
    ALTER TABLE slack_semantic.oban_jobs ADD CONSTRAINT test_reject_page_job
    CHECK ((args->>'timestamp')::bigint != 20)
    """)

    try do
      refute match?({:ok, _}, SlackSemanticQueue.enqueue_history_page(@queue_scope, 0, page))
      assert [[0]] = SalixStore.Repo.query!("SELECT count(*) FROM slack_semantic.oban_jobs").rows

      assert [[0]] =
               SalixStore.Repo.query!("SELECT count(*) FROM slack_semantic.search_cursors").rows
    after
      SalixStore.Repo.query!(
        "ALTER TABLE slack_semantic.oban_jobs DROP CONSTRAINT test_reject_page_job"
      )
    end

    results =
      for _ <- 1..2 do
        Task.async(fn -> SlackSemanticQueue.enqueue_history_page(@queue_scope, 0, page) end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.sort(results) == [{:ok, :advanced}, {:ok, :stale}]
    assert [[2]] = SalixStore.Repo.query!("SELECT count(*) FROM slack_semantic.oban_jobs").rows
    assert {:ok, 20} = SlackSemanticQueue.history_cursor(@queue_scope)
    stop_supervised!(SlackSemanticQueue.Oban)
    start_supervised!({Oban, opts})
    assert {:ok, 20} = SlackSemanticQueue.history_cursor(@queue_scope)

    assert {:ok, :advanced} =
             SlackSemanticQueue.enqueue_history_page(@queue_scope, 20, [%{"message_ts_us" => 10}])

    assert {:ok, 10} = SlackSemanticQueue.history_cursor(@queue_scope)
  end

  test "a deleted live attachment settles and historical text resumes", ctx do
    scope = seed_file_connect()
    Agent.update(ctx.state, &%{&1 | mode: :file_deleted})
    Application.put_env(:salix_analytics, :slack_semantic_file_source, SalixIM.SlackSemanticFiles)
    start_queue!()
    ts = System.os_time(:microsecond) - 1_000_000

    live_message!(ts, "live file was removed", %{
      "_semantic_context" => Map.take(scope, ~w(group_id connect_id)),
      "payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})
    })

    eventually(fn ->
      assert [["cancelled"]] =
               SalixStore.Repo.query!("""
               SELECT state::text FROM slack_semantic.oban_jobs
               WHERE priority=0 AND args->>'kind'='file'
               """).rows

      refute SlackSemanticQueue.pending_live?()
    end)

    current_message!(ctx.database, ts - 1, "history after revoked file")
    eventually(fn -> assert indexed_text(ctx.database) =~ "history after revoked file" end, 150)
  end

  test "new channels index through the real outbox without any configured scopes", ctx do
    owner = seed_file_connect()
    connect = Map.merge(connect(), owner)
    start_queue!()
    ts = System.os_time(:microsecond) - 1_000_000

    for {channel, number} <- Enum.with_index(["C456", "C789"], 1) do
      timestamp = slack_timestamp(ts + number)

      assert :ok =
               SalixIM.SlackMessageMirror.observe(connect, %{
                 "event" => %{
                   "type" => "message",
                   "channel" => channel,
                   "ts" => timestamp,
                   "text" => "automatic new channel #{number}",
                   "user" => "U123"
                 }
               })

      assert :idle = SalixIM.SlackMessageMirror.OutboxDrainer.drain_once(batch_size: 10)

      eventually(fn ->
        assert {:ok, %{"messages" => [hit]}} =
                 queue_tool(
                   %{
                     "channel" => channel,
                     "oldest" => slack_timestamp(ts),
                     "latest" => slack_timestamp(ts + 10)
                   },
                   owner
                 )

        assert hit["ts"] == timestamp
        assert hit["text"] =~ "automatic new channel #{number}"
      end)
    end

    assert [[0]] = SalixStore.Repo.query!("SELECT count(*) FROM slack_mirror_outbox").rows

    assert {:ok, %{rows: rows}} =
             SalixStore.Repo.query(
               "SELECT args->'scope' FROM slack_semantic.oban_jobs WHERE priority=0 AND args->>'kind'='text' ORDER BY id"
             )

    assert Enum.map(rows, fn [scope] -> scope["channel_id"] end) == ["C456", "C789"]

    assert Enum.all?(rows, fn [scope] ->
             scope["group_id"] == owner["group_id"] and scope["connect_id"] == owner["connect_id"]
           end)

    assert String.trim(
             sql!(
               "SELECT uniqExact(message_ts_us) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id=''"
             )
           ) ==
             "2"
  end

  test "existing installation discovery pages mirrored channels beyond one page", _ctx do
    owner = seed_file_connect()
    expected = for number <- 1..23, do: "CAUTO#{String.pad_leading(to_string(number), 2, "0")}"

    # Workspace watermarks alone cannot grant another installation's data.
    assert :ok = SalixStore.SlackSearchCatalog.remember_channels(owner, expected)

    {found, _state} =
      Enum.reduce_while(1..300, {MapSet.new(), nil}, fn _, {found, state} ->
        assert {:ok, scope, next} = SalixIM.SlackSemanticScopes.next(state)

        found =
          if scope && scope["group_id"] == owner["group_id"],
            do: MapSet.put(found, scope["channel_id"]),
            else: found

        if MapSet.subset?(MapSet.new(expected), found),
          do: {:halt, {found, next}},
          else: {:cont, {found, next}}
      end)

    assert MapSet.subset?(MapSet.new(expected), found)
  end

  test "production text queue indexes live arrivals while an attachment is stalled", ctx do
    Process.register(self(), BlockingFileSource)
    Application.put_env(:salix_analytics, :slack_semantic_file_source, BlockingFileSource)
    timestamp = System.os_time(:microsecond) - 1_000_000

    current_message!(ctx.database, timestamp, "", %{
      "payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})
    })

    start_queue!()
    assert_receive {:attachment_waiting, file_worker}, 7000

    try do
      live_message!(timestamp + 1, "new text during long attachment")

      eventually(fn ->
        assert indexed_text(ctx.database) ==
                 "new text during long attachment"
      end)

      assert Process.alive?(file_worker)
    after
      send(file_worker, :release)
    end
  end

  test "successive live messages overtake a continuously busy historical backlog", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :steady_load})
    ts = System.os_time(:microsecond) - 1_000_000

    for number <- 1..60 do
      current_message!(
        ctx.database,
        ts + number,
        "historical #{number} " <> String.duplicate("x", 1600)
      )
    end

    start_queue!()
    assert_receive :gpu_started, 5000

    for number <- 1..4 do
      started = System.monotonic_time(:millisecond)
      live_message!(ts + 500 + number, "fresh #{number}")

      eventually(fn ->
        assert String.trim(
                 sql!(
                   "SELECT count() FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id='' AND startsWith(chunks[1], 'fresh #{number}')"
                 )
               ) == "1"
      end)

      assert {:ok, [hit]} =
               queue_search(
                 @queue_scope,
                 "fresh #{number}",
                 ts + 500 + number,
                 ts + 501 + number,
                 1
               )

      assert String.trim(hit["text"]) == "fresh #{number}"
      assert System.monotonic_time(:millisecond) - started < 5000

      count =
        sql!(
          "SELECT uniqExact(message_ts_us) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id=''"
        )

      assert String.to_integer(String.trim(count)) < 60 + number
    end

    texts =
      Agent.get(ctx.state, fn s ->
        for {"/embed", body} <- Enum.reverse(s.calls), do: Jason.decode!(body)
      end)

    assert Enum.count(texts, &(&1["live"] == true)) == 4
    assert Enum.any?(texts, &(&1["background"] == true and &1["live"] == false))
  end

  test "a failed live encode stays durable and does not block another live message", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :busy})
    start_queue!()
    ts = System.os_time(:microsecond) - 1_000_000
    live_message!(ts, "retry me")
    assert_receive :gpu_started, 5000

    eventually(fn ->
      assert [[state]] =
               SalixStore.Repo.query!(
                 "SELECT state::text FROM slack_semantic.oban_jobs WHERE args->>'kind'='text'"
               ).rows

      assert state == "scheduled"
    end)

    Agent.update(ctx.state, &%{&1 | mode: :ok})
    live_message!(ts + 1, "second live message")

    eventually(fn ->
      assert String.trim(
               sql!(
                 "SELECT count() FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id='' AND startsWith(chunks[1], 'second live message')"
               )
             ) == "1"
    end)

    eventually(
      fn ->
        assert String.trim(
                 sql!(
                   "SELECT uniqExact(message_ts_us) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id=''"
                 )
               ) == "2"
      end,
      100
    )
  end

  test "normal long work is not rescued early but an abandoned job remains recoverable", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :hold_first})
    start_queue!()
    ts = System.os_time(:microsecond) - 1_000_000
    live_message!(ts, "healthy long-running work")
    assert_receive {:held_encode, encoder}, 5000

    try do
      # Advance the persisted attempt age, not wall time. Exercise the actual
      # production Lifeline plugin while the original executor still runs.
      SalixStore.Repo.query!("""
      UPDATE slack_semantic.oban_jobs
      SET attempted_at = timezone('UTC', now()) - interval '31 minutes'
      WHERE state = 'executing'
      """)

      plugin = Oban.Registry.whereis(SlackSemanticQueue.Oban, {:plugin, Oban.Plugins.Lifeline})
      assert is_pid(plugin)
      send(plugin, :rescue)
      :sys.get_state(plugin)

      assert [["executing", 1]] =
               SalixStore.Repo.query!("""
               SELECT state::text, attempt FROM slack_semantic.oban_jobs
               WHERE priority = 0 AND args->>'kind' = 'text'
               """).rows

      SalixStore.Repo.query!("""
      UPDATE slack_semantic.oban_jobs
      SET attempted_at = timezone('UTC', now()) - interval '61 minutes'
      WHERE state = 'executing'
      """)

      send(plugin, :rescue)
      :sys.get_state(plugin)

      assert [["available"]] =
               SalixStore.Repo.query!("""
               SELECT state::text FROM slack_semantic.oban_jobs
               WHERE priority = 0 AND args->>'kind' = 'text'
               """).rows
    after
      send(encoder, :release)
    end

    eventually(fn -> assert indexed_text(ctx.database) == "healthy long-running work" end)
  end

  test "a rescued but still-running old job cannot acknowledge a new observation", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :hold_first})
    start_queue!(plugins: [{Oban.Plugins.Lifeline, rescue_after: 100, interval: 100}])
    ts = System.os_time(:microsecond) - 1_000_000
    live_message!(ts, "old observation")
    assert_receive {:held_encode, encoder}, 5000

    try do
      eventually(
        fn ->
          assert [["available"]] =
                   SalixStore.Repo.query!(
                     "SELECT state::text FROM slack_semantic.oban_jobs WHERE priority=0 AND args->>'kind'='text'"
                   ).rows
        end,
        30
      )

      live_message!(ts, "new observation")

      eventually(fn ->
        assert [[count]] =
                 SalixStore.Repo.query!(
                   "SELECT count(*) FROM slack_semantic.oban_jobs WHERE args->>'kind'='text' AND priority=0"
                 ).rows

        assert count == 2
      end)
    after
      send(encoder, :release)
    end

    eventually(fn ->
      assert indexed_text(ctx.database) == "new observation"

      assert [[2]] =
               SalixStore.Repo.query!(
                 "SELECT count(*) FROM slack_semantic.oban_jobs WHERE args->>'kind'='text' AND priority=0 AND state='completed'"
               ).rows
    end)
  end

  test "a live arrival cancels historical media cooperatively and cleans its temporary file",
       ctx do
    Process.register(self(), FileSource)
    Agent.update(ctx.state, &%{&1 | mode: :media_heartbeat})
    Application.put_env(:salix_analytics, :slack_semantic_file_source, FileSource)
    ts = System.os_time(:microsecond) - 1_000_000

    current_message!(ctx.database, ts, "", %{
      "payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})
    })

    start_queue!()
    assert_receive {:file_path, path}, 5000
    assert_receive :media_started, 5000
    assert File.exists?(path)
    started = System.monotonic_time(:millisecond)
    live_message!(ts + 1, "preempt historical attachment")
    assert_receive {:held_live_encode, encoder}, 2000

    try do
      eventually(fn -> refute File.exists?(path) end, 15)
      # The original stream runs for three seconds. Cleanup must occur while
      # live work is held, before normal termination can make this test pass.
      assert System.monotonic_time(:millisecond) - started < 2000
    after
      send(encoder, :release)
    end

    assert String.trim(
             sql!(
               "SELECT count() FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id!=''"
             )
           ) ==
             "0"

    eventually(fn ->
      assert indexed_text(ctx.database) == "preempt historical attachment"
    end)

    assert [[count]] =
             SalixStore.Repo.query!(
               "SELECT count(*) FROM slack_semantic.oban_jobs WHERE args->>'kind'='file' AND state IN ('scheduled','available','executing')"
             ).rows

    assert count > 0
  end

  test "concurrent offers stay bounded and saturation never changes mirror acknowledgment", ctx do
    pid = start_supervised!(SlackSemanticQueue)
    :sys.suspend(pid)
    ts = System.os_time(:microsecond) - 1_000_000

    try do
      results =
        1..2048
        |> Task.async_stream(fn i -> SlackSemanticQueue.offer(@scope, ts + i) end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.to_list()

      assert Enum.count(results, &(&1 == {:ok, :ok})) == 1024
      assert Enum.count(results, &(&1 == {:ok, {:error, :full}})) == 1024
      live_message!(ts + 3000, "canonical write while local buffer is full")
      assert String.trim(sql!("SELECT count() FROM #{ctx.database}.slack_messages FINAL")) == "1"
    after
      :sys.resume(pid)
    end
  end

  test "persisted live jobs survive enqueue bridge and Oban restart", ctx do
    opts =
      SlackSemanticQueue.oban_options() |> Keyword.put(:queues, []) |> Keyword.put(:plugins, [])

    start_supervised!({Oban, opts})
    start_supervised!(SlackSemanticQueue)
    ts = System.os_time(:microsecond) - 1_000_000
    live_message!(ts, "survive restart")

    eventually(fn ->
      assert [[1]] =
               SalixStore.Repo.query!(
                 "SELECT count(*) FROM slack_semantic.oban_jobs WHERE state='available'"
               ).rows
    end)

    stop_supervised!(SlackSemanticQueue)
    stop_supervised!(SlackSemanticQueue.Oban)
    start_queue!()

    eventually(fn ->
      assert indexed_text(ctx.database) == "survive restart"
    end)
  end

  test "bounded terminal cleanup preserves queued and discarded work" do
    opts =
      SlackSemanticQueue.oban_options() |> Keyword.put(:queues, []) |> Keyword.put(:plugins, [])

    start_supervised!({Oban, opts})
    bridge = start_supervised!(SlackSemanticQueue)
    ts = System.os_time(:microsecond) - 1_000_000

    ids =
      for {state, index} <- Enum.with_index(~w(available completed cancelled discarded)) do
        assert {:ok, job} = SlackSemanticQueue.enqueue(@queue_scope, ts + index, "text", true)

        SalixStore.Repo.query!(
          "UPDATE slack_semantic.oban_jobs SET state=$2::slack_semantic.oban_job_state, inserted_at=now()-interval '2 days' WHERE id=$1",
          [job.id, state]
        )

        {state, job.id}
      end

    send(bridge, :prune)

    eventually(fn ->
      rows =
        SalixStore.Repo.query!("SELECT state::text,id FROM slack_semantic.oban_jobs ORDER BY id").rows

      assert rows == for({state, id} <- ids, state in ["available", "discarded"], do: [state, id])
    end)
  end

  test "unsupported live files settle independently from supported siblings", ctx do
    Application.put_env(:salix_analytics, :slack_semantic_file_source, MixedFileSource)
    start_queue!()
    ts = System.os_time(:microsecond) - 1_000_000

    live_message!(ts, "", %{
      "payload" => Jason.encode!(%{"files" => [%{"id" => "Fbad"}, %{"id" => "F123"}]})
    })

    eventually(fn ->
      assert String.trim(
               sql!(
                 "SELECT file_id FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id!=''"
               )
             ) ==
               "F123"

      assert [["cancelled"]] =
               SalixStore.Repo.query!(
                 "SELECT state::text FROM slack_semantic.oban_jobs WHERE priority=0 AND args->>'file_id'='Fbad'"
               ).rows

      refute SlackSemanticQueue.pending_live?()
    end)
  end

  test "late vectors and equal-version changed source text cannot expose an edit or tombstone",
       ctx do
    message!(ctx.database, %{"text" => "old content"})
    assert {:ok, %{documents: 1}} = pass()

    old_document =
      sql!("SELECT * FROM #{ctx.database}.slack_semantic_documents FORMAT JSONEachRow")
      |> Jason.decode!()
      |> Map.delete("indexed_at")

    message!(ctx.database, %{"text" => "edited content", "version" => 2})
    assert {:ok, %{"messages" => []}} = tool()
    assert {:ok, %{documents: 1}} = pass()
    assert {:ok, %{"messages" => [%{"text" => "edited content\n"}]}} = tool()
    insert!(ctx.database, "slack_semantic_documents", old_document)
    assert {:ok, %{"messages" => []}} = tool()
    assert {:ok, %{documents: 1}} = pass()
    message!(ctx.database, %{"text" => "same version replacement", "version" => 2})
    assert {:ok, %{"messages" => []}} = tool()
    message!(ctx.database, %{"text" => "", "version" => 3, "deleted" => true})
    assert {:ok, %{"messages" => []}} = tool()
    assert {:ok, %{documents: 0}} = pass()
  end

  test "a payload-only edit suppresses the old semantic document", ctx do
    message!(ctx.database, %{"text" => "old"})
    assert {:ok, %{documents: 1}} = pass()

    insert!(
      ctx.database,
      "slack_message_payloads",
      Map.merge(@scope, %{
        "event_date" => "2026-05-28",
        "message_ts_us" => @ts,
        "version" => 10,
        "text" => "payload edit",
        "body_text" => ""
      })
    )

    assert {:ok, %{"messages" => []}} = tool()
    assert {:ok, %{documents: 1}} = pass()
    assert {:ok, %{"messages" => [%{"text" => "payload edit\n"}]}} = tool()
  end

  test "GPU failure halfway through a document publishes no partial result and later pass retries",
       ctx do
    message!(ctx.database, %{"text" => String.duplicate("长", 900)})
    Agent.update(ctx.state, &%{&1 | mode: :fail_second})
    assert {:error, :semantic_unavailable} = pass()

    assert String.trim(sql!("SELECT count() FROM #{ctx.database}.slack_semantic_documents")) ==
             "0"

    Agent.update(ctx.state, &%{&1 | mode: :ok})
    assert {:ok, %{documents: 1, chunks: 3}} = pass()
  end

  test "semantic search verifies access while another channel check is in flight", ctx do
    message!(ctx.database, %{"text" => "deploy rollback"})
    assert {:ok, %{documents: 1}} = pass()
    Agent.update(ctx.state, &%{&1 | mode: :hold_other_channel})

    other =
      Task.async(fn ->
        Slack.API.request_form(
          Slack.API.installation(connect()),
          "conversations.info",
          %{"channel" => "C999"},
          timeout_ms: 5000
        )
      end)

    assert_receive {:held_channel_check, request}, 2000

    try do
      assert {:ok, %{"messages" => [hit]}} = tool()
      assert hit["text"] == "deploy rollback\n"
      calls = Agent.get(ctx.state, & &1.calls)

      assert Enum.count(calls, fn {path, body} ->
               path == "/api/conversations.info" and URI.decode_query(body)["channel"] == "C123"
             end) == 2
    after
      send(request, :release)
      Task.await(other, 5000)
    end
  end

  test "denied or revoked channel membership never returns indexed content", ctx do
    message!(ctx.database, %{"text" => "private"})
    assert {:ok, %{documents: 1}} = pass()
    Agent.update(ctx.state, &%{&1 | member: false, calls: []})
    assert {:error, _} = tool()
    refute Enum.any?(Agent.get(ctx.state, & &1.calls), &(elem(&1, 0) == "/embed"))
    Agent.update(ctx.state, &%{&1 | member: :revoke_after_check})
    assert {:error, _} = tool()
  end

  test "busy, malformed, oversized, slow, dead GPU and missing index only fail the optional tool",
       ctx do
    message!(ctx.database, %{"text" => "ordinary history"})
    assert {:ok, %{documents: 1}} = pass()

    for mode <- [:busy, :invalid, :oversized, :slow] do
      Agent.update(ctx.state, &%{&1 | mode: mode})
      started = System.monotonic_time(:millisecond)
      assert {:error, _} = tool()
      assert System.monotonic_time(:millisecond) - started < 5500

      assert {:ok, %{"messages" => [%{"text" => "ordinary history"}]}} = history()
    end

    cfg = Application.get_env(:salix_analytics, :slack_semantic_search)

    Application.put_env(
      :salix_analytics,
      :slack_semantic_search,
      Keyword.put(cfg, :url, "http://127.0.0.1:1/embed")
    )

    assert {:error, _} = tool()
    Application.put_env(:salix_analytics, :slack_semantic_search, cfg)
    Agent.update(ctx.state, &%{&1 | mode: :ok})
    sql!("DROP TABLE #{ctx.database}.slack_semantic_documents")
    assert {:error, _} = tool()
    assert {:ok, %{"messages" => [_]}} = history()
  end

  test "an undrained edit suppresses the otherwise current semantic hit", ctx do
    message!(ctx.database, %{"text" => "before edit"})
    assert {:ok, %{documents: 1}} = pass()

    assert :ok =
             SalixStore.SlackMirrorOutbox.append(
               Map.merge(@scope, %{
                 "message_ts" => "1780000000.000001",
                 "message_ts_us" => @ts,
                 "text" => "pending edit"
               })
             )

    on_exit(fn ->
      SalixStore.Repo.query!("DELETE FROM slack_mirror_outbox WHERE row->>'tenant_id' = $1", [
        @scope["tenant_id"]
      ])
    end)

    assert {:ok, %{"messages" => []}} = tool()
  end

  test "a stalled background encoder does not block ordinary ingress, history or keyword search",
       ctx do
    message!(ctx.database, %{"text" => "ordinary history"})
    Agent.update(ctx.state, &%{&1 | mode: :slow})

    worker = spawn(fn -> pass() end)

    assert_receive :gpu_started, 1500
    started = System.monotonic_time(:millisecond)

    assert :ok =
             SalixIM.SlackMessageMirror.observe(connect(), %{
               "team_id" => "T123",
               "event_id" => "Ev-semantic-isolation",
               "event_time" => 1_780_000_001,
               "event" => %{
                 "type" => "message",
                 "channel" => "C123",
                 "user" => "U777",
                 "ts" => "1780000001.000001",
                 "text" => "mainline message"
               }
             })

    assert {:ok, %{"messages" => [%{"text" => "ordinary history"}]}} = history()

    assert {:ok, %{"messages" => [_]}} =
             Slack.call(%{}, connect(), "slack.search", %{"query" => "history"})

    assert System.monotonic_time(:millisecond) - started < 1500
    Process.exit(worker, :kill)
    assert {:ok, %{"messages" => [_]}} = history()

    on_exit(fn ->
      SalixStore.Repo.query!("DELETE FROM slack_mirror_outbox WHERE row->>'tenant_id' = $1", [
        @scope["tenant_id"]
      ])
    end)
  end

  test "neighboring channel payloads do not consume the selected channel read budget", ctx do
    # One physical granule straddles the selected and neighboring channel.
    # Filtering after payload reads would spend over 64 MiB on unrelated text.
    for table <- ~w(slack_messages slack_message_payloads) do
      sql!("""
      CREATE TABLE #{ctx.database}.#{table}_wide AS #{ctx.database}.#{table}
      ENGINE = ReplacingMergeTree(version) PARTITION BY toYYYYMM(event_date)
      ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
      SETTINGS index_granularity_bytes = 0
      """)

      sql!("DROP TABLE #{ctx.database}.#{table}")
      sql!("RENAME TABLE #{ctx.database}.#{table}_wide TO #{ctx.database}.#{table}")

      sql!("""
      INSERT INTO #{ctx.database}.#{table}
        (event_date, tenant_id, workspace_id, channel_id, message_ts_us, version, text, payload)
      SELECT toDate('2026-05-28'), 'semantic-tenant', 'T123',
        if(number = 0, 'C123', 'C124'), #{@ts} + number, 1,
        if(number = 0, 'scoped document', repeat('x', 270000)),
        if(number = 0, '{"files":[{"id":"F123","mimetype":"video/mp4"}]}', '{}')
      FROM numbers(257)
      """)
    end

    # The canonical timestamp is intentionally set separately from the key.
    message!(ctx.database, %{"text" => "scoped document", "version" => 2})
    assert {:ok, %{documents: 1}} = pass()

    assert {:ok, [%{"file_id" => "F123"}]} =
             SlackSemanticIndex.missing_files(@scope, @ts - 1, @ts + 1)

    assert {:ok, %{files: 1}} = file_pass()
    assert {:ok, %{"messages" => hits}} = tool()
    assert length(hits) == 2
    assert Enum.all?(hits, &(&1["channel"] == "C123"))
  end

  for layout <- ~w(Compact Wide) do
    @layout layout
    test "default window searches #{@layout} parts within the interactive read budget", ctx do
      recent = System.os_time(:microsecond) - 1_000_000
      older = recent - 7 * 86_400 * 1_000_000
      min_wide_bytes = if @layout == "Compact", do: 1_000_000_000, else: 0
      min_wide_rows = if @layout == "Compact", do: 1_000_000, else: 0

      # A selected message shares a physical granule with wide neighboring
      # channel bodies. Compact parts read those bodies even with PREWHERE;
      # the explicit narrow-window tests never included this older granule.
      for table <- ~w(slack_messages slack_message_payloads) do
        sql!("""
        CREATE TABLE #{ctx.database}.#{table}_layout AS #{ctx.database}.#{table}
        ENGINE = ReplacingMergeTree(version) PARTITION BY toYYYYMM(event_date)
        ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
        SETTINGS min_bytes_for_wide_part = #{min_wide_bytes}, min_rows_for_wide_part = #{min_wide_rows},
          index_granularity_bytes = 256000000
        """)

        sql!("DROP TABLE #{ctx.database}.#{table}")
        sql!("RENAME TABLE #{ctx.database}.#{table}_layout TO #{ctx.database}.#{table}")

        sql!("""
        INSERT INTO #{ctx.database}.#{table}
          (event_date, tenant_id, workspace_id, channel_id, message_ts_us, version, text)
        SELECT toDate(fromUnixTimestamp64Micro(toInt64(#{older}), 'UTC')),
          'semantic-tenant', 'T123', if(number = 0, 'C123', 'C124'), #{older} + number, 1,
          if(number = 0, 'older message', repeat('x', 32768))
        FROM numbers(1153)
        """)
      end

      assert String.trim(
               sql!("""
               SELECT DISTINCT part_type FROM system.parts
               WHERE active AND database = '#{ctx.database}'
                 AND table IN ('slack_messages', 'slack_message_payloads')
               FORMAT TSV
               """)
             ) == @layout

      current_message!(ctx.database, recent, "default window rollback")
      assert :ok = SlackSemanticIndexer.index_message(@scope, recent)

      assert {:ok, %{"messages" => [%{"text" => "default window rollback\n"}]}} =
               tool(%{
                 "oldest" => slack_timestamp(recent),
                 "latest" => slack_timestamp(recent + 1)
               })

      assert {:ok, %{"messages" => [hit], "coverage" => coverage}} =
               Slack.call(%{}, connect(), "slack.semantic_search", %{
                 "channel" => "C123",
                 "query" => "rollback"
               })

      assert hit["text"] == "default window rollback\n"
      assert hit["ts"] == slack_timestamp(recent)
      assert {:ok, oldest} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(coverage["oldest"])
      assert {:ok, latest} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(coverage["latest"])
      assert latest - oldest == 14 * 86_400 * 1_000_000
      assert oldest < older and recent < latest
    end
  end

  test "a physical source backlog cannot exceed the optional ClickHouse read budget", ctx do
    sql!("""
    INSERT INTO #{ctx.database}.slack_messages
      (event_date, tenant_id, workspace_id, channel_id, message_ts_us, message_ts, version, text)
    SELECT toDate('2026-05-28'), 'semantic-tenant', 'T123', 'C123',
      #{@ts} + number, concat('1780000000.', leftPad(toString(number + 1), 6, '0')),
      1, 'many source messages'
    FROM numbers(70000)
    """)

    # All newer messages are already indexed: finding the one oldest gap
    # requires reading the large source/index window, even with LIMIT 20.
    sql!("""
    INSERT INTO #{ctx.database}.slack_semantic_documents
      (event_date, tenant_id, workspace_id, channel_id, message_ts_us,
       source_version, payload_version, source_text, chunks, embeddings)
    SELECT toDate('2026-05-28'), 'semantic-tenant', 'T123', 'C123',
      #{@ts} + number + 1, 1, 0, 'many source messages\\n',
      ['many source messages'], [arrayResize([toFloat32(1)], 256, toFloat32(0))]
    FROM numbers(69999)
    """)

    assert {:error, :read_over_budget} =
             SlackSemanticIndexer.run([@scope], latest: @ts + 70001, pace_ms: 0)

    refute Enum.any?(Agent.get(ctx.state, & &1.calls), &(elem(&1, 0) == "/embed"))

    # The larger interactive byte allowance does not remove its row ceiling.
    assert {:error, "Semantic search exceeded its read budget; narrow oldest/latest."} =
             tool(%{"latest" => slack_timestamp(@ts + 70001)})
  end

  test "staging live indexing ignores the removed manual switch", ctx do
    config =
      Application.fetch_env!(:salix_analytics, :slack_semantic_search)
      |> Keyword.put(:environment, "staging")
      |> Keyword.put(:enabled, false)

    Application.put_env(:salix_analytics, :slack_semantic_search, config)
    start_queue!()
    ts = System.os_time(:microsecond) - 1_000_000
    live_message!(ts, "index without an operator switch")

    eventually(fn ->
      assert indexed_text(ctx.database) =~ "index without an operator switch"

      assert {:ok, %{"messages" => [_]}} =
               queue_tool(%{"oldest" => slack_timestamp(ts), "latest" => slack_timestamp(ts + 1)})

      assert [["completed"]] =
               SalixStore.Repo.query!(
                 "SELECT state::text FROM slack_semantic.oban_jobs WHERE priority=0 AND args->>'kind'='text'"
               ).rows
    end)
  end

  test "production cannot enable semantic workers or queries with a legacy switch", ctx do
    message!(ctx.database, %{"text" => "ordinary history"})
    config = Application.fetch_env!(:salix_analytics, :slack_semantic_search)

    for environment <- ["prod", "production"] do
      Application.put_env(
        :salix_analytics,
        :slack_semantic_search,
        Keyword.merge(config, environment: environment, enabled: true)
      )

      assert SlackSemanticIndex.children() == []
      assert {:error, _} = tool()

      assert {:cancel, :indexing_disabled} =
               SalixAnalytics.SlackSemanticJob.perform(%Oban.Job{
                 args: %{"scope" => @scope, "timestamp" => @ts, "kind" => "text", "live" => true}
               })

      assert {:ok, %{"messages" => [_]}} = history()
    end

    refute Enum.any?(Agent.get(ctx.state, & &1.calls), &(elem(&1, 0) == "/embed"))
  end

  test "incomplete connection settings fail only semantic search", ctx do
    message!(ctx.database, %{"text" => "ordinary history"})

    for config <- [
          [environment: "staging"],
          [environment: "staging", url: "http://127.0.0.1:1/embed"]
        ] do
      Application.put_env(:salix_analytics, :slack_semantic_search, config)
      assert {:error, _} = tool()
      assert {:ok, %{"messages" => [_]}} = history()
    end

    refute Enum.any?(Agent.get(ctx.state, & &1.calls), &(elem(&1, 0) == "/embed"))
  end

  test "discovery failure leaves the reconciler and ordinary reads available", ctx do
    message!(ctx.database, %{"text" => "ordinary history"})
    Application.put_env(:salix_analytics, :slack_semantic_scope_source, UnavailableScopeSource)

    pid = start_supervised!({SlackSemanticIndexer, start_delay_ms: 0})
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
    assert {:ok, %{"messages" => [%{"text" => "ordinary history"}]}} = history()
    assert Process.alive?(pid)
    refute_receive :gpu_started
  end

  test "query parameters and work scopes reject unbounded requests before network", ctx do
    assert {:error, _} = tool(%{"count" => 21})
    assert {:error, _} = tool(%{"oldest" => "1.000000"})
    assert {:error, _} = tool(%{"channel" => "all"})
    assert {:error, _} = tool(%{"query" => String.duplicate("x", 4097)})
    assert Agent.get(ctx.state, & &1.calls) == []
    assert_raise ArgumentError, fn -> SlackSemanticIndexer.run(List.duplicate(@scope, 9)) end
  end

  test "all attachment modalities share vector retrieval and retain file locators", ctx do
    payload = Jason.encode!(%{"files" => [%{"id" => "F123", "mimetype" => "video/mp4"}]})
    message!(ctx.database, %{"payload" => payload})
    assert {:ok, [row]} = SlackSemanticIndex.missing_files(@scope, @ts - 1, @ts + 1)
    assert row["file_id"] == "F123"
    assert {:ok, _} = file_pass()
    assert {:ok, []} = SlackSemanticIndex.missing_files(@scope, @ts - 1, @ts + 1)
    assert {:ok, %{"messages" => [hit]}} = tool()
    assert hit["file_id"] == "F123"
    assert hit["content_kind"] in ~w(image video_segment ocr_text asr_transcript document_text)
    assert is_integer(hit["page"])
    assert hit["segment_end_ms"] > hit["segment_start_ms"]

    kinds =
      sql!(
        "SELECT arrayJoin(kinds) AS kind FROM #{ctx.database}.slack_semantic_files FORMAT JSONEachRow"
      )

    assert Enum.all?(
             ~w(image video_segment ocr_text asr_transcript document_text),
             &String.contains?(kinds, &1)
           )

    Agent.update(ctx.state, &%{&1 | mode: :file_deleted})
    assert {:ok, %{"messages" => []}} = tool()
    Agent.update(ctx.state, &%{&1 | mode: :ok})
    message!(ctx.database, %{"payload" => Jason.encode!(%{"files" => []})})
    assert {:ok, %{"messages" => []}} = tool()
  end

  test "interrupted media stream never publishes partial vectors and later pass retries", ctx do
    message!(ctx.database, %{"payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})})

    for mode <- [:media_partial, :upload_failure] do
      Agent.update(ctx.state, &%{&1 | mode: mode})
      assert {:error, :semantic_unavailable} = file_pass()
      assert String.trim(sql!("SELECT count() FROM #{ctx.database}.slack_semantic_files")) == "0"
    end

    assert {:ok, %{"messages" => []}} = tool()
    Agent.update(ctx.state, &%{&1 | mode: :ok})
    assert {:ok, _} = file_pass()
    assert {:ok, %{"messages" => [_]}} = tool()
    message!(ctx.database, %{"version" => 3, "deleted" => true})
    assert {:ok, %{"messages" => []}} = tool()
  end

  test "Block Kit file references and repeated messages produce one file candidate", ctx do
    payload =
      Jason.encode!(%{
        "blocks" => [
          %{
            "type" => "section",
            "accessory" => %{"type" => "image", "slack_file" => %{"id" => "F123"}}
          }
        ]
      })

    message!(ctx.database, %{"payload" => payload})

    message!(ctx.database, %{
      "payload" => payload,
      "message_ts_us" => @ts + 1,
      "message_ts" => "1780000000.000002"
    })

    scope = Map.merge(@scope, %{"group_id" => "test-group", "connect_id" => "test-connect"})

    assert {:ok, _} =
             SlackSemanticIndexer.run([scope],
               latest: @ts + 2,
               pace_ms: 0,
               file_source: FileSource
             )

    assert {:ok, %{"messages" => [%{"file_id" => "F123"}]}} =
             tool(%{"latest" => "1780000000.000003"})

    assert String.trim(sql!("SELECT count() FROM #{ctx.database}.slack_semantic_files")) == "2"
  end

  test "real background acquisition resolves its exact connect and streams through Slack and GPU",
       ctx do
    scope = seed_file_connect()
    message!(ctx.database, %{"payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})})

    assert {:ok, _} =
             SlackSemanticIndexer.run([scope],
               latest: @ts + 1,
               pace_ms: 0,
               file_source: SalixIM.SlackSemanticFiles
             )

    assert_receive {:file_download, ["Bearer test-token"]}
    assert {:ok, %{"messages" => [%{"file_id" => "F123"}]}} = tool()
    calls = Agent.get(ctx.state, & &1.calls)
    assert {"/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "source bytes"} in calls
    assert String.trim(sql!("SELECT count() FROM #{ctx.database}.slack_semantic_files")) == "1"
  end

  test "background file acquisition refuses cross-tenant connects, oversized files and credential redirects",
       ctx do
    scope = seed_file_connect()

    consume = fn _, _ ->
      send(self(), :refused_file_reached_inference)
      {:ok, []}
    end

    assert {:error, _} =
             SalixIM.SlackSemanticFiles.extract(
               Map.put(scope, "tenant_id", "foreign"),
               "F123",
               consume
             )

    assert Agent.get(ctx.state, & &1.calls) == []

    for mode <- [
          :oversized_file,
          :wrong_file_host,
          :file_redirect,
          :file_stream_error
        ] do
      Agent.update(ctx.state, &%{&1 | mode: mode, calls: []})
      assert {:error, _} = SalixIM.SlackSemanticFiles.extract(scope, "F123", consume)
      refute Enum.any?(Agent.get(ctx.state, & &1.calls), &(elem(&1, 0) == "/credential-trap"))
      refute_received :refused_file_reached_inference
    end
  end

  test "rendered canvas bytes need not equal Slack file metadata size", ctx do
    scope = seed_file_connect()
    Agent.update(ctx.state, &%{&1 | mode: :canvas})

    assert {:ok, {"application/vnd.slack-docs", "source bytes"}} =
             SalixIM.SlackSemanticFiles.extract(scope, "F123", fn path, mime ->
               {:ok, {mime, File.read!(path)}}
             end)
  end

  test "stalled attachment inference does not block ordinary message history", ctx do
    message!(ctx.database, %{
      "text" => "ordinary history",
      "payload" => Jason.encode!(%{"files" => [%{"id" => "F123"}]})
    })

    Agent.update(ctx.state, &%{&1 | mode: :media_slow})
    task = Task.async(fn -> file_pass() end)
    assert_receive :media_started, 2000
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{"messages" => [_]}} = history()
    assert System.monotonic_time(:millisecond) - started < 1500
    assert {:error, :semantic_unavailable} = Task.await(task, 17_000)
    assert {:ok, %{"messages" => [_]}} = history()
  end

  defp seed_file_connect do
    scope =
      Map.merge(@scope, %{
        "group_id" => "semantic-group-#{System.unique_integer([:positive])}",
        "connect_id" => "semantic-connect"
      })

    record =
      Map.merge(
        connect(),
        Map.merge(scope, %{
          "provider" => "slack",
          "oauth_completed_at" => System.os_time(:millisecond),
          "connect_generation" => "semantic-test-generation"
        })
      )

    {:ok, _} =
      SalixStore.CasRecord.create(
        SalixStore.Keys.ctl_im_connect(scope["group_id"], scope["connect_id"]),
        record
      )

    scope
  end

  defp file_pass do
    scope = Map.merge(@scope, %{"group_id" => "test-group", "connect_id" => "test-connect"})
    SlackSemanticIndexer.run([scope], latest: @ts + 1, pace_ms: 0, file_source: FileSource)
  end

  defp pass, do: SlackSemanticIndexer.run([@scope], latest: @ts + 1, pace_ms: 0)

  defp tool(extra \\ %{}) do
    params =
      Map.merge(
        %{
          "channel" => "C123",
          "query" => "rollback",
          "oldest" => "1780000000.000000",
          "latest" => "1780000000.000002"
        },
        extra
      )

    Slack.call(%{}, connect(), "slack.semantic_search", params)
  end

  defp history,
    do:
      Slack.call(%{}, connect(), "slack.get_channel_history", %{"channel" => "C123", "limit" => 1})

  defp connect,
    do:
      Map.merge(@scope, %{
        "bot_token" => "test-token",
        "app_id" => "A123",
        "bot_user_id" => "U123"
      })

  defp queue_tool(extra, scope \\ @queue_scope) do
    channel = extra["channel"] || "C123"

    timestamp = fn value ->
      [seconds, fraction] = String.split(value, ".")

      String.to_integer(seconds) * 1_000_000 +
        String.to_integer(String.pad_trailing(fraction, 6, "0"))
    end

    with {:ok, rows} <-
           queue_search(
             Map.put(scope, "channel_id", channel),
             extra["query"] || "rollback",
             timestamp.(extra["oldest"]),
             timestamp.(extra["latest"]),
             extra["count"] || 10
           ) do
      {:ok, %{"messages" => rows}}
    end
  end

  defp queue_search(scope, query, oldest, latest, count) do
    search_scope = %{tenant_id: scope["tenant_id"], group_id: scope["group_id"]}

    filters = %{
      mode: :semantic,
      oldest: oldest,
      latest: latest,
      workspace: scope["workspace_id"],
      channel: scope["channel_id"],
      sender: "",
      kind: ""
    }

    with {:ok, vector} <- SlackSemanticIndex.embed(query),
         {:ok, candidates} <-
           SalixAnalytics.SlackMessageSearchIndex.candidates(
             search_scope,
             [scope],
             query,
             vector,
             filters,
             count
           ),
         {:ok, published} <- SalixStore.SlackSearchSources.visible(candidates) do
      SalixAnalytics.SlackMessageSearchIndex.excerpts(
        search_scope,
        Enum.filter(candidates, &MapSet.member?(published, &1["build_id"]))
      )
    end
  end

  defp indexed_text(database) do
    sql!(
      "SELECT arrayStringConcat(chunks, '') AS source_text FROM #{database}.slack_message_search_components FINAL WHERE file_id='' ORDER BY message_ts_us, component FORMAT JSONEachRow"
    )
    |> String.split("\n", trim: true)
    |> Enum.map(&(Jason.decode!(&1)["source_text"] |> String.trim()))
    |> Enum.join("\n")
  end

  defp start_queue!(oban_overrides \\ []) do
    stop_supervised!(SlackSemanticIndex.HTTP)

    children =
      Enum.map(SlackSemanticIndex.children(), fn
        {Oban, opts} -> {Oban, Keyword.merge(opts, oban_overrides)}
        child -> child
      end)

    start_supervised!(%{
      id: :semantic_production_supervision,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    })
  end

  defp current_message!(database, timestamp, text, attrs \\ %{}) do
    message!(
      database,
      Map.merge(
        %{
          "event_date" =>
            timestamp
            |> DateTime.from_unix!(:microsecond)
            |> DateTime.to_date()
            |> Date.to_iso8601(),
          "message_ts_us" => timestamp,
          "message_ts" => slack_timestamp(timestamp),
          "text" => text
        },
        attrs
      )
    )
  end

  defp live_message!(timestamp, text, attrs \\ %{}) do
    row =
      Map.merge(@scope, %{
        "event_date" =>
          timestamp
          |> DateTime.from_unix!(:microsecond)
          |> DateTime.to_date()
          |> Date.to_iso8601(),
        "message_ts_us" => timestamp,
        "message_ts" => slack_timestamp(timestamp),
        "thread_ts" => "",
        "version" => System.os_time(:microsecond),
        "text" => text,
        "body_text" => "",
        "deleted" => false,
        "ingest_source" => "webhook",
        "_semantic_context" => %{"group_id" => "test-group", "connect_id" => "test-connect"}
      })

    assert :ok = SalixIM.SlackMessageMirror.write_batch([Map.merge(row, attrs)])
  end

  defp slack_timestamp(timestamp),
    do:
      "#{div(timestamp, 1_000_000)}.#{String.pad_leading(to_string(rem(timestamp, 1_000_000)), 6, "0")}"

  defp message!(database, attrs) do
    row =
      Map.merge(@scope, %{
        "event_date" => "2026-05-28",
        "message_ts_us" => @ts,
        "message_ts" => "1780000000.000001",
        "thread_ts" => "",
        "version" => 1,
        "text" => "",
        "body_text" => "",
        "deleted" => false
      })
      |> Map.merge(attrs)

    insert!(database, "slack_messages", Map.put(row, "source_write_id", Ecto.UUID.generate()))
  end

  defp insert!(database, table, row),
    do: sql!("INSERT INTO #{database}.#{table} FORMAT JSONEachRow\n" <> Jason.encode!(row))

  defp sql!(sql) do
    response = Req.post!(@url, body: sql, retry: false)
    assert response.status == 200, "ClickHouse failed: #{inspect(response.body)}"
    response.body
  end

  defp eventually(assertion, attempts \\ 60) do
    assertion.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(100)
      eventually(assertion, attempts - 1)
  end
end
