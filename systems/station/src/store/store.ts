import { latest as latestNote } from "../agents/migrations.ts";
// All durable station state, in one SQLite file (the Rust station's store.rs ported: the same file, schema, SQL and rules, so
// the Rust station and this one open each other's data). One read-write connection, used synchronously; every method is
// the Rust `Store` method of the same name in camelCase, with its parameters in the same order.
//
// A thread is a log of entries that are appended and never changed: an edit is an entry of its own, which readers merge
// into the message it changes. A thread whose sessions are all archived is written out to a zstd file and read from
// there (store/archive.ts).
//
// What changed is told to subscribers once the method's writes are done (Store::with): the same StoreChange values at
// the same points as the Rust, in the same order.
import type { Clock } from "effect";
import { randomBytes } from "node:crypto";
import { mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { DatabaseSync, type SQLInputValue, type StatementSync } from "node:sqlite";
import { liveClock } from "../ops/fibers.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { archiveText, readArchive, threadFile, writeCompressed } from "./archive.ts";
import {
  type Attachment, type AutoTitle, type CardAnswer, type EntryRow, type JobNotice, type JobRow, type Json, type Membership,
  type MessageRow, type NewMessage, type NewSession, type PendingMessage, type ProcessRow, type ProfileStatus,
  type Quote, type RanIn, type SessionRow, type SessionStats, type SessionThread, type StoreChange, type TaskIndexRow, type TaskMark,
  type TaskStatus, type ThreadRow, type ThreadSummary,
  type TurnFor, type TurnRow, type TurnSummary, type WidgetModel, AUTO, I64_MAX, MANUAL, STILLFAIL_SURFACE, attachment,
  byBytes, cardOf, jsonList, mergeEntries, onlyMilestones, optionsCard, parsed, quote, takeChars, toEntry, toJob, toMembership,
  toMessage, toSession, toSessionThread, toThread, toTurnSummary,
} from "./rows.ts";
import { SCHEMA, SCHEMA_VERSION, addArchiveColumns, addAutoTitleColumns, addClientColumn, addMilestonesColumn, addRuntimeSessionRuntimeColumn, addTaskAnsweredColumn, addTaskLabelsColumn, addTaskSentColumn, addTaskStartColumn, addWatchColumn } from "./schema.ts";
import * as usage from "./usage.ts";

export * from "./rows.ts";
export { SCHEMA_VERSION } from "./schema.ts";
export { writeCompressed } from "./archive.ts";
export type { UsageCall, UsageFile, UsageFor, UsageGroup, UsageTurn } from "./usage.ts";

/// Archived threads whose entries are kept decompressed, the most recently read last.
const ARCHIVE_CACHE = 32;
/// How many of a job's notices are kept.
const JOB_NOTICES = 50;
/// A Task's title in its index row is cut to this many characters.
export const TASK_TITLE_MAX = 120;
/// A Task's last_activity_at moves at most this often (ms): something said within it of the last move moves nothing.
export const TASK_ACTIVITY_EVERY_MS = 10_000;
/// How a turn that leaves its Task to a person ended (TurnSummary.ending: finished, or needing a person).
const ENDED_FOR_REVIEW = ["all_done", "need_help", "need_human"];

type Changes = StoreChange[];
type Arg = SQLInputValue;
const flag = (b: boolean): number => (b ? 1 : 0);
const optFlag = (b: boolean | null | undefined): number | null => (b === null || b === undefined ? null : flag(b));

export class Store {
  readonly db: DatabaseSync;
  /// Where archived threads (and sessions' transcript copies) are written.
  readonly #archiveDir: string;
  /// Removed on close: an in-memory store's archive.
  readonly #temp: string | null;
  /// Entries of archived threads read lately (they never change), the most recent last.
  #archived: [number, EntryRow[]][] = [];
  #listeners: ((change: StoreChange) => void)[] = [];
  #statements = new Map<string, StatementSync>();

  /// Its time: what the rows say things happened at (a TestClock in tests).
  readonly clock: Clock.Clock;

  private constructor(db: DatabaseSync, archiveDir: string, temp: string | null, clock: Clock.Clock) {
    this.db = db;
    this.clock = clock;
    this.#archiveDir = archiveDir;
    this.#temp = temp;
  }

  /// Opens the store at `path` (":memory:" for one of its own); archived threads go to `archive`, else `archive/`
  /// beside the database. A database of another schema version is refused.
  static open(path: string, archive: string | null = null, clock: Clock.Clock = liveClock): Store {
    const memory = path === ":memory:";
    if (!memory) mkdirSync(dirname(path), { recursive: true });
    // Busy for a moment (another process reading, the WAL recovered after a crash): waited for, from the first statement.
    const db = new DatabaseSync(path, { timeout: 5000 });
    try {
      db.exec("PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;");
      const hasTables = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions'").get() !== undefined;
      if (hasTables) {
        const version = (db.prepare("PRAGMA user_version").get() as Json).user_version;
        if (version !== SCHEMA_VERSION) {
          throw new Error(`${path} has schema version ${version}; this station uses ${SCHEMA_VERSION}. Move its data by hand, or move it aside.`);
        }
      }
      db.exec(SCHEMA);
      addArchiveColumns(db);
      addClientColumn(db);
      addAutoTitleColumns(db);
      addWatchColumn(db);
      addTaskSentColumn(db);
      addTaskStartColumn(db);
      addTaskAnsweredColumn(db);
      addTaskLabelsColumn(db);
      addMilestonesColumn(db);
      addRuntimeSessionRuntimeColumn(db);
      db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
    } catch (e) {
      db.close();
      throw e;
    }
    let store: Store;
    if (archive !== null) store = new Store(db, archive, null, clock);
    else if (memory) {
      const dir = join(tmpdir(), `stillfail-archive-${randomBytes(8).toString("hex")}`);
      mkdirSync(dir, { recursive: true });
      store = new Store(db, dir, dir, clock);
    } else store = new Store(db, join(dirname(path), "archive"), null, clock);
    try {
      store.#reconcileTasks();
    } catch (e) {
      // The station runs without it: each Task's row is made again with the next change to it.
      console.error("task index:", e);
    }
    return store;
  }

  /// Now, by its clock.
  now(): number {
    return this.clock.currentTimeMillisUnsafe();
  }

  /// Closes the database (and removes an in-memory store's archive): the Rust's drop.
  close(): void {
    this.db.close();
    if (this.#temp !== null) rmSync(this.#temp, { recursive: true, force: true });
  }

  /// Hears what changes from now on; the function returned stops it.
  subscribe(listener: (change: StoreChange) => void): () => void {
    this.#listeners.push(listener);
    return () => {
      this.#listeners = this.#listeners.filter((l) => l !== listener);
    };
  }

  /// Where archived threads and transcript copies go (`threads/`, `transcripts/`).
  archiveDir(): string {
    return this.#archiveDir;
  }

  #send(changes: Changes): void {
    const listeners = this.#listeners;
    for (const change of changes) {
      for (const l of listeners) {
        try {
          l(change);
        } catch (e) {
          // A follower failing must not undo what was written, nor keep the others from hearing it.
          console.error("store listener:", e);
        }
      }
    }
  }

  /// Store::with: runs `run`, then tells what it says changed (also when it failed part way, as the Rust does).
  #with<T>(run: (changes: Changes) => T): T {
    const changes: Changes = [];
    try {
      return run(changes);
    } finally {
      this.#indexTasks(changes);
      this.#send(changes);
    }
  }

  /// rusqlite's transaction(): BEGIN (deferred), committed when `run` returns, rolled back when it throws.
  #tx<T>(run: () => T): T {
    this.db.exec("BEGIN");
    let result: T;
    try {
      result = run();
    } catch (e) {
      try {
        this.db.exec("ROLLBACK");
      } catch {
        // Already rolled back by SQLite.
      }
      throw e;
    }
    this.db.exec("COMMIT");
    return result;
  }

  #stmt(sql: string): StatementSync {
    let s = this.#statements.get(sql);
    if (s === undefined) {
      s = this.db.prepare(sql);
      this.#statements.set(sql, s);
    }
    return s;
  }
  #one(sql: string, ...args: Arg[]): Json | undefined {
    return this.#stmt(sql).get(...args);
  }
  #all(sql: string, ...args: Arg[]): Json[] {
    return this.#stmt(sql).all(...args);
  }
  /// How many rows it changed.
  #run(sql: string, ...args: Arg[]): number {
    return Number(this.#stmt(sql).run(...args).changes);
  }

  /// Announces a change the station keeps outside the database (e.g. a runtime process ending).
  notify(session: string): void {
    this.#send([{ type: "session", key: session }]);
  }

  // ── sessions ──

  getSession(key: string): SessionRow | null {
    const r = this.#one("SELECT * FROM sessions WHERE key = ?", key);
    return r ? toSession(r) : null;
  }

  sessionByToken(token: string): SessionRow | null {
    const r = this.#one("SELECT * FROM sessions WHERE token = ?", token);
    return r ? toSession(r) : null;
  }

  /// Every session, most recently active first.
  listSessions(): SessionRow[] {
    return this.#all("SELECT * FROM sessions ORDER BY last_active_at DESC").map(toSession);
  }

  insertSession(s: NewSession): void {
    this.#with((changes) => {
      this.#run(
        `INSERT INTO sessions (key, connect, scope, title, created_by, runtime, profile, profile_pinned, model, effort, workspace, cwd, runtime_session_id, token, created_at, last_active_at, told_notes, fast)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        s.key, s.connect, s.scope ?? "thread", s.title ?? null, s.createdBy ?? null, s.runtime, s.profile, flag(s.profilePinned ?? false),
        s.model ?? null, s.effort ?? null, s.workspace, s.cwd ?? null, s.runtimeSessionId ?? null, s.token, s.createdAt, s.lastActiveAt,
        // A new session begins with today's instructions: no note is news to it.
        latestNote(), optFlag(s.fast),
      );
      changes.push({ type: "session", key: s.key });
    });
  }

  /// Moves a session to another profile (its transcripts are shared by its runtime's profiles); `pinned` keeps it there.
  setSessionProfile(key: string, profile: string, pinned: boolean): void {
    this.#updateSession(key, "UPDATE sessions SET profile = ?1, profile_pinned = ?2 WHERE key = ?3", profile, flag(pinned), key);
  }

  /// A session's model and effort from its next start on (null: the runtime's default).
  setSessionModel(key: string, model: string | null, effort: string | null): void {
    this.#updateSession(key, "UPDATE sessions SET model = ?1, effort = ?2 WHERE key = ?3", model, effort, key);
  }

  setSessionFast(key: string, fast: boolean | null): void {
    this.#updateSession(key, "UPDATE sessions SET fast = ?1 WHERE key = ?2", optFlag(fast), key);
  }

  codexSessionFast(thread: string): boolean | null {
    const r = this.#one("SELECT fast FROM sessions WHERE runtime = 'codex' AND runtime_session_id = ?", thread);
    return r === undefined || r.fast === null ? null : r.fast !== 0;
  }

  setTitle(key: string, title: string | null): void {
    this.#updateSession(key, "UPDATE sessions SET title = ?1 WHERE key = ?2", title, key);
  }

  setRuntimeSessionId(key: string, id: string): void {
    this.#updateSession(key, "UPDATE sessions SET runtime_session_id = ?1 WHERE key = ?2", id, key);
  }

  /// A runtime session the session runs in, on `profile` (null: not known, a profile it had is kept), running the
  /// session's runtime.
  ranIn(key: string, id: string, profile: string | null): void {
    this.#run(
      `INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) VALUES (?1, ?2, ?3, ?4, (SELECT runtime FROM sessions WHERE key = ?1))
       ON CONFLICT (session_key, id) DO UPDATE SET profile = COALESCE(excluded.profile, profile), runtime = COALESCE(runtime, excluded.runtime)`,
      key, id, profile, this.now(),
    );
  }

  /// The profile a runtime session of the session last ran on, if known.
  ranOn(key: string, id: string): string | null {
    return this.#one("SELECT profile FROM runtime_sessions WHERE session_key = ? AND id = ?", key, id)?.profile ?? null;
  }

  /// The runtime sessions the session has run in, the first first, ending with the one it runs in now; each with the
  /// runtime it ran (one kept before runtimes were: the session's).
  runtimeSessions(key: string): RanIn[] {
    const row = this.getSession(key);
    const own = row?.runtime ?? "";
    const current = row?.runtimeSessionId ?? null;
    const ran: RanIn[] = this.#all("SELECT id, runtime FROM runtime_sessions WHERE session_key = ? ORDER BY at, rowid", key).map((r) => ({ id: r.id, runtime: r.runtime ?? own }));
    if (current === null) return ran;
    return [...ran.filter((r) => r.id !== current), ran.find((r) => r.id === current) ?? { id: current, runtime: own }];
  }

  /// Leaves the runtime session a session runs in, kept with those it ran: its next start goes on afresh in a new one,
  /// told where its past is (sessions/afresh.ts), as it does on another account.
  leaveRuntimeSession(key: string): void {
    this.#with((changes) => {
      this.#run(
        `INSERT INTO runtime_sessions (session_key, id, profile, at, runtime)
           SELECT key, runtime_session_id, NULL, ?2, runtime FROM sessions WHERE key = ?1 AND runtime_session_id IS NOT NULL
         ON CONFLICT (session_key, id) DO UPDATE SET runtime = COALESCE(runtime, excluded.runtime)`,
        key, this.now(),
      );
      this.#run("UPDATE sessions SET runtime_session_id = NULL WHERE key = ?", key);
      changes.push({ type: "session", key });
    });
  }

  /// The station a Task of this station's own runs on when it is not this one (tasks.ts moveTo); null when its own
  /// sessions run it.
  runsOn(thread: number): string | null {
    return this.#one("SELECT station FROM task_runs WHERE thread = ?", thread)?.station ?? null;
  }

  /// Task `thread` runs on `station` from now on (null: on its own sessions again). Its row in the Task index is made
  /// again.
  setRunsOn(thread: number, station: string | null): void {
    this.#with((changes) => {
      if (station === null) this.#run("DELETE FROM task_runs WHERE thread = ?", thread);
      else this.#run("INSERT INTO task_runs (thread, station, at) VALUES (?, ?, ?) ON CONFLICT (thread) DO UPDATE SET station = excluded.station, at = excluded.at", thread, station, this.now());
      changes.push({ type: "thread", id: thread, entries: [] });
    });
  }

  /// Gives up what was pending for `session` in `thread`: none of it is handed to it.
  dropPending(thread: number, session: string): void {
    this.#run("DELETE FROM deliveries WHERE thread = ? AND session = ? AND delivered_at IS NULL", thread, session);
  }

  /// Through which entry `sessions` answered `thread`: the last post of theirs that ended a turn (all_done, need_help),
  /// short of the first message still pending for one of them.
  answeredBy(thread: number, sessions: string[]): number {
    if (sessions.length === 0) return 0;
    const list = JSON.stringify(sessions);
    const ended = this.#one(
      "SELECT MAX(n) AS n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND author IN (SELECT value FROM json_each(?)) AND declared IN ('all_done', 'need_help')",
      thread, list,
    )?.n;
    const pending = this.#one("SELECT MIN(n) AS n FROM deliveries WHERE thread = ? AND session IN (SELECT value FROM json_each(?)) AND delivered_at IS NULL", thread, list)?.n;
    const answered = ended === null || ended === undefined ? 0 : Number(ended);
    return pending === null || pending === undefined ? answered : Math.min(answered, Number(pending) - 1);
  }

  /// The runtimes each session ran in its runtime sessions, by its key (more than its own: it changed runtime).
  runtimesRun(): Map<string, Set<string>> {
    const ran = new Map<string, Set<string>>();
    for (const r of this.#all("SELECT DISTINCT session_key, runtime FROM runtime_sessions WHERE runtime IS NOT NULL")) {
      const of = ran.get(r.session_key) ?? new Set<string>();
      of.add(r.runtime);
      ran.set(r.session_key, of);
    }
    return ran;
  }

  /// Moves a session to another runtime from its next start, on `profile` (`pinned` keeps it there) with `model`,
  /// `effort` and `fast`. The runtime sessions it ran in keep the runtime they ran, the one it runs in now among them: its
  /// next start leaves it for a new one (sessions/afresh.ts).
  setSessionRuntime(key: string, runtime: string, profile: string, pinned: boolean, model: string | null, effort: string | null, fast: boolean | null): void {
    this.#with((changes) => {
      this.#run(
        `INSERT INTO runtime_sessions (session_key, id, profile, at, runtime)
           SELECT key, runtime_session_id, NULL, ?2, runtime FROM sessions WHERE key = ?1 AND runtime_session_id IS NOT NULL
         ON CONFLICT (session_key, id) DO UPDATE SET runtime = COALESCE(runtime, excluded.runtime)`,
        key, this.now(),
      );
      this.#run("UPDATE runtime_sessions SET runtime = (SELECT runtime FROM sessions WHERE key = ?1) WHERE session_key = ?1 AND runtime IS NULL", key);
      this.#run(
        "UPDATE sessions SET runtime = ?1, profile = ?2, profile_pinned = ?3, model = ?4, effort = ?5, fast = ?6 WHERE key = ?7",
        runtime, profile, flag(pinned), model, effort, optFlag(fast), key,
      );
      changes.push({ type: "session", key });
    });
  }

  setRunning(key: string, running: boolean): void {
    this.#updateSession(key, "UPDATE sessions SET running = ?1, last_active_at = ?2 WHERE key = ?3", flag(running), this.now(), key);
  }

  #updateSession(key: string, sql: string, ...args: Arg[]): void {
    this.#with((changes) => {
      this.#run(sql, ...args);
      changes.push({ type: "session", key });
    });
  }

  touch(key: string): void {
    this.#run("UPDATE sessions SET last_active_at = ? WHERE key = ?", this.now(), key);
  }

  /// Hides a session from lists, or shows it again, with its own chat (ThreadRow.home); `by` is MANUAL or AUTO. A thread
  /// out of lists goes out to its archive file; showing it again brings it back.
  setArchived(key: string, archived: boolean, by: string): void {
    this.#with((changes) => this.#setArchived(key, archived, by, changes));
  }

  /// Hides a chat of its own from lists, or shows it again; its sessions stay as they are.
  setThreadHidden(thread: number, hidden: boolean, by: string): void {
    this.#with((changes) => this.#setThreadHidden(thread, hidden, by, changes));
  }

  /// Names a chat, or (null) leaves it to be named by the first thing a person said in it.
  setThreadTitle(thread: number, title: string | null): void {
    this.#with((changes) => {
      this.#run("UPDATE threads SET title = ?1 WHERE id = ?2", title, thread);
      changes.push({ type: "thread", id: thread, entries: [] });
    });
  }

  /// The name a chat's agent gave it, as it stands: the name, the entry it came at, and how often it was changed since.
  autoTitle(thread: number): AutoTitle {
    const r = this.#one("SELECT auto_title, auto_title_n, auto_title_changes FROM threads WHERE id = ?", thread);
    return r ? { title: r.auto_title, n: r.auto_title_n ?? 0, changes: r.auto_title_changes } : { title: null, n: 0, changes: 0 };
  }

  /// Names a chat as its agent did: the first name, or (`changed`) another one, counted.
  setAutoTitle(thread: number, title: string, changed: boolean): void {
    this.#with((changes) => {
      const n = this.lastEntry(thread);
      this.#run(
        "UPDATE threads SET auto_title = ?1, auto_title_n = ?2, auto_title_changes = auto_title_changes + ?3 WHERE id = ?4",
        title, n, flag(changed), thread,
      );
      changes.push({ type: "thread", id: thread, entries: [] });
    });
  }

  /// How many messages people have written in a thread after entry `n`.
  peopleSaidAfter(thread: number, n: number): number {
    return this.#one("SELECT COUNT(*) AS c FROM entries WHERE thread = ? AND n > ? AND kind = 'message' AND author_kind = 'person'", thread, n).c;
  }

  /// When anyone last read a thread (moved their read position), in ms; null if nobody has.
  lastReadAt(thread: number): number | null {
    return this.#one("SELECT MAX(at) AS at FROM reads WHERE thread = ?", thread).at;
  }

  /// A session's own chat on the page (ThreadRow.home), if it has one.
  homeChat(session: string): ThreadRow | null {
    const r = this.#one("SELECT * FROM threads WHERE home = ? ORDER BY id LIMIT 1", session);
    return r ? toThread(r) : null;
  }

  /// Chats of their own on the page (no session's home) still in lists.
  chatsOfTheirOwn(): ThreadRow[] {
    return this.#all("SELECT * FROM threads WHERE surface = ? AND home IS NULL AND hidden_at IS NULL", STILLFAIL_SURFACE).map(toThread);
  }

  /// Forgets a session: its row, turns, deliveries, memberships and bindings, and the threads only it took part in,
  /// with their entries (or archive files) and reads.
  deleteSession(key: string): void {
    this.#with((changes) => {
      const kept: number[] = [];
      const removed: number[] = [];
      this.#tx(() => {
        const threads: number[] = this.#all("SELECT thread FROM thread_sessions WHERE session = ?", key).map((r) => r.thread);
        this.#run("DELETE FROM thread_sessions WHERE session = ?", key);
        this.#run("DELETE FROM deliveries WHERE session = ?", key);
        this.#run("DELETE FROM turns WHERE session_key = ?", key);
        this.#run("DELETE FROM runtime_sessions WHERE session_key = ?", key);
        this.#run("DELETE FROM bindings WHERE session_key = ?", key);
        this.#run("DELETE FROM job_notices WHERE job_id IN (SELECT id FROM jobs WHERE session_key = ?)", key);
        this.#run("DELETE FROM jobs WHERE session_key = ?", key);
        this.#run("DELETE FROM widget_states WHERE session = ?", key);
        this.#run("DELETE FROM pins WHERE session = ?", key);
        this.#run("DELETE FROM sessions WHERE key = ?", key);
        for (const thread of threads) {
          if (this.#one("SELECT 1 FROM thread_sessions WHERE thread = ? LIMIT 1", thread) !== undefined) {
            kept.push(thread);
            continue;
          }
          removed.push(thread);
          this.#run("DELETE FROM deliveries WHERE thread = ?", thread);
          this.#run("DELETE FROM entries WHERE thread = ?", thread);
          this.#run("DELETE FROM reads WHERE thread = ?", thread);
          this.#run("DELETE FROM items WHERE thread = ?", thread);
          this.#run("DELETE FROM dismissed WHERE thread = ?", thread);
          this.#run("DELETE FROM closed_cards WHERE thread = ?", thread);
          this.#run("DELETE FROM kept_chats WHERE thread = ?", thread);
          this.#run("DELETE FROM threads WHERE id = ?", thread);
        }
      });
      for (const thread of removed) {
        this.#archived = this.#archived.filter(([id]) => id !== thread);
        rmSync(this.#threadFile(thread), { force: true });
      }
      changes.push({ type: "sessionRemoved", key });
      // Clients drop what they keep of the threads that went with it.
      for (const id of removed) changes.push({ type: "threadRemoved", id });
      for (const id of kept) changes.push({ type: "thread", id, entries: [] });
    });
  }

  // ── single-session bindings ──

  /// The session a single-session connect delivers into, if one is bound.
  binding(connect: string): string | null {
    const r = this.#one("SELECT session_key FROM bindings WHERE connect = ?", connect);
    return r ? r.session_key : null;
  }

  /// Binds a connect to a session, or unbinds it (null) so its next message starts a new one.
  setBinding(connect: string, session: string | null): void {
    this.#with((changes) => {
      const before = this.binding(connect);
      if (session !== null) this.#run("INSERT OR REPLACE INTO bindings (connect, session_key) VALUES (?, ?)", connect, session);
      else this.#run("DELETE FROM bindings WHERE connect = ?", connect);
      const keys = [...new Set([before, session].filter((k): k is string => k !== null))].sort(byBytes);
      for (const key of keys) changes.push({ type: "session", key });
    });
  }

  /// Connects bound to each session (by session key, in the BTreeMap's order).
  listBindings(): Map<string, string[]> {
    const out = new Map<string, string[]>();
    for (const r of this.#all("SELECT connect, session_key FROM bindings")) out.set(r.session_key, [...(out.get(r.session_key) ?? []), r.connect]);
    return new Map([...out].sort(([a], [b]) => byBytes(a, b)));
  }

  // ── threads ──

  getThread(id: number): ThreadRow | null {
    const r = this.#one("SELECT * FROM threads WHERE id = ?", id);
    return r ? toThread(r) : null;
  }

  threadAt(surface: string, channel: string, threadTs: string): ThreadRow | null {
    const r = this.#one("SELECT * FROM threads WHERE surface = ? AND channel = ? AND thread_ts = ?", surface, channel, threadTs);
    return r ? toThread(r) : null;
  }

  /// The threads at CHANNEL/THREAD_TS on any surface (an agent names a conversation without its surface).
  threadsAt(channel: string, threadTs: string): ThreadRow[] {
    return this.#all("SELECT * FROM threads WHERE channel = ? AND thread_ts = ? ORDER BY id", channel, threadTs).map(toThread);
  }

  /// The thread at this address, made if new.
  openThread(surface: string, channel: string, threadTs: string, title: string | null, createdBy: string | null): ThreadRow {
    return this.openThreadOf(surface, channel, threadTs, title, createdBy, null);
  }

  /// The thread at this address, made if new as `home`'s own chat (ThreadRow.home).
  openThreadOf(surface: string, channel: string, threadTs: string, title: string | null, createdBy: string | null, home: string | null): ThreadRow {
    this.#run(
      "INSERT OR IGNORE INTO threads (surface, channel, thread_ts, title, created_by, created_at, home) VALUES (?, ?, ?, ?, ?, ?, ?)",
      surface, channel, threadTs, title, createdBy, this.now(), home,
    );
    const thread = this.threadAt(surface, channel, threadTs);
    if (thread === null) throw new Error(`thread ${surface} ${channel}/${threadTs} not made`);
    // A new chat on the page is a new Task (one there already was reads the same: no new rev).
    if (surface === STILLFAIL_SURFACE) this.#indexTasks([{ type: "thread", id: thread.id, entries: [] }]);
    return thread;
  }

  /// The thread a platform message is in: the one it was said in, else the one it starts.
  threadOfMessage(surface: string, channel: string, ts: string): ThreadRow | null {
    const said = this.#one(
      "SELECT t.* FROM entries e JOIN threads t ON t.id = e.thread WHERE t.surface = ? AND t.channel = ? AND e.ts = ? LIMIT 1",
      surface, channel, ts,
    );
    return said ? toThread(said) : this.threadAt(surface, channel, ts);
  }

  /// The Station whose Task a session takes part in (tasks_elsewhere), null when it takes part in none.
  taskHostOf(session: string): string | null {
    const r = this.#one("SELECT te.station FROM thread_sessions ts JOIN tasks_elsewhere te ON te.thread = ts.thread WHERE ts.session = ? LIMIT 1", session);
    return typeof r?.station === "string" ? r.station : null;
  }

  /// Makes a session take part in a thread, posting through `connect`. False if it already did.
  joinThread(thread: number, session: string, connect: string): boolean {
    return this.#with((changes) => {
      const joined = this.#run("INSERT OR IGNORE INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, ?)", thread, session, connect, this.now()) > 0;
      if (joined) {
        changes.push({ type: "session", key: session });
        changes.push({ type: "thread", id: thread, entries: [] });
      }
      return joined;
    });
  }

  /// Makes a session no longer take part in a thread: it hears nothing more of it, and what was pending for it there is
  /// not handed to it. False if it did not take part.
  leaveThread(thread: number, session: string): boolean {
    return this.#with((changes) => {
      const left = this.#tx(() => {
        const gone = this.#run("DELETE FROM thread_sessions WHERE thread = ? AND session = ?", thread, session) > 0;
        if (gone) this.#run("DELETE FROM deliveries WHERE thread = ? AND session = ? AND delivered_at IS NULL", thread, session);
        return gone;
      });
      if (left) {
        changes.push({ type: "session", key: session });
        changes.push({ type: "thread", id: thread, entries: [] });
      }
      return left;
    });
  }

  threadSessions(thread: number): Membership[] {
    return this.#all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", thread).map(toMembership);
  }

  /// A thread of this session by the address the agent names it with, and how the session posts there.
  sessionThread(session: string, channel: string, threadTs: string): SessionThread | null {
    const r = this.#one(
      "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? AND t.channel = ? AND t.thread_ts = ?",
      session, channel, threadTs,
    );
    return r ? toSessionThread(r) : null;
  }

  /// The threads a session takes part in, most recently joined first, with the connect it posts through in each.
  sessionThreads(session: string): SessionThread[] {
    return this.#all(
      "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? ORDER BY ts.joined_at DESC, ts.rowid DESC",
      session,
    ).map(toSessionThread);
  }

  /// The thread a session last heard from: where the station's own notices go and whose connect's name the agent goes
  /// by. Falls back to the thread it joined last when it has heard nothing yet.
  latestThread(session: string): SessionThread | null {
    const heard = this.#one(
      `SELECT t.*, ts.connect FROM deliveries d JOIN threads t ON t.id = d.thread
       JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session
       WHERE d.session = ? ORDER BY d.rowid DESC LIMIT 1`,
      session,
    );
    return heard ? toSessionThread(heard) : (this.sessionThreads(session)[0] ?? null);
  }

  /// Threads with their sessions, last entry, latest message and the viewer's unread count, most recently said in
  /// first: those of one session, one thread, or all.
  listThreads(viewer: string, session: string | null, thread: number | null): ThreadSummary[] {
    const base = "SELECT t.*, COALESCE(r.n, 0) AS read_n FROM threads t LEFT JOIN reads r ON r.thread = t.id AND r.viewer = ?1";
    const rows =
      thread !== null
        ? this.#all(`${base} WHERE t.id = ?2`, viewer, thread)
        : session !== null
          ? this.#all(`${base} WHERE t.id IN (SELECT thread FROM thread_sessions WHERE session = ?2)`, viewer, session)
          : this.#all(base, viewer);
    const summaries: ThreadSummary[] = rows.map((r) => {
      const t = toThread(r);
      const read: number = r.read_n;
      return {
        sessions: this.threadSessions(t.id),
        last: this.lastEntry(t.id),
        lastMessage: this.lastMessage(t.id),
        read,
        unread: this.#unreadCount(viewer, t.id, read),
        people: this.#threadPeople(t.id, t.surface),
        firstText: this.#firstText(t.id),
        thread: t,
      };
    });
    const said = (t: ThreadSummary) => t.lastMessage?.createdAt ?? 0;
    summaries.sort((a, b) => said(b) - said(a) || b.thread.createdAt - a.thread.createdAt || b.thread.id - a.thread.id);
    return summaries;
  }

  /// The thread's latest message as merged, for lists.
  lastMessage(thread: number): MessageRow | null {
    if (this.#isArchived(thread)) return mergeEntries(this.#archivedEntries(thread)).pop() ?? null;
    const r = this.#one("SELECT * FROM merged WHERE thread = ? ORDER BY n DESC LIMIT 1", thread);
    return r ? toMessage(r) : null;
  }

  /// Messages after the viewer's read position that are not the viewer's own (nor of a Slack user they are).
  unreadCount(viewer: string, thread: number): number {
    return this.#unreadCount(viewer, thread, this.readPosition(viewer, thread));
  }

  // ── entries ──

  /// Records something said. A message already recorded in that thread (Slack delivers to every connect in the channel,
  /// and redelivers) is the same message: its n comes back with `fresh` false and nothing changes. A post that only
  /// records milestones (onlyMilestones) is kept as a "milestone" entry, with no text.
  insertMessage(m: NewMessage): [number, boolean] {
    return this.#with((changes) => {
      const existing = this.#entryAt(m.thread, m.ts);
      if (existing !== null) return [existing, false];
      const card = m.card ?? undefined;
      const options = m.options ?? undefined;
      const only = onlyMilestones(m);
      const entry = this.#append(
        {
          agentIdentity: undefined, thread: m.thread, n: 0, kind: only ? "milestone" : "message", target: null, ts: m.ts, authorKind: m.authorKind,
          author: m.author, text: only ? null : m.text, attachments: m.attachments ?? [], quotes: m.quotes ?? [], declared: m.declared ?? null,
          client: m.client ?? null, profile: m.profile ?? null,
          // An options card is kept as options too (what stations and clients from before cards read).
          options: options ?? (card !== undefined && card !== null && typeof card === "object" && card.type === "options" ? card.options : undefined),
          card: card ?? (options === undefined ? undefined : optionsCard(options)),
          at: m.at ?? this.now(),
          milestones: m.milestones && m.milestones.length > 0 ? [...m.milestones] : undefined,
        },
        changes,
      );
      return [entry.n, true];
    });
  }

  /// A platform edit: an edit entry with the message's new words. The thread, or null for a message the station never
  /// recorded or one whose words did not change.
  editMessage(surface: string, channel: string, threadTs: string, ts: string, text: string): number | null {
    return this.#with((changes) => {
      const thread = this.threadAt(surface, channel, threadTs);
      if (thread === null) return null;
      const message = this.#messageAt(thread.id, ts);
      if (message === null || message.text === text) return null;
      this.#append(
        {
          agentIdentity: undefined, thread: message.thread, n: 0, kind: "edit", target: message.n, ts: null,
          authorKind: message.authorKind, author: message.author, text, attachments: message.attachments, quotes: message.quotes,
          declared: null, client: null, profile: null, options: undefined, card: undefined, at: this.now(), milestones: undefined,
        },
        changes,
      );
      return message.thread;
    });
  }

  recentDecisions(): Json[] {
    return this.#all("SELECT id, session, created_at, result FROM decision_checks ORDER BY id DESC LIMIT 30").map((r) => ({
      id: r.id, session: r.session, at: r.created_at, detail: parsed(r.result) ?? null,
    }));
  }

  /// Audit metadata only: no conversation text or API credentials.
  recordDecision(session: string, result: Json): void {
    this.#with((changes) => {
      this.#run("INSERT INTO decision_checks(session, created_at, result) VALUES (?, ?, ?)", session, this.now(), JSON.stringify(result));
      changes.push({ type: "decisionChecks" });
    });
  }

  /// The session's latest decision record, if any.
  lastDecision(session: string): Json | null {
    const row = this.#one("SELECT result FROM decision_checks WHERE session = ? ORDER BY id DESC LIMIT 1", session);
    return row ? (parsed(row.result) ?? null) : null;
  }

  /// The checks recorded since `since` (ms), oldest first.
  decisionsSince(since: number): Json[] {
    return this.#all("SELECT id, session, created_at, result FROM decision_checks WHERE created_at >= ? ORDER BY id", since).map((r) => ({
      id: r.id, session: r.session, at: r.created_at, detail: parsed(r.result) ?? null,
    }));
  }

  /// The archive policy as last saved, and who saved it; null until anyone has (the default then).
  archivePolicy(): { policy: Json; change: Json } | null {
    const r = this.#one("SELECT id, at, policy, author, summary FROM archive_policy ORDER BY id DESC LIMIT 1");
    if (!r) return null;
    const policy = parsed(r.policy);
    if (!policy) return null;
    return { policy, change: { id: r.id, at: r.at, by: parsed(r.author) ?? null, summary: r.summary } };
  }

  /// A new archive policy, by whom, and what it changed.
  setArchivePolicy(policy: Json, author: Json, summary: string): void {
    this.#with((changes) => {
      this.#run("INSERT INTO archive_policy(at, policy, author, summary) VALUES (?, ?, ?, ?)", this.now(), JSON.stringify(policy), JSON.stringify(author), summary);
      changes.push({ type: "decisionChecks" });
    });
  }

  /// What the latest review found for a thread as it stood at `version`: the option picked, or why there is none.
  setArchiveVerdict(session: string, thread: number, version: number, verdict: Json): void {
    this.#with((changes) => {
      this.#run(
        "INSERT INTO archive_verdicts(thread, version, at, verdict) VALUES (?, ?, ?, ?) ON CONFLICT(thread) DO UPDATE SET version = excluded.version, at = excluded.at, verdict = excluded.verdict",
        thread, version, this.now(), JSON.stringify(verdict),
      );
      changes.push({ type: "session", key: session });
    });
  }

  /// The decision found nothing left to do in this thread as it stood at `version` (its last entry then).
  suggestArchive(session: string, thread: number, version: number): void {
    this.#with((changes) => {
      this.#run(
        "INSERT INTO archive_suggestions(thread, version, at) VALUES (?, ?, ?) ON CONFLICT(thread) DO UPDATE SET version = excluded.version, at = excluded.at",
        thread, version, this.now(),
      );
      changes.push({ type: "session", key: session });
    });
  }

  /// The decision no longer says so (it found something left, or could not tell).
  clearArchiveSuggestion(session: string, thread: number): void {
    this.#with((changes) => {
      if (this.#run("DELETE FROM archive_suggestions WHERE thread = ?", thread) > 0) changes.push({ type: "session", key: session });
    });
  }

  /// Whether the archive is recommended for the thread: the decision looked at it as it stands now.
  archiveSuggested(thread: number): boolean {
    let version: number | null = null;
    try {
      version = this.#one("SELECT version FROM archive_suggestions WHERE thread = ?", thread)?.version ?? null;
    } catch {
      // `.ok()`: a failing read is no suggestion.
    }
    return version !== null && version === this.lastEntry(thread);
  }

  /// The thread's last entry number, 0 before anything is said.
  lastEntry(thread: number): number {
    if (this.#isArchived(thread)) return this.#archivedEntries(thread).at(-1)?.n ?? 0;
    return this.#one("SELECT MAX(n) AS n FROM entries WHERE thread = ?", thread).n ?? 0;
  }

  /// Entries after n: what came since.
  entriesAfter(thread: number, n: number): EntryRow[] {
    return this.entriesBetween(thread, n + 1, I64_MAX);
  }

  /// The latest `limit` entries before n (the latest of all without it), oldest first.
  entriesBefore(thread: number, n: number | null, limit: number): EntryRow[] {
    const before = n ?? I64_MAX;
    if (this.#isArchived(thread)) {
      const entries = this.#archivedEntries(thread).filter((e) => e.n < before);
      return entries.slice(Math.max(0, entries.length - limit));
    }
    return this.#all("SELECT * FROM entries WHERE thread = ? AND n < ? ORDER BY n DESC LIMIT ?", thread, before, limit).map(toEntry).reverse();
  }

  /// Entries from n = `from` to n = `to`, both included: a gap.
  entriesBetween(thread: number, from: number | bigint, to: number | bigint): EntryRow[] {
    if (this.#isArchived(thread)) return this.#archivedEntries(thread).filter((e) => e.n >= from && e.n <= to);
    return this.#all("SELECT * FROM entries WHERE thread = ? AND n >= ? AND n <= ? ORDER BY n", thread, from, to).map(toEntry);
  }

  /// A message of the thread by its platform id, as merged.
  messageAt(thread: number, ts: string): MessageRow | null {
    return this.#messageAt(thread, ts);
  }

  /// The latest `limit` messages before n (the latest of all without it), as merged, oldest first.
  messagesBefore(thread: number, n: number | null, limit: number): MessageRow[] {
    const before = n ?? I64_MAX;
    if (this.#isArchived(thread)) {
      const messages = mergeEntries(this.#archivedEntries(thread)).filter((m) => m.n < before);
      return messages.slice(Math.max(0, messages.length - limit));
    }
    return this.#all("SELECT * FROM merged WHERE thread = ? AND n < ? ORDER BY n DESC LIMIT ?", thread, before, limit).map(toMessage).reverse();
  }

  // ── deliveries ──

  /// Hands a message to sessions. Those that did not have it yet. A Task here that runs on another station hands its
  /// chat's own sessions nothing (runsOn).
  deliver(thread: number, n: number, sessions: string[]): string[] {
    if (this.runsOn(thread) !== null) return [];
    return this.#with((changes) => {
      const added: string[] = [];
      for (const s of sessions) {
        if (this.#run("INSERT OR IGNORE INTO deliveries (thread, n, session) VALUES (?, ?, ?)", thread, n, s) > 0) {
          added.push(s);
          changes.push({ type: "session", key: s });
        }
      }
      return added;
    });
  }

  /// What the session has yet to read, as merged now, in the order it was handed over.
  pendingMessages(session: string): PendingMessage[] {
    return this.#all(
      `SELECT m.*, t.surface, t.channel, t.thread_ts, ts.connect FROM deliveries d
       JOIN merged m ON m.thread = d.thread AND m.n = d.n JOIN threads t ON t.id = d.thread
       JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session
       WHERE d.session = ? AND d.delivered_at IS NULL ORDER BY d.rowid`,
      session,
    ).map((r) => ({ message: toMessage(r), surface: r.surface, channel: r.channel, threadTs: r.thread_ts, connect: r.connect }));
  }

  /// Marks messages (thread, n) read by the session.
  markDelivered(session: string, messages: [number, number][]): void {
    this.#with((changes) => {
      const now = this.now();
      for (const [thread, n] of messages) {
        this.#run("UPDATE deliveries SET delivered_at = ? WHERE thread = ? AND n = ? AND session = ? AND delivered_at IS NULL", now, thread, n, session);
      }
      if (messages.length > 0) changes.push({ type: "session", key: session });
    });
  }

  /// Makes messages delivered to the session pending again: the runtime they were handed to ended before it could be
  /// sure to have read them.
  markUndelivered(session: string, messages: [number, number][]): void {
    this.#with((changes) => {
      for (const [thread, n] of messages) {
        this.#run("UPDATE deliveries SET delivered_at = NULL WHERE thread = ? AND n = ? AND session = ?", thread, n, session);
      }
      if (messages.length > 0) changes.push({ type: "session", key: session });
    });
  }

  /// Threads the session has already read something from.
  heardThreads(session: string): Set<number> {
    return new Set(this.#all("SELECT DISTINCT thread FROM deliveries WHERE session = ? AND delivered_at IS NOT NULL", session).map((r) => r.thread));
  }

  sessionsWithPending(): string[] {
    return this.#all("SELECT DISTINCT session FROM deliveries WHERE delivered_at IS NULL").map((r) => r.session);
  }

  /// Everyone who wrote in each session's threads (or one session's), as creator references, earliest first.
  participants(session: string | null): Map<string, string[]> {
    const sql = `SELECT ts.session, ts.connect, t.id, t.surface, t.archived_at FROM thread_sessions ts JOIN threads t ON t.id = ts.thread ${session !== null ? "WHERE ts.session = ?" : ""}`;
    const rows = session !== null ? this.#all(sql, session) : this.#all(sql);
    // Each person once per session, at the first time they wrote in any of its threads.
    const firsts = new Map<string, Map<string, number>>();
    for (const r of rows) {
      const authors: [string, number][] =
        r.archived_at !== null
          ? this.#archivedEntries(r.id).filter((e) => e.kind === "message" && e.authorKind === "person").map((e) => [e.author, e.at])
          : this.#all("SELECT author, MIN(at) AS at FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' GROUP BY author", r.id).map((a) => [a.author, a.at]);
      const refs = firsts.get(r.session) ?? new Map<string, number>();
      firsts.set(r.session, refs);
      for (const [author, at] of authors) {
        const reference = r.surface === STILLFAIL_SURFACE ? author : `slack:${r.connect}:${author}`;
        const first = refs.get(reference);
        if (first === undefined || at < first) refs.set(reference, at);
      }
    }
    const out = new Map<string, string[]>();
    for (const [key, refs] of [...firsts].sort(([a], [b]) => byBytes(a, b))) {
      if (refs.size === 0) continue;
      // In the BTreeMap's order, then (stably) by when.
      const sorted = [...refs].sort(([a], [b]) => byBytes(a, b)).sort(([, a], [, b]) => a - b);
      out.set(key, sorted.map(([r]) => r));
    }
    return out;
  }

  // ── reads ──

  /// How far a viewer has read a thread (an entry number), 0 if never.
  readPosition(viewer: string, thread: number): number {
    return this.#one("SELECT n FROM reads WHERE viewer = ? AND thread = ?", viewer, thread)?.n ?? 0;
  }

  /// Moves a viewer's read position forward (never back). Where it is now.
  setRead(viewer: string, thread: number, n: number): number {
    return this.#with((changes) => {
      this.#run(
        `INSERT INTO reads (viewer, thread, n, at) VALUES (?, ?, ?, ?)
         ON CONFLICT (viewer, thread) DO UPDATE SET n = MAX(n, excluded.n), at = excluded.at`,
        viewer, thread, n, this.now(),
      );
      const now = this.readPosition(viewer, thread);
      changes.push({ type: "read", viewer, thread, n: now });
      return now;
    });
  }

  // ── pins ──

  /// The chats a viewer pinned (by their session's key), with when.
  pins(viewer: string): Map<string, number> {
    return new Map(this.#all("SELECT session, at FROM pins WHERE viewer = ?", viewer).map((r) => [r.session, r.at]));
  }

  /// The chats someone pinned (by their session's key): the station does not archive them for idling.
  pinnedSessions(): Set<string> {
    return new Set(this.#all("SELECT DISTINCT session FROM pins").map((r) => r.session));
  }

  /// Pins a chat to the top of a viewer's list, or lets it go. Pinned again, it keeps when it was first pinned.
  setPin(viewer: string, session: string, pinned: boolean): void {
    this.#with((changes) => {
      if (pinned) this.#run("INSERT OR IGNORE INTO pins (viewer, session, at) VALUES (?, ?, ?)", viewer, session, this.now());
      else this.#run("DELETE FROM pins WHERE viewer = ? AND session = ?", viewer, session);
      changes.push({ type: "pins", viewer });
    });
  }

  /// Chats kept instead of offered for archiving. Null selects every viewer, for automatic archiving.
  keptChats(viewer: string | null): Set<number> {
    return new Set(this.#all("SELECT DISTINCT thread FROM kept_chats WHERE ?1 IS NULL OR viewer = ?1", viewer).map((r) => r.thread));
  }

  keepChat(viewer: string, thread: number): void {
    this.#with((changes) => {
      this.#run("INSERT OR IGNORE INTO kept_chats (viewer, thread) VALUES (?, ?)", viewer, thread);
      changes.push({ type: "dismissed", viewer });
    });
  }

  // ── cards ──

  /// The thread's card still pending, if any: its latest post with a card (a newer one replaces an older one), as long
  /// as no person has written in the thread since. The post as merged, and its card.
  pendingCard(thread: number): [MessageRow, Json] | null {
    if (this.#isArchived(thread)) return null;
    // The latest of each kind (cards, and options from before cards), each read by its own index.
    const latest = (column: string): Json | undefined =>
      this.#one(`SELECT n, card, options FROM entries WHERE thread = ? AND kind = 'message' AND ${column} IS NOT NULL ORDER BY n DESC LIMIT 1`, thread);
    const a = latest("card");
    const b = latest("options");
    const asked = a && b ? (a.n >= b.n ? a : b) : (a ?? b);
    if (!asked) return null;
    const n: number = asked.n;
    const answered = this.#one("SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ? LIMIT 1", thread, n) !== undefined;
    const closed = this.#one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, n) !== undefined;
    if (answered || closed) return null;
    const card = cardOf(asked.card, asked.options);
    if (card === undefined) return null;
    const m = this.#one("SELECT * FROM merged WHERE thread = ? AND n = ?", thread, n);
    return m ? [toMessage(m), card] : null;
  }

  /// The message an agent's need without a card asks with, while no person has written after it: the one its turn is
  /// about (`about`, an entry n), else the agent's latest message during the turn (`during`: from, to, ms); with the two
  /// messages before it. Null in an archived chat, or when that message has a card.
  askingMessage(thread: number, about: number | null, during: [number, number]): [MessageRow, MessageRow[]] | null {
    if (this.#isArchived(thread)) return null;
    const n: number | null =
      about ??
      this.#one("SELECT max(n) AS n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND at >= ? AND at <= ?", thread, during[0], during[1]).n;
    if (n === null) return null;
    const answered = this.#one("SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ? LIMIT 1", thread, n) !== undefined;
    // A post with a card is pendingCard's: one no longer pending was answered, closed or withdrawn.
    const carded = this.#one("SELECT 1 FROM entries WHERE thread = ? AND n = ? AND (card IS NOT NULL OR options IS NOT NULL)", thread, n) !== undefined;
    if (answered || carded) return null;
    const messages = this.messagesBefore(thread, n + 1, 3);
    const m = messages.pop();
    return m && m.n === n && m.authorKind === "agent" ? [m, messages] : null;
  }

  /// The cards answered since `since` (ms), whoever answered them: each a person's first message after a card (the
  /// thread's latest card then), or a choice that closed it (closed_cards, by a person: not its agent withdrawing it).
  answersSince(since: number): CardAnswer[] {
    const out: CardAnswer[] = [];
    const said = this.#all("SELECT thread, n FROM entries WHERE author_kind = 'person' AND kind = 'message' AND at >= ?", since);
    const askedBefore = (thread: number, n: number): number | null => {
      const card: number | null = this.#one("SELECT max(n) AS n FROM entries WHERE thread = ? AND n < ? AND kind = 'message' AND card IS NOT NULL", thread, n).n;
      const options: number | null = this.#one("SELECT max(n) AS n FROM entries WHERE thread = ? AND n < ? AND kind = 'message' AND options IS NOT NULL", thread, n).n;
      // Option's max: None below any Some.
      return card === null ? options : options === null ? card : Math.max(card, options);
    };
    const cardAt = (thread: number, n: number): [MessageRow, Json] | null => {
      const row = this.#one("SELECT card, options FROM entries WHERE thread = ? AND n = ?", thread, n);
      const card = row ? cardOf(row.card, row.options) : undefined;
      if (card === undefined) return null;
      const m = this.#one("SELECT * FROM merged WHERE thread = ? AND n = ?", thread, n);
      return m ? [toMessage(m), card] : null;
    };
    for (const { thread, n } of said) {
      const asked = askedBefore(thread, n);
      if (asked === null) continue;
      // Only the first word after it answers it; one closed (by a choice or withdrawn) was answered then.
      const earlier = this.#one("SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ? AND n < ? LIMIT 1", thread, asked, n) !== undefined;
      const closed = this.#one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, asked) !== undefined;
      if (earlier || closed) continue;
      const found = cardAt(thread, asked);
      if (!found) continue;
      const answer = this.#one("SELECT * FROM merged WHERE thread = ? AND n = ?", thread, n);
      if (!answer) continue;
      const a = toMessage(answer);
      out.push({ question: found[0], card: found[1], by: a.author, at: a.createdAt, answer: a });
    }
    for (const { thread, n, viewer: by, at } of this.#all("SELECT thread, n, viewer, at FROM closed_cards WHERE at >= ?", since)) {
      const found = cardAt(thread, n);
      if (!found) continue;
      // Withdrawn by its own agent: no one answered it.
      if (found[0].author === by) continue;
      out.push({ question: found[0], card: found[1], by, at, answer: null });
    }
    return out;
  }

  /// The cards a viewer dismissed, as "thread:n" (read/store.ts's key for the Rust's (thread, n)).
  dismissed(viewer: string): Set<string> {
    return new Set(this.#all("SELECT thread, n FROM dismissed WHERE viewer = ?", viewer).map((r) => `${r.thread}:${r.n}`));
  }

  /// A viewer will not take up a card (the post at `n`): it leaves their list, on every device of theirs.
  dismiss(viewer: string, thread: number, n: number): void {
    this.#with((changes) => {
      this.#run("INSERT OR IGNORE INTO dismissed (viewer, thread, n, at) VALUES (?, ?, ?, ?)", viewer, thread, n, this.now());
      changes.push({ type: "dismissed", viewer });
    });
  }

  /// The author withdraws one exact card, without deleting its post or declaring the chat complete.
  withdrawCard(agent: string, thread: number, ts: string): boolean {
    return this.#with((changes) => {
      const r = this.#one(
        "SELECT n FROM entries WHERE thread = ? AND ts = ? AND kind = 'message' AND author_kind = 'agent' AND author = ? AND (card IS NOT NULL OR options IS NOT NULL)",
        thread, ts, agent,
      );
      if (r === undefined) return false;
      this.#run("INSERT OR IGNORE INTO closed_cards (thread, n, viewer, at) VALUES (?, ?, ?, ?)", thread, r.n, agent, this.now());
      changes.push({ type: "thread", id: thread, entries: [] });
      return true;
    });
  }

  /// Close this exact pending card for everyone. This writes no message or delivery: the agent stays asleep. A stale
  /// click cannot close a newer question or overwrite a newer turn's state. `lang` is lang.rs `spoken()`: the request's.
  closeCard(viewer: string, thread: number, n: number, option: string, lang: Lang = stationLang()): boolean {
    return this.#with((changes) => {
      // Told only when it got as far as closing it (one already closed says true and tells nothing, as the Rust).
      let closed: { agent: string; changed: boolean } | null = null;
      const done = this.#tx(() => {
        const offered = this.#one("SELECT card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", thread, n);
        const card = offered ? cardOf(offered.card, offered.options) : undefined;
        if (card === undefined) return false;
        const choices: Json[] = card !== null && Array.isArray(card.options) ? card.options : [];
        const closes = choices.some((o) => o !== null && typeof o === "object" && typeof o.label === "string" && o.label.trim() === option && o.action === "close");
        if (card === null || card.type !== "options" || !closes) return false;
        if (this.#one("SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, n) !== undefined) return true;
        const asked = this.#one(
          "SELECT n, author, at FROM entries WHERE thread = ? AND kind = 'message' AND (card IS NOT NULL OR options IS NOT NULL) ORDER BY n DESC LIMIT 1",
          thread,
        );
        if (asked === undefined) return false;
        const answered = this.#one("SELECT EXISTS(SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ?) AS e", thread, n).e !== 0;
        if (asked.n !== n || answered) return false;
        // Do not race the agent still composing its question / recording its ending.
        const composing = this.#one("SELECT ended_at IS NULL AS c FROM turns WHERE session_key = ? ORDER BY started_at DESC LIMIT 1", asked.author);
        if (composing !== undefined && composing.c !== 0) return false;
        this.#run("INSERT INTO closed_cards (thread, n, viewer, at) VALUES (?, ?, ?, ?)", thread, n, viewer, this.now());
        const changed = this.#run(
          `UPDATE turns SET declared = 'final', need = ?5, wait_seconds = NULL
           WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC LIMIT 1)
             AND declared IN ('block', 'need_help', 'need_human', 'need_decision') AND ended_at IS NOT NULL
             AND ((about_thread = ?2 AND about_n = ?3) OR (about_n IS NULL AND thread = ?2 AND started_at <= ?4))`,
          asked.author, thread, n, asked.at, tr(lang, "station.card.chosen", { option }),
        );
        closed = { agent: asked.author, changed: changed > 0 };
        return true;
      });
      const told = closed as { agent: string; changed: boolean } | null;
      if (told !== null) {
        if (told.changed) changes.push({ type: "session", key: told.agent });
        changes.push({ type: "thread", id: thread, entries: [] });
      }
      return done;
    });
  }

  // ── identities ──

  /// The Slack users a viewer said are them: their messages are the viewer's own.
  slackIdentities(viewer: string): string[] {
    return this.#all("SELECT slack_user FROM identities WHERE viewer = ? ORDER BY at", viewer).map((r) => r.slack_user);
  }

  /// Binds a Slack user to a viewer ("这是我"), or unbinds it. Nobody checks: it is the viewer's word.
  setSlackIdentity(viewer: string, user: string, bound: boolean): void {
    this.#with((changes) => {
      if (bound) this.#run("INSERT OR IGNORE INTO identities (viewer, slack_user, at) VALUES (?, ?, ?)", viewer, user, this.now());
      else this.#run("DELETE FROM identities WHERE viewer = ? AND slack_user = ?", viewer, user);
      changes.push({ type: "identities", viewer });
    });
  }

  // ── turns ──

  /// Whether the session has had a turn.
  hasTurns(session: string): boolean {
    return this.#one("SELECT EXISTS (SELECT 1 FROM turns WHERE session_key = ?) AS e", session).e !== 0;
  }

  startTurn(id: string, session: string, kind: string): void {
    this.startTurnFor(id, session, kind, { profile: null, person: null, thread: null });
  }

  /// Starts a turn for someone: the person whose message it answers, in that thread, on that profile. A turn nobody's
  /// message started goes on with the work of the one before it, so it is theirs.
  startTurnFor(id: string, session: string, kind: string, by: TurnFor): void {
    this.#with((changes) => {
      const before = (column: string) => `(SELECT ${column} FROM turns WHERE session_key = ?2 AND ${column} IS NOT NULL ORDER BY started_at DESC LIMIT 1)`;
      this.#run(
        `INSERT INTO turns (id, session_key, kind, started_at, profile, person, thread) VALUES (?1, ?2, ?3, ?4, ?5, COALESCE(?6, ${before("person")}), COALESCE(?7, ${before("thread")}))`,
        id, session, kind, this.now(), by.profile, by.person, by.thread,
      );
      changes.push({ type: "session", key: session });
    });
  }

  /// What a turn waits for once it ends as waiting (chat_state waiting `for`), in the agent's words.
  setWaitFor(id: string, what: string): void {
    this.#run("UPDATE turns SET wait_for = ? WHERE id = ?", what, id);
  }

  /// The message a turn's state is about (`about`: thread, entry and ts), or none.
  setAbout(id: string, about: [number, number, string] | null): void {
    const [thread, n, ts] = about ?? [null, null, null];
    this.#run("UPDATE turns SET about_thread = ?, about_n = ?, about_ts = ? WHERE id = ?", thread, n, ts, id);
  }

  /// The last migration note a session was told; 0 for one never told any.
  toldNotes(key: string): number {
    return this.#one("SELECT told_notes FROM sessions WHERE key = ?", key)?.told_notes ?? 0;
  }

  setToldNotes(key: string, n: number): void {
    this.#run("UPDATE sessions SET told_notes = ? WHERE key = ?", n, key);
  }

  /// What a turn needs of a person once it ends as need_help (`need`), in the agent's words.
  setNeed(id: string, what: string): void {
    this.#run("UPDATE turns SET need = ? WHERE id = ?", what, id);
  }

  /// Ends a turn; `waitSeconds` is how long a turn ending as waiting waits at most.
  endTurn(id: string, outcome: string, detail: string | null, declared: string | null, waitSeconds: number | null): void {
    this.#with((changes) => {
      this.#run("UPDATE turns SET ended_at = ?, outcome = ?, detail = ?, declared = ?, wait_seconds = ? WHERE id = ?", this.now(), outcome, detail, declared, waitSeconds, id);
      const r = this.#one("SELECT session_key FROM turns WHERE id = ?", id);
      if (r !== undefined) changes.push({ type: "session", key: r.session_key });
    });
  }

  /// The session was stopped while it waited: its latest turn, if it ended waiting, is recorded as stopped instead
  /// (aborted, no longer waiting). Whether it was.
  stopWait(session: string): boolean {
    return this.#with((changes) => {
      const n = this.#run(
        `UPDATE turns SET outcome = 'aborted', declared = NULL, wait_seconds = NULL, detail = 'other: stopped while waiting'
         WHERE id = (SELECT id FROM turns WHERE session_key = ?1 ORDER BY started_at DESC LIMIT 1) AND declared = 'waiting' AND ended_at IS NOT NULL`,
        session,
      );
      if (n > 0) changes.push({ type: "session", key: session });
      return n > 0;
    });
  }

  /// The session's latest turn.
  lastTurn(session: string): TurnSummary | null {
    const r = this.#one("SELECT * FROM turns WHERE session_key = ? ORDER BY started_at DESC, rowid DESC LIMIT 1", session);
    return r ? toTurnSummary(r) : null;
  }

  listTurns(session: string): TurnRow[] {
    return this.#all("SELECT * FROM turns WHERE session_key = ? ORDER BY started_at", session).map((r) => ({ id: r.id, summary: toTurnSummary(r) }));
  }

  /// Per session (or for one): turn count, the latest turn, undelivered messages and the first one it heard.
  sessionStats(key: string | null): Map<string, SessionStats> {
    const sql = `SELECT s.key,
         (SELECT COUNT(*) FROM turns t WHERE t.session_key = s.key) AS turns,
         (SELECT COUNT(*) FROM deliveries d WHERE d.session = s.key AND d.delivered_at IS NULL) AS pending,
         (SELECT substr(m.text, 1, 300) FROM deliveries d JOIN merged m ON m.thread = d.thread AND m.n = d.n
           WHERE d.session = s.key ORDER BY d.rowid LIMIT 1) AS first_text,
         l.kind, l.outcome, l.declared, l.wait_seconds, l.wait_for, l.need, l.about_thread, l.about_n, l.about_ts, l.detail, l.started_at, l.ended_at
       FROM sessions s
       LEFT JOIN turns l ON l.id = (SELECT id FROM turns t2 WHERE t2.session_key = s.key ORDER BY t2.started_at DESC LIMIT 1)
       ${key !== null ? "WHERE s.key = ?" : ""}`;
    const rows = key !== null ? this.#all(sql, key) : this.#all(sql);
    return new Map(
      rows
        .map((r): [string, SessionStats] => [
          r.key,
          { turns: r.turns, pending: r.pending, firstText: r.first_text, lastTurn: r.started_at === null ? null : toTurnSummary(r) },
        ])
        .sort(([a], [b]) => byBytes(a, b)),
    );
  }

  // ── profile checks and quotas ──

  profileStatus(): Map<string, ProfileStatus> {
    return new Map(
      this.#all("SELECT profile, check_json, quota_json FROM profile_status")
        .map((r): [string, ProfileStatus] => [r.profile, { check: parsed(r.check_json) ?? null, quota: parsed(r.quota_json) ?? null }])
        .sort(([a], [b]) => byBytes(a, b)),
    );
  }

  /// Keeps a profile's check (its `checkedAt` says when).
  setProfileCheck(profile: string, check: Json): void {
    this.#run(
      `INSERT INTO profile_status (profile, check_json, checked_at) VALUES (?, ?, ?)
       ON CONFLICT (profile) DO UPDATE SET check_json = excluded.check_json, checked_at = excluded.checked_at`,
      profile, JSON.stringify(check), checkedAt(check),
    );
  }

  /// Keeps a profile's quota (its `checkedAt` says when).
  setProfileQuota(profile: string, quota: Json): void {
    this.#run(
      `INSERT INTO profile_status (profile, quota_json, quota_at) VALUES (?, ?, ?)
       ON CONFLICT (profile) DO UPDATE SET quota_json = excluded.quota_json, quota_at = excluded.quota_at`,
      profile, JSON.stringify(quota), checkedAt(quota),
    );
  }

  // ── runtime process groups ──

  recordProcess(pgid: number, startedAt: number, runtime: string, label: string): void {
    this.#with((changes) => {
      this.#run("INSERT OR REPLACE INTO processes (pgid, started_at, runtime, label) VALUES (?, ?, ?, ?)", pgid, startedAt, runtime, label);
      changes.push({ type: "processes" });
    });
  }

  forgetProcess(pgid: number): void {
    this.#with((changes) => {
      if (this.#run("DELETE FROM processes WHERE pgid = ?", pgid) > 0) changes.push({ type: "processes" });
    });
  }

  // ── background jobs ──

  insertJob(job: JobRow): void {
    this.#with((changes) => {
      this.#run(
        "INSERT INTO jobs (id, session_key, name, command, cwd, port, token, state, pgid, exit_code, started_at, ended_at, restarts, log, watch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        job.id, job.sessionKey, job.name, job.command, job.cwd, job.port, job.token, job.state, job.pgid, job.exitCode, job.startedAt,
        job.endedAt, job.restarts, job.log, flag(job.watch),
      );
      changes.push({ type: "session", key: job.sessionKey });
      changes.push({ type: "job", id: job.id });
    });
  }

  /// A job started (again): running, in this process group.
  jobStarted(id: string, pgid: number, restarted: boolean): void {
    this.#jobUpdate(id, "UPDATE jobs SET state = 'running', pgid = ?1, exit_code = NULL, ended_at = NULL, restarts = restarts + ?2 WHERE id = ?3", pgid, flag(restarted), id);
  }

  /// A job ended: `state` exited, stopped or failed.
  jobEnded(id: string, state: string, exitCode: number | null): void {
    this.#jobUpdate(id, "UPDATE jobs SET state = ?1, exit_code = ?2, ended_at = ?3, pgid = NULL WHERE id = ?4", state, exitCode, this.now(), id);
  }

  #jobUpdate(id: string, sql: string, ...args: Arg[]): void {
    this.#with((changes) => {
      this.#run(sql, ...args);
      this.#jobChanged(id, changes);
    });
  }

  /// Its session and the job, when the job is there.
  #jobChanged(id: string, changes: Changes): void {
    const r = this.#one("SELECT session_key FROM jobs WHERE id = ?", id);
    if (r !== undefined) {
      changes.push({ type: "session", key: r.session_key });
      changes.push({ type: "job", id });
    }
  }

  getJob(id: string): JobRow | null {
    const r = this.#one("SELECT * FROM jobs WHERE id = ?", id);
    return r ? toJob(r) : null;
  }

  jobByToken(token: string): JobRow | null {
    const r = this.#one("SELECT * FROM jobs WHERE token = ?", token);
    return r ? toJob(r) : null;
  }

  /// A session's jobs (all sessions' with null), newest first.
  listJobs(session: string | null): JobRow[] {
    return this.#all("SELECT * FROM jobs WHERE ?1 IS NULL OR session_key = ?1 ORDER BY started_at DESC", session).map(toJob);
  }

  /// What a job said (`stillfail-job notify`), kept for the pages: a job's latest words are how people see what it is up to.
  addJobNotice(id: string, text: string): void {
    this.#with((changes) => {
      this.#run("INSERT INTO job_notices (job_id, at, text) VALUES (?, ?, ?)", id, this.now(), text);
      // A job keeps its latest words only.
      this.#run(
        "DELETE FROM job_notices WHERE job_id = ?1 AND rowid NOT IN (SELECT rowid FROM job_notices WHERE job_id = ?1 ORDER BY at DESC, rowid DESC LIMIT ?2)",
        id, JOB_NOTICES,
      );
      this.#jobChanged(id, changes);
    });
  }

  /// A session's jobs that are over (stopped, failed, or ended by themselves; a service waiting to start again is not)
  /// taken off its record, with what they said: their ids and logs.
  clearEndedJobs(session: string): [string, string][] {
    return this.#with((changes) => {
      const gone = this.#tx(() => {
        const gone: [string, string][] = this.#all(
          "SELECT id, log FROM jobs WHERE session_key = ? AND (state IN ('stopped', 'failed') OR (state = 'exited' AND port IS NULL))",
          session,
        ).map((r) => [r.id, r.log]);
        for (const [id] of gone) {
          this.#run("DELETE FROM job_notices WHERE job_id = ?", id);
          this.#run("DELETE FROM jobs WHERE id = ?", id);
        }
        return gone;
      });
      if (gone.length > 0) {
        changes.push({ type: "session", key: session });
        for (const [id] of gone) changes.push({ type: "jobRemoved", id, session });
      }
      return gone;
    });
  }

  /// A job's notices, newest first (at most `limit`).
  jobNotices(id: string, limit: number): JobNotice[] {
    return this.#all("SELECT at, text FROM job_notices WHERE job_id = ? ORDER BY at DESC, rowid DESC LIMIT ?", id, limit).map((r) => ({ at: r.at, text: r.text }));
  }

  listProcesses(): ProcessRow[] {
    return this.#all("SELECT * FROM processes").map((r) => ({ pgid: r.pgid, startedAt: r.started_at, runtime: r.runtime, label: r.label }));
  }

  // ── widget states ──

  /// Keeps what a widget in one of the session's messages holds (`state`, JSON) and what of it is for the agent
  /// (`model`). A model other than the one last told is told again.
  putWidgetState(session: string, path: string, state: string, model: string | null): void {
    this.#run(
      `INSERT INTO widget_states (session, path, state, model, updated_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (session, path) DO UPDATE SET state = excluded.state, model = excluded.model, updated_at = excluded.updated_at,
         told_at = CASE WHEN widget_states.model IS excluded.model THEN widget_states.told_at END`,
      session, path, state, model, this.now(),
    );
  }

  widgetState(session: string, path: string): string | null {
    return this.#one("SELECT state FROM widget_states WHERE session = ? AND path = ?", session, path)?.state ?? null;
  }

  /// The session's widget models it has not been told, with where each widget was posted (the latest of its threads'
  /// messages that carry the file).
  untoldWidgetModels(session: string): WidgetModel[] {
    const untold = this.#all("SELECT path, model FROM widget_states WHERE session = ? AND model IS NOT NULL AND told_at IS NULL ORDER BY updated_at, rowid", session);
    return untold.map(({ path, model }) => {
      const found = this.#one(
        `SELECT t.channel, t.thread_ts, json_extract(a.value, '$.name') AS name FROM merged m
         JOIN threads t ON t.id = m.thread JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = ?1, json_each(m.attachments) a
         WHERE m.attachments IS NOT NULL AND json_extract(a.value, '$.path') = ?2 ORDER BY m.created_at DESC LIMIT 1`,
        session, path,
      );
      const base: string = path.split(/[/\\]/).pop() ?? path;
      if (found === undefined) return { path, name: base, thread: null, model };
      const name = typeof found.name === "string" && found.name !== "" ? found.name : base;
      return { path, name, thread: [found.channel, found.thread_ts], model };
    });
  }

  /// The agent was told these (path, model): each is marked told unless its model changed since.
  markWidgetModelsTold(session: string, told: [string, string][]): void {
    const now = this.now();
    for (const [path, model] of told) {
      this.#run("UPDATE widget_states SET told_at = ? WHERE session = ? AND path = ? AND model = ?", now, session, path, model);
    }
  }

  // ── usage (store/usage.rs) ──

  /// Every transcript read for usage so far, by path.
  usageFiles(): Map<string, usage.UsageFile> {
    return usage.usageFiles(this.db);
  }

  /// Records a transcript's calls read up to `file.offset`, each with what it was for; a call recorded before keeps its
  /// row (its output grown, when the transcript wrote it again whole). How many were new.
  recordUsage(path: string, file: usage.UsageFile, runtime: string, calls: [usage.UsageCall, usage.UsageFor][]): number {
    return this.#tx(() => usage.recordUsage(this.db, path, file, runtime, calls));
  }

  /// Tells whoever follows the store that calls were recorded.
  usageChanged(): void {
    this.#send([{ type: "usage" }]);
  }

  /// Sessions whose transcripts may have grown since `since`: a turn running, or ended since then.
  usageActiveSessions(since: number): string[] {
    return usage.usageActiveSessions(this.db, since);
  }

  /// A session's turns, oldest first, each with whom it worked for (store/usage.ts says how).
  usageTurns(session: string): usage.UsageTurn[] {
    return usage.usageTurns(this.db, session);
  }

  /// The calls from `from` until `to` (ms), added up by day in the asker's time zone and by thread, person, profile and
  /// model.
  usageGroups(from: number, to: number, utcOffsetMin: number): usage.UsageGroup[] {
    return usage.usageGroups(this.db, from, to, utcOffsetMin);
  }

  /// The threads usage names, each with the first thing a person said in it (for its title; none where its archive
  /// cannot be read). Those gone are left out.
  usageThreads(ids: number[]): [ThreadRow, string | null][] {
    const out: [ThreadRow, string | null][] = [];
    for (const id of ids) {
      const thread = this.getThread(id);
      if (thread === null) continue;
      let first: string | null = null;
      if (thread.title === null && thread.autoTitle === null) {
        try {
          first = this.#firstText(id);
        } catch {
          // `.ok().flatten()`: an archive that does not read gives none.
        }
      }
      out.push([thread, first]);
    }
    return out;
  }

  /// When the earliest call recorded was made.
  usageSince(): number | null {
    return usage.usageSince(this.db);
  }

  // ── the Task index ──
  //
  // A Task of this station is a chat on its page (surface STILLFAIL_SURFACE); a Slack thread or a Task of another
  // station taken part in here (surface `task`) is not, and has no row. Each Task's row is made again after every write
  // that may change it (Store::with, by what it says changed) and takes the index's next rev only when it reads
  // differently. Its status: archived while the chat is in the archive; else done or cancelled as a person marked it
  // (setTaskStatus; a person writing in it again takes the mark away); else needs_review while a card waits for an
  // answer or its agent's last turn ended finished or needing a person; else in_progress.

  /// The index's epoch, made once with it: another epoch is another index (its reader reads it all again).
  taskIndexEpoch(): string {
    return this.#meta("task_index_epoch") ?? this.#atomically(() => this.#ensureEpoch());
  }

  /// The index's last rev (0 before any).
  taskIndexRev(): number {
    return Number(this.#meta("task_index_rev") ?? 0);
  }

  /// The rows changed after rev `since`, the first `limit` of them by rev: Tasks as they are now, and the tombstones of
  /// those deleted (not yet pruned).
  taskIndexSince(since: number, limit: number): TaskIndexRow[] {
    return this.#all("SELECT thread, rev, removed, json FROM task_index WHERE rev > ? ORDER BY rev LIMIT ?", since, limit).map((r) => ({
      thread: r.thread, rev: r.rev, removed: r.removed !== 0, json: r.json,
    }));
  }

  /// Forgets the tombstones up to rev `through`, once whoever reads the index has them. How many went.
  pruneTaskIndexTombstones(through: number): number {
    return this.#run("DELETE FROM task_index WHERE removed = 1 AND rev <= ?", through);
  }

  /// A Task's status as its row has it; null for a thread that is not a Task of this station.
  taskStatus(thread: number): TaskStatus | null {
    const r = this.#one("SELECT json FROM task_index WHERE thread = ? AND removed = 0", thread);
    return r ? (parsed(r.json)?.status ?? null) : null;
  }

  /// A person marks a Task done or cancelled, or (null) takes the mark away: its status is what its chat shows again.
  /// The status it has then; null for a thread that is not a Task of this station.
  setTaskStatus(thread: number, mark: TaskMark | null): TaskStatus | null {
    if (this.getThread(thread)?.surface !== STILLFAIL_SURFACE) return null;
    this.#with((changes) => {
      this.#atomically(() => {
        this.#indexTask(thread);
        this.#run("UPDATE task_index SET marked = ? WHERE thread = ?", mark, thread);
      });
      // Its row is made again (Store::with) and the chat's readers hear of it.
      changes.push({ type: "thread", id: thread, entries: [] });
    });
    return this.taskStatus(thread);
  }

  /// A person sets a Task's labels (the Group's label ids, as the app has them; at most TASK_LABELS_MAX). The labels it
  /// has then; null for a thread that is not a Task of this station.
  setTaskLabels(thread: number, labels: readonly string[]): string[] | null {
    if (this.getThread(thread)?.surface !== STILLFAIL_SURFACE) return null;
    const kept = [...new Set(labels)].sort();
    this.#with((changes) => {
      this.#atomically(() => {
        this.#indexTask(thread);
        this.#run("UPDATE task_index SET labels = ? WHERE thread = ?", JSON.stringify(kept), thread);
      });
      // Its row is made again (Store::with) and the chat's readers hear of it.
      changes.push({ type: "thread", id: thread, entries: [] });
    });
    return kept;
  }

  #meta(key: string): string | null {
    return this.#one("SELECT value FROM meta WHERE key = ?", key)?.value ?? null;
  }

  #setMeta(key: string, value: string): void {
    this.#run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", key, value);
  }

  #ensureEpoch(): string {
    const epoch = this.#meta("task_index_epoch") ?? randomBytes(16).toString("hex");
    this.#setMeta("task_index_epoch", epoch);
    return epoch;
  }

  /// SAVEPOINT: all of `run` or none of it, inside a transaction under way or on its own.
  #atomically<T>(run: () => T): T {
    this.db.exec("SAVEPOINT task_index");
    try {
      const result = run();
      this.db.exec("RELEASE task_index");
      return result;
    } catch (e) {
      this.db.exec("ROLLBACK TO task_index");
      this.db.exec("RELEASE task_index");
      throw e;
    }
  }

  /// On open: the epoch, made once; a row for every Task (the chats from before the index included), each made again
  /// where it reads differently now; a tombstone for each row whose chat is gone.
  #reconcileTasks(): void {
    this.#atomically(() => {
      this.#ensureEpoch();
      for (const { id } of this.#all("SELECT id FROM threads WHERE surface = ? ORDER BY id", STILLFAIL_SURFACE)) {
        try {
          this.#indexTask(id);
        } catch (e) {
          console.error(`task index: thread ${id}:`, e);
        }
      }
      for (const { thread } of this.#all("SELECT thread FROM task_index WHERE removed = 0 AND thread NOT IN (SELECT id FROM threads)")) {
        this.#dropTask(thread);
      }
    });
  }

  /// After a write (Store::with): the rows of the Tasks it may have changed, made again; those of chats it deleted,
  /// tombstones. A failure is only logged: the write is done, and the row is made again with the next change to it.
  #indexTasks(changes: Changes): void {
    if (changes.length === 0) return;
    try {
      const threads = new Set<number>();
      const removed = new Set<number>();
      for (const c of changes) {
        if (c.type === "thread") threads.add(c.id);
        else if (c.type === "threadRemoved") removed.add(c.id);
        else if (c.type === "session") {
          const ofSession = this.#all("SELECT ts.thread FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? AND t.surface = ?", c.key, STILLFAIL_SURFACE);
          for (const r of ofSession) threads.add(r.thread);
        }
      }
      this.#atomically(() => {
        for (const id of removed) this.#dropTask(id);
        for (const id of threads) if (!removed.has(id)) this.#indexTask(id);
      });
    } catch (e) {
      console.error("task index:", e);
    }
  }

  /// Makes a Task's row again as its chat stands now; a new rev only when it reads differently. Nothing for a thread
  /// that is not a Task.
  #indexTask(id: number): void {
    const t = this.#one("SELECT * FROM threads WHERE id = ?", id);
    if (t === undefined || t.surface !== STILLFAIL_SURFACE) return;
    const prev = this.#one("SELECT rev, json, removed, marked, labels FROM task_index WHERE thread = ?", id);
    const was: Json | undefined = prev !== undefined && prev.removed === 0 ? parsed(prev.json) : undefined;
    const archived = t.archived_at !== null;
    const sessions = this.threadSessions(id).map((m) => m.session);
    // The agent it is with: its own session's (a chat made with one), else the first to join it.
    const key: string | undefined = t.home ?? sessions[0];
    const session = key === undefined ? null : this.getSession(key);
    // Run on another station: as that station's Session was started there (tasks.ts moveTo).
    const elsewhere = this.runsOn(id);
    const started = elsewhere === null ? null : parsed(this.#one("SELECT start FROM task_sessions WHERE thread = ? AND station = ? ORDER BY joined_at DESC LIMIT 1", id, elsewhere)?.start ?? "null");
    const body = {
      task: `${t.channel}/${t.thread_ts}`,
      thread: id,
      title: this.#taskTitle(id, t, archived, was),
      status: elsewhere === null ? this.#deriveTaskStatus(id, archived, prev?.marked ?? null, sessions) : this.#elsewhereStatus(id, archived, prev?.marked ?? null, elsewhere),
      created_by: t.created_by ?? session?.createdBy ?? null,
      created_at: t.created_at,
      last_activity_at: this.#taskActivity(id, t, archived, was),
      runtime: elsewhere === null ? (session?.runtime ?? null) : typeof started?.runtime === "string" ? started.runtime : null,
      model: elsewhere === null ? (session?.model ?? null) : typeof started?.model === "string" ? started.model : null,
      labels: labelsOf(prev?.labels),
    };
    if (was !== undefined && prev.json === JSON.stringify({ ...body, rev: prev.rev })) return;
    const rev = this.#nextTaskRev();
    this.#run(
      `INSERT INTO task_index (thread, rev, json, removed) VALUES (?, ?, ?, 0)
       ON CONFLICT (thread) DO UPDATE SET rev = excluded.rev, json = excluded.json, removed = 0`,
      id, rev, JSON.stringify({ ...body, rev }),
    );
  }

  /// A deleted Task's row becomes its tombstone, at the next rev.
  #dropTask(id: number): void {
    const prev = this.#one("SELECT json FROM task_index WHERE thread = ? AND removed = 0", id);
    if (prev === undefined) return;
    const rev = this.#nextTaskRev();
    const json = JSON.stringify({ task: parsed(prev.json)?.task ?? null, thread: id, removed: true, rev });
    this.#run("UPDATE task_index SET rev = ?, json = ?, removed = 1, marked = NULL, labels = NULL WHERE thread = ?", rev, json, id);
  }

  #nextTaskRev(): number {
    const rev = this.taskIndexRev() + 1;
    this.#setMeta("task_index_rev", String(rev));
    return rev;
  }

  /// What its list calls a Task: the name people or its agent gave it, else the first line a person wrote in it; cut to
  /// TASK_TITLE_MAX characters. An archived chat keeps the one its row had (its words are in its archive file).
  #taskTitle(id: number, t: Json, archived: boolean, was: Json | undefined): string | null {
    const given = [t.title, t.auto_title].filter((s): s is string => typeof s === "string").map((s) => s.trim()).find((s) => s !== "");
    let title: string | null = given ?? null;
    if (title === null) {
      if (archived && was !== undefined) return was.title ?? null;
      let first: string | null = null;
      try {
        first = this.#firstText(id);
      } catch {
        // An archive that does not read: no title from it.
      }
      title = (first ?? "").split("\n").map((line) => line.trim().split(/\s+/).join(" ")).find((l) => l !== "") ?? null;
    }
    return title === null ? null : takeChars(title, TASK_TITLE_MAX).trimEnd();
  }

  /// When something was last said in a Task (its creation before that), moved at most every TASK_ACTIVITY_EVERY_MS: a
  /// message within that of the last move leaves it.
  #taskActivity(id: number, t: Json, archived: boolean, was: Json | undefined): number {
    if (archived && was !== undefined) return was.last_activity_at;
    let last: number | undefined;
    try {
      last = archived
        ? this.#archivedEntries(id).filter((e) => e.kind === "message").at(-1)?.at
        : this.#one("SELECT at FROM entries WHERE thread = ? AND kind = 'message' ORDER BY n DESC LIMIT 1", id)?.at;
    } catch {
      // An archive that does not read: when it went there.
      last = t.archived_at ?? undefined;
    }
    const latest: number = last ?? t.created_at;
    if (was !== undefined && typeof was.last_activity_at === "number" && latest - was.last_activity_at < TASK_ACTIVITY_EVERY_MS) return was.last_activity_at;
    return latest;
  }

  /// A Task's status (the section's head says how), from its chat, its mark and its sessions' latest turns (the
  /// chat_state of `comma tools`' status).
  #deriveTaskStatus(id: number, archived: boolean, marked: string | null, sessions: string[]): TaskStatus {
    if (archived) return "archived";
    if (marked === "done" || marked === "cancelled") return marked;
    const turns = sessions.map((k) => this.lastTurn(k)).filter((x): x is TurnSummary => x !== null);
    if (turns.some((x) => x.endedAt === null)) return "in_progress";
    if (this.pendingCard(id) !== null) return "needs_review";
    const last = turns.sort((a, b) => b.startedAt - a.startedAt)[0];
    return last !== undefined && last.ending !== null && ENDED_FOR_REVIEW.includes(last.ending) ? "needs_review" : "in_progress";
  }

  /// How a Task run on `station` stands, as what it said: done or for review after its Session's last post ended a turn
  /// so and nothing came after it; else at work.
  #elsewhereStatus(id: number, archived: boolean, marked: string | null, station: string): TaskStatus {
    if (archived) return "archived";
    if (marked === "done" || marked === "cancelled") return marked;
    const last = this.#one("SELECT author_kind, author, declared FROM entries WHERE thread = ? AND kind = 'message' ORDER BY n DESC LIMIT 1", id);
    const theirs = last !== undefined && last.author_kind === "agent" && String(last.author).startsWith(`${station}/`);
    return theirs && ENDED_FOR_REVIEW.includes(last.declared) ? "needs_review" : "in_progress";
  }

  // ── Inner ──

  #unreadCount(viewer: string, thread: number, read: number): number {
    const t = this.getThread(thread);
    const slack = t ? t.surface !== STILLFAIL_SURFACE : true;
    const selves = [viewer];
    if (slack) selves.push(...this.slackIdentities(viewer));
    if (this.#isArchived(thread)) {
      return mergeEntries(this.#archivedEntries(thread)).filter((m) => m.n > read && !(m.authorKind === "person" && selves.includes(m.author))).length;
    }
    return this.#one(
      `SELECT COUNT(*) AS c FROM entries WHERE thread = ? AND n > ? AND kind = 'message'
       AND NOT (author_kind = 'person' AND author IN (SELECT value FROM json_each(?)))`,
      thread, read, JSON.stringify(selves),
    ).c;
  }

  /// Everyone who wrote in a thread, as creator references (a Slack user through a connect in it), earliest first.
  #threadPeople(thread: number, surface: string): string[] {
    const connect: string | null = this.#one("SELECT MIN(connect) AS c FROM thread_sessions WHERE thread = ?", thread).c;
    let authors: string[];
    if (this.#isArchived(thread)) {
      const seen = new Set<string>();
      authors = this.#archivedEntries(thread)
        .filter((e) => e.kind === "message" && e.authorKind === "person")
        .map((e) => e.author)
        .filter((a) => !seen.has(a) && (seen.add(a), true));
    } else {
      authors = this.#all(
        "SELECT author, MIN(n) AS first FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' GROUP BY author ORDER BY first",
        thread,
      ).map((r) => r.author);
    }
    if (surface === STILLFAIL_SURFACE) return authors;
    return connect === null ? [] : authors.map((a) => `slack:${connect}:${a}`);
  }

  /// The first thing a person said in it (up to 300 characters).
  #firstText(thread: number): string | null {
    if (this.#isArchived(thread)) {
      const m = mergeEntries(this.#archivedEntries(thread)).find((m) => m.authorKind === "person");
      return m ? takeChars(m.text, 300) : null;
    }
    return this.#one("SELECT substr(text, 1, 300) AS t FROM merged WHERE thread = ? AND author_kind = 'person' ORDER BY n LIMIT 1", thread)?.t ?? null;
  }

  /// The n of the entry with ts `ts` in the thread (a message, or a post of milestones alone); null when none has it.
  #entryAt(thread: number, ts: string): number | null {
    if (this.#isArchived(thread)) return this.#archivedEntries(thread).find((e) => e.ts === ts)?.n ?? null;
    return this.#one("SELECT n FROM entries WHERE thread = ? AND ts = ?", thread, ts)?.n ?? null;
  }

  #messageAt(thread: number, ts: string): MessageRow | null {
    if (this.#isArchived(thread)) return mergeEntries(this.#archivedEntries(thread)).find((m) => m.ts === ts) ?? null;
    const r = this.#one("SELECT * FROM merged WHERE thread = ? AND ts = ?", thread, ts);
    return r ? toMessage(r) : null;
  }

  /// Appends an entry as the thread's next, bringing an archived thread back first.
  #append(entry: EntryRow, changes: Changes): EntryRow {
    if (entry.kind === "message" && entry.authorKind === "agent") {
      const r = this.#one("SELECT model, effort FROM sessions WHERE key = ?", entry.author);
      entry.agentIdentity = r ? { model: r.model, effort: r.effort } : undefined;
    }
    if (this.#isArchived(entry.thread)) this.#restoreThread(entry.thread);
    this.#tx(() => {
      const n: number | null = this.#one("SELECT MAX(n) AS n FROM entries WHERE thread = ?", entry.thread).n;
      entry.n = (n ?? 0) + 1;
      this.#insertEntry(entry);
      // A person writing in a Task they marked done or cancelled takes it up again: its status is what its chat shows
      // from then on. An agent's post (a closing note, say) leaves the mark.
      if (entry.kind === "message" && entry.authorKind === "person") {
        this.#run("UPDATE task_index SET marked = NULL WHERE thread = ? AND marked IS NOT NULL", entry.thread);
      }
    });
    changes.push({ type: "thread", id: entry.thread, entries: [{ ...entry }] });
    this.#bringBack(entry, changes);
    return entry;
  }

  #setArchived(key: string, archived: boolean, by: string, changes: Changes): void {
    const now = this.now();
    this.#tx(() => {
      if (archived) {
        this.#run("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?", now, by, key);
      } else {
        const shown = by === MANUAL ? now : null;
        this.#run("UPDATE sessions SET archived_at = NULL, archived_by = NULL, shown_at = COALESCE(?, shown_at) WHERE key = ?", shown, key);
      }
      this.#run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?", archived ? now : null, archived ? by : null, key);
    });
    for (const t of this.sessionThreads(key)) {
      this.#fileAway(t.thread.id);
      changes.push({ type: "thread", id: t.thread.id, entries: [] });
    }
    changes.push({ type: "session", key });
  }

  #setThreadHidden(thread: number, hidden: boolean, by: string, changes: Changes): void {
    const now = this.now();
    if (hidden) {
      this.#run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE id = ?", now, by, thread);
    } else {
      const shown = by === MANUAL ? now : null;
      this.#run("UPDATE threads SET hidden_at = NULL, hidden_by = NULL, shown_at = COALESCE(?, shown_at) WHERE id = ?", shown, thread);
    }
    this.#fileAway(thread);
    changes.push({ type: "thread", id: thread, entries: [] });
  }

  /// Out of every list: archived itself, or none of its sessions shown.
  #outOfLists(thread: number): boolean {
    const r = this.#one("SELECT hidden_at FROM threads WHERE id = ?", thread);
    if (r === undefined) return false;
    if (r.hidden_at !== null) return true;
    const shown =
      this.#one("SELECT 1 FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ? AND s.archived_at IS NULL LIMIT 1", thread) !== undefined;
    return !shown;
  }

  /// Writes a thread out to its archive file when it went out of lists, or brings it back when it came back.
  #fileAway(thread: number): void {
    const out = this.#outOfLists(thread);
    const filed = this.#isArchived(thread);
    if (out && !filed) this.#archiveThread(thread);
    else if (!out && filed) this.#restoreThread(thread);
  }

  /// Something new said in a thread brings what it is about back into lists: the chat, if it was archived alone, and
  /// the archived sessions that hear it (a person's message goes to every session of the thread) or said it.
  #bringBack(entry: EntryRow, changes: Changes): void {
    if (entry.kind !== "message" || entry.authorKind === "ember") return;
    const thread = this.getThread(entry.thread);
    if (thread === null) return;
    const archived: string[] =
      entry.authorKind === "agent"
        ? this.#all("SELECT key FROM sessions WHERE key = ? AND archived_at IS NOT NULL", entry.author).map((r) => r.key)
        : this.#all("SELECT s.key FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ? AND s.archived_at IS NOT NULL", entry.thread).map((r) => r.key);
    for (const key of archived) this.#setArchived(key, false, AUTO, changes);
    if (thread.hiddenAt !== null && thread.home === null) this.#setThreadHidden(thread.id, false, AUTO, changes);
  }

  // ── archive ──

  #isArchived(thread: number): boolean {
    const r = this.#one("SELECT archived_at FROM threads WHERE id = ?", thread);
    return r !== undefined && r.archived_at !== null;
  }

  #threadFile(thread: number): string {
    return threadFile(this.#archiveDir, thread);
  }

  /// Writes a thread's entries out to its archive file (one entry per line, zstd) and deletes their rows. Entries never
  /// change, so the file is the thread as it was and what clients keep of it stays true.
  #archiveThread(thread: number): void {
    const entries = this.#all("SELECT * FROM entries WHERE thread = ? ORDER BY n", thread).map(toEntry);
    const path = this.#threadFile(thread);
    writeCompressed(path, archiveText(entries));
    try {
      this.#tx(() => {
        this.#run("DELETE FROM entries WHERE thread = ?", thread);
        this.#run("UPDATE threads SET archived_at = ? WHERE id = ?", this.now(), thread);
      });
    } catch (e) {
      rmSync(path, { force: true });
      throw e;
    }
  }

  /// Loads an archived thread's entries back into the database and removes its file.
  #restoreThread(thread: number): void {
    const entries = this.#archivedEntries(thread);
    this.#tx(() => {
      for (const e of entries) this.#insertEntry(e);
      this.#run("UPDATE threads SET archived_at = NULL WHERE id = ?", thread);
    });
    this.#archived = this.#archived.filter(([id]) => id !== thread);
    rmSync(this.#threadFile(thread), { force: true });
  }

  /// An archived thread's entries, from its file.
  #archivedEntries(thread: number): EntryRow[] {
    const at = this.#archived.findIndex(([id]) => id === thread);
    if (at >= 0) {
      const [cached] = this.#archived.splice(at, 1);
      this.#archived.push(cached!);
      return cached![1];
    }
    const entries = readArchive(this.#threadFile(thread));
    if (this.#archived.length >= ARCHIVE_CACHE) this.#archived.shift();
    this.#archived.push([thread, entries]);
    return entries;
  }

  #insertEntry(e: EntryRow): void {
    this.#run(
      "INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, attachments, quotes, declared, client, profile, options, card, at, agent_identity, milestones) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      e.thread, e.n, e.kind, e.target, e.ts, e.authorKind, e.author, e.text,
      jsonList<Attachment>(e.attachments, attachment), jsonList<Quote>(e.quotes, quote),
      e.declared, e.client, e.profile,
      e.options === undefined ? null : JSON.stringify(e.options),
      e.card === undefined ? null : JSON.stringify(e.card),
      e.at,
      e.agentIdentity === undefined ? null : JSON.stringify(e.agentIdentity),
      e.milestones === undefined ? null : JSON.stringify(e.milestones),
    );
  }
}

/// `value.get("checkedAt").and_then(Value::as_i64)`.
function checkedAt(value: Json): number | null {
  const at = value !== null && typeof value === "object" && !Array.isArray(value) ? value.checkedAt : undefined;
  return typeof at === "number" && Number.isInteger(at) ? at : null;
}

/// The most labels a Task carries.
export const TASK_LABELS_MAX = 20;

/// A Task's labels as its row keeps them (a JSON array); none when it has none or they do not read.
function labelsOf(raw: unknown): string[] {
  if (typeof raw !== "string") return [];
  try {
    const value: unknown = JSON.parse(raw);
    return Array.isArray(value) ? value.filter((id): id is string => typeof id === "string") : [];
  } catch {
    return [];
  }
}
