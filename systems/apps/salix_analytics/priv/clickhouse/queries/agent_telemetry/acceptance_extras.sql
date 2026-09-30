-- PR5 A-class acceptance probes: stale rate, cache hit, token/turn, capped rate, tokens/sec.
-- Seam read (migrations 20260723000001..3): time-pruned v2 UNION frozen v1,
-- converged at query time instead of FINAL. Delete the v1 branches together
-- with the seam cleanup.
WITH
  llm AS (
    SELECT *
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
    WHERE observed_at >= now() - INTERVAL 24 HOUR
  ),
  tools AS (
    SELECT *
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
    WHERE observed_at >= now() - INTERVAL 24 HOUR
  )
SELECT 'llm_stale_rate' AS metric, countIf(stale) / nullIf(count(), 0) AS value FROM llm
UNION ALL
SELECT
  'llm_cache_hit_rate',
  countIf(cache_read_input_tokens > 0) / nullIf(count(), 0)
FROM llm
UNION ALL
SELECT
  'llm_tokens_per_round',
  sum(prompt_tokens + completion_tokens) / nullIf(uniqExact(round_id), 0)
FROM llm
UNION ALL
SELECT
  'tool_capped_rate',
  countIf(error_type = 'capped') / nullIf(countIf(status != 'cancelled'), 0)
FROM tools
UNION ALL
SELECT
  'llm_tokens_per_second',
  sum(completion_tokens) /
    nullIf(sum(greatest(duration_ms - ifNull(first_token_ms, 0), 0)) / 1000, 0)
FROM llm;
