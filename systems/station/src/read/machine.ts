// Sessions this machine's own Claude Code and Codex keep (run in a terminal, in ~/.claude and ~/.codex), for a person
// to go on with one in a chat: ported from the Rust station's machine_sessions.rs (`list`, `find`, `conversation` and what
// they read with), and the routes' answers (admin/mod.rs GET /machine-sessions, GET /machine-sessions/:runtime/:id).
// Only read; blocking (many transcripts), so it runs in a reader thread.
//
// Directories are read in the order the file system gives (opendir, as Rust's read_dir), not sorted: which of equally
// recent files comes first, and which project a Claude session is found in first, stay the Rust's.
import { type Dirent, closeSync, opendirSync, openSync, readSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { type Lang, tr } from "../ops/i18n.ts";
import { type Json, type Store, listSessions, runtimeSessions } from "./store.ts";
import { HttpError } from "./views.ts";

type Runtime = "claude" | "codex";

/// Where the machine's runtimes keep their sessions (MachineRoots): Claude Code's projects/, Codex's sessions/.
export type Roots = { claude: string; codex: string };

/// MachineRoots::of the station's environment: $HOME/.claude/projects, and $CODEX_HOME (else $HOME/.codex)/sessions.
export function roots(): Roots {
  const home = process.env.HOME ?? ".";
  const codex = process.env.CODEX_HOME ? process.env.CODEX_HOME : join(home, ".codex");
  return { claude: join(home, ".claude", "projects"), codex: join(codex, "sessions") };
}

/// A session of the machine's, as the pages list it (MachineSession; `path` is not written).
export type MachineSession = {
  runtime: Runtime; id: string; cwd: string; title: string | null; first: string | null; model: string | null;
  updatedAt: number; size: number; session: string | null; path: string;
};

/// Enough of a first message to know it by.
const FIRST = 200;
/// Records read from a transcript's start for its directory and first message.
const HEAD_RECORDS = 400;
/// Bytes read from a transcript's end for its latest name.
const TAIL = 256 * 1024;
/// A line longer than this is passed over (read as an empty one): a screenshot or a tool's output a Codex rollout keeps
/// (seen at 16 MB, a head of 51 MB) holds nothing a listing wants, and a reader's heap is bounded (read/pool.ts).
const LINE_LIMIT = 256 * 1024;

// ---- Rust's text handling ----

const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const TRIM = new RegExp(`^[${WS}]+|[${WS}]+$`, "g");
const TRIM_START = new RegExp(`^[${WS}]+`);
const SPLIT = new RegExp(`[${WS}]+`);
/// str::trim, trim_start, split_whitespace (char::is_whitespace).
const trim = (s: string) => s.replace(TRIM, "");
const trimStart = (s: string) => s.replace(TRIM_START, "");
const splitWhitespace = (s: string) => s.split(SPLIT).filter((w) => w !== "");
const str = (v: Json): string | null => (typeof v === "string" ? v : null);
const get = (v: Json, k: string): Json => (v !== null && typeof v === "object" && !Array.isArray(v) ? v[k] : undefined);

/// serde_json::from_str::<Value>(line).ok().
function parse(line: string): Json | undefined {
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
}

/// Path::extension: after the last dot of the name, unless that dot starts it.
function extension(name: string): string | null {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1) : null;
}

/// std::fs::read_dir, flattened: a directory's entries in the file system's order; none when it cannot be read.
function readDir(dir: string): Dirent[] {
  let d;
  try {
    d = opendirSync(dir);
  } catch {
    return [];
  }
  const out: Dirent[] = [];
  try {
    for (let e = d.readSync(); e !== null; e = d.readSync()) out.push(e);
  } catch {
    // An entry that does not read ends it, as `flatten` skips it.
  } finally {
    d.closeSync();
  }
  return out;
}

