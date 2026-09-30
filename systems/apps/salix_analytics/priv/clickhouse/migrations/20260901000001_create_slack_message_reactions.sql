-- Shared current-state reaction observations for mirrored Slack messages.
-- Reactions are context only: this table is never an ambient Triage trigger.
CREATE TABLE IF NOT EXISTS {{database}}.slack_message_reactions (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  message_ts String,
  user_id String,
  reaction String,
  version UInt64,
  deleted Bool,
  ingest_source LowCardinality(String),
  ingest_at DateTime64(3) DEFAULT now64(3),
  INDEX idx_reaction reaction TYPE bloom_filter(0.01) GRANULARITY 4,
  INDEX idx_user user_id TYPE bloom_filter(0.01) GRANULARITY 4
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us, user_id, reaction)
;
