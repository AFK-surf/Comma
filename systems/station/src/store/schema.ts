// The store's schema (the Rust station's store.rs `// ── schema`): the tables as CREATE … IF NOT EXISTS, and the columns that
// came after schema version 12 without changing it, added in place on open (add_*_columns), the same way and in the
// same order as the Rust station does, so either station opens what the other kept.
import type { DatabaseSync } from "node:sqlite";

/// Bump on schema changes. A database of another version is refused: there is one station, and its data is moved by
/// hand when the schema changes (no migrations are kept in the code).
export const SCHEMA_VERSION = 12;

export const SCHEMA = `
CREATE TABLE IF NOT EXISTS archive_suggestions (
  thread INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS archive_policy (
  id INTEGER PRIMARY KEY,
  at INTEGER NOT NULL,
  policy TEXT NOT NULL,
  author TEXT NOT NULL,
  summary TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS archive_verdicts (
  thread INTEGER PRIMARY KEY,
  version INTEGER NOT NULL,
  at INTEGER NOT NULL,
  verdict TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS decision_checks (
  id INTEGER PRIMARY KEY,
  session TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  result TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  key TEXT PRIMARY KEY,
  connect TEXT NOT NULL,
  scope TEXT NOT NULL,
  title TEXT,
  created_by TEXT,
  runtime TEXT NOT NULL,
  profile TEXT NOT NULL,
  profile_pinned INTEGER NOT NULL DEFAULT 0,
  model TEXT,
  effort TEXT,
  fast INTEGER,
  runtime_session_id TEXT,
  workspace TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE,
  running INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  last_active_at INTEGER NOT NULL,
  archived_at INTEGER,
  archived_by TEXT,
  shown_at INTEGER,
  cwd TEXT
);
CREATE TABLE IF NOT EXISTS threads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  surface TEXT NOT NULL,
  channel TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  title TEXT,
  created_by TEXT,
  created_at INTEGER NOT NULL,
  archived_at INTEGER,
  home TEXT,
  hidden_at INTEGER,
  hidden_by TEXT,
  shown_at INTEGER,
  auto_title TEXT,
  auto_title_n INTEGER,
  auto_title_changes INTEGER NOT NULL DEFAULT 0,
  UNIQUE (surface, channel, thread_ts)
);
CREATE TABLE IF NOT EXISTS thread_sessions (
  thread INTEGER NOT NULL,
  session TEXT NOT NULL,
  connect TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (thread, session)
);
CREATE INDEX IF NOT EXISTS thread_sessions_session ON thread_sessions (session);
CREATE TABLE IF NOT EXISTS entries (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  kind TEXT NOT NULL,
  target INTEGER,
  ts TEXT,
  author_kind TEXT NOT NULL,
  author TEXT NOT NULL,
  text TEXT,
  attachments TEXT,
  quotes TEXT,
  declared TEXT,
  at INTEGER NOT NULL,
  client TEXT,
  profile TEXT,
  options TEXT,
  card TEXT,
  PRIMARY KEY (thread, n)
);
CREATE UNIQUE INDEX IF NOT EXISTS entries_ts ON entries (thread, ts) WHERE ts IS NOT NULL;
CREATE INDEX IF NOT EXISTS entries_target ON entries (thread, target) WHERE target IS NOT NULL;
CREATE TABLE IF NOT EXISTS deliveries (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  session TEXT NOT NULL,
  delivered_at INTEGER,
  PRIMARY KEY (thread, n, session)
);
CREATE INDEX IF NOT EXISTS deliveries_pending ON deliveries (session) WHERE delivered_at IS NULL;
CREATE INDEX IF NOT EXISTS deliveries_session ON deliveries (session, thread);
CREATE TABLE IF NOT EXISTS reads (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread)
);
CREATE TABLE IF NOT EXISTS profile_status (
  profile TEXT PRIMARY KEY,
  check_json TEXT, checked_at INTEGER,
  quota_json TEXT, quota_at INTEGER
);
CREATE TABLE IF NOT EXISTS bindings (
  connect TEXT PRIMARY KEY,
  session_key TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS turns (
  id TEXT PRIMARY KEY,
  session_key TEXT NOT NULL,
  kind TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  outcome TEXT,
  detail TEXT,
  declared TEXT,
  wait_seconds INTEGER,
  wait_for TEXT,
  need TEXT,
  about_thread INTEGER,
  about_n INTEGER,
  about_ts TEXT
);
CREATE TABLE IF NOT EXISTS processes (
  pgid INTEGER PRIMARY KEY,
  started_at INTEGER NOT NULL,
  runtime TEXT NOT NULL,
  label TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  session_key TEXT NOT NULL,
  name TEXT NOT NULL,
  command TEXT NOT NULL,
  cwd TEXT NOT NULL,
  port INTEGER,
  token TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL,
  pgid INTEGER,
  exit_code INTEGER,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  restarts INTEGER NOT NULL DEFAULT 0,
  log TEXT NOT NULL,
  watch INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS jobs_by_session ON jobs (session_key);
CREATE TABLE IF NOT EXISTS job_notices (
  job_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  text TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS job_notices_by_job ON job_notices (job_id, at);
CREATE TABLE IF NOT EXISTS identities (
  viewer TEXT NOT NULL,
  slack_user TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, slack_user)
);
-- Came after schema version 12 without changing it: made in place on open, like add_archive_columns' columns.
-- The chats a viewer keeps at the top of their list, by their item's id (its session's key), and since when.
CREATE TABLE IF NOT EXISTS pins (
  viewer TEXT NOT NULL,
  session TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, session)
);
CREATE TABLE IF NOT EXISTS widget_states (
  session TEXT NOT NULL,
  path TEXT NOT NULL,
  state TEXT NOT NULL,
  model TEXT,
  updated_at INTEGER NOT NULL,
  told_at INTEGER,
  PRIMARY KEY (session, path)
);
-- The pieces of work in a chat, as its agents declare them (chat_post items): each waiting on someone or not.
CREATE TABLE IF NOT EXISTS items (
  thread INTEGER NOT NULL,
  key TEXT NOT NULL,
  session TEXT NOT NULL,
  title TEXT NOT NULL,
  state TEXT NOT NULL,
  waiting_on TEXT,
  ask TEXT,
  detail TEXT,
  evidence INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (thread, key)
);
-- Pending decisions (an agent's block post with options) a viewer said they will not take up: not on their list
-- any more, still pending for everyone else. By the post's thread and entry number.
CREATE TABLE IF NOT EXISTS dismissed (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread, n)
);
-- A viewer keeps a chat instead of receiving archive reminders.
CREATE TABLE IF NOT EXISTS kept_chats (
  viewer TEXT NOT NULL,
  thread INTEGER NOT NULL,
  PRIMARY KEY (viewer, thread)
);
-- A card closed by its viewer or withdrawn by its author.
CREATE TABLE IF NOT EXISTS closed_cards (
  thread INTEGER NOT NULL,
  n INTEGER NOT NULL,
  viewer TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (thread, n)
);
-- What the agents spent (store/usage.rs): one row per model call their runtimes recorded, read from the transcripts,
-- with whom and what it was for as it was then. Kept when its session goes: it was spent all the same.
CREATE TABLE IF NOT EXISTS usage (
  id TEXT PRIMARY KEY,
  at INTEGER NOT NULL,
  session TEXT NOT NULL,
  turn TEXT,
  thread INTEGER,
  person TEXT,
  profile TEXT,
  runtime TEXT NOT NULL,
  model TEXT,
  subagent INTEGER NOT NULL DEFAULT 0,
  fast INTEGER NOT NULL DEFAULT 0,
  input INTEGER NOT NULL,
  cache_read INTEGER NOT NULL,
  cache_write INTEGER NOT NULL,
  cache_write_long INTEGER NOT NULL,
  output INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS usage_at ON usage (at);
-- The runtime sessions a session has run in, the first first, each with the profile it last ran on. The latest is
-- sessions.runtime_session_id; one before it was left for a new one (its account changed), and its history goes on
-- from theirs.
CREATE TABLE IF NOT EXISTS runtime_sessions (
  session_key TEXT NOT NULL,
  id TEXT NOT NULL,
  profile TEXT,
  at INTEGER NOT NULL,
  PRIMARY KEY (session_key, id)
);
-- How far each transcript has been read for it.
CREATE TABLE IF NOT EXISTS usage_files (
  path TEXT PRIMARY KEY,
  session TEXT,
  offset INTEGER NOT NULL,
  model TEXT
);
-- Tasks (src/tasks/tasks.ts). A Task here: the Sessions of other Stations taking part in it, with the entry through which
-- each was given the Task (sent) and what it was invited with (start, JSON: a Station that lost the Task is invited
-- again with it), and what each posted by its key (a post asked again is one Message). answered: through which Message
-- that Station's Sessions answered the Task already (what sent was when one of them last ended a turn), told to it
-- with all it is given; NULL from before it was kept, until the Task is read for it.
CREATE TABLE IF NOT EXISTS task_sessions (
  thread INTEGER NOT NULL,
  station TEXT NOT NULL,
  session TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  sent INTEGER NOT NULL DEFAULT 0,
  start TEXT,
  answered INTEGER,
  PRIMARY KEY (thread, station, session)
);
CREATE TABLE IF NOT EXISTS task_posts (
  thread INTEGER NOT NULL,
  station TEXT NOT NULL,
  session TEXT NOT NULL,
  key TEXT NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (thread, station, session, key)
);
-- A Task on another Station that Sessions here take part in: its thread here, and the entry through which the host gave it
-- for them (what people have read is kept where the Task is, per person). answered: the seq its host says the
-- Sessions of this Station answered the Task through (the most it said, with an invite or a put); what is given
-- through it is what was said before, handed to no Session.
CREATE TABLE IF NOT EXISTS tasks_elsewhere (
  thread INTEGER PRIMARY KEY,
  station TEXT NOT NULL,
  task TEXT NOT NULL,
  fetched INTEGER NOT NULL DEFAULT 0,
  answered INTEGER NOT NULL DEFAULT 0,
  UNIQUE (station, task)
);
-- The station's own facts by name: task_index_epoch (made once, on the first open that has the Task index) and
-- task_index_rev (the Task index's last rev).
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- The Task index: one row per chat on the station's page (a Task), what Salix lists of it (no message text), as of
-- rev. Every change to a row takes the next rev of the whole index; a Task deleted leaves a tombstone (removed = 1)
-- until it was told. marked: done or cancelled, as a person marked the Task (kept here, not on its thread's row: the
-- threads table stays the Rust station's).
CREATE TABLE IF NOT EXISTS task_index (
  thread INTEGER PRIMARY KEY,
  rev INTEGER NOT NULL,
  json TEXT NOT NULL,
  removed INTEGER NOT NULL DEFAULT 0,
  marked TEXT
);
CREATE INDEX IF NOT EXISTS task_index_rev ON task_index (rev);
`;

