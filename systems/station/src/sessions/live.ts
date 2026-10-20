// Live view of sessions (the Rust station's live.rs): what a running turn is doing, told at its turning points — the phase
// (asking the model, thinking, working), each step starting (thinking, writing, a tool with its input) and ending — and
// the transcript's entries as each is written whole. What a step writes as it goes (the runtime's deltas) is not sent:
// a step's words come with its entry; how fast it writes is, now and then. Nothing here is stored: the steps in flight
// live in memory until they end, and the transcript stays the record, read as it grows and kept in memory while someone
// watches. Redesigned on one point (docs/station-ts.md, push not poll): a watched transcript is followed by the file
// system's change events (fs.watch), not looked at every 250 ms.
import type { Clock } from "effect";
import { closeSync, existsSync, type FSWatcher, openSync, readFileSync, readSync, statSync, watch } from "node:fs";
import { zstdDecompressSync } from "node:zlib";
import type { LiveEvent } from "../agents/runtime.ts";
import { Fibers } from "../ops/fibers.ts";
import { type ReadState, type TimelineEntry, timelineOf } from "../read/transcript.ts";

type Json = any;
type Phase = Extract<LiveEvent, { kind: "phase" }>["phase"];

/// A step in flight: what it is, not what it has written so far.
export type LiveStep = { id: string; step: "text" | "thinking" | "tool"; tool?: string; subagent?: boolean; parent?: string; input: string; startedAt: number };

export type TranscriptUsage = { modelCalls: number; inputTokens: number; cachedTokens: number; outputTokens: number; model: string | null };

export type LiveMessage =
  | { type: "steps"; steps: LiveStep[]; phase: { phase: Phase; elapsedMs: number } | null }
  | { type: "step"; event: LiveEvent }
  | { type: "timeline"; start: number; entries: TimelineEntry[]; usage: TranscriptUsage }
  /// How fast the model is writing now (≈ tokens a second, from bytes), at most once a second; 0 once it stops.
  | { type: "rate"; tokensPerSecond: number }
  | { type: "clear" };

export type Listener = (message: LiveMessage) => void;

/// How much of a tool's input a step carries: enough to say what it runs.
const INPUT_CHARS = 300;
/// The output rate is told at most this often, over this window (bytes / 4 ≈ tokens).
const RATE_EVERY_MS = 1_000;
const RATE_WINDOW_MS = 2_000;
const RATE_FIRST_MS = 500;

const takeChars = (text: string, n: number) => Array.from(text).slice(0, n).join("");

/// Reads a transcript as it grows (transcript.rs TranscriptTail): each read gives the timeline entries of the lines
/// written since the last one, and the usage so far. Everything read is kept, so watchers joining later are served from
/// memory.
export class TranscriptTail {
  readonly runtime: "claude" | "codex";
  readonly path: string;
  private offset = 0;
  private packedStamp: string | null = null;
  private partial = Buffer.alloc(0);
  entries: TimelineEntry[] = [];
  usage: TranscriptUsage = { modelCalls: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0, model: null };
  private seen = new Set<string>();
  private state: ReadState = { inner: new Map() };

  constructor(runtime: "claude" | "codex", path: string) {
    this.runtime = runtime;
    this.path = path;
  }

