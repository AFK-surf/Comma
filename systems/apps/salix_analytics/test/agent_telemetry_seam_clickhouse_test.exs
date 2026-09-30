defmodule SalixAnalytics.AgentTelemetrySeamClickHouseTest do
  @moduledoc """
  Live-ClickHouse verification of the v1→v2 seam semantics that the mocked
  SQL-text tests cannot prove:

    * rows in frozen v1 and live v2 are BOTH visible through one windowed
      read (rolling-deploy old pods keep writing v1 around the flip);
    * a retry of one logical fact whose metered_at drifted across midnight
      (two live rows under v2's event_date-leading key — the dedup-identity
      blocker that sank the in-place rebuild) converges to ONE winner at
      query time, with the newest version winning;
    * unmerged same-key versions inside v2 alone converge without FINAL;
    * an offset timestamp (`-07:00`) lands in its UTC calendar window —
      event_date now derives from the UTC instant, and the coarse bounds
      are widened a day for pre-fix historical rows.
  """
  use ExUnit.Case, async: false

  alias SalixAnalytics.AgentTelemetryQueries, as: Queries
  alias SalixAnalytics.Migrations
  alias SalixAnalytics.{AgentRunEvent, LLMCallEvent, ToolCallEvent}
  alias SalixAnalytics.Sink.ClickHouseTyped

  @moduletag :clickhouse

  @clickhouse_url "http://127.0.0.1:8123/"

  # Windows fixed relative to the midnight the cross-day retry straddles.
  @from ~U[2026-07-10 00:00:00Z]
  @to ~U[2026-07-11 00:00:00Z]
  @window [from: @from, to: @to]

  setup_all do
    Application.ensure_all_started(:req)

    database = "salix_telemetry_seam_test_#{System.unique_integer([:positive])}"
    prev = Application.get_env(:salix_analytics, :clickhouse)

    clickhouse_query!("DROP DATABASE IF EXISTS #{database}")

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events"
    )

    {:ok, _versions} = Migrations.migrate()

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, prev)
      clickhouse_query!("DROP DATABASE IF EXISTS #{database}")
    end)

    {:ok, database: database}
  end

  test "windowed reads see frozen v1 rows and live v2 rows through one seam", %{
    database: database
  } do
    # A pre-flip row written by an old pod: insert directly into frozen v1.
    insert_v1_tool!(database, "tool:v1-legacy", "sess-seam",
      version: 1,
      metered_at: "2026-07-10T09:00:00Z",
      status: "completed"
    )

    # A post-flip row arrives through the production sink (writes v2).
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               tool("tool:v2-live", "sess-seam", ~U[2026-07-10 10:00:00Z], status: "completed")
             ])

    assert {:ok, rows} = Queries.tool_rates("t1", @window)

    seam_rows =
      Enum.filter(rows, &(&1["tool_source"] in ["v1-legacy", "v2-live"]))

    assert Enum.map(seam_rows, & &1["total_calls"]) |> Enum.sum() == 2
    assert Enum.map(seam_rows, & &1["completed_calls"]) |> Enum.sum() == 2
  end

  test "a cross-midnight retry of one logical fact converges to the newest version", %{
    database: database
  } do
    # version 1 lands before midnight (event_date 2026-07-09), the correction
    # lands after midnight (event_date 2026-07-10). Under the v2 key these are
    # two live rows that background replacement will NEVER merge — the reader
    # must still count exactly one call, and it must be the v2 emission.
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               tool("tool:retry", "sess-retry", ~U[2026-07-09 23:59:30Z],
                 version: 1,
                 status: "error",
                 error_type: "timeout"
               )
             ])

    assert {:ok, 1} =
             ClickHouseTyped.insert([
               tool("tool:retry", "sess-retry", ~U[2026-07-10 00:00:30Z],
                 version: 2,
                 status: "completed"
               )
             ])

    assert both_dates_live_in_v2?(database, "tool:retry")

    # The 2026-07-10 window: convergence runs over the coarse row set before
    # the exact window filter, so the superseded 07-09 version can never
    # resurface. Exactly one call, counted as completed.
    assert {:ok, rows} = Queries.tool_rates("t1", @window)
    [row] = Enum.filter(rows, &(&1["tool_name"] == "seam_probe" and &1["tool_source"] == "retry"))
    assert row["total_calls"] == 1
    assert row["completed_calls"] == 1
    assert row["error_calls"] == 0
  end

  test "unmerged same-key versions in v2 converge without FINAL" do
    # The suite shares one database; scope the read to this test's provider.
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:versions", "sess-v", ~U[2026-07-10 08:00:00Z],
                 version: 1,
                 status: "error",
                 attempts: 1,
                 provider: "versions_probe"
               )
             ])

    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:versions", "sess-v", ~U[2026-07-10 08:00:05Z],
                 version: 2,
                 status: "ok",
                 attempts: 2,
                 provider: "versions_probe"
               )
             ])

    assert {:ok, [row]} = Queries.llm_overview("t1", @window ++ [provider: "versions_probe"])
    assert row["calls"] == 1
    assert row["failed"] == 0
    assert row["retried"] == 1
  end

  test "equal-version winners are decided by the instant, not the timestamp text" do
    # Production builders default every row to version = 1, so the tie-break
    # decides in practice. Both instants sit inside the window, but the LATER
    # one (21:00:01Z, written with a -07:00 offset) sorts LOWER as text than
    # the earlier 20:00:00Z — `...T1` < `...T2` — so a lexicographic
    # tie-break picks the obsolete error.
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:tiebreak-offset", "sess-tb", "2026-07-10T20:00:00Z",
                 status: "error",
                 provider: "tiebreak_offset_probe"
               )
             ])

    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:tiebreak-offset", "sess-tb", "2026-07-10T14:00:01-07:00",
                 status: "ok",
                 provider: "tiebreak_offset_probe"
               )
             ])

    assert {:ok, [row]} =
             Queries.llm_overview("t1", @window ++ [provider: "tiebreak_offset_probe"])

    assert row["calls"] == 1
    assert row["failed"] == 0, "lexicographic tie-break resurrected the obsolete error row"

    # Same failure mode via fractional seconds: an exact-second `...00Z`
    # sorts ABOVE the later `...00.001Z`.
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:tiebreak-millis", "sess-tb", "2026-07-10T12:00:00Z",
                 status: "error",
                 provider: "tiebreak_millis_probe"
               )
             ])

    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:tiebreak-millis", "sess-tb", "2026-07-10T12:00:00.001Z",
                 status: "ok",
                 provider: "tiebreak_millis_probe"
               )
             ])

    assert {:ok, [millis_row]} =
             Queries.llm_overview("t1", @window ++ [provider: "tiebreak_millis_probe"])

    assert millis_row["calls"] == 1
    assert millis_row["failed"] == 0
  end

  test "convergence_drift sees a revision that lands outside any query window" do
    # The case the contract is about, and the one a WINDOWED probe cannot see:
    # the original on July 10 and its correction three days later on July 13.
    # A July 10-11 probe would clip the correction and report zero drift for
    # the very corpus that is drifting — hence the probe is unwindowed.
    # Seeded on agent_run_events, which no other test in this file writes, so
    # the counts are exact regardless of test order.
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               run("run:drift", "sess-drift", ~U[2026-07-10 12:00:00Z], status: "llm_failed")
             ])

    assert {:ok, 1} =
             ClickHouseTyped.insert([
               run("run:drift", "sess-drift", ~U[2026-07-13 12:00:00Z],
                 version: 2,
                 status: "completed"
               )
             ])

    assert {:ok, 1} =
             ClickHouseTyped.insert([
               run("run:same-day", "sess-drift", ~U[2026-07-10 09:00:00Z], status: "completed")
             ])

    assert {:ok, rows} = Queries.convergence_drift("t1")
    runs = Map.new(rows, &{&1["table"], &1})["agent_run_events"]

    assert runs["facts"] == 2
    assert runs["facts_with_revisions"] == 1

    assert runs["facts_spanning_dates"] == 1,
           "the probe must see a correction that landed outside the dashboard window"

    # And the drift is real, not theoretical: the July 10-11 window converges
    # over the July 10 row alone and reports the superseded failure, while a
    # window covering both returns the correction. This is the accepted
    # imprecision, pinned so a future change cannot alter it silently.
    assert {:ok, [narrow]} =
             Queries.run_outcomes("t1",
               from: ~U[2026-07-10 00:00:00Z],
               to: ~U[2026-07-11 00:00:00Z]
             )

    assert narrow["llm_failed"] == 1

    assert {:ok, [wide]} =
             Queries.run_outcomes("t1",
               from: ~U[2026-07-10 00:00:00Z],
               to: ~U[2026-07-14 00:00:00Z]
             )

    assert wide["llm_failed"] == 0
    assert wide["completed"] == 2
  end

  test "an offset timestamp lands in its UTC calendar window" do
    # 2026-07-09T17:30:00-07:00 IS 2026-07-10T00:30:00Z. event_date derives
    # from the UTC instant, so the UTC July 10 window must return it.
    assert {:ok, 1} =
             ClickHouseTyped.insert([
               llm("llm:offset", "sess-offset", "2026-07-09T17:30:00-07:00",
                 status: "ok",
                 provider: "offset_probe"
               )
             ])

    assert {:ok, rows} = Queries.llm_speed("t1", @window ++ [provider: "offset_probe"])
    assert [%{"calls" => 1}] = Enum.map(rows, &Map.take(&1, ["calls"]))
  end

  # ---- row builders ----

  defp llm(key, session, at, extra) do
    LLMCallEvent.build(
      Map.merge(
        %{
          source: "seam_test",
          source_key: key,
          entrypoint: "round",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "system",
          charge_status: "unattributed",
          provider: "openrouter",
          model: "claude-haiku-4.5",
          metered_at: at,
          started_at: at,
          duration_ms: 1000,
          salix_agent_id: "ag-1",
          session_id: session
        },
        Map.new(extra)
      )
    )
  end

  defp tool(key, session, at, extra) do
    ToolCallEvent.build(
      Map.merge(
        %{
          source: "seam_test",
          source_key: key,
          entrypoint: "tool_call",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "tool",
          tool_name: "seam_probe",
          tool_source: source_suffix(key),
          metered_at: at,
          started_at: at,
          duration_ms: 5,
          call_index: 0,
          async: false,
          salix_agent_id: "ag-1",
          session_id: session
        },
        Map.new(extra)
      )
    )
  end

  defp run(key, session, at, extra) do
    AgentRunEvent.build(
      Map.merge(
        %{
          source: "seam_test",
          source_key: key,
          entrypoint: "agent_run",
          surface: "comma",
          tenant_id: "t1",
          group_id: "g1",
          actor_type: "user",
          metered_at: at,
          started_at: at,
          duration_ms: 100,
          salix_agent_id: "ag-1",
          session_id: session
        },
        Map.new(extra)
      )
    )
  end

  defp source_suffix(key), do: key |> String.split(":") |> List.last()

  # Write a frozen-generation row exactly as an old pod's sink would have:
  # straight into the v1 table.
  defp insert_v1_tool!(database, key, session, opts) do
    metered_at = Keyword.fetch!(opts, :metered_at)

    row =
      %{
        "dedup" => "seam_test|#{key}|#{opts[:version] || 1}",
        "source" => "seam_test",
        "source_key" => key,
        "version" => opts[:version] || 1,
        "event_date" => String.slice(metered_at, 0, 10),
        "metered_at" => metered_at,
        "created_at" => metered_at,
        "entrypoint" => "tool_call",
        "surface" => "comma",
        "tenant_id" => "t1",
        "group_id" => "g1",
        "actor_type" => "tool",
        "resource_kind" => "tool_call",
        "charge_status" => "unattributed",
        "tool_name" => "seam_probe",
        "tool_source" => source_suffix(key),
        "status" => Keyword.fetch!(opts, :status),
        "duration_ms" => 5,
        "started_at" => String.replace(String.replace(metered_at, "T", " "), "Z", ""),
        "call_index" => 0,
        "async" => false,
        "salix_agent_id" => "ag-1",
        "session_id" => session
      }

    body = Jason.encode!(row)

    clickhouse_query!(
      "INSERT INTO #{database}.tool_call_events FORMAT JSONEachRow",
      body
    )
  end

  defp both_dates_live_in_v2?(database, key) do
    dates =
      """
      SELECT DISTINCT toString(event_date)
      FROM #{database}.tool_call_events_v2
      WHERE source_key = '#{key}'
      ORDER BY event_date
      FORMAT TSV
      """
      |> clickhouse_query!()
      |> String.split("\n", trim: true)

    dates == ["2026-07-09", "2026-07-10"]
  end

  defp clickhouse_query!(sql, body \\ "") do
    case Req.post(@clickhouse_url, params: [query: sql], body: body, receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        to_string(body)

      {:ok, %{status: status, body: body}} ->
        raise "ClickHouse query failed with #{status}: #{body}\nSQL:\n#{sql}"

      {:error, reason} ->
        raise "ClickHouse query failed: #{inspect(reason)}\nSQL:\n#{sql}"
    end
  end
end
