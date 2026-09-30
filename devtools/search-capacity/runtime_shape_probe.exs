# Run through the systems umbrella's salix_analytics Mix application.
# All bodies, owner records and encoder responses are local synthetic fixtures.
Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:req)
SalixStore.RepoTestSetup.ensure!()

if System.get_env("SEARCH_PROBE_INIT_ONLY") != "1" do
  defmodule SearchRuntimeProbe.Encoder do
    import Plug.Conn
    def init(vectors), do: vectors

    def call(conn, vectors) do
      {:ok, body, conn} = read_body(conn)
      query = Jason.decode!(body)["text"]
      vector = Enum.at(vectors, :erlang.phash2(query, length(vectors)))

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"embedding" => vector}))
    end
  end

  defmodule SearchRuntimeProbe do
    alias SalixStore.{CasRecord, Keys, SlackSearchCatalog}

    def run do
      dir = System.fetch_env!("SEARCH_PROBE_DIRECTORY")
      fixture = File.read!(Path.join(dir, "fixture.json")) |> Jason.decode!()
      url = System.fetch_env!("SALIX_TEST_CLICKHOUSE_URL")
      database = fixture["database"]
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      if is_nil(Process.whereis(SalixStore.S3.Fake)), do: SalixStore.S3.Fake.start_link()

      Application.put_env(:salix_analytics, :clickhouse,
        base_url: url,
        database: database,
        table: "#{database}.events"
      )

      vectors =
        sql!(
          url,
          "SELECT embeddings[1] AS vector FROM #{database}.slack_message_search_components LIMIT 97 FORMAT JSONEachRow"
        )
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!(&1)["vector"])

      {:ok, server} =
        Bandit.start_link(
          plug: {SearchRuntimeProbe.Encoder, vectors},
          ip: {127, 0, 0, 1},
          port: 0
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)

      Application.put_env(:salix_analytics, :slack_semantic_search,
        environment: "test",
        url: "http://127.0.0.1:#{port}/embed",
        client_id: "fixture",
        client_secret: "fixture"
      )

      Application.put_env(
        :salix_im,
        :slack_message_search_reader,
        SalixAnalytics.SlackMessageSearch
      )

      {:ok, _} =
        Finch.start_link(
          name: SalixAnalytics.SlackSemanticIndex.HTTP,
          pools: %{default: [size: 3, count: 1]}
        )

      for {group, scopes} <- Enum.group_by(fixture["scopes"], & &1["group_id"]) do
        tenant = hd(scopes)["tenant_id"]
        agent = agent_id(group)

        {:ok, _} =
          CasRecord.create(Keys.ctl_group(group), %{
            "group_id" => group,
            "tenant_id" => tenant,
            "router_conversation_id" => "cnv1_1000000000000000500"
          })

        {:ok, _} =
          CasRecord.create(Keys.ctl_agent(agent), %{
            "agent_id" => agent,
            "group_id" => group,
            "tenant_id" => tenant,
            "role" => "worker",
            "heartbeat_schedule_id" => "sch1_1000000000000000600"
          })

        for {_id, channels} <- Enum.group_by(scopes, & &1["connect_id"]) do
          connect =
            hd(channels)
            |> Map.drop(["channel_id"])
            |> Map.merge(%{"provider" => "slack", "oauth_completed_at" => 1})

          {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)
          :ok = SlackSearchCatalog.remember_connects([connect])

          :ok =
            SlackSearchCatalog.remember_channels(connect, Enum.map(channels, & &1["channel_id"]))
        end
      end

      # The only source tenant with semantic units is selected from the index,
      # not inferred from the anonymized tenant's ordering.
      group =
        sql!(
          url,
          "SELECT group_id FROM #{database}.slack_message_search_components GROUP BY group_id ORDER BY sum(length(embeddings)) DESC LIMIT 1"
        )
        |> String.trim()

      agent = agent_id(group)
      channels = Enum.filter(fixture["scopes"], &(&1["group_id"] == group))

      if System.get_env("SEARCH_PROBE_NEIGHBOR_ONLY") == "1" do
        neighbor = neighbor_probe(url, database, hd(channels), agent, fixture)
        File.write!(Path.join(dir, "neighbor.json"), Jason.encode!(neighbor, pretty: true))
      else
        storage_parts =
          sql!(url, """
          SELECT table, partition, count() AS parts, sum(rows) AS rows
          FROM system.parts WHERE active AND database='#{database}'
          GROUP BY table, partition FORMAT JSONEachRow
          """)
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        started_at = DateTime.utc_now()

        cases =
          for mode <- ~w(keyword semantic hybrid), concurrency <- [1, 4] do
            results =
              0..39
              |> Task.async_stream(
                fn n ->
                  params = %{
                    "query" => "marker_#{String.pad_leading(to_string(rem(n * 13, 97)), 2, "0")}",
                    "mode" => mode,
                    "count" => 20,
                    "latest" => timestamp(fixture["reference_end_us"])
                  }

                  timed(agent, params)
                end,
                max_concurrency: concurrency,
                timeout: 15_000,
                ordered: true
              )
              |> Enum.map(fn
                {:ok, r} -> r
                other -> %{error: inspect(other), elapsed_ms: 15_000}
              end)

            record =
              summarize(results)
              |> Map.merge(%{
                mode: mode,
                concurrency: concurrency,
                scope: "whole_group",
                samples: results
              })

            IO.puts(Jason.encode!(Map.drop(record, [:samples])))
            record
          end

        channel_cases =
          for scope <- channels do
            result =
              timed(agent, %{
                "query" => "marker_13",
                "mode" => "hybrid",
                "count" => 20,
                "workspace" => scope["workspace_id"],
                "channel" => scope["channel_id"],
                "latest" => timestamp(fixture["reference_end_us"])
              })

            Map.put(result, :channel, scope["channel_id"])
          end

        sql!(url, "SYSTEM FLUSH LOGS")

        query_stats =
          sql!(url, """
          SELECT query_duration_ms, read_rows, read_bytes, memory_usage, result_rows, exception_code,
            multiIf(position(query, 'cosineDistance(')>0, 'semantic_rank',
              position(query, 'positionCaseInsensitiveUTF8(')>0, 'keyword_rank',
              position(query, '.slack_messages FINAL')>0, 'message_metadata',
              position(query, '.slack_message_payloads FINAL')>0, 'payload_metadata', 'excerpts') AS phase
          FROM system.query_log
          WHERE query_start_time_microseconds >= parseDateTime64BestEffort('#{DateTime.to_iso8601(started_at)}', 6)
            AND type IN ('QueryFinish','ExceptionWhileProcessing','ExceptionBeforeStart')
            AND startsWith(query,'SELECT') AND position(query,'#{database}.')>0
            AND position(query,'system.query_log')=0
          FORMAT JSONEachRow
          """)
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        output = %{
          fixture: Map.drop(fixture, ["scopes"]),
          storage_parts: storage_parts,
          started_at: started_at,
          ended_at: DateTime.utc_now(),
          cases: cases,
          channels: channel_cases,
          query_stats: query_stats,
          method:
            "Actual Provider -> MessageSearch -> ClickHouse/PG/source/publication/owner checks -> excerpts/cursor. Local HTTP encoder returns synthetic vectors; S3 control owner uses the repository fake, PostgreSQL is real. No real GPU, production network, cold OS-cache flush, relevance/recall or SLA claim."
        }

        File.write!(Path.join(dir, "results.json"), Jason.encode!(output, pretty: true))

        if System.get_env("SEARCH_PROBE_NEIGHBOR") == "1" do
          neighbor = neighbor_probe(url, database, hd(channels), agent, fixture)
          File.write!(Path.join(dir, "neighbor.json"), Jason.encode!(neighbor, pretty: true))
        end
      end
    end

    # Bounded neighboring-reader experiment, separate from search measurements.
    # Replays frozen text-component rows only; it never changes canonical state.
    defp neighbor_probe(url, database, scope, agent, fixture) do
      read = fn ->
        SalixAnalytics.SlackMirror.Reader.history(
          Map.take(scope, ~w(tenant_id workspace_id channel_id)),
          limit: 20,
          latest: timestamp(fixture["reference_end_us"])
        )
      end

      {:ok, expected} = read.()
      if expected.messages == [], do: raise("neighbor fixture needs messages")

      measure = fn ->
        for _ <- 1..40 do
          start = System.monotonic_time(:microsecond)
          result = read.()
          if result != {:ok, expected}, do: raise("ordinary history changed: #{inspect(result)}")

          %{
            ok: true,
            hits: length(expected.messages),
            elapsed_ms: (System.monotonic_time(:microsecond) - start) / 1000
          }
        end
      end

      baseline = measure.()

      writer =
        Task.async(fn ->
          for _ <- 1..40 do
            sql!(url, """
            INSERT INTO #{database}.slack_message_search_components
            SELECT * FROM #{database}.slack_message_search_components FINAL
            WHERE file_id='' LIMIT 20
            SETTINGS max_threads=1,max_memory_usage=134217728,async_insert=0
            """)

            Process.sleep(25)
          end

          :ok
        end)

      search =
        Task.async(fn ->
          for n <- 1..20 do
            timed(agent, %{
              "query" => "marker_#{rem(n, 97)}",
              "mode" => "hybrid",
              "count" => 20,
              "latest" => timestamp(fixture["reference_end_us"])
            })
          end
        end)

      overlap = measure.()
      :ok = Task.await(writer, 60_000)
      search_results = Task.await(search, 60_000)

      %{
        baseline: summarize(baseline),
        overlap: summarize(overlap),
        search: summarize(search_results),
        identical_history: true,
        writes: 40,
        rows_per_write: 20,
        method:
          "Same 20-message ordinary Reader.history page; bounded overlap with hybrid search and immutable component retries. No GPU, production traffic, or zero-interference claim."
      }
    end

    defp timed(agent, params) do
      start = System.monotonic_time(:microsecond)

      result =
        SalixIM.Provider.call_api(agent, "slack", "slack.message_search", %{"params" => params})

      elapsed = (System.monotonic_time(:microsecond) - start) / 1000

      case result do
        {:ok, %{"messages" => messages}} ->
          unique =
            messages |> Enum.uniq_by(&{&1["workspace_id"], &1["channel"], &1["ts"]}) |> length()

          if unique != length(messages), do: raise("duplicate source on a page")

          %{
            ok: true,
            elapsed_ms: elapsed,
            hits: length(messages),
            channels: messages |> Enum.map(& &1["channel"]) |> Enum.uniq() |> length()
          }

        {:error, reason} ->
          %{ok: false, elapsed_ms: elapsed, error: inspect(reason)}
      end
    end

    defp summarize(results) do
      sorted = results |> Enum.map(& &1.elapsed_ms) |> Enum.sort()

      %{
        requests: length(results),
        errors: Enum.count(results, &(not Map.get(&1, :ok, false))),
        p50_ms: Enum.at(sorted, div(length(sorted), 2)),
        p95_ms: Enum.at(sorted, ceil(length(sorted) * 0.95) - 1),
        max_ms: List.last(sorted),
        min_hits: results |> Enum.map(&Map.get(&1, :hits, 0)) |> Enum.min()
      }
    end

    defp agent_id(group),
      do: String.replace_prefix(group, "grp1_", "agt1_") <> "_1000000000000000400"

    defp timestamp(us),
      do: "#{div(us, 1_000_000)}.#{String.pad_leading(to_string(rem(us, 1_000_000)), 6, "0")}"

    defp sql!(url, sql) do
      %{status: 200, body: body} =
        Req.post!(url, body: sql, decode_body: false, retry: false, receive_timeout: 30_000)

      body
    end
  end

  SearchRuntimeProbe.run()
end
