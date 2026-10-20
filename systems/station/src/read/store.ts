// The station's database as the admin API reads it, ported from the Rust station's store.rs: the same SQL over the same
// file (opened read-only), and the same rows. A thread whose sessions are all archived lives in a zstd file under the
// archive directory (`archive/threads/<id>.jsonl.zst` beside the database) and is read from there, as the Rust does.
//
// serde's reading of a stored value is kept where it shows: a list of files or quotes that does not read is none, a
// card or identity that does not parse is none, an archive file that does not read fails the request.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { zstdDecompressSync } from "node:zlib";
import { wall } from "../ops/fibers.ts";

export type Json = any;

/// The page's own threads live on this surface (stored under the name of before the rename).
export const STILLFAIL_SURFACE = "ember";
/// Archived by a person.
export const MANUAL = "manual";
/// Archived threads whose entries are kept decompressed, the most recently read last.
const ARCHIVE_CACHE = 32;
/// SQLite's and Rust's i64::MAX, for "no bound".
export const I64_MAX = 9223372036854775807n;

/// The readers' threads have no clock of their own: the machine's time.
export const nowMs = () => wall.now();

// ---- rows ----

export type AuthorKind = "person" | "agent" | "ember";

export type SessionRow = {
  key: string; connect: string; scope: "thread" | "all"; title: string | null; createdBy: string | null; runtime: string;
  profile: string; profilePinned: boolean; model: string | null; effort: string | null; fast: boolean | null;
  runtimeSessionId: string | null; workspace: string; cwd: string | null; running: boolean; createdAt: number;
  lastActiveAt: number; archivedAt: number | null; archivedBy: string | null; shownAt: number | null;
};

export type ThreadRow = {
  id: number; surface: string; channel: string; threadTs: string; title: string | null; autoTitle: string | null;
  createdBy: string | null; createdAt: number; home: string | null; hiddenAt: number | null; hiddenBy: string | null;
  shownAt: number | null;
};

/// A session in a thread, and the connect it posts there through.
export type Membership = { thread: number; session: string; connect: string; joinedAt: number };

/// One entry of a thread's log. `agentIdentity`, `options` and `card` are undefined where the Rust has None (and
/// leaves them out), and may be null where it has Some(Value::Null).
export type EntryRow = {
  agentIdentity: Json | undefined; thread: number; n: number; kind: "message" | "edit"; target: number | null;
  ts: string | null; authorKind: AuthorKind; author: string; text: string | null; attachments: Json[]; quotes: Json[];
  declared: string | null; client: string | null; profile: string | null; options: Json | undefined; card: Json | undefined;
  at: number;
};

/// A message as it reads now: its latest edit's words, files and quotes.
export type MessageRow = {
  agentIdentity: Json | null; thread: number; n: number; ts: string; authorKind: AuthorKind; author: string; text: string;
  attachments: Json[]; quotes: Json[]; declared: string | null; client: string | null; createdAt: number; editedAt: number | null;
};

/// A card someone answered (`answers_since`).
export type CardAnswer = { question: MessageRow; card: Json; by: string; at: number; answer: MessageRow | null };

/// A thread for listings: who takes part, the last thing said, and how much the viewer has not read.
export type ThreadSummary = {
  thread: ThreadRow; sessions: Membership[]; last: number; lastMessage: MessageRow | null; read: number; unread: number;
  people: string[]; firstText: string | null;
};

/// TurnSummary, as serde writes it (camelCase, the skipped Nones left out).
export type TurnSummary = Record<string, Json>;

export type SessionStats = { turns: number; pending: number; firstText: string | null; lastTurn: TurnSummary | null };

export type JobRow = {
  id: string; sessionKey: string; name: string; command: string; cwd: string; port: number | null; state: string;
  pgid: number | null; exitCode: number | null; startedAt: number; endedAt: number | null; restarts: number; log: string;
  watch: boolean;
};

/// How a turn ended or a post was declared, in the words from before: final, block, waiting.
export function saidBefore(declared: string): string {
  if (declared === "all_done") return "final";
  if (declared === "need_decision" || declared === "need_help") return "block";
  return declared;
}

/// The same in today's words: final is all_done, block and need_decision need_help.
export function ending(declared: string): string {
  if (declared === "final") return "all_done";
  if (declared === "block" || declared === "need_decision") return "need_help";
  return declared;
}

/// AuthorKind::parse.
function authorKind(s: string): AuthorKind {
  if (s === "agent") return "agent";
  if (s === "ember" || s === "stillfail") return "ember";
  return "person";
}

/// Options to pick from as a card.
export const optionsCard = (options: Json): Json => ({ type: "options", options });

