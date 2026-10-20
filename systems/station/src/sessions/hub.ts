// Routes chat messages to session actors and creates sessions (the Rust station's hub.rs). Several connects share one hub;
// each has its own chat connection and its own sessions.
//
// A connect's mode decides the sessions: multi-session gives each thread its own session (started by an @mention);
// single-session sends every thread the connect sees into the one session bound to it, which people can switch or
// replace. Either way every message carries its source and the agent names the thread it answers, so a session never
// assumes it belongs to one conversation; replies go out through whichever connect the thread came in on.
//
// Everything said in a thread is recorded once (the store): people's messages are delivered to every session in the
// thread, and what agents and the station post there is recorded after the platform takes it.
//
// The Rust hub is one 2500-line type; here it is this core (actors, routing, holds, handover, eviction) and modules
// beside it, each a group of what the hub does: accounts.ts (which profile), conversations.ts (what agents post and
// read in their chats), others.ts (other chats), messages.ts (session_send), titles.ts, lifecycle.ts (sessions and
// chats made, archived, deleted), review.ts (the archive suggestion). The tools (src/tools/) are built on it.
//
// Redesigned where docs/station-ts.md asks: no settle-by-polling and no handing over of processes: at a handover the
// hub holds turns, waits until every actor's queue has run what it had (`flushed`, pushed, not polled), and snapshots
// every actor into <data>/run/handover.json; the runners keep the processes. A starting hub takes them up from that
// file (`takeUp`), and from the runners a crashed station left (no snapshot), then `recover` resumes the turns marked
// running that nothing took up.
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Clock, Effect, Fiber } from "effect";
import { liveClock, within } from "../ops/fibers.ts";
import type { AgentDriver, AgentSession } from "../agents/runtime.ts";
import { runnerId } from "../agents/process.ts";
import { allLeft, findRunner } from "../agents/runner.ts";
import { log } from "../ops/log.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import { iso, transcriptPaths } from "../read/transcript.ts";
import { type Attachment, type SessionRow, type Store, STILLFAIL_SURFACE, slackSurface, type ThreadRow } from "../store/store.ts";
import { Accounts } from "./accounts.ts";
import { SessionActor, type SessionDeps, type SessionStatus, type Snapshot, openOptions } from "./actor.ts";
import { isStopCommand } from "./args.ts";
import type { ChatEvent, ChatSurface, InboundFile, InboundMessage, ThreadRef } from "./chat.ts";
import { toolStatus } from "./chat.ts";
import { type Connect, type HubConfig, profilesFor, runtimeNamed } from "./config.ts";
import { INTERNAL_CONNECT, type InternalChat, nextTsAt } from "./internal.ts";
import { TASK_CONNECT, TASK_SURFACE } from "../tasks/names.ts";
import { LiveHub } from "./live.ts";
import type { Jobs } from "./neighbours.ts";
import { agentHomePaths } from "./agent-home.ts";
import { startsAfresh } from "./afresh.ts";
import { serves } from "./pool.ts";
import { imageSize } from "./image-size.ts";

type Json = any;

/// A multi-session connect's session for one thread.
export const sessionKey = (connect: string, channel: string, threadTs: string) => `${connect}:${channel}:${threadTs}`;

/// A new session for a single-session connect.
export const newSingleSessionKey = (connect: string) => `${connect}:s-${randomBytes(4).toString("hex")}`;

/// A new session talked to in the station's chat.
export const newChatKey = () => `${INTERNAL_CONNECT}:c-${randomBytes(5).toString("hex")}`;

/// The bearer token a session presents to the MCP endpoint.
export const newToken = () => randomBytes(24).toString("base64url");

/// Why turns are held. Each is taken back on its own: a station drained for a restart while in no workspace takes no
/// turns once the drain ends either.
/// - drain: a restart or handover is coming.
/// - unbound: the station is in no workspace (never joined one, or removed from it): it does no work until it is.
export type Hold = "drain" | "unbound";

/// Cold storage of archived sessions' files (archive.rs, footprint.rs): an archived, idle session's workspace and
/// transcripts packed, and restored before its runtime starts again or when it is shown again. The station's is
/// cold.ts; the default keeps nothing cold.
export interface ColdStorage {
  isCold(key: string): boolean;
  restore(key: string): void | Promise<void>;
  /// Packs what it can of an archived, idle session.
  pack(key: string): void | Promise<void>;
}

/// The most of a shared file the station fetches, as much as an agent may attach.
const MAX_INBOUND_FILE = 50 * 1024 * 1024;

const NOTHING_COLD: ColdStorage = { isCold: () => false, restore: () => {}, pack: () => {} };

