-- Q5: LLM/tool activity with no terminal run event after a 15 minute grace window.
-- Seam read (migrations 20260723000001..3): time-pruned v2 UNION frozen v1,
-- activity converged at query time instead of FINAL. Delete the v1 branches
-- together with the seam cleanup.
--
-- The terminal CTE takes NO upper bound (a terminal later than the window
-- must stay visible or a converged session would be reported) and needs no
-- convergence (max over duplicate emissions of one terminal picks the same
-- latest instant). Its v2 lower bound is verdict-neutral: any terminal it
-- excludes predates every in-window activity row, so
-- `last_activity_at > terminal_at` decides identically with or without it.
WITH
  activity AS (
    SELECT
      session_id,
      max(observed_at) AS last_activity_at,
      count() AS activity_events
    FROM (
      SELECT session_id, observed_at
      FROM (
        SELECT *
        FROM (
          SELECT *, observed_at
          FROM llm_call_events_v2
          WHERE event_date >= toDate(now() - INTERVAL 24 HOUR) - 1
            AND event_date <= toDate(now()) + 1
          UNION ALL
          SELECT *, parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at
          FROM llm_call_events
        )
        ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC
        LIMIT 1 BY source, source_key
      )
      UNION ALL
      SELECT session_id, observed_at
      FROM (
        SELECT *
        FROM (
          SELECT *, observed_at
          FROM tool_call_events_v2
          WHERE event_date >= toDate(now() - INTERVAL 24 HOUR) - 1
            AND event_date <= toDate(now()) + 1
          UNION ALL
          SELECT *, parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at
          FROM tool_call_events
        )
        ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC
        LIMIT 1 BY source, source_key
      )
    )
    WHERE session_id IS NOT NULL
      AND observed_at IS NOT NULL
      AND observed_at >= now() - INTERVAL 24 HOUR
    GROUP BY session_id
  ),
  terminal AS (
    SELECT
      session_id,
      any(status) AS terminal_status,
      max(observed_at) AS terminal_at
    FROM (
      SELECT session_id, status, observed_at
      FROM agent_run_events_v2
      WHERE event_date >= toDate(now() - INTERVAL 24 HOUR) - 1
      UNION ALL
      SELECT session_id, status, parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at
      FROM agent_run_events
    )
    WHERE session_id IS NOT NULL
    GROUP BY session_id
  )
SELECT
  activity.session_id,
  activity.last_activity_at,
  activity.activity_events
FROM activity
LEFT JOIN terminal USING (session_id)
WHERE (terminal.terminal_status IS NULL OR activity.last_activity_at > terminal.terminal_at)
  AND activity.last_activity_at < now() - INTERVAL 15 MINUTE
ORDER BY activity.last_activity_at ASC
SETTINGS join_use_nulls = 1;
