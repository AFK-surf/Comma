// Renewing a Claude login without sending a prompt (the Rust station's claude_oauth.rs): under Claude Code's own locks (its
// current one in the config directory and its legacy one beside it), read again once locked, and saved back where it
// was (the keychain for the machine's login on macOS, else the file), never as a copy. Used for the machine profile's
// token (the Claude driver's `machineToken`) and for reading a subscription's allowance.
import { execFile, spawn } from "node:child_process";
import { closeSync, fstatSync, mkdirSync, openSync, readFileSync, realpathSync, rmdirSync, statSync, futimesSync } from "node:fs";
import { join } from "node:path";
import type { Env } from "../agents/machine-logins.ts";
import { writePrivate } from "../agents/no-keychain.ts";
import { wall } from "../ops/fibers.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { platform } from "../platform/index.ts";

type Json = any;

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const ITEM = "Claude Code-credentials";
const MARGIN_MS = 5 * 60_000;
const LOCK_WAIT_MS = 40_000;
const LOCK_STALE_MS = 60_000;
const HEARTBEAT_MS = 5_000;

/// The OAuth access token Claude Code keeps in this config directory's file (quota.rs claude_token).
export function claudeToken(home: string): string | undefined {
  try {
    const token = JSON.parse(readFileSync(join(home, ".credentials.json"), "utf8"))?.claudeAiOauth?.accessToken;
    return typeof token === "string" && token !== "" ? token : undefined;
  } catch {
    return undefined;
  }
}

type Credentials = { data: Json; keychain: boolean };

function access(c: Credentials, lang: Lang): [string, number] {
  const oauth = c.data?.claudeAiOauth;
  const token = oauth?.accessToken;
  if (typeof token !== "string" || token === "") throw new Error(tr(lang, "station.claudeAuth.noCredentials"));
  return [token, Number.isInteger(oauth.expiresAt) ? oauth.expiresAt : 0];
}

function usable(c: Credentials, rejected: string | null, lang: Lang): boolean {
  try {
    const [token, expires] = access(c, lang);
    return rejected !== token && (expires === 0 || expires - wall.now() > MARGIN_MS);
  } catch {
    return false;
  }
}

const homeOf = (env: Env) => platform.home(env) ?? ".";

function run(command: string, args: string[], env: Env, input?: string): Promise<{ ok: boolean; stdout: string } | undefined> {
  return new Promise((resolve) => {
    const r = platform.runnable(command, args, env as NodeJS.ProcessEnv);
    const child = execFile(r.file, r.args, { env: env as NodeJS.ProcessEnv, timeout: 10_000, killSignal: "SIGKILL", windowsVerbatimArguments: r.windowsVerbatimArguments }, (error, stdout) => {
      if (error && (error as NodeJS.ErrnoException).code === "ENOENT") resolve(undefined);
      else resolve({ ok: !error, stdout: String(stdout) });
    });
    if (input !== undefined) child.stdin?.end(input);
    else child.stdin?.end();
  });
}

async function read(env: Env, home: string, machine: boolean, lang: Lang): Promise<Credentials> {
  if (machine && platform.hasKeychain) {
    const found = await run("security", ["find-generic-password", "-w", "-s", ITEM], env);
    if (found?.ok) {
      // An unreadable keychain entry must not be replaced with a stale file's login.
      try {
        return { data: JSON.parse(found.stdout), keychain: true };
      } catch {
        throw new Error(tr(lang, "station.claudeAuth.keychainUnreadable"));
      }
    }
  }
  let text: string;
  try {
    text = readFileSync(join(home, ".credentials.json"), "utf8");
  } catch {
    throw new Error(tr(lang, "station.claudeAuth.noCredentials"));
  }
  try {
    return { data: JSON.parse(text), keychain: false };
  } catch {
    throw new Error(tr(lang, "station.claudeAuth.credentialsUnreadable"));
  }
}

