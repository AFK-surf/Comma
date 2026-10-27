// The store's rows (the Rust station's store.rs `// ── rows`), camelCase, and how they are read from and written to the database.
// Option is `T | null`; where the Rust leaves a None Value out (EntryRow's agentIdentity, options, card) it is undefined.
// The conversions are read/store.ts's, with the token fields the station needs (sessions, jobs) kept.

export type Json = any;

/// The page's own threads live on this surface, in this channel (stored under the name of before the rename).
export const STILLFAIL_SURFACE = "ember";
/// Archived by a person.
export const MANUAL = "manual";
/// Archived by the station, for idling (or brought back by something said).
export const AUTO = "auto";
/// SQLite's and Rust's i64::MAX, for "no bound".
export const I64_MAX = 9223372036854775807n;


/// Where a Slack connect's threads live: its team, or the connect itself while the team is unknown.
export function slackSurface(connect: string, teamId: string | null): string {
  return teamId ? `slack:${teamId}` : `slack:${connect}`;
}

export type SessionScope = "thread" | "all";

export type SessionRow = {
  key: string; connect: string; scope: SessionScope; title: string | null; createdBy: string | null; runtime: string;
  profile: string; profilePinned: boolean; model: string | null; effort: string | null; fast: boolean | null;
  runtimeSessionId: string | null; workspace: string; cwd: string | null;
  /// Not for the pages (serde skip).
  token: string;
  running: boolean; createdAt: number; lastActiveAt: number; archivedAt: number | null; archivedBy: string | null;
  shownAt: number | null;
};

/// A runtime session a session ran in, with the runtime it ran (Store::runtimeSessions).
export type RanIn = { id: string; runtime: string };

/// A session as it is first recorded (what NewSession::default leaves out may be left out).
export type NewSession = {
  key: string; connect: string; scope?: SessionScope | null; title?: string | null; createdBy?: string | null;
  runtime: string; profile: string; profilePinned?: boolean; model?: string | null; effort?: string | null;
  fast?: boolean | null; workspace: string; cwd?: string | null; runtimeSessionId?: string | null; token: string;
  createdAt: number; lastActiveAt: number;
};

/// A place people talk: a Slack thread, or a chat on the station's page.
export type ThreadRow = {
  id: number; surface: string; channel: string; threadTs: string; title: string | null; autoTitle: string | null;
  createdBy: string | null; createdAt: number; home: string | null; hiddenAt: number | null; hiddenBy: string | null;
  shownAt: number | null;
};

/// A Task of this station (a chat on its page) as its list shows it: archived (out of lists), else what a person
/// marked it (done, cancelled), else needs_review while its agent says it is finished or needs a person (or a card
/// waits for an answer), else in_progress.
export type TaskStatus = "in_progress" | "needs_review" | "done" | "cancelled" | "archived";
/// What a person marks a Task (PUT /threads/:id/status); in_progress takes the mark away.
export type TaskMark = "done" | "cancelled";

/// One row of the Task index (Store::taskIndexSince): a Task's `json` as of `rev`, or (`removed`) its tombstone.
export type TaskIndexRow = { thread: number; rev: number; removed: boolean; json: string };

/// The name a chat's agent gave it (Store::autoTitle).
export type AutoTitle = { title: string | null; n: number; changes: number };

/// A thread of a session, with the connect the session posts there through.
export type SessionThread = { thread: ThreadRow; connect: string };

/// A session in a thread, and the connect it posts there through.
export type Membership = { thread: number; session: string; connect: string; joinedAt: number };

/// "ember" is the station itself (named, stored and sent as before the rename).
export type AuthorKind = "person" | "agent" | "ember";
/// "milestone": an agent's post that only records milestones (onlyMilestones): no transcript shows it, it is handed to
/// no session and tells no person; a Task's Activity reads it.
export type EntryKind = "message" | "edit" | "milestone";

export type Quote = { author: string; text: string; comment: string; ts?: string; role?: string; file?: string };
export type Attachment = { name: string; path: string; size: number; width?: number; height?: number; thumbhash?: string };

/// One entry of a thread's log (as the archive files hold them, one per line).
export type EntryRow = {
  agentIdentity: Json | undefined; thread: number; n: number; kind: EntryKind; target: number | null; ts: string | null;
  authorKind: AuthorKind; author: string; text: string | null; attachments: Attachment[]; quotes: Quote[];
  declared: string | null; client: string | null; profile: string | null; options: Json | undefined; card: Json | undefined;
  at: number;
  /// The key steps its agent finished (chat_post milestones), in order; none: undefined.
  milestones: string[] | undefined;
};

