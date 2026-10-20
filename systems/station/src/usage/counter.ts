// What the agents spent, counted (the Rust station's usage.rs `Usage`): every model call their runtimes write to a transcript
// (Claude Code's message usage, Codex's token counts) is recorded once in the store (store/usage.ts), with the turn it
// was in and whom that turn worked for. The transcripts are read as they grow, from where the last read stopped: all of
// them the first time (what was spent before the station counted), then those of the sessions that ran since.
//
// Pushed rather than polled (the Rust reads every minute): a read when the counter starts, one shortly after a turn
// ends (the store's session changes say so), and a slow safety read for anything missed (a long turn's calls so far).
// Reads never overlap. The reading itself must not hold the main thread: files are read asynchronously in chunks cut
// at whole lines, each chunk parsed and recorded on its own, with the event loop let through between chunks.
// The prices (what a call costs) are the usage page's: src/read/usage.ts.
import { Clock, Effect, Fiber, Queue } from "effect";
import { liveClock } from "../ops/fibers.ts";
import { createReadStream } from "node:fs";
import { type FileHandle, open, readFile, readdir, realpath, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { promisify } from "node:util";
import { createZstdDecompress, zstdDecompress } from "node:zlib";
import { log } from "../ops/log.ts";
import { parseIso } from "../read/transcript.ts";
import type { SessionRow, Store, UsageCall, UsageFile, UsageFor, UsageTurn } from "../store/store.ts";

/// Calls a little before a session was made (the runtime's clock against the station's) are still its own.
export const SKEW_MS = 5_000;
/// A later read takes the sessions with a turn running or ended this long before the last read began (the Rust's
/// EVERY, the margin it reads them again with).
const MARGIN_MS = 60_000;
/// How long after a turn ends its transcript is read (its last lines written, other turns ending with it).
export const SETTLE_MS = 2_000;
/// How often everything that ran is read anyway, for what no turn's end told.
export const SAFETY_MS = 10 * 60_000;
/// How much of a transcript is read, parsed and recorded at a time before the event loop is let through.
const CHUNK = 1 << 20;

type Runtime = "claude" | "codex";

/// What the counter reads of the station's config: where its data is, and each profile's home (absolute).
export type UsageConfig = { dataDir: string; profiles: readonly { home: string }[] };

export type UsageCounterOptions = {
  store: Store;
  /// Read at every read, so profiles added since are read too.
  config: () => UsageConfig;
  settleMs?: number;
  safetyMs?: number;
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
};

// ── reading transcripts ──

/// What reading a transcript carries from line to line and from read to read: the model it last named (Codex) and
/// its session's id (Codex's first line).
export type CallState = { model: string | null; codexId: string | null };

const get = (v: unknown, k: string): unknown =>
  v !== null && typeof v === "object" && !Array.isArray(v) && Object.hasOwn(v, k) ? (v as Record<string, unknown>)[k] : undefined;
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
/// serde_json's as_i64, or 0.
const n = (v: unknown): number => (typeof v === "number" && Number.isInteger(v) ? v : 0);

/// calls_of: a transcript's lines read into calls; `state` carries the model and Codex id on.
export function callsOf(runtime: Runtime, text: string, subagent: boolean, state: CallState): UsageCall[] {
  const out: UsageCall[] = [];
  const atIndex = new Map<string, number>();
  for (let line of text.split("\n")) {
    if (line.endsWith("\r")) line = line.slice(0, -1);
    // Most lines are something else: only those that may hold usage are parsed.
    const wanted = runtime === "claude" ? line.includes('"usage"') : line.includes("token_count") || line.includes("turn_context") || line.includes("session_meta");
    if (!wanted) continue;
    let r: unknown;
    try {
      r = JSON.parse(line);
    } catch {
      continue;
    }
    const stamp = str(get(r, "timestamp"));
    const at = (stamp === null ? null : parseIso(stamp)) ?? 0;
    if (runtime === "claude") {
      if (str(get(r, "type")) !== "assistant") continue;
      const m = get(r, "message");
      if (m === undefined) continue;
      const usage = get(m, "usage");
      const id = str(get(m, "id"));
      if (usage === undefined || id === null) continue;
      const name = str(get(m, "model"));
      if (name === null || name === "<synthetic>") continue;
      const written = n(get(usage, "cache_creation_input_tokens"));
      const split = get(usage, "cache_creation");
      const long = split === undefined ? 0 : n(get(split, "ephemeral_1h_input_tokens"));
      const five = split === undefined ? null : n(get(split, "ephemeral_5m_input_tokens"));
      const short = five !== null && five + long === written ? five : written - long;
      const call: UsageCall = {
        id, at, model: name, subagent: subagent || get(r, "isSidechain") === true, fast: get(usage, "speed") === "fast",
        input: n(get(usage, "input_tokens")), cacheRead: n(get(usage, "cache_read_input_tokens")), cacheWrite: short,
        cacheWriteLong: long, output: n(get(usage, "output_tokens")),
      };
      // One response is written as several lines (a block each), each with its usage: counted once, at its fullest.
      const i = atIndex.get(id);
      if (i !== undefined) out[i]!.output = Math.max(out[i]!.output, call.output);
      else {
        atIndex.set(id, out.length);
        out.push(call);
      }
    } else {
      const p = get(r, "payload") ?? null;
      const type = str(get(r, "type"));
      if (type === "session_meta") state.codexId = str(get(p, "id")) ?? state.codexId;
      else if (type === "turn_context") state.model = str(get(p, "model")) ?? state.model;
      else if (type === "event_msg" && str(get(p, "type")) === "token_count") {
        const info = get(p, "info");
        const last = info === undefined || info === null ? undefined : get(info, "last_token_usage");
        if (last === undefined || last === null) continue;
        // Token counts are told again with rate limits; the running total tells a call from its repeat.
        const totals = get(info, "total_token_usage");
        const total = totals === undefined ? at : n(get(totals, "total_tokens"));
        const cached = n(get(last, "cached_input_tokens"));
        out.push({
          id: `codex:${state.codexId ?? ""}:${total}`, at, model: state.model, subagent, fast: false,
          input: Math.max(n(get(last, "input_tokens")) - cached, 0), cacheRead: cached, cacheWrite: 0, cacheWriteLong: 0,
          output: n(get(last, "output_tokens")),
        });
      }
    }
  }
  return out;
}

/// archive.rs `packed`: where a file is once put away.
const packed = (path: string) => `${path}.zst`;

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

async function isDir(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

const canonical = async (path: string) => {
  try {
    return await realpath(path);
  } catch {
    return path;
  }
};

/// Rust's Path::extension: after the name's last dot, none for a name that only begins with one.
function extension(path: string): string | null {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  return dot <= 0 ? null : name.slice(dot + 1);
}

/// A part of a transcript: its whole lines from where the last part ended, and where they end in the file.
export type Part = { text: string; offset: number };

/// Whole lines of `bytes` (what follows `from` in the file), a part at most CHUNK long each where lines allow.
function* partsOf(bytes: Buffer, from: number): Generator<Part> {
  let at = 0;
  while (at < bytes.length) {
    const window = Math.min(bytes.length, at + CHUNK);
    let cut = bytes.lastIndexOf(0x0a, window - 1);
    if (cut < at) cut = bytes.indexOf(0x0a, window);
    if (cut < 0) return;
    yield { text: bytes.toString("utf8", at, cut + 1), offset: from + cut + 1 };
    at = cut + 1;
  }
}

const decompress = promisify(zstdDecompress);

/// read_from: what a file holds past `offset`, up to its last whole line, in parts with where each ends. A file now
/// shorter than `offset` was written anew: it is read from its start (calls already recorded stay once). A file put
/// away (only its `.zst` there) is read decompressed.
export async function* readFrom(path: string, offset: number): AsyncGenerator<Part> {
  if (!(await exists(path)) && (await exists(packed(path)))) {
    let bytes: Buffer;
    try {
      bytes = await decompress(await readFile(packed(path)));
    } catch {
      return;
    }
    const from = offset > bytes.length ? 0 : offset;
    yield* partsOf(bytes.subarray(from), from);
    return;
  }
  let size: number;
  try {
    size = (await stat(path)).size;
  } catch {
    return;
  }
  let pos = size < offset ? 0 : offset;
  if (pos === size) return;
  let file: FileHandle;
  try {
    file = await open(path, "r");
  } catch {
    return;
  }
  try {
    // Up to the size it had: what is written meanwhile is the next read's.
    let carry = Buffer.alloc(0);
    let start = pos;
    while (pos < size) {
      const buf = Buffer.allocUnsafe(Math.min(CHUNK, size - pos));
      const { bytesRead } = await file.read(buf, 0, buf.length, pos);
      if (bytesRead === 0) break;
      pos += bytesRead;
      const bytes = carry.length === 0 ? buf.subarray(0, bytesRead) : Buffer.concat([carry, buf.subarray(0, bytesRead)]);
      const cut = bytes.lastIndexOf(0x0a);
      if (cut < 0) {
        carry = bytes;
        continue;
      }
      yield { text: bytes.toString("utf8", 0, cut + 1), offset: start + cut + 1 };
      carry = bytes.subarray(cut + 1);
      start += cut + 1;
    }
  } finally {
    await file.close();
  }
}

async function jsonlIn(dir: string): Promise<string[]> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  const paths = new Set<string>();
  for (const name of names) {
    const p = join(dir, name);
    if (!(await isFile(p))) continue;
    const q = extension(p) === "zst" ? p.slice(0, -".zst".length) : p;
    if (extension(q) === "jsonl") paths.add(q);
  }
  return [...paths].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
}

/// claude_files: a Claude Code session's transcripts in a project directory: its own, and its sub-agents' beside it
/// (`<id>/subagents/*.jsonl`); `subagent` says which. `only`: that runtime session's alone (a session continued from a
/// terminal shares its directory with the terminal's own).
export async function claudeFiles(dir: string, only: string | null): Promise<[string, boolean][]> {
  let own: string[];
  if (only !== null) {
    const p = join(dir, `${only}.jsonl`);
    own = (await isFile(p)) || (!(await exists(p)) && (await isFile(packed(p)))) ? [p] : [];
  } else own = await jsonlIn(dir);
  const out: [string, boolean][] = own.map((p) => [p, false]);
  for (const p of own) {
    const id = basename(p).slice(0, -".jsonl".length);
    for (const s of await jsonlIn(join(dir, id, "subagents"))) out.push([s, true]);
  }
  return out;
}

async function rolloutsIn(dir: string, out: string[]): Promise<void> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return;
  }
  for (const name of names.sort()) {
    let path = join(dir, name);
    if (extension(path) === "zst") path = path.slice(0, -".zst".length);
    if (await isDir(path)) await rolloutsIn(path, out);
    else if (name.startsWith("rollout-") && extension(path) === "jsonl") out.push(path);
  }
}