  /// New entries since the last read, with the index of the first.
  read(): [number, TimelineEntry[]] {
    let start = this.entries.length;
    const compressed = !existsSync(this.path);
    const disk = compressed ? `${this.path}.zst` : this.path;
    let meta;
    try {
      meta = statSync(disk);
    } catch {
      return [start, []];
    }
    const stamp = `${meta.size}:${meta.mtimeMs}`;
    if (compressed && this.packedStamp === stamp) return [start, []];
    let unpacked: Buffer | null = null;
    if (compressed) {
      try {
        unpacked = zstdDecompressSync(readFileSync(disk));
      } catch {
        return [start, []];
      }
    }
    const size = unpacked ? unpacked.length : meta.size;
    this.packedStamp = compressed ? stamp : null;
    if (size < this.offset) {
      // Rewritten: start over.
      this.offset = 0;
      this.partial = Buffer.alloc(0);
      this.entries = [];
    }
    start = this.entries.length;
    if (size === this.offset) return [start, []];
    let buffer: Buffer;
    if (unpacked) buffer = unpacked.subarray(this.offset);
    else {
      try {
        const file = openSync(this.path, "r");
        try {
          buffer = Buffer.alloc(size - this.offset);
          let at = 0;
          while (at < buffer.length) {
            const n = readSync(file, buffer, at, buffer.length - at, this.offset + at);
            if (n === 0) return [start, []];
            at += n;
          }
        } finally {
          closeSync(file);
        }
      } catch {
        return [start, []];
      }
    }
    this.offset = size;
    const bytes = Buffer.concat([this.partial, buffer]);
    // A line still being written waits for the next read.
    const cut = bytes.lastIndexOf(0x0a) + 1;
    this.partial = Buffer.from(bytes.subarray(cut));
    const records: Json[] = [];
    for (let line of new TextDecoder("utf-8").decode(bytes.subarray(0, cut)).split("\n")) {
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line === "") continue;
      try {
        records.push(JSON.parse(line));
      } catch {}
    }
    this.addUsage(records);
    const entries: TimelineEntry[] = [];
    for (const r of records) timelineOf(this.runtime, r, this.state, entries);
    this.entries.push(...entries);
    return [start, entries];
  }

  private addUsage(records: Json[]) {
    const n = (v: Json) => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : 0);
    for (const r of records) {
      if (this.runtime === "claude") {
        const m = r?.type === "assistant" ? r.message : undefined;
        if (!m || m.usage === undefined || typeof m.id !== "string") continue;
        if (this.seen.has(m.id)) continue;
        this.seen.add(m.id);
        const u = m.usage;
        const cached = n(u?.cache_read_input_tokens) + n(u?.cache_creation_input_tokens);
        this.usage.modelCalls++;
        this.usage.inputTokens += n(u?.input_tokens) + cached;
        this.usage.cachedTokens += n(u?.cache_read_input_tokens);
        this.usage.outputTokens += n(u?.output_tokens);
        if (typeof m.model === "string" && m.model !== "<synthetic>") this.usage.model = m.model;
      } else {
        const p = r?.payload ?? null;
        if (r?.type === "turn_context" && typeof p?.model === "string") this.usage.model = p.model;
        const last = r?.type === "event_msg" && p?.type === "token_count" ? p?.info?.last_token_usage : undefined;
        if (last === undefined || last === null) continue;
        this.usage.modelCalls++;
        this.usage.inputTokens += n(last.input_tokens);
        this.usage.cachedTokens += n(last.cached_input_tokens);
        this.usage.outputTokens += n(last.output_tokens);
      }
    }
  }
}

/// A session's transcripts read as one: those of the runtime sessions it ran in before (done, read whole) and then the
/// one it runs in now, their entries one after another, so its history goes on across a new runtime session.
export class ChainTail {
  readonly runtime: "claude" | "codex";
  private tails: TranscriptTail[];

  constructor(runtime: "claude" | "codex", paths: string[]) {
    this.runtime = runtime;
    this.tails = paths.map((path) => new TranscriptTail(runtime, path));
  }

  /// The transcript written to now.
  get path(): string {
    return this.tails.at(-1)!.path;
  }

  get entries(): TimelineEntry[] {
    return this.tails.length === 1 ? this.tails[0]!.entries : this.tails.flatMap((t) => t.entries);
  }

