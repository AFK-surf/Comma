ALTER TABLE {{database}}.trajectory_eval_events
  ADD COLUMN IF NOT EXISTS verdict String DEFAULT '',
  ADD COLUMN IF NOT EXISTS reason String DEFAULT '';
