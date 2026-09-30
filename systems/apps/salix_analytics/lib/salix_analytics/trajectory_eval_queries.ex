defmodule SalixAnalytics.TrajectoryEvalQueries do
  @moduledoc """
  Read-side aggregation queries over `trajectory_eval_events` for the
  dashboard trend page.

  HTTP transport, param binding, and config validation live in
  `SalixAnalytics.ClickHouseRead`; this module only owns the SQL and its
  counting semantics.

  ## Counting contract

  The unit of truth is a **finding**: one `(window, metric)` pair, where a
  window (one check over one slice of a session) is `agent:session:window_to`.
  Raw rows fan out — one row per finding, a `clean` row when a check found
  nothing, judge rows next to heuristic rows, and `ReplacingMergeTree` dedup
  is eventual — so everything first collapses to one row per finding in the
  `findings_sql/2` inner query (`GROUP BY wkey, metric`; boolean flags via
  `countIf(...) > 0` are duplicate-safe).

  Each finding carries its judge state: confirmed, dismissed (judge ruled
  false alarm), or unreviewed. Headline counts are **net**: found minus
  dismissed — an unreviewed finding still counts as an issue until a judge
  clears it. Dismissed counts are returned alongside so the UI can show
  what was filtered rather than silently shrink numbers.
  """

  alias SalixAnalytics.ClickHouseRead

  @table "trajectory_eval_events"

  @type rows :: [map()]
  @type result :: {:ok, rows()} | {:error, term()}

  @doc """
  Checks vs checks-with-standing-issues per `(event_date, group_id)`.

  A check counts under `with_issues` when at least one of its findings is
  not `clean` and not judge-dismissed. Rows: `event_date`, `group_id`,
  `checks`, `with_issues`.
  """
  @spec flag_rate_trend(String.t(), keyword()) :: result()
  def flag_rate_trend(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT found_date AS event_date,
             grp AS group_id,
             uniqExact(wkey) AS checks,
             uniqExactIf(wkey, metric != 'clean' AND NOT is_dismissed) AS with_issues
      FROM (#{findings_sql(db, opts)})
      GROUP BY event_date, group_id
      ORDER BY event_date, group_id
      FORMAT JSONEachRow
      """
    end

    run(sql, binds(tenant_id, opts))
  end

  @doc """
  Findings per `(metric, event_date)` with their judge outcomes.

  Rows: `metric`, `event_date`, `found` (all L1 findings), `confirmed`,
  `dismissed`, `reviewed` (confirmed + dismissed). Net standing issues =
  `found - dismissed`.
  """
  @spec metric_breakdown(String.t(), keyword()) :: result()
  def metric_breakdown(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT metric,
             found_date AS event_date,
             count() AS found,
             countIf(is_confirmed) AS confirmed,
             countIf(is_dismissed) AS dismissed,
             countIf(is_reviewed) AS reviewed
      FROM (#{findings_sql(db, opts)})
      WHERE metric != 'clean'
      GROUP BY metric, event_date
      ORDER BY metric, event_date
      FORMAT JSONEachRow
      """
    end

    run(sql, binds(tenant_id, opts))
  end

  @doc """
  Judge confirmation rate per `(metric, evaluator_version)` — the online
  precision proxy for each L1 rule, comparable across rubric versions.
  Denominator is what the judge actually reviewed, not all findings.
  Rows: `metric`, `evaluator_version`, `confirmed`, `total`.
  """
  @spec judge_confirm_rate(String.t(), keyword()) :: result()
  def judge_confirm_rate(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT metric,
             evaluator_version,
             uniqExactIf(source_key, verdict = 'confirmed') AS confirmed,
             uniqExact(source_key) AS total
      FROM #{db}.#{@table}
      WHERE tenant_id = {tenant_id:String}
        AND event_date >= {from:Date}
        AND event_date <= {to:Date}
        AND evaluator = 'judge'
        AND metric != 'clean'
        #{group_clause(opts)}
      GROUP BY metric, evaluator_version
      ORDER BY metric, evaluator_version
      FORMAT JSONEachRow
      """
    end

    run(sql, binds(tenant_id, opts))
  end

  @doc """
  Sessions ranked by standing issues (judge-dismissed excluded from the
  rank, returned alongside). Rows: `salix_agent_id`, `session_id`,
  `issues`, `dismissed`, `last_date`.
  """
  @spec top_flagged_sessions(String.t(), keyword()) :: result()
  def top_flagged_sessions(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT agent_id AS salix_agent_id,
             sess_id AS session_id,
             countIf(NOT is_dismissed) AS issues,
             countIf(is_dismissed) AS dismissed,
             max(found_date) AS last_date
      FROM (#{findings_sql(db, opts)})
      WHERE metric != 'clean'
      GROUP BY salix_agent_id, session_id
      ORDER BY issues DESC, last_date DESC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    run(sql, binds(tenant_id, opts) ++ [limit: opts[:limit] || 20])
  end

  @doc """
  Returns one keyset-ordered row per L2-confirmed trajectory window.

  This is the read-side source for `/v1/runtime/eval/trajectory-results`.
  It reads the already-recorded ClickHouse facts; it does not create a second
  candidate projection or participate in the online evaluator's write path.

  Required options are `:after_at`, `:after_key`, and `:snapshot_to`. The
  caller owns the opaque cursor and requests `limit + 1` rows to determine
  whether another page exists.
  """
  @spec confirmed_windows(String.t(), keyword()) :: result()
  def confirmed_windows(tenant_id, opts) when is_list(opts) do
    sql = fn db ->
      """
      SELECT
        window_key,
        salix_agent_id,
        session_id,
        group_id,
        outcome,
        round_id,
        window_from,
        window_to,
        window_messages,
        max_confirmed_severity,
        evaluator_version,
        formatDateTime(evaluated_at_raw, '%Y-%m-%dT%H:%i:%S.%fZ', 'UTC') AS evaluated_at,
        findings_json
      FROM
      (
        SELECT
          concat(salix_agent_id, ':', session_id, ':', toString(window_to)) AS window_key,
          salix_agent_id,
          session_id,
          any(group_id) AS group_id,
          any(outcome) AS outcome,
          any(round_id) AS round_id,
          any(window_from) AS window_from,
          window_to,
          any(window_messages) AS window_messages,
          max(score) AS max_confirmed_severity,
          any(evaluator_version) AS evaluator_version,
          max(seen_at) AS evaluated_at_raw,
          toJSONString(
            arraySort(
              finding -> tupleElement(finding, 1),
              groupArray(tuple(metric, score, verdict, reason, evidence))
            )
          ) AS findings_json
        FROM
        (
          SELECT
            source_key,
            argMax(salix_agent_id, recorded_at) AS salix_agent_id,
            argMax(session_id, recorded_at) AS session_id,
            argMax(group_id, recorded_at) AS group_id,
            argMax(outcome, recorded_at) AS outcome,
            argMax(round_id, recorded_at) AS round_id,
            argMax(window_from, recorded_at) AS window_from,
            argMax(window_to, recorded_at) AS window_to,
            argMax(window_messages, recorded_at) AS window_messages,
            argMax(metric, recorded_at) AS metric,
            argMax(score, recorded_at) AS score,
            argMax(verdict, recorded_at) AS verdict,
            argMax(reason, recorded_at) AS reason,
            argMax(evidence, recorded_at) AS evidence,
            argMax(evaluator_version, recorded_at) AS evaluator_version,
            max(recorded_at) AS seen_at
          FROM
          (
            SELECT *, parseDateTime64BestEffort(created_at, 6, 'UTC') AS recorded_at
            FROM #{db}.#{@table}
            WHERE tenant_id = {tenant_id:String}
              AND event_date >= {from_date:Date}
              AND event_date <= {to_date:Date}
              AND evaluator = 'judge'
              AND metric != 'clean'
              #{group_clause(opts)}
          )
          GROUP BY source_key
          HAVING verdict = 'confirmed'
        )
        GROUP BY salix_agent_id, session_id, window_to
        HAVING max_confirmed_severity >= {min_severity:Float64}
      )
      WHERE evaluated_at_raw <= parseDateTime64BestEffort({snapshot_to:String}, 6, 'UTC')
        AND (
          evaluated_at_raw > parseDateTime64BestEffort({after_at:String}, 6, 'UTC')
          OR (
            evaluated_at_raw = parseDateTime64BestEffort({after_at:String}, 6, 'UTC')
            AND window_key > {after_key:String}
          )
        )
      ORDER BY evaluated_at_raw ASC, window_key ASC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    after_at = Keyword.fetch!(opts, :after_at)
    snapshot_to = Keyword.fetch!(opts, :snapshot_to)

    query_binds = [
      tenant_id: tenant_id,
      from_date: after_at |> DateTime.to_date() |> Date.to_iso8601(),
      to_date: snapshot_to |> DateTime.to_date() |> Date.to_iso8601(),
      after_at: DateTime.to_iso8601(after_at),
      after_key: opts[:after_key] || "",
      snapshot_to: DateTime.to_iso8601(snapshot_to),
      min_severity: opts[:min_severity] || 0.5,
      limit: opts[:limit] || 51
    ]

    query_binds =
      case opts[:group_id] do
        nil -> query_binds
        group_id -> query_binds ++ [group_id: group_id]
      end

    with {:ok, rows} <- ClickHouseRead.run(sql, query_binds, query: "trajectory_eval") do
      decode_confirmed_windows(rows)
    end
  end

  # ============================ shared plumbing ============================

  # One row per finding `(window, metric)`, collapsing heuristic + judge +
  # ReplacingMergeTree-duplicate rows. `wkey` is the check identity
  # (`agent:session:window_to` — the metric-free prefix of `source_key`,
  # see TrajectoryEvalRecorder). Judge rows for the same finding differ
  # only in the evaluator segment, so they collapse into the same group and
  # become the `is_*` flags. `HAVING has_l1` drops judge-only groups
  # (e.g. clean-window samples) from finding counts.
  defp findings_sql(db, opts) do
    """
    SELECT
      concat(coalesce(salix_agent_id, ''), ':', coalesce(session_id, ''), ':', toString(window_to)) AS wkey,
      metric,
      any(salix_agent_id) AS agent_id,
      any(session_id) AS sess_id,
      anyIf(group_id, evaluator = 'heuristic') AS grp,
      minIf(event_date, evaluator = 'heuristic') AS found_date,
      countIf(evaluator = 'heuristic') > 0 AS has_l1,
      countIf(evaluator = 'judge' AND verdict = 'confirmed') > 0 AS is_confirmed,
      countIf(evaluator = 'judge' AND verdict = 'rejected') > 0 AS is_dismissed,
      countIf(evaluator = 'judge' AND verdict IN ('confirmed', 'rejected')) > 0 AS is_reviewed
    FROM #{db}.#{@table}
    WHERE tenant_id = {tenant_id:String}
      AND event_date >= {from:Date}
      AND event_date <= {to:Date}
      #{group_clause(opts)}
    GROUP BY wkey, metric
    HAVING has_l1
    """
  end

  defp binds(tenant_id, opts) do
    to = opts[:to] || Date.utc_today()
    from = opts[:from] || Date.add(to, -13)

    base = [tenant_id: tenant_id, from: Date.to_iso8601(from), to: Date.to_iso8601(to)]

    case opts[:group_id] do
      nil -> base
      group_id -> base ++ [group_id: group_id]
    end
  end

  # The clause is a fixed string chosen by presence — the group id itself
  # still travels as a bound parameter, never in the SQL text.
  defp group_clause(opts) do
    if opts[:group_id], do: "AND group_id = {group_id:String}", else: ""
  end

  defp decode_confirmed_windows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case decode_findings(row["findings_json"]) do
        {:ok, findings} ->
          decoded = row |> Map.delete("findings_json") |> Map.put("findings", findings)
          {:cont, {:ok, [decoded | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_findings(json) when is_binary(json) do
    with {:ok, tuples} when is_list(tuples) <- Jason.decode(json) do
      findings =
        Enum.map(tuples, fn
          [metric, score, verdict, reason, evidence] ->
            %{
              "metric" => metric,
              "score" => score,
              "verdict" => verdict,
              "reason" => reason,
              "evidence" => decode_evidence(evidence)
            }

          _ ->
            nil
        end)

      if Enum.any?(findings, &is_nil/1),
        do: {:error, {:bad_findings, json}},
        else: {:ok, findings}
    else
      _ -> {:error, {:bad_findings, json}}
    end
  end

  defp decode_findings(other), do: {:error, {:bad_findings, other}}

  defp decode_evidence(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_evidence(value), do: value

  defp run(sql_fn, binds), do: ClickHouseRead.run(sql_fn, binds, query: "trajectory_eval")
end
