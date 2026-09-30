CREATE TABLE IF NOT EXISTS {{table}} (
  dedup String,
  agent String,
  seq UInt64,
  type String,
  message_id Nullable(UInt64),
  payload String
) ENGINE = ReplacingMergeTree
ORDER BY dedup;