/// `serde_json::from_str::<Value>(..).ok()`: undefined when it does not parse.
function parsed(text: string | null): Json | undefined {
  if (text === null || text === undefined) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/// A message's card as kept: its `card` column, else its `options` (from before cards) as an options card.
function cardOf(card: string | null, options: string | null): Json | undefined {
  const own = parsed(card);
  if (own !== undefined) return own;
  const before = parsed(options);
  return before === undefined ? undefined : optionsCard(before);
}

// serde's reading of Attachment and Quote: their fields in their order, unknown ones dropped, a wrong one fails the list.
const isObj = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);
const optional = (v: Json, ok: (v: Json) => boolean) => v === undefined || v === null || ok(v);
const isStr = (v: Json) => typeof v === "string";
const isU64 = (v: Json) => typeof v === "number" && Number.isInteger(v) && v >= 0;
const isU32 = (v: Json) => isU64(v) && v <= 0xffffffff;

function attachment(a: Json): Json {
  if (!isObj(a) || !isStr(a.name) || !isStr(a.path) || !isU64(a.size)) throw new Error("attachment");
  if (!optional(a.width, isU32) || !optional(a.height, isU32) || !optional(a.thumbhash, isStr)) throw new Error("attachment");
  const v: Json = { name: a.name, path: a.path, size: a.size };
  if (a.width !== undefined && a.width !== null) v.width = a.width;
  if (a.height !== undefined && a.height !== null) v.height = a.height;
  if (a.thumbhash !== undefined && a.thumbhash !== null) v.thumbhash = a.thumbhash;
  return v;
}

function quote(q: Json): Json {
  if (!isObj(q) || !isStr(q.author) || !isStr(q.text) || !isStr(q.comment)) throw new Error("quote");
  if (!optional(q.ts, isStr) || !optional(q.role, isStr) || !optional(q.file, isStr)) throw new Error("quote");
  const v: Json = { author: q.author, text: q.text, comment: q.comment };
  if (q.ts !== undefined && q.ts !== null) v.ts = q.ts;
  if (q.role !== undefined && q.role !== null) v.role = q.role;
  if (q.file !== undefined && q.file !== null) v.file = q.file;
  return v;
}

/// from_json_list: a stored list, or none when it does not read.
function fromJsonList(text: string | null, read: (v: Json) => Json): Json[] {
  const list = parsed(text);
  if (!Array.isArray(list)) return [];
  try {
    return list.map(read);
  } catch {
    return [];
  }
}

function toSession(r: Json): SessionRow {
  return {
    key: r.key, connect: r.connect, scope: r.scope === "all" ? "all" : "thread", title: r.title, createdBy: r.created_by,
    runtime: r.runtime, profile: r.profile, profilePinned: r.profile_pinned === 1, model: r.model, effort: r.effort,
    fast: r.fast === null || r.fast === undefined ? null : r.fast !== 0, runtimeSessionId: r.runtime_session_id,
    workspace: r.workspace, cwd: r.cwd ?? null, running: r.running === 1, createdAt: r.created_at,
    lastActiveAt: r.last_active_at, archivedAt: r.archived_at, archivedBy: r.archived_by, shownAt: r.shown_at,
  };
}

function toThread(r: Json): ThreadRow {
  return {
    id: r.id, surface: r.surface, channel: r.channel, threadTs: r.thread_ts, title: r.title, autoTitle: r.auto_title,
    createdBy: r.created_by, createdAt: r.created_at, home: r.home, hiddenAt: r.hidden_at, hiddenBy: r.hidden_by,
    shownAt: r.shown_at,
  };
}

const toMembership = (r: Json): Membership => ({ thread: r.thread, session: r.session, connect: r.connect, joinedAt: r.joined_at });

function toEntry(r: Json): EntryRow {
  return {
    agentIdentity: parsed(r.agent_identity),
    thread: r.thread,
    n: r.n,
    kind: r.kind === "edit" ? "edit" : "message",
    target: r.target,
    ts: r.ts,
    authorKind: authorKind(r.author_kind),
    author: r.author,
    text: r.text,
    attachments: fromJsonList(r.attachments, attachment),
    quotes: fromJsonList(r.quotes, quote),
    declared: r.declared,
    client: r.client,
    profile: r.profile,
    options: parsed(r.options),
    card: parsed(r.card),
    at: r.at,
  };
}

function toMessage(r: Json): MessageRow {
  return {
    agentIdentity: parsed(r.agent_identity) ?? null,
    thread: r.thread,
    n: r.n,
    ts: r.ts ?? "",
    authorKind: authorKind(r.author_kind),
    author: r.author,
    text: r.text ?? "",
    attachments: fromJsonList(r.attachments, attachment),
    quotes: fromJsonList(r.quotes, quote),
    declared: r.declared,
    client: r.client,
    createdAt: r.created_at,
    editedAt: r.edited_at,
  };
}

