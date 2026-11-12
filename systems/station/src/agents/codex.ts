// Codex driver (the Rust station's runtime/codex.rs): one shared `codex app-server` per profile, under a runner whose id comes
// from the profile, one thread per session.
//
// Pinned by spikes (spike/README.md):
// - a thread adds <1MB to its app-server, so sessions share one process;
// - per-session settings (the MCP endpoint and token) travel in the thread/start|resume `config`, not the process
//   environment;
// - threads need sandbox "danger-full-access" with approvalPolicy "never", or MCP tool calls are refused.
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join } from "node:path";
import { log } from "../ops/log.ts";
import { LiveFromCodex, chars, type CodexLiveState } from "./live.ts";
import { linkCodexAuth, type Env } from "./machine-logins.ts";
import { AgentProcess, ackedOffset, debug, findRunner, linesBefore, outFile, runnerId } from "./process.ts";
import { accessKind, codexOverrides, expandRoute, isMachine, profileEnv, profileFast, profileModel, profileVia } from "./profiles.ts";
import { cleanEnv, type AgentDriver, type AgentSession, type FailureReason, type OpenOptions, type Profile, type RuntimeEvent, type TurnOutcome } from "./runtime.ts";
import type { RunnerInfo } from "./runner.ts";
import { wall } from "../ops/fibers.ts";
import { Duration } from "effect";
import { SALIX_TOOL_CALL_TIMEOUT } from "../connector/config.ts";

/// How long Codex waits for a tool of the station's MCP server: a little past the station's wait for a Salix tool call.
export const COMMA_STATION_MCP_TOOL_TIMEOUT_SECONDS = Duration.toSeconds(SALIX_TOOL_CALL_TIMEOUT) + 30;

type Json = any;

const SCRUBBED = ["OPENAI_API_KEY", "CODEX_HOME"];

/// Codex otherwise reads the system's root certificates for each new connection. On macOS, from a process outside the
/// desktop session, that can take seconds or hang past its 15 s request timeout, and fail with UnknownIssuer.
/// SSL_CERT_FILE makes it use a CA file instead, for its model websocket as well as its HTTP clients. One the user set
/// wins.
const CA_BUNDLE = "/etc/ssl/cert.pem";

export function withCaBundle(env: Record<string, string>, bundle: string) {
  if (["SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE"].some((k) => k in env) || !existsSync(bundle)) return;
  env.SSL_CERT_FILE = bundle;
}

/// Paths in the order Rust sorts PathBufs: component by component.
function comparePaths(a: string, b: string): number {
  const x = a.split("/");
  const y = b.split("/");
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    if (x[i] !== y[i]) return x[i]! < y[i]! ? -1 : 1;
  }
  return x.length - y.length;
}

/// Codex also loads the skills in the user's own ~/.agents/skills. The station's agents share skills through the agent
/// home instead, and the personal ones pull them off course, so each is turned off by path: codex's skills.config takes
/// files, not directories.
export function hostSkillsOff(root: string): { path: string; enabled: false }[] {
  const found: string[] = [];
  const visited = new Set<string>();
  const walk = (dir: string, depth: number) => {
    if (depth > 6) return;
    let real: string;
    try {
      real = realpathSync(dir);
    } catch {
      return;
    }
    if (visited.has(real)) return;
    visited.add(real);
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const path = join(dir, name);
      // Follows links: skill folders are often linked in.
      let isDir: boolean;
      try {
        isDir = statSync(path).isDirectory();
      } catch {
        continue;
      }
      if (isDir) walk(path, depth + 1);
      else if (name === "SKILL.md") found.push(path);
    }
  };
  walk(root, 0);
  return found.sort(comparePaths).map((path) => ({ path, enabled: false as const }));
}

export function classifyCodexError(info: unknown): FailureReason {
  const code = typeof info === "string" ? info : info && typeof info === "object" && !Array.isArray(info) ? Object.keys(info)[0] : undefined;
  if (code === "unauthorized") return "auth";
  if (code === "usageLimitExceeded" || code === "rateLimitExceeded" || code === "serverOverloaded") return "rate_limit";
  return "model";
}

/// Keeps capabilities alongside model ids; an old runtime may omit them.
export class ModelCatalog {
  models: string[] = [];
  efforts = new Map<string, string[]>();

