defmodule SalixAnalytics.HistoricalLLMBackfillClickHouseTest do
  @moduledoc """
  Live regression for the ClickHouse half of the historical provider repair.

  The predicate compared `created_at` — a String column in both generations —
  against a DateTime, which ClickHouse rejects outright with `NO_COMMON_TYPE`.
  The repair therefore never ran at all, and once it iterated both generations
  it failed on the first table and never reached the second. A mocked test
  cannot catch that: the statement is only rejected by a real server, against
  the real column types.

  Covers both generations, all three eligible provider spellings
  (`unknown`/empty/NULL), and two controls that must be left alone.
  """
  use ExUnit.Case, async: false

  alias BillingCore.Metering.HistoricalLLMBackfill
  alias SalixAnalytics.Migrations

  @moduletag :clickhouse

  @clickhouse_url "http://127.0.0.1:8123/"

  # The repair has a Postgres half and a ClickHouse half. This suite owns the
  # ClickHouse half, so the Postgres side is stubbed to a no-op: the point is
  # to run the REAL statement against a REAL server, which is the only thing
  # that catches a type mismatch the server rejects.
  defmodule NoopRepo do
    def transaction(fun), do: {:ok, fun.()}
  end

  defmodule NoopSQL do
    def query!(_repo, _sql), do: %{num_rows: 0, rows: []}
    def query!(_repo, _sql, _params), do: %{num_rows: 0, rows: []}
    def query!(_repo, _sql, _params, _opts), do: %{num_rows: 0, rows: []}
  end

  setup do
    Application.ensure_all_started(:req)

    database = "salix_backfill_test_#{System.unique_integer([:positive])}"
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

  test "repairs unknown providers in both generations and leaves controls alone", %{
    database: database
  } do
    recent = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.to_iso8601()
    ancient = "2020-01-01T00:00:00Z"

    rows = [
      # eligible: the three provider spellings the Postgres half also matches
      {"unknown-provider", "claude-haiku-4.5", "unknown", recent, "anthropic"},
      {"empty-provider", "gpt-5", "", recent, "openai"},
      {"null-provider", "gemini-2.5", nil, recent, "gemini"},
      # controls: outside the window, and a sku the mapping does not claim
      {"too-old", "claude-haiku-4.5", "unknown", ancient, "unknown"},
      {"unmapped-sku", "some-local-model", "unknown", recent, "unknown"}
    ]

    for table <- ~w(llm_call_events_v2 llm_call_events), {key, sku, provider, at, _} <- rows do
      clickhouse_query!("""
      INSERT INTO #{database}.#{table}
        (dedup, source, source_key, version, event_date, metered_at, created_at,
         entrypoint, surface, billing_account_id, product_owner_type,
         product_owner_id, tenant_id, group_id, actor_type, resource_kind,
         provider, sku, status, charge_status, quality, stale)
      VALUES ('', 'backfill_test', '#{key}', 1, toDate('#{String.slice(at, 0, 10)}'),
              '#{at}', '#{at}', 'round', 'comma', 'ba', 'workspace', 'po', 't1', 'g1',
              'agent', 'llm', #{provider_literal(provider)}, '#{sku}', 'ok',
              'unrated', '[]', false)
      """)
    end

    # The repair is a mutation; wait for it rather than sampling mid-flight.
    summary = HistoricalLLMBackfill.run(repo: NoopRepo, sql_runner: NoopSQL, clickhouse: true)

    assert summary.clickhouse_backfill == :ok,
           "the ClickHouse repair did not run: #{inspect(summary.clickhouse_backfill)}"

    await_mutations!(database)

    for table <- ~w(llm_call_events_v2 llm_call_events) do
      actual =
        """
        SELECT source_key, provider FROM #{database}.#{table}
        WHERE source = 'backfill_test' ORDER BY source_key FORMAT TSV
        """
        |> clickhouse_query!()
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [k, v] = String.split(line, "\t", parts: 2)
          {k, v}
        end)

      for {key, _sku, _provider, _at, expected} <- rows do
        assert actual[key] == expected,
               "#{table}.#{key}: expected provider #{expected}, got #{inspect(actual[key])}"
      end
    end
  end

  defp provider_literal(nil), do: "NULL"
  defp provider_literal(value), do: "'#{value}'"

  defp await_mutations!(database) do
    Enum.reduce_while(1..120, :timeout, fn _, _ ->
      pending =
        "SELECT count() FROM system.mutations WHERE database = '#{database}' AND NOT is_done FORMAT TSV"
        |> clickhouse_query!()
        |> String.trim()

      if pending == "0" do
        {:halt, :ok}
      else
        Process.sleep(250)
        {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("provider repair mutation did not finish in #{database}")
    end
  end

  defp clickhouse_query!(sql) do
    case Req.post(@clickhouse_url, params: [query: sql], body: "", receive_timeout: 60_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        to_string(body)

      {:ok, %{status: status, body: body}} ->
        raise "ClickHouse query failed with #{status}: #{body}\nSQL:\n#{sql}"

      {:error, reason} ->
        raise "ClickHouse query failed: #{inspect(reason)}\nSQL:\n#{sql}"
    end
  end
end
