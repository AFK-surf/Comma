// Who this machine's own Claude Code and Codex are signed in as, in their usual homes (~/.claude, ~/.codex)
// (the Rust station's machine_logins.rs `MachineLogins`): for the pages that ask for a first profile, and for making a
// `machine` profile. How such a profile uses the login is agents/machine-logins.ts's (and oauth.ts renews Claude's).
//
// Read at start, when a profile on it is made, after a runtime is installed, and when the overview is read with a
// reading older than two minutes (in the background: the overview answers with the last one). Nothing on the machine
// says when someone signs in or out in a terminal, so that age is what tells it to read again; who follows hears a
// reading that differs from the last (`changes`).
import type { Clock } from "effect";
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { codexHome, type Env, readClaudeCredentials } from "../agents/machine-logins.ts";
import { liveClock } from "../ops/fibers.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import type { ProfileQuota } from "./profiles.ts";
import { platform } from "../platform/index.ts";

type Json = any;

export type MachineLogin = {
  runtime: "claude" | "codex";
  /// Its command is on the station's PATH.
  installed: boolean;
  /// Signed in with an account (a subscription or a key).
  loggedIn: boolean;
  email: string | null;
  plan: string | null;
  /// A profile can use it as it is (kept in a file, not only in the keychain).
  usable: boolean;
  /// Its allowance, as a profile on it would show (none until read, or when it cannot be).
  quota: Json | null;
  /// In a line, as the pages show it.
  text: string;
};

/// How long a reading serves before the next overview reads again.
const FRESH_MS = 2 * 60_000;

const label = (runtime: "claude" | "codex") => (runtime === "claude" ? "Claude Code" : "Codex");

const login = (runtime: "claude" | "codex", installed: boolean, loggedIn: boolean, text: string): MachineLogin => ({
  runtime, installed, loggedIn, email: null, plan: null, usable: false, quota: null, text,
});

/// How a login's allowance is read (quota.ts machineUsage).
export type Usage = (runtime: "claude" | "codex", env: Env) => Promise<ProfileQuota | Json | null>;

export class MachineLogins {
  private logins: MachineLogin[] = [];
  private readAt = 0;
  private reading: Promise<void> | null = null;
  private listeners = new Set<() => void>();

  readonly env: Env;
  private usage?: Usage;
  private lang: () => Lang;

  private clock: Clock.Clock;

  constructor(env: Env, usage?: Usage, lang: () => Lang = stationLang, clock: Clock.Clock = liveClock) {
    this.clock = clock;
    this.env = env;
    this.usage = usage;
    this.lang = lang;
  }

  /// The last reading, at once; read again in the background when it is old.
  get(): MachineLogin[] {
    if (this.clock.currentTimeMillisUnsafe() - this.readAt > FRESH_MS) void this.refresh();
    return this.logins.map((l) => ({ ...l }));
  }