  extend(answer: Json) {
    const rows = answer?.data;
    if (!Array.isArray(rows)) throw new Error("model/list omitted data");
    for (const m of rows.filter((m: Json) => m?.hidden !== true)) {
      const id = typeof m?.id === "string" ? m.id : typeof m?.model === "string" && m?.id === undefined ? m.model : undefined;
      if (!id) continue;
      this.models.push(id);
      if (Array.isArray(m.supportedReasoningEfforts)) {
        const efforts: string[] = [];
        for (const level of m.supportedReasoningEfforts) {
          const effort = level?.reasoningEffort;
          if (typeof effort === "string" && effort !== "" && !efforts.includes(effort)) efforts.push(effort);
        }
        this.efforts.set(id, efforts);
      }
    }
  }
}

/// A thread's share of its app-server's notifications.
type Notice = { kind: "method"; method: string; params: Json } | { kind: "hostExited"; reason: string };
type Sink = (notice: Notice) => void;

/// What a crashed station had seen of a thread (read again from the app-server's output).
type Recovered = { busy: boolean; turnId: string | null; live: LiveFromCodex };

/// While sessions are being taken up, what the app-server says of a thread not taken up yet waits this long for it.
const ORPHANS_MS = 60_000;
const ORPHANS_MAX = 10_000;

