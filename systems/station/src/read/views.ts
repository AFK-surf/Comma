// What the pages read: the sidebar (GET /chats) and thread entries (GET /threads/:id/entries), ported from
// the Rust station's admin/views.rs with the same JSON, field for field and in serde_json's order (preserve_order).
//
// What the Rust station keeps outside the database is taken as a station with none of it has it:
// - the hub: no session has a runtime process (`process_state` "cold"), no client keys (`client_key` none);
// - Slack connections: none connected, so no workspace or channel names (`known_channel`) and no Slack people
//   (`known_person`): a Slack user goes by their id, with no email;
// - the cloud's names (`deps.names`): those of the members who asked since the station started (`Store.names`);
// - the config's connects are read from config.json in the data directory for the names
//   agents go by; none when it has none.
// Words are in the language the request asks in (`stillfail-lang`, else Accept-Language, else Chinese).
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { Viewer } from "../mesh/credential.ts";
import { type Lang, tr as translate } from "../ops/i18n.ts";
import * as store from "./store.ts";

export { makeStore, openStore } from "./store.ts";
import { knownChannel, knownPerson, slackCreator, teamName } from "./slack-known.ts";
import { type AuthorKind, type EntryRow, type Json, type MessageRow, type Store, type ThreadRow, type ThreadSummary, STILLFAIL_SURFACE, takeChars } from "./store.ts";

/// How much of a chat's last message the sidebar gets.
const LAST_CHARS = 200;
/// How far back a row says which cards the viewer answered in it: a day and a half.
const ANSWERED_WITHIN = 36 * 3600 * 1000;
/// The connect of the station's own chats (chat/internal.rs).
const INTERNAL_CONNECT = "ember";

/// An error with the status the admin API answers it with (admin/mod.rs `http_error`).
export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

// ---- words, in the language of the request (`spoken()`) ----

/// The language the request being answered asks in (one request at a time in a worker).
let spokenLang: Lang = "zh";
export const setSpoken = (lang: Lang) => (spokenLang = lang);
const tr = (key: string, args: Record<string, string> = {}) => translate(spokenLang, key, args);

/// What a chat with nothing to be called by is called.
export const noWords = () => tr("station.chat.noWords");

// ---- Rust's whitespace (char::is_whitespace), for trim and split_whitespace ----

const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const TRIM = new RegExp(`^[${WS}]+|[${WS}]+$`, "g");
const SPLIT = new RegExp(`[${WS}]+`);
const trim = (s: string) => s.replace(TRIM, "");
const splitWhitespace = (s: string) => s.split(SPLIT).filter((w) => w !== "");

// ---- the station's config: its connects' names, and whether the archive review is on ----

type Connect = { id: string; name: string };
type Config = { connects: Connect[]; reviews: boolean };
const configs = new WeakMap<Store, { stamp: string } & Config>();

