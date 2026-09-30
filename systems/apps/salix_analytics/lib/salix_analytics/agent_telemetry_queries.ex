defmodule SalixAnalytics.AgentTelemetryQueries do
  @moduledoc """
  Read-side aggregation queries over the agent telemetry tables
  (`agent_run_events`, `tool_call_events`, `llm_call_events`) for the
  Runtime Health dashboard pages.

  HTTP transport, param binding, and config validation live in
  `SalixAnalytics.ClickHouseRead`; this module only owns the SQL.

  ## Storage seam and query-time convergence

  Each table exists in two generations while the v1→v2 seam is open
  (migrations 20260723000001..3): frozen v1 (`ORDER BY (source, source_key)`,
  no partitioning, String timestamps) and live v2 (`PARTITION BY
  toYYYYMM(event_date)`, `ORDER BY (event_date, source, source_key)`, a
  MATERIALIZED `observed_at DateTime64`). Every read UNIONs both generations
  and converges duplicates at query time — newest version per
  `(source, source_key)` — instead of `FINAL`, because `event_date` sits in
  the v2 key and background replacement can no longer be relied on to
  collapse a fact whose timestamp drifted to another day. The coarse
  `event_date` bounds and the pushed-down `tenant_id` on the v2 branch are
  what buy pruning; the exact window filter runs on `observed_at` after
  convergence, where FINAL used to sit. Both generations are read
  unconditionally until a separate cleanup release backfills and retires v1
  — a build-time date cannot know when an environment's old writers exited.

  Convergence over a bounded window is not identical to whole-table `FINAL`:
  see the accuracy contract in `docs/observability.md` for
  the one case that differs and why it is accepted. `convergence_drift/2`
  measures it per environment.

  ## Counting contract

  Rates keep the acceptance-query denominators so dashboard numbers reconcile
  with `priv/clickhouse/queries/agent_telemetry/`:

    * tool infra error rate divides by `completed + error` — `guidance`
      (the agent was corrected, the tool never ran) and `cancelled` are not
      infra outcomes;
    * LLM `failed` means `status = 'error'` — retries fold into one row
      upstream, so a failed row failed for good;
    * cancelled async tool calls never emit a row, so any cancelled count
      is a floor, not a total.

  ## Q5 / unconverged sessions

  `agent_run_events` terminal rows are emitted by INTERNAL sessions only.
  External sessions never converge by construction here, so
  `unconverged_sessions/2` results MUST be filtered to internal agents by
  the caller (via `SalixAgent.Control.runtime_kind/1` — this app cannot see
  agent records). The query returns `salix_agent_id` per session to make
  that filter (and links) possible.
  """

  alias SalixAnalytics.ClickHouseRead

  @type result :: ClickHouseRead.result()

  # 15 minutes: a session with LLM/tool activity but no terminal run row is
  # only "unaccounted for" once it has been silent past this grace window.
  @stale_grace_seconds 900

  # ============================ agent_run_events ============================

  @doc """
  Run terminal outcome totals for the window. One row: `rounds`,
  `completed`, `llm_failed`, `actor_failed`, `repair_failed`, `parked`.

  `parked` counts the three guard stops together. A park is deliberate: a
  guard ended the run to stop a loop. It is not a crash, so it is counted
  apart from `actor_failed`. Every run is either `completed` or one of the
  rest, so the caller can still show `rounds - completed` as one total.
  """
  @spec run_outcomes(String.t(), keyword()) :: result()
  def run_outcomes(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT count() AS rounds,
             countIf(status = 'completed') AS completed,
             countIf(status = 'llm_failed') AS llm_failed,
             countIf(status = 'actor_failed') AS actor_failed,
             countIf(status = 'repair_failed') AS repair_failed,
             -- `SalixAgent.RunTelemetry.parked_statuses/0` owns this list.
             -- This app cannot depend on salix_agent, so the names repeat
             -- here. A park missing from this list still reaches the caller
             -- inside `rounds - completed`, which is how the page totals it.
             countIf(status IN ('runaway_guard_parked', 'repeated_tool_result_parked',
                                'input_round_budget_parked')) AS parked
      FROM #{events(db, "agent_run_events")}
      WHERE #{scope(opts)}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts), query: "run_outcomes")
  end

  @doc """
  Per-bucket round outcomes and duration quantiles. Rows: `bucket`
  (DateTime string), `rounds`, `failed`, `p50_ms`, `p95_ms`. Bucket width
  comes from `opts[:bucket_seconds]` (default 3600).
  """
  @spec round_trends(String.t(), keyword()) :: result()
  def round_trends(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT toStartOfInterval(observed_at, toIntervalSecond({bucket:UInt32})) AS bucket,
             count() AS rounds,
             countIf(status != 'completed') AS failed,
             quantileTDigest(0.50)(duration_ms) AS p50_ms,
             quantileTDigest(0.95)(duration_ms) AS p95_ms
      FROM #{events(db, "agent_run_events")}
      WHERE #{scope(opts)}
      GROUP BY bucket
      ORDER BY bucket
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [bucket: bucket_seconds(opts)],
      query: "round_trends"
    )
  end

  @doc """
  Per-bucket share of activation wall clock that no telemetry row covers.

  An activation is the chain of rounds that handled one input: rounds of a
  session sharing a non-empty `activation_key` (from their phase rows), or —
  when either side has none — rounds linked by the time heuristic the
  Activity tab uses (the earlier round recorded no ending and the next
  started within two minutes). Per activation: `span` from its first record
  to its last, `covered` = model calls + tool calls + recorded phases,
  `unknown` = max(span − covered, 0). Overlapping records (a background
  tool under a model call) over-count coverage, so unknown is a floor.

  Rows: `bucket` (activation start), `activations`, `span_ms`, `unknown_ms`,
  `phase_ms`. Bucket width from `opts[:bucket_seconds]` (default 3600).
  """
  @spec unknown_trends(String.t(), keyword()) :: result()
  def unknown_trends(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      WITH rounds AS (
        SELECT session_id,
               round_id,
               min(st) AS r_start,
               max(st + toIntervalMillisecond(d)) AS r_end,
               sumIf(d, k = 'llm') AS llm_ms,
               sumIf(d, k = 'tool') AS tool_ms,
               sumIf(d, k = 'phase') AS phase_ms,
               max(k = 'run') AS has_terminal,
               anyIf(key, key != '') AS act_key
        FROM (
          SELECT session_id, round_id, started_at AS st, coalesce(duration_ms, 0) AS d,
                 'llm' AS k, '' AS key
          FROM #{events(db, "llm_call_events")}
          WHERE #{scope(opts)} AND #{round_scoped()}
          UNION ALL
          SELECT session_id, round_id, started_at, duration_ms, 'tool', ''
          FROM #{events(db, "tool_call_events")}
          WHERE #{scope(opts)} AND #{round_scoped()}
          UNION ALL
          SELECT session_id, round_id, started_at, duration_ms, 'run', ''
          FROM #{events(db, "agent_run_events")}
          WHERE #{scope(opts)} AND #{round_scoped()}
          UNION ALL
          SELECT session_id, round_id, started_at, duration_ms, 'phase',
                 coalesce(activation_key, '')
          FROM #{phase_events(db, tenant_id)}
          WHERE #{scope(opts)} AND #{round_scoped()}
            AND phase IN ('miniskill', 'delivery_wait', 'activation', 'prepare', 'response_commit',
                          'tool_commit', 'boundary', 'finalize',
                          'async_pickup', 'async_commit', 'async_config')
        )
        GROUP BY session_id, round_id
      ),
      flagged AS (
        SELECT *,
               lagInFrame(r_end) OVER w AS prev_end,
               lagInFrame(has_terminal) OVER w AS prev_terminal,
               lagInFrame(act_key) OVER w AS prev_key,
               row_number() OVER w AS rn
        FROM rounds
        WINDOW w AS (PARTITION BY session_id ORDER BY r_start, round_id)
      ),
      marked AS (
        SELECT *,
               multiIf(
                 rn = 1, 1,
                 act_key != '' AND prev_key != '', if(act_key = prev_key, 0, 1),
                 prev_terminal = 1 OR dateDiff('millisecond', prev_end, r_start) >= 120000, 1,
                 0
               ) AS is_new
        FROM flagged
      ),
      acts AS (
        SELECT *,
               sum(is_new) OVER (PARTITION BY session_id ORDER BY r_start, round_id
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS act_no
        FROM marked
      ),
      per_act AS (
        SELECT session_id,
               act_no,
               min(r_start) AS act_start,
               dateDiff('millisecond', min(r_start), max(r_end)) AS act_span_ms,
               sum(llm_ms) + sum(tool_ms) + sum(phase_ms) AS act_covered_ms,
               sum(phase_ms) AS act_phase_ms
        FROM acts
        GROUP BY session_id, act_no
      )
      SELECT toStartOfInterval(act_start, toIntervalSecond({bucket:UInt32})) AS bucket,
             count() AS activations,
             sum(act_span_ms) AS span_ms,
             sum(greatest(act_span_ms - act_covered_ms, 0)) AS unknown_ms,
             sum(act_phase_ms) AS phase_ms
      FROM per_act
      WHERE act_span_ms > 0
      GROUP BY bucket
      ORDER BY bucket
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [bucket: bucket_seconds(opts)],
      query: "unknown_trends"
    )
  end

  # Rows that can sit on an activation lane: a session, a round, a start.
  defp round_scoped,
    do: "round_id IS NOT NULL AND session_id IS NOT NULL AND started_at IS NOT NULL"

  @doc """
  Latest non-completed rounds — the hard-failure half of the "runs needing
  attention" table (internal-only by construction: only internal sessions
  emit run terminals). Rows: `salix_agent_id`, `session_id`, `round_id`,
  `status`, `duration_ms`, `app_revision`, `observed_at`.
  """
  @spec failed_rounds(String.t(), keyword()) :: result()
  def failed_rounds(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT salix_agent_id,
             session_id,
             round_id,
             status,
             duration_ms,
             app_revision,
             observed_at
      FROM #{events(db, "agent_run_events")}
      WHERE #{scope(opts)}
        AND status != 'completed'
      ORDER BY observed_at DESC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [limit: opts[:limit] || 20],
      query: "failed_rounds"
    )
  end

  @doc """
  Q5, parameterized: sessions with LLM/tool activity in the window but no
  run terminal row covering it, silent past the grace window.

  Fixes over the acceptance script: a lower time bound on activity (raw Q5
  scans forever and surfaces permanently-stale ancient sessions), tenant and
  group binds, newest-silence-first ordering, a bound limit — and it returns
  `salix_agent_id` so the caller can drop external agents (see moduledoc)
  and render links. Rows: `session_id`, `salix_agent_id`, `last_activity_at`,
  `activity_events`.
  """
  @spec unconverged_sessions(String.t(), keyword()) :: result()
  def unconverged_sessions(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      WITH activity AS (
        SELECT session_id,
               anyIf(agent_id, agent_id != '') AS salix_agent_id,
               max(observed_at) AS last_activity_at,
               count() AS activity_events
        FROM (
          SELECT session_id,
                 coalesce(salix_agent_id, '') AS agent_id,
                 tenant_id,
                 group_id,
                 observed_at
          FROM #{events(db, "llm_call_events")}
          UNION ALL
          SELECT session_id,
                 coalesce(salix_agent_id, '') AS agent_id,
                 tenant_id,
                 group_id,
                 observed_at
          FROM #{events(db, "tool_call_events")}
        )
        WHERE session_id IS NOT NULL
          AND observed_at IS NOT NULL
          AND #{scope(opts)}
        GROUP BY session_id
      ),
      terminal AS (
        SELECT session_id,
               max(observed_at) AS terminal_at
        FROM #{terminal_events(db)}
        WHERE session_id IS NOT NULL
          AND tenant_id = {tenant_id:String}
        GROUP BY session_id
      )
      SELECT activity.session_id AS session_id,
             activity.salix_agent_id AS salix_agent_id,
             activity.last_activity_at AS last_activity_at,
             activity.activity_events AS activity_events
      FROM activity
      LEFT JOIN terminal USING (session_id)
      WHERE (terminal.terminal_at IS NULL OR activity.last_activity_at > terminal.terminal_at)
        AND activity.last_activity_at < {stale_before:DateTime}
      ORDER BY activity.last_activity_at DESC
      LIMIT {limit:UInt32}
      SETTINGS join_use_nulls = 1
      FORMAT JSONEachRow
      """
    end

    stale_before =
      opts[:stale_before] || DateTime.add(DateTime.utc_now(), -@stale_grace_seconds, :second)

    ClickHouseRead.run(
      sql,
      binds(tenant_id, opts) ++ [stale_before: dt(stale_before), limit: opts[:limit] || 20],
      query: "unconverged_sessions"
    )
  end

  # ============================ tool_call_events ============================

  @doc """
  Q1, parameterized: per-tool call volume, outcome counts, and the
  guidance_reason split. Rows: `tool_name`, `tool_source`, `total_calls`,
  `completed_calls`, `error_calls`, `guidance_calls`, `cancelled_calls`,
  `guidance_<reason>` counts for the four closed reasons, and
  `capped_calls` (error_type = capped — a SLICE of `error_calls`, never
  added to it).
  """
  @spec tool_rates(String.t(), keyword()) :: result()
  def tool_rates(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT tool_name,
             tool_source,
             count() AS total_calls,
             countIf(status = 'completed') AS completed_calls,
             countIf(status = 'error') AS error_calls,
             countIf(status = 'guidance') AS guidance_calls,
             countIf(status = 'cancelled') AS cancelled_calls,
             countIf(guidance_reason = 'not_callable') AS guidance_not_callable,
             countIf(guidance_reason = 'not_disclosed') AS guidance_not_disclosed,
             countIf(guidance_reason = 'invalid_params') AS guidance_invalid_params,
             countIf(guidance_reason = 'envelope_misuse') AS guidance_envelope_misuse,
             countIf(guidance_reason = 'unauthorized_target') AS guidance_unauthorized_target,
             countIf(error_type = 'capped') AS capped_calls
      FROM #{events(db, "tool_call_events")}
      WHERE #{scope(opts)}#{tool_source_clause(opts)}
      GROUP BY tool_name, tool_source
      ORDER BY error_calls DESC, total_calls DESC, tool_name ASC
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ source_bind(opts), query: "tool_rates")
  end

  @doc """
  Q2 rolled up over the window: per-tool latency quantiles, async rows
  separate (sync and async are timed differently — never averaged
  together). Rows: `tool_name`, `tool_source`, `async`, `total_calls`,
  `p50_ms`, `p95_ms`.
  """
  @spec tool_latency(String.t(), keyword()) :: result()
  def tool_latency(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT tool_name,
             tool_source,
             async,
             count() AS total_calls,
             quantileTDigest(0.50)(duration_ms) AS p50_ms,
             quantileTDigest(0.95)(duration_ms) AS p95_ms
      FROM #{events(db, "tool_call_events")}
      WHERE #{scope(opts)}#{tool_source_clause(opts)}
      GROUP BY tool_name, tool_source, async
      ORDER BY total_calls DESC
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ source_bind(opts), query: "tool_latency")
  end

  @doc """
  Row-expansion drill for one tool: error_type counts. Rows: `error_type`,
  `calls`.
  """
  @spec tool_error_types(String.t(), String.t(), keyword()) :: result()
  def tool_error_types(tenant_id, tool_name, opts \\ []) do
    sql = fn db ->
      """
      SELECT coalesce(error_type, 'unknown') AS error_type,
             count() AS calls
      FROM #{events(db, "tool_call_events")}
      WHERE #{scope(opts)}
        AND tool_name = {tool_name:String}
        AND status = 'error'
      GROUP BY error_type
      ORDER BY calls DESC
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [tool_name: tool_name],
      query: "tool_error_types"
    )
  end

  @doc """
  Row-expansion drill for one tool: the sessions hit hardest by its errors
  and sent-back calls. Rows: `session_id`, `salix_agent_id`, `calls`.
  """
  @spec tool_top_sessions(String.t(), String.t(), keyword()) :: result()
  def tool_top_sessions(tenant_id, tool_name, opts \\ []) do
    sql = fn db ->
      """
      SELECT session_id,
             anyIf(coalesce(salix_agent_id, ''), salix_agent_id IS NOT NULL) AS salix_agent_id,
             count() AS calls
      FROM #{events(db, "tool_call_events")}
      WHERE #{scope(opts)}
        AND tool_name = {tool_name:String}
        AND status IN ('error', 'guidance')
        AND session_id IS NOT NULL
      GROUP BY session_id
      ORDER BY calls DESC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(
      sql,
      binds(tenant_id, opts) ++ [tool_name: tool_name, limit: opts[:limit] || 10],
      query: "tool_top_sessions"
    )
  end

  # ============================ llm_call_events ============================

  @doc """
  Headline LLM tile numbers. One row: `calls`, `failed`, `retried`
  (rows with attempts > 1), `p95_first_token_ms` (streaming calls only).
  """
  @spec llm_overview(String.t(), keyword()) :: result()
  def llm_overview(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT count() AS calls,
             countIf(status = 'error') AS failed,
             countIf(attempts > 1) AS retried,
             quantileTDigestIf(0.95)(first_token_ms, first_token_ms IS NOT NULL) AS p95_first_token_ms
      FROM #{events(db, "llm_call_events")}
      WHERE #{scope(opts)}#{llm_clauses(opts)}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ llm_binds(opts), query: "llm_overview")
  end

  @doc """
  Q3 counts, parameterized: one row per
  `(provider, model, entrypoint, status, error_type, http_status)` with
  `calls` and `retried`. The caller rolls up totals and picks each group's
  top failure — quantiles deliberately live in `llm_speed/2` where the
  grouping doesn't split by outcome.
  """
  @spec llm_reliability(String.t(), keyword()) :: result()
  def llm_reliability(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT provider,
             model,
             entrypoint,
             status,
             coalesce(error_type, 'none') AS error_type,
             http_status,
             count() AS calls,
             countIf(attempts > 1) AS retried
      FROM #{events(db, "llm_call_events")}
      WHERE #{scope(opts)}#{llm_clauses(opts)}
      GROUP BY provider, model, entrypoint, status, error_type, http_status
      ORDER BY calls DESC
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ llm_binds(opts), query: "llm_reliability")
  end

  @doc """
  Latency per `(provider, model, entrypoint)`: `calls`, `p50_ms`, `p95_ms`,
  `p95_first_token_ms`, `streaming_calls` (rows that measured a first
  token — the first-word quantile's denominator).
  """
  @spec llm_speed(String.t(), keyword()) :: result()
  def llm_speed(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT provider,
             model,
             entrypoint,
             count() AS calls,
             quantileTDigest(0.50)(duration_ms) AS p50_ms,
             quantileTDigest(0.95)(duration_ms) AS p95_ms,
             quantileTDigestIf(0.95)(first_token_ms, first_token_ms IS NOT NULL) AS p95_first_token_ms,
             countIf(first_token_ms IS NOT NULL) AS streaming_calls
      FROM #{events(db, "llm_call_events")}
      WHERE #{scope(opts)}#{llm_clauses(opts)}
      GROUP BY provider, model, entrypoint
      ORDER BY calls DESC
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ llm_binds(opts), query: "llm_speed")
  end

  @doc """
  Per-bucket, per-provider call/failure counts and first-token p95. The
  caller sums buckets across providers for the failure-rate line and keeps
  the split for the per-provider first-word series. Rows: `bucket`,
  `provider`, `calls`, `failed`, `p95_first_token_ms`.
  """
  @spec llm_trends(String.t(), keyword()) :: result()
  def llm_trends(tenant_id, opts \\ []) do
    sql = fn db ->
      """
      SELECT toStartOfInterval(observed_at, toIntervalSecond({bucket:UInt32})) AS bucket,
             provider,
             count() AS calls,
             countIf(status = 'error') AS failed,
             quantileTDigestIf(0.95)(first_token_ms, first_token_ms IS NOT NULL) AS p95_first_token_ms
      FROM #{events(db, "llm_call_events")}
      WHERE #{scope(opts)}#{llm_clauses(opts)}
      GROUP BY bucket, provider
      ORDER BY bucket, provider
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(
      sql,
      binds(tenant_id, opts) ++ llm_binds(opts) ++ [bucket: bucket_seconds(opts)],
      query: "llm_trends"
    )
  end

  # ====================== cross-table (overview + session) ======================

  @doc """
  Doorway-tile error rates for one table over the current window and the
  immediately preceding equal-length window, in one scan. One row:
  `calls`, `errors`, `prev_calls`, `prev_errors`.

  `table` is `:tool` (infra denominator: completed + error only) or `:llm`
  (all calls; failed = status error).
  """
  @spec error_overview(:tool | :llm, String.t(), keyword()) :: result()
  def error_overview(table, tenant_id, opts \\ []) when table in [:tool, :llm] do
    {from, to} = window(opts)
    prev_from = DateTime.add(from, -DateTime.diff(to, from, :second), :second)

    {tbl, denom, err} =
      case table do
        :tool -> {"tool_call_events", "status IN ('completed', 'error')", "status = 'error'"}
        :llm -> {"llm_call_events", "1", "status = 'error'"}
      end

    sql = fn db ->
      """
      SELECT countIf(#{denom} AND observed_at >= {from:DateTime}) AS calls,
             countIf(#{err} AND observed_at >= {from:DateTime}) AS errors,
             countIf(#{denom} AND observed_at < {from:DateTime}) AS prev_calls,
             countIf(#{err} AND observed_at < {from:DateTime}) AS prev_errors
      FROM #{events_prev_window(db, tbl)}
      WHERE tenant_id = {tenant_id:String}
        AND observed_at >= {prev_from:DateTime}
        AND observed_at < {to:DateTime}
        #{group_clause(opts)}#{rev_clause(opts)}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [prev_from: dt(prev_from)],
      query: "error_overview"
    )
  end

  @doc """
  Per-revision outcome counts for one table, newest revision first.
  Rows for `:run`: `revision`, `rounds`, `failed`, `last_seen`.
  Rows for `:tool`: `revision`, `calls` (infra denominator), `errors`, `last_seen`.
  Rows for `:llm`: `revision`, `calls`, `errors`, `last_seen`.
  Revisions are `coalesce(app_revision, '')` — the caller labels '' as unknown.
  """
  @spec deploy_rates(:run | :tool | :llm, String.t(), keyword()) :: result()
  def deploy_rates(table, tenant_id, opts \\ []) when table in [:run, :tool, :llm] do
    {tbl, count_sql, err_sql} =
      case table do
        :run ->
          {"agent_run_events", "count() AS rounds", "countIf(status != 'completed') AS failed"}

        :tool ->
          {"tool_call_events", "countIf(status IN ('completed', 'error')) AS calls",
           "countIf(status = 'error') AS errors"}

        :llm ->
          {"llm_call_events", "count() AS calls", "countIf(status = 'error') AS errors"}
      end

    sql = fn db ->
      """
      SELECT coalesce(app_revision, '') AS revision,
             #{count_sql},
             #{err_sql},
             max(observed_at) AS last_seen
      FROM #{events(db, tbl)}
      WHERE #{scope(opts)}
      GROUP BY revision
      ORDER BY last_seen DESC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [limit: opts[:limit] || 6],
      query: "deploy_rates"
    )
  end

  @doc """
  Where the time went, per session, for one table. Rows for `:llm`:
  `session_id`, `salix_agent_id`, `duration_ms` (sum, includes retry
  backoff), `tokens` (prompt + completion), `rounds`, `errors`. Rows for
  `:tool`: `session_id`, `salix_agent_id`, `duration_ms` (overlapping async
  calls can exceed wall-clock), `errors`. Ordered by summed duration.
  """
  @spec session_costs(:tool | :llm, String.t(), keyword()) :: result()
  def session_costs(table, tenant_id, opts \\ []) when table in [:tool, :llm] do
    extra =
      case table do
        :llm ->
          """
                 sum(prompt_tokens + completion_tokens) AS tokens,
                 uniqExact(round_id) AS rounds,
          """

        :tool ->
          ""
      end

    tbl = if table == :llm, do: "llm_call_events", else: "tool_call_events"

    sql = fn db ->
      """
      SELECT session_id,
             anyIf(coalesce(salix_agent_id, ''), salix_agent_id IS NOT NULL) AS salix_agent_id,
             sum(duration_ms) AS duration_ms,
      #{extra}
             countIf(status = 'error') AS errors
      FROM #{events(db, tbl)}
      WHERE #{scope(opts)}
        AND session_id IS NOT NULL
      GROUP BY session_id
      ORDER BY duration_ms DESC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, binds(tenant_id, opts) ++ [limit: opts[:limit] || 15],
      query: "session_costs"
    )
  end

  @doc """
  Q4, parameterized: one session's LLM, tool, and run-terminal rows in
  execution order — extended to carry `model` on the LLM branch and to bind
  the tenant. Rows share the column set: `event_kind` (llm|tool|run),
  `started_at`, `metered_at`, `round_id`, `call_index`, `name`, `model`,
  `detail`, `status`, `error_type`, `guidance_reason`, `duration_ms`,
  `first_token_ms`, `attempts`, `tokens` (prompt + completion, llm rows
  only), `args_fingerprint`, `result_fingerprint`, `async`.
  """
  @spec session_trace(String.t(), String.t(), keyword()) :: result()
  def session_trace(tenant_id, session_id, opts \\ []) do
    # The three branches are wrapped in an outer SELECT because ClickHouse
    # binds a trailing ORDER BY to the LAST select of a UNION, not the whole
    # result set — unwrapped, llm rows would come back unsorted.
    sql = fn db ->
      """
      SELECT *
      FROM (
      SELECT 'llm' AS event_kind,
             started_at,
             metered_at,
             round_id,
             NULL AS call_index,
             provider AS name,
             model,
             response_kind AS detail,
             status,
             error_type,
             NULL AS guidance_reason,
             duration_ms,
             first_token_ms,
             attempts,
             prompt_tokens + completion_tokens AS tokens,
             NULL AS args_fingerprint,
             NULL AS result_fingerprint,
             false AS async
      FROM #{trace_seam(db, "llm_call_events")}
      UNION ALL
      SELECT 'tool' AS event_kind,
             started_at,
             metered_at,
             round_id,
             call_index,
             tool_name AS name,
             NULL AS model,
             tool_source AS detail,
             status,
             error_type,
             guidance_reason,
             duration_ms,
             NULL AS first_token_ms,
             NULL AS attempts,
             NULL AS tokens,
             args_fingerprint,
             result_fingerprint,
             async
      FROM #{trace_seam(db, "tool_call_events")}
      UNION ALL
      SELECT 'run' AS event_kind,
             started_at,
             metered_at,
             round_id,
             NULL AS call_index,
             'agent_run' AS name,
             NULL AS model,
             task_origin AS detail,
             status,
             NULL AS error_type,
             NULL AS guidance_reason,
             duration_ms,
             NULL AS first_token_ms,
             NULL AS attempts,
             NULL AS tokens,
             NULL AS args_fingerprint,
             NULL AS result_fingerprint,
             false AS async
      FROM #{trace_seam(db, "agent_run_events")}
      )
      ORDER BY started_at ASC, round_id ASC, call_index ASC, event_kind ASC
      LIMIT {limit:UInt32}
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(
      sql,
      [tenant_id: tenant_id, session_id: session_id, limit: opts[:limit] || 500],
      query: "session_trace"
    )
  end

  @doc """
  Activity timeline feed: every LLM call, tool call and run terminal that
  finished inside the window, newest first, across sessions — the raw
  material for the Runtime Health "Activity" tab, which lays each round
  out as a bar of calls and shows the time between calls as unknown.

  `tenant_scope` is a tenant id, or `:all` for a deployment-wide read.
  The admin dashboard is deployment-scoped, and neither table generation
  is indexed by tenant, so an all-tenant read scans exactly the date slice
  a per-tenant read does and is bounded by the same read budget.

  Rows share `session_trace/3`'s column set plus the identity columns a
  cross-session view needs: `tenant_id`, `group_id`, `salix_agent_id`,
  `session_id`. A fourth kind, `phase`, carries the round phase facts from
  `agent_phase_events` (`name` = phase, plus `activation_key`, the runtime's
  identity for the input the round answers — NULL on the other kinds).
  Dispatch rows with no session are excluded — they cannot be placed on a
  lane. `limit` (default 4000) bounds the row count; a result that fills it
  is cut at the OLD end, so the oldest round in it may be partial. `before`
  (a `DateTime`, millisecond precision) is the paging cursor: only rounds
  whose EARLIEST row started strictly before it are returned — whole rounds,
  never a round split across pages — so a page of lanes can hand its oldest
  start back to fetch the next, older page within the same window. A call
  recorded with a session but no round (an external runtime's proxied tool
  call) is its own cursor unit: it pages by its own `started_at`, so a
  long external session is served in page-sized slices rather than all or
  nothing.
  """
  @spec activity_trace(String.t() | :all, keyword()) :: result()
  def activity_trace(tenant_scope, opts \\ []) do
    sql = fn db ->
      """
      SELECT * EXCEPT (round_start, round_min)
      FROM (
      SELECT *, if(round_id IS NULL, started_at, round_min) AS round_start
      FROM (
      SELECT *, min(started_at) OVER (PARTITION BY session_id, round_id) AS round_min
      FROM (
      SELECT if(entrypoint = 'compaction', 'compaction', 'llm') AS event_kind,
             tenant_id,
             group_id,
             salix_agent_id,
             session_id,
             round_id,
             started_at,
             duration_ms,
             NULL AS call_index,
             provider AS name,
             model,
             response_kind AS detail,
             status,
             error_type,
             NULL AS guidance_reason,
             first_token_ms,
             attempts,
             prompt_tokens + completion_tokens AS tokens,
             false AS async,
             NULL AS activation_key
      FROM #{activity_events(db, "llm_call_events", tenant_scope)}
      WHERE #{activity_scope(tenant_scope, opts)}
        AND session_id IS NOT NULL
      UNION ALL
      SELECT 'tool' AS event_kind,
             tenant_id,
             group_id,
             salix_agent_id,
             session_id,
             round_id,
             started_at,
             duration_ms,
             call_index,
             tool_name AS name,
             NULL AS model,
             tool_source AS detail,
             status,
             error_type,
             guidance_reason,
             NULL AS first_token_ms,
             NULL AS attempts,
             NULL AS tokens,
             async,
             NULL AS activation_key
      FROM #{activity_events(db, "tool_call_events", tenant_scope)}
      WHERE #{activity_scope(tenant_scope, opts)}
        AND session_id IS NOT NULL
      UNION ALL
      SELECT 'run' AS event_kind,
             tenant_id,
             group_id,
             salix_agent_id,
             session_id,
             round_id,
             started_at,
             duration_ms,
             NULL AS call_index,
             'agent_run' AS name,
             NULL AS model,
             task_origin AS detail,
             status,
             NULL AS error_type,
             NULL AS guidance_reason,
             NULL AS first_token_ms,
             NULL AS attempts,
             NULL AS tokens,
             false AS async,
             NULL AS activation_key
      FROM #{activity_events(db, "agent_run_events", tenant_scope)}
      WHERE #{activity_scope(tenant_scope, opts)}
        AND session_id IS NOT NULL
      UNION ALL
      SELECT 'phase' AS event_kind,
             tenant_id,
             group_id,
             salix_agent_id,
             session_id,
             round_id,
             started_at,
             duration_ms,
             NULL AS call_index,
             phase AS name,
             NULL AS model,
             NULL AS detail,
             status,
             NULL AS error_type,
             NULL AS guidance_reason,
             NULL AS first_token_ms,
             NULL AS attempts,
             NULL AS tokens,
             false AS async,
             activation_key
      FROM #{phase_events(db, tenant_scope)}
      WHERE #{activity_scope(tenant_scope, opts)}
        AND session_id IS NOT NULL
      )
      )
      )
      WHERE #{before_clause(opts)}
      ORDER BY started_at DESC, session_id ASC, round_id ASC, call_index ASC, event_kind ASC
      LIMIT {limit:UInt32}
      FORMAT JSONCompactEachRowWithNames
      """
    end

    # 4,000 rows × 20 columns: with `JSONEachRow` the column names repeated on
    # every row are most of the response; the compact format sends them once.
    ClickHouseRead.run(
      sql,
      activity_binds(tenant_scope, opts) ++ [limit: opts[:limit] || 4000],
      query: "activity_trace",
      format: :compact_with_names
    )
  end

  defp activity_events(db, table, :all), do: events_any_tenant(db, table)
  defp activity_events(db, table, _tenant_id), do: events(db, table)

  # agent_phase_events is a single generation (no frozen predecessor, no
  # seam) with the same layout contract as the *_v2 tables, so it gets the
  # v2 branch alone: the coarse event_date prune, the tenant predicate when
  # scoped, and query-time convergence by version.
  defp phase_events(db, tenant_scope) do
    tenant = if tenant_scope == :all, do: "", else: " AND tenant_id = {tenant_id:String}"

    "(SELECT * FROM (SELECT *, observed_at FROM #{db}.agent_phase_events" <>
      " WHERE event_date >= toDate({from:DateTime}) - 1" <>
      " AND event_date <= toDate({to:DateTime}) + 1" <> tenant <> ") #{converge()})"
  end

  defp activity_scope(:all, opts),
    do: window_clause() <> group_clause(opts) <> rev_clause(opts)

  defp activity_scope(_tenant_id, opts), do: scope(opts)

  # The paging cursor cuts on a ROUND's earliest `started_at`, not on each
  # row's: a round's rows start far apart (its `delivery_wait` row starts
  # when the input arrived, possibly half an hour before its activation),
  # and a per-row cut left the wait on one page and the round's calls on
  # the other. `observed_at` (the window) is a record's completion, which
  # for a long call can sit on the other side of the cursor, so it is not
  # the cursor either.
  defp before_clause(opts) do
    if opts[:before], do: "round_start < {before:DateTime64(3)}", else: "1"
  end

  defp activity_binds(:all, opts),
    do: binds("", opts) |> Keyword.delete(:tenant_id) |> before_bind(opts)

  defp activity_binds(tenant_id, opts), do: binds(tenant_id, opts) |> before_bind(opts)

  defp before_bind(binds, opts) do
    case opts[:before] do
      %DateTime{} = before -> binds ++ [before: dt_ms(before)]
      _ -> binds
    end
  end

  # ============================ shared plumbing ============================

  # Every windowed read wraps its table the same way: a seam over frozen v1
  # and time-partitioned v2, converged at query time.
  #
  #   * The v2 branch carries the ONLY prunable time predicate: a coarse
  #     `event_date` bound (partition + primary-key prefix), widened by one
  #     day on each side so rows whose event_date was derived from a
  #     zone-local date before the UTC fix still land inside the coarse net.
  #     The exact window filter stays OUTSIDE on `observed_at` — a
  #     MATERIALIZED DateTime64 on v2, a per-row parse on frozen v1.
  #   * `tenant_id` is pushed into BOTH branches, not left to the outer
  #     `scope/1`. Neither generation's key can prune by tenant, so without
  #     the pushdown one tenant's dashboard sorts every other tenant's rows
  #     for the same dates. Filtering before convergence is safe because a
  #     `source_key` belongs to one tenant (identity rewrites move a fact
  #     between tenants wholesale, never splitting one key across two).
  #   * There is no FINAL. ReplacingMergeTree replacement is only an
  #     opportunistic compaction on v2 (event_date sits in its key, so a
  #     metered_at drift across midnight leaves two live rows for one
  #     logical fact), and unmerged same-key versions are visible in both
  #     generations — so every read converges duplicates itself: newest
  #     version per (source, source_key). Convergence runs over the coarse
  #     row set BEFORE the exact window filter, the same order FINAL used.
  #     Its residual imprecision is documented as an explicit accuracy
  #     contract — see `docs/observability.md`.
  #   * The v1 branch is never pruned by date. A source-code constant cannot
  #     express "every old writer in THIS environment has exited": the same
  #     artifact is staged, promoted, and rolled back on schedules the build
  #     does not know. Both generations are read until a separate cleanup
  #     release backfills v1 into v2 and retires it.
  #   * UNION ALL matches columns BY POSITION: both generations share the
  #     v1 physical column order (pinned by the live schema test), and each
  #     branch appends `observed_at` last.
  defp events(db, table) do
    v2 =
      "SELECT *, observed_at FROM #{db}.#{table}_v2" <>
        " WHERE tenant_id = {tenant_id:String}" <>
        " AND event_date >= toDate({from:DateTime}) - 1" <>
        " AND event_date <= toDate({to:DateTime}) + 1"

    seam(db, table, v2)
  end

  # error_overview scans its previous comparison window in the same pass, so
  # its coarse lower bound is prev_from, not from.
  defp events_prev_window(db, table) do
    v2 =
      "SELECT *, observed_at FROM #{db}.#{table}_v2" <>
        " WHERE tenant_id = {tenant_id:String}" <>
        " AND event_date >= toDate({prev_from:DateTime}) - 1" <>
        " AND event_date <= toDate({to:DateTime}) + 1"

    seam(db, table, v2)
  end

  defp seam(db, table, v2_branch) do
    v1 =
      "SELECT *, #{parse_metered_at()} AS observed_at FROM #{db}.#{table}" <>
        " WHERE tenant_id = {tenant_id:String}"

    "(SELECT * FROM (#{v2_branch} UNION ALL #{v1}) #{converge()})"
  end

  # The deployment-wide seam (`activity_trace/2` with `:all`): the same two
  # branches without the tenant predicate. Cost is unchanged — tenant is not
  # in either generation's key, so the per-tenant predicate never pruned,
  # it only dropped rows after the same scan. The read budget still bounds
  # it.
  defp events_any_tenant(db, table) do
    v2 =
      "SELECT *, observed_at FROM #{db}.#{table}_v2" <>
        " WHERE event_date >= toDate({from:DateTime}) - 1" <>
        " AND event_date <= toDate({to:DateTime}) + 1"

    v1 = "SELECT *, #{parse_metered_at()} AS observed_at FROM #{db}.#{table}"

    "(SELECT * FROM (#{v2} UNION ALL #{v1}) #{converge()})"
  end

  # v1 has no materialized instant, so its branch parses `metered_at` per
  # row. Use the DateTime64 parser so the UNION unifies with v2's
  # `DateTime64(3)` without losing milliseconds on the frozen side.
  defp parse_metered_at, do: "parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC')"

  # Newest version per logical fact, then the latest INSTANT — never the
  # timestamp text. Accepted ISO-8601 keeps offsets and optional fractional
  # seconds, and those strings are not lexicographically chronological
  # (`...23:59:59Z` sorts above the later `...17:00:01-07:00`, and an exact
  # `...00Z` above the later `...00.001Z`). `metered_at` remains only as the
  # final deterministic tie-break so equal instants pick one row stably.
  # NULLS LAST keeps an unparseable v1 timestamp from winning over a real one.
  defp converge do
    "ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC" <>
      " LIMIT 1 BY source, source_key"
  end

  # Q5's terminal CTE: the latest run-terminal instant per session, across
  # the seam. Two deliberate differences from events/3:
  #
  #   * NO upper coarse bound — a terminal later than the window must stay
  #     visible or a converged session would be reported as unconverged. The
  #     lower bound is verdict-neutral: a terminal it excludes predates every
  #     in-window activity row, so `last_activity_at > terminal_at` is true
  #     with or without it (NULL vs. an older instant decide the same way).
  #   * NO convergence — max(observed_at) over duplicate emissions of one
  #     terminal picks the latest instant, which is the intended semantics.
  defp terminal_events(db) do
    v2 =
      "SELECT session_id, tenant_id, observed_at FROM #{db}.agent_run_events_v2" <>
        " WHERE tenant_id = {tenant_id:String}" <>
        " AND event_date >= toDate({from:DateTime}) - 1"

    v1 =
      "SELECT session_id, tenant_id, #{parse_metered_at()} AS observed_at" <>
        " FROM #{db}.agent_run_events WHERE tenant_id = {tenant_id:String}"

    "(#{v2} UNION ALL #{v1})"
  end

  @doc """
  Accuracy probe for the query-time convergence contract: how many logical
  facts have rows spread across more than one `event_date`.

  Such a fact is the one case where convergence can differ from the old
  whole-table `FINAL`: its revisions sit in different v2 partitions, so a
  window containing only some of them converges over that subset.

  **This probe is deliberately unwindowed, and therefore unbounded.** A
  windowed version cannot see the thing it exists to detect — a revision that
  lands outside the window is exactly the case in question, and clipping it
  makes the probe report zero for the very corpus that is drifting. Bounding
  it would also make the frozen v1 branch (which has no `event_date` bound to
  prune by) report ancient facts against a recent window. So it scans both
  generations in full, per tenant.

  That makes it an operator-run diagnostic, not a dashboard query: it is the
  only read in this module that is not bounded, and it can exceed the read
  timeout on a large corpus. Nothing calls it on a request path.

  Returns one row per table: `facts`, `facts_with_revisions` (more than one
  row for one logical fact), and `facts_spanning_dates` (the subset whose
  rows carry different `event_date` values — the number the contract is
  about). Expected value is 0; a persistently non-zero
  `facts_spanning_dates` is the signal to revisit the contract in
  `docs/observability.md`.
  """
  @spec convergence_drift(String.t(), keyword()) :: result()
  def convergence_drift(tenant_id, _opts \\ []) do
    tables = ~w(llm_call_events tool_call_events agent_run_events)

    sql = fn db ->
      branches =
        Enum.map_join(tables, "\n  UNION ALL\n", fn table ->
          """
            SELECT '#{table}' AS table, source, source_key, event_date
            FROM #{db}.#{table}_v2
            WHERE tenant_id = {tenant_id:String}
            UNION ALL
            SELECT '#{table}' AS table, source, source_key, event_date
            FROM #{db}.#{table}
            WHERE tenant_id = {tenant_id:String}
          """
        end)

      """
      SELECT table,
             count() AS facts,
             countIf(dates > 1) AS facts_spanning_dates,
             countIf(rows > 1) AS facts_with_revisions
      FROM (
        SELECT table, source, source_key,
               uniqExact(event_date) AS dates,
               count() AS rows
        FROM (
      #{branches}
        )
        GROUP BY table, source, source_key
      )
      GROUP BY table
      ORDER BY table
      FORMAT JSONEachRow
      """
    end

    ClickHouseRead.run(sql, [tenant_id: tenant_id], query: "convergence_drift")
  end

  # session_trace's seam: a point lookup with no time window, so the exact
  # tenant/session predicates are pushed into BOTH branches (they are stable
  # equality columns — identity rewrites mutate both generations together)
  # to keep the convergence sort from ordering two whole tables. The v1
  # branch has no prune date: trace history stays readable until the seam
  # cleanup retires v1.
  # `observed_at` is projected explicitly on both branches: it is MATERIALIZED
  # on v2 and therefore NOT part of `SELECT *`, so the convergence clause
  # would not see it otherwise. The frozen branch computes it, matching the
  # windowed seam's column layout.
  defp trace_seam(db, table) do
    point = " WHERE tenant_id = {tenant_id:String} AND session_id = {session_id:String}"
    v2 = "SELECT *, observed_at FROM #{db}.#{table}_v2" <> point
    v1 = "SELECT *, #{parse_metered_at()} AS observed_at FROM #{db}.#{table}" <> point

    "(SELECT * FROM (#{v2} UNION ALL #{v1}) #{converge()})"
  end

  # Fixed clause text chosen by presence — the values themselves always
  # travel as bound parameters, never in the SQL text.
  defp scope(opts) do
    "tenant_id = {tenant_id:String} AND " <>
      window_clause() <> group_clause(opts) <> rev_clause(opts)
  end

  defp window_clause, do: "observed_at >= {from:DateTime} AND observed_at < {to:DateTime}"

  defp group_clause(opts) do
    if opts[:group_id], do: " AND group_id = {group_id:String}", else: ""
  end

  defp rev_clause(opts) do
    if opts[:app_revision], do: " AND app_revision = {rev:String}", else: ""
  end

  defp tool_source_clause(opts) do
    if opts[:tool_source], do: " AND tool_source = {tool_source:String}", else: ""
  end

  defp llm_clauses(opts) do
    provider = if opts[:provider], do: " AND provider = {provider:String}", else: ""
    entrypoint = if opts[:entrypoint], do: " AND entrypoint = {entrypoint:String}", else: ""
    provider <> entrypoint
  end

  defp binds(tenant_id, opts) do
    {from, to} = window(opts)
    base = [tenant_id: tenant_id, from: dt(from), to: dt(to)]

    base
    |> maybe_bind(:group_id, opts[:group_id])
    |> maybe_bind(:rev, opts[:app_revision])
  end

  defp source_bind(opts), do: maybe_bind([], :tool_source, opts[:tool_source])

  defp llm_binds(opts) do
    []
    |> maybe_bind(:provider, opts[:provider])
    |> maybe_bind(:entrypoint, opts[:entrypoint])
  end

  defp maybe_bind(binds, _name, nil), do: binds
  defp maybe_bind(binds, name, value), do: binds ++ [{name, value}]

  defp window(opts) do
    to = opts[:to] || DateTime.utc_now()
    from = opts[:from] || DateTime.add(to, -24 * 3600, :second)
    {from, to}
  end

  defp bucket_seconds(opts) do
    case opts[:bucket_seconds] do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> 3600
    end
  end

  # ClickHouse DateTime params take 'YYYY-MM-DD HH:MM:SS' (UTC).
  defp dt(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  # DateTime64(3) params keep the milliseconds.
  defp dt_ms(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S.%f")
    |> String.slice(0, 23)
  end
end
