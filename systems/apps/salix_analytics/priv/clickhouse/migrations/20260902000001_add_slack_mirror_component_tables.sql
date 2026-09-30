-- Independent message-component tables so reactions/pins/metadata and the
-- canonical payload can converge without sharing the message/edit/delete
-- version. Old writers that omit `payload` cannot clobber this table.
-- Design: docs/salix/slack-message-mirror.md

CREATE TABLE IF NOT EXISTS {{database}}.slack_message_payloads (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  version UInt64,
  payload String,
  ingest_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
;

CREATE TABLE IF NOT EXISTS {{database}}.slack_message_pins (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  message_ts String,
  pinned_by String,
  version UInt64,
  deleted Bool,
  ingest_source LowCardinality(String),
  ingest_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
;

CREATE TABLE IF NOT EXISTS {{database}}.slack_message_metadata (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  message_ts String,
  version UInt64,
  deleted Bool,
  metadata String,
  ingest_source LowCardinality(String),
  ingest_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
;
