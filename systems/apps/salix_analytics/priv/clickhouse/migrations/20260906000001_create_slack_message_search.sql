-- Metadata-only expansion. New writers persist a source ID with the outbox
-- row; old writers remain valid and default to zero. The background indexer
-- initializes legacy zero IDs by exact physical part/offset, without copying
-- message content, changing versions, or forcing a whole-table merge.
ALTER TABLE {{database}}.slack_messages ADD COLUMN IF NOT EXISTS
  source_write_id UUID DEFAULT toUUID('00000000-0000-0000-0000-000000000000');
ALTER TABLE {{database}}.slack_message_payloads ADD COLUMN IF NOT EXISTS
  source_write_id UUID DEFAULT toUUID('00000000-0000-0000-0000-000000000000');

-- One complete text slice or attachment per row. All parallel arrays belong
-- to this atomic row; no partial extraction may be inserted. A PG-allocated
-- sequence prevents a rescued/late old builder replacing a newer component.
-- PG still decides publication, and source identities are checked on return.
-- Fixed tenant buckets keep full-history reads from opening one vector stream
-- per month. This hash is physical placement only, never identity/authority;
-- tenant/group filters and current owners still authorize every result.
CREATE TABLE IF NOT EXISTS {{database}}.slack_message_search_components (
  event_date Date,
  tenant_id String,
  group_id String,
  connect_id String,
  connect_generation String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  message_ts String,
  thread_ts String,
  actor_id String,
  actor_kind LowCardinality(String),
  component String,
  change_epoch UInt64,
  message_identity String,
  payload_identity String,
  source_version UInt64,
  payload_version UInt64,
  build_id UUID,
  build_sequence UInt64,
  file_id String,
  file_epoch UInt64,
  chunks Array(String),
  kinds Array(String),
  pages Array(UInt32),
  starts Array(UInt64),
  ends Array(UInt64),
  embeddings Array(Array(Float32)),
  indexed_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(build_sequence)
PARTITION BY cityHash64(tenant_id) % 16
ORDER BY (tenant_id, group_id, connect_id,
  workspace_id, channel_id, message_ts_us, component)
SETTINGS index_granularity = 2048;

-- The full normalized text remains independently searchable across embedding
-- slice boundaries. This row is also the current source epoch for vector
-- components; a deleted/edited message must not leave old slices in ranking.
CREATE TABLE IF NOT EXISTS {{database}}.slack_message_search_documents (
  event_date Date,
  tenant_id String,
  group_id String,
  connect_id String,
  connect_generation String,
  workspace_id String,
  channel_id String,
  message_ts_us UInt64,
  message_ts String,
  thread_ts String,
  actor_id String,
  actor_kind LowCardinality(String),
  change_epoch UInt64,
  message_identity String,
  payload_identity String,
  source_version UInt64,
  payload_version UInt64,
  build_id UUID,
  build_sequence UInt64,
  deleted Bool,
  search_text String,
  indexed_at DateTime64(3) DEFAULT now64(3)
) ENGINE = ReplacingMergeTree(build_sequence)
PARTITION BY cityHash64(tenant_id) % 16
ORDER BY (tenant_id, group_id, connect_id, workspace_id, channel_id, message_ts_us)
SETTINGS index_granularity = 2048;
