-- Time-partitioned successor to agent_run_events, completing the *_v2 trio
-- (20260723000001..3).
--
-- == Shared design contract for the three agent-telemetry *_v2 tables ==
--
-- The v1 tables (ReplacingMergeTree ORDER BY (source, source_key), no
-- PARTITION BY, String timestamps, every read through FINAL) forced every
-- Runtime Health refresh to merge and scan all parts ever written. The v2
-- generation fixes the layout; the CUTOVER deliberately avoids the failure
-- modes of the withdrawn in-place rebuild (PR #535):
--
--   * These migrations only CREATE IF NOT EXISTS — no INSERT SELECT copy, no
--     RENAME/EXCHANGE, no exclusive writer quiesce. Every statement is
--     idempotent, so the runner's replay-the-whole-file retry semantics and
--     transport-level request retries are both safe.
--   * The same release switches the typed sink to write *_v2 and switches
--     readers to a seam: UNION of frozen v1 (still scanned with the old
--     String-parse predicate, but no longer growing) and pruned v2, with
--     query-time convergence. Rolling-deploy old pods keep writing v1; the
--     seam reads both, so no rows are lost either side of the flip.
--   * v1 history is NOT copied, and readers never prune the v1 branch on a
--     build-time date — a source constant cannot know when an environment's
--     old writers exited. Both generations are read until a later cleanup
--     release backfills v1 into v2 (safe once v1 has been frozen a full
--     release) and drops it together with the seam.
--
-- Dedup note (full rationale in 20260723000001): ORDER BY here is a layout
-- key, not a replacement-identity contract — readers converge duplicates at
-- query time, so a metered_at drift across midnight can never double-count.
--
-- == Bounded reads: the read budget, not projections ==
--
-- These tables carry NO tenant projections. `tenant_id` cannot go in the
-- sorting key (identity rewrites mutate it via ALTER UPDATE, which ClickHouse
-- rejects on key columns), and a non-key predicate prunes nothing -- so a
-- per-tenant read scans every tenant's rows for the window's dates. What keeps
-- that bounded is not a second sorted copy but the per-query read budget in
-- SalixAnalytics.ClickHouseRead (max rows/bytes/memory/time, overflow throw):
-- a read that would scan too much aborts and the dashboard shows "narrow the
-- window". Windowed reads still prune by PARTITION and the event_date-leading
-- key; only the tenant dimension is unindexed. These are low-frequency
-- operator dashboards, so a full date-slice scan under the budget is an
-- acceptable cost to avoid ~2-3x storage on growing tables. If a large
-- deployment's default view starts hitting the budget (visible in the
-- salix_analytics operation duration / over_budget metrics), tenant
-- projections can be added back in a follow-up.
--
-- == Layout verification ==
--
-- CREATE TABLE IF NOT EXISTS is a no-op against a table that already exists
-- with the WRONG layout, and a presence-only postcondition would ledger that
-- as success — the first read of `observed_at` then fails at runtime. The
-- throwIf statements below fail the migration instead.
CREATE TABLE IF NOT EXISTS {{database}}.agent_run_events_v2 (
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
  status String,
  duration_ms UInt64,
  started_at DateTime64(3),
  trace_id Nullable(String),
  request_id Nullable(String),
  salix_agent_id Nullable(String),
  session_id Nullable(String),
  round_id Nullable(String),
  app_revision Nullable(String),
  task_origin Nullable(String),
  platform Nullable(String),
  source_schedule_id Nullable(String),
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
   WHERE database = '{{database}}' AND name = 'agent_run_events_v2'
     AND engine IN ('ReplacingMergeTree', 'SharedReplacingMergeTree')
     AND partition_key = 'toYYYYMM(event_date)'
     AND sorting_key = 'event_date, source, source_key') != 1,
  'agent_run_events_v2 exists with an unexpected engine, partition key, or sorting key'
);

SELECT throwIf(
  (SELECT count() FROM system.columns
   WHERE database = '{{database}}' AND table = 'agent_run_events_v2'
     AND name = 'observed_at'
     AND type = 'DateTime64(3)'
     AND default_kind = 'MATERIALIZED'
     AND default_expression = 'parseDateTime64BestEffortOrZero(metered_at, 3, \'UTC\')') != 1,
  'agent_run_events_v2.observed_at is missing, mistyped, or has a drifted MATERIALIZED expression'
);

SELECT throwIf(
  (SELECT arrayStringConcat(groupArray(concat(name, ' ', type)), ',')
   FROM (SELECT name, type FROM system.columns
         WHERE database = '{{database}}' AND table = 'agent_run_events_v2'
         ORDER BY position))
  != 'dedup String,source String,source_key String,version UInt64,event_date Date,metered_at String,created_at String,entrypoint String,surface String,tenant_id String,group_id String,actor_type String,resource_kind String,charge_status String,status String,duration_ms UInt64,started_at DateTime64(3),trace_id Nullable(String),request_id Nullable(String),salix_agent_id Nullable(String),session_id Nullable(String),round_id Nullable(String),app_revision Nullable(String),task_origin Nullable(String),platform Nullable(String),source_schedule_id Nullable(String),observed_at DateTime64(3)',
  'agent_run_events_v2 column set or order drifted — the seam UNIONs both generations by position'
)
