-- What a killed attempt had received before the deadline.
--
-- A model call the session actor kills at its job deadline never returns to
-- the retry loop, so until now it wrote no llm_attempt_events row at all. The
-- actor now writes that attempt with outcome `killed` and the progress of its
-- response stream (SalixAgent.StreamProgress), which is what tells a provider
-- still writing an answer from one heartbeating over an empty stream.
-- Milliseconds are measured from the attempt's start. NULL means the value was
-- not observed: no response body ever arrived, or the call did not stream
-- through SalixLlm.Http. Rows of the other outcomes leave these NULL.
ALTER TABLE {{database}}.llm_attempt_events
  ADD COLUMN IF NOT EXISTS first_body_ms Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS last_body_ms Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS received_bytes Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS received_chunks Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS first_content_ms Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS last_content_ms Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS content_deltas Nullable(UInt64);