/// The first line of a file (or of its `.zst`), up to its end when it has no newline; null when it does not read.
async function firstLine(path: string): Promise<string | null> {
  const source = (await exists(path)) ? path : packed(path);
  if (!(await exists(source))) return null;
  return new Promise((resolve) => {
    const raw = createReadStream(source);
    const stream = source === path ? raw : raw.pipe(createZstdDecompress());
    const parts: Buffer[] = [];
    let done = false;
    const finish = (line: string | null) => {
      if (done) return;
      done = true;
      raw.destroy();
      if (stream !== raw) stream.destroy();
      resolve(line);
    };
    stream.on("data", (chunk: Buffer) => {
      const nl = chunk.indexOf(0x0a);
      if (nl < 0) parts.push(chunk);
      else {
        parts.push(chunk.subarray(0, nl + 1));
        finish(Buffer.concat(parts).toString("utf8"));
      }
    });
    stream.on("end", () => finish(Buffer.concat(parts).toString("utf8")));
    stream.on("error", () => finish(null));
    raw.on("error", () => finish(null));
  });
}

/// codex_meta: a Codex transcript's session id and the directory it ran in, from its first line.
export async function codexMeta(path: string): Promise<[string, string] | null> {
  const line = await firstLine(path);
  if (line === null) return null;
  let r: unknown;
  try {
    r = JSON.parse(line);
  } catch {
    return null;
  }
  const p = get(r, "payload");
  const [id, cwd] = [str(get(p, "id")), str(get(p, "cwd"))];
  return id !== null && cwd !== null ? [id, cwd] : null;
}

