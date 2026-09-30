CREATE TABLE IF NOT EXISTS {{database}}.agent_session_history
(
    agent_id String,
    session_id String,
    seq UInt64,
    part UInt32,
    text String,
    kind LowCardinality(String),
    tool_name String,
    label String,
    INDEX history_text text TYPE ngrambf_v1(2, 32768, 3, 0) GRANULARITY 1
)
ENGINE = ReplacingMergeTree
PARTITION BY cityHash64(agent_id, session_id) % 16
ORDER BY (agent_id, session_id, seq, part);