  get usage(): TranscriptUsage {
    const usage: TranscriptUsage = { modelCalls: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0, model: null };
    for (const t of this.tails) {
      usage.modelCalls += t.usage.modelCalls;
      usage.inputTokens += t.usage.inputTokens;
      usage.cachedTokens += t.usage.cachedTokens;
      usage.outputTokens += t.usage.outputTokens;
      usage.model = t.usage.model ?? usage.model;
    }
    return usage;
  }

  /// Goes on with the transcripts given (those it has, then new ones): the new ones are read after what it has.
  extend(paths: string[]) {
    if (paths.length < this.tails.length || this.tails.some((t, i) => t.path !== paths[i])) {
      this.tails = paths.map((path) => new TranscriptTail(this.runtime, path));
      return;
    }
    for (const path of paths.slice(this.tails.length)) this.tails.push(new TranscriptTail(this.runtime, path));
  }

  /// New entries since the last read, with the index of the first (all from the first that changed when an earlier
  /// transcript gained some, or was written anew).
  read(): [number, TimelineEntry[]] {
    let offset = 0;
    let from: number | null = null;
    for (const tail of this.tails) {
      const had = tail.entries.length;
      const [start, entries] = tail.read();
      if (from === null && (entries.length > 0 || start < had)) from = offset + start;
      offset += tail.entries.length;
    }
    if (from === null) return [offset, []];
    return [from, this.entries.slice(from)];
  }
}

type Rate = { buckets: [number, number][]; toldAt: number; told: number };
/// `behind`: the transcript of the runtime session it runs in now is not written yet (a runtime writes it once its
/// conversation has begun), so where its history goes on is looked for again on each read.
type Watched = { tail: ChainTail; watcher: FSWatcher | null; reading: boolean; behind: boolean; arm(): void };

/// Where a session's transcripts are: of the runtime sessions it ran in, the first first, ending with its current one
/// (`current`: whether that one's is among them; when not given, it is).
export type Locate = (key: string) => { runtime: "claude" | "codex"; paths: string[]; current?: boolean } | null;

export class LiveHub {
  private steps = new Map<string, LiveStep[]>();
  private phase = new Map<string, [Phase, number]>();
  private rates = new Map<string, Rate>();
  private listeners = new Map<string, [number, Listener][]>();
  private watched = new Map<string, Watched>();
  /// Its time and its waits (a read put off to gather a burst of writes).
  private time: Fibers;
  private nextId = 0;
  /// Where a session's transcript is, once its runtime has started one.
  private locate: Locate;

  constructor(locate: Locate, clock?: Clock.Clock) {
    this.locate = locate;
    this.time = new Fibers("live", clock);
  }

  private emit(key: string, message: LiveMessage) {
    for (const [, l] of this.listeners.get(key) ?? []) {
      try {
        l(message);
      } catch {}
    }
  }

  /// A runtime's live event for a session.
  event(key: string, event: LiveEvent) {
    switch (event.kind) {
      case "phase":
        this.phase.set(key, [event.phase, this.time.now()]);
        this.emit(key, { type: "step", event });
        break;
      // What a step writes as it goes is not told: its words come with its transcript entry. How fast it writes is.
      case "delta":
        this.counted(key, Buffer.byteLength(event.text));
        break;
      case "start": {
        const input = takeChars(event.input ?? "", INPUT_CHARS);
        const steps = this.steps.get(key) ?? [];
        // Started again with its input (Claude Code streams it after the start): it keeps when it started.
        const startedAt = steps.find((s) => s.id === event.id)?.startedAt ?? this.time.now();
        const kept = steps.filter((s) => s.id !== event.id);
        const step = { id: event.id, step: event.step } as LiveStep;
        if (event.tool !== undefined) step.tool = event.tool;
        if (event.subagent === true) step.subagent = true;
        if (event.parent !== undefined) step.parent = event.parent;
        step.input = input;
        step.startedAt = startedAt;
        kept.push(step);
        this.steps.set(key, kept);
        const told: LiveEvent = { kind: "start", id: event.id, step: event.step };
        if (event.tool !== undefined) told.tool = event.tool;
        told.input = input;
        if (event.subagent !== undefined) told.subagent = event.subagent;
        if (event.parent !== undefined) told.parent = event.parent;
        this.emit(key, { type: "step", event: told });
        break;
      }
      case "end": {
        const steps = this.steps.get(key);
        if (!steps) return;
        const kept = steps.filter((s) => s.id !== event.id);
        if (kept.length === steps.length) return;
        this.steps.set(key, kept);
        this.emit(key, { type: "step", event });
        // A step ended: the model is not writing (until its next output).
        const rate = this.rates.get(key);
        this.rates.delete(key);
        if (rate && rate.told > 0) this.emit(key, { type: "rate", tokensPerSecond: 0 });
        this.soon(key);
        break;
      }
    }
  }