async function save(env: Env, home: string, c: Credentials, lang: Lang) {
  if (!c.keychain) {
    try {
      writePrivate(join(home, ".credentials.json"), JSON.stringify(c.data));
      return;
    } catch {
      throw new Error(tr(lang, "station.claudeAuth.saveFailed"));
    }
  }
  // Secrets kept off argv, as Claude Code does: `security -i` reads its commands from stdin.
  const who = await run("/usr/bin/id", ["-un"], process.env as Env);
  const account = who?.stdout.trim() ?? "";
  if (!who?.ok || account === "" || /["\\\n\r]/.test(account)) throw new Error(tr(lang, "station.claudeAuth.keychainAccount"));
  const input = `add-generic-password -U -a "${account}" -s "${ITEM}" -X "${Buffer.from(JSON.stringify(c.data)).toString("hex")}"\n`;
  await new Promise<void>((resolve, reject) => {
    const child = spawn("security", ["-i"], { env: env as NodeJS.ProcessEnv, stdio: ["pipe", "ignore", "ignore"] });
    const timer = wall.after(10_000, () => {
      child.kill("SIGKILL");
      reject(new Error(tr(lang, "station.claudeAuth.keychainTimeout")));
    });
    child.on("error", () => {
      timer();
      reject(new Error(tr(lang, "station.claudeAuth.keychainWrite")));
    });
    child.on("exit", (code) => {
      timer();
      if (code === 0) resolve();
      else reject(new Error(tr(lang, "station.claudeAuth.keychainSaveFailed")));
    });
    child.stdin.end(input);
  });
}

/// A current access token and when it runs out: the one kept, unless it is about to run out or is `rejected` (a 401
/// said so); then renewed. `home`: a profile's config directory; null: the machine's own login (~/.claude, and on
/// macOS the keychain first).
export async function claudeOAuthToken(env: Env, home: string | null, rejected: string | null, endpoint: string, lang: Lang = stationLang()): Promise<[string, number]> {
  const machine = home === null;
  const dir = home ?? join(homeOf(env), ".claude");
  const initial = await read(env, dir, machine, lang);
  if (usable(initial, rejected, lang)) return access(initial, lang);
  mkdirSync(dir, { recursive: true });
  const current = await RefreshLock.acquire(join(dir, ".oauth_refresh.lock"), lang);
  try {
    const legacy = await RefreshLock.acquire(`${realpathSync(dir)}.lock`, lang);
    try {
      return await renew(env, dir, machine, rejected, endpoint, lang);
    } finally {
      legacy.release();
    }
  } finally {
    current.release();
  }
}

async function renew(env: Env, home: string, machine: boolean, rejected: string | null, endpoint: string, lang: Lang): Promise<[string, number]> {
  const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
  const credentials = await read(env, home, machine, lang);
  if (usable(credentials, rejected, lang)) return access(credentials, lang);
  const oauth = credentials.data?.claudeAiOauth ?? {};
  const refresh = oauth.refreshToken;
  if (typeof refresh !== "string" || refresh === "") throw new Error(t("station.claudeAuth.expiredNoRefresh"));
  const body: Json = { grant_type: "refresh_token", refresh_token: refresh, client_id: typeof oauth.clientId === "string" && oauth.clientId !== "" ? oauth.clientId : CLIENT_ID };
  if (Array.isArray(oauth.scopes)) {
    const scopes = oauth.scopes.filter((s: unknown) => typeof s === "string");
    if (scopes.length > 0) body.scope = scopes.join(" ");
  }
  let response: Response;
  try {
    response = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), redirect: "manual", signal: AbortSignal.timeout(30_000) });
  } catch {
    throw new Error(t("station.claudeAuth.refreshFailed"));
  }
  if (!response.ok) {
    // A CLI version using different locks may have won: its credentials are never erased or rolled back.
    const latest = await read(env, home, machine, lang);
    if (usable(latest, rejected, lang)) return access(latest, lang);
    const status = response.status;
    throw new Error(t(status === 400 || status === 401 ? "station.claudeAuth.refreshRefused" : "station.claudeAuth.refreshUnavailable", { status }));
  }
  let answer: Json;
  try {
    answer = await response.json();
  } catch {
    throw new Error(t("station.claudeAuth.badResponse"));
  }
  const token = answer?.access_token;
  if (typeof token !== "string" || token === "") throw new Error(t("station.claudeAuth.noAccessToken"));
  const seconds = answer?.expires_in;
  const sane = (s: unknown): s is number => Number.isInteger(s) && (s as number) > 0 && (s as number) < Number.MAX_SAFE_INTEGER / 2000;
  if (!sane(seconds)) throw new Error(t("station.claudeAuth.noExpiry"));
  const latest = await read(env, home, machine, lang);
  if (latest.keychain !== credentials.keychain || JSON.stringify(latest.data?.claudeAiOauth?.refreshToken) !== JSON.stringify(oauth.refreshToken)) {
    // A simultaneous login wins over this refresh, even of another account.
    if (usable(latest, null, lang)) return access(latest, lang);
    throw new Error(t("station.claudeAuth.changedDuringRefresh"));
  }
  const updated = latest.data.claudeAiOauth;
  updated.accessToken = token;
  updated.expiresAt = wall.now() + seconds * 1000;
  if (typeof answer.refresh_token === "string" && answer.refresh_token !== "") updated.refreshToken = answer.refresh_token;
  if (typeof answer.scope === "string") updated.scopes = answer.scope.split(/\s+/).filter((s: string) => s !== "");
  if (sane(answer.refresh_token_expires_in)) updated.refreshTokenExpiresAt = wall.now() + answer.refresh_token_expires_in * 1000;
  let error: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await wall.sleep(100);
    try {
      await save(env, home, latest, lang);
      error = undefined;
      break;
    } catch (e) {
      error = e;
    }
  }
  if (error) throw error;
  return access(latest, lang);
}