function hostSignature(profile: Profile): string {
  const sorted = (entries: [string, string][]) => Object.fromEntries([...entries].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  return JSON.stringify([
    profile.home,
    sorted(Object.entries(profileEnv(profile, "codex"))),
    sorted(codexOverrides(accessKind(profile), profileModel(profile), profileVia(profile))),
  ]);
}

function hostArgs(profile: Profile): string[] {
  const args = ["app-server"];
  for (const [k, v] of codexOverrides(accessKind(profile), profileModel(profile), profileVia(profile))) args.push("-c", `${k}=${v}`);
  args.push("--listen", "stdio://");
  return args;
}

type Pending = { method: string; resolve: (v: Json) => void; reject: (e: Error) => void };

/// One app-server process and its JSON-RPC connection.
class Host {
  proc!: AgentProcess;
  readonly pending = new Map<number, Pending>();
  readonly threads = new Map<string, Sink>();
  /// The threads a turn runs on now: a process a profile edit made stale is replaced once they end.
  readonly busy = new Set<string>();
  private idlers: (() => void)[] = [];
  private ready: boolean;
  private readying: Promise<void> | null = null;
  /// Notices for threads not taken up yet, while sessions are being taken up (null otherwise).
  private orphans: Map<string, Notice[]> | null = null;
  /// After a crash: where each thread stood when the station that crashed stopped acknowledging.
  recovered = new Map<string, Recovered>();
  readonly profile: string;
  /// What the process was started with; a profile edit that changes it needs a new process.
  readonly signature: string;
  private nextId: number;

  constructor(profile: string, signature: string, nextId: number, ready: boolean) {
    this.profile = profile;
    this.signature = signature;
    this.nextId = nextId;
    this.ready = ready;
  }

  processOptions(label: string) {
    return { label, line: (line: string) => this.onLine(line), exit: (said: string, stderr: string) => this.onExit(said, stderr) };
  }

  /// When the login it was started with runs out, if it was lent by another station.
  lentUntil: number | null = null;

  static async start(profile: Profile, command: string, data: string, env: Env, caBundle: string, lent?: CodexDriverOptions["lent"]): Promise<Host> {
    mkdirSync(profile.home, { recursive: true });
    if (isMachine(profile)) linkCodexAuth(profile.home, env);
    const until = lent?.borrowed(profile) ? await lent.write(profile) : null;
    const childEnv: Record<string, string> = { ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(profile, "codex"), profile.id) };
    childEnv.CODEX_HOME = profile.home;
    withCaBundle(childEnv, caBundle);
    const host = new Host(profile.id, hostSignature(profile), 1, false);
    host.lentUntil = until;
    const label = `codex app-server ${profile.id}`;
    host.proc = await AgentProcess.start(data, runnerId("codex", profile.id), command, hostArgs(profile), childEnv, profile.home, host.processOptions(label));
    return host;
  }

  /// Takes up an app-server a runner keeps. Replies to what the previous station asked are dropped: its ids are below
  /// `nextId`.
  static adopt(profile: string, info: RunnerInfo, signature: string, nextId: number, ready: boolean, recovered?: Map<string, Recovered>): Host {
    log.info("agents::codex", "taking up a codex app-server", { profile, pgid: info.pgid, crashed: recovered !== undefined });
    const host = new Host(profile, signature, nextId, ready);
    if (recovered) host.recovered = recovered;
    host.orphans = new Map();
    wall.after(ORPHANS_MS, () => {
      const dropped = [...(host.orphans?.values() ?? [])].reduce((n, l) => n + l.length, 0);
      if (dropped > 0) log.warn("agents::codex", "notifications for threads nobody took up, dropped", { profile, threads: host.orphans?.size, dropped });
      host.orphans = null;
    });
    host.proc = AgentProcess.adopt(info, host.processOptions(`codex app-server ${profile}`));
    return host;
  }

  alive() {
    return !this.proc.hasExited() && !this.proc.handed();
  }

  /// A thread's sink, and what came for it before it was taken up.
  addThread(threadId: string, sink: Sink) {
    this.threads.set(threadId, sink);
    const waiting = this.orphans?.get(threadId);
    if (waiting) {
      this.orphans!.delete(threadId);
      for (const notice of waiting) sink(notice);
    }
  }

  private onLine(line: string) {
    let msg: Json;
    try {
      msg = JSON.parse(line);
    } catch {
      debug("agents::codex", "codex non-json line", { line: line.slice(0, 500) });
      return;
    }
    const method = typeof msg?.method === "string" ? (msg.method as string) : undefined;
    if (Number.isInteger(msg?.id) && method === undefined) {
      const reply = this.pending.get(msg.id);
      if (!reply) {
        log.info("agents::codex", "a reply to a request of an earlier station, dropped", { profile: this.profile, id: msg.id });
        return;
      }
      this.pending.delete(msg.id);
      if (msg.error !== undefined && msg.error !== null) reply.reject(new Error(`codex ${JSON.stringify(msg.error)}`));
      else reply.resolve(msg.result === undefined ? null : msg.result);
    } else if (msg?.id !== undefined && msg?.id !== null && method !== undefined) {
      // Server->client requests (approvals) should not arrive with approvalPolicy "never"; refuse rather than hang.
      log.warn("agents::codex", "codex asked the client something; refusing", { method });
      this.proc.write(JSON.stringify({ id: msg.id, error: { code: -32601, message: "the station does not answer client requests" } }));
    } else if (method !== undefined) {
      const params = msg.params === undefined ? null : msg.params;
      const thread = typeof params?.threadId === "string" ? (params.threadId as string) : undefined;
      if (thread === undefined) return;
      const notice: Notice = { kind: "method", method, params };
      const sink = this.threads.get(thread);
      if (sink) sink(notice);
      else if (this.orphans) {
        const waiting = this.orphans.get(thread) ?? [];
        if (waiting.length < ORPHANS_MAX) waiting.push(notice);
        this.orphans.set(thread, waiting);
      }
    }
  }

  private onExit(said: string, stderr: string) {
    const reason = `codex app-server exited (${said})${stderr === "" ? "" : `: ${stderr}`}`;
    for (const pending of this.pending.values()) pending.reject(new Error(reason));
    this.pending.clear();
    const threads = [...this.threads.values()];
    this.threads.clear();
    this.busy.clear();
    this.wake();
    for (const thread of threads) thread({ kind: "hostExited", reason });
  }

  turnStarted(threadId: string) {
    this.busy.add(threadId);
  }

  turnEnded(threadId: string) {
    this.busy.delete(threadId);
    if (this.busy.size === 0) this.wake();
  }

  private wake() {
    const idlers = this.idlers;
    this.idlers = [];
    for (const idler of idlers) idler();
  }

  /// Once no turn runs on it (or it exited).
  idle(): Promise<void> {
    if (this.busy.size === 0 || !this.alive()) return Promise.resolve();
    return new Promise((resolve) => this.idlers.push(resolve));
  }

  /// Whether it was started for another version of `profile` (an edit, or a key lent to the station renewed): its
  /// turns would use the old one, and a process started with the profile as it is now takes its place.
  outdated(profile: Profile): boolean {
    return this.signature !== hostSignature(profile);
  }

  async ensureReady() {
    while (this.readying) await this.readying;
    if (this.ready) return;
    this.readying = (async () => {
      await this.request("initialize", { clientInfo: { name: "comma-station", version: "0" }, capabilities: { experimentalApi: true } });
      this.proc.write(JSON.stringify({ method: "initialized", params: {} }));
      this.ready = true;
    })();
    try {
      await this.readying;
    } finally {
      this.readying = null;
    }
  }

  request(method: string, params: Json): Promise<Json> {
    if (this.proc.handed()) return Promise.reject(new Error("codex app-server was handed over"));
    if (!this.alive()) return Promise.reject(new Error("codex app-server is not running"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { method, resolve, reject });
      this.proc.write(JSON.stringify({ id, method, params }));
    });
  }

  /// Stops hearing it (handover): what it says from now on is the next station's; replies owed go there (and are
  /// dropped there).
  freeze() {
    if (this.proc.handed()) return;
    this.proc.freeze();
    for (const pending of this.pending.values()) pending.reject(new Error("codex app-server was handed over"));
    this.pending.clear();
  }

  detach() {
    this.freeze();
    this.threads.clear();
    this.proc.detach();
  }

  snapshot(): CodexHostSnapshot {
    return { runner: this.proc.info.id, signature: this.signature, nextId: this.nextId, ready: this.ready };
  }
}