/// What the hub hands to the next station: each actor's snapshot (handover.json).
export type Handover = { sessions: Snapshot[] };

export type HubOptions = {
  /// Read on every use, so edits apply to the next decision.
  config: () => HubConfig;
  store: Store;
  /// The connected connects by id; configured connects without one are offline.
  chats: (connect: string) => ChatSurface | undefined;
  drivers: AgentDriver[];
  /// The agents' MCP endpoint (a function when it is known only once its server listens).
  mcpUrl: string | (() => string);
  /// The station's own chat on its pages; sessions can be talked to there too.
  internal?: InternalChat | null;
  /// A session's page in still.fail (its /o/ link), when the station is in a workspace.
  link?: (key: string) => string | undefined;
  /// The runners there on this machine now, by id (default: those of <data>/run/runners whose socket answers).
  runners?: () => string[];
  cold?: ColdStorage;
  /// Its time, and its sessions' (a TestClock in tests).
  clock?: Clock.Clock;
};

/// The handover file, in the data directory.
export const handoverFile = (dataDir: string) => join(dataDir, "run", "handover.json");

export class Hub {
  readonly options: HubOptions;
  readonly store: Store;
  readonly internal: InternalChat | null;
  readonly drivers: Map<string, AgentDriver>;
  readonly link: (key: string) => string | undefined;
  readonly cold: ColdStorage;
  readonly accounts: Accounts;
  readonly clock: Clock.Clock;
  /// What running turns are doing, for the pages' live view.
  readonly live: LiveHub;
  readonly actors = new Map<string, SessionActor>();
  /// When each idle process is next looked at for eviction.
  private deadlines = new Map<string, Fiber.Fiber<void>>();
  /// Fibers of the hub's own (title waits, archive reviews): interrupted at shutdown.
  readonly fibers = new Set<Fiber.Fiber<void>>();
  /// Why turns are held (SessionDeps.held): held while any reason stands.
  private holdsNow = new Set<Hold>();
  /// Sessions taken up from the previous station: their turns run on, not cut off.
  private adopted = new Set<string>();
  /// Chats made lately by session key: the key their client gave them, and when (NewChat.clientKey).
  readonly clientKeysMade = new Map<string, [string, number]>();
  /// Titles agents gave chats someone has open, waiting until they leave (titles.ts), by thread.
  readonly titles = new Map<number, string>();
  /// One message at a time per thread: Slack sends a mention twice (app_mention and message), and both would make its
  /// session.
  readonly gates = new Map<string, { tail: Promise<void>; waiting: number }>();
  /// The station's background jobs (made after the hub, which tells their agents).
  jobs: Jobs | null = null;
  private closedHook: ((key: string) => void) | null = null;
  private peersHook: ((station: string, request: Json) => Promise<Json>) | null = null;
  private tasks: ChatSurface | null = null;
  readonly deps: SessionDeps;

  constructor(options: HubOptions) {
    this.options = options;
    this.clock = options.clock ?? liveClock;
    this.store = options.store;
    this.internal = options.internal ?? null;
    this.drivers = new Map(options.drivers.map((d) => [d.runtime(), d]));
    this.link = options.link ?? (() => undefined);
    this.cold = options.cold ?? NOTHING_COLD;
    this.accounts = new Accounts({
      config: () => this.config(),
      store: this.store,
      running: () => [...this.actors.values()].filter((a) => a.processState() !== "cold").flatMap((a) => this.store.getSession(a.key)?.profile ?? []),
      clock: this.clock,
    });
    this.live = new LiveHub(
      (key) => {
        const row = this.store.getSession(key);
        const profile = row && this.config().profiles.find((p) => p.id === row.profile);
        const runtime = row && runtimeNamed(row.runtime);
        if (!row || !profile || !runtime || !row.runtimeSessionId) return null;
        const homes = [profile.home, ...this.config().profiles.map((p) => p.home).filter((h) => h !== profile.home)];
        const { paths, current } = transcriptPaths(runtime, homes, this.store.runtimeSessions(key));
        return paths.length === 0 ? null : { runtime, paths, current };
      },
      this.clock,
    );
    this.deps = this.sessionDeps();
  }

  config(): HubConfig {
    return this.options.config();
  }

  /// Now, by its clock.
  now(): number {
    return this.clock.currentTimeMillisUnsafe();
  }

  /// A Slack-style ts for something said now.
  nextTs(): string {
    return nextTsAt(this.now());
  }

  reposDir(): string {
    return join(this.config().dataDir, "repos");
  }

  // ── holds ──────────────────────────────────────────────────────────────────────────────────────────────────────

