-- Slack message mirror. Design: docs/salix/slack-message-mirror.md
--
-- One row is one observed state of one Slack message. Identity is
-- (tenant_id, workspace_id, channel_id, message_ts_us), which is also the
-- ReplacingMergeTree ORDER BY, so two observations of the same message
-- collapse and two different messages never can.
--
-- `tenant_id` leads the key even though Slack identity starts at the
-- workspace: it is the isolation boundary every read is scoped by, and it
-- makes a per-tenant erasure a key-prefix operation rather than a full scan.
-- One Slack workspace reachable from two tenants is stored twice on purpose —
-- that is exactly where the copies must not be shared. `group_id` is
-- deliberately absent: a group is an access-control fact, not a storage one,
-- so two bots in one workspace do not duplicate the same message.
--
-- `version` is derived from the message's OWN observable state, never from
-- when we happened to see it:
--
--   version = observed_state_ts_micros * 2 + (deleted ? 1 : 0)
--
-- where observed_state_ts is the message ts, its `edited.ts` once edited, or
-- the `message_deleted` event_ts. Two consequences fall out, and both are the
-- point: replaying the same Slack event produces a byte-identical row, and a
-- late writer that observed an OLDER state (a backfill page racing the live
-- tail) loses the merge instead of resurrecting stale text. The `* 2 + 1`
-- keeps a tombstone above every edit that shares its microsecond.
--
-- Tombstones are kept as rows and filtered at read time; the engine is plain
-- ReplacingMergeTree, NOT the `is_deleted` cleanup form. Physically removing a
-- tombstone would let a replayed pre-delete observation win by default and
-- resurrect a message the user deleted. Retention is the partition's job.
--
-- The text index is `ngrambf_v1`, not `tokenbf_v1`: token filters split on
-- non-alphanumeric boundaries, which does not tokenize Chinese at all, and
-- this corpus is bilingual. 4-grams serve both scripts and substring queries.
-- It is unused until the read seam lands; it is declared here because adding
-- a skip index later requires MATERIALIZE INDEX over every existing part.
CREATE TABLE IF NOT EXISTS {{database}}.slack_messages (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  message_ts String,
  thread_ts String,
  version UInt64,
  deleted Bool,
  actor_kind LowCardinality(String),
  actor_id String,
  subtype LowCardinality(String),
  text String,
  files String,
  file_count UInt16,
  reply_count UInt32,
  edited_ts String,
  ingest_source LowCardinality(String),
  -- Stamped by the server, and deliberately not by the writer: it is a
  -- diagnostic ("when did we see this"), never an ordering input. `version`
  -- is the only thing that decides a merge, and it comes from the message's
  -- own state. A row omits this column and ClickHouse fills it.
  ingest_at DateTime64(3) DEFAULT now64(3),
  INDEX idx_text text TYPE ngrambf_v1(4, 32768, 3, 0) GRANULARITY 4,
  INDEX idx_actor actor_id TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX idx_thread thread_ts TYPE bloom_filter(0.01) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
;
