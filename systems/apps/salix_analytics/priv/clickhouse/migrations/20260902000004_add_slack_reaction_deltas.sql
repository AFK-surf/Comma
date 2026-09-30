-- Reaction overlay is a history snapshot plus the event stream after that
-- snapshot was taken. Latest-row identity (user, reaction) collapses
-- add-then-remove and cannot be a cut against the snapshot. Deltas keep
-- `version` in the sorting key so retries collapse and distinct events do not.
-- `observed_ts_us` on the payload is Slack event time for webhooks and Pod
-- now for backfill (the live path starts first; same clock assumption as
-- indexed_to). Design: docs/salix/slack-message-mirror.md
--
-- Expand-only. Old `slack_message_reactions` is unread by new readers.

ALTER TABLE {{database}}.slack_message_payloads
  ADD COLUMN IF NOT EXISTS observed_ts_us UInt64 DEFAULT 0
;

ALTER TABLE {{database}}.slack_messages
  ADD COLUMN IF NOT EXISTS observed_ts_us UInt64 DEFAULT 0
;

CREATE TABLE IF NOT EXISTS {{database}}.slack_message_reaction_deltas (
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
  ingest_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us, user_id, reaction, version)
;
