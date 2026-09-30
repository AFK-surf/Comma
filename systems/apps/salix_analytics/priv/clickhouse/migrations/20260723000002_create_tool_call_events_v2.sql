-- Time-partitioned successor to tool_call_events. Shared design contract in
-- the 20260723000003 header comment; dedup/layout rationale in 20260723000001.
-- Column order MUST stay position-identical to v1 (seam readers UNION with
-- SELECT *; the live schema test pins it).
CREATE TABLE IF NOT EXISTS {{database}}.tool_call_events_v2 (
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
  tool_name String,
  tool_source String,
  status String,
  error_type Nullable(String),
  guidance_reason Nullable(String),
  duration_ms UInt64,
  started_at DateTime64(3),
  args_fingerprint Nullable(String),
  result_fingerprint Nullable(String),
  call_index Nullable(UInt64),
  async Bool,
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
-- Structural gate. CREATE TABLE IF NOT EXISTS is a no-op against an existing
-- table, so without this a near-miss schema (right engine and keys, but a
-- wrong materialized expression, a drifted column order, or a wrong column
-- type) would ledger as success and fail at the first read. The full column
-- name+type contract is checked, not just names: an exact-name table with a
-- wrong type (e.g. tenant_id UInt64) passes a name check and then rejects
-- String writes. Re-runs against a correct table are no-ops, so this stays
-- replay-safe.
-- ClickHouse Cloud rewrites ReplacingMergeTree DDL to its storage-native
-- SharedReplacingMergeTree and reports that concrete engine in system.tables.
-- Both names preserve the replacement-mode contract checked here; accepting
-- any other MergeTree family would weaken the gate.
SELECT throwIf(
  (SELECT count() FROM system.tables
   WHERE database = '{{database}}' AND name = 'tool_call_events_v2'
     AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
     AND partition_key = 'toYYYYMM(event_date)'
     AND sorting_key = 'event_date, source, source_key') != 1,
  'tool_call_events_v2 exists with an unexpected engine, partition key, or sorting key'
);

SELECT throwIf(
  (SELECT count() FROM system.columns
   WHERE database = '{{database}}' AND table = 'tool_call_events_v2'
     AND name = 'observed_at'
     AND type = 'DateTime64(3)'
     AND default_kind = 'MATERIALIZED'
     AND default_expression = 'parseDateTime64BestEffortOrZero(metered_at, 3, \'UTC\')') != 1,
  'tool_call_events_v2.observed_at is missing, mistyped, or has a drifted MATERIALIZED expression'
);

SELECT throwIf(
  (SELECT arrayStringConcat(groupArray(concat(name, ' ', type)), ',')
   FROM (SELECT name, type FROM system.columns
         WHERE database = '{{database}}' AND table = 'tool_call_events_v2'
         ORDER BY position))
  != 'dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,tenant_id String,group_id String,actor_type String,resource_kind String,charge_status String,tool_name String,tool_source String,status String,error_type Nullable(String),guidance_reason Nullable(String),duration_ms UInt64,started_at DateTime64(3),args_fingerprint Nullable(String),result_fingerprint Nullable(String),call_index Nullable(UInt64),async Bool,trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),round_id Nullable(String),app_revision Nullable(String),observed_at DateTime64(3)',
  'tool_call_events_v2 column set or order drifted — the seam UNIONs both generations by position'
)
