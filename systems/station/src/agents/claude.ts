// Claude Code driver (the Rust station's runtime/claude.rs): one `claude -p` stream-json process per session, under a
// runner whose id comes from the session key.
//
// Behaviour pinned by spikes (spike/README.md):
// - a turn is framed by system/init … result; `result.is_error` decides success, not `subtype` (an auth failure ends
//   as subtype "success");
// - 401/403 is retried silently for minutes, visible only as system/api_retry frames, so the first one fails the turn;
// - input written while a turn is finishing may start a turn of its own (a system/init with no prompt of ours);
// - interrupt is a control_request; the turn still ends with a result frame.
// - background_tasks (a control_request) moves the Bash commands and subagents a turn waits on to the background: each
//   call returns at once and the turn goes on; a task_notification tells when one ends. Input written after it is
//   read in the turn then, not when they end.
import { existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { log } from "../ops/log.ts";
import { LiveFromClaude, chars, type ClaudeLiveState } from "./live.ts";
import { CLAUDE_TOKEN_MARGIN_MS, machineClaudeToken, type Env, type MachineToken } from "./machine-logins.ts";
import { fileCredentials, takeBack } from "./no-keychain.ts";
import { AgentProcess, ackedOffset, debug, findRunner, linesBefore, outFile, runnerId } from "./process.ts";
import { bothNames, expandRoute, isMachine, profileEnv, profileModel } from "./profiles.ts";
import { cleanEnv, uuid, type AgentDriver, type AgentSession, type FailureReason, type OpenOptions, type Profile, type RuntimeEvent, type TurnOutcome } from "./runtime.ts";
import { wall } from "../ops/fibers.ts";

type Json = any;

const MCP_TOKEN_VAR = "STILLFAIL_MCP_TOKEN";
/// Inherited variables that would let a session authenticate as something other than its profile.
const SCRUBBED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"];

export const userMessage = (text: string) => JSON.stringify({ type: "user", message: { role: "user", content: [{ type: "text", text }] } });

/// Claude keeps a session at $CLAUDE_CONFIG_DIR/projects/<encoded cwd>/<id>.jsonl.
export function transcriptExists(home: string, sessionId: string): boolean {
  let dirs: string[];
  try {
    dirs = readdirSync(join(home, "projects"));
  } catch {
    return false;
  }
  return dirs.some((d) => {
    try {
      return statSync(join(home, "projects", d)).isDirectory() && existsSync(join(home, "projects", d, `${sessionId}.jsonl`));
    } catch {
      return false;
    }
  });
}

export function classifyResult(text: string): FailureReason {
  const lower = text.toLowerCase();
  const words = lower.split(/[^\p{L}\p{N}]+/u);
  const word = (w: string) => words.includes(w);
  if (word("401") || word("403") || lower.includes("authenticat") || lower.includes("api key")) return "auth";
  if (
    word("429") ||
    ["rate limit", "rate-limit", "rate_limit", "ratelimit", "usage limit", "overloaded"].some((s) => lower.includes(s)) ||
    ["session", "weekly", "daily"].some((window) => lower.includes(`hit your ${window} limit`)) ||
    lower.includes("you've hit your limit")
  ) {
    return "rate_limit";
  }
  return "model";
}

export type Turn = { busy: boolean; aborting: boolean; authFailure: string | null; closed: boolean };

/// A session as a next station takes it up (claude.rs Handed: the turn as its last handled line left it).
export type ClaudeSnapshot = {
  runtime: "claude";
  id: string;
  runner: string;
  turn: { busy: boolean; aborting: boolean; authFailure: string | null };
  machineExpires: number | null;
  live: ClaudeLiveState;
};

export type ClaudeDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The CLI, by name on the agent's PATH or a path (server.rs gives "claude").
  command?: string;
  /// The station's own environment (machine logins are read in it); process.env by default.
  env?: Env;
  /// The machine login's current token, renewed when about to run out (claude_oauth.rs; the accounts module's).
  machineToken?: (env: Env) => Promise<MachineToken>;
  /// Another station's subscription, borrowed (share/index.ts): a token lent by the station signed in on it, handed
  /// to the process as the machine's is.
  lent?: { borrowed(profile: Profile): boolean; token(profile: Profile): Promise<MachineToken> };
};

