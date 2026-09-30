-- Q4: reconstruct one session trajectory by started_at/call_index and round_id.
-- Replace {session_id:String} with the target session id in ClickHouse HTTP.
-- Seam read (migrations 20260723000001..3): each branch UNIONs v2 with frozen
-- v1 and converges at query time (newest version per source/source_key)
-- instead of FINAL. The point predicate is pushed into every generation
-- branch so convergence never sorts a whole table. Delete the v1 branches
-- together with the seam cleanup.
-- The three kind branches are wrapped in an outer SELECT because ClickHouse
-- binds a trailing ORDER BY to the LAST select of a UNION, not the whole set.
SELECT *
FROM (
SELECT
  'llm' AS event_kind,
  started_at,
  metered_at,
  round_id,
  request_id,
  trace_id,
  NULL AS call_index,
  provider AS name,
  response_kind AS detail,
  status,
  error_type,
  duration_ms,
  first_token_ms,
  attempts,
  NULL AS args_fingerprint,
  NULL AS result_fingerprint
FROM (
  SELECT *
  FROM (
    SELECT *, observed_at FROM llm_call_events_v2 WHERE session_id = {session_id:String}
    UNION ALL
    SELECT *, parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at FROM llm_call_events WHERE session_id = {session_id:String}
  )
  ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC
  LIMIT 1 BY source, source_key
)
UNION ALL
SELECT
  'tool' AS event_kind,
  started_at,
  metered_at,
  round_id,
  request_id,
  trace_id,
  call_index,
  tool_name AS name,
  tool_source AS detail,
  status,
  error_type,
  duration_ms,
  NULL AS first_token_ms,
  NULL AS attempts,
  args_fingerprint,
  result_fingerprint
FROM (
  SELECT *
  FROM (
    SELECT *, observed_at FROM tool_call_events_v2 WHERE session_id = {session_id:String}
    UNION ALL
    SELECT *, parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at FROM tool_call_events WHERE session_id = {session_id:String}
  )
  ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC
  LIMIT 1 BY source, source_key
)
UNION ALL
SELECT
  'run' AS event_kind,
  started_at,
  metered_at,
  round_id,
  request_id,
  trace_id,
  NULL AS call_index,
  'agent_run' AS name,
  task_origin AS detail,
  status,
  NULL AS error_type,
  duration_ms,
  NULL AS first_token_ms,
  NULL AS attempts,
  NULL AS args_fingerprint,
  NULL AS result_fingerprint
FROM (
  SELECT *
  FROM (
    SELECT *, observed_at FROM agent_run_events_v2 WHERE session_id = {session_id:String}
    UNION ALL
    SELECT *, parseDateTime64BestEffortOrNull(metered_at, 3, 'UTC') AS observed_at FROM agent_run_events WHERE session_id = {session_id:String}
  )
  ORDER BY version DESC, observed_at DESC NULLS LAST, metered_at DESC
  LIMIT 1 BY source, source_key
)
)
ORDER BY started_at ASC, round_id ASC, call_index ASC, event_kind ASC;
