#!/usr/bin/env bash
# Build the Go-side Willow-to-Salix migration exporter and optionally create a
# fixture agent DB for testing it. The operator workflow is documented in
# docs/product-features.md.
#
# Usage:
#   scripts/build_exporter.sh [OUTPUT]            # build → OUTPUT (default /tmp/willow-salix-export)
#   scripts/build_exporter.sh --fixture DB_PATH   # write a fixture agent DB (sqlite3 CLI)
#
# Build mode expects the matching legacy Willow Go source at
# cmd/willow-salix-export under the checkout root. Comma does not vendor that
# source, so operators must stage this script at systems/scripts/build_exporter.sh
# in the matching Willow checkout before running it. The exporter builds with
# -tags "libsqlite3".
#
# The fixture uses the REAL agent-DB schema for the three exported tables
# (sessions / messages / tool_calls), copied from internal/agent/db.go; the
# migration-added messages columns (metadata, compacted_through, tool_name) are
# applied as ALTERs, mirroring internal/agent/db_migrations.go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

build() {
  local out="${1:-/tmp/willow-salix-export}"
  if ! command -v go >/dev/null 2>&1; then
    echo "build_exporter.sh: go toolchain not found" >&2
    exit 3
  fi
  (cd "$REPO_ROOT" && go build -tags "libsqlite3" -o "$out" ./cmd/willow-salix-export)
  echo "$out"
}

