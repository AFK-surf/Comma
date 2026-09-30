-- Preserve old counters for billing. NULL means that the observation is unavailable.
ALTER TABLE {{database}}.llm_call_events
  ADD COLUMN IF NOT EXISTS usage_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS prompt_tokens_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS completion_tokens_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS cache_read_tokens_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS reasoning_tokens Nullable(UInt64);

ALTER TABLE {{database}}.llm_call_events_v2
  ADD COLUMN IF NOT EXISTS usage_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS prompt_tokens_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS completion_tokens_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS cache_read_tokens_reported Nullable(Bool),
  ADD COLUMN IF NOT EXISTS reasoning_tokens Nullable(UInt64);
