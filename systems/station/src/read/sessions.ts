// Sessions and threads as the pages read them, ported from the Rust station's admin/views.rs (`summary`, `sessions`, `session`,
// `threads`, `thread`, `thread_view`), admin/mod.rs (GET /sessions/:key/timeline, /widget-state) and admin/files.rs
// (`session_file`), with the same JSON, field for field and in serde_json's order.
//
// What the Rust station keeps outside the database is taken as views.ts takes it (a station with none of it):
// - the hub: no session has a runtime process (`process` "cold"); no transcript is watched, so a timeline is read from
//   the transcript's file each time, as the Rust does for a session nobody follows;
// - Slack names: as the names book has them (slack-known.ts), never waiting on Slack (a Slack user
//   goes by their id, with no email);
// - the cloud's names: those of the members who asked since the station started (`Store.names`).
import { knownChannel, knownPerson, slackCreator } from "./slack-known.ts";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, join, isAbsolute } from "node:path";
import { clean, cleanPosix, fileName, samePath, segments, within } from "../ops/paths.ts";
import type { Viewer } from "../mesh/credential.ts";
import type { Lang } from "../ops/i18n.ts";
import { watching } from "./store.ts";
import * as store from "./store.ts";
import type { AuthorKind, Json, SessionRow, Store, ThreadRow, ThreadSummary } from "./store.ts";
import { setLang, tr } from "./spoken.ts";
import { readTimeline, transcriptPaths } from "./transcript.ts";
import { HttpError, messageView } from "./views.ts";
import { type Thumbnail, SMALL, dir as thumbsDir, idOf, kept, wanted as thumbWanted } from "../sessions/thumbs.ts";
import { parseUsize } from "./jobs.ts";
import { shown } from "./jobs.ts";

/// The connect of the station's own chats (chat/internal.rs).
const INTERNAL_CONNECT = "ember";

// ---- the config: its connects' names and its profiles' homes (config.rs) ----

type Config = { connects: { id: string; name: string }[]; profiles: { id: string; home: string }[] };
const configs = new WeakMap<Store, { stamp: string; config: Config }>();