/// An entry from an archive file, as serde reads EntryRow (null where an Option is: None).
function archivedEntry(e: Json): EntryRow {
  const kind = e.kind;
  if (kind !== "message" && kind !== "edit") throw new Error(`unknown entry kind ${kind}`);
  if (!["person", "agent", "ember", "stillfail"].includes(e.authorKind)) throw new Error(`unknown author kind ${e.authorKind}`);
  const some = (v: Json) => (v === undefined || v === null ? undefined : v);
  return {
    agentIdentity: some(e.agentIdentity), thread: e.thread, n: e.n, kind, target: e.target ?? null, ts: e.ts ?? null,
    authorKind: authorKind(e.authorKind), author: e.author, text: e.text ?? null, attachments: (e.attachments ?? []).map(attachment),
    quotes: (e.quotes ?? []).map(quote), declared: e.declared ?? null, client: e.client ?? null, profile: e.profile ?? null,
    options: some(e.options), card: some(e.card), at: e.at,
  };
}

/// Entries merged into their messages, as the `merged` view does: for a thread read from its archive file.
function mergeEntries(entries: EntryRow[]): MessageRow[] {
  const messages = new Map<number, MessageRow>();
  for (const e of entries) {
    if (e.kind === "message") {
      messages.set(e.n, {
        agentIdentity: e.agentIdentity ?? null, thread: e.thread, n: e.n, ts: e.ts ?? "", authorKind: e.authorKind,
        author: e.author, text: e.text ?? "", attachments: e.attachments, quotes: e.quotes, declared: e.declared,
        client: e.client, createdAt: e.at, editedAt: null,
      });
    } else {
      const m = e.target === null ? undefined : messages.get(e.target);
      if (m) {
        m.text = e.text ?? "";
        m.attachments = e.attachments;
        m.quotes = e.quotes;
        m.editedAt = e.at;
      }
    }
  }
  return [...messages.values()].sort((a, b) => a.n - b.n);
}

/// The first `n` characters (Rust's `chars().take(n)`: code points, not UTF-16 units).
export function takeChars(text: string, n: number): string {
  let out = "";
  let count = 0;
  for (const c of text) {
    if (count++ >= n) break;
    out += c;
  }
  return out;
}

// ---- the store ----

export type Store = {
  db: DatabaseSync;
  /// The station's data directory: stillfail.db, archive/, config.json.
  dataDir: string;
  /// Where archived threads are (`threads/`): `archive/` in the data directory, as Store::open has it by default.
  archiveDir: string;
  /// Entries of archived threads read lately, the most recent last.
  archived: [number, EntryRow[]][];
  /// People's names by email, as their credentials say them (the admin API's `deps.names`, filled as members ask).
  names: Map<string, string>;
  /// What only the hub knows, as it was when the read was asked: each session's process state (`process_state`;
  /// "cold" for one not listed) and the client keys sessions were made with (`client_key`).
  processes: Map<string, string>;
  clientKeys: Map<string, string>;
};

/// The store over an open database, with the data directory its archive is in.
export function makeStore(db: DatabaseSync, dataDir: string): Store {
  return { db, dataDir, archiveDir: join(dataDir, "archive"), archived: [], names: new Map(), processes: new Map(), clientKeys: new Map() };
}

/// A station's store: `<dataDir>/stillfail.db`, opened read-only.
export function openStore(dataDir: string): Store {
  return makeStore(new DatabaseSync(join(dataDir, "stillfail.db"), { readOnly: true, timeout: 5000 }), dataDir);
}

const one = (s: Store, sql: string, ...args: Json[]): Json | undefined => s.db.prepare(sql).get(...args);
const all = (s: Store, sql: string, ...args: Json[]): Json[] => s.db.prepare(sql).all(...args);

// ── sessions ──

export function getSession(s: Store, key: string): SessionRow | null {
  const r = one(s, "SELECT * FROM sessions WHERE key = ?", key);
  return r ? toSession(r) : null;
}

/// Every session, most recently active first.
export function listSessions(s: Store): SessionRow[] {
  return all(s, "SELECT * FROM sessions ORDER BY last_active_at DESC").map(toSession);
}

/// Store::runtimeSessions: the runtime sessions a session has run in, the first first, ending with its current one.
export function runtimeSessions(s: Store, key: string): string[] {
  const current = getSession(s, key)?.runtimeSessionId ?? null;
  let ids: string[] = [];
  try {
    ids = all(s, "SELECT id FROM runtime_sessions WHERE session_key = ? ORDER BY at, rowid", key).map((r) => r.id);
  } catch {} // a database no station of this version has opened yet
  return current === null ? ids : [...ids.filter((id) => id !== current), current];
}

// ── threads ──

export function getThread(s: Store, id: number): ThreadRow | null {
  const r = one(s, "SELECT * FROM threads WHERE id = ?", id);
  return r ? toThread(r) : null;
}

/// The threads a session is in, the one it joined last first (store.rs session_threads).
export function sessionThreads(s: Store, session: string): ThreadRow[] {
  return all(s, "SELECT t.* FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? ORDER BY ts.joined_at DESC, ts.rowid DESC", session).map(toThread);
}

