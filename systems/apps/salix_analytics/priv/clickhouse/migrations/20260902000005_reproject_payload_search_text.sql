-- Side-table rows written before text/body_text existed keep empty defaults
-- after 20260902000003. Exhausted channels are not re-walked, so search
-- cannot wait for a later write. Fill `text` from the canonical payload;
-- the reader also matches JSONExtract of payload/blocks so block-only
-- rows remain candidates without a BlockText walk in SQL.
-- Retry-safe IF NOT EXISTS equivalent: WHERE text = '' skips filled rows.
-- Design: docs/salix/slack-message-mirror.md

ALTER TABLE {{database}}.slack_message_payloads
  UPDATE text = JSONExtractString(payload, 'text')
  WHERE text = ''
    AND payload != ''
    AND JSONExtractString(payload, 'text') != ''
  SETTINGS mutations_sync = 1
;
