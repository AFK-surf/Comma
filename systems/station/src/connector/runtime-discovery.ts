// Finding agent runtimes on this machine: Cloud VM managed installs (a bounded directory page), then the one on the
// PATH. A discovered path is the runtime's identity; it is never resolved through symlinks here, so an installer that
// moves its link keeps the same target.
import { accessSync, constants, lstatSync, readdirSync, statSync } from "node:fs";
import { delimiter, dirname, isAbsolute, join, normalize } from "node:path";
import { Clock, Duration, Effect } from "effect";
import { runBounded } from "./child.ts";
import { platform } from "../platform/index.ts";

export type RuntimeTarget = { provider: string; identityMaterial: string };

export const runtimeTargetKey = (target: RuntimeTarget) => `${target.provider}\0${target.identityMaterial}`;

export const MAX_RUNTIME_TARGETS = 32;
const MANAGED_INSTALLATION_ID = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/;

type Env = Record<string, string | undefined>;

export function executable(path: string): boolean {
  try {
    const info = statSync(path);
    if (info.isDirectory()) return false;
    accessSync(path, constants.X_OK);
    return (info.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

/**
 * Cloud VM installations under SALIX_MANAGED_RUNTIME_ROOT: at most sixteen, read as one directory page. A root with
 * more publishes nothing rather than a partial inventory. Only a published entry (a link or an executable) counts.
 */
export function managedRuntimeCommands(provider: string, env: Env): string[] {
  const root = env.SALIX_MANAGED_RUNTIME_ROOT ?? "";
  if (!root || (provider !== "codex" && provider !== "claude")) return [];
  let names: string[];
  try {
    names = readdirSync(root);
  } catch {
    return [];
  }
  if (names.length > 16) return [];
  const paths: string[] = [];
  for (const name of names.sort()) {
    if (!MANAGED_INSTALLATION_ID.test(name)) continue;
    const path = join(root, name, "bin", provider);
    try {
      const info = lstatSync(path);
      if (info.isSymbolicLink() || (info.isFile() && (info.mode & 0o111) !== 0)) paths.push(path);
    } catch {
      // Not published.
    }
  }
  return paths;
}

/** `name` on PATH as a shell finds it (with PATHEXT's extensions on Windows); only an absolute find counts. */
function lookPath(name: string, env: Env): string | undefined {
  const found = platform.findCommand(name, env)?.onPath;
  return found !== undefined && isAbsolute(found) ? found : undefined;
}

/** Appends an absolute path once (by its cleaned form, never resolving links); returns `paths`. */
export function appendUniquePath(paths: string[], seen: Set<string>, path: string | undefined): string[] {
  const trimmed = path?.trim() ?? "";
  if (!trimmed || !isAbsolute(trimmed)) return paths;
  const clean = normalize(trimmed);
  if (seen.has(clean)) return paths;
  seen.add(clean);
  paths.push(clean);
  return paths;
}
/**
 * A runtime's commands: the Cloud VM managed installs, then the one the station's PATH finds. The station's chats run
 * the runtime by name on that PATH, so a copy elsewhere (an older npm global, another Homebrew prefix, an app bundle)
 * never runs and is not listed.
 */
export function detectCommands(name: string, env: Env): string[] {
  const paths: string[] = [];
  const seen = new Set<string>();
  for (const path of managedRuntimeCommands(name, env)) appendUniquePath(paths, seen, path);
  appendUniquePath(paths, seen, lookPath(name, env));
  return paths;
}

/** Every runtime target on this machine, ordered by key and bounded. */
export function discoverAgentRuntimeTargets(options: { env: Env }): RuntimeTarget[] {
  const env = options.env;
  const targets: RuntimeTarget[] = (["codex", "claude"] as const).flatMap((provider) => detectCommands(provider, env).map((identityMaterial) => ({ provider, identityMaterial })));
  targets.sort((a, b) => (runtimeTargetKey(a) < runtimeTargetKey(b) ? -1 : runtimeTargetKey(a) > runtimeTargetKey(b) ? 1 : 0));
  return targets.slice(0, MAX_RUNTIME_TARGETS);
}

/** A PATH for running `command`: its own directory first, then the usual install locations and the host PATH. */
export function runtimeCommandPath(command: string, env: Env, ...prefixes: string[]): string {
  const dirs: string[] = [];
  const seen = new Set<string>();
  const add = (dir: string) => {
    const trimmed = dir.trim();
    if (!trimmed || seen.has(trimmed)) return;
    seen.add(trimmed);
    dirs.push(trimmed);
  };
  for (const prefix of prefixes) add(prefix);
  if (isAbsolute(command)) add(dirname(command));
  if (platform.hasHomebrew) {
    add("/opt/homebrew/bin");
    add("/usr/local/bin");
  }
  for (const dir of (env.PATH ?? "").split(delimiter)) add(dir);
  return dirs.join(delimiter);
}

// Runtime readiness: the command answers `--version`, and this computer's own login of it (the one Settings asks to
// sign in) is signed in, as the runtime's status command says.

export const RUNTIME_READINESS_VALIDITY_MS = 10 * 60_000;

/** `command --version` (combined output), within five seconds. */
export function commandVersion(command: string, env: Env): Effect.Effect<{ version: string; error: Error | null }> {
  return runBounded(command, ["--version"], { env: execEnvOf(env, { PATH: runtimeCommandPath(command, env) }), timeout: Duration.seconds(5), stdoutLimit: 64 * 1024, combine: true }).pipe(
    Effect.map((run) => {
      const version = run.stdout.toString("utf8").trim();
      const failed = run.timedOut || run.exit.error !== null || run.exit.code !== 0;
      return { version, error: failed ? new Error(run.timedOut ? "signal: killed" : run.exit.error ? run.exit.error.message : `exit status ${run.exit.code}`) : null };
    }),
  );
}

function execEnvOf(host: Env, extra: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(host)) if (value !== undefined) env[key] = value;
  return Object.assign(env, extra);
}

export type RuntimeAuth = { status: "authenticated" | "unauthenticated" | "unknown"; mode?: string };

/** What points a runtime at another home or account than this computer's own login (accounts/machine.ts drops the same). */
const OTHER_LOGIN: Record<string, string[]> = {
  claude: ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"],
  codex: ["OPENAI_API_KEY", "CODEX_API_KEY"],
};

/** Whether this computer's own login of the runtime is signed in: `claude auth status`, `codex login status`. */
export function commandAuth(provider: string, command: string, env: Env): Effect.Effect<RuntimeAuth> {
  const args = provider === "claude" ? ["auth", "status"] : provider === "codex" ? ["login", "status"] : null;
  if (args === null) return Effect.succeed({ status: "unknown" });
  const machine = Object.fromEntries(Object.entries(env).filter(([key]) => !(OTHER_LOGIN[provider] ?? []).includes(key)));
  return runBounded(command, args, { env: execEnvOf(machine, { PATH: runtimeCommandPath(command, env) }), timeout: Duration.seconds(10), stdoutLimit: 64 * 1024, combine: provider === "codex" }).pipe(
    Effect.map((run): RuntimeAuth => {
      if (run.timedOut || run.exit.error !== null) return { status: "unknown" };
      const said = run.stdout.toString("utf8");
      if (provider === "claude") {
        // Signed out, it exits 1 and still prints its JSON.
        try {
          const loggedIn = JSON.parse(said)?.loggedIn;
          return loggedIn === true ? { status: "authenticated" } : loggedIn === false ? { status: "unauthenticated" } : { status: "unknown" };
        } catch {
          return { status: "unknown" };
        }
      }
      const lower = said.toLowerCase();
      if (lower.includes("not logged in")) return { status: "unauthenticated" };
      if (run.exit.code !== 0 || !lower.includes("logged in")) return { status: "unknown" };
      return { status: "authenticated", ...(lower.includes("chatgpt") ? { mode: "chatgpt" } : lower.includes("api key") ? { mode: "api_key" } : {}) };
    }),
  );
}

/** One runtime target's inventory entry: identity, whether its command answers, and whether it is signed in. */
export function runtimeObservation(target: RuntimeTarget, env: Env): Effect.Effect<Record<string, any>> {
  return Effect.gen(function* () {
    const checkedAt = yield* Clock.currentTimeMillis;
    const { version, error } = yield* commandVersion(target.identityMaterial, env);
    const answers = !error;
    const auth: RuntimeAuth = answers ? yield* commandAuth(target.provider, target.identityMaterial, env) : { status: "unknown" };
    const ready = answers && auth.status === "authenticated";
    const runtime: Record<string, any> = {
      kind: "external",
      provider: target.provider,
      command: target.identityMaterial,
      identity_material: target.identityMaterial,
      version,
      version_detected: answers,
      auth_ready: auth.status === "authenticated",
      // The station's chats start the command itself: it starts when it answers.
      native_server_startable: answers,
      ready,
      status: ready ? "available" : "unavailable",
      readiness_checked_at: checkedAt,
      readiness_valid_until: checkedAt + RUNTIME_READINESS_VALIDITY_MS,
      transports: ["station-chat"],
      auth: { schema_version: 1, status: auth.status, requires_openai_auth: false, observed_at: checkedAt, ...(auth.mode ? { mode: auth.mode } : {}) },
    };
    if (error) {
      runtime.last_error = error.message;
      runtime.readiness_issue = "runtime_probe_failed";
    } else if (auth.status === "unauthenticated") {
      runtime.readiness_issue = "authentication_required";
    } else if (auth.status === "unknown") {
      runtime.readiness_issue = "runtime_probe_failed";
      runtime.readiness_message = "Could not read whether this runtime is signed in.";
    }
    return runtime;
  });
}