const interruptRequest = () => JSON.stringify({ type: "control_request", request_id: `interrupt-${uuid()}`, request: { subtype: "interrupt" } });

/// What a frame does to the turn (claude.rs on_frame). `interrupt` is how an auth failure stops the turn.
export function onFrame(frame: Json, turn: Turn, emit: (event: RuntimeEvent) => void, interrupt: () => void) {
  const kind = typeof frame?.type === "string" ? frame.type : "";
  const subtype = typeof frame?.subtype === "string" ? frame.subtype : "";
  if (kind === "system" && subtype === "init") {
    const was = turn.busy;
    turn.busy = true;
    if (!was) emit({ type: "turnStarted" });
  } else if (kind === "system" && subtype === "api_retry") {
    const status = Number.isInteger(frame.error_status) ? (frame.error_status as number) : 0;
    if ((status === 401 || status === 403) && turn.authFailure === null) {
      const error = frame.error === undefined ? "authentication failed" : typeof frame.error === "string" ? frame.error : JSON.stringify(frame.error);
      turn.authFailure = `${status} ${error}`;
      interrupt();
      turn.aborting = true;
    }
  } else if (kind === "result") {
    const text = typeof frame.result === "string" ? frame.result : subtype;
    let outcome: TurnOutcome;
    if (turn.authFailure !== null) outcome = { kind: "failed", reason: "auth", message: turn.authFailure };
    else if (turn.aborting) outcome = { kind: "aborted" };
    else if (frame.is_error === true) outcome = { kind: "failed", reason: classifyResult(text), message: chars(text, 1000) };
    else outcome = { kind: "completed" };
    turn.busy = false;
    turn.aborting = false;
    turn.authFailure = null;
    emit({ type: "turnEnded", outcome });
  }
}

const parse = (line: string): Json | undefined => {
  try {
    return JSON.parse(line);
  } catch {
    debug("agents::claude", "claude non-json line", { line: line.slice(0, 500) });
    return undefined;
  }
};

export class ClaudeDriver implements AgentDriver {
  private readonly data: string;
  private readonly command: string;
  private readonly env: Env;
  private readonly machineToken: (env: Env) => Promise<MachineToken>;
  private readonly lent: ClaudeDriverOptions["lent"];
  private live = new Set<ClaudeSession>();

  constructor(options: ClaudeDriverOptions) {
    this.data = options.data;
    this.command = options.command ?? "claude";
    this.env = options.env ?? process.env;
    this.machineToken = options.machineToken ?? machineClaudeToken;
    this.lent = options.lent;
  }

  runtime(): "claude" {
    return "claude";
  }