export function threadSessions(s: Store, thread: number): Membership[] {
  return all(s, "SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", thread).map(toMembership);
}

/// Threads with their sessions, last entry, latest message and the viewer's unread count, most recently said in
/// first: those of one session, one thread, or all.
export function listThreads(s: Store, viewer: string, session: string | null, thread: number | null): ThreadSummary[] {
  const base = "SELECT t.*, COALESCE(r.n, 0) AS read_n FROM threads t LEFT JOIN reads r ON r.thread = t.id AND r.viewer = ?1";
  const rows: Json[] =
    thread !== null
      ? all(s, `${base} WHERE t.id = ?2`, viewer, thread)
      : session !== null
        ? all(s, `${base} WHERE t.id IN (SELECT thread FROM thread_sessions WHERE session = ?2)`, viewer, session)
        : all(s, base, viewer);
  const summaries: ThreadSummary[] = rows.map((r) => {
    const t = toThread(r);
    const read: number = r.read_n;
    return {
      sessions: threadSessions(s, t.id),
      last: lastEntry(s, t.id),
      lastMessage: lastMessage(s, t.id),
      read,
      unread: unreadCount(s, viewer, t.id, read),
      people: threadPeople(s, t.id, t.surface),
      firstText: firstText(s, t.id),
      thread: t,
    };
  });
  const said = (t: ThreadSummary) => t.lastMessage?.createdAt ?? 0;
  summaries.sort((a, b) => said(b) - said(a) || b.thread.createdAt - a.thread.createdAt || b.thread.id - a.thread.id);
  return summaries;
}

/// The thread's latest message as merged, for lists.
export function lastMessage(s: Store, thread: number): MessageRow | null {
  if (isArchived(s, thread)) return mergeEntries(archivedEntries(s, thread)).pop() ?? null;
  const r = one(s, "SELECT * FROM merged WHERE thread = ? ORDER BY n DESC LIMIT 1", thread);
  return r ? toMessage(r) : null;
}

/// Messages after the read position that are not the viewer's own (nor of a Slack user they are).
function unreadCount(s: Store, viewer: string, thread: number, read: number): number {
  const t = getThread(s, thread);
  const slack = t ? t.surface !== STILLFAIL_SURFACE : true;
  const selves = [viewer];
  if (slack) selves.push(...slackIdentities(s, viewer));
  if (isArchived(s, thread)) {
    return mergeEntries(archivedEntries(s, thread)).filter((m) => m.n > read && !(m.authorKind === "person" && selves.includes(m.author))).length;
  }
  return one(
    s,
    `SELECT COUNT(*) AS c FROM entries WHERE thread = ? AND n > ? AND kind = 'message'
     AND NOT (author_kind = 'person' AND author IN (SELECT value FROM json_each(?)))`,
    thread,
    read,
    JSON.stringify(selves),
  ).c;
}

/// Everyone who wrote in a thread, as creator references (a Slack user through a connect in it), earliest first.
function threadPeople(s: Store, thread: number, surface: string): string[] {
  const connect: string | null = one(s, "SELECT MIN(connect) AS c FROM thread_sessions WHERE thread = ?", thread).c;
  let authors: string[];
  if (isArchived(s, thread)) {
    const seen = new Set<string>();
    authors = archivedEntries(s, thread)
      .filter((e) => e.kind === "message" && e.authorKind === "person")
      .map((e) => e.author)
      .filter((a) => !seen.has(a) && (seen.add(a), true));
  } else {
    authors = all(
      s,
      "SELECT author, MIN(n) AS first FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' GROUP BY author ORDER BY first",
      thread,
    ).map((r) => r.author);
  }
  if (surface === STILLFAIL_SURFACE) return authors;
  return connect === null ? [] : authors.map((a) => `slack:${connect}:${a}`);
}

/// The first thing a person said in it (up to 300 characters).
function firstText(s: Store, thread: number): string | null {
  if (isArchived(s, thread)) {
    const m = mergeEntries(archivedEntries(s, thread)).find((m) => m.authorKind === "person");
    return m ? takeChars(m.text, 300) : null;
  }
  const r = one(s, "SELECT substr(text, 1, 300) AS t FROM merged WHERE thread = ? AND author_kind = 'person' ORDER BY n LIMIT 1", thread);
  return r ? r.t : null;
}

// ── entries ──

/// The thread's last entry number, 0 before anything is said.
export function lastEntry(s: Store, thread: number): number {
  if (isArchived(s, thread)) return archivedEntries(s, thread).at(-1)?.n ?? 0;
  return one(s, "SELECT MAX(n) AS n FROM entries WHERE thread = ?", thread).n ?? 0;
}

/// Entries after n: what came since (`n + 1` wraps at i64::MAX, as a release build's does).
export function entriesAfter(s: Store, thread: number, n: bigint): EntryRow[] {
  return entriesBetween(s, thread, BigInt.asIntN(64, n + 1n), I64_MAX);
}

