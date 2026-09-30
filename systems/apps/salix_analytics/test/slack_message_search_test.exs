defmodule SalixAnalytics.SlackMessageSearchTest do
  use ExUnit.Case, async: false
  @moduletag :clickhouse
  alias SalixAnalytics.{
    SlackMessageSearch,
    SlackMessageSearchIndex,
    SlackMessageSearchIndexer,
    SlackSemanticIndex
  }

  alias SalixIM.{Provider, SlackMessageMirror}
  alias SalixIM.SlackMessageMirror.Row

  alias SalixStore.{
    CasRecord,
    Ids,
    Keys,
    Repo,
    SlackMirrorOutbox,
    SlackSearchCatalog,
    SlackSearchSources,
    SlackSearchFiles
  }

  @url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")
  @ts 1_600_000_000_000_000

  defmodule Encoder do
    import Plug.Conn
    def init(state), do: state

    def call(conn, {state, owner}) do
      {:ok, body, conn} = read_body(conn)
      Agent.update(state, &[{conn.request_path, body} | &1])
      if conn.request_path != "/embed", do: raise("search attempted a provider call")

      case Jason.decode!(body)["text"] do
        "busy-query" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            429,
            Jason.encode!(%{"detail" => "embedding_busy", "debug" => "private-provider-detail"})
          )

        text ->
          if text == "held-query" do
            send(owner, {:embedding_request, self()})

            receive do
              :complete_embedding -> :ok
            after
              2000 -> raise("test did not release embedding response")
            end
          end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"embedding" => [1.0 | List.duplicate(0.0, 255)]}))
      end
    end
  end

  defmodule LongVideo do
    def extract(_scope, _file, _consumer, _opts) do
      {:ok,
       for n <- 1..500 do
         %{
           "text" => "video segment #{n}",
           "content_kind" => "video_segment",
           "page" => 0,
           "segment_start_ms" => n * 1000,
           "segment_end_ms" => n * 1000 + 1000,
           "embedding" => [1.0 | List.duplicate(0.0, 255)]
         }
       end}
    end
  end

  defmodule ChangedVideo do
    def extract(scope, file_id, consumer, opts) do
      :ok =
        SlackSearchFiles.observe(scope, %{
          "event" => %{"type" => "file_change", "file_id" => file_id}
        })

      LongVideo.extract(scope, file_id, consumer, opts)
    end
  end

  defmodule LargeDocument do
    def extract(_scope, _file, _consumer, _opts) do
      {:ok,
       for n <- 1..1024 do
         %{
           "text" => if(n == 1, do: "", else: "page #{n} " <> String.duplicate("📄", 390)),
           "content_kind" => if(n == 1, do: "image", else: "document_text"),
           "page" => div(n - 1, 3) + 1,
           "segment_start_ms" => 0,
           "segment_end_ms" => 0,
           "embedding" => [1.0 | List.duplicate(0.0, 255)]
         }
       end}
    end
  end

  defmodule ShortFile do
    def extract(scope, file, consumer, opts) do
      {:ok, units} = LongVideo.extract(scope, file, consumer, opts)
      {:ok, Enum.take(units, 1)}
    end
  end

  defmodule ReplacementVideo do
    def extract(scope, file, consumer, opts) do
      {:ok, [unit]} = ShortFile.extract(scope, file, consumer, opts)

      {:ok,
       [
         %{
           unit
           | "text" => "replacement clip",
             "embedding" => [0.0, 1.0 | List.duplicate(0.0, 254)]
         }
       ]}
    end
  end

  defmodule SlowReader do
    def active?, do: true

    def candidates(_, _, _) do
      send(Process.whereis(__MODULE__), {:search_waiting, self()})
      Process.sleep(11_000)
      {:ok, []}
    end
  end

  setup_all do
    level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: level) end)
    {:ok, _} = Application.ensure_all_started(:req)
    SalixStore.RepoTestSetup.ensure!()
    :ok
  end

  setup do
    Repo.query!(
      "TRUNCATE slack_semantic.search_windows, slack_semantic.search_components, slack_semantic.search_sources, slack_semantic.search_files, slack_semantic.search_connects, slack_semantic.search_channels, slack_semantic.search_cursors, slack_mirror_source_writes"
    )

    if is_nil(Process.whereis(SalixStore.S3.Fake)), do: start_supervised!(SalixStore.S3.Fake)
    database = "slack_message_search_#{System.unique_integer([:positive])}"
    sql!("CREATE DATABASE #{database}")

    Application.app_dir(:salix_analytics, "priv/clickhouse/migrations/*.sql")
    |> Path.wildcard()
    |> Enum.filter(&String.contains?(&1, "slack_"))
    |> Enum.sort()
    |> Enum.each(fn path ->
      path
      |> File.read!()
      |> String.replace("{{database}}", database)
      |> String.replace(~r/^\s*--.*$/m, "")
      |> String.split(";", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.each(&sql!/1)
    end)

    calls = start_supervised!({Agent, fn -> [] end})

    server =
      start_supervised!({Bandit, plug: {Encoder, {calls, self()}}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    settings = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_analytics, :clickhouse, [base_url: @url, database: database]},
      {:salix_analytics, :slack_semantic_search,
       [
         environment: "test",
         url: "http://127.0.0.1:#{port}/embed",
         client_id: "test",
         client_secret: "test"
       ]},
      {:salix_analytics, :slack_semantic_file_source, LongVideo},
      {:salix_im, :slack_message_search_reader, SlackMessageSearch},
      {:salix_im, :slack_message_mirror_mod, SalixAnalytics.SlackMirror},
      {:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api"},
      {:salix_agent, :im_provider_mod, Provider}
    ]

    previous =
      Enum.map(settings, fn {app, key, _} -> {app, key, Application.get_env(app, key)} end)

    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)

    # Use the production pool selection at the real HTTP boundary.
    {Finch, _} = http = Enum.find(SlackSemanticIndex.children(), &match?({Finch, _}, &1))
    start_supervised!(http)

    on_exit(fn ->
      sql!("DROP DATABASE IF EXISTS #{database}")

      Enum.each(previous, fn {app, key, value} ->
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end)
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    {:ok, _} =
      CasRecord.create(Keys.ctl_group(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "router_conversation_id" => Ids.new_conversation_id()
      })

    a = agent!(tenant, group)
    b = agent!(tenant, group)

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => Ids.new_connect_id(),
      "connect_generation" => "generation-1",
      "workspace_id" => "T123",
      "bot_token" => "test-token",
      "oauth_completed_at" => 1
    }

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)
    :ok = SlackSearchCatalog.remember_connects([connect])

    %{
      database: database,
      calls: calls,
      tenant: tenant,
      group: group,
      a: a,
      b: b,
      connect: connect
    }
  end

  test "four query requests can reach the GPU alongside two background transfers", _ctx do
    requests =
      Task.async(fn ->
        1..6
        |> Task.async_stream(
          fn n -> SlackSemanticIndex.embed("held-query", background: n > 4) end,
          max_concurrency: 6,
          timeout: 4000
        )
        |> Enum.to_list()
      end)

    owners =
      for _ <- 1..6 do
        assert_receive {:embedding_request, owner}, 1000
        owner
      end

    Enum.each(owners, &send(&1, :complete_embedding))
    assert Enum.all?(Task.await(requests, 4000), &match?({:ok, {:ok, [_ | _]}}, &1))
  end

  test "embedding busy remains actionable after tool result sanitization", ctx do
    call = %{
      id: "busy-query",
      name: "im_api.slack.semantic_search",
      args: %{"query" => "busy-query", "kind" => "image", "mode" => "semantic"}
    }

    [result] =
      SalixAgent.Tools.execute([call], %{agent_id: ctx.a, role: "worker", calls_prepared: true})

    assert result.error
    assert result.error_class == "search_busy"
    assert result.diagnostic_visibility == "user_reportable"
    assert result.public_summary == "Message search is busy; retry shortly."

    [visible] =
      SalixAgent.VisibleReplyPolicy.sanitize_context([Map.put(result, :role, "tool")], :clean)

    assert Jason.decode!(visible.content) == %{
             "status" => "error",
             "public_summary" => result.public_summary
           }

    refute visible.content =~ "private-provider-detail"

    assert {:error, :semantic_unavailable} =
             SlackSemanticIndex.embed("busy-query", background: true)
  end

  test "the actual tool searches retained history across channels for both group agents", ctx do
    for {channel, text, n} <- [{"C101", "部署 rollback 原因", 1}, {"C202", "旧频道部署记录", 2}] do
      write!(ctx, channel, @ts + n, text)
      assert :ok = SlackMessageSearchIndexer.text(scope(ctx, channel), @ts + n, 0)
    end

    for agent <- [ctx.a, ctx.b] do
      result =
        SalixAgent.Tools.ImRouter.call_dynamic_operation(
          "im_api.slack.semantic_search",
          %{"query" => "部署", "count" => 20},
          %{agent_id: agent, role: "worker"}
        )
        |> Jason.decode!()

      assert MapSet.new(result["messages"], & &1["channel"]) == MapSet.new(["C101", "C202"])
      assert result["coverage"]["oldest"] == "0.000000"
    end

    assert Enum.all?(Agent.get(ctx.calls, & &1), fn {path, _} -> path == "/embed" end)

    assert String.contains?(
             sql!("SHOW CREATE TABLE #{ctx.database}.slack_message_search_components"),
             "index_granularity = 2048"
           )
  end

  test "accepted edits and same-version late payloads hide stale excerpts", ctx do
    original = write!(ctx, "C101", @ts, "old deploy")
    :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)
    assert {:ok, %{"messages" => [_]}} = search(ctx, %{"query" => "deploy", "mode" => "keyword"})

    edited = %{
      original
      | "text" => "new deploy",
        "payload" => Jason.encode!(%{"text" => "new deploy"})
    }

    assert :ok = SlackMirrorOutbox.append(edited, "message", ctx.connect)
    assert {:ok, %{"messages" => []}} = search(ctx, %{"query" => "deploy", "mode" => "keyword"})
    {:ok, entries} = SlackMirrorOutbox.claim(200, 60_000)
    entry = Enum.find(entries, &(&1.row["tenant_id"] == ctx.tenant))

    assert :ok =
             SlackMessageMirror.write_batch([Map.put(entry.row, "_mirror_outbox_id", entry.id)])

    assert :ok = SlackMirrorOutbox.delete([entry.id])
    :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)

    assert {:ok, %{"messages" => [%{"text" => text}]}} =
             search(ctx, %{"query" => "deploy", "mode" => "keyword"})

    assert text =~ "new deploy"

    # A settled old request may still arrive. PG's epoch stays unchanged;
    # the actual payload-row identity must invalidate the new index.
    payload =
      Map.take(
        original,
        ~w(event_date tenant_id workspace_id channel_id message_ts_us version payload text body_text source_write_id)
      )

    sql!(
      "INSERT INTO #{ctx.database}.slack_message_payloads FORMAT JSONEachRow\n" <>
        Jason.encode!(payload)
    )

    assert {:ok, %{"messages" => []}} = search(ctx, %{"query" => "deploy", "mode" => "keyword"})
  end

  test "long text continues beyond 8000 characters and keyword reads do not call the encoder",
       ctx do
    body = String.duplicate("ordinary text ", 700) <> "TAIL_NEEDLE"
    write!(ctx, "C101", @ts, body)
    assert {:continue, next} = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)
    assert :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, next)
    Agent.update(ctx.calls, fn _ -> [] end)

    assert {:ok, %{"messages" => [%{"text" => text}]}} =
             search(ctx, %{"query" => "tail_needle", "mode" => "keyword"})

    assert text =~ "TAIL_NEEDLE"
    assert Agent.get(ctx.calls, & &1) == []
  end

  test "one 500-unit video cannot occupy a message page and revocation applies to later pages",
       ctx do
    for n <- 1..41 do
      write!(ctx, "C101", @ts + n, "deploy #{n}")
      assert :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts + n, 0)
    end

    write!(ctx, "C101", @ts + 42, "video", [%{"id" => "F123"}])
    assert :ok = SlackMessageSearchIndexer.file(scope(ctx, "C101"), @ts + 42, "F123")

    assert {:ok, first} = search(ctx, %{"query" => "deploy", "mode" => "semantic", "count" => 20})
    assert length(first["messages"]) == 20
    assert Enum.count(first["messages"], &(&1["file_id"] == "F123")) == 1
    assert {:ok, second} = search(ctx, %{"cursor" => first["next_cursor"]})
    assert length(second["messages"]) == 20
    assert Enum.uniq_by(first["messages"] ++ second["messages"], & &1["ts"]) |> length() == 40

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(ctx.group, ctx.connect["connect_id"]),
        &Map.put(&1, "disabled_at", 1)
      )

    assert {:ok, %{"messages" => [], "next_cursor" => nil}} =
             search(ctx, %{"cursor" => second["next_cursor"]})
  end

  @tag :excerpt_memory
  test "an image page from large documents fits the existing search memory budget", ctx do
    Application.put_env(:salix_analytics, :slack_semantic_file_source, LargeDocument)

    for n <- 1..20 do
      file = "FLARGE#{n}"
      write!(ctx, "C101", @ts + n, "studio document", [%{"id" => file}])
      assert :ok = SlackMessageSearchIndexer.file(scope(ctx, "C101"), @ts + n, file)
    end

    assert {:ok, %{"messages" => hits}} =
             search(ctx, %{
               "query" => "studio",
               "kind" => "image",
               "mode" => "semantic",
               "count" => 20
             })

    assert length(hits) == 20
    assert MapSet.new(hits, & &1["file_id"]) == MapSet.new(1..20, &"FLARGE#{&1}")

    assert Enum.all?(
             hits,
             &(&1["content_kind"] == "image" and &1["page"] == 1 and &1["text"] == "")
           )
  end

  @tag :excerpt_selection
  test "component excerpts preserve requested unit sets and reject superseded builds", ctx do
    write!(ctx, "C101", @ts, "video", [%{"id" => "F123"}])
    s = scope(ctx, "C101")
    assert :ok = SlackMessageSearchIndexer.file(s, @ts, "F123")
    reader_scope = %{tenant_id: ctx.tenant, group_id: ctx.group}

    request = %{
      "query" => "video",
      "mode" => "semantic",
      "kind" => "video_segment",
      "oldest" => 0,
      "latest" => @ts + 1,
      "workspace" => "",
      "channel" => ""
    }

    assert {:ok, [candidate]} =
             SlackMessageSearch.candidates(reader_scope, [ctx.connect], request)

    requested = [
      Map.put(candidate, "unit", 500),
      candidate,
      candidate,
      Map.put(candidate, "unit", 0),
      Map.put(candidate, "unit", 501),
      Map.put(candidate, "build_id", Ecto.UUID.generate())
    ]

    assert {:ok, excerpts} = SlackMessageSearchIndex.excerpts(reader_scope, requested)
    assert Enum.sort(Enum.map(excerpts, & &1["unit"])) == [1, 500]

    for row <- excerpts do
      assert row["text"] == "video segment #{row["unit"]}"
      assert row["segment_start_ms"] == row["unit"] * 1000
      assert row["segment_end_ms"] == (row["unit"] + 1) * 1000
      assert row["content_kind"] == "video_segment"
    end

    :ok =
      SlackSearchFiles.observe(s, %{"event" => %{"type" => "file_change", "file_id" => "F123"}})

    Application.put_env(:salix_analytics, :slack_semantic_file_source, ReplacementVideo)
    assert :ok = SlackMessageSearchIndexer.file(s, @ts, "F123")
    assert {:ok, []} = SlackMessageSearchIndex.excerpts(reader_scope, requested)
  end

  test "literal phrases span text slices, honor sender, and keep all source text searchable",
       ctx do
    phrase = String.duplicate("跨边界检索", 90)
    body = String.duplicate("前", 350) <> phrase <> String.duplicate("后", 1100)
    write!(ctx, "C101", @ts, body)
    assert :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)

    assert {:ok, %{"messages" => [hit]}} =
             search(ctx, %{"query" => phrase, "mode" => "keyword", "sender" => "U123"})

    assert hit["text"] =~ phrase
    assert hit["match_start"] == 350
    assert hit["match_end"] == 800

    assert {:ok, %{"messages" => []}} =
             search(ctx, %{"query" => phrase, "mode" => "hybrid", "sender" => "U999"})
  end

  test "credential and Triage generation changes preserve retained data; workspace and channel ownership do not",
       ctx do
    write!(ctx, "C101", @ts, "retained archive")
    :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)
    key = Keys.ctl_im_connect(ctx.group, ctx.connect["connect_id"])

    {:ok, _} =
      CasRecord.update(key, fn c ->
        c |> Map.put("connect_generation", "generation-2") |> Map.delete("bot_token")
      end)

    assert {:ok, %{"messages" => [_]}} = search(ctx, %{"query" => "archive", "mode" => "keyword"})
    {:ok, _} = CasRecord.update(key, &Map.put(&1, "workspace_id", "TOTHER"))
    assert {:ok, %{"messages" => []}} = search(ctx, %{"query" => "archive", "mode" => "keyword"})
    {:ok, _} = CasRecord.update(key, &Map.put(&1, "workspace_id", "T123"))

    Repo.query!("DELETE FROM slack_semantic.search_channels WHERE tenant_id=$1 AND group_id=$2", [
      ctx.tenant,
      ctx.group
    ])

    assert {:ok, %{"messages" => []}} = search(ctx, %{"query" => "archive", "mode" => "keyword"})
  end

  test "group and tenant scope cannot be supplied by a caller or reused through another group's cursor",
       ctx do
    for n <- 1..3 do
      write!(ctx, "C101", @ts + n, "scope evidence #{n}")
      :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts + n, 0)
    end

    assert {:ok, first} = search(ctx, %{"query" => "evidence", "mode" => "keyword", "count" => 1})
    group = Ids.new_group_id(ctx.tenant)

    {:ok, _} =
      CasRecord.create(Keys.ctl_group(group), %{
        "tenant_id" => ctx.tenant,
        "group_id" => group,
        "router_conversation_id" => Ids.new_conversation_id()
      })

    other = %{ctx | a: agent!(ctx.tenant, group), group: group}

    assert {:ok, %{"messages" => []}} =
             search(other, %{"query" => "evidence", "mode" => "keyword"})

    assert {:error, _} = search(other, %{"cursor" => first["next_cursor"]})
    assert {:error, _} = search(other, %{"query" => "evidence", "group_id" => ctx.group})
  end

  test "known file changes fence in-flight extraction and deletion removes all stale media",
       ctx do
    write!(ctx, "C101", @ts, "attachment", [%{"id" => "F123"}])
    s = scope(ctx, "C101")
    :ok = SlackMessageSearchIndexer.file(s, @ts, "F123")

    assert {:ok, %{"messages" => [_]}} =
             search(ctx, %{"query" => "video segment", "mode" => "keyword"})

    :ok =
      SlackMessageMirror.observe(ctx.connect, %{
        "event" => %{"type" => "file_change", "file_id" => "F123"}
      })

    assert {:ok, %{"messages" => []}} =
             search(ctx, %{"query" => "video segment", "mode" => "keyword"})

    Application.put_env(:salix_analytics, :slack_semantic_file_source, ChangedVideo)
    assert {:error, :file_changed} = SlackMessageSearchIndexer.file(s, @ts, "F123")

    assert {:ok, %{"messages" => []}} =
             search(ctx, %{"query" => "video segment", "mode" => "keyword"})

    Application.put_env(:salix_analytics, :slack_semantic_file_source, LongVideo)
    assert :ok = SlackMessageSearchIndexer.file(s, @ts, "F123")

    assert {:ok, %{"messages" => [_]}} =
             search(ctx, %{"query" => "video segment", "mode" => "keyword"})

    :ok =
      SlackSearchFiles.observe(ctx.connect, %{
        "event" => %{"type" => "file_change", "file_id" => "F123"}
      })

    Application.put_env(:salix_analytics, :slack_semantic_file_source, ReplacementVideo)
    assert :ok = SlackMessageSearchIndexer.file(s, @ts, "F123")
    # The old packet has better vector similarity; it must be removed before
    # source ranking so that final publication filtering cannot hide this hit.
    assert {:ok, %{"messages" => [%{"text" => "replacement clip"}]}} =
             search(ctx, %{
               "query" => "video segment",
               "mode" => "semantic",
               "kind" => "video_segment"
             })

    :ok =
      SlackMessageMirror.observe(ctx.connect, %{
        "event" => %{"type" => "file_deleted", "file_id" => "F123"}
      })

    assert {:ok, %{"messages" => []}} =
             search(ctx, %{"query" => "video segment", "mode" => "keyword"})

    assert :ok = SlackMessageSearchIndexer.file(s, @ts, "F123")

    assert sql!(
             "SELECT sum(length(embeddings)) FROM #{ctx.database}.slack_message_search_components FINAL WHERE file_id='F123'"
           ) == "0\n"
  end

  test "legacy row initialization changes only zero identities and keeps history content intact",
       ctx do
    {:ok, row} =
      Row.from_history(
        ctx.connect,
        "C101",
        %{"ts" => ts(@ts), "text" => "legacy body", "user" => "U123"},
        @ts + 1
      )

    # Simulate an old binary, which never knows the new source ID column.
    assert :ok = SalixAnalytics.SlackMirror.record_batch([row])
    existing = write!(ctx, "C101", @ts + 1, "new writer body")
    assert {:ok, [source]} = SlackMessageSearchIndex.source(scope(ctx, "C101"), @ts)
    assert source["message_identity"] != "00000000-0000-0000-0000-000000000000"
    assert source["payload_identity"] != "00000000-0000-0000-0000-000000000000"
    assert source["source_text"] =~ "legacy body"
    assert source["source_version"] == row["version"]
    assert {:ok, [again]} = SlackMessageSearchIndex.source(scope(ctx, "C101"), @ts)
    assert again["message_identity"] == source["message_identity"]
    assert {:ok, [unchanged]} = SlackMessageSearchIndex.source(scope(ctx, "C101"), @ts + 1)
    assert unchanged["message_identity"] == existing["source_write_id"]
    :ok = SlackSearchCatalog.remember_channels(ctx.connect, ["C101"])
    assert :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)

    assert {:ok, %{"messages" => [_]}} =
             search(ctx, %{"query" => "legacy body", "mode" => "keyword"})
  end

  test "history replay survives a writer crash without entering the live Triage stream", ctx do
    {:ok, row} =
      Row.from_history(
        ctx.connect,
        "C101",
        %{"ts" => ts(@ts), "text" => "durable history", "user" => "U123"},
        @ts + 1
      )

    {:ok, [frozen]} =
      SlackMirrorOutbox.admit_messages([Map.put(row, "_semantic_context", ctx.connect)])

    assert {:error, :source_pending} = SlackSearchSources.capture(scope(ctx, "C101"), @ts)
    assert {:ok, []} = SlackMirrorOutbox.claim(200, 60_000)
    assert :idle = SalixIM.SlackMessageMirror.OutboxDrainer.drain_once()
    assert {:ok, _} = SlackSearchSources.capture(scope(ctx, "C101"), @ts)
    assert sql!("SELECT count() FROM #{ctx.database}.slack_message_event_triggers") == "0\n"
    assert :ok = SlackMessageMirror.write_batch([frozen])
    assert {:ok, [source]} = SlackMessageSearchIndex.source(scope(ctx, "C101"), @ts)
    assert source["message_identity"] == frozen["source_write_id"]
    assert source["source_text"] =~ "durable history"
    assert :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts, 0)

    assert {:ok, %{"messages" => [_]}} =
             search(ctx, %{"query" => "durable history", "mode" => "keyword"})

    assert sql!("SELECT count() FROM #{ctx.database}.slack_message_event_triggers") == "0\n"

    assert String.contains?(
             sql!("SHOW CREATE TABLE #{ctx.database}.slack_messages"),
             "index_granularity = 8192"
           )
  end

  test "shared occurrences across two connects still produce one hit per source", ctx do
    other = Map.put(ctx.connect, "connect_id", Ids.new_connect_id())
    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(ctx.group, other["connect_id"]), other)
    :ok = SlackSearchCatalog.remember_connects([other])
    :ok = SlackSearchCatalog.remember_channels(other, ["C101"])

    for n <- 1..5 do
      write!(ctx, "C101", @ts + n, "shared occurrence #{n}")
      :ok = SlackMessageSearchIndexer.text(scope(ctx, "C101"), @ts + n, 0)
      :ok = SlackMessageSearchIndexer.text(Map.put(other, "channel_id", "C101"), @ts + n, 0)
    end

    for mode <- ~w(keyword semantic hybrid) do
      assert {:ok, %{"messages" => hits}} =
               search(ctx, %{"query" => "shared", "mode" => mode, "count" => 20})

      assert length(hits) == 5
      assert length(Enum.uniq_by(hits, & &1["ts"])) == 5

      assert {:ok, %{"messages" => narrowed}} =
               Provider.call_api(ctx.a, "slack", "slack.message_search", %{
                 "connect_id" => other["connect_id"],
                 "params" => %{"query" => "shared", "mode" => mode, "count" => 20}
               })

      assert length(narrowed) == 5
      assert Enum.all?(narrowed, &(&1["connect_id"] == other["connect_id"]))
    end
  end

  test "a stalled dependency is cancelled within the whole search budget", ctx do
    Process.register(self(), SlowReader)
    Application.put_env(:salix_im, :slack_message_search_reader, SlowReader)
    started = System.monotonic_time(:millisecond)
    assert {:error, message} = search(ctx, %{"query" => "timeout", "mode" => "keyword"})
    assert message =~ "timed out"
    assert System.monotonic_time(:millisecond) - started < 11_000
    assert_receive {:search_waiting, worker}
    refute Process.alive?(worker)
  end

  test "file refresh pages commit with jobs and a failed page cannot skip a reference", ctx do
    Application.put_env(:salix_analytics, :slack_semantic_file_source, ShortFile)

    for n <- 1..21 do
      write!(ctx, "C101", @ts + n, "file reference #{n}", [%{"id" => "FREFRESH"}])
      :ok = SlackMessageSearchIndexer.file(scope(ctx, "C101"), @ts + n, "FREFRESH")
    end

    :ok =
      SlackMessageMirror.observe(ctx.connect, %{
        "event" => %{"type" => "file_change", "file_id" => "FREFRESH"}
      })

    Repo.query!("TRUNCATE slack_semantic.oban_jobs")

    opts =
      SalixAnalytics.SlackSemanticQueue.oban_options()
      |> Keyword.put(:queues, [])
      |> Keyword.put(:plugins, [])

    start_supervised!({Oban, opts})
    enqueue = &SalixAnalytics.SlackSemanticQueue.enqueue(&1, &2, "file", true, &3)

    assert {:error, :page_interrupted} =
             SlackSearchFiles.reconcile_page(fn s, ts, f ->
               if ts == @ts + 2, do: {:error, :page_interrupted}, else: enqueue.(s, ts, f)
             end)

    assert [[0]] = Repo.query!("SELECT count(*) FROM slack_semantic.oban_jobs").rows
    assert {:ok, :advanced} = SlackSearchFiles.reconcile_page(enqueue)
    assert [[20]] = Repo.query!("SELECT count(*) FROM slack_semantic.oban_jobs").rows
    assert {:ok, :advanced} = SlackSearchFiles.reconcile_page(enqueue)

    assert [[21, 21]] =
             Repo.query!(
               "SELECT count(*), count(DISTINCT args->>'timestamp') FROM slack_semantic.oban_jobs"
             ).rows

    assert {:ok, :idle} = SlackSearchFiles.reconcile_page(enqueue)
  end

  defp search(ctx, params),
    do: Provider.call_api(ctx.a, "slack", "slack.message_search", %{"params" => params})

  defp scope(ctx, channel), do: Map.put(ctx.connect, "channel_id", channel)

  defp write!(ctx, channel, timestamp, text, files \\ []) do
    message = %{"ts" => ts(timestamp), "text" => text, "user" => "U123", "files" => files}
    {:ok, row} = Row.from_history(ctx.connect, channel, message, timestamp + 1)
    assert :ok = SlackMessageMirror.write_batch([Map.put(row, "_semantic_context", ctx.connect)])

    %{"source_write_id" => id} =
      sql!(
        "SELECT toString(source_write_id) AS source_write_id FROM #{ctx.database}.slack_messages FINAL WHERE tenant_id='#{ctx.tenant}' AND channel_id='#{channel}' AND message_ts_us=#{timestamp} FORMAT JSONEachRow"
      )
      |> Jason.decode!()

    Map.put(row, "source_write_id", id)
  end

  defp agent!(tenant, group) do
    id = Ids.new_agent_id(group)

    {:ok, _} =
      CasRecord.create(Keys.ctl_agent(id), %{
        "agent_id" => id,
        "tenant_id" => tenant,
        "group_id" => group,
        "role" => "worker",
        "heartbeat_schedule_id" => Ids.new_schedule_id()
      })

    id
  end

  defp ts(us),
    do:
      "#{div(us, 1_000_000)}.#{us |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")}"

  defp sql!(sql) do
    {:ok, %{status: 200, body: body}} =
      Req.post(@url,
        body: sql,
        headers: [{"connection", "close"}],
        decode_body: false,
        retry: false,
        receive_timeout: 30_000
      )

    body
  end
end
