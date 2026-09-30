-- Round phase facts: what the runtime was doing between the calls the
-- other agent-telemetry tables record. One row per (round, phase):
--
--   activation      the session actor deciding to run: repair, reading the
--                   session, materializing input, rebuilding the runtime
--                   config, committing the activation — up to Round.run
--   prepare         Round.run up to the provider dispatch (prompt snapshot,
--                   context providers, request assembly, fee-control check)
--   response_commit provider completion up to the assistant turn committed
--                   (tool rounds; includes the actor mailbox wait)
--   tool_batch      wall clock of the synchronous tool batch
--   tool_commit     tool results committed to the session
--   boundary        the status=idle write that ends a tool round
--   finalize        provider completion up to the final message committed
--                   (the round that produces text; includes mailbox wait)
--
-- Model calls stay in llm_call_events_v2 and tool calls in
-- tool_call_events_v2; this table only covers the stretches between them,
-- which the Activity tab otherwise has to draw as "unknown". A single
-- generation (no frozen predecessor, no read seam): layout follows the
-- *_v2 contract — month partitions, event_date-leading key, MATERIALIZED
-- observed_at, replacement by version converged at read time. Design
-- rationale in docs/salix/agent-telemetry-consumer.md ("Round phases").
--
-- activation_key is the runtime's own identity for "the input this round
-- is answering" (source message ids), shared by every round of one
-- activation chain, so readers can group a chain exactly instead of by a
-- time heuristic.
CREATE TABLE IF NOT EXISTS {{database}}.agent_phase_events (
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
  phase LowCardinality(String),
  status String,
  duration_ms UInt64,
  started_at DateTime64(3),
  trace_id Nullable(String),
  request_id Nullable(String),
  salix_agent_id Nullable(String),
  session_id Nullable(String),
  round_id Nullable(String),
  activation_key Nullable(String),
  app_revision Nullable(String),
  observed_at DateTime64(3) MATERIALIZED parseDateTime64BestEffortOrZero(metered_at, 3, 'UTC')
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, source, source_key)
;
-- Structural gates, same reasoning as the *_v2 tables: CREATE TABLE IF NOT
-- EXISTS is a no-op against a near-miss precreated table, so the layout
-- this reader depends on is asserted rather than assumed.
SELECT throwIf(
  (SELECT count() FROM system.tables
   WHERE database = '{{database}}' AND name = 'agent_phase_events'
     AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
     AND partition_key = 'toYYYYMM(event_date)'
     AND sorting_key = 'event_date, source, source_key') != 1,
  'agent_phase_events exists with an unexpected engine, partition key, or sorting key'
);

SELECT throwIf(
  (SELECT count() FROM system.columns
   WHERE database = '{{database}}' AND table = 'agent_phase_events'
     AND name = 'observed_at'
     AND type = 'DateTime64(3)'
     AND default_kind = 'MATERIALIZED'
     AND default_expression = 'parseDateTime64BestEffortOrZero(metered_at, 3, \'UTC\')') != 1,
  'agent_phase_events.observed_at is missing, mistyped, or has a drifted MATERIALIZED expression'
);

SELECT throwIf(
  (SELECT arrayStringConcat(groupArray(concat(name, ' ', type)), ',')
   FROM (SELECT name, type FROM system.columns
         WHERE database = '{{database}}' AND table = 'agent_phase_events'
         ORDER BY position))
  != 'dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,tenant_id String,group_id String,actor_type String,resource_kind String,charge_status String,phase LowCardinality(String),status String,duration_ms UInt64,started_at DateTime64(3),trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),round_id Nullable(String),activation_key Nullable(String),app_revision Nullable(String),observed_at DateTime64(3)',
  'agent_phase_events column set or order drifted from the contract the sink and readers were built against'
)