/// The latest `limit` entries before n (the latest of all without it), oldest first.
export function entriesBefore(s: Store, thread: number, n: bigint | null, limit: number): EntryRow[] {
  const before = n ?? I64_MAX;
  if (isArchived(s, thread)) {
    const entries = archivedEntries(s, thread).filter((e) => e.n < before);
    return entries.slice(Math.max(0, entries.length - limit));
  }
  return all(s, "SELECT * FROM entries WHERE thread = ? AND n < ? ORDER BY n DESC LIMIT ?", thread, before, limit).map(toEntry).reverse();
}

/// Entries from n = `from` to n = `to`, both included: a gap.
export function entriesBetween(s: Store, thread: number, from: bigint, to: bigint): EntryRow[] {
  if (isArchived(s, thread)) return archivedEntries(s, thread).filter((e) => e.n >= from && e.n <= to);
  return all(s, "SELECT * FROM entries WHERE thread = ? AND n >= ? AND n <= ? ORDER BY n", thread, from, to).map(toEntry);
}

/// The latest `limit` messages before n (the latest of all without it), as merged, oldest first.
export function messagesBefore(s: Store, thread: number, n: number | null, limit: number): MessageRow[] {
  const before = n ?? I64_MAX;
  if (isArchived(s, thread)) {
    const messages = mergeEntries(archivedEntries(s, thread)).filter((m) => m.n < before);
    return messages.slice(Math.max(0, messages.length - limit));
  }
  return all(s, "SELECT * FROM merged WHERE thread = ? AND n < ? ORDER BY n DESC LIMIT ?", thread, before, limit).map(toMessage).reverse();
}

// ── the archive review ──

/// Whether the decision recommended the thread for the archive as it stands now (its last entry then is its last now).
export function archiveSuggested(s: Store, thread: number): boolean {
  const version = one(s, "SELECT version FROM archive_suggestions WHERE thread = ?", thread)?.version ?? null;
  return version !== null && version === lastEntry(s, thread);
}

/// What the latest review found for the thread, while it stands as it was then: the option picked (`option`, `name`,
/// `archive`) or the failure (`error`), and when.
export function archiveVerdict(s: Store, thread: number): Json | null {
  const r = one(s, "SELECT version, at, verdict FROM archive_verdicts WHERE thread = ?", thread);
  if (!r || r.version !== lastEntry(s, thread)) return null;
  const v = parsed(r.verdict);
  return v && typeof v === "object" ? { ...v, at: r.at } : null;
}

// ── pins, kept chats ──

/// The chats a viewer pinned (by their session's key), with when.
export function pins(s: Store, viewer: string): Map<string, number> {
  return new Map(all(s, "SELECT session, at FROM pins WHERE viewer = ?", viewer).map((r) => [r.session, r.at]));
}

/// Chats kept instead of offered for archiving. Null selects every viewer.
export function keptChats(s: Store, viewer: string | null): Set<number> {
  return new Set(all(s, "SELECT DISTINCT thread FROM kept_chats WHERE ?1 IS NULL OR viewer = ?1", viewer).map((r) => r.thread));
}

// ── cards ──