export type CodexHostSnapshot = { runner: string; signature: string; nextId: number; ready: boolean };

/// A thread as a next station takes it up (codex.rs HandedThread), with what its app-server needs (HandedHost).
export type CodexSnapshot = {
  runtime: "codex";
  threadId: string;
  profile: string;
  busy: boolean;
  turnId: string | null;
  live: CodexLiveState;
  host: CodexHostSnapshot;
};

export type CodexDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The CLI, by name on the agent's PATH or a path (server.rs gives "codex").
  command?: string;
  /// The station's own environment (the machine's Codex home is found in it); process.env by default.
  env?: Env;
  /// Where the user's own skills are (~/.agents/skills), turned off for the station's agents.
  hostSkills?: string;
  /// The CA file Codex is pointed at (/etc/ssl/cert.pem).
  caBundle?: string;
  /// A session's own Fast choice (store.rs codex_session_fast): undefined when it has none.
  fast?: (threadId: string) => boolean | undefined;
  /// A profile as the config says now (settings), for what a turn reads of it; the opened one otherwise.
  currentProfile?: (id: string) => Profile | undefined;
  /// Another station's subscription, borrowed (share/index.ts): its home's auth.json written with tokens lent by the
  /// station signed in on it (none Codex could renew with); when they run out.
  lent?: { borrowed(profile: Profile): boolean; write(profile: Profile): Promise<number> };
};

/// A borrowed login this close to its end is replaced (its app-server started again, once idle).
const LENT_RENEW_MS = 6 * 3600_000;

/// When the access token in a home's auth.json runs out (0 when it does not say).
function lentExpiry(home: string): number {
  try {
    const token = JSON.parse(readFileSync(join(home, "auth.json"), "utf8"))?.tokens?.access_token;
    const claims = JSON.parse(Buffer.from(String(token).split(".")[1] ?? "", "base64url").toString("utf8"));
    return typeof claims?.exp === "number" ? claims.exp * 1000 : 0;
  } catch {
    return 0;
  }
}

export class CodexDriver implements AgentDriver {
  private readonly data: string;
  private readonly command: string;
  private readonly env: Env;
  private readonly hostSkills: string;
  private readonly caBundle: string;
  readonly options: CodexDriverOptions;
  private hosts = new Map<string, Host>();
  private hostQueue: Promise<unknown> = Promise.resolve();

  constructor(options: CodexDriverOptions) {
    this.options = options;
    this.data = options.data;
    this.command = options.command ?? "codex";
    this.env = options.env ?? process.env;
    this.hostSkills = options.hostSkills ?? join(this.env.HOME ?? "", ".agents", "skills");
    this.caBundle = options.caBundle ?? CA_BUNDLE;
  }

