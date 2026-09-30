ALTER TABLE {{database}}.slack_messages
ADD COLUMN IF NOT EXISTS actor_label String AFTER actor_id
;