  /// The turn is over: whatever was in flight is in the transcript now, or never will be.
  turnEnded(key: string) {
    this.steps.delete(key);
    this.phase.delete(key);
    this.rates.delete(key);
    this.emit(key, { type: "clear" });
    this.soon(key);
  }

  /// Follows a session: first the transcript entries from index `from` on (only the `last` of them, when given: a long
  /// transcript is not sent whole; the ones before come by `before`) and the usage so far, the steps in flight, then
  /// everything new. Gives the id to unsubscribe with.
  subscribe(key: string, from: number, last: number | null, listener: Listener): number {
    const id = ++this.nextId;
    this.listeners.set(key, [...(this.listeners.get(key) ?? []), [id, listener]]);
    if (this.watch(key)) {
      const tail = this.watched.get(key)!.tail;
      // A watcher that has more than the transcript (it was written anew) is told where it ends.
      const len = tail.entries.length;
      const start = Math.max(Math.min(from, len), last === null ? 0 : Math.max(0, len - last));
      listener({ type: "timeline", start, entries: tail.entries.slice(start), usage: tail.usage });
    }
    const phase = this.phase.get(key);
    listener({ type: "steps", steps: [...(this.steps.get(key) ?? [])], phase: phase ? { phase: phase[0], elapsedMs: this.time.now() - phase[1] } : null });
    return id;
  }

  /// Up to `limit` transcript entries just before index `before`, and the index of the first: from what is watched,
  /// else read now. Null when the session has no transcript.
  before(key: string, before: number, limit: number): [number, TimelineEntry[]] | null {
    const slice = (entries: TimelineEntry[]): [number, TimelineEntry[]] => {
      const end = Math.min(before, entries.length);
      const start = Math.max(0, end - limit);
      return [start, entries.slice(start, end)];
    };
    const watched = this.watched.get(key);
    if (watched) return slice(watched.tail.entries);
    const at = this.locate(key);
    if (!at) return null;
    const tail = new ChainTail(at.runtime, at.paths);
    tail.read();
    return slice(tail.entries);
  }

  /// The session went on in a new runtime session: a watched history reads on in its transcript.
  moved(key: string) {
    const watched = this.watched.get(key);
    if (!watched) return;
    // What the transcript left has is read first: its entries come before the new one's.
    const [start, entries] = watched.tail.read();
    if (entries.length > 0) this.emit(key, { type: "timeline", start, entries, usage: watched.tail.usage });
    // The new one is usually not written yet: it is looked for on each read until it is.
    watched.behind = true;
    this.follow(watched, key);
    this.soon(key);
  }

  /// Goes on into the transcripts a session that moved on has now, watching the one written to.
  private follow(watched: Watched, key: string) {
    const at = this.locate(key);
    if (!at) return;
    watched.behind = at.current === false;
    const path = watched.tail.path;
    watched.tail.extend(at.paths);
    if (watched.tail.path !== path) watched.arm();
  }