  /// Holds turns for `reason`: none starts from now on, and messages stay pending. Those running go on.
  hold(reason: Hold) {
    this.holdsNow.add(reason);
  }

  /// Takes back `reason` to hold turns; once none is left, turns start again and what waited meanwhile goes on.
  release(reason: Hold) {
    if (!this.holdsNow.delete(reason) || this.holdsNow.size > 0) return;
    for (const actor of this.actors.values()) void actor.release();
    for (const key of this.store.sessionsWithPending()) {
      const row = this.store.getSession(key);
      if (row) void this.actor(row).kick();
    }
  }

  /// Whether turns are held for `reason`.
  holds(reason: Hold): boolean {
    return this.holdsNow.has(reason);
  }

  /// The station left its workspace (turns are held first): every runtime process ends, running or idle, then what the
  /// drivers run themselves (codex's app-servers), so no agent goes on outside the workspace. Turns cut off stay marked
  /// running and messages given to them pending again (SessionActor.suspend): `recover` resumes them once the station
  /// is back in its workspace.
  async suspendAll() {
    for (const fiber of this.deadlines.values()) this.interrupt(fiber);
    this.deadlines.clear();
    // Taken up from the previous station or not, what was cut off now resumes the usual way.
    this.adopted.clear();
    await Promise.all([...this.actors.values()].map((a) => a.suspend()));
    await Promise.all([...this.drivers.values()].map((d) => d.shutdown()));
  }

  /// How many turns are running.
  running(): number {
    return [...this.actors.values()].filter((a) => a.processState() === "running").length;
  }

  anyRunning(): boolean {
    return this.running() > 0;
  }

  // ── handover ───────────────────────────────────────────────────────────────────────────────────────────────────

  /// Hands the sessions to the next station: turns held, every queue run out, each actor's snapshot written to
  /// <data>/run/handover.json, and the drivers let go of their processes (the runners keep them). Until the snapshot
  /// is taken it can fail (the queues did not settle within `limitMs`) and turns are released again; after, this hub
  /// does nothing more.
  async handOver(limitMs = 30_000): Promise<Handover> {
    this.hold("drain");
    try {
      await this.settled(limitMs);
    } catch (error) {
      this.release("drain");
      throw error;
    }
    // Settled: snapshotted at once, before anything else is taken in.
    const sessions: Snapshot[] = [];
    for (const actor of this.actors.values()) {
      if (actor.processState() !== "cold" || actor.holdsState()) sessions.push(actor.snapshot());
      else actor.close();
    }
    for (const driver of this.drivers.values()) driver.detach();
    // The next station attaches to their runners once this file is there: every ack is in by then.
    await allLeft();
    this.stopTimers();
    const handed: Handover = { sessions };
    const file = handoverFile(this.config().dataDir);
    mkdirSync(join(file, ".."), { recursive: true });
    writeFileSync(file, JSON.stringify(handed));
    log.info("hub", "handed over", { sessions: sessions.length });
    return handed;
  }

  /// Resolves once no actor has a task queued or running: each queue is run out, and again while new tasks came
  /// meanwhile (a runtime's events). Fails after `limitMs`.
  private async settled(limitMs: number) {
    const runOut = async () => {
      for (;;) {
        await Promise.all([...this.actors.values()].map((a) => a.flushed()));
        if ([...this.actors.values()].every((a) => a.settled())) return;
      }
    };
    await within(this.clock, limitMs, runOut(), () => new Error(`sessions did not settle within ${Math.round(limitMs / 1000)} s`));
  }

  /// Takes up what the previous station left: the snapshots of its handover, then the runners it left without one (it
  /// crashed). Sessions taken up with their runtime run on; a turn marked running whose runtime is gone is `recover`'s.
  async takeUp() {
    const file = handoverFile(this.config().dataDir);
    let handed: Handover = { sessions: [] };
    if (existsSync(file)) {
      try {
        handed = JSON.parse(readFileSync(file, "utf8"));
      } catch (error) {
        log.warn("hub", "the handover file does not read; sessions resume the usual way", { error: (error as Error).message });
      }
      rmSync(file, { force: true });
    }
    await this.adopt(handed);
    // A crash left runners without a snapshot: what they keep is taken up as it stands.
    const kept = async (id: string) => (this.options.runners ? this.options.runners().includes(id) : (await findRunner(this.config().dataDir, id)) !== undefined);
    const taken = new Set(handed.sessions.map((s) => s.key));
    for (const row of this.store.listSessions()) {
      if (taken.has(row.key)) continue;
      const runtime = runtimeNamed(row.runtime);
      // Claude's runner is the session's own (an idle one is taken up too); codex sessions share their profile's host,
      // which its driver finds, for a turn that was running.
      if (!runtime || (runtime === "claude" ? !(await kept(runnerId("claude", row.key))) : !row.running)) continue;
      const turn = row.running ? this.store.listTurns(row.key).at(-1) : undefined;
      const snap: Snapshot = {
        key: row.key,
        runtime,
        agent: null,
        turn: turn && turn.summary.endedAt === null ? { id: turn.id, authRetried: turn.summary.kind === "auth_retry", by: { profile: null, person: null, thread: null }, declared: null, wait: null } : null,
        workingFor: [],
        notices: [],
        waitingMs: null,
        waitingSeconds: 0,
        nudges: 0,
        stopRequested: false,
      };
      await this.adoptOne(row, snap, true);
    }
  }

