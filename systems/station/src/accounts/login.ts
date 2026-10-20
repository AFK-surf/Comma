// Signing a subscription profile in from the pages (the Rust station's login.rs). The runtime's own login command runs here,
// on the station's machine, so the credentials land in the profile's home; the page only relays what the person has to
// do in their browser:
// - Claude: `claude auth login` prints an authorize link; after approving, the browser shows a code, which the person
//   pastes back and the station types in.
// - Codex: `codex login --device-auth` prints a link and a one-time code; the person enters the code on that page and
//   the command finishes by itself.
// A stand-in `open` on PATH keeps the commands from opening a browser on the server. Who follows hears each change of a
// job (`changes`): pushed, not asked again.
import type { Clock } from "effect";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileCredentials } from "../agents/no-keychain.ts";
import { cleanEnv } from "../agents/runtime.ts";
import type { Runtime } from "../agents/profiles.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { Fibers } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";

export type LoginState = "starting" | "needs_code" | "needs_approval" | "verifying" | "done" | "failed" | "cancelled";

export type LoginJob = {
  profile: string;
  runtime: Runtime;
  state: LoginState;
  url: string | null;
  userCode: string | null;
  error: string | null;
  startedAt: number;
  expiresAt: number;
};

const TIMEOUT_MS = 15 * 60_000;
/// Variables that would make the login command talk to something other than the subscription.
const SCRUBBED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_HOME", "OPENAI_API_KEY"];

/// The login commands, by runtime.
export type LoginCommands = { claude: string; codex: string };

/// What a sign-in is for: a profile's id, the runtime it signs in to, and its home.
export type LoginProfile = { id: string; runtime: Runtime; home: string };

type Running = { run: number; job: LoginJob; child: ChildProcess; output: string; cancelTimer: () => void; exited: boolean; lang: Lang };

export class LoginManager {
  private jobs = new Map<string, Running>();
  private finished = new Map<string, LoginJob>();
  private listeners = new Set<(profile: string) => void>();
  private runs = 0;
  private noBrowserDir: string;
  private commands: LoginCommands;
  private background: Fibers;
  /// The environment the commands start from (the station's, less what points elsewhere).
  private env: () => Record<string, string>;

  constructor(data: string, commands: LoginCommands = { claude: "claude", codex: "codex" }, env: () => Record<string, string> = () => cleanEnv(SCRUBBED), clock?: Clock.Clock) {
    this.background = new Fibers("login", clock);
    this.noBrowserDir = join(data, "run", "no-browser");
    this.commands = commands;
    this.env = () => Object.fromEntries(Object.entries(env()).filter(([k]) => !SCRUBBED.includes(k)));
  }

