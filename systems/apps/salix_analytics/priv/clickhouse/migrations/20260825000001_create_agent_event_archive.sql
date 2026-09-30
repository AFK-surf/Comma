-- Encrypted agent event archive. Design: docs/salix/encrypted-agent-event-archive.md
--
-- Every row is one boundary crossing of the agent loop. `e` is a complete,
-- standalone age v1 file, base64-encoded; every other column is the PLAINTEXT
-- header, stored as a real column so the archive stays navigable, purgeable and
-- gap-checkable by people who hold no key at all. That asymmetry is the whole
-- design: metadata is queryable, content is not readable in the cluster.
--
-- Why base64 rather than raw bytes: rows arrive over the HTTP interface as
-- JSONEachRow, whose String values must be valid UTF-8. An age file is
-- arbitrary bytes. The 33% inflation is the documented cost of ingesting
-- through the same narrow HTTP sink the rest of the analytics path uses.
--
-- Identity is (event_date, tenant_id, stream, writer, seq), which is also the
-- ReplacingMergeTree dedup key. `writer` is a per-boot random id and is NOT
-- decoration: the seq counter is node-local ETS and restarts at 1 on every
-- boot, so (stream, seq) alone collides across restarts and would let
-- ReplacingMergeTree silently collapse two DIFFERENT events into one. With
-- `writer` in the key, a retried insert of the same item is idempotent and two
-- genuinely different items can never merge.
CREATE TABLE IF NOT EXISTS {{database}}.agent_event_archive (
  event_date Date,
  tenant_id String,
  stream String,
  writer String,
  seq UInt64,
  ts String,
  agent_id String,
  session_id String,
  round_id String,
  boundary LowCardinality(String),
  direction LowCardinality(String),
  payload_bytes UInt64,
  app_revision String,
  key_ids Array(String),
  wire_version UInt16,
  e String,
  observed_at DateTime64(3) MATERIALIZED parseDateTime64BestEffortOrZero(ts, 3, 'UTC')
) ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, tenant_id, stream, writer, seq)
;