/// The thread's card still pending, if any: its latest post with a card, as long as no person has written in the
/// thread since (nor was it closed). The post as merged, and its card.
export function pendingCard(s: Store, thread: number): [MessageRow, Json] | null {
  if (isArchived(s, thread)) return null;
  // The latest of each kind (cards, and options from before cards), each read by its own index.
  const latest = (column: string): Json | undefined =>
    one(s, `SELECT n, card, options FROM entries WHERE thread = ? AND kind = 'message' AND ${column} IS NOT NULL ORDER BY n DESC LIMIT 1`, thread);
  const a = latest("card");
  const b = latest("options");
  const asked = a && b ? (a.n >= b.n ? a : b) : (a ?? b);
  if (!asked) return null;
  const n: number = asked.n;
  const answered = one(s, "SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ? LIMIT 1", thread, n) !== undefined;
  const closed = one(s, "SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, n) !== undefined;
  if (answered || closed) return null;
  const card = cardOf(asked.card, asked.options);
  if (card === undefined) return null;
  const m = one(s, "SELECT * FROM merged WHERE thread = ? AND n = ?", thread, n);
  return m ? [toMessage(m), card] : null;
}

/// The message an agent's need without a card asks with, while no person has written after it: the one its turn is
/// about (`about`), else the agent's latest message during the turn; with the two messages before it.
export function askingMessage(s: Store, thread: number, about: number | null, during: [number, number | bigint]): [MessageRow, MessageRow[]] | null {
  if (isArchived(s, thread)) return null;
  const n: number | null =
    about ?? one(s, "SELECT max(n) AS n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND at >= ? AND at <= ?", thread, during[0], during[1]).n;
  if (n === null) return null;
  const answered = one(s, "SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ? LIMIT 1", thread, n) !== undefined;
  // A post with a card is pending_card's: one no longer pending was answered, closed or withdrawn.
  const carded = one(s, "SELECT 1 FROM entries WHERE thread = ? AND n = ? AND (card IS NOT NULL OR options IS NOT NULL)", thread, n) !== undefined;
  if (answered || carded) return null;
  const messages = messagesBefore(s, thread, n + 1, 3);
  const m = messages.pop();
  return m && m.n === n && m.authorKind === "agent" ? [m, messages] : null;
}

/// The cards answered since `since` (ms), whoever answered them: each a person's first message after a card, or a
/// choice that closed it (closed_cards, by a person: not its agent withdrawing it).
export function answersSince(s: Store, since: number): CardAnswer[] {
  const out: CardAnswer[] = [];
  const said = all(s, "SELECT thread, n FROM entries WHERE author_kind = 'person' AND kind = 'message' AND at >= ?", since);
  const askedBefore = (thread: number, n: number): number | null => {
    const card: number | null = one(s, "SELECT max(n) AS n FROM entries WHERE thread = ? AND n < ? AND kind = 'message' AND card IS NOT NULL", thread, n).n;
    const options: number | null = one(s, "SELECT max(n) AS n FROM entries WHERE thread = ? AND n < ? AND kind = 'message' AND options IS NOT NULL", thread, n).n;
    // Option's max: None below any Some.
    return card === null ? options : options === null ? card : Math.max(card, options);
  };
  const cardAt = (thread: number, n: number): [MessageRow, Json] | null => {
    const row = one(s, "SELECT card, options FROM entries WHERE thread = ? AND n = ?", thread, n);
    const card = row ? cardOf(row.card, row.options) : undefined;
    if (card === undefined) return null;
    const m = one(s, "SELECT * FROM merged WHERE thread = ? AND n = ?", thread, n);
    return m ? [toMessage(m), card] : null;
  };
  for (const { thread, n } of said) {
    const asked = askedBefore(thread, n);
    if (asked === null) continue;
    // Only the first word after it answers it; one closed (by a choice or withdrawn) was answered then.
    const earlier = one(s, "SELECT 1 FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' AND n > ? AND n < ? LIMIT 1", thread, asked, n) !== undefined;
    const closed = one(s, "SELECT 1 FROM closed_cards WHERE thread = ? AND n = ?", thread, asked) !== undefined;
    if (earlier || closed) continue;
    const found = cardAt(thread, asked);
    if (!found) continue;
    const answer = one(s, "SELECT * FROM merged WHERE thread = ? AND n = ?", thread, n);
    if (!answer) continue;
    const a = toMessage(answer);
    out.push({ question: found[0], card: found[1], by: a.author, at: a.createdAt, answer: a });
  }
  for (const { thread, n, viewer: by, at } of all(s, "SELECT thread, n, viewer, at FROM closed_cards WHERE at >= ?", since)) {
    const found = cardAt(thread, n);
    if (!found) continue;
    // Withdrawn by its own agent: no one answered it.
    if (found[0].author === by) continue;
    out.push({ question: found[0], card: found[1], by, at, answer: null });
  }
  return out;
}

/// The cards a viewer dismissed, as "thread:n".
export function dismissed(s: Store, viewer: string): Set<string> {
  return new Set(all(s, "SELECT thread, n FROM dismissed WHERE viewer = ?", viewer).map((r) => `${r.thread}:${r.n}`));
}

// ── identities ──

/// The Slack users a viewer said are them: their messages are the viewer's own.
export function slackIdentities(s: Store, viewer: string): string[] {
  return all(s, "SELECT slack_user FROM identities WHERE viewer = ? ORDER BY at", viewer).map((r) => r.slack_user);
}

// ── turns ──

/// TurnSummary from a turns row (or session_stats' `l.*`), as serde writes it.
function turnSummary(r: Json, startedAt: number): TurnSummary {
  const v: TurnSummary = {
    kind: r.kind,
    outcome: r.outcome,
    declared: r.declared === null ? null : saidBefore(r.declared),
  };
  if (r.declared !== null) v.ending = ending(r.declared);
  if (r.need !== null) v.need = r.need;
  if (r.about_thread !== null && r.about_n !== null && r.about_ts !== null) v.about = { thread: r.about_thread, seq: r.about_n, ts: r.about_ts };
  if (r.wait_seconds !== null) v.waitSeconds = r.wait_seconds;
  if (r.wait_for !== null) v.waitFor = r.wait_for;
  v.detail = r.detail;
  v.startedAt = startedAt;
  v.endedAt = r.ended_at;
  return v;
}

/// Per session (or for one): turn count, the latest turn, undelivered messages and the first one it heard.
export function sessionStats(s: Store, key: string | null): Map<string, SessionStats> {
  const sql = `SELECT s.key,
       (SELECT COUNT(*) FROM turns t WHERE t.session_key = s.key) AS turns,
       (SELECT COUNT(*) FROM deliveries d WHERE d.session = s.key AND d.delivered_at IS NULL) AS pending,
       (SELECT substr(m.text, 1, 300) FROM deliveries d JOIN merged m ON m.thread = d.thread AND m.n = d.n
         WHERE d.session = s.key ORDER BY d.rowid LIMIT 1) AS first_text,
       l.kind, l.outcome, l.declared, l.wait_seconds, l.wait_for, l.need, l.about_thread, l.about_n, l.about_ts, l.detail, l.started_at, l.ended_at
     FROM sessions s
     LEFT JOIN turns l ON l.id = (SELECT id FROM turns t2 WHERE t2.session_key = s.key ORDER BY t2.started_at DESC LIMIT 1)
     ${key !== null ? "WHERE s.key = ?" : ""}`;
  const rows = key !== null ? all(s, sql, key) : all(s, sql);
  return new Map(
    rows.map((r) => [
      r.key as string,
      { turns: r.turns, pending: r.pending, firstText: r.first_text, lastTurn: r.started_at === null ? null : turnSummary(r, r.started_at) },
    ]),
  );
}

// ── jobs ──

const toJob = (r: Json): JobRow => ({
  id: r.id, sessionKey: r.session_key, name: r.name, command: r.command, cwd: r.cwd, port: r.port, state: r.state,
  pgid: r.pgid, exitCode: r.exit_code, startedAt: r.started_at, endedAt: r.ended_at, restarts: r.restarts, log: r.log,
  watch: r.watch !== 0,
});

/// A session's jobs (all sessions' with null), newest first.
export function listJobs(s: Store, session: string | null): JobRow[] {
  return all(s, "SELECT * FROM jobs WHERE ?1 IS NULL OR session_key = ?1 ORDER BY started_at DESC", session).map(toJob);
}

/// A job's notices, newest first (at most `limit`).
export function jobNotices(s: Store, id: string, limit: number): { at: number; text: string }[] {
  return all(s, "SELECT at, text FROM job_notices WHERE job_id = ? ORDER BY at DESC, rowid DESC LIMIT ?", id, limit).map((r) => ({ at: r.at, text: r.text }));
}

/// jobs.rs `watching`: the sessions keeping watch (a watch job running), each with its watches' names, since when, and
/// when one last said something.
export function watching(s: Store): Map<string, Json> {
  const by = new Map<string, JobRow[]>();
  for (const job of listJobs(s, null).filter((j) => j.watch && j.state === "running")) {
    by.set(job.sessionKey, [...(by.get(job.sessionKey) ?? []), job]);
  }
  const out = new Map<string, Json>();
  for (const [key, jobs] of by) {
    jobs.sort((a, b) => a.startedAt - b.startedAt);
    const at = Math.max(...jobs.map((j) => Math.max(jobNotices(s, j.id, 1)[0]?.at ?? j.startedAt, j.startedAt)));
    out.set(key, { names: jobs.map((j) => j.name), since: jobs[0]!.startedAt, at });
  }
  return out;
}

// ── archive ──

export function isArchived(s: Store, thread: number): boolean {
  const r = one(s, "SELECT archived_at FROM threads WHERE id = ?", thread);
  return r !== undefined && r.archived_at !== null;
}

function threadFile(s: Store, thread: number): string {
  return join(s.archiveDir, "threads", `${thread}.jsonl.zst`);
}

/// An archived thread's entries, from its file.
export function archivedEntries(s: Store, thread: number): EntryRow[] {
  const at = s.archived.findIndex(([id]) => id === thread);
  if (at >= 0) {
    const [cached] = s.archived.splice(at, 1);
    s.archived.push(cached!);
    return cached![1];
  }
  const path = threadFile(s, thread);
  // As anyhow shows std::fs::read failing.
  if (!existsSync(path)) throw new Error("No such file or directory (os error 2)");
  const text = zstdDecompressSync(readFileSync(path)).toString("utf8");
  const entries = text
    .split("\n")
    .map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l))
    .filter((l) => l !== "")
    .map((l) => archivedEntry(JSON.parse(l)));
  if (s.archived.length >= ARCHIVE_CACHE) s.archived.shift();
  s.archived.push([thread, entries]);
  return entries;
}