  runtime(): "codex" {
    return "codex";
  }

  /// Whether an app-server runs on a profile now (its login is not renewed from outside meanwhile).
  running(profileId: string): boolean {
    return this.hosts.get(profileId)?.alive() === true;
  }

  /// Whether `session`'s app-server is outdated for `profile` (see `Host.outdated`) and no turn runs on the session:
  /// opened again (`resume`), it goes on in a process started with the profile as it is now.
  stale(session: AgentSession, profile: Profile): boolean {
    return session instanceof CodexSession && session.staleFor(profile);
  }

  /// One at a time, as Rust's hosts mutex: starting, replacing and taking up hosts.
  private serial<T>(work: () => Promise<T>): Promise<T> {
    const next = this.hostQueue.then(work, work);
    this.hostQueue = next.catch(() => {});
    return next;
  }

  /// The profile's app-server, started if need be. One outdated for the profile (`Host.outdated`) is replaced first:
  /// the turns running on it go on to their end, and no thread is opened on it meanwhile (the open waits), so no turn
  /// starts with what the profile no longer says. Its loaded threads are closed with it, and taken up again
  /// (`resume`) by their next turn. A turn opens no session itself (the station's tools post, they do not wait on
  /// another session's turn), so what is waited on never waits on this.
  private async host(profile: Profile): Promise<Host> {
    for (;;) {
      const got = await this.serial(async (): Promise<Host | { drains: Host }> => {
        const current = this.hosts.get(profile.id);
        // A borrowed login about to run out: a new process with a new one, once no thread is loaded on it. Not under a
        // loaded thread: the lender may have no newer login to give (its own Codex running, it renews none), and a
        // process started then would be as close to its end; replacing one with loaded threads for that would go on
        // and on. Asking first is for another change.
        if (current && current.alive() && current.lentUntil !== null && current.lentUntil - wall.now() < LENT_RENEW_MS && current.threads.size === 0) {
          log.info("agents::codex", "its borrowed login runs out; restarting its codex app-server", { profile: profile.id });
          this.hosts.delete(profile.id);
          await current.proc.kill(5000);
        }
        if (current && current.alive() && current.outdated(profile)) {
          if (current.busy.size > 0) {
            log.info("agents::codex", "profile changed; its codex app-server is replaced once the turns on it end", { profile: profile.id, turns: current.busy.size });
            return { drains: current };
          }
          log.info("agents::codex", "profile changed; restarting its codex app-server", { profile: profile.id, threads: current.threads.size });
          this.hosts.delete(profile.id);
          await current.proc.kill(5000);
        }
        return this.hostNow(profile);
      });
      if (got instanceof Host) {
        await got.ensureReady();
        return got;
      }
      await got.drains.idle();
    }
  }

  /// The profile's app-server as it is, or one started (or taken up) for it. Under `serial`.
  private async hostNow(profile: Profile): Promise<Host> {
    const alive = this.hosts.get(profile.id);
    if (alive && alive.alive()) return alive;
    // Its app-server exited: its runner, on its way out, is not one to take up.
    if (alive) await alive.proc.released();
    // One an earlier station left running (its threads may be taken up yet) is taken up rather than replaced.
    const left = await findRunner(this.data, runnerId("codex", profile.id));
    const host = left ? await this.takeUp(profile, left) : await Host.start(profile, this.command, this.data, this.env, this.caBundle, this.options.lent);
    // Taken up on a borrowed login: when that one runs out, as its auth.json says.
    if (left && this.options.lent?.borrowed(profile)) host.lentUntil = lentExpiry(profile.home);
    this.hosts.set(profile.id, host);
    return host;
  }