/// Each message as it reads now: its latest edit's words, files and quotes.
export const MERGED = `CREATE VIEW merged AS
  SELECT m.thread, m.n, m.ts, m.author_kind, m.author,
    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
    m.declared, m.client, m.agent_identity, m.at AS created_at, e.at AS edited_at
  FROM entries m
  LEFT JOIN entries e ON e.thread = m.thread
    AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)
  WHERE m.kind = 'message';`;

const has = (db: DatabaseSync, table: string, column: string): boolean =>
  db.prepare(`SELECT 1 FROM pragma_table_info('${table}') WHERE name = ?`).get(column) !== undefined;

/// add_archive_columns: columns archiving came with, added to a database made before them. When they come, each
/// session's first chat on the page is taken as its own, and chats of sessions archived then as archived with them.
export function addArchiveColumns(db: DatabaseSync): void {
  for (const [column, kind] of [["archived_by", "TEXT"], ["shown_at", "INTEGER"], ["cwd", "TEXT"], ["fast", "INTEGER"]]) {
    if (!has(db, "sessions", column!)) db.exec(`ALTER TABLE sessions ADD COLUMN ${column} ${kind}`);
  }
  // Came with waiting's limit, after the turns table.
  if (!has(db, "turns", "wait_seconds")) db.exec("ALTER TABLE turns ADD COLUMN wait_seconds INTEGER");
  // Came with saying what a wait is for (chat_state waiting `for`).
  if (!has(db, "turns", "wait_for")) db.exec("ALTER TABLE turns ADD COLUMN wait_for TEXT");
  // Came with migration notes: the last one each session was told. A session from before them was told none.
  if (!has(db, "sessions", "told_notes")) db.exec("ALTER TABLE sessions ADD COLUMN told_notes INTEGER");
  // Came with need_help's `need`: what a person has to give or do.
  if (!has(db, "turns", "need")) db.exec("ALTER TABLE turns ADD COLUMN need TEXT");
  // Came with `about`: the message a turn's state is about.
  for (const [column, kind] of [["about_thread", "INTEGER"], ["about_n", "INTEGER"], ["about_ts", "TEXT"]]) {
    if (!has(db, "turns", column!)) db.exec(`ALTER TABLE turns ADD COLUMN ${column} ${kind}`);
  }
  // Came with usage (store/usage.ts): whom a turn worked for, where, and on which profile.
  for (const [column, kind] of [["profile", "TEXT"], ["person", "TEXT"], ["thread", "INTEGER"]]) {
    if (!has(db, "turns", column!)) db.exec(`ALTER TABLE turns ADD COLUMN ${column} ${kind}`);
  }
  if (has(db, "threads", "home")) return;
  db.exec(
    `BEGIN;
     ALTER TABLE threads ADD COLUMN home TEXT;
     ALTER TABLE threads ADD COLUMN hidden_at INTEGER;
     ALTER TABLE threads ADD COLUMN hidden_by TEXT;
     ALTER TABLE threads ADD COLUMN shown_at INTEGER;
     UPDATE threads SET home = (SELECT ts.session FROM thread_sessions ts WHERE ts.thread = threads.id ORDER BY ts.joined_at, ts.rowid LIMIT 1)
     WHERE surface = 'ember' AND id = (
       SELECT MIN(t2.id) FROM threads t2 JOIN thread_sessions ts2 ON ts2.thread = t2.id
       WHERE t2.surface = 'ember' AND ts2.session = (SELECT ts.session FROM thread_sessions ts WHERE ts.thread = threads.id ORDER BY ts.joined_at, ts.rowid LIMIT 1));
     UPDATE sessions SET archived_by = 'manual' WHERE archived_at IS NOT NULL AND archived_by IS NULL;
     UPDATE threads SET hidden_at = (SELECT archived_at FROM sessions WHERE key = threads.home), hidden_by = 'manual'
     WHERE home IN (SELECT key FROM sessions WHERE archived_at IS NOT NULL);
     COMMIT;`,
  );
}

