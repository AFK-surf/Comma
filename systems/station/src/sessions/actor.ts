// One actor per session (the Rust station's session.rs): every change to a session's state runs through its serial queue, so
// runtime events, deliveries and tool calls never interleave halfway. Redesigned on two points (docs/station-ts.md):
// - Where it stands is one value (`phase`): idle, starting, running, waiting, or closed; not three flags kept apart.
// - What tools say of the running turn (its state, need, about, what it waits for) goes through the queue too, and the
//   tool answers once it is recorded: a turn's end comes after the tool's answer, so nothing a tool said is lost.
// Its process is a runner's (src/agents/runner.ts): this actor can go (a station stopping or handing over) and the
// next take it up (`snapshot` / `adopt`), its turn going on all along.
import { join } from "node:path";
import { Clock, Effect, Exit, FiberSet, Scope, Semaphore } from "effect";
import type { AgentDriver, AgentSession, LiveEvent, OpenOptions, Profile, RuntimeEvent, TurnOutcome } from "../agents/runtime.ts";
import { GO_ON_AFTER_AUTH, GO_ON_AFTER_SPENT, NUDGE, RESUME_AFTER_RESTART, RESUME_LOST, continuedHere, formatInbound, formatWidgetModels, sessionInstructions, waitOver } from "../agents/instructions.ts";
import { latest as latestNote, untold } from "../agents/migrations.ts";
import { unreadableDir, unreadableDirMessage } from "../ops/files.ts";
import { log } from "../ops/log.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import type { PostFrom } from "./chat.ts";

/// How an agent ended its turn (chat_post / chat_state `kind`).
export type DeclaredState = { kind: "all_done" } | { kind: "need_help" } | { kind: "waiting"; seconds: number };

/// A kind as kept or given, the words from before these included: final is all_done, block and need_decision need_help.
export function parseDeclared(kind: string, wait: number): DeclaredState | null {
  if (kind === "all_done" || kind === "final") return { kind: "all_done" };
  if (["need_human", "need_help", "block", "need_decision"].includes(kind)) return { kind: "need_help" };
  if (kind === "waiting") return { kind: "waiting", seconds: wait };
  return null;
}

/// The turn ended as the agent's to take up again only when a person (or nothing) brings it back: not waiting.
const settled = (d: DeclaredState) => d.kind !== "waiting";

export type TurnFor = { profile: string | null; person: string | null; thread: number | null };
const nobody: TurnFor = { profile: null, person: null, thread: null };

/// A chat thread the running turn works for, with the message that brought it in: it is told what the turn does.
type Working = { connect: string; channel: string; threadTs: string; ts: string | null };

/// What the actor needs of the store: the Rust Store's methods, camelCase (src/store/store.ts).
export type SessionStore = {
  pendingMessages(key: string): any[];
  markDelivered(key: string, pairs: [number, number][]): void;
  markUndelivered(key: string, pairs: [number, number][]): void;
  untoldWidgetModels(key: string): any[];
  markWidgetModelsTold(key: string, pairs: [string, string][]): void;
  heardThreads(key: string): Set<number> | number[];
  threadSessions(thread: number): { session: string; connect: string }[];
  getSession(key: string): any | null;
  hasTurns(key: string): boolean;
  toldNotes(key: string): number | null;
  setToldNotes(key: string, n: number): void;
  startTurnFor(id: string, key: string, kind: string, by: TurnFor): void;
  endTurn(id: string, outcome: string, detail: string | null, declared: string | null, wait: number | null): void;
  setRunning(key: string, running: boolean): void;
  setRuntimeSessionId(key: string, id: string): void;
  setWaitFor(turn: string, what: string): void;
  setNeed(turn: string, what: string): void;
  setAbout(turn: string, about: [number, number, string] | null): void;
  lastTurn(key: string): any | null;
  stopWait(key: string): void;
  listJobs(session: string | null): any[];
  latestThread(key: string): any | null;
  insertMessage(message: any): unknown;
  notify(key: string): void;
};

/// A chat surface, as far as a session uses one (chat/mod.rs `ChatSurface`).
export type Surface = {
  post(thread: { channel: string; threadTs: string }, text: string, files: unknown[], from?: PostFrom): Promise<string>;
  userName?(user: string): Promise<string | null>;
  working?(thread: { channel: string; threadTs: string }, messageTs: string | null, status: string): void;
  botName?(): string;
  botUserId?(): string;
};

/// What a session needs of the station; the hub gives it.
export type SessionDeps = {
  store: SessionStore;
  chat(connect: string): Surface | undefined;
  driver(runtime: "claude" | "codex"): AgentDriver;
  /// The profile a session's runtime starts on now: its own while usable, else another that can take it on.
  runOn(key: string): Profile & { spelling?(model: string): string | null };
  /// A turn ran into its profile's allowance: the profile left and the one moved to, when it moved.
  spend(key: string): [string, string] | null;
  mcpUrl(): string;
  reposDir(): string;
  memoryPath(): string;
  /// What a Session working in `workspace` is told besides the station's instructions: a coding Session's checkout
  /// and how it keeps its work (tasks/coding.ts); null for any other.
  workspaceInstructions(workspace: string): string | null;
  maxNudges(): number;
  backgroundOnMessage(key: string): boolean;
  /// Where the runtime's live steps go, for whoever watches the session (and that it went on in a new runtime session).
  live?: { event(key: string, event: LiveEvent): void; turnEnded(key: string): void; moved?(key: string): void };
  /// What it is told when it goes on on `to` in a new runtime session rather than take up `id` (last run on `was`, when
  /// the store does not know); null: it takes it up (sessions/afresh.ts).
  startsAfresh?(key: string, id: string | null, to: Profile, was: string | null): string | null;
  /// The runtime session it runs in, on `profile` (null: not known).
  ranIn?(key: string, id: string, profile: string | null): void;
  idle(key: string): void;
  archiveIsCold(key: string): boolean;
  restoreArchive(key: string): void | Promise<void>;
  /// An archived session's process is gone: its files may go to cold storage now (session.rs `clean_archive`).
  cleanArchive?(key: string): void | Promise<void>;
  /// Turns are held (the station is about to stop or hand over, or this session's workspace is being prepared): none
  /// starts, messages stay pending.
  held(key?: string): boolean;
  /// Stopped while it waits: ends the session's jobs that would bring it back.
  stopJobs(key: string): Promise<void>;
  toolStatus(tool: string): string;
  nextTs(): string;
  /// Its time (the hub's).
  clock: Clock.Clock;
};