  async open(options: OpenOptions, events: (event: RuntimeEvent) => void): Promise<AgentSession> {
    const home = options.profile.home;
    mkdirSync(home, { recursive: true });
    if (options.resume !== undefined && !transcriptExists(home, options.resume)) {
      // claude would start and exit at once; failing here lets the caller start fresh.
      throw new Error(`no claude transcript for session ${options.resume}`);
    }
    const sessionId = options.resume ?? uuid();
    const mcpConfig = { mcpServers: { stillfail: { type: "http", url: options.mcpUrl, headers: { Authorization: `Bearer \${${MCP_TOKEN_VAR}}` } } } };
    const model = options.model ?? profileModel(options.profile);
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--dangerously-skip-permissions"];
    if (options.resume !== undefined) args.push("--resume", sessionId);
    else args.push("--session-id", sessionId);
    if (model !== undefined) args.push("--model", model);
    if (options.effort !== undefined) args.push("--effort", options.effort);
    // None for a session continued from a terminal: its system prompt stays as it began, so its cache holds.
    if (options.instructions !== "") args.push("--append-system-prompt", options.instructions);
    args.push("--mcp-config", JSON.stringify(mcpConfig));

    const env: Record<string, string> = { ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "claude"), options.route) };
    env.CLAUDE_CONFIG_DIR = home;
    env[MCP_TOKEN_VAR] = options.mcpToken;
    // Lets the agent name its own transcript, e.g. for an independent reviewer (codex has CODEX_THREAD_ID).
    for (const name of bothNames("RUNTIME_SESSION_ID")) env[name] = sessionId;
    // A machine profile runs on the machine's own login, handed over as its current token (machine_logins.rs).
    // Another station's subscription the same way, with the token that station lends.
    const machine = isMachine(options.profile)
      ? await this.machineToken(this.env)
      : this.lent?.borrowed(options.profile)
        ? await this.lent.token(options.profile)
        : undefined;
    if (machine) {
      env.CLAUDE_CODE_OAUTH_TOKEN = machine.token;
    } else {
      // Its own login stays in its home's file when it refreshes it (no_keychain.rs).
      await takeBack(home);
      fileCredentials(env);
    }
    // Its own root certificates, not the system's: read from the macOS keychain by a process outside the desktop
    // session, they took up to 36 s before a new session could start. One the user chose wins.
    env.CLAUDE_CODE_CERT_STORE ??= "bundled";
    // Claude Code nudges a model that has gone a few turns without writing to the user to say what it is doing. Here
    // ordinary output reaches nobody, so the nudge turned into status posts in the chat; the instructions say when to post.
    env.CLAUDE_CODE_SILENT_TURN_REMINDER ??= "0";

    const session = new ClaudeSession(this, sessionId, { busy: false, aborting: false, authFailure: null, closed: false }, machine?.expiresAt ?? null, new LiveFromClaude(), events);
    const label = `claude ${sessionId}`;
    session.attach(await AgentProcess.start(this.data, runnerId("claude", options.key), this.command, args, env, options.cwd, session.processOptions(label)));
    this.live.add(session);
    return session;
  }

  async adopt(options: OpenOptions, snapshot: unknown | null, events: (event: RuntimeEvent) => void): Promise<AgentSession> {
    const handed = snapshot as ClaudeSnapshot | null;
    const id = handed?.runner ?? runnerId("claude", options.key);
    const info = await findRunner(this.data, id);
    if (!info) throw new Error(`no runner keeps claude for ${options.key}`);
    let session: ClaudeSession;
    if (handed) {
      log.info("agents::claude", "taking up a claude process handed over", { session: handed.id, pgid: info.pgid, busy: handed.turn.busy });
      session = new ClaudeSession(this, handed.id, { ...handed.turn, closed: false }, handed.machineExpires, new LiveFromClaude(handed.live), events);
    } else {
      // The previous station crashed: what it had handled (stdout up to where it acknowledged) is read again, silently,
      // to know where the turn stands; the rest comes as it would have.
      const at = await ackedOffset(info, outFile(this.data, id));
      const turn: Turn = { busy: false, aborting: false, authFailure: null, closed: false };
      const live = new LiveFromClaude();
      for (const line of linesBefore(outFile(this.data, id), at)) {
        const frame = parse(line);
        if (frame === undefined) continue;
        live.feed(frame);
        onFrame(frame, turn, () => {}, () => {});
      }
      const flag = info.args.findIndex((a) => a === "--session-id" || a === "--resume");
      const sessionId = flag >= 0 ? info.args[flag + 1]! : (options.resume ?? "");
      log.info("agents::claude", "taking up a claude process after a crash", { session: sessionId, pgid: info.pgid, busy: turn.busy, from: at });
      // Its token is not known: as if about to run out, so its next turn starts it again with the machine's current one.
      session = new ClaudeSession(this, sessionId, turn, isMachine(options.profile) ? wall.now() : null, live, events);
      // A turn is running that this station did not start.
      if (turn.busy) events({ type: "turnStarted" });
    }
    session.attach(AgentProcess.adopt(info, session.processOptions(`claude ${session.id()}`)));
    this.live.add(session);
    return session;
  }

  forget(session: ClaudeSession) {
    this.live.delete(session);
  }

  async shutdown() {
    const live = [...this.live];
    this.live.clear();
    await Promise.all(live.map((s) => s.dispose()));
  }

  detach() {
    for (const session of this.live) session.detach();
    this.live.clear();
  }
}

