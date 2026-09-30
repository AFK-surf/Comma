-- Time-partitioned successor to llm_call_events (see 20260723000003 header
-- comment for the shared design contract of the three *_v2 tables).
--
-- Layout: PARTITION BY month + event_date-leading ORDER BY so window reads
-- prune parts/granules instead of scanning all history. observed_at is a
-- MATERIALIZED typed timestamp so window predicates stop re-parsing the
-- metered_at String per row per query.
--
-- IMPORTANT — ORDER BY is a LAYOUT key here, not a dedup contract. The v1
-- table's ReplacingMergeTree key (source, source_key) was the storage-level
-- replacement identity; emitters may re-emit one logical fact with a drifted
-- metered_at (and therefore a drifted event_date), so with event_date in the
-- key such retries become distinct rows that background replacement will
-- never collapse. That is accepted by design: every reader converges at
-- query time (ORDER BY version DESC LIMIT 1 BY source, source_key) instead
-- of relying on FINAL. ReplacingMergeTree remains only as an opportunistic
-- storage compaction for same-day retries.
--
-- Column order MUST stay position-identical to v1 (create + ALTER history):
-- readers UNION v1 and v2 with SELECT * during the seam window, and
-- ClickHouse matches UNION columns by position. The live schema test pins
-- this. Never ALTER one generation without the other while both exist.
--
-- tenant_id / group_id / salix_agent_id / session_id stay OUT of the key:
-- hierarchy and session identity migrations rewrite them via ALTER UPDATE,
-- and ClickHouse rejects mutations of key columns.
CREATE TABLE IF NOT EXISTS {{database}}.llm_call_events_v2 (
  dedup String,
  source String,
  source_key String,
  version UInt64,
  event_date Date,
  metered_at String,
  created_at String,
  entrypoint String,
  surface String,
  billing_account_id String,
  product_owner_type String,
  product_owner_id String,
  tenant_id String,
  group_id String,
  actor_type String,
  resource_kind String,
  provider Nullable(String),
  sku Nullable(String),
  model Nullable(String),
  status String,
  charge_status String,
  prompt_tokens UInt64,
  completion_tokens UInt64,
  total_tokens UInt64,
  cache_read_input_tokens UInt64,
  cache_write_input_tokens UInt64,
  quality String,
  trace_id Nullable(String),
  request_id Nullable(String),
  salix_agent_id Nullable(String),
  session_id Nullable(String),
  turn_id Nullable(String),
  round_id Nullable(String),
  stale Bool,
  duration_ms Nullable(UInt64),
  started_at Nullable(DateTime64(3)),
  first_token_ms Nullable(UInt64),
  attempts UInt8 DEFAULT 1,
  response_kind Nullable(String),
  error_type String DEFAULT 'none',
  http_status Nullable(UInt16),
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
   WHERE database = '{{database}}' AND name = 'llm_call_events_v2'
     AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
     AND partition_key = 'toYYYYMM(event_date)'
     AND sorting_key = 'event_date, source, source_key') != 1,
  'llm_call_events_v2 exists with an unexpected engine, partition key, or sorting key'
);

SELECT throwIf(
  (SELECT count() FROM system.columns
   WHERE database = '{{database}}' AND table = 'llm_call_events_v2'
     AND name = 'observed_at'
     AND type = 'DateTime64(3)'
     AND default_kind = 'MATERIALIZED'
     AND default_expression = 'parseDateTime64BestEffortOrZero(metered_at, 3, \'UTC\')') != 1,
  'llm_call_events_v2.observed_at is missing, mistyped, or has a drifted MATERIALIZED expression'
);

SELECT throwIf(
  (SELECT arrayStringConcat(groupArray(concat(name, ' ', type)), ',')
   FROM (SELECT name, type FROM system.columns
         WHERE database = '{{database}}' AND table = 'llm_call_events_v2'
         ORDER BY position))
  != 'dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,billing_account_id String,product_owner_type String,product_owner_id String,tenant_id String,group_id String,actor_type String,resource_kind String,provider Nullable(String),sku Nullable(String),model Nullable(String),status String,charge_status String,prompt_tokens UInt64,completion_tokens UInt64,total_tokens UInt64,cache_read_input_tokens UInt64,cache_write_input_tokens UInt64,quality String,trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),turn_id Nullable(String),round_id Nullable(String),stale Bool,duration_ms Nullable(UInt64),started_at Nullable(DateTime64(3)),first_token_ms Nullable(UInt64),attempts UInt8,response_kind Nullable(String),error_type String,http_status Nullable(UInt16),app_revision Nullable(String),observed_at DateTime64(3)',
  'llm_call_events_v2 column set or order drifted — the seam UNIONs both generations by position'
)