  /// Hears the profile id of each login job that changes; gives the function that stops it.
  changes(listener: (profile: string) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  get(profile: string): LoginJob | null {
    const running = this.jobs.get(profile);
    if (running) return { ...running.job };
    const done = this.finished.get(profile);
    return done ? { ...done } : null;
  }

  /// Starts a sign-in for a subscription profile, replacing any running one.
  async start(profile: LoginProfile, lang: Lang = stationLang()): Promise<LoginJob> {
    this.cancel(profile.id);
    this.finished.delete(profile.id);
    mkdirSync(profile.home, { recursive: true });
    const [noBrowser, open] = this.noBrowser();
    const env = platform.prependPath(this.env(), noBrowser) as Record<string, string>;
    env.BROWSER = open;
    let command: string;
    let args: string[];
    if (profile.runtime === "claude") {
      env.CLAUDE_CONFIG_DIR = profile.home;
      fileCredentials(env);
      [command, args] = [this.commands.claude, ["auth", "login", "--claudeai"]];
    } else {
      env.CODEX_HOME = profile.home;
      [command, args] = [this.commands.codex, ["login", "--device-auth"]];
    }
    const now = this.background.now();
    const job: LoginJob = { profile: profile.id, runtime: profile.runtime, state: "starting", url: null, userCode: null, error: null, startedAt: now, expiresAt: now + TIMEOUT_MS };
    const run = ++this.runs;
    const id = profile.id;
    const r = platform.runnable(command, args, env);
    const child = spawn(r.file, r.args, { cwd: profile.home, env, stdio: ["pipe", "pipe", "pipe"], windowsVerbatimArguments: r.windowsVerbatimArguments, windowsHide: true });
    const spawned = await new Promise<Error | null>((resolve) => {
      child.once("spawn", () => resolve(null));
      child.once("error", (e) => resolve(e));
    });
    if (spawned) {
      // Recorded like any other failure, so the page shows why.
      const failed: LoginJob = { ...job, state: "failed", error: tr(lang, "station.login.cannotRun", { error: spawned.message }) };
      this.finished.set(id, failed);
      this.emit(id);
      return { ...failed };
    }
    // A later failure to write (the command gone) is its end's to say.
    child.stdin?.on("error", () => {});
    const running: Running = {
      run,
      job,
      child,
      output: "",
      exited: false,
      lang,
      cancelTimer: this.background.after(TIMEOUT_MS, () => this.failRun(id, run, tr(lang, "station.login.timedOut"))),
    };
    this.jobs.set(id, running);
    for (const stream of [child.stdout, child.stderr]) stream?.on("data", (chunk: Buffer) => this.output(id, run, chunk.toString("utf8")));
    // Everything it said is in before its end is judged: `close` comes after its output ends.
    child.once("close", (code, signal) => {
      const current = this.jobs.get(id);
      if (!current || current.run !== run) return;
      current.exited = true;
      if (code === 0) return this.finish(id, "done", null);
      const said = lastLines(current.output);
      const shown = code !== null ? String(code) : signal ? "signal" : "signal";
      this.finish(id, "failed", said !== "" ? said : tr(lang, "station.login.exited", { code: shown }));
    });
    log.info("login", "login started", { profile: id, runtime: profile.runtime });
    this.emit(id);
    return { ...job };
  }

  /// Claude only: the code the browser showed after approving.
  async submitCode(profile: string, code: string, lang: Lang = stationLang()): Promise<LoginJob> {
    const running = this.jobs.get(profile);
    if (!running || running.job.state !== "needs_code") throw new Error(tr(lang, "station.login.notWaitingForCode"));
    const clean = code.trim();
    if (clean === "") throw new Error(tr(lang, "station.login.emptyCode"));
    running.job.state = "verifying";
    const job = { ...running.job };
    await new Promise<void>((resolve, reject) => {
      const stdin = running.child.stdin;
      if (!stdin || stdin.destroyed) return resolve();
      stdin.write(`${clean}\n`, (error) => (error ? reject(error) : resolve()));
    });
    this.emit(profile);
    return job;
  }

  cancel(profile: string) {
    if (this.jobs.has(profile)) this.finish(profile, "cancelled", null);
  }

  stopAll() {
    for (const id of [...this.jobs.keys()]) this.cancel(id);
  }

  /// Stops every sign-in and what waits on them.
  async close() {
    this.stopAll();
    await this.background.close();
  }

  private output(profile: string, run: number, chunk: string) {
    const running = this.jobs.get(profile);
    if (!running || running.run !== run) return;
    running.output += stripAnsi(chunk);
    const chars = [...running.output];
    if (chars.length > 8000) running.output = chars.slice(chars.length - 8000).join("");
    if (parse(running.job, running.output)) this.emit(profile);
  }

  private failRun(profile: string, run: number, error: string) {
    if (this.jobs.get(profile)?.run === run) this.finish(profile, "failed", error);
  }

  private finish(profile: string, state: LoginState, error: string | null) {
    const running = this.jobs.get(profile);
    if (!running) return;
    this.jobs.delete(profile);
    running.cancelTimer();
    if (!running.exited) {
      try {
        running.child.kill("SIGTERM");
      } catch {}
    }
    this.finished.set(profile, { ...running.job, state, error });
    log.info("login", "login ended", { profile, state, error });
    this.emit(profile);
  }

  private emit(profile: string) {
    for (const listener of this.listeners) {
      try {
        listener(profile);
      } catch (e) {
        log.warn("login", "a login listener failed", { error: (e as Error).message });
      }
    }
  }

  /// A directory whose `open` and `xdg-open` do nothing, put first on the login command's PATH; and what `open` is to
  /// be called by (BROWSER).
  private noBrowser(): [dir: string, open: string] {
    mkdirSync(this.noBrowserDir, { recursive: true });
    const [open] = ["open", "xdg-open"].map((name) => platform.makeCommand(join(this.noBrowserDir, name), "#!/bin/sh\nexit 0\n", true));
    return [this.noBrowserDir, open!];
  }
}

/// Reads where to sign in from what the command said so far. Whether the job changed.
export function parse(job: LoginJob, output: string): boolean {
  if (job.state !== "starting") return false;
  const urls = output
    .split(/\s+/)
    .filter((w) => w.includes("https://"))
    .map((w) => w.slice(w.indexOf("https://")));
  if (job.runtime === "claude") {
    const url = urls.find((u) => u.includes("/oauth/authorize?") && !u.endsWith("?"));
    if (url !== undefined && output.toLowerCase().includes("paste code")) {
      job.url = url;
      job.state = "needs_code";
      return true;
    }
  } else {
    const url = urls.find((u) => u.startsWith("https://auth.openai.com/") && u.includes("device"));
    const code = deviceCode(output);
    if (url !== undefined && code !== null) {
      job.url = url;
      job.userCode = code;
      job.state = "needs_approval";
      return true;
    }
  }
  return false;
}

/// A one-time code like ABCD-12345: four capitals or digits, a dash, four to six more.
export function deviceCode(output: string): string | null {
  const code = (s: string, min: number, max: number) => s.length >= min && s.length <= max && /^[A-Z0-9]+$/.test(s);
  for (const word of output.split(/[^A-Za-z0-9_-]/)) {
    const parts = word.split("-");
    for (let i = 0; i + 1 < parts.length; i++) {
      if (code(parts[i]!, 4, 4) && code(parts[i + 1]!, 4, 6)) return `${parts[i]}-${parts[i + 1]}`;
    }
  }
  return null;
}

/// Drops terminal escapes (colours, cursor moves): ESC [ parameters letter.
export function stripAnsi(text: string): string {
  let out = "";
  const chars = [...text];
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i]!;
    if (c === "\u001b" && chars[i + 1] === "[") {
      i += 1;
      while (i + 1 < chars.length) {
        const p = chars[i + 1]!;
        i += 1;
        if (/[A-Za-z]/.test(p)) break;
        if (!/[0-9;?]/.test(p)) break;
      }
      continue;
    }
    out += c;
  }
  return out;
}

function lastLines(output: string): string {
  const lines = output
    .trim()
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "");
  return [...lines.slice(Math.max(0, lines.length - 4)).join("\n")].slice(0, 600).join("");
}