  /// Takes up a handover's snapshots (sessions handed over by the previous station).
  async adopt(handed: Handover) {
    for (const snap of handed.sessions) {
      const row = this.store.getSession(snap.key);
      if (!row) {
        log.warn("hub", "session handed over is gone", { session: snap.key });
        continue;
      }
      await this.adoptOne(row, snap, snap.agent !== null);
    }
  }

  private async adoptOne(row: SessionRow, snap: Snapshot, withProcess: boolean) {
    let actor: SessionActor;
    try {
      actor = this.actor(row);
    } catch (error) {
      log.warn("hub", "session handed over could not be taken up; it resumes the usual way", { session: row.key, error: (error as Error).message });
      return;
    }
    let agent: AgentSession | null = null;
    if (withProcess) {
      try {
        const driver = this.sessionDriver(snap.runtime);
        const generation = actor.nextGeneration();
        agent = await driver.adopt(openOptions(row, this.accounts.runOn(row.key), this.deps), snap.agent, actor.listener(generation));
      } catch (error) {
        log.warn("hub", "a session's runtime could not be taken up; it resumes the usual way", { session: row.key, error: (error as Error).message });
      }
    }
    // Its runtime not taken up: a turn it had is resumed the usual way (recover).
    if (withProcess && !agent) return;
    actor.adopt(snap, agent);
    log.info("hub", "session taken up from the previous station", { session: row.key, withAgent: agent !== null });
    if (agent) {
      this.adopted.add(row.key);
      if (!snap.turn) this.idleNow(row.key);
    }
    if (snap.notices.length > 0) void actor.release();
  }

  // ── messages in ────────────────────────────────────────────────────────────────────────────────────────────────

  /// Takes one event from a connect's platform. Resolves once it is durably recorded (or deliberately ignored).
  async receive(connectId: string, event: ChatEvent) {
    if (event.type === "message") return this.accept(connectId, event.message);
    this.store.editMessage(this.surface(connectId), event.channel, event.threadTs, event.ts, event.text);
  }

  /// Accepts one message seen by a connect, one at a time per thread. Resolves once it is durably recorded (or
  /// deliberately ignored).
  async accept(connectId: string, message: InboundMessage) {
    const at = `${this.surface(connectId)}\0${message.channel}\0${message.threadTs}`;
    let gate = this.gates.get(at);
    if (!gate) this.gates.set(at, (gate = { tail: Promise.resolve(), waiting: 0 }));
    gate.waiting++;
    const turn = gate.tail.then(() => this.acceptInTurn(connectId, message));
    gate.tail = turn.then(
      () => {},
      () => {},
    );
    try {
      return await turn;
    } finally {
      // No one waits on it any more.
      if (--gate.waiting === 0 && this.gates.get(at) === gate) this.gates.delete(at);
    }
  }

