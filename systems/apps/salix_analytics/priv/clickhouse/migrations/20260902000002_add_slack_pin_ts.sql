-- Slack pin overlay needs the pin's own timestamp. `pinned_info.pinned_ts`
-- is when the pin was created; `message_ts` is when the message was posted.
-- Design: docs/salix/slack-message-mirror.md
--
-- Expand-only: old writers omit the column and ClickHouse stores ''. A reader
-- then falls back to the pin row's version, which is already derived from
-- `event_ts`.
ALTER TABLE {{database}}.slack_message_pins
  ADD COLUMN IF NOT EXISTS pinned_ts String DEFAULT ''
;