type Turn = { id: string; declared: DeclaredState | null; authRetried: boolean; by: TurnFor };

/// Where a session stands: no runtime session; one starting up; a turn running; the agent waiting on work it started;
/// or the actor closed (its station stopping or handing over).
type Phase = "idle" | "running" | "waiting" | "closed";

/// Where a session stands, as the host of a Task it takes part in is told (`task.status`, tasks.ts): `running` (a turn
/// runs, or is starting), `waiting` (the agent declared it waits on work it started), `cannot_start` (messages are
/// pending but its runtime did not start, tried again backing off; `last_failure` says why last), `idle` (nothing runs,
/// nothing pending), or `gone` (no such Session). `pending`: messages not handed to it yet. `for_ms`: how long it has
/// been in this state (a duration, so the host's clock need not agree with this one's), null when not known (a Session
/// no actor has held since the station started).
export type SessionStatus = {
  state: "running" | "waiting" | "idle" | "cannot_start" | "gone";
  pending: number;
  for_ms: number | null;
  last_failure: string | null;
};

/// At most this much of why a turn did not start goes in a status.
const LAST_FAILURE_CHARS = 200;

/// What a next station takes up from this one (session.rs `HandedSession`, without the process: the runner keeps it).
export type Snapshot = {
  key: string;
  runtime: "claude" | "codex";
  agent: unknown | null;
  turn: { id: string; authRetried: boolean; by: TurnFor; declared: string | null; wait: number | null } | null;
  workingFor: Working[];
  notices: string[];
  waitingMs: number | null;
  waitingSeconds: number;
  nudges: number;
  stopRequested: boolean;
};

const t = (key: string, args?: Record<string, unknown>) => tr(stationLang(), key, args);

/// The longest a session whose turn did not start waits before what is pending is given to it again.
export const START_AGAIN_MAX_MS = 60_000;

export class SessionActor {
  readonly key: string;
  /// The runtime it was made with; its session may go on with another (configure).
  private readonly made: "claude" | "codex";
  private deps: SessionDeps;
  private lock = Semaphore.makeUnsafe(1);
  /// Runs an effect as a fiber of this actor's (its tasks, its wait's timer): they end when it closes.
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  private scope: Scope.Closeable;

  private agent: { generation: number; session: AgentSession; runtime: "claude" | "codex" } | null = null;
  private profile: string | null = null;
  private generation = 0;
  private phase: Phase = "idle";
  private turn: Turn | null = null;
  private nudges = 0;
  private stopRequested = false;
  /// The stop asked is said nowhere (stop).
  private quietStop = false;
  private resumeLost = false;
  /// Started afresh: what it is told of it with its next prompt.
  private afresh: string | null = null;
  private idleSince: number;
  private workingFor: Working[] = [];
  private tools: [string, string][] = [];
  private notices: string[] = [];
  /// The wait: its number (a newer wait voids an older one's timer), when it is over, and how long it was said to be.
  private waiting: number | null = null;
  private waits = 0;
  private waitingUntil = 0;
  private waitingSeconds = 0;
  /// Messages given to the running turn while it ran: the runtime may not have read them yet (suspend).
  private steered: [number, number][] = [];
  /// Starts of a turn that failed in a row (one that works ends the count); the timer of the next try, by its number
  /// (a newer failure's voids an older one's); and whether the start under way is that timer's (its failure is not
  /// told in the thread again).
  private startFailures = 0;
  private agains = 0;
  private tryingAgain = false;
  private queued = 0;
  /// For `status()`: a turn being started (its runtime opening, before the turn begins); when the running turn (or its
  /// start) began; when the wait began; when the starts began failing, and why the last did.
  private starting = false;
  private runningSince: number | null = null;
  private waitingSince = 0;
  private failingSince = 0;
  private lastStartFailure: string | null = null;