  /// An app-server a runner keeps, with no snapshot: what the previous station had handled of it is read again to know
  /// where each thread stands.
  private async takeUp(profile: Profile, info: RunnerInfo): Promise<Host> {
    const out = outFile(this.data, info.id);
    const at = await ackedOffset(info, out);
    const recovered = new Map<string, Recovered>();
    for (const line of linesBefore(out, at)) {
      let msg: Json;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      const thread = msg?.params?.threadId;
      if (typeof msg?.method !== "string" || typeof thread !== "string") continue;
      const r = recovered.get(thread) ?? { busy: false, turnId: null, live: new LiveFromCodex() };
      recovered.set(thread, r);
      r.live.feed(msg.method, msg.params);
      if (msg.method === "turn/started") {
        r.busy = true;
        if (typeof msg.params.turn?.id === "string") r.turnId = msg.params.turn.id;
      } else if (msg.method === "turn/completed") {
        r.busy = false;
        r.turnId = null;
      }
    }
    // Its signature is the profile's if it runs with what the profile says now (the arguments carry the overrides).
    const same = JSON.stringify(info.args) === JSON.stringify(hostArgs(profile));
    // Ids above any the previous station can have sent.
    return Host.adopt(profile.id, info, same ? hostSignature(profile) : "unknown", wall.now(), true, recovered);
  }

  /// The account's rate-limit windows, as the profile's app-server reports them (ChatGPT subscriptions).
  async rateLimits(profile: Profile): Promise<Json> {
    return (await this.host(profile)).request("account/rateLimits/read", {});
  }

  async resetQuota(profile: Profile, key: string): Promise<Json> {
    return (await this.host(profile)).request("account/rateLimitResetCredit/consume", { idempotencyKey: key });
  }

  /// The models the account can run in Codex, as its app-server lists them (the ones it does not hide).
  async models(profile: Profile): Promise<ModelCatalog> {
    const host = await this.host(profile);
    const catalog = new ModelCatalog();
    let cursor: string | null = null;
    const seen = new Set<string>();
    for (;;) {
      const answer = await host.request("model/list", { cursor });
      catalog.extend(answer);
      cursor = typeof answer?.nextCursor === "string" && answer.nextCursor !== "" ? answer.nextCursor : null;
      if (cursor === null) break;
      if (seen.has(cursor)) throw new Error("model/list repeated its cursor");
      seen.add(cursor);
    }
    catalog.models = [...new Set(catalog.models.sort())];
    return catalog;
  }

  async open(options: OpenOptions, events: (event: RuntimeEvent) => void): Promise<AgentSession> {
    const host = await this.host(options.profile);
    const model = options.model ?? profileModel(options.profile);
    const skillsOff = hostSkillsOff(this.hostSkills);
    const config: Json = {
      "mcp_servers.comma-station.url": options.mcpUrl,
      "mcp_servers.comma-station.http_headers": { Authorization: `Bearer ${options.mcpToken}` },
      // Codex gives an MCP call 60 seconds by default; salix_call waits as long as its Salix tool (a long env.exec).
      "mcp_servers.comma-station.tool_timeout_sec": COMMA_STATION_MCP_TOOL_TIMEOUT_SECONDS,
      // The `comma` command's way to the station from the thread's shell commands (connector/comma-client-cli.ts, its
      // Salix backend): the app-server is one process for the profile, so the session's token goes in its thread.
      "shell_environment_policy.set": { COMMA_STATION_MCP_URL: options.mcpUrl, COMMA_STATION_MCP_TOKEN: options.mcpToken },
    };
    if (options.effort !== undefined) config.model_reasoning_effort = options.effort;
    if (skillsOff.length > 0) config["skills.config"] = skillsOff;
    const common: Json = { cwd: options.cwd, approvalPolicy: "never", sandbox: "danger-full-access", developerInstructions: options.instructions, config };
    if (model !== undefined) common.model = model;
    // None for a thread continued from a terminal: it keeps its own, so its cache holds.
    if (options.instructions === "") delete common.developerInstructions;
    let opened: Json;
    if (options.resume !== undefined) {
      common.threadId = options.resume;
      opened = await host.request("thread/resume", common);
      // A thread still loaded is rejoined as it is, with the MCP connection it had: one that failed (the station's
      // door was closed then) stays failed, and its turns have no station tools. Unloaded, it is loaded again with them.
      if (await stationToolsFailed(host, options.resume)) {
        log.warn("agents::codex", "a thread's station tools had failed; loading it again", { thread: options.resume });
        await host.request("thread/unsubscribe", { threadId: options.resume });
        opened = await host.request("thread/resume", common);
      }
    } else {
      opened = await host.request("thread/start", common);
    }
    const threadId = opened?.thread?.id;
    if (typeof threadId !== "string") throw new Error("codex gave no thread id");
    const session = new CodexSession(this, threadId, host, options.profile, { busy: false, turnId: null, closed: false }, new LiveFromCodex(), events);
    host.addThread(threadId, session.sink());
    return session;
  }

