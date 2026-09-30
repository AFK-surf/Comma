-- Q2: tool p50/p95 latency and hourly frequency, split by async flag.
-- Seam read (migrations 20260723000001..3): time-pruned v2 UNION frozen v1,
-- converged at query time instead of FINAL. Delete the v1 branch together
-- with the seam cleanup.
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
  toStartOfHour(observed_at) AS hour,
  tool_name,
  tool_source,
  async,
  count() AS total_calls,
  quantileTDigest(0.50)(duration_ms) AS p50_duration_ms,
  quantileTDigest(0.95)(duration_ms) AS p95_duration_ms
FROM events
WHERE observed_at >= now() - INTERVAL 24 HOUR
GROUP BY hour, tool_name, tool_source, async
ORDER BY hour DESC, p95_duration_ms DESC;