/// former.rs `claude_project`: Claude Code's directory name for where a session runs.
export const claudeProject = (path: string): string => Array.from(path, (c) => (/^[A-Za-z0-9]$/.test(c) ? c : "-")).join("");

/// Lets the event loop through (timers, I/O, requests) before going on.
const breathe = () => new Promise<void>((resolve) => setImmediate(resolve));

class Stopped extends Error {}

// ── the counter ──

export class UsageCounter {
  readonly #store: Store;
  readonly #config: () => UsageConfig;
  readonly #settleMs: number;
  readonly #safetyMs: number;
  /// When the last read started; 0 before the first.
  #last = 0;
  /// The first read (everything) is under way.
  #first = false;
  /// The read under way (reads queue behind it).
  #reading: Promise<unknown> = Promise.resolve();
  /// Sessions that changed since the loop last looked, and when each one's latest turn had ended when it last did.
  #changed = new Set<string>();
  #ended = new Map<string, number>();
  #startedAt = 0;
  #wake = Effect.runSync(Queue.dropping<void>(1));
  #fiber: Fiber.Fiber<void> | null = null;
  #unsubscribe: (() => void) | null = null;
  #abort = new AbortController();
  #clock: Clock.Clock;

  constructor(options: UsageCounterOptions) {
    this.#store = options.store;
    this.#config = options.config;
    this.#settleMs = options.settleMs ?? SETTLE_MS;
    this.#safetyMs = options.safetyMs ?? SAFETY_MS;
    this.#clock = options.clock ?? liveClock;
  }