const isDir = (p: string) => statSync(p, { throwIfNoEntry: false })?.isDirectory() ?? false;
const isFile = (p: string) => statSync(p, { throwIfNoEntry: false })?.isFile() ?? false;

const STRICT = new TextDecoder("utf-8", { fatal: true });

/// BufRead::lines over a file, `map_while(Result::ok)`: its lines (without "\n" or "\r\n"), stopping at the first that is
/// not UTF-8; at most `limit`.
function lines(path: string, limit = Infinity): string[] {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return [];
  }
  const out: string[] = [];
  try {
    const chunk = Buffer.alloc(1 << 16);
    let pending: Buffer[] = [];
    // Bytes of the line read so far; past LINE_LIMIT what comes until its end is dropped, and it is read as "".
    let pendingSize = 0;
    let over = false;
    const take = (bytes: Buffer): boolean => {
      if (over) {
        over = false;
        out.push("");
        return out.length < limit;
      }
      let line = bytes;
      if (line.length && line[line.length - 1] === 0x0a) line = line.subarray(0, -1);
      if (line.length && line[line.length - 1] === 0x0d) line = line.subarray(0, -1);
      try {
        out.push(STRICT.decode(line));
      } catch {
        return false;
      }
      return out.length < limit;
    };
    for (;;) {
      let n: number;
      try {
        n = readSync(fd, chunk, 0, chunk.length, null);
      } catch {
        return out;
      }
      if (n === 0) break;
      let start = 0;
      const keep = (part: Buffer) => {
        if (over) return;
        pendingSize += part.length;
        if (pendingSize > LINE_LIMIT) {
          over = true;
          pending = [];
        } else pending.push(Buffer.from(part));
      };
      for (let nl = chunk.indexOf(0x0a, start); nl >= 0 && nl < n; nl = chunk.indexOf(0x0a, start)) {
        keep(chunk.subarray(start, nl + 1));
        const line = Buffer.concat(pending);
        pending = [];
        pendingSize = 0;
        start = nl + 1;
        if (!take(line)) return out;
      }
      if (start < n) keep(chunk.subarray(start, n));
    }
    if (pending.length || over) take(Buffer.concat(pending));
    return out;
  } finally {
    closeSync(fd);
  }
}

