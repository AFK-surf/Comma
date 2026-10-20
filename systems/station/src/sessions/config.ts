// What the hub reads of config.json (the Rust station's config.rs `Config`, as parse_config fills it in): profiles, connects,
// and the numbers that govern turns, warm processes and archiving. Read on every use (the hub is given a function), so
// edits apply to the next decision. A profile stays config.json's object (the drivers read its access, env, model…),
// its home made absolute and what parse_config derives added: name, runtimes, models, backgroundOnMessage.
import { isAbsolute, join } from "node:path";
import type { Profile as RuntimeProfile } from "../agents/runtime.ts";
import { profileRuntimes, type Runtime } from "../agents/profiles.ts";
import { modelKey } from "../read/usage.ts";

export type { Runtime };

export type Profile = RuntimeProfile & {
  /// Shown instead of the id.
  name: string;
  /// The runtimes it can run.
  runtimes: Runtime[];
  /// Models it may be used for, chosen by hand from what its check found (trimmed, each once).
  models: string[];
  model?: string;
  /// A message that reaches a running Claude Code turn first moves what it waits on to the background (absent: on).
  backgroundOnMessage: boolean;
};

export type ConnectMode = "multi-session" | "single-session";

export type Connect = {
  id: string;
  enabled: boolean;
  mode: ConnectMode;
  /// single-session only: whether starting on a new thread needs an @mention (multi-session: always).
  requireMention: boolean;
  slack: { botName?: string; [key: string]: unknown };
  bind: { runtime: Runtime; profile?: string; model?: string; effort?: string };
};

/// decision.rs `DecisionRule`: the completion review after all_done, and the model it asks.
export type DecisionRule = { enabled: boolean; model: string | null };

export type HubConfig = {
  dataDir: string;
  /// Shared MEMORY.md and skills/ linked into every profile home.
  agentHome: string;
  connects: Connect[];
  profiles: Profile[];
  /// How many times a turn that ended without a state is nudged before giving up.
  maxNudges: number;
  automaticDecisions: { completion: DecisionRule };
  /// Idle claude processes kept alive at most this long before they may be evicted.
  warmMs: number;
  /// Idle claude processes beyond this count are evicted, oldest first, once past warmMs.
  maxWarmClaude: number;
  /// Chats idle this long, and done (auto archive), are archived by the station; 0: never.
  autoArchiveMs: number;
};

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const nonEmpty = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const under = (dataDir: string, path: string) => (isAbsolute(path) ? path : join(dataDir, path));

/// config.json (parsed) as the hub reads it: parse_config's defaults and derivations, without its checks (the config
/// module refuses a config that does not pass them before anything reads it).
export function hubConfig(raw: any, dataDir: string): HubConfig {
  const profiles: Profile[] = (Array.isArray(raw?.profiles) ? raw.profiles : []).map((p: any): Profile => {
    const seen = new Set<string>();
    const models = (Array.isArray(p.models) ? p.models : [])
      .map((m: unknown) => String(m).trim())
      .filter((m: string) => m !== "" && !seen.has(m) && (seen.add(m), true));
    const base: RuntimeProfile = { ...p, home: under(dataDir, String(p.home ?? "")) };
    const runtimes = profileRuntimes(base);
    return {
      ...base,
      id: p.id,
      name: str(p.name)?.trim() || p.id,
      // One that runs neither runtime (a provider of chat completions only) is Claude's in name.
      runtime: runtimes[0] ?? "claude",
      runtimes,
      models,
      model: nonEmpty(p.model),
      backgroundOnMessage: p.background_on_message !== false,
    };
  });
  const connects: Connect[] = (Array.isArray(raw?.connects) ? raw.connects : []).map((c: any): Connect => {
    const mode: ConnectMode = c.mode === "single-session" ? "single-session" : "multi-session";
    const bind = c.bind ?? {};
    return {
      id: c.id,
      enabled: c.enabled !== false,
      mode,
      requireMention: mode === "multi-session" ? true : c.requireMention !== false,
      slack: { ...(c.slack ?? {}), botName: nonEmpty(c.slack?.botName) },
      bind: { runtime: bind.runtime === "codex" ? "codex" : "claude", profile: nonEmpty(bind.profile), model: nonEmpty(bind.model), effort: nonEmpty(bind.effort) },
    };
  });
  const completion = raw?.automaticDecisions?.completion ?? {};
  return {
    dataDir,
    agentHome: under(dataDir, str(raw?.agentHome) ?? "agent"),
    connects,
    profiles,
    maxNudges: typeof raw?.maxNudges === "number" ? raw.maxNudges : 2,
    automaticDecisions: { completion: { enabled: completion.enabled === true, model: str(completion.model) ?? null } },
    warmMs: Math.trunc((typeof raw?.warmMinutes === "number" ? raw.warmMinutes : 30) * 60_000),
    maxWarmClaude: typeof raw?.maxWarmClaude === "number" ? raw.maxWarmClaude : 4,
    autoArchiveMs: Math.trunc(Math.max(0, typeof raw?.autoArchiveDays === "number" ? raw.autoArchiveDays : 1) * 86_400_000),
  };
}

/// Its own spelling of a model it has enabled, however the model is spelled (gpt-6-astra here may be
/// openai/gpt-6-astra there).
export function spelling(profile: Profile, model: string): string | null {
  return profile.models.find((m) => m === model) ?? profile.models.find((m) => sameModel(m, model)) ?? null;
}

/// Whether it has a model enabled, in any spelling.
export const runs = (profile: Profile, model: string): boolean => spelling(profile, model) !== null;

/// shapes model.rs `same`: two spellings are one model.
export const sameModel = (a: string, b: string): boolean => a === b || modelKey(a) === modelKey(b);

/// The profiles a connect's sessions can run on: every profile of its runtime.
export const profilesFor = (config: HubConfig, connect: Connect): Profile[] => config.profiles.filter((p) => p.runtimes.includes(connect.bind.runtime));

export const runtimeName = (r: Runtime) => r;
export const runtimeNamed = (name: string): Runtime | null => (name === "claude" || name === "codex" ? name : null);
/// How people call a runtime.
export const runtimeTitle = (r: Runtime) => (r === "claude" ? "Claude Code" : "Codex");
