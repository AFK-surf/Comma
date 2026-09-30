CREATE TABLE IF NOT EXISTS {{database}}.billing_source_events (
  dedup String,
  source String,
  source_key String,
  version UInt64,
  event_date Date,
  occurred_at String,
  created_at String,
  surface String,
  billing_account_id String,
  product_owner_type String,
  product_owner_id String,
  event_kind String,
  source_type String,
  source_id String,
  source_event_id Nullable(String),
  idempotency_key Nullable(String),
  package_code Nullable(String),
  package_version Nullable(String),
  credit_grant_id Nullable(String),
  status String,
  reason Nullable(String),
  provider Nullable(String),
  provider_event_id Nullable(String),
  metadata_json String,
  trace_id Nullable(String),
  log_correlation_id Nullable(String)
) ENGINE = ReplacingMergeTree(version)
ORDER BY (source, source_key);

ALTER TABLE {{database}}.fee_control_checks
  ADD COLUMN IF NOT EXISTS action Nullable(String) AFTER mode;

ALTER TABLE {{database}}.fee_control_checks
  ADD COLUMN IF NOT EXISTS target_resource_kind Nullable(String) AFTER action;

ALTER TABLE {{database}}.fee_control_checks
  ADD COLUMN IF NOT EXISTS allowed Bool AFTER target_resource_kind;

ALTER TABLE {{database}}.fee_control_checks
  ADD COLUMN IF NOT EXISTS reason Nullable(String) AFTER allowed;

ALTER TABLE {{database}}.fee_control_checks
  ADD COLUMN IF NOT EXISTS decision_id Nullable(String) AFTER reason;