  constructor(key: string, runtime: "claude" | "codex", deps: SessionDeps) {
    this.key = key;
    this.made = runtime;
    this.deps = deps;
    this.idleSince = deps.clock.currentTimeMillisUnsafe();
    this.scope = Effect.runSync(Scope.make());
    const run = Effect.runSync(Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope));
    this.run = (effect) => run(effect.pipe(Effect.provideService(Clock.Clock, deps.clock)));
  }

  private now(): number {
    return this.deps.clock.currentTimeMillisUnsafe();
  }

  /// The runtime its session runs now.
  get runtime(): "claude" | "codex" {
    const runtime = this.deps.store.getSession(this.key)?.runtime;
    return runtime === "claude" || runtime === "codex" ? runtime : this.made;
  }

  // ── the queue ─────────────────────────────────────────────────────────────────────────────────────────────────

  /// Queues a task; the promise resolves once it has run (or was skipped: the actor closed). A task's failure is
  /// logged, never thrown into the queue.
  private enqueue(task: () => Promise<void>): Promise<void> {
    this.queued++;
    const run = this.lock.withPermits(1)(
      Effect.promise(async () => {
        if (this.phase === "closed") return;
        try {
          await task();
        } catch (error) {
          log.error("session", "session task failed", { session: this.key, error: (error as Error).message });
        }
      }),
    ).pipe(Effect.ensuring(Effect.sync(() => this.queued--)));
    // Skipped (interrupted) once the actor closes: its caller is answered all the same.
    return this.run(run).catch(() => undefined);
  }

  /// No task queued or running.
  settled(): boolean {
    return this.queued === 0;
  }

  /// Resolves once every task queued before it has run (a handover waits on it, then looks at `settled`).
  flushed(): Promise<void> {
    return this.enqueue(async () => {});
  }

  /// Archived and idle: its files go to cold storage, in turn with the rest (session.rs `clean_archive`).
  cleanArchive(): Promise<void> {
    return this.enqueue(async () => {
      if (this.agent || this.turn || this.waiting !== null || this.notices.length > 0) return;
      await this.deps.cleanArchive?.(this.key);
    });
  }

  // ── what the hub asks ────────────────────────────────────────────────────────────────────────────────────────

  /// running: a turn is in progress; warm: a runtime process waits for input; cold: none.
  processState(): "running" | "warm" | "cold" {
    if (this.turn || this.agent?.session.busy()) return "running";
    return this.agent ? "warm" : "cold";
  }

  /// How long the runtime process has sat idle, or null if there is none or it is working.
  idleMs(now: number): number | null {
    return this.agent && !this.agent.session.busy() && !this.turn && this.waiting === null ? now - this.idleSince : null;
  }

  holdsState(): boolean {
    return this.notices.length > 0 || this.waiting !== null;
  }

  /// Where it stands now, for the host of a Task it takes part in (task.status). A read: starts no turn, changes nothing.
  status(): SessionStatus {
    const pending = this.deps.store.pendingMessages(this.key).length;
    const since = (at: number | null) => (at === null ? null : Math.max(0, this.now() - at));
    if (this.starting || this.turn || this.agent?.session.busy()) return { state: "running", pending, for_ms: since(this.runningSince), last_failure: null };
    if (this.waiting !== null) return { state: "waiting", pending, for_ms: since(this.waitingSince), last_failure: null };
    if (pending > 0 && this.startFailures > 0) return { state: "cannot_start", pending, for_ms: since(this.failingSince), last_failure: this.lastStartFailure };
    return { state: "idle", pending, for_ms: since(this.idleSince), last_failure: null };
  }

  /// Delivers any pending messages.
  kick(): Promise<void> {
    return this.enqueue(() => this.pump());
  }

  /// A word from the station for the agent outside any conversation (a job's notice): it joins the running turn, or
  /// runs as a turn of its own; one the running turn cannot take waits for its end.
  notify(text: string): Promise<void> {
    this.notices.push(text);
    return this.enqueue(() => this.giveNotices());
  }

  /// What a tool says of the running turn, recorded in turn order (the tool answers once this resolves).
  declare(state: DeclaredState): Promise<void> {
    return this.enqueue(async () => {
      if (this.turn) this.turn.declared = state;
    });
  }

  waitFor(what: string): Promise<void> {
    return this.enqueue(async () => {
      if (this.turn) this.deps.store.setWaitFor(this.turn.id, what);
    });
  }

  need(what: string): Promise<void> {
    return this.enqueue(async () => {
      if (this.turn) this.deps.store.setNeed(this.turn.id, what);
    });
  }

  about(about: [number, number, string] | null): Promise<void> {
    return this.enqueue(async () => {
      if (this.turn) this.deps.store.setAbout(this.turn.id, about);
    });
  }

  /// Stops what it is doing: the running turn; or, while it waits on work it started, that work and the wait. Said in
  /// its chat, unless `quiet`: its Task runs elsewhere now (tasks.ts moveTo), which no one asked it to stop for.
  stop(quiet = false): Promise<void> {
    return this.enqueue(async () => {
      if (this.agent?.session.busy()) {
        this.stopRequested = true;
        this.quietStop = quiet;
        await this.agent.session.abort();
        return;
      }
      if (!this.turn) await this.stopWaiting(quiet);
    });
  }

  /// Its last turn stopped at its account's allowance and it was changed since: it goes on where it stopped.
  goOn(): Promise<void> {
    return this.enqueue(async () => {
      if (this.deps.held(this.key) || this.turn || this.agent?.session.busy()) return;
      if (this.deps.store.pendingMessages(this.key).length > 0) return this.pump();
      await this.startTurn("resume", GO_ON_AFTER_SPENT);
    });
  }

  /// After a station stopped with this session's turn running and no runner kept it: the turn was cut off; resume it.
  recover(): Promise<void> {
    return this.enqueue(async () => {
      const store = this.deps.store;
      store.setRunning(this.key, false);
      const pending = store.pendingMessages(this.key);
      const [said, widgets] = await this.format(pending);
      await this.startTurn("resume", said === "" ? RESUME_AFTER_RESTART : `${RESUME_AFTER_RESTART}\n\n${said}`);
      this.delivered(pending, widgets);
    });
  }

  /// Turns were held and are no longer: what waited meanwhile goes on.
  release(): Promise<void> {
    return this.enqueue(async () => {
      if (this.waiting !== null && this.waitingUntil <= this.now()) this.waitMs(this.waitingSeconds, 0);
      await this.pump();
      if (this.notices.length > 0) await this.giveNotices();
    });
  }

  /// Starts the runtime process ahead of a message, so its start-up overlaps the typing.
  warm(): Promise<void> {
    return this.enqueue(async () => {
      if (this.agent || this.deps.held(this.key)) return;
      log.info("session", "warming session process", { session: this.key });
      await this.ensureAgent();
      this.idleSince = this.now();
      this.deps.store.notify(this.key);
      this.deps.idle(this.key);
    });
  }

  /// Ends the runtime process if it is idle.
  evict(): Promise<void> {
    return this.enqueue(async () => {
      const agent = this.agent;
      if (!agent || agent.session.busy() || this.turn || this.waiting !== null) return;
      this.agent = null;
      log.info("session", "evicting idle session process", { session: this.key });
      await agent.session.dispose();
      this.deps.store.notify(this.key);
    });
  }

  /// The station left its workspace: the runtime process ends, and with it whatever the agent was doing or had been
  /// given (session.rs `suspend`): a turn under way stays marked running (to resume once back), unless it had already
  /// said a settled state; messages given to it while it ran are pending again.
  suspend(): Promise<void> {
    return this.enqueue(async () => {
      const agent = this.agent;
      this.agent = null;
      const busy = agent?.session.busy() ?? false;
      const turn = this.turn;
      this.turn = null;
      this.tools = [];
      this.workingFor = [];
      this.stopRequested = false;
      const steered = this.steered;
      this.steered = [];
      if (!agent && !turn) return;
      const store = this.deps.store;
      const resume = (turn !== null || busy) && !(turn?.declared && settled(turn.declared));
      log.info("session", "ending the runtime process: the station is in no workspace", { session: this.key, resume });
      await agent?.session.dispose();
      if (turn) store.endTurn(turn.id, "aborted", "other: the station left its workspace", turn.declared?.kind ?? null, null);
      store.setRunning(this.key, resume);
      if (turn || busy) store.markUndelivered(this.key, steered);
      this.deps.live?.turnEnded(this.key);
      store.notify(this.key);
      this.phase = "idle";
      this.runningSince = null;
      this.idleSince = this.now();
    });
  }

  /// Where the session stands, for the next station; from here on this actor does nothing more. Its runtime session is
  /// let go of (the runner keeps the process), not ended.
  snapshot(): Snapshot {
    const agent = this.agent?.session ?? null;
    const snap: Snapshot = {
      key: this.key,
      runtime: this.runtime,
      agent: agent?.snapshot() ?? null,
      turn: this.turn && {
        id: this.turn.id,
        authRetried: this.turn.authRetried,
        by: this.turn.by,
        declared: this.turn.declared?.kind ?? null,
        wait: this.turn.declared?.kind === "waiting" ? this.turn.declared.seconds : null,
      },
      workingFor: this.workingFor,
      notices: this.notices,
      waitingMs: this.waiting !== null ? Math.max(0, this.waitingUntil - this.now()) : null,
      waitingSeconds: this.waitingSeconds,
      nudges: this.nudges,
      stopRequested: this.stopRequested,
    };
    agent?.detach();
    this.close();
    return snap;
  }

  /// Takes up a session the previous station left (its snapshot), on its runtime session when the driver took that up:
  /// as the generation the caller opened it as (`nextGeneration`, whose `listener` the driver was given).
  adopt(snap: Snapshot, agent: AgentSession | null) {
    this.profile = this.deps.store.getSession(this.key)?.profile ?? null;
    this.agent = agent ? { generation: this.generation, session: agent, runtime: this.runtime } : null;
    this.turn = snap.turn && {
      id: snap.turn.id,
      authRetried: snap.turn.authRetried,
      by: snap.turn.by,
      declared: snap.turn.declared ? parseDeclared(snap.turn.declared, snap.turn.wait ?? 0) : null,
    };
    this.phase = this.turn ? "running" : "idle";
    this.runningSince = this.turn ? this.now() : null;
    this.workingFor = snap.workingFor;
    this.notices = snap.notices;
    this.nudges = snap.nudges;
    this.stopRequested = snap.stopRequested;
    this.idleSince = this.now();
    if (snap.waitingMs !== null) this.waitMs(snap.waitingSeconds, snap.waitingMs);
  }

  /// The events of the runtime session opened (or adopted) as `generation`, as a driver gives them.
  listener(generation: number): (event: RuntimeEvent) => void {
    return (event) => this.onEvent(generation, event);
  }

  nextGeneration(): number {
    return ++this.generation;
  }

  /// For shutdown or handover: queued and later tasks are skipped, timers end. A running turn stays marked running.
  close() {
    this.phase = "closed";
    Effect.runFork(Scope.close(this.scope, Exit.void));
  }

  /// Ends the runtime process too (the session is deleted, or the station stops for good).
  async dispose() {
    const agent = this.agent;
    this.agent = null;
    this.close();
    await agent?.session.dispose();
  }

  // ── inside the queue ─────────────────────────────────────────────────────────────────────────────────────────

  /// The notices waiting, as the agent reads them: each a message from the station (via="ember", as before the rename).
  private takeNotices(): string | null {
    const notices = this.notices;
    this.notices = [];
    if (notices.length === 0) return null;
    const at = this.deps.nextTs();
    return notices.map((n) => `<message via="ember" from="ember" ts="${at}">\n${n}\n</message>`).join("\n");
  }

  private async giveNotices() {
    if (this.deps.held(this.key)) return;
    if (this.agent?.session.busy()) {
      const text = this.takeNotices();
      if (text === null) return;
      // Not now: after the running turn.
      if (!(await this.agent.session.steer(text))) this.notices.unshift(text);
      return;
    }
    const text = this.takeNotices();
    if (text !== null) await this.startTurn("job", text);
  }

  private async pump() {
    if (this.deps.held(this.key)) return; // they stay pending
    const store = this.deps.store;
    const pending = store.pendingMessages(this.key);
    if (pending.length === 0) return;
    const [text, widgets] = await this.format(pending);
    const agent = this.agent?.session;
    if (agent?.busy()) {
      // So it is read now, not when a long command ends; what it waited on goes on.
      if (this.deps.backgroundOnMessage(this.key)) await agent.backgroundTools();
      if (await agent.steer(text)) {
        this.workFor(pending);
        this.delivered(pending, widgets);
        this.steered.push(...pending.map((m: any): [number, number] => [m.message.thread, m.message.n]));
      }
      return; // otherwise delivered when the turn ends
    }
    this.nudges = 0;
    this.workFor(pending);
    // The turn is for the first person whose message it takes.
    const first = pending.find((m: any) => m.message.authorKind === "person");
    const by: TurnFor = first ? { person: personRef(first), thread: first.message.thread, profile: null } : nobody;
    await this.startTurn("input", text, by);
    this.delivered(pending, widgets);
  }

  private workFor(messages: any[]) {
    for (const m of messages.filter((m) => m.surface !== "ember")) {
      const at = this.workingFor.find((w) => w.connect === m.connect && w.channel === m.channel && w.threadTs === m.threadTs);
      if (at) at.ts = m.message.ts;
      else this.workingFor.push({ connect: m.connect, channel: m.channel, threadTs: m.threadTs, ts: m.message.ts });
    }
    this.say(t("station.status.thinking"));
  }

  private say(status: string) {
    for (const w of this.workingFor) this.deps.chat(w.connect)?.working?.({ channel: w.channel, threadTs: w.threadTs }, w.ts, status);
  }

  /// A live step of the running turn, for its threads' status line.
  private onLive(event: LiveEvent) {
    if (this.workingFor.length === 0) return;
    if (event.kind === "start" && event.step === "tool" && event.tool) {
      if (!this.tools.some(([i]) => i === event.id)) this.tools.push([event.id, event.tool]);
    } else if (event.kind === "end") this.tools = this.tools.filter(([i]) => i !== event.id);
    else if (event.kind !== "phase") return;
    const last = this.tools.at(-1);
    this.say(last ? this.deps.toolStatus(last[1]) : t("station.status.thinking"));
  }

  /// The turn is over: its threads' status line goes.
  private doneWorking() {
    this.say("");
    this.workingFor = [];
    this.tools = [];
  }

  private delivered(messages: any[], widgets: [string, string][]) {
    this.deps.store.markDelivered(this.key, messages.map((m): [number, number] => [m.message.thread, m.message.n]));
    this.deps.store.markWidgetModelsTold(this.key, widgets);
  }

  /// The messages as the agent reads them, made now so edits count (session.rs `format`).
  private async format(said: any[]): Promise<[string, [string, string][]]> {
    const store = this.deps.store;
    const heard = new Set(store.heardThreads(this.key));
    const newThreads = new Set<number>(said.map((m) => m.message.thread).filter((t: number) => !heard.has(t)));
    const names = new Map<string, string>();
    for (const m of said) {
      if (names.has(m.message.author)) continue;
      if (m.message.authorKind === "agent") {
        names.set(m.message.author, this.agentName(m.message.author, m.message.thread));
        continue;
      }
      if (m.message.authorKind !== "person") continue;
      const name = await this.deps.chat(m.connect)?.userName?.(m.message.author);
      if (name) names.set(m.message.author, name);
    }
    // What the agent is called in each connect these came through: the bot's name there and its mention.
    const selves = new Map<string, string>();
    for (const m of said) {
      if (selves.has(m.connect)) continue;
      const chat = this.deps.chat(m.connect);
      const [name, user] = [chat?.botName?.() ?? "", chat?.botUserId?.() ?? ""];
      if (name !== "") selves.set(m.connect, user === "" ? name : `${name} (<@${user}>)`);
    }
    const text = formatInbound(said, newThreads, names, selves);
    const models = store.untoldWidgetModels(this.key);
    const widgets = models.map((w: any): [string, string] => [w.path, w.model]);
    const told = formatWidgetModels(models);
    return [told === "" ? text : text === "" ? told : `${text}\n\n${told}`, widgets];
  }

  /// What another agent goes by in a thread: the bot of the connect it posts there through, with its mention; in the
  /// station's own chats, its runtime and model.
  private agentName(key: string, thread: number): string {
    const via = this.deps.store.threadSessions(thread).find((m) => m.session === key)?.connect;
    const chat = via && via !== "ember" ? this.deps.chat(via) : undefined;
    const name = chat?.botName?.() ?? "";
    if (name !== "") {
      const user = chat?.botUserId?.() ?? "";
      return user === "" ? name : `${name} (<@${user}>)`;
    }
    const row = this.deps.store.getSession(key);
    return row ? `${row.runtime === "claude" ? "Claude Code" : "Codex"}${row.model ? ` ${row.model}` : ""}` : "another agent";
  }

  /// Starts a turn with `text` for someone. On failure the thread is told and the error thrown, so callers leave their
  /// messages pending for the next attempt, which `startAgain` makes.
  private async startTurn(kind: string, text: string, by: TurnFor = nobody): Promise<void> {
    const store = this.deps.store;
    this.starting = true;
    this.runningSince ??= this.now();
    try {
      // Until the runtime says it has sent its request, the turn is starting.
      this.deps.live?.event(this.key, { kind: "phase", phase: "starting" });
      let agent = await this.ensureAgent();
      const row = store.getSession(this.key);
      // A session begun in a terminal and continued here: its first turn here says so, with how still.fail works.
      const continued = row && row.cwd && !store.hasTurns(this.key) ? continuedHere(sessionInstructions(row.workspace, row.cwd, this.deps.reposDir(), this.deps.memoryPath())) : null;
      const lost = this.resumeLost;
      this.resumeLost = false;
      let prompt = lost ? `${RESUME_LOST}\n\n${text}` : text;
      const afresh = this.afresh;
      this.afresh = null;
      if (afresh !== null) prompt = `${afresh}\n\n${prompt}`;
      if (continued !== null) prompt = `${continued}\n\n${prompt}`;
      // What changed in how it works since it was last told (migrations): once, before what it is handed.
      const told = store.toldNotes(this.key) ?? latestNote();
      if (told < latestNote()) {
        const full = row ? join(row.workspace, ".stillfail-instructions.md") : "";
        if (row) {
          const { writeFileSync } = await import("node:fs");
          try {
            writeFileSync(full, sessionInstructions(row.workspace, row.cwd ?? null, this.deps.reposDir(), this.deps.memoryPath()));
          } catch {}
        }
        store.setToldNotes(this.key, latestNote());
        prompt = `${untold(told, full)}\n\n${prompt}`;
      }
      // The runtime may have started a turn on its own (late input became a turn); join it.
      if (agent.busy() && (await agent.steer(prompt))) {
        this.startFailures = 0;
        return;
      }
      this.steered = [];
      this.beginTurn(kind, by);
      try {
        await agent.prompt(prompt);
      } catch (error) {
        // The runtime is unusable (died between turns, or refused): replace it once.
        log.warn("session", "prompt failed, reopening the runtime", { session: this.key, error: (error as Error).message });
        this.agent = null;
        await agent.dispose();
        agent = await this.ensureAgent();
        await agent.prompt(prompt);
      }
      this.startFailures = 0;
    } catch (error) {
      const message = (error as Error).message;
      const turn = this.turn;
      this.turn = null;
      this.phase = "idle";
      this.runningSince = null;
      this.idleSince = this.now();
      if (turn) store.endTurn(turn.id, "failed", `other: ${message}`, null, null);
      store.setRunning(this.key, false);
      this.doneWorking();
      if (this.startFailures === 0) this.failingSince = this.now();
      this.startFailures++;
      this.lastStartFailure = Array.from(message).slice(0, LAST_FAILURE_CHARS).join("");
      // Said once: the tries that follow are the station's own, and say so in its log.
      if (!this.tryingAgain) await this.notice(`⚠️ ${t("station.notice.cannotStart", { error: message })}`, null, { session: this.key, cannotStart: message });
      this.startAgain(message);
      throw error;
    } finally {
      this.starting = false;
    }
  }

  /// A turn did not start: what is pending for the session is given to it again after 1 s, then 2 s, 4 s… at most
  /// START_AGAIN_MAX_MS, until a turn starts (as a put a Station did not answer is given again, tasks.ts). A message
  /// that comes meanwhile tries at once, as ever. Nothing pending is nothing to try: the next failure is a new one.
  /// The timer is a fiber of this actor's: it ends with it, and the next station's start delivers what is pending.
  private startAgain(error: string) {
    const again = ++this.agains;
    const wait = Math.min(START_AGAIN_MAX_MS, 1000 * 2 ** (this.startFailures - 1));
    log.warn("session", "a turn did not start; what is pending is given again", { session: this.key, error, failures: this.startFailures, wait });
    void this.run(
      Effect.sleep(wait).pipe(
        Effect.andThen(
          Effect.promise(() =>
            this.enqueue(async () => {
              if (this.agains !== again || this.startFailures === 0) return;
              if (this.deps.store.pendingMessages(this.key).length === 0) {
                this.startFailures = 0;
                return;
              }
              this.tryingAgain = true;
              try {
                await this.pump();
              } finally {
                this.tryingAgain = false;
              }
            }),
          ),
        ),
      ),
    ).catch(() => undefined);
  }

  private beginTurn(kind: string, by: TurnFor) {
    const id = crypto.randomUUID();
    this.turn = { id, declared: null, authRetried: kind === "auth_retry", by };
    this.phase = "running";
    this.runningSince ??= this.now();
    this.waiting = null;
    this.deps.store.startTurnFor(id, this.key, kind, { ...by, profile: this.profile });
    this.deps.store.setRunning(this.key, true);
  }

  private async ensureAgent(): Promise<AgentSession> {
    const profile = this.deps.runOn(this.key);
    const runtime = this.runtime;
    // Its runtime process goes on while it is the runtime session the session runs in, as the store says: one left for
    // a new one (store.leaveRuntimeSession) or of another runtime (configure) is not.
    const current = this.deps.store.getSession(this.key)?.runtimeSessionId ?? null;
    if (this.agent && this.profile === profile.id && this.agent.runtime === runtime && this.agent.session.id() === current) return this.agent.session;
    if (this.agent) {
      const previous = this.agent;
      this.agent = null;
      await previous.session.dispose();
    }
    if (this.deps.archiveIsCold(this.key)) await this.deps.restoreArchive(this.key);
    const store = this.deps.store;
    const row = store.getSession(this.key);
    if (!row) throw new Error(`session ${this.key} disappeared`);
    const driver = this.deps.driver(runtime);
    const base = openOptions(row, profile, this.deps);
    // A runtime started where the station may not read exits at once with nothing to say why (macOS privacy protection
    // on a session continued in ~/Documents): told as it is instead.
    if (unreadableDir(base.cwd)) throw new Error(unreadableDirMessage(stationLang(), base.cwd));
    const generation = this.nextGeneration();
    let agent: AgentSession;
    // Recorded before it may be left, so the history reads on from it.
    if (row.runtimeSessionId) this.deps.ranIn?.(this.key, row.runtimeSessionId, null);
    const afresh = this.deps.startsAfresh?.(this.key, row.runtimeSessionId ?? null, profile, this.profile) ?? null;
    if (afresh !== null) {
      log.info("session", "going on in a new runtime session on another account", { session: this.key, left: row.runtimeSessionId, profile: profile.id });
      agent = await driver.open(base, this.listener(generation));
      this.afresh = afresh;
    } else if (row.runtimeSessionId) {
      try {
        agent = await driver.open({ ...base, resume: row.runtimeSessionId }, this.listener(generation));
      } catch (error) {
        log.warn("session", "resume failed; starting a new runtime session", { session: this.key, id: row.runtimeSessionId, error: (error as Error).message });
        agent = await driver.open(base, this.listener(generation));
        this.resumeLost = true;
      }
    } else {
      agent = await driver.open(base, this.listener(generation));
    }
    if (row.runtimeSessionId !== agent.id()) {
      store.setRuntimeSessionId(this.key, agent.id());
      if (row.runtimeSessionId) this.deps.live?.moved?.(this.key);
    }
    this.deps.ranIn?.(this.key, agent.id(), profile.id);
    this.agent = { generation, session: agent, runtime };
    this.profile = profile.id;
    return agent;
  }

  private isCurrent(generation: number) {
    return this.agent?.generation === generation;
  }

  /// A runtime session's events, in order: live steps at once (they only feed the status line and watchers), the rest
  /// through the queue.
  private onEvent(generation: number, event: RuntimeEvent) {
    switch (event.type) {
      case "turnStarted":
        void this.enqueue(async () => {
          if (this.isCurrent(generation) && !this.turn) this.beginTurn("input", nobody);
        });
        break;
      case "turnEnded":
        this.deps.live?.turnEnded(this.key);
        this.doneWorking();
        void this.enqueue(() => this.onTurnEnded(generation, event.outcome));
        break;
      case "live":
        this.deps.live?.event(this.key, event.event);
        this.onLive(event.event);
        break;
      case "closed":
        void this.enqueue(async () => {
          if (!this.isCurrent(generation)) return;
          log.info("session", "session runtime closed", { session: this.key, reason: event.why });
          this.agent = null;
          this.deps.store.notify(this.key);
        });
        break;
    }
  }

  private async onTurnEnded(generation: number, outcome: TurnOutcome) {
    if (!this.isCurrent(generation)) return;
    const store = this.deps.store;
    this.idleSince = this.now();
    const turn = this.turn;
    this.turn = null;
    this.phase = "idle";
    this.runningSince = null;
    const stopRequested = this.stopRequested;
    const quiet = this.quietStop;
    this.stopRequested = false;
    this.quietStop = false;
    store.setRunning(this.key, false);
    if (turn) {
      const detail = outcome.kind === "failed" ? `${outcome.reason}: ${outcome.message}` : null;
      const wait = turn.declared?.kind === "waiting" ? turn.declared.seconds : null;
      store.endTurn(turn.id, outcome.kind, detail, turn.declared?.kind ?? null, wait);
    }
    // Reopen Claude once so it reads the current credentials (and refreshes an expiring machine token). Resume its
    // transcript with a continuation, never replay the original request: it may already have run tools.
    if (this.runtime === "claude" && outcome.kind === "failed" && outcome.reason === "auth" && !stopRequested && !this.deps.held(this.key) && turn && !turn.authRetried && !turn.declared) {
      this.nudges = 0;
      const agent = this.agent;
      this.agent = null;
      await agent?.session.dispose();
      log.info("session", "Claude authentication failed; reopening and continuing once", { session: this.key });
      return this.startTurn("auth_retry", GO_ON_AFTER_AUTH, turn.by);
    }
    if (outcome.kind === "failed" && outcome.reason === "rate_limit") {
      this.nudges = 0;
      // Left to the station, it moves to another account and goes on there; otherwise it waits for a change.
      let moved: [string, string] | null = null;
      try {
        moved = this.deps.spend(this.key);
      } catch (error) {
        log.warn("session", "could not move off a spent profile", { session: this.key, error: (error as Error).message });
      }
      if (moved) {
        // Its process runs on the account left: the next starts on the one taken.
        const agent = this.agent;
        this.agent = null;
        await agent?.session.dispose();
        log.info("session", "allowance ran out; going on on another profile", { session: this.key, from: moved[0], to: moved[1] });
        if (store.pendingMessages(this.key).length > 0) return this.pump();
        return this.startTurn("resume", GO_ON_AFTER_SPENT);
      }
      await this.notice(failureNotice(outcome), this.profile);
    } else if (outcome.kind === "failed") {
      this.nudges = 0;
      // A sign-in that failed is its profile's: the notice points there.
      await this.notice(failureNotice(outcome), outcome.reason === "auth" ? this.profile : null);
    } else if (outcome.kind === "aborted") {
      this.nudges = 0;
      if (stopRequested && !quiet) await this.notice(t("station.notice.stopped"));
    }

    if (store.pendingMessages(this.key).length > 0) return this.pump();
    if (this.notices.length > 0) return this.giveNotices();
    const declared = turn?.declared ?? null;
    if (outcome.kind === "completed" && declared?.kind === "waiting") {
      this.nudges = 0;
      this.wait(declared.seconds);
      this.deps.idle(this.key);
      return;
    }
    this.deps.idle(this.key);
    if (outcome.kind !== "completed" || declared) {
      this.nudges = 0;
      return;
    }
    if (this.deps.held(this.key)) return;
    if (this.nudges < this.deps.maxNudges()) {
      this.nudges++;
      log.info("session", "turn ended without a state; nudging", { session: this.key, attempt: this.nudges });
      return this.startTurn("nudge", NUDGE);
    }
    this.nudges = 0;
    await this.notice(`⚠️ ${t("station.notice.noResult")}`);
  }

  /// Stopped while it waits: the wait ends, and so does the work that would bring it back (session.rs `stop_waiting`).
  private async stopWaiting(quiet = false) {
    const store = this.deps.store;
    const waited = this.waiting !== null;
    this.waiting = null;
    if (this.phase === "waiting") {
      this.phase = "idle";
      this.idleSince = this.now();
    }
    // Its wait may be on record only (an earlier station had it).
    const last = store.lastTurn(this.key);
    const recorded = last && last.endedAt !== null && last.declared === "waiting";
    if (!waited && !recorded) return;
    log.info("session", "stopped while waiting", { session: this.key });
    await this.deps.stopJobs(this.key);
    this.nudges = 0;
    const agent = this.agent;
    this.agent = null;
    await agent?.session.dispose();
    store.stopWait(this.key);
    if (!quiet) await this.notice(t("station.notice.stopped"));
  }

  /// Asks the agent again after `seconds`, unless a turn has started by then.
  private wait(seconds: number) {
    this.waitMs(seconds, seconds * 1000);
  }

  /// The same, with `ms` of it left. The timer is a fiber of this actor's: it ends with it.
  private waitMs(seconds: number, ms: number) {
    const wait = ++this.waits;
    this.waiting = wait;
    this.phase = "waiting";
    this.waitingSince = this.now();
    this.waitingUntil = this.now() + ms;
    this.waitingSeconds = seconds;
    void this.run(
      Effect.sleep(Math.max(0, ms)).pipe(
        Effect.andThen(
          Effect.promise(() =>
            this.enqueue(async () => {
              // Held: the wait stays, for the next station to take up.
              if (this.deps.held(this.key) || this.waiting !== wait) return;
              this.waiting = null;
              this.phase = "idle";
              // Keeping watch: the watch brings it back (its notices, its end), not the clock; it waits on.
              if (this.deps.store.listJobs(this.key).some((j) => j.watch && j.state === "running")) return this.wait(seconds);
              log.info("session", "the wait is over without word; asking again", { session: this.key, seconds });
              await this.startTurn("nudge", waitOver(seconds));
            }),
          ),
        ),
      ),
    ).catch(() => undefined);
  }

  /// The station's own words about the session, in its queue (as `notice`).
  tell(text: string): Promise<void> {
    return this.enqueue(() => this.notice(text));
  }

  /// The station's own words (not the agent's) go to the thread people spoke in last, and are recorded there; one about
  /// a profile (`profile`, its id) is linked to that profile's page.
  private async notice(text: string, profile: string | null = null, from?: PostFrom) {
    const store = this.deps.store;
    const latest = store.latestThread(this.key);
    const chat = latest ? this.deps.chat(latest.connect) : undefined;
    if (!latest || !chat) {
      log.warn("session", "no thread to post a notice to", { session: this.key, text });
      return;
    }
    try {
      const ts = await chat.post({ channel: latest.thread.channel, threadTs: latest.thread.threadTs }, text, [], from);
      store.insertMessage({ thread: latest.thread.id, ts, authorKind: "ember", author: "ember", text, profile, attachments: [], quotes: [], declared: null, client: null, card: null, options: null, agentIdentity: null });
    } catch (error) {
      log.warn("session", "notice failed", { session: this.key, error: (error as Error).message });
    }
  }
}

