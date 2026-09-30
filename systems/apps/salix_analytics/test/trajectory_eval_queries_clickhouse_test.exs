defmodule SalixAnalytics.TrajectoryEvalQueriesClickHouseTest do
  @moduledoc """
  Exercises the L2 cursor query against real ClickHouse. The HTTP stand-in used
  by the unit tests cannot catch ClickHouse alias resolution or type errors.
  """

  use ExUnit.Case, async: false

  alias SalixAnalytics.{Migrations, TrajectoryEvalEvent, TrajectoryEvalQueries}
  alias SalixAnalytics.Sink.ClickHouseTyped

  @moduletag :clickhouse

  @clickhouse_url System.get_env("SALIX_TEST_CLICKHOUSE_URL", "http://127.0.0.1:8123/")
  @evaluated_at ~U[2026-08-14 10:00:00Z]

  setup_all do
    Application.ensure_all_started(:req)

    database = "salix_trajectory_eval_q_test_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:salix_analytics, :clickhouse)

    clickhouse_query!("DROP DATABASE IF EXISTS #{database}")

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: @clickhouse_url,
      table: "#{database}.events"
    )

    {:ok, _versions} = Migrations.migrate()

    row =
      TrajectoryEvalEvent.build(%{
        source: "trajectory_eval_query_test",
        source_key: "agent-1:session-1:2:judge:confusion",
        entrypoint: "trajectory_eval",
        surface: "runtime",
        tenant_id: "tenant-1",
        group_id: "group-1",
        actor_type: "agent",
        salix_agent_id: "agent-1",
        session_id: "session-1",
        round_id: "round-1",
        evaluator: "judge",
        evaluator_version: "1",
        outcome: "final",
        metric: "confusion",
        score: 0.9,
        hits: 1,
        verdict: "confirmed",
        reason: "synthetic backtracking",
        evidence: [%{message_id: 2, quote: "synthetic"}],
        window_from: 2,
        window_to: 2,
        window_messages: 1,
        created_at: @evaluated_at
      })

    {:ok, 1} = ClickHouseTyped.insert([row])

    on_exit(fn ->
      Application.put_env(:salix_analytics, :clickhouse, previous)
      clickhouse_query!("DROP DATABASE IF EXISTS #{database}")
    end)

    :ok
  end

  test "confirmed_windows filters on DateTime64 and formats the response timestamp" do
    assert {:ok, [row]} =
             TrajectoryEvalQueries.confirmed_windows("tenant-1",
               after_at: ~U[2026-08-14 09:00:00Z],
               after_key: "",
               snapshot_to: ~U[2026-08-14 11:00:00Z],
               group_id: "group-1",
               min_severity: 0.5,
               limit: 2
             )

    assert row["window_key"] == "agent-1:session-1:2"
    assert row["evaluated_at"] == "2026-08-14T10:00:00.000000Z"
    assert row["max_confirmed_severity"] == 0.9

    assert row["findings"] == [
             %{
               "metric" => "confusion",
               "score" => 0.9,
               "verdict" => "confirmed",
               "reason" => "synthetic backtracking",
               "evidence" => [%{"message_id" => 2, "quote" => "synthetic"}]
             }
           ]
  end

  defp clickhouse_query!(sql) do
    case Req.post(@clickhouse_url, params: [query: sql], body: "", receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        to_string(body)

      {:ok, %{status: status, body: body}} ->
        raise "ClickHouse query failed with #{status}: #{body}\nSQL:\n#{sql}"

      {:error, reason} ->
        raise "ClickHouse query failed: #{inspect(reason)}\nSQL:\n#{sql}"
    end
  end
end