/// A message as it reads now: its latest edit's words, files and quotes.
export type MessageRow = {
  agentIdentity: Json | null; thread: number; n: number; ts: string; authorKind: AuthorKind; author: string; text: string;
  attachments: Attachment[]; quotes: Quote[]; declared: string | null; client: string | null; createdAt: number;
  editedAt: number | null;
};

/// A card someone answered (`answersSince`).
export type CardAnswer = { question: MessageRow; card: Json; by: string; at: number; answer: MessageRow | null };

/// A message a session has yet to read, with where it was said and how the session hears that thread.
export type PendingMessage = { message: MessageRow; surface: string; channel: string; threadTs: string; connect: string };

/// A thread for listings: who takes part, the last thing said, and how much the viewer has not read.
export type ThreadSummary = {
  thread: ThreadRow; sessions: Membership[]; last: number; lastMessage: MessageRow | null; read: number; unread: number;
  people: string[]; firstText: string | null;
};

/// The message a turn's state is about: its thread, entry (`seq`) and ts.
export type TurnAbout = { thread: number; seq: number; ts: string };

export type TurnSummary = {
  kind: string; outcome: string | null; declared: string | null; ending: string | null; need: string | null;
  about: TurnAbout | null; waitSeconds: number | null; waitFor: string | null; detail: string | null; startedAt: number;
  endedAt: number | null;
};

export type TurnRow = { id: string; summary: TurnSummary };

export type SessionStats = { turns: number; pending: number; firstText: string | null; lastTurn: TurnSummary | null };

/// A profile's last check and quota, kept across restarts.
export type ProfileStatus = { check: Json | null; quota: Json | null };

export type ProcessRow = { pgid: number; startedAt: number; runtime: string; label: string };

/// A message being recorded (NewMessage::new's defaults may be left out).
export type NewMessage = {
  thread: number; ts: string; authorKind: AuthorKind; author: string; text: string; attachments?: Attachment[];
  quotes?: Quote[]; declared?: string | null; client?: string | null; profile?: string | null; card?: Json | null;
  options?: Json | null; at?: number | null; milestones?: string[] | null;
};

/// At most this many milestones in one post, each at most this many characters on one line (the Salix contract's).
export const MAX_MILESTONES = 20;
export const MAX_MILESTONE_CHARS = 80;

/// Milestones as given (chat_post's argument, a Message from another Station): each title on one line (its spaces
/// made one), of 1 to MAX_MILESTONE_CHARS characters, at most MAX_MILESTONES; null for none. Throws what is wrong.
export function milestoneTitles(value: Json): string[] | null {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value)) throw new Error("milestones must be a list of titles");
  if (value.length > MAX_MILESTONES) throw new Error(`a post carries at most ${MAX_MILESTONES} milestones: one per batch when the items are many`);
  const titles = value.map((title) => (typeof title === "string" ? title.split(/\s+/).filter((w) => w !== "").join(" ") : ""));
  if (titles.some((t) => t === "" || Array.from(t).length > MAX_MILESTONE_CHARS)) {
    throw new Error(`each milestone is one line of 1 to ${MAX_MILESTONE_CHARS} characters naming what was finished`);
  }
  return titles.length === 0 ? null : titles;
}

/// A post that only records milestones: no words, files or card. It is kept as a "milestone" entry.
export const onlyMilestones = (m: NewMessage): boolean =>
  (m.milestones?.length ?? 0) > 0 && m.text === "" && (m.attachments?.length ?? 0) === 0 && (m.card ?? null) === null && (m.options ?? null) === null;

export const newMessage = (thread: number, ts: string, authorKind: AuthorKind, author: string, text: string): NewMessage => ({
  thread, ts, authorKind, author, text,
});

/// A background job a session started. `sessionKey` is serde's `session`.
export type JobRow = {
  id: string; sessionKey: string; name: string; command: string; cwd: string; port: number | null;
  /// Not for the pages (serde skip).
  token: string;
  state: string; pgid: number | null; exitCode: number | null; startedAt: number; endedAt: number | null;
  restarts: number; log: string; watch: boolean;
};

export type JobNotice = { at: number; text: string };

/// What a person chose in a widget an agent posted. `thread` is (channel, thread ts) when its message is still there.
export type WidgetModel = { path: string; name: string; thread: [string, string] | null; model: string };

/// Whom a turn works for (Store::startTurnFor).
export type TurnFor = { profile: string | null; person: string | null; thread: number | null };