/// add_client_column: the column a message's app came with (entries.client) and those after it, and the `merged` view
/// made anew with them.
export function addClientColumn(db: DatabaseSync): void {
  if (!has(db, "entries", "agent_identity")) db.exec("ALTER TABLE entries ADD COLUMN agent_identity TEXT");
  if (!has(db, "entries", "client")) db.exec("ALTER TABLE entries ADD COLUMN client TEXT");
  // The profile a notice is about; the `merged` view has no need of it.
  if (!has(db, "entries", "profile")) db.exec("ALTER TABLE entries ADD COLUMN profile TEXT");
  // A block post's answers to pick from; the `merged` view has no need of them.
  if (!has(db, "entries", "options")) db.exec("ALTER TABLE entries ADD COLUMN options TEXT");
  // A message's card; an options card is kept in `options` too, which stations from before cards read.
  if (!has(db, "entries", "card")) db.exec("ALTER TABLE entries ADD COLUMN card TEXT");
  // A chat's latest card is looked for on every list of chats: only its posts with one are read.
  db.exec("CREATE INDEX IF NOT EXISTS entries_options ON entries (thread, n) WHERE options IS NOT NULL");
  db.exec("CREATE INDEX IF NOT EXISTS entries_cards ON entries (thread, n) WHERE card IS NOT NULL");
  // What people said lately is looked for on every list of chats (the cards they answered: `answersSince`).
  db.exec("CREATE INDEX IF NOT EXISTS entries_people_at ON entries (at) WHERE author_kind = 'person' AND kind = 'message'");
  // A prior upgrade may have added the table column without rebuilding this view.
  if (!has(db, "merged", "client") || !has(db, "merged", "agent_identity")) db.exec(`BEGIN; DROP VIEW IF EXISTS merged; ${MERGED} COMMIT;`);
}