  /// Hears each reading that differs from the last.
  changes(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /// Reads them now (or waits for the reading under way).
  refresh(): Promise<void> {
    this.reading ??= this.read().finally(() => (this.reading = null));
    return this.reading;
  }

  private async read() {
    const lang = this.lang();
    const logins = await Promise.all([claudeLogin(this.env, lang), codexLogin(this.env, lang)]);
    // Each one a profile could use, with its allowance: an account refused (suspended, say) shows before it is used.
    if (this.usage) {
      for (const l of logins.filter((l) => l.loggedIn && l.usable)) {
        try {
          const q = (await this.usage(l.runtime, this.env)) ?? null;
          l.quota = q !== null && typeof q === "object" ? { ...q, checkedAt: this.clock.currentTimeMillisUnsafe() } : q;
        } catch {
          l.quota = null;
        }
      }
    }
    // When it was read is not a change: what was read is.
    const said = (ls: MachineLogin[]) => JSON.stringify(ls, (k, v) => (k === "checkedAt" ? undefined : v));
    const changed = said(logins) !== said(this.logins);
    this.logins = logins;
    this.readAt = this.clock.currentTimeMillisUnsafe();
    if (changed) for (const listener of this.listeners) listener();
  }
}

/// The environment the machine's own CLI would run in: none of what points it at another home or account.
const machineEnv = (env: Env, drop: string[]): Env => Object.fromEntries(Object.entries(env).filter(([k, v]) => v !== undefined && !drop.includes(k)));

const CLAUDE_DROP = ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"];

/// What a command said, and how it ended: undefined when it could not be run at all (not installed).
function run(command: string, args: string[], env: Env): Promise<{ ok: boolean; stdout: string; stderr: string } | undefined | Error> {
  return new Promise((resolve) => {
    const r = platform.runnable(command, args, env as NodeJS.ProcessEnv);
    execFile(r.file, r.args, { env: env as NodeJS.ProcessEnv, timeout: 20_000, killSignal: "SIGKILL", windowsVerbatimArguments: r.windowsVerbatimArguments }, (error, stdout, stderr) => {
      if (error && (error as NodeJS.ErrnoException).code === "ENOENT") return resolve(undefined);
      if (error && error.killed) return resolve(new Error(`${command} took too long`));
      resolve({ ok: !error, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

async function claudeLogin(env: Env, lang: Lang): Promise<MachineLogin> {
  const rt = "claude";
  const name = label(rt);
  const ran = await run("claude", ["auth", "status"], machineEnv(env, CLAUDE_DROP));
  if (ran === undefined) return login(rt, false, false, tr(lang, "station.machine.notInstalled", { name }));
  if (ran instanceof Error) return login(rt, true, false, tr(lang, "station.machine.unreadableFor", { name }));
  // `auth status` exits non-zero when signed out, still printing its JSON.
  let status: Json;
  try {
    status = JSON.parse(ran.stdout);
  } catch {
    return login(rt, true, false, tr(lang, "station.machine.unreadableFor", { name }));
  }
  if (status?.loggedIn !== true) return login(rt, true, false, tr(lang, "station.machine.signedOut", { name }));
  const email = typeof status.email === "string" ? status.email : null;
  const plan = typeof status.subscriptionType === "string" ? status.subscriptionType : null;
  const usable = (await readClaudeCredentials(env as Record<string, string | undefined>)) !== undefined;
  const text = said(name, email, plan, lang);
  return { runtime: rt, installed: true, loggedIn: true, email, plan, usable, quota: null, text: usable ? text : tr(lang, "station.machine.inKeychainUnreadable", { text }) };
}

async function codexLogin(env: Env, lang: Lang): Promise<MachineLogin> {
  const rt = "codex";
  const name = label(rt);
  const home = codexHome(env);
  const ran = await run("codex", ["login", "status"], { ...machineEnv(env, ["OPENAI_API_KEY", "CODEX_API_KEY"]), CODEX_HOME: home });
  if (ran === undefined) return login(rt, false, false, tr(lang, "station.machine.notInstalled", { name }));
  // `login status` exits non-zero when signed out.
  const text = ran instanceof Error ? "" : `${ran.stdout}${ran.stderr}`;
  const lower = text.toLowerCase();
  if (!lower.includes("logged in") || lower.includes("not logged in")) return login(rt, true, false, tr(lang, "station.machine.signedOut", { name }));
  const [email, plan] = codexAccount(home);
  const usable = existsSync(join(home, "auth.json"));
  const line = said(name, email, plan, lang);
  return { runtime: rt, installed: true, loggedIn: true, email, plan, usable, quota: null, text: usable ? line : tr(lang, "station.machine.inKeychain", { text: line }) };
}

/// The claims of a Codex home's id token (auth.json), when it has one.
export function codexClaims(home: string): Json | undefined {
  try {
    const auth = JSON.parse(readFileSync(join(home, "auth.json"), "utf8"));
    const payload = String(auth?.tokens?.id_token ?? "").split(".")[1];
    if (!payload) return undefined;
    return JSON.parse(Buffer.from(payload.replace(/=+$/, ""), "base64url").toString("utf8"));
  } catch {
    return undefined;
  }
}

/// The account in Codex's auth.json: its id token's email and ChatGPT plan (none for an API key, or in the keyring).
function codexAccount(home: string): [string | null, string | null] {
  const claims = codexClaims(home);
  if (!claims) return [null, null];
  const email = claims.email ?? claims["https://api.openai.com/profile"]?.email;
  const plan = claims["https://api.openai.com/auth"]?.chatgpt_plan_type;
  return [typeof email === "string" ? email : null, typeof plan === "string" ? plan : null];
}

export const capitalized = (plan: string) => (plan === "" ? "" : plan[0]!.toUpperCase() + plan.slice(1));

function said(name: string, email: string | null, plan: string | null, lang: Lang): string {
  const p = plan === null ? null : capitalized(plan);
  if (email !== null && p !== null) return tr(lang, "station.machine.signedInAsPlan", { name, email, plan: p });
  if (email !== null) return tr(lang, "station.machine.signedInAs", { name, email });
  if (p !== null) return tr(lang, "station.machine.signedInPlan", { name, plan: p });
  return tr(lang, "station.machine.signedIn", { name });
}
