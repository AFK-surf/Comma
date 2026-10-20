-- Feishu message mirror. Design: SalixIM.FeishuMessageMirror moduledoc.
--
-- One row is one observed state of one Feishu message. Identity is
-- (tenant_id, app_id, chat_id, message_id), which is also the
-- ReplacingMergeTree ORDER BY. `app_id` scopes the copy because Feishu
-- open_ids are app-scoped: the same message read by two apps names its sender
-- differently, so those copies must not merge.
--
-- `version` is derived from the message's OWN state, never from ingest time:
--
--   version = observed_state_ts_micros * 2 + (deleted ? 1 : 0)
--
-- where observed_state_ts is create_time, update_time once edited, or the
-- recall event's recall_time. A replayed event writes a byte-identical row and
-- an older history observation loses to a newer live one. The `* 2 + 1` keeps
-- a recall above every edit that shares its microsecond.
--
-- A recall event carries no create_time, so the partition is a tenant hash,
-- not a month: a tombstone must land in the same partition as the message it
-- replaces or the merge never meets it. Tombstones are rows and are filtered
-- at read time. `create_time_us` is 0 on a tombstone written from a recall.
--
-- The text index is ngrambf_v1 for the same reason as slack_messages: token
-- filters do not split Chinese text.
CREATE TABLE IF NOT EXISTS {{database}}.feishu_messages (
  tenant_id String,
  app_id String,
  chat_id String,
  message_id String,
  create_time_us UInt64,
  version UInt64,
  deleted Bool,
  root_id String,
  parent_id String,
  thread_id String,
  chat_type LowCardinality(String),
  message_type LowCardinality(String),
  actor_kind LowCardinality(String),
  actor_id String,
  actor_label String,
  text String,
  content String,
  file_count UInt16,
  ingest_source LowCardinality(String),
  observed_ts_us UInt64,
  ingest_at DateTime64(3) DEFAULT now64(3),
  INDEX idx_text text TYPE ngrambf_v1(4, 32768, 3, 0) GRANULARITY 4,
  INDEX idx_actor actor_id TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX idx_thread thread_id TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX idx_create_time create_time_us TYPE minmax GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY cityHash64(tenant_id) % 16
ORDER BY (tenant_id, app_id, chat_id, message_id)
SETTINGS index_granularity = 2048
