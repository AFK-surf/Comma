-- Slack message mirror: canonical payload plus searchable projections.
-- Design: docs/salix/slack-message-mirror.md
--
-- `payload` is the stable Slack message object. Searchable `body_text` and
-- retained `blocks` are derived from it. Rows written before these columns
-- existed are not restated here: a re-walk writes the same `version`, and
-- ClickHouse keeps the later insert.
ALTER TABLE {{database}}.slack_messages
  ADD COLUMN IF NOT EXISTS body_text String DEFAULT '',
  ADD COLUMN IF NOT EXISTS blocks String DEFAULT '',
  ADD COLUMN IF NOT EXISTS payload String DEFAULT ''
;

ALTER TABLE {{database}}.slack_messages
  ADD INDEX IF NOT EXISTS idx_body_text body_text TYPE ngrambf_v1(4, 32768, 3, 0) GRANULARITY 4
;

ALTER TABLE {{database}}.slack_messages
  MATERIALIZE INDEX idx_body_text SETTINGS mutations_sync = 1
;