  private async acceptInTurn(connectId: string, message: InboundMessage) {
    const config = this.config();
    // What a bot of this station posted is its agent's, recorded and handed to the thread as it was posted: Slack's
    // copy of it, seen through another connect, is not a message of its own.
    if (this.ownBot(config, message.user)) return;
    const connect = connectOf(config, connectId);
    const chat = this.chat(connectId);
    const surface = this.surface(connectId);
    const single = connect.mode === "single-session";
    const bound = single ? this.store.binding(connect.id) : null;
    const key = bound ?? (single ? newSingleSessionKey(connect.id) : sessionKey(connect.id, message.channel, message.threadTs));
    const existing = this.store.threadAt(surface, message.channel, message.threadTs);
    const members = existing ? this.store.threadSessions(existing.id) : [];
    const exists = this.store.getSession(key) !== null;
    const wanted = single ? message.addressed || !connect.requireMention || (exists && members.some((m) => m.session === key)) : exists || message.addressed;
    // Chatter this connect is not part of, in a thread no session takes part in.
    if (!wanted && members.length === 0) return;
    const here: ThreadRef = { channel: message.channel, threadTs: message.threadTs };
    const createdBy = `slack:${connect.id}:${message.user}`;
    if (wanted && !exists) {
      try {
        this.createSession(config, key, connect, single ? "all" : "thread", message, null, createdBy);
        if (single) this.store.setBinding(connect.id, key);
      } catch (error) {
        log.error("hub", "cannot create session", { session: key, error: (error as Error).message });
        await chat.post(here, `⚠️ ${tr(stationLang(), "station.slack.sessionFailed", { error: (error as Error).message })}`, []);
        return;
      }
      // As the broker did: a new session says first where it can be followed. Once, as it starts; not waited for. In
      // Slack's own link form: what the station posts is sent as written.
      const link = single ? undefined : this.link(key);
      if (link !== undefined) {
        chat.post(here, `<${link}|${tr(stationLang(), "station.slack.viewSession")}>`, []).catch((error) => log.warn("hub", "session link not posted", { session: key, error: (error as Error).message }));
      }
    }
    const thread = existing ?? (await this.openSlackThread(chat, surface, message, createdBy, key));
    if (wanted) this.store.joinThread(thread.id, key, connect.id);
    // Its files go where a session of the thread reads them; once (Slack sends a message again it was slow to hear of).
    const into = wanted ? key : (members[0]?.session ?? key);
    const said = this.store.messageAt(thread.id, message.ts) === null ? await this.fetched(chat, into, message.text, message.files) : { text: message.text, attachments: [] };
    const [n, fresh] = this.store.insertMessage({ thread: thread.id, ts: message.ts, authorKind: "person", author: message.user, ...said });
    // A message seen by a second connect is already delivered to the thread; only a session it brings in lacks it.
    const targets = fresh ? this.store.threadSessions(thread.id).map((m) => m.session) : wanted ? [key] : [];
    this.deliver(thread.id, n, targets, message.text);
  }

  /// A Slack thread the station starts following. When that happens mid-thread, what was said before is recorded first
  /// (without deliveries), so the thread on the pages and chat_history are complete and the log keeps Slack's order.
  private async openSlackThread(chat: ChatSurface, surface: string, message: InboundMessage, createdBy: string, key: string): Promise<ThreadRow> {
    let earlier: { ts: string; user: string; text: string; files?: InboundFile[] }[] = [];
    if (message.ts !== message.threadTs) {
      try {
        earlier = (await chat.history?.({ channel: message.channel, threadTs: message.threadTs }, message.ts, 200)) ?? [];
      } catch (error) {
        log.warn("hub", "cannot read what the thread said before; continuing without it", { channel: message.channel, threadTs: message.threadTs, error: (error as Error).message });
      }
    }
    // Asked before the thread exists, so a connect seeing the same message meanwhile cannot record it ahead of these.
    const said = [];
    for (const m of earlier) said.push({ ...m, ...(await this.fetched(chat, key, m.text, m.files)) });
    const thread = this.store.openThread(surface, message.channel, message.threadTs, null, createdBy);
    for (const m of said) this.store.insertMessage({ thread: thread.id, ts: m.ts, authorKind: "person", author: m.user, text: m.text, attachments: m.attachments });
    return thread;
  }

  /// A message's text and its shared files, fetched into the session's uploads (as files sent in the station's own
  /// chats are). A file that cannot be fetched is named in the text with why, so its reader knows one was there.
  private async fetched(chat: ChatSurface, key: string, text: string, files: InboundFile[] | undefined): Promise<{ text: string; attachments: Attachment[] }> {
    const row = files && files.length > 0 ? this.store.getSession(key) : null;
    if (!files || !row) return { text, attachments: [] };
    const dir = join(row.workspace, "uploads");
    const attachments: Attachment[] = [];
    const missing: string[] = [];
    for (const file of files) {
      try {
        if (!chat.download) throw new Error("this platform does not give files");
        if (file.size > MAX_INBOUND_FILE) throw new Error("over 50 MB");
        const bytes = await chat.download(file);
        mkdirSync(dir, { recursive: true });
        const safe = Array.from(file.name)
          .map((c) => (c === "\\" || c === "/" || c.codePointAt(0)! < 0x20 ? "_" : c))
          .join("");
        const path = join(dir, `${iso(this.now()).slice(0, 19).replace(/[:.]/g, "-")}-${file.id}-${safe}`);
        writeFileSync(path, bytes);
        const attachment: Attachment = { name: file.name, path, size: bytes.length };
        const size = /\.(png|jpe?g|gif|webp)$/i.test(file.name) ? imageSize(path) : null;
        if (size) [attachment.width, attachment.height] = size;
        attachments.push(attachment);
      } catch (error) {
        log.warn("hub", "shared file not fetched", { session: key, file: file.id, error: (error as Error).message });
        missing.push(tr(stationLang(), "station.slack.fileNotFetched", { name: file.name, error: (error as Error).message }));
      }
    }
    return { text: [text, ...missing].filter((t) => t !== "").join("\n\n"), attachments };
  }

