// The account pool: which of a station's profiles a session runs on, as systems/profiles pool.rs decides it for Comma's
// AccountPool too (the order is told there). A session keeps its profile while it is usable (its runtime's cache is that
// account's); its transcripts are shared by all, so when it is not, another takes it on.
// Also the reasoning levels a model offers (shapes reasoning.rs), which the pool's accounts decide.
import { type Profile, runs, sameModel } from "./config.ts";
import { profilesNative, unified } from "../agents/unified.ts";
import { wall } from "../ops/fibers.ts";

type Json = any;

/// How a profile is doing: its last check and allowance (profiles.rs ProfileCheck / ProfileQuota, camelCase JSON), and
/// whether a turn on it ran into its allowance since the allowance was last read (Hub `spend`).
export type ProfileHealth = { check?: Json | null; quota?: Json | null; spent?: boolean };

export type PoolSignals = {
  health(id: string): ProfileHealth;
  /// Sessions with a live process on this profile.
  load(id: string): number;
  /// When the pool last chose this profile (0 if never).
  lastPicked(id: string): number;
  /// Now, in milliseconds (allowances refill at times in milliseconds).
  now(): number;
};

/// How a profile's allowance ranks: whether its short windows are nearly full; whether a long window refills within a
/// day with some left; how fast it has to be spent not to lose any.
export type Urgency = { crowded: boolean; soon: boolean; pace: number };

/// What the Profiles' pool says of one profile's health (a profile of no account of its own: only its health counts).
const state = (health: ProfileHealth, now: number): { usable: boolean; urgency: Urgency } =>
  JSON.parse(profilesNative().profileState(JSON.stringify(unified({ id: "", home: "", runtime: "claude" }, health)), JSON.stringify({ spent: health.spent === true }), null, now));

/// How a profile's allowance ranks (systems/profiles pool.rs `urgency`).
export function urgency(quota: Json | null | undefined, now: number): Urgency {
  return state({ quota }, now).urgency;
}

/// Whether a profile can run now: it signs in, its key was not rejected, none of its windows is used up (and not yet
/// refilled), and no turn ran into its allowance since.
export function usable(health: ProfileHealth, now: number = wall.now()): boolean {
  return state(health, now).usable;
}

/// A chosen model needs the profile to have it enabled; no model means the profile's own default.
export const serves = (profile: Profile, model: string | null | undefined): boolean => model === null || model === undefined || runs(profile, model);

/// `strict` (a chat started by hand): the model must be enabled on a profile. Otherwise (a connect's binding, set up
/// before models were enabled) profiles with it enabled are preferred, and without any the bound ones still serve. Of
/// those, the Profiles' pool (systems/profiles pool.rs, Comma's too) decides; when nothing healthy serves it, still one
/// that has it enabled, so the failure shows in the session.
export function pickProfile(candidates: Profile[], model: string | null | undefined, signals: PoolSignals, strict: boolean): Profile {
  if (candidates.length === 0) throw new Error("no profile to run on");
  const profiles = candidates.map((p) => unified(p, signals.health(p.id)));
  const now = signals.now();
  const request = {
    model: model ?? null,
    strict,
    keep_unusable: true,
    now,
    signals: Object.fromEntries(candidates.map((p) => [p.id, { load: signals.load(p.id), last_picked: signals.lastPicked(p.id), spent: signals.health(p.id).spent === true }])),
  };
  const [first] = profilesNative().profileRank(JSON.stringify(profiles), JSON.stringify(request));
  return candidates.find((p) => p.id === first) ?? candidates[0]!;
}

// ── reasoning levels (client/core-ts/src/shapes/reasoning.ts) ──

/// Runtime-reported model capabilities: runtime → model → levels.
export type Catalog = Record<string, Record<string, string[]>>;

export function fallbackEfforts(runtime: string): string[] {
  return runtime === "codex" ? ["minimal", "low", "medium", "high", "xhigh"] : ["low", "medium", "high", "xhigh", "max"];
}

/// The levels a model offers: as its runtime reported them (an empty list: none), else the runtime's usual ones.
export function availableEfforts(runtime: string, model: string | null | undefined, catalog: Catalog | null | undefined): string[] {
  const models = catalog?.[runtime];
  if (model !== null && model !== undefined && models) {
    const levels = models[model] ?? Object.entries(models).find(([id]) => sameModel(id, model))?.[1];
    if (levels) return [...levels];
  }
  return fallbackEfforts(runtime);
}

/// The levels every one of these offers.
export function commonEfforts(profiles: string[][], runtime: string): string[] {
  const [first, ...others] = profiles;
  if (!first) return availableEfforts(runtime, null, null);
  return first.filter((level) => others.every((o) => o.includes(level)));
}
