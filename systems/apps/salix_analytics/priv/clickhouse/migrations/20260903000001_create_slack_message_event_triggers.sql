-- Webhook observations that may create ambient Triage receipts.
-- History backfill writes slack_messages (and may replace ingest_source at
-- equal version) but never this table, so a live event's trigger fact
-- survives a later reconstruction of the same physical message.
-- Expand-only. Old writers ignore it; mixed-version new patrols miss
-- webhooks that only old Pods ACKed.

CREATE TABLE IF NOT EXISTS {{database}}.slack_message_event_triggers (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  version UInt64,
  ingest_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
;