  async adopt(options: OpenOptions, snapshot: unknown | null, events: (event: RuntimeEvent) => void): Promise<AgentSession> {
    const handed = snapshot as CodexSnapshot | null;
    const profileId = handed?.profile ?? options.profile.id;
    const host = await this.serial(async () => {
      const current = this.hosts.get(profileId);
      if (current && current.alive()) return current;
      if (current) await current.proc.released();
      const id = handed?.host.runner ?? runnerId("codex", profileId);
      const info = await findRunner(this.data, id);
      if (!info) throw new Error(`codex app-server ${profileId} was not taken up: no runner keeps it`);
      const host = handed
        ? Host.adopt(profileId, info, handed.host.signature, handed.host.nextId, handed.host.ready)
        : await this.takeUp(options.profile, info);
      this.hosts.set(profileId, host);
      return host;
    });
    let session: CodexSession;
    if (handed) {
      session = new CodexSession(this, handed.threadId, host, options.profile, { busy: handed.busy, turnId: handed.turnId, closed: false }, new LiveFromCodex(handed.live), events);
    } else {
      const threadId = options.resume;
      if (threadId === undefined) throw new Error("a codex thread is taken up by its id (resume)");
      const r = host.recovered.get(threadId);
      host.recovered.delete(threadId);
      session = new CodexSession(this, threadId, host, options.profile, { busy: r?.busy ?? false, turnId: r?.turnId ?? null, closed: false }, r?.live ?? new LiveFromCodex(), events);
      // A turn is running that this station did not start.
      if (r?.busy) events({ type: "turnStarted" });
    }
    host.addThread(session.id(), session.sink());
    return session;
  }

  async shutdown() {
    const hosts = [...this.hosts.values()];
    this.hosts.clear();
    await Promise.all(hosts.map((h) => h.proc.kill(5000)));
  }

  detach() {
    for (const host of this.hosts.values()) host.detach();
    this.hosts.clear();
  }
}

/// Whether thread `threadId`'s connection to the station's MCP endpoint failed, as its app-server says (once its startup
/// ended). An app-server that cannot say: not known to have failed.
async function stationToolsFailed(host: Host, threadId: string): Promise<boolean> {
  try {
    const answer = await host.request("mcpServerStatus/list", { threadId, serverName: "comma", detail: "toolsAndAuthOnly" });
    return Array.isArray(answer?.data) && answer.data.some((s: Json) => s?.name === "comma" && s?.runtimeStatus === "failed");
  } catch {
    return false;
  }
}

type ThreadState = { busy: boolean; turnId: string | null; closed: boolean };

const input = (text: string) => [{ type: "text", text }];

export class CodexSession implements AgentSession {
  private driver: CodexDriver;
  private threadId: string;
  private host: Host;
  private profile: Profile;
  private state: ThreadState;
  private live: LiveFromCodex;
  private events: (event: RuntimeEvent) => void;

  constructor(driver: CodexDriver, threadId: string, host: Host, profile: Profile, state: ThreadState, live: LiveFromCodex, events: (event: RuntimeEvent) => void) {
    this.driver = driver;
    this.threadId = threadId;
    this.host = host;
    this.profile = profile;
    this.state = state;
    this.live = live;
    this.events = events;
  }

  private endTurn(outcome: TurnOutcome) {
    this.state.busy = false;
    this.state.turnId = null;
    this.host.turnEnded(this.threadId);
    this.events({ type: "turnEnded", outcome });
  }

  /// Whether this thread's app-server is outdated for `profile` (`Host.outdated`), and no turn runs on the thread.
  staleFor(profile: Profile): boolean {
    return !this.state.closed && this.host.alive() && this.host.outdated(profile) && !this.state.busy;
  }