// ── usage (store/usage.rs) ──

/// The calls of one day (in the asker's time zone) for one thread, person, profile and model, added up (UsageGroup).
export type UsageGroup = {
  day: string; session: string; thread: number | null; person: string | null; profile: string | null; runtime: string;
  model: string | null; fast: boolean; calls: number; input: number; cacheRead: number; cacheWrite: number;
  cacheWriteLong: number; output: number;
};

/// usage_groups: the calls from `from` until `to` (ms), added up by day in the asker's time zone (`utcOffsetMin`) and by
/// thread, person, profile and model. Bounds are i64s (bigint), bound as integers as rusqlite binds them.
export function usageGroups(s: Store, from: bigint, to: bigint, utcOffsetMin: bigint): UsageGroup[] {
  return all(
    s,
    `SELECT strftime('%Y-%m-%d', (at + ?3 * 60000) / 1000, 'unixepoch') AS day, session, thread, person, profile, runtime, model, fast,
       COUNT(*) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read, SUM(cache_write) AS cache_write,
       SUM(cache_write_long) AS cache_write_long, SUM(output) AS output
     FROM usage WHERE at >= ?1 AND at < ?2
     GROUP BY day, session, thread, person, profile, runtime, model, fast`,
    from,
    to,
    utcOffsetMin,
  ).map((r) => ({
    day: r.day, session: r.session, thread: r.thread, person: r.person, profile: r.profile, runtime: r.runtime, model: r.model,
    fast: r.fast !== 0 && r.fast !== null, calls: r.calls, input: r.input, cacheRead: r.cache_read, cacheWrite: r.cache_write,
    cacheWriteLong: r.cache_write_long, output: r.output,
  }));
}