  /// Gives sessions a message they have not had: each runs it, or stops for `-stop` (hub.rs `hand_over`).
  deliver(thread: number, n: number, sessions: string[], text: string) {
    for (const key of this.store.deliver(thread, n, sessions)) {
      this.store.touch(key);
      const row = this.store.getSession(key);
      if (!row) continue;
      const actor = this.actor(row);
      if (isStopCommand(text)) {
        this.store.markDelivered(key, [[thread, n]]);
        void actor.stop();
      } else void actor.kick();
    }
  }

  /// An agent's post reaches the other sessions of its thread, as a person's would: agents work together there.
  shared(thread: number, n: number, author: string, text: string) {
    const others = this.store.threadSessions(thread).map((m) => m.session).filter((s) => s !== author);
    if (others.length > 0) this.deliver(thread, n, others, text);
  }

  /// After a restart: resume cut-off turns (those not taken up with their runtime), then deliver whatever is still
  /// pending.
  recover() {
    for (const row of this.store.listSessions().filter((s) => s.running)) {
      // Taken up from the previous station: its turn runs on.
      if (this.adopted.has(row.key) || !this.online(row)) continue;
      log.info("hub", "recovering a turn cut off by restart", { session: row.key });
      void this.actor(row).recover();
    }
    for (const key of this.store.sessionsWithPending()) {
      const row = this.store.getSession(key);
      if (row && this.online(row)) void this.actor(row).kick();
    }
  }

  // ── warm processes ─────────────────────────────────────────────────────────────────────────────────────────────

  /// Ends idle claude processes beyond the warm limit, oldest first, once they have idled past warmMs. Codex threads
  /// share a process and stay. Runs when a process goes idle (the count grew) and at each idle process's deadline.
  private evictIdle() {
    const config = this.config();
    const now = this.now();
    const idle = [...this.actors.values()]
      .filter((a) => a.runtime === "claude")
      .flatMap((a) => {
        const ms = a.idleMs(now);
        return ms === null ? [] : [[a, ms] as const];
      })
      .sort((a, b) => b[1] - a[1]);
    let excess = idle.length - config.maxWarmClaude;
    for (const [actor, ms] of idle) {
      if (excess <= 0 || ms < config.warmMs) break;
      void actor.evict();
      excess--;
    }
  }

  /// A process went idle: look again when it has idled past warmMs.
  idleNow(key: string) {
    // A manual archive may have arrived during the last turn. Finish that archive when the turn ends; never sweep old
    // directories on a clock or at startup.
    const row = this.store.getSession(key);
    if (row && row.archivedAt !== null) {
      const actor = this.actor(row);
      void actor.evict().then(() => actor.cleanArchive());
    }
    const old = this.deadlines.get(key);
    if (old) this.interrupt(old);
    const fiber = this.runFork(
      Effect.sleep(this.config().warmMs).pipe(
        Effect.andThen(
          Effect.sync(() => {
            this.deadlines.delete(key);
            this.evictIdle();
          }),
        ),
      ),
    );
    this.deadlines.set(key, fiber);
    this.evictIdle();
  }

  /// Ends the session's runtime process if it is idle; the conversation resumes on the next message.
  async evict(key: string) {
    await this.actors.get(key)?.evict();
  }

  /// Starts a session's runtime ahead of a message (SessionActor.warm).
  async warm(key: string) {
    const row = this.store.getSession(key);
    if (row) await this.actor(row).warm();
  }