/// The config's connects (config.rs), each with what it is called (Connect::name: its bot's name, else its id), and
/// whether the decision reviews done chats for the archive (automaticDecisions.completion); read again when config.json
/// changed.
function configOf(s: Store): Config {
  const path = join(s.dataDir, "config.json");
  let stamp = "none";
  try {
    const st = statSync(path);
    stamp = `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch {}
  const had = configs.get(s);
  if (had && had.stamp === stamp) return had;
  const connects: Connect[] = [];
  let reviews = false;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    reviews = raw?.automaticDecisions?.completion?.enabled === true;
    for (const c of Array.isArray(raw.connects) ? raw.connects : []) {
      const bot = typeof c?.slack?.botName === "string" && c.slack.botName !== "" ? c.slack.botName : undefined;
      if (typeof c?.id === "string") connects.push({ id: c.id, name: bot ?? c.id });
    }
  } catch {
    // No config: no connects.
  }
  const config = { stamp, connects, reviews };
  configs.set(s, config);
  return config;
}

export type Api = { store: Store; connects: Connect[]; reviews: boolean };
export const apiOf = (s: Store): Api => {
  const { connects, reviews } = configOf(s);
  return { store: s, connects, reviews };
};
/// The cloud's names of the store being answered for, for `people` and `authorNames` used on their own.
export const useNames = (s: Store) => ((cloudNames = s.names), (currentStore = s));
/// The store being answered for, for Slack's names (slack-known.ts).
let currentStore: Store | null = null;

// ---- titles ----

function turnSummary(t: store.TurnSummary): Json {
  return t;
}

/// The connect a Slack thread came in through: the first of its sessions' that is not the station's own.
export function slackConnectOf(t: ThreadSummary): string | null {
  return t.sessions.map((m) => m.connect).find((c) => c !== INTERNAL_CONNECT) ?? null;
}

/// The name a chat has been given: by people, else by its agent.
function given(thread: ThreadRow): string | null {
  return [thread.title, thread.autoTitle].filter((s): s is string => s !== null).map(trim).find((s) => s !== "") ?? null;
}

/// Whether a chat has a title of its own, or something a person said in it to take one from.
function hasWords(t: ThreadSummary): boolean {
  return given(t.thread) !== null || (t.firstText !== null && trim(t.firstText) !== "");
}

/// What a thread is called (title_of over a summary).
export function chatTitle(t: ThreadSummary, channelName: string | null): string {
  return titleOf(t.thread, t.firstText, channelName);
}

/// What a thread is called: the name people gave it, else the one its agent gave it, else the first line a person
/// wrote in it (Slack mentions left out, spaces collapsed), else its Slack channel (`#name`, 私信 for a direct message).
export function titleOf(thread: ThreadRow, firstText: string | null, channelName: string | null): string {
  const title = given(thread);
  if (title !== null) return title;
  const text = withoutMentions(firstText ?? "");
  const first = text.split("\n").map((line) => splitWhitespace(line).join(" ")).find((l) => l !== "");
  if (first !== undefined) return first;
  const name = channelName === null ? "" : trim(channelName);
  if (name !== "") return `#${name}`;
  if (thread.surface !== STILLFAIL_SURFACE && thread.channel.startsWith("D")) return tr("station.chat.directMessage");
  return noWords();
}

/// `<@U…>` mentions taken out.
function withoutMentions(text: string): string {
  let out = "";
  let rest = text;
  for (let at = rest.indexOf("<@"); at >= 0; at = rest.indexOf("<@")) {
    out += rest.slice(0, at);
    const after = rest.slice(at + 2);
    const end = after.indexOf(">");
    if (end > 0 && /^[A-Z0-9]+$/.test(after.slice(0, end))) {
      rest = after.slice(end + 1);
    } else {
      out += "<@";
      rest = after;
    }
  }
  return out + rest;
}

// ---- people ----

/// A creator reference in words: who, and their email where known.
/// The names of the store being answered for (creator and people have no store of their own).
let cloudNames = new Map<string, string>();

function creator(reference: string | null): Json | null {
  if (reference === null) return null;
  if (reference === "local") return { id: "local", name: tr("station.creator.localPage"), email: null, via: "local" };
  if (reference.startsWith("slack:") && currentStore !== null) {
    const slack = slackCreator(currentStore, reference);
    if (slack !== null) return slack;
  }
  return { id: reference, name: cloudNames.get(reference) ?? reference, email: reference, via: "cloud" };
}

/// Several people, once each: one person may write through Slack and the station's chat under the same email.
export function people(refs: string[]): Json[] {
  const seen = new Set<string>();
  return refs
    .map((r) => creator(r))
    .filter((p): p is Json => p !== null)
    .filter((p) => {
      const key = typeof p.email === "string" ? p.email : typeof p.id === "string" ? p.id : "";
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

/// Whether a person is the viewer: by id, by email, or as a Slack user the viewer said is them.
function isMine(api: Api, viewer: Viewer): (person: Json | null) => boolean {
  const id = viewer.email;
  const email = viewer.email.toLowerCase();
  const slack = new Set(store.slackIdentities(api.store, id));
  return (p) => {
    if (p === null || p === undefined) return false;
    const pid: string = typeof p.id === "string" ? p.id : "";
    return (
      pid === id ||
      (typeof p.email === "string" && p.email.toLowerCase() === email) ||
      (p.via === "slack" && slack.has(pid.slice(pid.lastIndexOf(":") + 1)))
    );
  };
}

/// Where a Slack thread is, for the connect icon's tip: the Slack workspace, the channel. No connection is up to name
/// the workspace, nor knows the channel.
function origin(t: ThreadSummary): Json {
  const connect = slackConnectOf(t);
  const s = currentStore!;
  return { teamName: connect === null ? null : teamName(s, connect), channel: t.thread.channel, channelName: knownChannel(s, connect, t.thread.channel), threadTs: t.thread.threadTs };
}

type Names = (kind: AuthorKind, author: string) => string | null;

/// Who wrote in a thread, in words: each author asked once.
export function authorNames(api: Api, thread: number): Names {
  const th = store.getThread(api.store, thread);
  const members = store.threadSessions(api.store, thread);
  const names = new Map<string, string | null>();
  return (kind, author) => {
    const key = `${kind}:${author}`;
    if (names.has(key)) return names.get(key)!;
    let name: string | null;
    if (kind === "ember") name = "still.fail";
    else if (kind === "agent") {
      // An agent goes by the name of the connect it posts through (on the page, of the connect that started it).
      const session = store.getSession(api.store, author);
      const via = members.find((m) => m.session === author)?.connect;
      const connect = via !== undefined && via !== INTERNAL_CONNECT ? via : (session?.connect ?? null);
      const c = api.connects.find((c) => c.id === connect);
      name = c ? c.name : (session?.title ?? null);
    } else if (th !== null && th.surface === STILLFAIL_SURFACE) {
      name = author === "local" ? tr("station.author.admin") : (api.store.names.get(author) ?? author);
    } else {
      // A Slack person: by the name their connect's Slack gives them, as far as known.
      const connect = members.map((m) => m.connect).find((c) => c !== INTERNAL_CONNECT) ?? null;
      const person = connect === null ? null : knownPerson(api.store, connect, author);
      name = person?.name ? person.name : null;
    }
    names.set(key, name);
    return name;
  };
}

// ---- messages ----

/// A merged message as lists show it (a thread's latest), with its author's name.
export function messageView(m: MessageRow, names: Names): Json {
  const v: Json = {
    agentIdentity: m.agentIdentity, seq: m.n, thread: m.thread, ts: m.ts, authorKind: m.authorKind, author: m.author, authorName: names(m.authorKind, m.author),
    text: m.text, attachments: m.attachments, quotes: m.quotes, declared: m.declared, createdAt: m.createdAt, editedAt: m.editedAt,
  };
  declaredView(v, m.declared);
  return v;
}

/// A post's declared kind as the pages read it: `declared` in the words from before, `ending` in today's.
function declaredView(v: Json, declared: string | null) {
  if (declared !== null) {
    v.declared = store.saidBefore(declared);
    v.ending = store.ending(declared);
  }
}

/// serde_json's Map::remove with preserve_order: the last entry takes the removed one's place (swap_remove).
function swapRemove(v: Json, key: string): Json {
  const entries = Object.entries(v);
  const at = entries.findIndex(([k]) => k === key);
  if (at < 0) return v;
  const last = entries.pop()!;
  if (at < entries.length) entries[at] = last;
  return Object.fromEntries(entries);
}

/// A card the viewer answered, for its chat's row (`answered`).
function answeredView(a: store.CardAnswer): Json {
  const v: Json = { seq: a.question.n, text: a.question.text, askedAt: a.question.createdAt, answeredAt: a.at, card: a.card };
  if (a.answer !== null) {
    v.reply = a.answer.text;
    v.quoted = a.answer.quotes.some((q) => q.ts === a.question.ts);
  } else {
    v.closed = true;
  }
  return v;
}

/// A chat's card still pending, for its row: `seq`, the `card`, the post itself (`message`) and the two messages
/// before it (`before`), `dismissed` when the viewer will not take it up.
function cardView(api: Api, thread: number, dismissed: Set<string>, names: Names): Json | null {
  const pending = store.pendingCard(api.store, thread);
  if (pending === null) return null;
  const [m, card] = pending;
  const message = messageView(m, names);
  if (field(card, "type") === "options") message.options = field(card, "options");
  message.card = card;
  const before = store.messagesBefore(api.store, thread, m.n, 2).map((b) => messageView(b, names));
  const v: Json = { seq: m.n, card, message, before };
  if (dismissed.has(`${thread}:${m.n}`)) v.dismissed = true;
  return v;
}

/// serde_json's `value[key]`: null for a key it lacks or a value that is no object.
function field(v: Json, key: string): Json {
  return v !== null && typeof v === "object" && !Array.isArray(v) && key in v ? v[key] : null;
}

/// What one of a chat's agents needs a person for without a card (its last turn ended need_help), while no one has
/// written since: `seq`, `message`, the two messages before it and `dismissed`, as `card_view` gives a card.
function needView(api: Api, thread: number, agents: Json[], dismissed: Set<string>, names: Names): Json | null {
  const turn = agents
    .map((a) => field(a, "lastTurn"))
    .find((t) => {
      const ending = field(t, "ending");
      return typeof ending === "string" ? ending === "need_help" || ending === "need_decision" : field(t, "declared") === "block";
    });
  if (turn === undefined) return null;
  const about = field(turn, "about");
  const seq = about !== null && typeof about === "object" && !Array.isArray(about) && field(about, "thread") === thread && Number.isInteger(field(about, "seq")) ? field(about, "seq") : null;
  const started = field(turn, "startedAt");
  const ended = field(turn, "endedAt");
  const during: [number, number | bigint] = [Number.isInteger(started) ? started : 0, Number.isInteger(ended) ? ended : store.I64_MAX];
  const asked = store.askingMessage(api.store, thread, seq, during);
  if (asked === null) return null;
  const [m, earlier] = asked;
  const before = earlier.map((b) => messageView(b, names));
  const v: Json = { seq: m.n, message: messageView(m, names), before };
  if (dismissed.has(`${thread}:${m.n}`)) v.dismissed = true;
  return v;
}

// ---- the sidebar ----

/// The viewer's sidebar: one kind of item, an agent (a shown session) merged with its internal chat. An agent in an
/// internal chat is that chat's item; one with none yet is an item without a chat. A Slack thread is no item: it lends
/// its agent's item a title (while the chat has no words of its own), the connect and the origin. `archived`: the
/// archive's items instead, each with `archived: {at, by, alone}`. Each says when the viewer pinned it (`pinned`).
export function chats(station: Store, viewer: Viewer, archived: boolean): Json[] {
  useNames(station);
  const api = apiOf(station);
  const s = api.store;
  const mine = isMine(api, viewer);
  const stats = store.sessionStats(s, null);
  const sessions = store.listSessions(s);
  const shown = new Map(sessions.filter((x) => (x.archivedAt !== null) === archived).map((x) => [x.key, x]));
  const order = sessions.filter((x) => (x.archivedAt !== null) === archived).map((x) => x.key);
  // In the archive, a chat of its own shows its agents whatever they are doing elsewhere.
  const all = new Map(sessions.map((x) => [x.key, x]));
  const listed = (t: ThreadSummary) => (t.thread.hiddenAt !== null) === archived;
  const inChat = (t: ThreadSummary): string[] => {
    const alone = archived && t.thread.home === null;
    return t.sessions.filter((m) => (alone ? all.has(m.session) : shown.has(m.session))).map((m) => m.session);
  };
  const archivedOf = (x: store.SessionRow) => ({ at: x.archivedAt ?? 0, by: x.archivedBy ?? store.MANUAL, alone: false });
  const watches = store.watching(s);
  const agent = (key: string): Json => {
    const x = all.get(key)!;
    const stat = stats.get(key);
    const v: Json = {
      key, runtime: x.runtime, model: x.model, effort: x.effort, process: s.processes.get(x.key) ?? "cold",
      pending: stat?.pending ?? 0, lastTurn: stat?.lastTurn ? turnSummary(stat.lastTurn) : null,
    };
    const watch = watches.get(key);
    if (watch !== undefined) v.watch = watch;
    return v;
  };
  const threads = store.listThreads(s, viewer.email, null, null);
  // Per agent: the Slack thread it came from (the latest one it is in), and whether it has an internal chat.
  const origins = new Map<string, ThreadSummary>();
  const chatted = new Set<string>();
  for (const t of threads) {
    for (const m of t.sessions) {
      if (t.thread.surface === STILLFAIL_SURFACE) {
        if (listed(t)) chatted.add(m.session);
      } else if (!origins.has(m.session)) {
        origins.set(m.session, t);
      }
    }
  }
  const rows: Json[] = [];
  // The decisions the viewer said they will not take up.
  const dismissed = store.dismissed(s, viewer.email);
  const kept = store.keptChats(s, viewer.email);
  // The cards the viewer answered lately, by chat.
  const answered = new Map<number, Json[]>();
  if (!archived) {
    for (const a of store.answersSince(s, store.nowMs() - ANSWERED_WITHIN)) {
      if (!mine(creator(a.by))) continue;
      const list = answered.get(a.question.thread) ?? [];
      list.push(answeredView(a));
      answered.set(a.question.thread, list);
    }
  }
  for (const t of threads.filter((t) => t.thread.surface === STILLFAIL_SURFACE && listed(t) && inChat(t).length > 0)) {
    const from = t.sessions.map((m) => origins.get(m.session)).find((o) => o !== undefined) ?? null;
    const agents = inChat(t).map(agent);
    const origin_ = from === null ? null : origin(from);
    const creator_ = creator(t.thread.createdBy);
    const people_ = people(t.people);
    const names = authorNames(api, t.thread.id);
    const lastView = t.lastMessage === null ? null : messageView(t.lastMessage, names);
    const starters = agents.map((a) => creator(all.get(a.key)?.createdBy ?? null));
    const key = agents[0].key;
    const title = from !== null && origin_ !== null && !hasWords(t) ? chatTitle(from, origin_.channelName) : chatTitle(t, null);
    let last: Json = null;
    if (lastView !== null) {
      const text0 = trim(typeof lastView.text === "string" ? lastView.text : "");
      // Something to show when there are no words: a message that only quotes says so.
      const text = text0 === "" && Array.isArray(lastView.quotes) && lastView.quotes.length > 0 ? tr("station.chat.quotedOnly") : text0;
      last = {
        seq: lastView.seq, authorKind: lastView.authorKind, author: lastView.author, authorName: lastView.authorName,
        text: typeof lastView.text === "string" ? takeChars(text, LAST_CHARS) : null, createdAt: lastView.createdAt,
      };
    }
    const isMineRow = mine(creator_) || people_.some((p) => mine(p)) || starters.some((x) => mine(x));
    const row: Json = {
      // An item is its agent's, from its first moment to its last: the session key is its id, chat or no chat.
      id: key, session: key, thread: t.thread.id,
      title,
      agents,
      last,
      unread: t.unread > 0,
      mine: isMineRow,
      lastActiveAt: Math.max(t.thread.createdAt, t.lastMessage?.createdAt ?? 0),
      connect: from === null ? null : slackConnectOf(from),
      origin: origin_,
      // Who is in it, for the row's pictures: who started it, and everyone who wrote in it.
      creator: creator_,
      people: people_,
    };
    row.archiveReminderDismissed = kept.has(t.thread.id);
    // The decision looked at it (after its agent said all done) and found nothing left to do; with the review on, only
    // such a chat is shown as one to archive (`archiveReviewed`), not every one whose agents are done.
    row.archiveRecommended = !archived && store.archiveSuggested(s, t.thread.id);
    if (api.reviews) {
      row.archiveReviewed = true;
      // What the review made of it as it stands: the option picked (and whether that recommends it), or its failure.
      const verdict = archived ? null : store.archiveVerdict(s, t.thread.id);
      if (verdict !== null) row.archiveCheck = verdict;
    }
    // The client key it was made with, while the hub remembers it.
    const clientKey = s.clientKeys.get(String(key));
    if (clientKey !== undefined) row.clientKey = clientKey;
    // The card it waits on, if any, and whether the viewer dismissed it; an options card is its `decision` too.
    const card = archived ? null : cardView(api, t.thread.id, dismissed, names);
    if (card !== null) {
      if (field(card.card, "type") === "options") {
        const decision = swapRemove(card, "card");
        decision.options = field(card.card, "options");
        row.decision = decision;
      }
      row.card = card;
    } else if (!archived) {
      // With no card waiting: what an agent needs a person for all the same, the message that asks.
      const need = needView(api, t.thread.id, agents, dismissed, names);
      if (need !== null) row.need = need;
    }
    const list = answered.get(t.thread.id);
    if (list !== undefined) {
      answered.delete(t.thread.id);
      row.answered = list;
    }
    if (archived) {
      const home = t.thread.home === null ? undefined : all.get(t.thread.home);
      row.archived = home !== undefined ? archivedOf(home) : { at: t.thread.hiddenAt ?? 0, by: t.thread.hiddenBy ?? store.MANUAL, alone: true };
    }
    rows.push(row);
  }
  for (const key of order.filter((k) => !chatted.has(k))) {
    const x = shown.get(key)!;
    const from = origins.get(key) ?? null;
    const origin_ = from === null ? null : origin(from);
    const own = x.title === null ? "" : trim(x.title);
    const title = own !== "" ? own : from !== null && origin_ !== null ? chatTitle(from, origin_.channelName) : noWords();
    const starter = creator(x.createdBy);
    const row: Json = {
      id: key, session: key, thread: null,
      title,
      agents: [agent(key)],
      last: null,
      unread: false,
      // No chat yet: mine only if the viewer started the session; others in its Slack thread do not count.
      mine: mine(starter),
      lastActiveAt: x.lastActiveAt,
      connect: x.connect === INTERNAL_CONNECT ? null : x.connect,
      origin: origin_,
      // No one has written yet: only who started it.
      people: starter === null ? [] : [starter],
      creator: starter,
    };
    if (archived) row.archived = archivedOf(x);
    rows.push(row);
  }
  // When the viewer pinned each to the top of their list, or null.
  const pins = store.pins(s, viewer.email);
  for (const row of rows) row.pinned = typeof row.id === "string" ? (pins.get(row.id) ?? null) : null;
  return rows;
}


// ---- thread entries ----

/// `asked.param`'s value as a number: Rust's `str::parse::<f64>`, which takes no spaces, no hex, nothing empty.
const RUST_F64 = /^[+-]?(?:inf|infinity|nan|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)$/i;
function parseF64(text: string): number | null {
  if (!RUST_F64.test(text)) return null;
  const body = text.replace(/^[+-]/, "").toLowerCase();
  const sign = text.startsWith("-") ? -1 : 1;
  if (body === "inf" || body === "infinity") return sign * Infinity;
  if (body === "nan") return NaN;
  return sign * Number(body);
}

/// Rust's `f64 as i64`: truncated, saturating, NaN 0.
function asI64(n: number): bigint {
  if (Number.isNaN(n)) return 0n;
  if (n >= 9223372036854775807) return store.I64_MAX;
  if (n <= -9223372036854775808) return -store.I64_MAX - 1n;
  return BigInt(Math.trunc(n));
}

/// GET /threads/:id/entries: `after` (an n) gives what came since; `before` pages back (`limit` entries); `from` and
/// `to` a gap (both included); none of them the latest page. `params`: the query's pairs, the first of a name counts
/// (admin/mod.rs `query_pairs`, `Asked::param`), or a plain map of them.
export function entries(station: Store, _viewer: Viewer, thread: number, params: Record<string, string> | [string, string][]): Json {
  useNames(station);
  const pairs = Array.isArray(params) ? params : Object.entries(params);
  const param = (name: string) => pairs.find(([k]) => k === name)?.[1];
  const api = apiOf(station);
  if (store.getThread(api.store, thread) === null) throw new HttpError(404, `unknown thread ${thread}`);
  const number = (name: string): bigint | null => {
    const v = param(name);
    if (v === undefined) return null;
    const n = parseF64(v);
    if (n !== null && Number.isFinite(n) && Math.trunc(n) === n && n >= 0) return asI64(n);
    throw new HttpError(400, tr("station.admin.notInteger", { name }));
  };
  const [after, before, from, to] = [number("after"), number("before"), number("from"), number("to")];
  const asked = param("limit");
  const parsedLimit = asked === undefined ? null : parseF64(asked);
  const wanted = parsedLimit === null || parsedLimit === 0 ? 50 : parsedLimit;
  // f64::clamp keeps NaN, which `as usize` makes 0.
  const limit = Number.isNaN(wanted) ? 0 : Math.trunc(Math.min(Math.max(wanted, 1), 500));
  if ((from !== null) !== (to !== null)) throw new HttpError(400, tr("station.admin.fromAndTo"));
  const s = api.store;
  const last = store.lastEntry(s, thread);
  const found =
    after !== null ? store.entriesAfter(s, thread, after) : from !== null && to !== null ? store.entriesBetween(s, thread, from, to) : store.entriesBefore(s, thread, before, limit);
  return { last, entries: entryViews(api, thread, found) };
}

/// EntryRow as serde writes it: its fields in their order, the skipped Nones left out.
function entryJson(e: EntryRow): Json {
  const v: Json = {};
  if (e.agentIdentity !== undefined) v.agentIdentity = e.agentIdentity;
  Object.assign(v, {
    thread: e.thread, n: e.n, kind: e.kind, target: e.target, ts: e.ts, authorKind: e.authorKind, author: e.author, text: e.text,
    attachments: e.attachments, quotes: e.quotes, declared: e.declared,
  });
  if (e.client !== null) v.client = e.client;
  if (e.profile !== null) v.profile = e.profile;
  if (e.options !== undefined) v.options = e.options;
  if (e.card !== undefined) v.card = e.card;
  v.at = e.at;
  return v;
}

/// Entries with their authors' names.
function entryViews(api: Api, thread: number, entries: EntryRow[]): Json[] {
  const names = authorNames(api, thread);
  return entries.map((e) => {
    const v = entryJson(e);
    v.authorName = names(e.authorKind, e.author);
    declaredView(v, e.declared);
    // Its card, a post's options from before cards as an options card (EntryRow::card).
    const card = e.card !== undefined ? e.card : e.options !== undefined ? store.optionsCard(e.options) : undefined;
    if (card !== undefined) v.card = card;
    return v;
  });
}