/// What the store says changed, for whoever follows it (the admin API's /events, the hub).
export type StoreChange =
  /// Anything about that session changed.
  | { type: "session"; key: string }
  /// It was deleted.
  | { type: "sessionRemoved"; key: string }
  /// Entries were appended there (contiguous, in order), or its sessions changed (none).
  | { type: "thread"; id: number; entries: EntryRow[] }
  /// It went, with every entry it had.
  | { type: "threadRemoved"; id: number }
  /// A viewer's read position moved.
  | { type: "read"; viewer: string; thread: number; n: number }
  /// The Slack users a viewer said are them changed.
  | { type: "identities"; viewer: string }
  /// The chats a viewer pinned changed.
  | { type: "pins"; viewer: string }
  /// The decisions a viewer dismissed changed.
  | { type: "dismissed"; viewer: string }
  /// The recorded runtime processes changed.
  | { type: "processes" }
  | { type: "decisionChecks" }
  /// A background job started, started again, ended or said something (its session changes as well).
  | { type: "job"; id: string }
  /// A job that was over was taken off its session's record.
  | { type: "jobRemoved"; id: string; session: string }
  /// Model calls were recorded (store/usage.ts).
  | { type: "usage" };

// ── words ──

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

/// Options to pick from as a card.
export const optionsCard = (options: Json): Json => ({ type: "options", options });

/// EntryRow::card: its own card, else its options as an options card (a post from before cards).
export const cardOfEntry = (e: EntryRow): Json | undefined => e.card ?? (e.options === undefined ? undefined : optionsCard(e.options));

/// `serde_json::from_str::<Value>(..).ok()`: undefined when it does not parse.
export function parsed(text: string | null | undefined): Json | undefined {
  if (text === null || text === undefined) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/// A message's card as kept: its `card` column, else its `options` (from before cards) as an options card.
export function cardOf(card: string | null, options: string | null): Json | undefined {
  const own = parsed(card);
  if (own !== undefined) return own;
  const before = parsed(options);
  return before === undefined ? undefined : optionsCard(before);
}

// serde's reading (and writing) of Attachment and Quote: their fields in their order, unknown ones dropped, a wrong one
// fails the list.
const isObj = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);
const optional = (v: Json, ok: (v: Json) => boolean) => v === undefined || v === null || ok(v);
const isStr = (v: Json) => typeof v === "string";
const isU64 = (v: Json) => typeof v === "number" && Number.isInteger(v) && v >= 0;
const isU32 = (v: Json) => isU64(v) && v <= 0xffffffff;

export function attachment(a: Json): Attachment {
  if (!isObj(a) || !isStr(a.name) || !isStr(a.path) || !isU64(a.size)) throw new Error("attachment");
  if (!optional(a.width, isU32) || !optional(a.height, isU32) || !optional(a.thumbhash, isStr)) throw new Error("attachment");
  const v: Attachment = { name: a.name, path: a.path, size: a.size };
  if (a.width !== undefined && a.width !== null) v.width = a.width;
  if (a.height !== undefined && a.height !== null) v.height = a.height;
  if (a.thumbhash !== undefined && a.thumbhash !== null) v.thumbhash = a.thumbhash;
  return v;
}

export function quote(q: Json): Quote {
  if (!isObj(q) || !isStr(q.author) || !isStr(q.text) || !isStr(q.comment)) throw new Error("quote");
  if (!optional(q.ts, isStr) || !optional(q.role, isStr) || !optional(q.file, isStr)) throw new Error("quote");
  const v: Quote = { author: q.author, text: q.text, comment: q.comment };
  if (q.ts !== undefined && q.ts !== null) v.ts = q.ts;
  if (q.role !== undefined && q.role !== null) v.role = q.role;
  if (q.file !== undefined && q.file !== null) v.file = q.file;
  return v;
}

/// from_json_list: a stored list, or none when it does not read.
function fromJsonList<T>(text: string | null, read: (v: Json) => T): T[] {
  const list = parsed(text);
  if (!Array.isArray(list)) return [];
  try {
    return list.map(read);
  } catch {
    return [];
  }
}

/// json_list: none for an empty list, else the list as serde writes it.
export function jsonList<T>(value: T[], write: (v: Json) => T): string | null {
  return value.length === 0 ? null : JSON.stringify(value.map(write));
}

/// AuthorKind::parse.
export function authorKind(s: string): AuthorKind {
  if (s === "agent") return "agent";
  if (s === "ember" || s === "stillfail") return "ember";
  return "person";
}

export function toSession(r: Json): SessionRow {
  return {
    key: r.key, connect: r.connect, scope: r.scope === "all" ? "all" : "thread", title: r.title, createdBy: r.created_by,
    runtime: r.runtime, profile: r.profile, profilePinned: r.profile_pinned === 1, model: r.model, effort: r.effort,
    fast: r.fast === null || r.fast === undefined ? null : r.fast !== 0, runtimeSessionId: r.runtime_session_id,
    workspace: r.workspace, cwd: r.cwd ?? null, token: r.token, running: r.running === 1, createdAt: r.created_at,
    lastActiveAt: r.last_active_at, archivedAt: r.archived_at, archivedBy: r.archived_by, shownAt: r.shown_at,
  };
}