  /// Interrupts the session's running turn, or what it waits on, as `-stop` in a thread would.
  async stop(key: string) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    await this.actor(row).stop();
  }

  /// A word from the station for a session's agent, outside any conversation (SessionActor.notify).
  notify(key: string, text: string) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    void this.actor(row).notify(text);
  }

  /// Live process state of a session, for the pages.
  processState(key: string): "running" | "warm" | "cold" {
    return this.actors.get(key)?.processState() ?? "cold";
  }

  /// Where a session stands, for the host of a Task it takes part in (SessionActor.status). A read: no actor is made
  /// for it. One no actor has held since the station started is idle, for how long unknown; with messages pending
  /// (its connect offline, so `recover` did not take it up), it is idle with those pending: held, not worked on.
  sessionStatus(key: string): SessionStatus {
    const actor = this.actors.get(key);
    if (actor) return actor.status();
    return { state: "idle", pending: this.store.pendingMessages(key).length, for_ms: null, last_failure: null };
  }

  /// Every session's process state that is not cold (what the reads are given).
  processes(): Map<string, string> {
    return new Map([...this.actors].flatMap(([key, a]) => (a.processState() === "cold" ? [] : [[key, a.processState()] as [string, string]])));
  }

  /// The key the client that asked for a session gave it (NewChat.clientKey), while it is kept.
  clientKey(key: string): string | undefined {
    const kept = this.clientKeysMade.get(key);
    return kept && this.now() - kept[1] < CLIENT_KEY_KEPT_MS ? kept[0] : undefined;
  }

  clientKeys(): Map<string, string> {
    return new Map([...this.clientKeysMade].filter(([, [, at]]) => this.now() - at < CLIENT_KEY_KEPT_MS).map(([key, [client]]) => [key, client]));
  }

  // ── what goes beside it ────────────────────────────────────────────────────────────────────────────────────────

  /// The station's background jobs, once they are made.
  setJobs(jobs: Jobs) {
    this.jobs = jobs;
  }

  /// What to do when a session is archived or deleted (Remote.closeSession).
  onClose(closed: (key: string) => void) {
    this.closedHook = closed;
  }

  closed(key: string) {
    this.closedHook?.(key);
  }

  /// The surface of Tasks of other stations (tasks.ts), once it is made.
  setTasks(tasks: ChatSurface) {
    this.tasks = tasks;
  }

  /// Hooks session_send up to the other stations of the workspace.
  onPeer(call: (station: string, request: Json) => Promise<Json>) {
    this.peersHook = call;
  }

  peers() {
    return this.peersHook;
  }

  async shutdown() {
    this.stopTimers();
    this.live.close();
    await Promise.all([...this.actors.values()].map((a) => a.dispose()));
    await Promise.all([...this.drivers.values()].map((d) => d.shutdown()));
  }

  private stopTimers() {
    for (const fiber of [...this.deadlines.values(), ...this.fibers]) this.interrupt(fiber);
    this.deadlines.clear();
    this.fibers.clear();
  }

  /// Runs `effect` as a fiber of the hub's own, interrupted at shutdown or handover.
  fork(effect: Effect.Effect<void>) {
    // It may end before runFork returns.
    const held: { fiber?: Fiber.Fiber<void>; done?: boolean } = {};
    held.fiber = this.runFork(
      effect.pipe(
        Effect.ensuring(
          Effect.sync(() => {
            held.done = true;
            if (held.fiber) this.fibers.delete(held.fiber);
          }),
        ),
      ),
    );
    if (!held.done) this.fibers.add(held.fiber);
  }

  /// Runs `effect` on the hub's clock.
  private runFork<A>(effect: Effect.Effect<A>): Fiber.Fiber<A> {
    return Effect.runFork(effect.pipe(Effect.provideService(Clock.Clock, this.clock)));
  }

  private interrupt(fiber: Fiber.Fiber<void>) {
    Effect.runFork(Fiber.interrupt(fiber));
  }

  // ── chats and connects ─────────────────────────────────────────────────────────────────────────────────────────

  chat(connect: string): ChatSurface {
    const chat = this.chatOf(connect);
    if (!chat) throw new Error(`connect ${connect} is not connected`);
    return chat;
  }

  chatOf(connect: string): ChatSurface | undefined {
    if (connect === INTERNAL_CONNECT) return this.internal ?? undefined;
    if (connect === TASK_CONNECT) return this.tasks ?? undefined;
    return this.options.chats(connect);
  }

  /// Where a connect's threads live; the rule the v10 migration follows too.
  surface(connect: string): string {
    if (connect === INTERNAL_CONNECT) return STILLFAIL_SURFACE;
    if (connect === TASK_CONNECT) return TASK_SURFACE;
    return slackSurface(connect, this.chatOf(connect)?.workspace() ?? null);
  }

  /// A Slack user that is one of this station's connects' bots.
  private ownBot(config: HubConfig, user: string): boolean {
    return config.connects.some((c) => {
      const bot = this.chatOf(c.id)?.botUserId() ?? "";
      return bot !== "" && bot === user;
    });
  }

  private online(row: SessionRow): boolean {
    const via = this.store.latestThread(row.key)?.connect ?? row.connect;
    if (this.chatOf(via)) return true;
    log.warn("hub", "session's latest thread came through a connect that is not connected; leaving it", { session: row.key, connect: via });
    return false;
  }

  /// A session for a connect: the connect's own profile when it keeps to one (and it still can run it); else any of its
  /// runtime, the model's first (pool.ts).
  createSession(config: HubConfig, key: string, connect: Connect, scope: "thread" | "all", message: InboundMessage | null, title: string | null, createdBy: string | null) {
    const fits = profilesFor(config, connect);
    const model = connect.bind.model ?? null;
    const kept = connect.bind.profile !== undefined ? fits.find((p) => p.id === connect.bind.profile && serves(p, model)) : undefined;
    const profile = kept ?? this.accounts.pick(fits, model, false);
    const dir = scope === "thread" && message ? `${message.channel}-${message.threadTs.replace(".", "-")}` : key.slice(connect.id.length + 1);
    const workspace = join(config.dataDir, "sessions", connect.id, dir, "workspace");
    mkdirSync(workspace, { recursive: true });
    mkdirSync(join(config.dataDir, "repos"), { recursive: true });
    const now = this.now();
    this.store.insertSession({
      key,
      connect: connect.id,
      scope,
      title,
      createdBy,
      runtime: connect.bind.runtime,
      profile: profile.id,
      profilePinned: kept !== undefined,
      model: connect.bind.model ?? null,
      effort: connect.bind.effort ?? null,
      fast: null,
      workspace,
      cwd: null,
      runtimeSessionId: null,
      token: newToken(),
      createdAt: now,
      lastActiveAt: now,
    });
    log.info("hub", "session created", { session: key, connect: connect.id, scope, runtime: connect.bind.runtime, profile: profile.id });
  }

  /// The session's actor, made on first use.
  actor(row: SessionRow): SessionActor {
    const existing = this.actors.get(row.key);
    if (existing) return existing;
    const runtime = runtimeNamed(row.runtime);
    if (!runtime) throw new Error(`session ${row.key} runs an unknown runtime ${row.runtime}`);
    const actor = new SessionActor(row.key, runtime, this.deps);
    this.actors.set(row.key, actor);
    return actor;
  }

  /// Takes a session's actor out (deleted).
  dropActor(key: string): SessionActor | undefined {
    const actor = this.actors.get(key);
    this.actors.delete(key);
    const deadline = this.deadlines.get(key);
    if (deadline) this.interrupt(deadline);
    this.deadlines.delete(key);
    return actor;
  }

  private sessionDriver(runtime: string): AgentDriver {
    const driver = this.drivers.get(runtime);
    if (!driver) throw new Error(`no ${runtime} driver`);
    return driver;
  }

  /// What a session needs of the station (SessionDeps).
  private sessionDeps(): SessionDeps {
    return {
      store: this.store,
      chat: (connect) => this.chatOf(connect),
      driver: (runtime) => this.sessionDriver(runtime),
      runOn: (key) => this.accounts.runOn(key),
      spend: (key) => this.accounts.spend(key),
      mcpUrl: () => (typeof this.options.mcpUrl === "string" ? this.options.mcpUrl : this.options.mcpUrl()),
      reposDir: () => this.reposDir(),
      memoryPath: () => agentHomePaths(this.config().agentHome)[0],
      maxNudges: () => this.config().maxNudges,
      backgroundOnMessage: (key) => {
        const row = this.store.getSession(key);
        if (!row) return true;
        return this.config().profiles.find((p) => p.id === row.profile)?.backgroundOnMessage ?? true;
      },
      live: this.live,
      startsAfresh: (key, id, to, was) => startsAfresh(this, key, id, to, was),
      ranIn: (key, id, profile) => this.store.ranIn(key, id, profile),
      idle: (key) => this.idleNow(key),
      archiveIsCold: (key) => this.cold.isCold(key),
      restoreArchive: (key) => this.cold.restore(key),
      cleanArchive: (key) => this.cold.pack(key),
      held: () => this.holdsNow.size > 0,
      stopJobs: async (key) => {
        const jobs = this.jobs;
        const running = this.store.listJobs(key).filter((j) => j.state === "running" && (j.watch || j.port === null));
        if (!jobs) return;
        for (const job of running) {
          try {
            await jobs.stop(job.id);
            log.info("hub", "job stopped with its session's wait", { session: key, job: job.id });
          } catch (error) {
            log.warn("hub", "job not stopped", { session: key, job: job.id, error: (error as Error).message });
          }
        }
      },
      toolStatus,
      nextTs: () => this.nextTs(),
      clock: this.clock,
    };
  }
}

/// How long a new chat's rows say the key its client gave it: long past its answer.
export const CLIENT_KEY_KEPT_MS = 10 * 60 * 1000;

export function connectOf(config: HubConfig, id: string): Connect {
  const connect = config.connects.find((c) => c.id === id);
  if (!connect) throw new Error(`unknown connect ${id}`);
  return connect;
}
