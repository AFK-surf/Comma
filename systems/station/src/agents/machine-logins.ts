// How a `machine` profile uses this machine's own login (the Rust station's machine_logins.rs). Never copied: both vendors
// rotate single-use refresh tokens, so a copy would sign one side out later.
// - Codex: the profile's home links auth.json to the machine's; Codex saves through the link, so both share one login.
// - Claude Code: a link does not hold (it replaces the file when it refreshes), so the profile's processes are handed
//   the machine's current access token (CLAUDE_CODE_OAUTH_TOKEN) and never refresh. It is read where claude reads it:
//   on macOS the keychain first, then the file (a claude run by hand saves to the keychain and deletes the file).
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";

export type Env = Record<string, string | undefined>;

/// How close to running out a token is taken as run out: Claude Code refreshes its own this close to the end, so a
/// process handed one this close is started again for its next turn.
export const CLAUDE_TOKEN_MARGIN_MS = 5 * 60_000;

export type MachineToken = { token: string; expiresAt: number };

const homeOf = (env: Env) => platform.home(env) ?? ".";
export const claudeCredentialsFile = (env: Env) => join(homeOf(env), ".claude", ".credentials.json");
export const codexHome = (env: Env) => (env.CODEX_HOME ? env.CODEX_HOME : join(homeOf(env), ".codex"));
export const codexAuthFile = (env: Env) => join(codexHome(env), "auth.json");

/// The keychain item Claude Code keeps the machine's login in on macOS (no CLAUDE_CONFIG_DIR, so no suffix).
const CLAUDE_KEYCHAIN_ITEM = "Claude Code-credentials";

export function parseClaudeCredentials(text: string): MachineToken | undefined {
  try {
    const oauth = JSON.parse(text)?.claudeAiOauth;
    const token = oauth?.accessToken;
    if (typeof token !== "string" || token === "") return undefined;
    return { token, expiresAt: typeof oauth.expiresAt === "number" ? oauth.expiresAt : 0 };
  } catch {
    return undefined;
  }
}

/// The machine's Claude Code login where claude reads it: on macOS the keychain first, then the file.
export async function readClaudeCredentials(env: Env): Promise<MachineToken | undefined> {
  if (platform.hasKeychain) {
    const found = await new Promise<string | undefined>((resolve) =>
      execFile("security", ["find-generic-password", "-w", "-s", CLAUDE_KEYCHAIN_ITEM], { env, timeout: 10_000 }, (error, stdout) =>
        resolve(error ? undefined : String(stdout).trim()),
      ),
    );
    const parsed = found === undefined ? undefined : parseClaudeCredentials(found);
    if (parsed) return parsed;
  }
  try {
    return parseClaudeCredentials(readFileSync(claudeCredentialsFile(env), "utf8"));
  } catch {
    return undefined;
  }
}

/// The machine's current token, as machine_claude_token gives it. Renewing it when it is about to run out
/// (claude_oauth.rs, under Claude Code's own locks) is the accounts module's: a driver is given that as
/// `machineToken`; this default only reads, and refuses a token about to run out.
export async function machineClaudeToken(env: Env): Promise<MachineToken> {
  const found = await readClaudeCredentials(env);
  if (!found) throw new Error("the machine's Claude Code login could not be read");
  if (found.expiresAt !== 0 && found.expiresAt - wall.now() <= CLAUDE_TOKEN_MARGIN_MS) {
    throw new Error("the machine's Claude Code token runs out and is not renewed here");
  }
  return found;
}

/// A machine profile's Codex home, sharing the machine's login: its auth.json the machine's file (platform.shareFile:
/// a link, or where one is refused a hard link). Made again when something replaced it (a sign-in in the home, say).
export function linkCodexAuth(home: string, env: Env) {
  mkdirSync(home, { recursive: true });
  platform.shareFile(codexAuthFile(env), join(home, "auth.json"));
}
