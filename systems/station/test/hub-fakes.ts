// What the hub tests run on (the Rust station's hub/tests.rs's fakes and rig): a chat platform that records what is posted,
// runtimes that script turns in-process, a real Store, and a hub over them in a temporary data directory.
import { type Clock, Effect, Scope } from "effect";
import { TestClock } from "effect/testing";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentDriver, AgentSession, OpenOptions, RuntimeEvent, TurnOutcome } from "../src/agents/runtime.ts";
import type { ChatMessage, ChatSurface, InboundFile, InboundMessage, ThreadRef } from "../src/sessions/chat.ts";
import { type HubConfig, hubConfig } from "../src/sessions/config.ts";
import { type ColdStorage, Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { chatTools } from "../src/tools/chat.ts";
import { type Attachment, Store } from "../src/store/store.ts";

type Json = any;

let counter = 1;
const next = () => counter++;

export class FakeChat implements ChatSurface {
  bot: string;
  posts: [ThreadRef, string][] = [];
  /// What it was told the agent is doing, per thread ("" once done).
  statuses: [string, string | null, string][] = [];
  calls: [string, Json][] = [];
  answers = new Map<string, Json>();
  /// What the platform says was in a thread before the station saw it, by thread ts.
  earlier = new Map<string, ChatMessage[]>();
  /// The names of the files each post carried.
  files: string[][] = [];
  /// Like a Slack app without files:write.
  noFiles = false;
  /// The bytes of files shared in messages, by file id (others cannot be read); the ids fetched, in order.
  shared = new Map<string, string>();
  downloads: string[] = [];

  constructor(bot: string) {
    this.bot = bot;
  }
  texts() {
    return this.posts.map((p) => p[1]);
  }
  lastText() {
    return this.texts().at(-1) ?? "";
  }
  botUserId() {
    return this.bot;
  }
  botName() {
    return "ember";
  }
  workspace() {
    return "T1";
  }
  async post(thread: ThreadRef, message: string, files: Attachment[]) {
    if (files.length > 0 && this.noFiles) throw new Error("slack files.getUploadURLExternal: missing_scope");
    this.files.push(files.map((f) => f.name));
    this.posts.push([thread, message]);
    return `${9_000_000 + next()}.000200`;
  }
  async download(file: InboundFile) {
    this.downloads.push(file.id);
    const bytes = this.shared.get(file.id);
    if (bytes === undefined) throw new Error("missing_scope");
    return new TextEncoder().encode(bytes);
  }
  working(thread: ThreadRef, messageTs: string | null, status: string) {
    this.statuses.push([`${thread.channel}/${thread.threadTs}`, messageTs, status]);
  }
  async api(method: string, params: Json) {
    this.calls.push([method, params]);
    return this.answers.get(method) ?? { ok: true, ts: `${9_500_000 + next()}.000300` };
  }
  history(thread: ThreadRef, before: string, limit: number) {
    const all = this.earlier.get(thread.threadTs) ?? [];
    const earlier = all.filter((m) => Number(m.ts) < Number(before));
    return Promise.resolve(earlier.slice(Math.max(0, earlier.length - limit)));
  }
}

export class FakeSession implements AgentSession {
  readonly sessionId: string;
  options: OpenOptions;
  events: (event: RuntimeEvent) => void;
  prompts: string[] = [];
  steers: string[] = [];
  /// Times the running turn's tool calls were moved to the background.
  backgrounds = 0;
  aborts = 0;
  disposed = false;
  busyNow = false;
  /// Takes no steer (e.g. a codex turn that is not steerable).
  unsteerable = false;

  constructor(id: string, options: OpenOptions, events: (event: RuntimeEvent) => void, busy = false) {
    this.sessionId = id;
    this.options = options;
    this.events = events;
    this.busyNow = busy;
  }
  /// The test ends the running turn.
  end(outcome: TurnOutcome) {
    this.busyNow = false;
    this.events({ type: "turnEnded", outcome });
  }
  complete() {
    this.end({ kind: "completed" });
  }
  id() {
    return this.sessionId;
  }
  busy() {
    return this.busyNow;
  }
  async prompt(text: string) {
    if (this.disposed) throw new Error("disposed");
    if (this.busyNow) throw new Error("busy");
    this.busyNow = true;
    this.prompts.push(text);
  }
  async steer(text: string) {
    if (!this.busyNow || this.unsteerable) return false;
    this.steers.push(text);
    return true;
  }
  async backgroundTools() {
    this.backgrounds++;
  }
  async abort() {
    this.aborts++;
  }
  async dispose() {
    this.disposed = true;
  }
  snapshot() {
    return { id: this.sessionId, busy: this.busyNow };
  }
  detach() {}
}

export class FakeDriver implements AgentDriver {
  readonly kind: "claude" | "codex";
  sessions: FakeSession[] = [];
  /// Runtime session ids that resume fails for.
  unresumable = new Set<string>();
  private n = 1;
  /// Times every process it started was ended.
  shutdowns = 0;

  constructor(kind: "claude" | "codex") {
    this.kind = kind;
  }
  runtime() {
    return this.kind;
  }
  last(): FakeSession {
    const last = this.sessions.at(-1);
    if (!last) throw new Error("a session opened");
    return last;
  }
  count() {
    return this.sessions.length;
  }
  async open(options: OpenOptions, events: (event: RuntimeEvent) => void) {
    if (options.resume !== undefined && this.unresumable.has(options.resume)) throw new Error("no such session");
    const session = new FakeSession(options.resume ?? `${this.kind}-${this.n++}`, options, events);
    this.sessions.push(session);
    return session;
  }
  async adopt(options: OpenOptions, snapshot: unknown, events: (event: RuntimeEvent) => void) {
    const handed = snapshot as { id: string; busy: boolean } | null;
    if (!handed) throw new Error("no runner");
    const session = new FakeSession(handed.id, options, events, handed.busy);
    this.sessions.push(session);
    return session;
  }
  async shutdown() {
    this.shutdowns++;
  }
  detach() {}
}

/// Lets queued actor tasks and what they started run.
export async function settle(rounds = 100) {
  for (let i = 0; i < rounds; i++) await new Promise((r) => setImmediate(r));
}

export const message = (over: Partial<InboundMessage> = {}): InboundMessage => {
  const ts = `${1000 + next()}.000100`;
  return { channel: "C1", threadTs: ts, ts, user: "U1", text: "<@UBOT> hello", addressed: true, ...over };
};
export const say = (text: string, over: Partial<InboundMessage> = {}) => message({ text, ...over });
/// A reply in a thread, not addressed to anyone.
export const reply = (to: InboundMessage, ts: string, text: string, over: Partial<InboundMessage> = {}): InboundMessage => ({
  channel: to.channel,
  threadTs: to.threadTs,
  ts,
  user: "U1",
  text,
  addressed: false,
  ...over,
});

export type Setup = { maxNudges?: number; maxWarmClaude?: number; warmMinutes?: number; teamRequireMention?: boolean; link?: boolean; cold?: ColdStorage; clock?: Clock.Clock };

/// A TestClock for a rig (its hub's, its store's, its sessions'): `adjust(ms)` moves it on, and what was due by then runs.
/// `asked()` counts the waits begun on it; `begun(n)` resolves once `n` have, each then sleeping on it (an adjust
/// reaches it): what a test waits for before it moves the time, rather than for a while.
export function testClock(): { clock: Clock.Clock; adjust(ms: number): Promise<void>; asked(): number; begun(n: number): Promise<void> } {
  const scope = Effect.runSync(Scope.make());
  const test = Effect.runSync(Scope.provide(TestClock.make(), scope));
  let asked = 0;
  let heard: (() => void)[] = [];
  const clock: Clock.Clock = {
    ...test,
    sleep: (d) =>
      Effect.suspend(() => {
        asked++;
        for (const wake of heard.splice(0)) wake();
        return test.sleep(d);
      }),
  };
  const begun = async (n: number) => {
    while (asked < n) await new Promise<void>((r) => heard.push(r));
    // Its sleep is on the clock once the fiber that began it has gone on.
    await settle(5);
  };
  return { clock, adjust: (ms) => Effect.runPromise(test.adjust(`${ms} millis`)), asked: () => asked, begun };
}

export class Rig {
  dir: string;
  raw: Json;
  config: HubConfig;
  store: Store;
  chat = new FakeChat("UBOT");
  gptChat = new FakeChat("UGPT");
  teamChat = new FakeChat("UTEAM");
  claude = new FakeDriver("claude");
  codex = new FakeDriver("codex");
  hub: Hub;
  clock: Clock.Clock | undefined;

  constructor(o: Setup = {}) {
    this.clock = o.clock;
    this.dir = mkdtempSync(join(tmpdir(), "hub-"));
    this.raw = {
      profiles: [
        { id: "cc", runtime: "claude", home: "homes/cc" },
        { id: "cx", runtime: "codex", home: "homes/cx" },
      ],
      connects: [
        { id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude", model: "opus", effort: "high" } },
        { id: "gpt", bind: { runtime: "codex" } },
        { id: "team", mode: "single-session", requireMention: o.teamRequireMention ?? true, bind: { runtime: "claude" } },
      ],
    };
    if (o.maxNudges !== undefined) this.raw.maxNudges = o.maxNudges;
    if (o.maxWarmClaude !== undefined) this.raw.maxWarmClaude = o.maxWarmClaude;
    if (o.warmMinutes !== undefined) this.raw.warmMinutes = o.warmMinutes;
    this.config = hubConfig(this.raw, this.dir);
    this.store = Store.open(":memory:", null, o.clock);
    const chats = new Map<string, ChatSurface>([
      ["cl", this.chat],
      ["gpt", this.gptChat],
      ["team", this.teamChat],
    ]);
    this.hub = this.newHub({ chats: (id) => chats.get(id), link: o.link, cold: o.cold });
  }

  /// A hub over this rig's store and config (another station's, after a restart: given its own drivers).
  newHub(o: { chats: (id: string) => ChatSurface | undefined; link?: boolean; cold?: ColdStorage; drivers?: AgentDriver[]; internal?: boolean }) {
    return new Hub({
      config: () => this.config,
      store: this.store,
      chats: o.chats,
      drivers: o.drivers ?? [this.claude, this.codex],
      mcpUrl: "http://127.0.0.1:1/mcp",
      internal: o.internal === false ? null : new InternalChat(),
      link: o.link ? (key) => `https://ember.test/o/ws/st/${key.replaceAll(":", "%3A")}` : undefined,
      runners: () => [],
      cold: o.cold,
      clock: this.clock,
    });
  }

  async accept(m: InboundMessage, connect = "cl") {
    await this.hub.accept(connect, m);
  }
  call(key: string, name: string, args: Json): Promise<string> {
    const tool = chatTools(this.hub).find((t) => t.name === name);
    if (!tool) throw new Error(`no tool ${name}`);
    return tool.run(key, args);
  }
  /// The error a call is refused with.
  async refused(key: string, name: string, args: Json): Promise<string> {
    try {
      await this.call(key, name, args);
    } catch (error) {
      return (error as Error).message;
    }
    throw new Error(`${name} was not refused`);
  }
  edit(change: (raw: Json) => void) {
    change(this.raw);
    this.config = hubConfig(this.raw, this.dir);
  }
  session(key: string) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`no session ${key}`);
    return row;
  }
  thread(channel: string, threadTs: string) {
    const row = this.store.threadAt("slack:T1", channel, threadTs);
    if (!row) throw new Error(`no thread ${channel}/${threadTs}`);
    return row;
  }
  said(thread: number) {
    return this.store.messagesBefore(thread, null, 10);
  }
  async close() {
    await this.hub.shutdown();
    this.store.close();
    rmSync(this.dir, { recursive: true, force: true });
  }
}

/// Whether `parts` are in `text`, in this order.
export function matches(text: string, parts: string[]): boolean {
  let rest = text;
  for (const part of parts) {
    const at = rest.indexOf(part);
    if (at < 0) return false;
    rest = rest.slice(at + part.length);
  }
  return true;
}