/// add_auto_title_columns: the columns a chat's own name from its agent came with (threads.auto_title…).
export function addAutoTitleColumns(db: DatabaseSync): void {
  for (const [column, kind] of [["auto_title", "TEXT"], ["auto_title_n", "INTEGER"], ["auto_title_changes", "INTEGER NOT NULL DEFAULT 0"]]) {
    if (!has(db, "threads", column!)) db.exec(`ALTER TABLE threads ADD COLUMN ${column} ${kind}`);
  }
}

/// add_task_sent_column: the column Tasks given to other Stations came with (task_sessions.sent). Those taking part
/// before it are given the Task again from its start; what they had is not written twice.
export function addTaskSentColumn(db: DatabaseSync): void {
  if (!has(db, "task_sessions", "sent")) db.exec("ALTER TABLE task_sessions ADD COLUMN sent INTEGER NOT NULL DEFAULT 0");
}

/// add_task_start_column: the column inviting again came with (task_sessions.start). For those invited before it, an
/// invite asked again is made from the Task's chat (its creator and title).
export function addTaskStartColumn(db: DatabaseSync): void {
  if (!has(db, "task_sessions", "start")) db.exec("ALTER TABLE task_sessions ADD COLUMN start TEXT");
}

/// add_task_answered_column: the columns `answered` came with. tasks_elsewhere.answered: Tasks from before it were told
/// none, 0, all that is given is handed over. task_sessions.answered: NULL for those taking part from before it, read
/// from the Task once.
export function addTaskAnsweredColumn(db: DatabaseSync): void {
  if (!has(db, "tasks_elsewhere", "answered")) db.exec("ALTER TABLE tasks_elsewhere ADD COLUMN answered INTEGER NOT NULL DEFAULT 0");
  if (!has(db, "task_sessions", "answered")) db.exec("ALTER TABLE task_sessions ADD COLUMN answered INTEGER");
}

/// add_watch_column: the column watching jobs came with (jobs.watch).
export function addWatchColumn(db: DatabaseSync): void {
  if (!has(db, "jobs", "watch")) db.exec("ALTER TABLE jobs ADD COLUMN watch INTEGER NOT NULL DEFAULT 0");
}

/// add_task_labels_column: the column a Task's labels came with (task_index.labels, a JSON array of the Group's label
/// ids). Tasks from before it have none.
export function addTaskLabelsColumn(db: DatabaseSync): void {
  if (!has(db, "task_index", "labels")) db.exec("ALTER TABLE task_index ADD COLUMN labels TEXT");
}
