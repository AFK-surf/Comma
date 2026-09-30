ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS duration_ms Nullable(UInt64) AFTER stale;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS started_at Nullable(DateTime64(3)) AFTER duration_ms;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS first_token_ms Nullable(UInt64) AFTER started_at;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS attempts UInt8 DEFAULT 1 AFTER first_token_ms;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS response_kind Nullable(String) AFTER attempts;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS error_type String DEFAULT 'none' AFTER response_kind;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS http_status Nullable(UInt16) AFTER error_type;

ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS app_revision Nullable(String) AFTER http_status;

CREATE TABLE IF NOT EXISTS {{database}}.tool_call_events (
  dedup String,
  source String,
  source_key String,
  version UInt64,
  event_date Date,
  metered_at String,
  created_at String,
  entrypoint String,
  surface String,
  tenant_id String,
  group_id String,
  actor_type String,
  resource_kind String,
  charge_status String,
  tool_name String,
  tool_source String,
  status String,
  error_type Nullable(String),
  guidance_reason Nullable(String),
  duration_ms UInt64,
  started_at DateTime64(3),
  args_fingerprint Nullable(String),
  result_fingerprint Nullable(String),
  call_index Nullable(UInt64),
  async Bool,
  trace_id Nullable(String),
  request_id Nullable(String),
  salix_agent_id Nullable(String),
  session_id Nullable(String),
  round_id Nullable(String),
  app_revision Nullable(String)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (source, source_key);

CREATE TABLE IF NOT EXISTS {{database}}.agent_run_events (
  dedup String,
  source String,
  source_key String,
  version UInt64,
  event_date Date,
  metered_at String,
  created_at String,
  entrypoint String,
  surface String,
  tenant_id String,
  group_id String,
  actor_type String,
  resource_kind String,
  charge_status String,
  status String,
  duration_ms UInt64,
  started_at DateTime64(3),
  trace_id Nullable(String),
  request_id Nullable(String),
  salix_agent_id Nullable(String),
  session_id Nullable(String),
  round_id Nullable(String),
  app_revision Nullable(String),
  task_origin Nullable(String),
  platform Nullable(String),
  source_schedule_id Nullable(String)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (source, source_key);
