-- Optional, replaceable text index. No external call or index readiness gate.
-- Freshness is checked against the canonical mirror at read time, including
-- equal-version text changes. See docs/salix/slack-semantic-search.md.
CREATE TABLE IF NOT EXISTS {{database}}.slack_semantic_documents (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  source_version UInt64,
  payload_version UInt64,
  source_text String,
  chunks Array(String),
  embeddings Array(Array(Float32)),
  indexed_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(indexed_at)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us)
;

-- Independently replaceable complete file results; raw source_files is an
-- authoritative-source comparison, not a digest or attestation.
CREATE TABLE IF NOT EXISTS {{database}}.slack_semantic_files (
  event_date Date,
  tenant_id String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  source_version UInt64,
  payload_version UInt64,
  source_files String,
  file_id String,
  chunks Array(String),
  kinds Array(String),
  pages Array(UInt32),
  starts Array(UInt64),
  ends Array(UInt64),
  embeddings Array(Array(Float32)),
  indexed_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(indexed_at)
PARTITION BY toYYYYMM(event_date)
ORDER BY (tenant_id, workspace_id, channel_id, message_ts_us, file_id)
;
