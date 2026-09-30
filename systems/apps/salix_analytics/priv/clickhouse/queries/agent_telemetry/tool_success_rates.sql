-- Q1: 24h tool call volume, infra success rate, and guidance rate.
-- Seam read (migrations 20260723000001..3): time-pruned v2 UNION frozen v1,
-- converged at query time (newest version per source/source_key) instead of
-- FINAL. Delete the v1 branch together with the seam cleanup.
WITH events AS (
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
SELECT
  tool_name,
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
  completed_calls / nullIf(completed_calls + error_calls, 0) AS infra_success_rate,
  guidance_calls / nullIf(completed_calls + error_calls + guidance_calls, 0) AS guidance_rate
FROM events
WHERE observed_at >= now() - INTERVAL 24 HOUR
GROUP BY tool_name, tool_source
ORDER BY total_calls DESC, tool_name ASC;