  unsubscribe(key: string, id: number) {
    const listeners = this.listeners.get(key);
    if (!listeners) return;
    const kept = listeners.filter(([i]) => i !== id);
    if (kept.length > 0) {
      this.listeners.set(key, kept);
      return;
    }
    this.listeners.delete(key);
    this.unwatch(key);
  }

  /// A deleted session: nothing of it is watched or kept any more.
  forget(key: string) {
    this.steps.delete(key);
    this.phase.delete(key);
    this.rates.delete(key);
    this.emit(key, { type: "clear" });
    this.listeners.delete(key);
    this.unwatch(key);
  }

  close() {
    for (const key of [...this.watched.keys()]) this.unwatch(key);
    void this.time.close();
  }

  /// Output written: its rate is told once half a second of it has come (a first few bytes say nothing of the pace),
  /// then when a second has passed since it last was.
  private counted(key: string, bytes: number) {
    const now = this.time.now();
    let rate = this.rates.get(key);
    if (!rate) this.rates.set(key, (rate = { buckets: [], toldAt: 0, told: 0 }));
    const bucket = Math.floor(now / 250) * 250;
    const last = rate.buckets.at(-1);
    if (last && last[0] === bucket) last[1] += bytes;
    else rate.buckets.push([bucket, bytes]);
    rate.buckets = rate.buckets.filter(([at]) => at >= now - RATE_WINDOW_MS);
    if (now - rate.toldAt < RATE_EVERY_MS) return;
    const first = rate.buckets[0]![0];
    if (rate.toldAt === 0 && now - first < RATE_FIRST_MS) return;
    const span = Math.min(RATE_WINDOW_MS, Math.max(250, now - first));
    const total = rate.buckets.reduce((sum, [, b]) => sum + b, 0);
    const tokensPerSecond = Math.max(1, Math.round((total * 1000) / (4 * span)));
    rate.toldAt = now;
    rate.told = tokensPerSecond;
    this.emit(key, { type: "rate", tokensPerSecond });
  }

  /// Starts reading a watched session's transcript, once it exists. Whether it is watched now.
  private watch(key: string): boolean {
    if (this.watched.has(key)) return true;
    if (!this.listeners.has(key)) return false;
    const at = this.locate(key);
    if (!at) return false;
    const tail = new ChainTail(at.runtime, at.paths);
    tail.read(); // what is already there counts as known; subscribers ask for what they lack
    // The transcript written to now is watched: its file, or its `.zst` while packed (sessions/cold.ts): packed or
    // restored, it is another file, watched from then on (live.rs looks at whichever is there).
    const arm = () => {
      watched.watcher?.close();
      watched.watcher = null;
      if (this.watched.get(key) !== watched) return;
      const path = tail.path;
      try {
        const watcher: FSWatcher = watch(existsSync(path) ? path : `${path}.zst`, { persistent: false }, (event) => {
          if (event === "rename") arm();
          this.soon(key);
        });
        watcher.on("error", () => {});
        watched.watcher = watcher;
      } catch {}
    };
    const watched: Watched = { tail, watcher: null, reading: false, behind: at.current === false, arm };
    this.watched.set(key, watched);
    arm();
    return true;
  }

  private unwatch(key: string) {
    const watched = this.watched.get(key);
    this.watched.delete(key);
    watched?.watcher?.close();
  }

  /// Reads what the transcript gained, coalescing bursts of writes.
  private soon(key: string) {
    if (!this.listeners.has(key)) return;
    const fresh = !this.watched.has(key);
    if (!this.watch(key)) return;
    const watched = this.watched.get(key)!;
    if (watched.reading) return;
    watched.reading = true;
    this.time.after(40, () => {
      const now = this.watched.get(key);
      if (!now) return;
      now.reading = false;
      if (now.behind) this.follow(now, key);
      const [start, entries] = now.tail.read();
      if (entries.length > 0 || fresh) this.emit(key, { type: "timeline", start, entries, usage: now.tail.usage });
    });
  }
}
