-- Search must not depend on slack_messages.text/body_text: an old writer can
-- land last at equal version and leave those projections empty after OPTIMIZE.
-- Copy the same projections onto slack_message_payloads, which old writers
-- cannot insert into. Design: docs/salix/slack-message-mirror.md
--
-- Expand-only: omitted columns default to ''. The reader matches either table.
ALTER TABLE {{database}}.slack_message_payloads
  ADD COLUMN IF NOT EXISTS text String DEFAULT '',
  ADD COLUMN IF NOT EXISTS body_text String DEFAULT ''
;

ALTER TABLE {{database}}.slack_message_payloads
  ADD INDEX IF NOT EXISTS idx_payload_text text TYPE ngrambf_v1(4, 32768, 3, 0) GRANULARITY 4
;

ALTER TABLE {{database}}.slack_message_payloads
  ADD INDEX IF NOT EXISTS idx_payload_body_text body_text TYPE ngrambf_v1(4, 32768, 3, 0) GRANULARITY 4
;