export function toThread(r: Json): ThreadRow {
  return {
    id: r.id, surface: r.surface, channel: r.channel, threadTs: r.thread_ts, title: r.title, autoTitle: r.auto_title,
    createdBy: r.created_by, createdAt: r.created_at, home: r.home, hiddenAt: r.hidden_at, hiddenBy: r.hidden_by,
    shownAt: r.shown_at,
  };
}

export const toSessionThread = (r: Json): SessionThread => ({ thread: toThread(r), connect: r.connect });

export const toMembership = (r: Json): Membership => ({ thread: r.thread, session: r.session, connect: r.connect, joinedAt: r.joined_at });

export function toEntry(r: Json): EntryRow {
  return {
    agentIdentity: parsed(r.agent_identity), thread: r.thread, n: r.n, kind: entryKind(r.kind),
    target: r.target, ts: r.ts, authorKind: authorKind(r.author_kind), author: r.author, text: r.text,
    attachments: fromJsonList(r.attachments, attachment), quotes: fromJsonList(r.quotes, quote), declared: r.declared,
    client: r.client, profile: r.profile, options: parsed(r.options), card: parsed(r.card), at: r.at,
    milestones: storedMilestones(r.milestones),
  };
}

export const entryKind = (kind: Json): EntryKind => (kind === "edit" ? "edit" : kind === "milestone" ? "milestone" : "message");

/// A stored list of milestones (entries.milestones, an archive file's): undefined for none.
export function storedMilestones(value: Json): string[] | undefined {
  const list = typeof value === "string" ? parsed(value) : value;
  if (!Array.isArray(list)) return undefined;
  const titles = list.filter((t): t is string => typeof t === "string");
  return titles.length === 0 ? undefined : titles;
}

export function toMessage(r: Json): MessageRow {
  return {
    agentIdentity: parsed(r.agent_identity) ?? null, thread: r.thread, n: r.n, ts: r.ts ?? "",
    authorKind: authorKind(r.author_kind), author: r.author, text: r.text ?? "",
    attachments: fromJsonList(r.attachments, attachment), quotes: fromJsonList(r.quotes, quote), declared: r.declared,
    client: r.client, createdAt: r.created_at, editedAt: r.edited_at,
  };
}

/// to_about: all three, or none.
function toAbout(r: Json): TurnAbout | null {
  return r.about_thread !== null && r.about_n !== null && r.about_ts !== null ? { thread: r.about_thread, seq: r.about_n, ts: r.about_ts } : null;
}

/// TurnSummary from a turns row (or session_stats' `l.*`).
export function toTurnSummary(r: Json): TurnSummary {
  return {
    kind: r.kind, outcome: r.outcome, declared: r.declared === null ? null : saidBefore(r.declared),
    ending: r.declared === null ? null : ending(r.declared), need: r.need, about: toAbout(r), waitSeconds: r.wait_seconds,
    waitFor: r.wait_for, detail: r.detail, startedAt: r.started_at, endedAt: r.ended_at,
  };
}

/// TurnSummary as serde writes it: camelCase, the skipped Nones (ending, need, about, waitSeconds, waitFor) left out.
export function turnSummaryJson(t: TurnSummary): Record<string, Json> {
  const v: Record<string, Json> = { kind: t.kind, outcome: t.outcome, declared: t.declared };
  if (t.ending !== null) v.ending = t.ending;
  if (t.need !== null) v.need = t.need;
  if (t.about !== null) v.about = t.about;
  if (t.waitSeconds !== null) v.waitSeconds = t.waitSeconds;
  if (t.waitFor !== null) v.waitFor = t.waitFor;
  v.detail = t.detail;
  v.startedAt = t.startedAt;
  v.endedAt = t.endedAt;
  return v;
}

export function toJob(r: Json): JobRow {
  return {
    id: r.id, sessionKey: r.session_key, name: r.name, command: r.command, cwd: r.cwd, port: r.port, token: r.token,
    state: r.state, pgid: r.pgid, exitCode: r.exit_code, startedAt: r.started_at, endedAt: r.ended_at,
    restarts: r.restarts, log: r.log, watch: r.watch !== 0,
  };
}

/// Entries merged into their messages, as the `merged` view does: for a thread read from its archive file.
export function mergeEntries(entries: EntryRow[]): MessageRow[] {
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

/// Rust's ordering of String keys (a BTreeMap's): by their UTF-8 bytes.
export const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));