/// transcript.rs parse_iso: milliseconds of an ISO time (YYYY-MM-DDTHH:MM:SS[.fff]), read by position.
export function parseIso(at: string): number | null {
  const b = Buffer.from(at, "utf8");
  const num = (from: number, len: number): number | null => {
    if (from + len > b.length) return null;
    const s = b.subarray(from, from + len).toString("latin1");
    return /^[+-]?[0-9]+$/.test(s) ? parseInt(s, 10) : null;
  };
  const [y, mo, d, h, mi, s] = [num(0, 4), num(5, 2), num(8, 2), num(11, 2), num(14, 2), num(17, 2)];
  if (y === null || mo === null || d === null || h === null || mi === null || s === null) return null;
  let ms = 0;
  if (b[19] === 0x2e) {
    const frac = /^[0-9]*/.exec(b.subarray(20).toString("utf8"))![0];
    ms = parseInt(frac.slice(0, 3).padEnd(3, "0"), 10) || 0;
  }
  // Days from the civil date (Howard Hinnant's algorithm).
  const [yy, mm] = mo <= 2 ? [y - 1, mo + 9] : [y, mo - 3];
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const doy = Math.trunc((153 * mm + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.trunc(yoe / 4) - Math.trunc(yoe / 100) + doy;
  const days = era * 146_097 + doe - 719_468;
  return (days * 86_400 + h * 3600 + mi * 60 + s) * 1000 + ms;
}

// ---- what was said ----

/// transcript.rs injected: context Codex adds as a person's message under a tag of its own.
function injected(text: string): boolean {
  const t = trimStart(text);
  return ["environment_context", "user_instructions", "permissions", "skills_instructions", "collaboration_mode"].some((tag) => {
    if (!t.startsWith(`<${tag}`)) return false;
    const after = t.slice(tag.length + 1);
    const next = [...after.slice(0, 2)][0];
    return after === "" || (!/^[\p{Alphabetic}\p{N}]$/u.test(next!) && next !== "_");
  });
}

/// not_said: what a person typed that the runtime keeps as their message though it is not what they said.
function notSaid(text: string): boolean {
  const t = trimStart(text);
  return (
    t === "" ||
    ["<command-", "<local-command", "<system-reminder>", "<bash-", "<user-memory-input>", "Caveat: ", "This session is being continued from a previous conversation"].some((p) =>
      t.startsWith(p),
    )
  );
}

/// typed: what the person typed in a part of a Codex user message (none of the instructions it adds; of an editor's
/// context before a request, only the request).
function typed(text: string): string | null {
  const t = trimStart(text);
  if (t.startsWith("# AGENTS.md instructions")) return null;
  if (!t.startsWith("#")) return text;
  for (const mark of ["## My request for Codex:", "## My request:"]) {
    const at = t.lastIndexOf(mark);
    if (at >= 0) return trim(t.slice(at + mark.length));
  }
  return text;
}

/// wrapped: context Codex adds as a person's message, one tag around all of it.
function wrapped(text: string): boolean {
  const t = trim(text);
  if (!t.startsWith("<")) return false;
  const close = t.indexOf(">", 1);
  if (close < 0) return false;
  const name = t.slice(1, close);
  return name !== "" && /^[A-Za-z0-9_-]+$/.test(name) && t.endsWith(`</${name}>`);
}

type Said = [person: boolean, text: string];

function claudeSaid(r: Json): Said[] {
  const kind = str(get(r, "type")) ?? "";
  const flag = (k: string) => get(r, k) === true;
  if ((kind !== "user" && kind !== "assistant") || ["isMeta", "isSidechain", "isCompactSummary", "isApiErrorMessage"].some(flag)) return [];
  const person = kind === "user";
  const content = get(get(r, "message"), "content");
  const texts: string[] =
    typeof content === "string"
      ? [content]
      : Array.isArray(content)
        ? content.filter((b) => get(b, "type") === "text").map((b) => str(get(b, "text"))).filter((t): t is string => t !== null)
        : [];
  return texts.filter((t) => trim(t) !== "" && !(person && notSaid(t))).map((t) => [person, trim(t)]);
}

function codexSaid(r: Json): Said[] {
  const p = get(r, "payload");
  if (get(r, "type") !== "response_item" || get(p, "type") !== "message") return [];
  const role = get(p, "role");
  if (role !== "user" && role !== "assistant") return [];
  const person = role === "user";
  // Each part on its own: Codex puts its context in parts of their own, beside what the person said.
  const content = get(p, "content");
  const text = (Array.isArray(content) ? content : [])
    .map((b) => str(get(b, "text")))
    .filter((t): t is string => t !== null)
    .map((t) => (person ? typed(t) : t))
    .filter((t): t is string => t !== null)
    .filter((t) => trim(t) !== "" && !(person && (injected(t) || wrapped(t) || notSaid(t))))
    .join("\n");
  return trim(text) === "" ? [] : [[person, trim(text)]];
}

/// codex_event_said: Codex's events of what was said: item_completed with a UserMessage or AgentMessage item (newer),
/// user_message and agent_message (older).
function codexEventSaid(r: Json): Said[] {
  if (get(r, "type") !== "event_msg") return [];
  const p = get(r, "payload");
  if (p === undefined) return [];
  let person: boolean;
  let text: string | null;
  switch (get(p, "type")) {
    case "user_message": {
      person = true;
      const m = str(get(p, "message"));
      text = m === null ? null : typed(m);
      break;
    }
    case "agent_message":
      person = false;
      text = str(get(p, "message"));
      break;
    case "item_completed": {
      const item = get(p, "item");
      const t = get(item, "type");
      if (t === "UserMessage") person = true;
      else if (t === "AgentMessage") person = false;
      else return [];
      const content = get(item, "content");
      const parts = (Array.isArray(content) ? content : []).map((b) => str(get(b, "text"))).filter((t): t is string => t !== null);
      text = parts.map((t) => (person ? typed(t) : t)).filter((t): t is string => t !== null).join("\n");
      break;
    }
    default:
      return [];
  }
  if (text === null) return [];
  const t = trim(text);
  return t !== "" && !(person && (wrapped(t) || notSaid(t))) ? [[person, t]] : [];
}

const hasCodexEvents = (records: Json[]) => records.some((r) => codexEventSaid(r).some(([person]) => person));

/// said: Claude's messages; Codex's events of what was said when it writes them, else its model messages.
function said(runtime: Runtime, events: boolean, r: Json): Said[] {
  if (runtime === "claude") return claudeSaid(r);
  return events ? codexEventSaid(r) : codexSaid(r);
}

/// conversation: what was said in a session's transcript, oldest first: people's messages, and each turn's words of
/// the agent in one message.
function conversation(runtime: Runtime, path: string): Json[] {
  const records = lines(path).map(parse).filter((r) => r !== undefined);
  const events = runtime === "codex" && hasCodexEvents(records);
  const out: { person: boolean; text: string; at: number | null }[] = [];
  for (const r of records) {
    const ts = str(get(r, "timestamp"));
    const at = ts === null ? null : parseIso(ts);
    for (const [person, text] of said(runtime, events, r)) {
      const last = out.at(-1);
      if (last && !person && !last.person) last.text += `\n\n${text}`;
      else out.push({ person, text, at });
    }
  }
  return out;
}

// ---- the sessions ----

/// stamp: when a file was last written (ms) and its size.
function stamp(path: string): [number, number] | null {
  const meta = statSync(path, { throwIfNoEntry: false, bigint: true });
  if (!meta) return null;
  return [Number(meta.mtimeNs / 1_000_000n), Number(meta.size)];
}

/// rollouts_in: Codex's rollout-*.jsonl files under a directory, at any depth.
export function rolloutsIn(dir: string, out: string[]) {
  for (const entry of readDir(dir)) {
    const path = join(dir, entry.name);
    if (isDir(path)) rolloutsIn(path, out);
    else if (entry.name.startsWith("rollout-") && extension(entry.name) === "jsonl") out.push(path);
  }
}

/// rollout_of: a rollout file of a thread: rollout-<time>-<id>.jsonl, or rollout-<time>-<id>_<more>.jsonl.
export function rolloutOf(path: string, id: string): boolean {
  const name = basename(path);
  return name.endsWith(`-${id}.jsonl`) || name.includes(`-${id}_`);
}

/// tail: the records in the last part of a file (whole lines only).
function tail(path: string, size: number): Json[] {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return [];
  }
  const from = Math.max(0, size - TAIL);
  const parts: Buffer[] = [];
  try {
    const chunk = Buffer.alloc(1 << 16);
    for (let at = from; ; ) {
      const n = readSync(fd, chunk, 0, chunk.length, at);
      if (n === 0) break;
      parts.push(Buffer.from(chunk.subarray(0, n)));
      at += n;
    }
  } catch {
    return [];
  } finally {
    closeSync(fd);
  }
  const text = Buffer.concat(parts).toString("utf8");
  let whole = text;
  if (from > 0) {
    const nl = text.indexOf("\n");
    whole = nl >= 0 ? text.slice(nl + 1) : "";
  }
  // str::lines: split at "\n", a "\r" before it dropped, no empty last line.
  const ls = whole.split("\n").map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
  if (whole.endsWith("\n") || whole === "") ls.pop();
  return ls.map(parse).filter((r) => r !== undefined);
}

/// claude_title: the name given by hand, else the runtime's latest.
function claudeTitle(records: Json[]): string | null {
  const latest = (kind: string, field: string) => {
    const r = records.findLast((r) => get(r, "type") === kind);
    const t = str(get(r, field));
    return t === null || trim(t) === "" ? null : trim(t);
  };
  return latest("custom-title", "customTitle") ?? latest("ai-title", "aiTitle") ?? latest("summary", "summary");
}

/// clip: whitespace collapsed, at most `max` characters (and an ellipsis past them).
function clip(text: string, max: number): string {
  const line = splitWhitespace(text).join(" ");
  const chars = [...line];
  return chars.length > max ? `${chars.slice(0, max).join("")}…` : line;
}

/// read: a transcript as the pages list it; none when it ran nowhere or asked nothing.
function read(runtime: Runtime, path: string, updatedAt: number, size: number): MachineSession | null {
  const head = lines(path, HEAD_RECORDS).map(parse).filter((r) => r !== undefined);
  const events = runtime === "codex" && hasCodexEvents(head);
  let firstSaid: string | null = null;
  for (const r of head) {
    const found = said(runtime, events, r).find(([person]) => person);
    if (found) {
      firstSaid = found[1];
      break;
    }
  }
  const first = firstSaid === null ? null : clip(firstSaid, FIRST);
  let id: string | null;
  let cwd: string | null;
  if (runtime === "claude") {
    const name = basename(path);
    const dot = name.lastIndexOf(".");
    id = dot > 0 ? name.slice(0, dot) : name;
    cwd = head.map((r) => str(get(r, "cwd"))).find((c) => c !== null) ?? null;
  } else {
    const meta = get(head.find((r) => get(r, "type") === "session_meta"), "payload");
    if (meta === undefined) return null;
    [id, cwd] = [str(get(meta, "id")), str(get(meta, "cwd"))];
  }
  if (id === null || cwd === null || first === null) return null;
  const records = [...head, ...tail(path, size)];
  const title = runtime === "claude" ? claudeTitle(records) : null;
  let model: string | null = null;
  for (let i = records.length - 1; i >= 0 && model === null; i--) {
    const r = records[i];
    const m =
      runtime === "claude"
        ? get(r, "type") === "assistant" ? get(get(r, "message"), "model") : undefined
        : get(r, "type") === "turn_context" ? get(get(r, "payload"), "model") : undefined;
    if (typeof m === "string" && !m.startsWith("<")) model = m;
  }
  return { runtime, id, cwd, title, first, model, updatedAt, size, session: null, path };
}

/// codex_names: the names Codex gave its threads (session_index.jsonl beside sessions/: the latest line for an id counts).
function codexNames(r: Roots): Map<string, string> {
  const names = new Map<string, string>();
  for (const line of lines(join(dirname(r.codex), "session_index.jsonl"))) {
    const v = parse(line);
    const [id, name] = [str(get(v, "id")), str(get(v, "thread_name"))];
    if (id !== null && name !== null && trim(name) !== "") names.set(id, trim(name));
  }
  return names;
}

function named(s: MachineSession, names: Map<string, string>): MachineSession {
  if (s.title === null) s.title = names.get(s.id) ?? null;
  return s;
}

/// list: the machine's sessions, most recently written first, at most `limit`: those that ran somewhere and asked
/// something.
function list(r: Roots, limit: number): MachineSession[] {
  const files: [Runtime, string, number, number][] = [];
  for (const dir of readDir(r.claude)) {
    const d = join(r.claude, dir.name);
    for (const file of readDir(d)) {
      const path = join(d, file.name);
      if (extension(file.name) !== "jsonl") continue;
      const st = stamp(path);
      if (st) files.push(["claude", path, st[0], st[1]]);
    }
  }
  const rollouts: string[] = [];
  rolloutsIn(r.codex, rollouts);
  for (const path of rollouts) {
    const st = stamp(path);
    if (st) files.push(["codex", path, st[0], st[1]]);
  }
  files.sort((a, b) => b[2] - a[2]);
  const names = codexNames(r);
  // Codex may keep a thread in more than one file: the latest written stands for it.
  const seen = new Set<string>();
  const out: MachineSession[] = [];
  for (const [runtime, path, at, size] of files) {
    if (out.length >= limit) break;
    const s = read(runtime, path, at, size);
    if (s === null || seen.has(`${s.runtime}\0${s.id}`)) continue;
    seen.add(`${s.runtime}\0${s.id}`);
    out.push(named(s, names));
  }
  return out;
}

/// find: one of the machine's sessions, by its runtime and id.
export function find(r: Roots, runtime: Runtime, id: string): MachineSession | null {
  if (id === "" || !/^[A-Za-z0-9-]+$/.test(id)) return null;
  let path: string | undefined;
  if (runtime === "claude") {
    path = readDir(r.claude).map((d) => join(r.claude, d.name, `${id}.jsonl`)).find(isFile);
  } else {
    const rollouts: string[] = [];
    rolloutsIn(r.codex, rollouts);
    const mine = rollouts
      .filter((p) => rolloutOf(p, id))
      .map((p) => [stamp(p)?.[0], p] as const)
      .filter((m): m is readonly [number, string] => m[0] !== undefined)
      .sort((a, b) => b[0] - a[0]);
    path = mine.map(([, p]) => p).find((p) => {
      const st = stamp(p);
      return st !== null && read(runtime, p, st[0], st[1])?.id === id;
    });
  }
  if (path === undefined) return null;
  const st = stamp(path);
  if (st === null) return null;
  const s = read(runtime, path, st[0], st[1]);
  return s !== null && s.id === id ? named(s, codexNames(r)) : null;
}

/// A MachineSession as serde writes it: `path` skipped.
function shown(s: MachineSession): Json {
  const { path: _, ...rest } = s;
  return rest;
}

// ---- the routes' answers (admin/mod.rs) ----

/// GET /machine-sessions: the machine's latest 100, each with the station's session already going on with it.
export function machineSessions(s: Store): Json {
  const found = list(roots(), 100);
  // A HashMap collected from every session: of two going on with one, the last listed (least recently active) stands.
  const going = new Map<string, string>();
  for (const r of listSessions(s)) for (const id of runtimeSessions(s, r.key)) going.set(`${r.runtime}\0${id}`, r.key);
  for (const m of found) m.session = going.get(`${m.runtime}\0${m.id}`) ?? null;
  return { sessions: found.map(shown) };
}

/// GET /machine-sessions/:runtime/:id: one of them to look at before going on with it: what was said, the latest
/// `limit` (a usize, default 200, 1–1000).
export function machineSession(s: Store, lang: Lang, runtime: string, id: string, limitParam: string | undefined): Json {
  if (runtime !== "claude" && runtime !== "codex") throw new HttpError(404, `no runtime ${runtime}`);
  // str::parse::<usize>: digits, a `+` before them at most, no more than a u64 holds; else the default.
  const asked = limitParam !== undefined && /^\+?[0-9]+$/.test(limitParam) && BigInt(limitParam) <= 18446744073709551615n ? BigInt(limitParam) : 200n;
  const limit = Number(asked < 1n ? 1n : asked > 1000n ? 1000n : asked);
  const found = find(roots(), runtime, id);
  if (found === null) throw new HttpError(404, tr(lang, "station.admin.noLocalSession", { id }));
  const said = conversation(runtime, found.path);
  found.session = listSessions(s).find((r) => r.runtime === runtime && runtimeSessions(s, r.key).includes(found.id))?.key ?? null;
  const total = said.length;
  return { session: shown(found), total, said: said.slice(Math.max(0, total - limit)) };
}