fixture() {
  local db="$1"
  rm -f "$db"
  sqlite3 "$db" <<'SQL'
-- Real agent-DB schema (internal/agent/db.go) for the three exported tables.
CREATE TABLE IF NOT EXISTS messages (
    message_id    INTEGER PRIMARY KEY AUTOINCREMENT,
    role          TEXT NOT NULL,
    content       TEXT NOT NULL,
    tool_call_id   TEXT,
    source_message_id TEXT,
    session_id    TEXT,
    model         TEXT,
    input_tokens  INTEGER,
    output_tokens INTEGER,
    cache_read_input_tokens INTEGER,
    cache_write_input_tokens INTEGER,
    turn_id       TEXT NOT NULL DEFAULT '',
    round_id      TEXT NOT NULL DEFAULT '',
    request_id    TEXT NOT NULL DEFAULT '',
    trace_id      TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL
);
-- migration-added columns (internal/agent/db_migrations.go)
ALTER TABLE messages ADD COLUMN metadata TEXT;
ALTER TABLE messages ADD COLUMN compacted_through INTEGER;
ALTER TABLE messages ADD COLUMN tool_name TEXT;

CREATE TABLE IF NOT EXISTS tool_calls (
    call_id       TEXT NOT NULL,
    message_id    INTEGER NOT NULL REFERENCES messages(message_id),
    tool_name     TEXT NOT NULL,
    input         TEXT NOT NULL,
    output        TEXT,
    status        TEXT NOT NULL DEFAULT 'pending',
    session_id    TEXT NOT NULL,
    duration_ms   INTEGER,
    turn_id       TEXT NOT NULL DEFAULT '',
    round_id      TEXT NOT NULL DEFAULT '',
    request_id    TEXT NOT NULL DEFAULT '',
    trace_id      TEXT NOT NULL DEFAULT '',
    started_at    INTEGER NOT NULL DEFAULT 0,
    completed_at  INTEGER NOT NULL DEFAULT 0,
    error_class   TEXT NOT NULL DEFAULT '',
    error_message TEXT NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (session_id, call_id)
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id               TEXT PRIMARY KEY,
    agent_id                 TEXT NOT NULL,
    name                     TEXT NOT NULL DEFAULT '',
    hidden                   INTEGER NOT NULL DEFAULT 0,
    deleted_at               INTEGER,
    parent_session_id        TEXT REFERENCES sessions(session_id),
    fork_message_id          INTEGER,
    purpose                  TEXT NOT NULL DEFAULT '',
    source_session_id        TEXT REFERENCES sessions(session_id) ON DELETE SET NULL,
    source_schedule_id       TEXT,
    outbound_target_json     TEXT,
    status                   TEXT NOT NULL DEFAULT 'idle',
    compact_requested        INTEGER NOT NULL DEFAULT 0,
    microcompact_requested   INTEGER NOT NULL DEFAULT 0,
    created_at               INTEGER NOT NULL,
    last_activity_at         INTEGER,
    activity_status          TEXT,
    last_round_error         TEXT,
    consecutive_failures     INTEGER NOT NULL DEFAULT 0,
    last_failed_at           INTEGER,
    -- Legacy Willow source column. Salix import/export ignores it because wake
    -- is an actor/scheduler signal, not internal session durable state.
    wake_sequence            INTEGER NOT NULL DEFAULT 0,
    pending_template_id      TEXT,
    pending_reasoning_effort TEXT,
    last_ack_message_id      INTEGER NOT NULL DEFAULT 0,
    summary_sequence         INTEGER NOT NULL DEFAULT 0
);

-- Fixture data: 2 live sessions, one assistant turn with a tool call + its
-- tool result, a compaction-summary row, and a deleted session whose message
-- must NOT be exported.
INSERT INTO sessions (session_id, agent_id, status, created_at, wake_sequence, last_ack_message_id, summary_sequence)
VALUES ('s-main', 'agent-fixture', 'idle', 1000, 3, 5, 1);
INSERT INTO sessions (session_id, agent_id, status, created_at, wake_sequence, last_ack_message_id, summary_sequence)
VALUES ('s-side', 'agent-fixture', 'queued', 1001, 1, 0, 0);
INSERT INTO sessions (session_id, agent_id, status, created_at, deleted_at)
VALUES ('s-gone', 'agent-fixture', 'idle', 1002, 2000);

INSERT INTO messages (role, content, source_message_id, session_id, created_at)
VALUES ('user', 'hello', 'src-1', 's-main', 1100);                                    -- id 1
INSERT INTO messages (role, content, session_id, created_at)
VALUES ('assistant', 'let me check that file', 's-main', 1101);                       -- id 2
INSERT INTO messages (role, content, tool_call_id, session_id, created_at)
VALUES ('tool', '{"ok":true,"bytes":5}', 'call-1', 's-main', 1102);                   -- id 3
INSERT INTO messages (role, content, session_id, created_at)
VALUES ('assistant', 'done — the file says hi', 's-main', 1103);                      -- id 4
INSERT INTO messages (role, content, source_message_id, session_id, created_at)
VALUES ('user', 'ping', 'src-2', 's-side', 1104);                                     -- id 5
-- compaction summary row (a user row with compacted_through set; folded into
-- the session record by the exporter, not re-exported as a message)
INSERT INTO messages (role, content, session_id, compacted_through, created_at)
VALUES ('user', 'summary: greeted and read /notes.txt', 's-main', 4, 1105);           -- id 6
-- message of a deleted session (skipped, but still counts for next_message_id)
INSERT INTO messages (role, content, session_id, created_at)
VALUES ('user', 'orphaned', 's-gone', 1106);                                          -- id 7

INSERT INTO tool_calls (call_id, message_id, tool_name, input, output, status, session_id, created_at)
VALUES ('call-1', 2, 'vfs_read', '{"path":"/notes.txt"}', '{"ok":true,"bytes":5}', 'completed', 's-main', 1101);

-- Control-DB agents table (base schema internal/control/db.go; the
-- role/name/system_prompt/router_system_prompt/template_id/provider/... columns
-- are migration-added there and folded in here) so this same fixture file can
-- be passed to the exporter as -control-db. The exporter derives the agent_id
-- ('agent-fixture') from sessions.agent_id above when -agent-id is omitted.
CREATE TABLE IF NOT EXISTS agents (
    agent_id      TEXT PRIMARY KEY,
    tenant_id     TEXT NOT NULL,
    def_id        TEXT NOT NULL,
    group_id      TEXT,
    role          TEXT NOT NULL DEFAULT 'worker',
    name          TEXT NOT NULL DEFAULT '',
    system_prompt TEXT NOT NULL DEFAULT '',
    router_system_prompt TEXT NOT NULL DEFAULT '',
    template_id   TEXT NOT NULL DEFAULT '',
    provider      TEXT NOT NULL DEFAULT '',
    source_initial_agent_slot     TEXT NOT NULL DEFAULT '',
    source_initial_agent_revision INTEGER NOT NULL DEFAULT 0,
    archived_at   INTEGER,
    db_namespace  TEXT NOT NULL UNIQUE,
    db_secret     TEXT,
    forked_from   TEXT,
    status        TEXT NOT NULL DEFAULT 'created',
    hidden        INTEGER NOT NULL DEFAULT 0,
    purpose       TEXT NOT NULL DEFAULT '',
    backfill_epoch INTEGER NOT NULL DEFAULT 0,
    node_id       TEXT,
    lock_token    TEXT,
    lock_expires  INTEGER,
    created_at    INTEGER NOT NULL,
    started_at    INTEGER,
    completed_at  INTEGER,
    error         TEXT,
    tool_router_enabled INTEGER NOT NULL DEFAULT 1
);

INSERT INTO agents (agent_id, tenant_id, def_id, role, name, system_prompt, router_system_prompt, db_namespace, status, created_at)
VALUES ('agent-fixture', 'tenant-fixture', 'def-fixture', 'router', 'fixture router',
        'You are a helpful assistant.', 'You are the router for this agent group.',
        'agent_agent-fixture', 'created', 1000);
SQL
  echo "$db"
}

case "${1:-}" in
  --fixture)
    [ -n "${2:-}" ] || { echo "usage: build_exporter.sh --fixture DB_PATH" >&2; exit 2; }
    fixture "$2"
    ;;
  *)
    build "${1:-}"
    ;;
esac