/// The station's config.json, as far as these reads need it (read again when it changed); none of it when it does not
/// read.
function configOf(s: Store): Config {
  let stamp = "none";
  try {
    const st = statSync(join(s.dataDir, "config.json"));
    stamp = `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch {}
  let config = configs.get(s)?.stamp === stamp ? configs.get(s)!.config : undefined;
  if (!config) {
    config = { connects: [], profiles: [] };
    try {
      const raw = JSON.parse(readFileSync(join(s.dataDir, "config.json"), "utf8"));
      for (const c of Array.isArray(raw.connects) ? raw.connects : []) {
        // Connect::name: its bot's name, else its id.
        const bot = typeof c?.slack?.botName === "string" && c.slack.botName !== "" ? c.slack.botName : undefined;
        if (typeof c?.id === "string") config.connects.push({ id: c.id, name: bot ?? c.id });
      }
      for (const p of Array.isArray(raw.profiles) ? raw.profiles : []) {
        // A profile's home, under the data directory when it is relative (config.rs `under`).
        if (typeof p?.id === "string" && typeof p?.home === "string") config.profiles.push({ id: p.id, home: isAbsolute(p.home) ? p.home : join(s.dataDir, p.home) });
      }
    } catch {
      // No config: none.
    }
    configs.set(s, { stamp, config });
  }
  return config;
}

// ---- people (views.rs `creator`, `people`; as views.ts has them) ----

/// A creator reference in words: who, and their email where known.
function creator(s: Store, reference: string | null): Json | null {
  if (reference === null) return null;
  if (reference === "local") return { id: "local", name: tr("station.creator.localPage"), email: null, via: "local" };
  const slack = slackCreator(s, reference);
  if (slack !== null) return slack;
  return { id: reference, name: s.names.get(reference) ?? reference, email: reference, via: "cloud" };
}

/// Several people, once each (by email, else id).
function people(s: Store, refs: string[]): Json[] {
  const seen = new Set<string>();
  return refs
    .map((r) => creator(s, r))
    .filter((p): p is Json => p !== null)
    .filter((p) => {
      const key = typeof p.email === "string" ? p.email : typeof p.id === "string" ? p.id : "";
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

/// views.rs `author_names`: who wrote in a thread, in words, each author asked once.
function authorNames(s: Store, thread: number): (kind: AuthorKind, author: string) => string | null {
  const th = store.getThread(s, thread);
  const members = store.threadSessions(s, thread);
  const connects = configOf(s).connects;
  const names = new Map<string, string | null>();
  return (kind, author) => {
    const key = `${kind}:${author}`;
    if (names.has(key)) return names.get(key)!;
    let name: string | null;
    if (kind === "ember") name = "still.fail";
    else if (kind === "agent") {
      // An agent goes by the name of the connect it posts through (on the page, of the connect that started it).
      const session = store.getSession(s, author);
      const via = members.find((m) => m.session === author)?.connect;
      const connect = via !== undefined && via !== INTERNAL_CONNECT ? via : (session?.connect ?? null);
      const c = connects.find((c) => c.id === connect);
      name = c ? c.name : (session?.title ?? null);
    } else if (th !== null && th.surface === store.STILLFAIL_SURFACE) {
      name = author === "local" ? tr("station.author.admin") : (s.names.get(author) ?? author);
    } else {
      // A Slack person: by the name their connect's Slack gives them, as far as known.
      const connect = members.map((m) => m.connect).find((c) => c !== INTERNAL_CONNECT) ?? null;
      const person = connect === null ? null : knownPerson(s, connect, author);
      name = person?.name ? person.name : null;
    }
    names.set(key, name);
    return name;
  };
}

// ---- sessions ----

/// SessionRow as serde writes it: the token skipped, `cwd` left out when none.
function sessionJson(r: SessionRow): Json {
  const v: Json = {
    key: r.key, connect: r.connect, scope: r.scope, title: r.title, createdBy: r.createdBy, runtime: r.runtime, profile: r.profile,
    profilePinned: r.profilePinned, model: r.model, effort: r.effort, fast: r.fast, runtimeSessionId: r.runtimeSessionId, workspace: r.workspace,
  };
  if (r.cwd !== null) v.cwd = r.cwd;
  Object.assign(v, { running: r.running, createdAt: r.createdAt, lastActiveAt: r.lastActiveAt, archivedAt: r.archivedAt, archivedBy: r.archivedBy, shownAt: r.shownAt });
  return v;
}

/// admin/mod.rs `session_row`: the session, or 404.
function sessionRow(s: Store, key: string): SessionRow {
  const row = store.getSession(s, key);
  if (row === null) throw new HttpError(404, `unknown session ${key}`);
  return row;
}

type Lists = { stats: Map<string, store.SessionStats>; bindings: Map<string, string[]>; participants: Map<string, string[]>; watches: Map<string, Json> };

/// views.rs `summary_with`: a session for lists and events: its row (without the token), process state, counts and people.
function summaryWith(s: Store, key: string, l: Lists): Json {
  const row = sessionRow(s, key);
  const v = sessionJson(row);
  v.boundTo = l.bindings.get(key) ?? [];
  // The hub's, as given with the read.
  v.process = s.processes.get(key) ?? "cold";
  const stat = l.stats.get(key);
  v.turns = stat?.turns ?? 0;
  v.pending = stat?.pending ?? 0;
  v.firstText = stat?.firstText ?? null;
  v.lastTurn = stat?.lastTurn ?? null;
  v.creator = creator(s, row.createdBy);
  v.participants = people(s, l.participants.get(key) ?? []);
  // Keeping watch (jobs::watching): the pages say so.
  const watch = l.watches.get(key);
  if (watch !== undefined) v.watch = watch;
  return v;
}

/// views.rs `summary`: one session's.
export function summary(s: Store, key: string): Json {
  return summaryWith(s, key, { stats: store.sessionStats(s, key), bindings: store.listBindings(s), participants: store.participants(s, key), watches: watching(s) });
}

/// GET /sessions (views.rs `sessions`): the sessions shown in lists, or only the archived ones; those of one connect.
export function sessions(s: Store, connect: string | null, archived: boolean, lang: Lang): Json[] {
  setLang(lang);
  const l: Lists = { stats: store.sessionStats(s, null), bindings: store.listBindings(s), participants: store.participants(s, null), watches: watching(s) };
  return store
    .listSessions(s)
    .filter((x) => (connect === null || x.connect === connect) && (x.archivedAt !== null) === archived)
    .map((x) => summaryWith(s, x.key, l));
}

/// GET /sessions/:key (views.rs `session`): the session, its threads, turns and jobs (newest first).
export function session(s: Store, key: string, viewer: Viewer, lang: Lang): Json {
  setLang(lang);
  const turns = store.listTurns(s, key);
  const jobs = store.listJobs(s, key).map((j) => shown(s, j));
  return { session: summary(s, key), threads: threadViews(s, viewer, key), turns, jobs };
}

// ---- threads ----

/// ThreadRow as serde writes it: auto_title, home, hidden_at, hidden_by and shown_at left out when none.
function threadJson(t: ThreadRow): Json {
  const v: Json = { id: t.id, surface: t.surface, channel: t.channel, threadTs: t.threadTs, title: t.title };
  if (t.autoTitle !== null) v.autoTitle = t.autoTitle;
  v.createdBy = t.createdBy;
  v.createdAt = t.createdAt;
  if (t.home !== null) v.home = t.home;
  if (t.hiddenAt !== null) v.hiddenAt = t.hiddenAt;
  if (t.hiddenBy !== null) v.hiddenBy = t.hiddenBy;
  if (t.shownAt !== null) v.shownAt = t.shownAt;
  return v;
}

/// views.rs `thread_view`: a thread with its sessions, last entry and message, what the viewer read, who wrote.
function threadView(s: Store, t: ThreadSummary): Json {
  const names = authorNames(s, t.thread.id);
  const v = threadJson(t.thread);
  v.sessions = t.sessions.map((m) => ({ thread: m.thread, session: m.session, connect: m.connect, joinedAt: m.joinedAt }));
  v.last = t.last;
  v.lastMessage = t.lastMessage === null ? null : messageView(t.lastMessage, names);
  v.read = t.read;
  v.unread = t.unread;
  v.people = people(s, t.people);
  v.firstText = t.firstText;
  // A Slack channel's name, as far as known.
  v.channelName = t.thread.surface === store.STILLFAIL_SURFACE ? null : knownChannel(s, t.sessions.map((m) => m.connect).find((c) => c !== INTERNAL_CONNECT) ?? null, t.thread.channel);
  v.creator = creator(s, t.thread.createdBy);
  // A Task here that runs on another station (tasks.ts moveTo): there, its Session, its runtime and model.
  const elsewhere = t.thread.surface === store.STILLFAIL_SURFACE ? store.runsElsewhere(s, t.thread.id) : null;
  if (elsewhere !== null) v.runsOn = elsewhere;
  return v;
}

function threadViews(s: Store, viewer: Viewer, session: string | null): Json[] {
  return store.listThreads(s, viewer.email, session, null).map((t) => threadView(s, t));
}

/// GET /threads?session= (views.rs `threads`): the threads (of one session).
export function threads(s: Store, viewer: Viewer, session: string | null, lang: Lang): Json[] {
  setLang(lang);
  return threadViews(s, viewer, session);
}

/// GET /threads/:id (admin/mod.rs, views.rs `thread`): the id an i64, the thread there.
export function thread(s: Store, viewer: Viewer, id: string, lang: Lang): Json {
  setLang(lang);
  const n = parseI64(id);
  if (n === null || store.getThread(s, n) === null) throw new HttpError(404, `unknown thread ${id}`);
  const found = store.listThreads(s, viewer.email, null, n)[0];
  if (found === undefined) throw new HttpError(404, `unknown thread ${n}`);
  return threadView(s, found);
}

/// `str::parse::<i64>`: digits with a sign at most, within an i64.
export function parseI64(text: string): number | null {
  if (!/^[+-]?\d+$/.test(text)) return null;
  const n = BigInt(text);
  return n > 9223372036854775807n || n < -9223372036854775808n ? null : Number(n);
}

// ---- a session's timeline and widgets ----

/// GET /sessions/:key/timeline: transcript entries before those a page was sent: up to `limit` (200, from 1 to 1000)
/// before entry `before` (0), and the index of the first (live.rs `before`). The transcript is found through the
/// session's profile (hub.rs `locate`); none found: nothing.
export function timeline(s: Store, key: string, beforeParam: string | undefined, limitParam: string | undefined, lang: Lang): Json {
  setLang(lang);
  const row = sessionRow(s, key);
  const before = parseUsize(beforeParam) ?? 0;
  const limit = Math.min(Math.max(parseUsize(limitParam) ?? 200, 1), 1000);
  const profile = configOf(s).profiles.find((p) => p.id === row.profile);
  if (!profile || row.runtimeSessionId === null) return { start: 0, entries: [] };
  // Those of the runtime sessions it ran in before come first, each read as its runtime wrote it (sessions/afresh.ts).
  const homes = [profile.home, ...configOf(s).profiles.map((p) => p.home).filter((h) => h !== profile.home)];
  const { paths } = transcriptPaths(homes, store.runtimeSessions(s, key));
  const entries = paths.flatMap(({ runtime, path }) => readTimeline(runtime, path));
  const end = Math.min(before, entries.length);
  const start = Math.max(0, end - limit);
  return { start, entries: entries.slice(start, end) };
}

/// GET /sessions/:key/widget-state?path: what a widget in one of the session's messages holds, null when nothing or
/// what is kept does not read as JSON.
export function widgetState(s: Store, key: string, path: string | undefined, lang: Lang): Json {
  setLang(lang);
  sessionRow(s, key);
  const kept = store.widgetState(s, key, path ?? "");
  let state: Json = null;
  if (kept !== null) {
    try {
      state = JSON.parse(kept);
    } catch {
      state = null;
    }
  }
  return { state };
}

// ---- a session's files (admin/files.rs) ----

/// files.rs `mime`: by the file's extension.
function mime(path: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  // Path::extension: none for a name with no dot, or only the one it starts with.
  const ext = dot <= 0 ? null : name.slice(dot + 1).toLowerCase();
  const kinds: Record<string, string> = {
    png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", svg: "image/svg+xml",
    pdf: "application/pdf", txt: "text/plain; charset=utf-8", md: "text/markdown; charset=utf-8", json: "application/json",
  };
  return (ext !== null && Object.hasOwn(kinds, ext) ? kinds[ext] : undefined) ?? "application/octet-stream";
}

const isFile = (path: string) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};
const canonical = (path: string): string | null => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};
/// footprint.rs `room_of`: a session's own directory, the one its workspace is in when the station made it
/// (<data>/sessions/<connect>/<session>/workspace), else none.
function roomOf(dataDir: string, workspace: string): string | null {
  const sessions = canonical(join(dataDir, "sessions"));
  if (sessions === null) return null;
  let path = canonical(workspace);
  if (path === null) {
    if (fileName(workspace) !== "workspace") return null;
    const parent = canonical(dirname(workspace));
    if (parent === null) return null;
    path = join(parent, "workspace");
  }
  if (!within(path, sessions) || samePath(path, sessions)) return null;
  const relative = segments(path.slice(sessions.length)).filter((p) => p !== "");
  if (relative.length !== 3 || fileName(path) !== "workspace") return null;
  return dirname(path);
}

/// thumbs.rs `thumbnail`, as far as a reader goes: the image's thumbnail as kept; else whether one is to be made (an
/// image by its name, over 24 KiB), which the route asks the image codecs for (sessions/thumbs.ts: the addon is not
/// loaded in the readers, and a reader is not held up decoding); else null, the image shown itself.
function thumbnail(image: string, dataDir: string): Thumbnail | "make" | null {
  const name = fileName(image);
  if (name === null || !thumbWanted(name)) return null;
  let len: number;
  try {
    len = statSync(image).size;
  } catch {
    return null;
  }
  if (len <= SMALL) return null;
  return kept(thumbsDir(dataDir), idOf(image)) ?? "make";
}

/// std::io::Error as anyhow shows it.
export function ioMessage(e: NodeJS.ErrnoException): string {
  const said: Record<string, string> = { ENOENT: "No such file or directory", EACCES: "Permission denied", EISDIR: "Is a directory", EPERM: "Operation not permitted" };
  return e.code && said[e.code] && typeof e.errno === "number" ? `${said[e.code]} (os error ${-e.errno})` : e.message;
}

/// GET /sessions/:key/files?name&thumb=1 (files.rs `session_file`): a file sent to the session, for previews: only from
/// its upload directory, else from its archived workspace. `thumb`: an image as a chat shows it. Its path and its type,
/// for the route to answer with (cache-control `private, max-age=3600`); or, for a thumbnail not made yet,
/// `{contentType, image, thumbs}`: the route has it made (else answers the image itself, of that type).
export function sessionFile(s: Store, key: string, name: string, thumb: boolean, lang: Lang): Json {
  setLang(lang);
  const row = sessionRow(s, key);
  const room = roomOf(s.dataDir, row.workspace);
  const uploads = clean(join(row.workspace, "uploads"));
  const base = name.split(/[/\\]/).at(-1) ?? "";
  const path = clean(`${uploads}/${base}`);
  const notFound = () => new HttpError(404, tr("station.files.notFound"));
  if (base === "" || !within(path, uploads) || samePath(path, uploads)) throw notFound();
  if (!isFile(path)) {
    // Packed with its archived workspace: the route reads it out of the archive (sessions/archive.ts), under its lock.
    if (room === null || !existsSync(join(room, "workspace.tar.zst"))) throw notFound();
    return { contentType: mime(path), archived: { room, path, relative: `uploads/${base}` }, notFound: tr("station.files.notFound") };
  }
  const small = thumb ? thumbnail(path, s.dataDir) : null;
  if (small === "make") return { contentType: mime(path), image: path, thumbs: thumbsDir(s.dataDir) };
  const [file, kind] = small !== null ? [small.path, small.type] : [path, mime(path)];
  // Read by the route, as it goes out: a big file is never all in memory here, nor sent across as base64.
  return { contentType: kind, file };
}