export class ClaudeSession implements AgentSession {
  private proc!: AgentProcess;
  private driver: ClaudeDriver;
  private sessionId: string;
  private turn: Turn;
  /// The machine login's token this process runs on (machine profiles): when it runs out.
  private machineExpires: number | null;
  private live: LiveFromClaude;
  private events: (event: RuntimeEvent) => void;

  constructor(driver: ClaudeDriver, sessionId: string, turn: Turn, machineExpires: number | null, live: LiveFromClaude, events: (event: RuntimeEvent) => void) {
    this.driver = driver;
    this.sessionId = sessionId;
    this.turn = turn;
    this.machineExpires = machineExpires;
    this.live = live;
    this.events = events;
  }

  processOptions(label: string) {
    return {
      label,
      line: (line: string) => {
        const frame = parse(line);
        if (frame === undefined) return;
        for (const event of this.live.feed(frame)) this.events({ type: "live", event });
        onFrame(frame, this.turn, this.events, () => this.proc.write(interruptRequest()));
      },
      exit: (said: string, stderr: string) => {
        this.turn.closed = true;
        const busy = this.turn.busy;
        this.turn.busy = false;
        // What it wrote to stderr last is the only word of why one that fails as it starts gives (`claude exited (1)`
        // alone says nothing).
        const why = stderr === "" ? "" : `: ${stderr}`;
        if (busy) this.events({ type: "turnEnded", outcome: { kind: "failed", reason: "exited", message: `claude exited (${said}) during the turn${why}` } });
        this.events({ type: "closed", why: `claude exited (${said})${why}` });
        this.driver.forget(this);
      },
    };
  }

  attach(proc: AgentProcess) {
    this.proc = proc;
  }

  id() {
    return this.sessionId;
  }

  busy() {
    return this.turn.busy;
  }

  async prompt(text: string) {
    if (this.turn.closed) throw new Error("claude session is closed");
    if (this.turn.busy) throw new Error("a turn is already running");
    // Its token cannot refresh itself: about to run out, it is started again (resuming) with the machine's next one.
    if (this.machineExpires !== null && this.machineExpires - wall.now() < CLAUDE_TOKEN_MARGIN_MS) throw new Error("the machine login's token runs out");
    this.turn.busy = true;
    this.proc.write(userMessage(text));
  }

  async steer(text: string) {
    if (this.turn.closed || !this.turn.busy) return false;
    this.proc.write(userMessage(text));
    return true;
  }

  async backgroundTools() {
    if (this.turn.closed || !this.turn.busy) return;
    // Ctrl+B: every foreground Bash command and subagent. A CLI without it answers an error, and the message waits
    // as before.
    this.proc.write(JSON.stringify({ type: "control_request", request_id: `background-${uuid()}`, request: { subtype: "background_tasks" } }));
  }

  async abort() {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return;
    this.turn.aborting = true;
    this.proc.write(interruptRequest());
  }

  async dispose() {
    this.driver.forget(this);
    await this.proc.kill(5000);
  }

  /// Stops hearing it: the turn stands as its last handled line left it, and the lines after are the next station's.
  snapshot(): ClaudeSnapshot {
    this.proc.freeze();
    this.turn.closed = true;
    return {
      runtime: "claude",
      id: this.sessionId,
      runner: this.proc.info.id,
      turn: { busy: this.turn.busy, aborting: this.turn.aborting, authFailure: this.turn.authFailure },
      machineExpires: this.machineExpires,
      live: this.live.state(),
    };
  }

  detach() {
    this.turn.closed = true;
    this.driver.forget(this);
    this.proc.detach();
  }
}
