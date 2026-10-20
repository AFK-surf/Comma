-- Record of QQ group messages. Design: SalixIM.QQMessageRecord moduledoc.
--
-- One row is one message QQ delivered to a bot, or one message the bot sent
-- to a group. Identity is (tenant_id, app_id, chat_id, message_id), which is
-- also the ReplacingMergeTree ORDER BY. `app_id` is the bot's AppID and scopes
-- the copy because QQ OpenIDs are per bot: the same group and the same person
-- have different ids for two bots, so their copies must not merge.
--
-- `version` is derived from the message's own send time, never from ingest
-- time, so a callback QQ delivers twice writes a byte-identical row. QQ sends
-- no event for a recalled or changed message, so `deleted` stays false.
--
-- The thread columns are part of the row shape and stay empty: a QQ group has
-- no threads.
--
-- The text index is ngrambf_v1 for the same reason as slack_messages: token
-- filters do not split Chinese text.
CREATE TABLE IF NOT EXISTS {{database}}.qq_messages (
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
  INDEX idx_create_time create_time_us TYPE minmax GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY cityHash64(tenant_id) % 16
ORDER BY (tenant_id, app_id, chat_id, message_id)
SETTINGS index_granularity = 2048