  /// Reads every transcript now, then those of sessions whose turn ended (shortly after), and all that ran every
  /// SAFETY_MS. Stopped by `stop`.
  start(): void {
    if (this.#fiber !== null) return;
    this.#startedAt = this.#clock.currentTimeMillisUnsafe();
    this.#unsubscribe = this.#store.subscribe((change) => {
      if (change.type !== "session") return;
      this.#changed.add(change.key);
      Queue.offerUnsafe(this.#wake, undefined);
    });
    const me = this;
    const readNow = Effect.promise(() => me.#readLogged());
    // Whether a turn ended since the loop last looked, of the sessions that changed.
    const turnEnded = Effect.sync(() => {
      let ended = false;
      for (const key of me.#changed) {
        const at = me.#store.lastTurn(key)?.endedAt ?? null;
        if (at !== null && at > (me.#ended.get(key) ?? me.#startedAt)) {
          me.#ended.set(key, at);
          ended = true;
        }
      }
      me.#changed.clear();
      return ended;
    });
    const loop = Effect.gen(function* () {
      yield* readNow;
      let due = (yield* Clock.currentTimeMillis) + me.#safetyMs;
      while (true) {
        const woken = yield* Effect.raceFirst(
          Queue.take(me.#wake).pipe(Effect.as(true)),
          Clock.currentTimeMillis.pipe(Effect.flatMap((now) => Effect.sleep(Math.max(1, due - now))), Effect.as(false)),
        );
        if (woken) {
          yield* Effect.sleep(me.#settleMs);
          yield* Queue.clear(me.#wake);
          if (!(yield* turnEnded) && (yield* Clock.currentTimeMillis) < due) continue;
        }
        yield* readNow;
        due = (yield* Clock.currentTimeMillis) + me.#safetyMs;
      }
    });
    this.#fiber = Effect.runFork(loop.pipe(Effect.provideService(Clock.Clock, this.#clock)));
  }

  /// Stops reading: the read under way stops at its next part (what it recorded stays).
  async stop(): Promise<void> {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    this.#abort.abort();
    if (this.#fiber !== null) await Effect.runPromise(Fiber.interrupt(this.#fiber));
    this.#fiber = null;
    await this.#reading.catch(() => {});
  }

  /// reading_all: whether everything is still being read for the first time.
  readingAll(): boolean {
    return this.#first || this.#last === 0;
  }

  async #readLogged(): Promise<void> {
    try {
      await this.read();
    } catch (e) {
      if (!(e instanceof Stopped)) log.warn("usage", "usage not read", { error: (e as Error).message });
    }
  }

  /// One read: the transcripts of every session the first time, then of those that ran since the last. How many calls
  /// were new. Reads queue behind one another.
  read(): Promise<number> {
    const next = this.#reading.catch(() => {}).then(() => this.#read());
    this.#reading = next;
    return next;
  }

  async #read(): Promise<number> {
    const started = this.#clock.currentTimeMillisUnsafe();
    const last = this.#last;
    this.#first = last === 0;
    const store = this.#store;
    const sessions: SessionRow[] = store.listSessions();
    const wanted: Set<string> | null = last === 0 ? null : new Set(store.usageActiveSessions(last - MARGIN_MS));
    const known = store.usageFiles();
    const config = this.#config();
    let added = 0;
    // Claude Code: each session's project directory (named after where it runs), in the shared transcripts and in any
    // profile's own.
    const distinct = async (roots: string[]) => {
      const seen = new Set<string>();
      const out: string[] = [];
      for (const r of roots) {
        if (!(await isDir(r))) continue;
        const real = await canonical(r);
        if (seen.has(real)) continue;
        seen.add(real);
        out.push(r);
      }
      return out;
    };
    const claudeRoots = await distinct([join(config.dataDir, "transcripts", "claude"), ...config.profiles.map((p) => join(p.home, "projects"))]);
    const codexRoots = await distinct([join(config.dataDir, "transcripts", "codex"), ...config.profiles.map((p) => join(p.home, "sessions"))]);
    const seenFiles = new Set<string>();
    for (const s of sessions) {
      if (wanted !== null && !wanted.has(s.key)) continue;
      if (s.runtime !== "claude") continue;
      const project = claudeProject(s.cwd ?? s.workspace);
      const only = s.cwd !== null ? s.runtimeSessionId : null;
      if (s.cwd !== null && only === null) continue;
      const turns: { of: UsageTurn[] | null } = { of: null };
      for (const root of claudeRoots) {
        for (const [path, subagent] of await claudeFiles(join(root, project), only)) {
          const real = await canonical(path);
          if (seenFiles.has(real)) continue;
          seenFiles.add(real);
          added += await this.#readFile(path, "claude", subagent, s, known, turns);
        }
      }
    }
    // Codex: its transcripts are kept by date, so each new one is matched to a session by its id, or by where it ran.
    const found: string[] = [];
    for (const root of codexRoots) await rolloutsIn(root, found);
    const rollouts = [...new Set(found)];
    if (rollouts.length > 0) {
      const codex = sessions.filter((s) => s.runtime === "codex");
      const turnsOf = new Map<string, { of: UsageTurn[] | null }>();
      for (const path of rollouts) {
        const file = known.get(path);
        let session: string | null;
        if (file !== undefined) session = file.session;
        else {
          const meta = await codexMeta(path);
          session = meta === null ? null : (codex.find((s) => s.runtimeSessionId === meta[0] || (s.cwd === null && s.workspace === meta[1]))?.key ?? null);
        }
        if (session === null) {
          if (file === undefined) {
            // None of the station's (a terminal's own): passed over from now on.
            let size = 0;
            try {
              size = (await stat(path)).size;
            } catch {}
            store.recordUsage(path, { session: null, offset: size, model: null }, "codex", []);
          }
          continue;
        }
        if (wanted !== null && !wanted.has(session) && file !== undefined) continue;
        const s = codex.find((c) => c.key === session);
        if (s === undefined) continue;
        let turns = turnsOf.get(session);
        if (turns === undefined) turnsOf.set(session, (turns = { of: null }));
        added += await this.#readFile(path, "codex", false, s, known, turns);
      }
    }
    this.#last = started;
    this.#first = false;
    if (added > 0) {
      if (last === 0) log.info("usage", "usage read from every transcript", { calls: added, ms: this.#clock.currentTimeMillisUnsafe() - started });
      store.usageChanged();
    }
    return added;
  }

  /// Reads one transcript of `session` on from where it was left, and records its calls, a part at a time.
  async #readFile(path: string, runtime: Runtime, subagent: boolean, session: SessionRow, known: Map<string, UsageFile>, turns: { of: UsageTurn[] | null }): Promise<number> {
    const before = known.get(path) ?? { session: null, offset: 0, model: null };
    const state: CallState = { model: before.model, codexId: null };
    let added = 0;
    let first = true;
    for await (const part of readFrom(path, before.offset)) {
      if (this.#abort.signal.aborted) throw new Stopped();
      if (first) {
        // A Codex transcript's id is in its first line: read again for a file read on from the middle.
        if (runtime === "codex") state.codexId = (await codexMeta(path))?.[0] ?? null;
        first = false;
      }
      // What ran before the station had the session (a terminal's, continued here) is not the station's.
      const calls = callsOf(runtime, part.text, subagent, state).filter((c) => c.at >= session.createdAt - SKEW_MS);
      turns.of ??= this.#store.usageTurns(session.key);
      const of = turns.of;
      const withFor: [UsageCall, UsageFor][] = calls.map((c) => {
        // The turn it was made in: the last to start before it (the first, for one before them all).
        let lo = 0;
        let hi = of.length;
        while (lo < hi) {
          const mid = (lo + hi) >> 1;
          if (of[mid]!.startedAt <= c.at) lo = mid + 1;
          else hi = mid;
        }
        return [c, of[Math.max(lo - 1, 0)]!.of];
      });
      added += this.#store.recordUsage(path, { session: session.key, offset: part.offset, model: state.model }, runtime, withFor);
      await breathe();
    }
    return added;
  }
}
