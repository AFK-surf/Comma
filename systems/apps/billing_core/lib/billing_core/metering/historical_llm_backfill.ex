defmodule BillingCore.Metering.HistoricalLLMBackfill do
  @moduledoc """
  Bounded repair for historical LLM rows whose provider/sku were recorded before
  provider inference landed.
  """

  @default_days 7

  def run(opts \\ []) do
    repo = opts[:repo] || Application.fetch_env!(:billing_core, :repo)
    sql = opts[:sql_runner] || Ecto.Adapters.SQL
    now = opts[:now] || DateTime.utc_now()
    days = min(opts[:days] || @default_days, @default_days)
    since = DateTime.add(now, -days * 86_400, :second)

    with {:ok, pending_count} <- repo.transaction(fn -> backfill_pending(repo, sql, since) end) do
      clickhouse_result = maybe_backfill_clickhouse(opts, since)

      replay =
        BillingCore.Metering.PricingBackfill.run(%{
          repo: repo,
          sql_runner: sql,
          now: now
        })

      %{
        pending_backfilled: pending_count,
        clickhouse_backfill: clickhouse_result,
        replay: replay,
        since: since
      }
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp backfill_pending(repo, sql, since) do
    result =
      sql.query!(
        repo,
        """
        WITH candidates AS (
          SELECT id,
                 CASE
                   WHEN sku LIKE 'gpt-%' OR sku LIKE 'o1%' OR sku LIKE 'o3%' OR sku LIKE 'o4%' OR sku LIKE 'o5%' THEN 'openai'
                   WHEN sku LIKE 'claude-%' THEN 'anthropic'
                   WHEN sku LIKE 'gemini-%' THEN 'gemini'
                   WHEN sku LIKE 'deepseek-%' THEN 'deepseek'
                   WHEN sku LIKE 'kimi-%' OR sku LIKE 'moonshot-%' THEN 'kimi'
                   WHEN sku LIKE 'glm-%' THEN 'glm'
                   ELSE NULL
                 END AS inferred_provider
          FROM pending_meter_charges
          WHERE resource_kind = 'llm'
            AND status = 'pending'
            AND metered_at >= $1
            AND (provider IS NULL OR provider = '' OR provider = 'unknown')
        )
        UPDATE pending_meter_charges p
        SET provider = c.inferred_provider,
            meter_snapshot =
              jsonb_set(
                COALESCE(p.meter_snapshot::jsonb, '{}'::jsonb),
                '{provider}',
                to_jsonb(c.inferred_provider),
                true
              )
        FROM candidates c
        WHERE p.id = c.id
          AND c.inferred_provider IS NOT NULL
        """,
        [since]
      )

    result.num_rows || 0
  end

  defp maybe_backfill_clickhouse(opts, since) do
    if Keyword.get(opts, :clickhouse, true) do
      backfill_clickhouse(opts, since)
    else
      :skipped
    end
  end

  # Both generations of the LLM table need the repair while the storage seam
  # is open: post-cutover rows land in `_v2`, pre-cutover rows stay in the
  # frozen table, and dashboard reads UNION the two. Drop the frozen entry
  # with the seam cleanup.
  @llm_tables ~w(llm_call_events_v2 llm_call_events)

  defp backfill_clickhouse(opts, since) do
    Enum.reduce_while(@llm_tables, :ok, fn table, :ok ->
      case backfill_clickhouse_table(opts, since, table) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # `created_at` is a String column in both generations, so it must be parsed
  # before it can be compared to an instant — comparing it directly to
  # `parseDateTimeBestEffort(...)` is rejected outright with NO_COMMON_TYPE,
  # which meant this repair never ran at all. The provider predicate also
  # matches NULL/empty the same way the Postgres half does.
  defp backfill_clickhouse_table(opts, since, table_name) do
    cfg = clickhouse_config(opts)
    table = "#{cfg.database}.#{table_name}"

    query = """
    ALTER TABLE #{table}
    UPDATE provider = multiIf(
      startsWith(sku, 'gpt-') OR startsWith(sku, 'o1') OR startsWith(sku, 'o3') OR startsWith(sku, 'o4') OR startsWith(sku, 'o5'), 'openai',
      startsWith(sku, 'claude-'), 'anthropic',
      startsWith(sku, 'gemini-'), 'gemini',
      startsWith(sku, 'deepseek-'), 'deepseek',
      startsWith(sku, 'kimi-') OR startsWith(sku, 'moonshot-'), 'kimi',
      startsWith(sku, 'glm-'), 'glm',
      provider
    )
    WHERE parseDateTime64BestEffortOrNull(created_at, 3, 'UTC') >= parseDateTime64BestEffortOrZero('#{DateTime.to_iso8601(since)}', 3, 'UTC')
      AND (provider = 'unknown' OR provider = '' OR provider IS NULL)
      AND (
        startsWith(sku, 'gpt-') OR startsWith(sku, 'o1') OR startsWith(sku, 'o3') OR startsWith(sku, 'o4') OR startsWith(sku, 'o5') OR
        startsWith(sku, 'claude-') OR startsWith(sku, 'gemini-') OR startsWith(sku, 'deepseek-') OR
        startsWith(sku, 'kimi-') OR startsWith(sku, 'moonshot-') OR startsWith(sku, 'glm-')
      )
    """

    case Req.post(cfg.base_url,
           params: params(cfg, query),
           headers: headers(cfg),
           body: "",
           receive_timeout: cfg.receive_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clickhouse_config(opts) do
    cfg =
      Keyword.merge(
        Application.get_env(:salix_analytics, :clickhouse, []),
        opts[:clickhouse_opts] || []
      )

    table = cfg[:table] || "salix_analytics.events"

    %{
      base_url: cfg[:base_url] || "http://127.0.0.1:8123",
      database:
        cfg[:typed_database] || cfg[:database] || table |> String.split(".", parts: 2) |> hd(),
      user: cfg[:user],
      password: cfg[:password],
      receive_timeout_ms: cfg[:receive_timeout_ms] || 30_000
    }
  end

  defp params(cfg, query) do
    base = [query: query]
    if cfg.database, do: [{:database, cfg.database} | base], else: base
  end

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "" do
    [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]
  end

  defp headers(_), do: []
end