/// proper-lockfile-compatible mkdir locks, as Claude Code takes them: a 5 s heartbeat and a 60 s stale threshold. The
/// directory is held open, so an owner from before cannot touch or remove a lock that replaced its own.
export class RefreshLock {
  private path: string;
  private fd: number;
  private heartbeat: () => void;

  private constructor(path: string, fd: number, heartbeat: () => void) {
    this.path = path;
    this.fd = fd;
    this.heartbeat = heartbeat;
  }

  static async acquire(path: string, lang: Lang = stationLang()): Promise<RefreshLock> {
    const deadline = wall.now() + LOCK_WAIT_MS;
    for (;;) {
      try {
        mkdirSync(path);
        break;
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw new Error(tr(lang, "station.claudeAuth.lockFailed"));
        let age = 0;
        try {
          age = wall.now() - statSync(path).mtimeMs;
        } catch {
          continue;
        }
        if (age > LOCK_STALE_MS) {
          try {
            rmdirSync(path);
            continue;
          } catch (e) {
            if ((e as NodeJS.ErrnoException).code === "ENOENT") continue;
          }
        }
        if (wall.now() >= deadline) throw new Error(tr(lang, "station.claudeAuth.refreshLocked"));
        await wall.sleep(100);
      }
    }
    const fd = openSync(path, "r");
    const heartbeat = wall.every(HEARTBEAT_MS, () => {
      try {
        const now = new Date(wall.now());
        futimesSync(fd, now, now);
      } catch {
        heartbeat();
      }
    });
    return new RefreshLock(path, fd, heartbeat);
  }

  release() {
    this.heartbeat();
    try {
      const held = fstatSync(this.fd);
      const current = statSync(this.path);
      if (held.dev === current.dev && held.ino === current.ino) rmdirSync(this.path);
    } catch {}
    try {
      closeSync(this.fd);
    } catch {}
  }
}