/// usage_threads: the threads usage names, each with the first thing a person said in it (for its title; none where
/// its archive cannot be read). Those gone are left out.
export function usageThreads(s: Store, ids: number[]): [ThreadRow, string | null][] {
  const out: [ThreadRow, string | null][] = [];
  for (const id of ids) {
    const thread = getThread(s, id);
    if (thread === null) continue;
    let first: string | null = null;
    if (thread.title === null && thread.autoTitle === null) {
      try {
        first = firstText(s, id);
      } catch {
        // `.ok().flatten()`: an archive that does not read gives none.
      }
    }
    out.push([thread, first]);
  }
  return out;
}

/// usage_since: when the earliest call recorded was made.
export function usageSince(s: Store): number | null {
  return one(s, "SELECT MIN(at) AS at FROM usage").at ?? null;
}

// ── what the session and job reads add (admin/views.rs sessions, session, threads; jobs.rs) ──

/// Rust's ordering of String keys (a BTreeMap's): by their UTF-8 bytes.
export const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

/// Store::list_bindings: the connects bound to each session.
export function listBindings(s: Store): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const r of all(s, "SELECT connect, session_key FROM bindings")) out.set(r.session_key, [...(out.get(r.session_key) ?? []), r.connect]);
  return out;
}

/// Store::participants: everyone who wrote in each session's threads (or one session's), as creator references,
/// earliest first; a session no one wrote to has none.
export function participants(s: Store, session: string | null): Map<string, string[]> {
  const sql = `SELECT ts.session, ts.connect, t.id, t.surface, t.archived_at FROM thread_sessions ts JOIN threads t ON t.id = ts.thread ${session !== null ? "WHERE ts.session = ?" : ""}`;
  const rows = session !== null ? all(s, sql, session) : all(s, sql);
  // Each person once per session, at the first time they wrote in any of its threads.
  const firsts = new Map<string, Map<string, number>>();
  for (const r of rows) {
    const authors: [string, number][] =
      r.archived_at !== null
        ? archivedEntries(s, r.id).filter((e) => e.kind === "message" && e.authorKind === "person").map((e) => [e.author, e.at])
        : all(s, "SELECT author, MIN(at) AS at FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'person' GROUP BY author", r.id).map((a) => [a.author, a.at]);
    const refs = firsts.get(r.session) ?? new Map<string, number>();
    firsts.set(r.session, refs);
    for (const [author, at] of authors) {
      const reference = r.surface === STILLFAIL_SURFACE ? author : `slack:${r.connect}:${author}`;
      const first = refs.get(reference);
      if (first === undefined || at < first) refs.set(reference, at);
    }
  }
  const out = new Map<string, string[]>();
  for (const [key, refs] of firsts) {
    if (refs.size === 0) continue;
    // In the BTreeMap's order, then (stably) by when.
    const sorted = [...refs].sort(([a], [b]) => byBytes(a, b)).sort(([, a], [, b]) => a - b);
    out.set(key, sorted.map(([r]) => r));
  }
  return out;
}

/// Store::list_turns: a session's turns, oldest first, each its summary and id (as views.rs `session` shows them).
export function listTurns(s: Store, session: string): Json[] {
  return all(s, "SELECT * FROM turns WHERE session_key = ? ORDER BY started_at", session).map((r) => ({ ...turnSummary(r, r.started_at), id: r.id }));
}

export function getJob(s: Store, id: string): JobRow | null {
  const r = one(s, "SELECT * FROM jobs WHERE id = ?", id);
  return r ? toJob(r) : null;
}

/// Store::widget_state: what a widget in one of the session's messages holds, as kept (JSON text).
export function widgetState(s: Store, session: string, path: string): string | null {
  const r = one(s, "SELECT state FROM widget_states WHERE session = ? AND path = ?", session, path);
  return r ? r.state : null;
}