/// How a session's runtime session is opened (or taken up) on `profile`: its directory, model as the profile spells it,
/// effort, instructions and MCP token.
export function openOptions(row: any, profile: Profile & { spelling?(model: string): string | null }, deps: Pick<SessionDeps, "mcpUrl" | "reposDir" | "memoryPath" | "workspaceInstructions">): OpenOptions {
  // The model as this profile spells it (openai/gpt-6-astra on a router for gpt-6-astra).
  const model = row.model ? (profile.spelling?.(row.model) ?? row.model) : undefined;
  return {
    key: row.key,
    profile,
    cwd: row.cwd ?? row.workspace,
    model,
    effort: row.effort ?? undefined,
    // A session continued from a terminal keeps the system prompt it began with (its cache holds).
    instructions: row.cwd ? "" : withWorkspace(sessionInstructions(row.workspace, null, deps.reposDir(), deps.memoryPath()), deps.workspaceInstructions(row.workspace)),
    mcpToken: row.token,
    mcpUrl: deps.mcpUrl(),
    route: row.key,
  };
}

const withWorkspace = (instructions: string, more: string | null) => (more === null ? instructions : `${instructions}\n\n${more}`);

function failureNotice(outcome: TurnOutcome): string {
  if (outcome.kind !== "failed") return "";
  const key = outcome.reason === "auth" ? "auth" : outcome.reason === "rate_limit" ? "rateLimit" : outcome.reason === "exited" ? "exited" : "failed";
  return `⚠️ ${t(`station.notice.${key}`, { error: outcome.message })}`;
}

/// Who wrote a message, as a creator reference: their email on the page, their Slack user through the connect it came by.
const personRef = (m: any) => (m.surface === "ember" ? m.message.author : `slack:${m.connect}:${m.message.author}`);