  /// A thread's share of its app-server's notifications: its turns and live steps, as events.
  sink(): Sink {
    return (notice) => {
      if (notice.kind === "hostExited") {
        this.state.closed = true;
        if (this.state.busy) this.endTurn({ kind: "failed", reason: "exited", message: notice.reason });
        this.events({ type: "closed", why: notice.reason });
        return;
      }
      const { method, params } = notice;
      for (const event of this.live.feed(method, params)) this.events({ type: "live", event });
      if (method === "turn/started") {
        const id = params?.turn?.id;
        if (typeof id === "string") this.state.turnId = id;
        const was = this.state.busy;
        this.state.busy = true;
        this.host.turnStarted(this.threadId);
        if (!was) this.events({ type: "turnStarted" });
      } else if (method === "turn/completed") {
        const turn = params?.turn ?? null;
        const status = turn?.status;
        let outcome: TurnOutcome;
        if (status === "interrupted") outcome = { kind: "aborted" };
        else if (status === "failed") {
          const error = turn?.error ?? null;
          outcome = {
            kind: "failed",
            reason: classifyCodexError(error?.codexErrorInfo ?? null),
            message: chars(typeof error?.message === "string" ? error.message : "turn failed", 1000),
          };
        } else outcome = { kind: "completed" };
        this.endTurn(outcome);
      } else if (method === "error" && params?.willRetry !== true) {
        log.warn("agents::codex", "codex turn error", { thread: this.threadId, error: JSON.stringify(params?.error ?? null) });
      }
    };
  }

  id() {
    return this.threadId;
  }

  busy() {
    return this.state.busy;
  }

  async prompt(text: string) {
    const fast = this.driver.options.fast?.(this.threadId);
    if (this.state.closed) throw new Error("codex session is closed");
    if (this.state.busy) throw new Error("a turn is already running");
    this.state.busy = true;
    this.host.turnStarted(this.threadId);
    const params: Json = { threadId: this.threadId, input: input(text) };
    const p = this.driver.options.currentProfile ? this.driver.options.currentProfile(this.host.profile) : this.profile;
    if (p && accessKind(p) === "subscription") {
      // An explicit null clears a previously selected tier; omitting it would keep Fast on.
      params.serviceTier = (fast ?? profileFast(p)) ? "fast" : null;
    }
    try {
      const started = await this.host.request("turn/start", params);
      const id = started?.turn?.id;
      if (typeof id === "string") this.state.turnId = id;
    } catch (error) {
      this.state.busy = false;
      this.host.turnEnded(this.threadId);
      throw error;
    }
  }

  async steer(text: string) {
    if (this.state.closed || !this.state.busy || this.state.turnId === null) return false;
    try {
      await this.host.request("turn/steer", { threadId: this.threadId, input: input(text), expectedTurnId: this.state.turnId });
      return true;
    } catch (error) {
      debug("agents::codex", "codex steer refused", { thread: this.threadId, error: String(error) });
      return false;
    }
  }

  /// Codex cannot move what a turn waits on to the background.
  async backgroundTools() {}

  async abort() {
    if (this.state.closed || !this.state.busy || this.state.turnId === null) return;
    try {
      await this.host.request("turn/interrupt", { threadId: this.threadId, turnId: this.state.turnId });
    } catch (error) {
      log.warn("agents::codex", "codex interrupt failed", { thread: this.threadId, error: String(error) });
    }
  }

  async dispose() {
    if (this.state.closed) return;
    this.state.closed = true;
    this.host.threads.delete(this.threadId);
    this.host.turnEnded(this.threadId);
    // Handed over, the thread is the next station's.
    if (this.host.proc.handed()) return;
    // Best effort: the thread just stays loaded.
    await this.host.request("thread/unsubscribe", { threadId: this.threadId }).catch(() => {});
  }

  /// Stops hearing its app-server (all of its threads: lines are the app-server's): the thread stands as it last said.
  snapshot(): CodexSnapshot {
    this.host.freeze();
    this.state.closed = true;
    return {
      runtime: "codex",
      threadId: this.threadId,
      profile: this.host.profile,
      busy: this.state.busy,
      turnId: this.state.turnId,
      live: this.live.state(),
      host: this.host.snapshot(),
    };
  }

  detach() {
    this.state.closed = true;
    this.host.freeze();
    this.host.threads.delete(this.threadId);
    this.host.turnEnded(this.threadId);
    if (this.host.threads.size === 0) this.host.detach();
  }
}
