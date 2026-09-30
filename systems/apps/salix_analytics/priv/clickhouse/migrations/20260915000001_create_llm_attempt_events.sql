-- Provider attempt failures: every failed attempt of a logical model
-- request, including the ones a later attempt recovered from and the ones
-- whose job was killed before it could write its llm_call_events_v2 row.
-- One row per (round, request, attempt):
--
--   attempt      1-based attempt number inside the logical request
--   outcome      retry      another attempt follows after delay_ms
--                abandoned  the delay would outlast the request deadline
--                exhausted  no more attempts (budget spent or not retryable)
--   category     the failure class the provider seam assigned
--                (transport_error, retryable_provider_error, ...)
--   reason       identifier-only summary: provider error type/code/status
--                from a JSON body, kernel reason words, atoms and struct
--                names of a transport reason, an exception's module.
--                Never provider message text, raw bodies, exception
--                messages or exit values (providers echo API keys in
--                them); the raw detail is sealed in agent_event_archive.
--   http_status  the provider's HTTP status when the failure carried one
--   duration_ms  how long the failed attempt ran
--   delay_ms     the backoff chosen before the next attempt (0 otherwise)
--
-- llm_call_events_v2 keeps one row per logical request with its final
-- status and total attempt count; it cannot say why the earlier attempts
-- failed, and a request killed at the job deadline never reaches it at all
-- (staging 2026-09-14: one Router failed 18 rounds in a row at the 600 s
-- deadline with no provider row to explain them). Same single-generation
-- layout as agent_phase_events: month partitions, event_date-leading key,
-- MATERIALIZED observed_at, replacement by version converged at read time.
CREATE TABLE IF NOT EXISTS {{database}}.llm_attempt_events (
  dedup String,
  source String,
  source_key String,
  version UInt64,
  event_date Date,
  metered_at String,
  created_at String,
  entrypoint String,
  surface String,
  tenant_id String,
  group_id String,
  actor_type String,
  resource_kind String,
  charge_status String,
  provider Nullable(String),
  model Nullable(String),
  attempt UInt8,
  max_attempts UInt8,
  outcome LowCardinality(String),
  category LowCardinality(String),
  reason String,
  http_status Nullable(UInt16),
  duration_ms UInt64,
  delay_ms UInt64,
  started_at DateTime64(3),
  trace_id Nullable(String),
  request_id Nullable(String),
  salix_agent_id Nullable(String),
  session_id Nullable(String),
  round_id Nullable(String),
  app_revision Nullable(String),
  observed_at DateTime64(3) MATERIALIZED parseDateTime64BestEffortOrZero(metered_at, 3, 'UTC')
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, source, source_key)
;
-- Structural gates, same reasoning as agent_phase_events: CREATE TABLE IF
-- NOT EXISTS is a no-op against a near-miss precreated table, so the layout
-- the sink and readers depend on is asserted rather than assumed.
SELECT throwIf(
  (SELECT count() FROM system.tables
   WHERE database = '{{database}}' AND name = 'llm_attempt_events'
     AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
     AND partition_key = 'toYYYYMM(event_date)'
     AND sorting_key = 'event_date, source, source_key') != 1,
  'llm_attempt_events exists with an unexpected engine, partition key, or sorting key'
);

SELECT throwIf(
  (SELECT count() FROM system.columns
   WHERE database = '{{database}}' AND table = 'llm_attempt_events'
     AND name = 'observed_at'
     AND type = 'DateTime64(3)'
     AND default_kind = 'MATERIALIZED'
     AND default_expression = 'parseDateTime64BestEffortOrZero(metered_at, 3, \'UTC\')') != 1,
  'llm_attempt_events.observed_at is missing, mistyped, or has a drifted MATERIALIZED expression'
);

SELECT throwIf(
  (SELECT arrayStringConcat(groupArray(concat(name, ' ', type)), ',')
   FROM (SELECT name, type FROM system.columns
         WHERE database = '{{database}}' AND table = 'llm_attempt_events'
         ORDER BY position))
  != 'dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,tenant_id String,group_id String,actor_type String,resource_kind String,charge_status String,provider Nullable(String),model Nullable(String),attempt UInt8,max_attempts UInt8,outcome LowCardinality(String),category LowCardinality(String),reason String,http_status Nullable(UInt16),duration_ms UInt64,delay_ms UInt64,started_at DateTime64(3),trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),round_id Nullable(String),app_revision Nullable(String),observed_at DateTime64(3)',
  'llm_attempt_events column set or order drifted from the contract the sink and readers were built against'
)
