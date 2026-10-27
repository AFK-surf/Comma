// Which account a session runs on (the Rust station's hub.rs: run_on, spend, pick, health_of, model_efforts, configure): the
// pool's choice among the station's profiles, kept while usable, moved off one whose allowance ran out, and changed by
// hand (profile, model, effort, fast). How profiles are doing comes from outside (the accounts module's checks and
// allowances: `setHealth`); which ran into their allowance lately is kept here.
import type { Clock } from "effect";
import { log } from "../ops/log.ts";
import { tr, type Lang, stationLang } from "../ops/i18n.ts";
import type { Store } from "../store/store.ts";
import { type HubConfig, type Profile, type Runtime, runs, runtimeNamed, runtimeTitle, sameModel, spelling } from "./config.ts";
import { availableEfforts, commonEfforts, type ProfileHealth, pickProfile, serves, usable } from "./pool.ts";

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);

/// How long a profile a turn ran into the allowance of is passed over when its allowance is not read again.
const SPENT_FOR_MS = 60 * 60 * 1000;

/// How a session runs from its next turn on. A field left out: unchanged; null: back to the default.
export type SessionChange = { runtime?: string; profile?: string | null; model?: string | null; effort?: string | null; fast?: boolean | null };

/// A session moved to another runtime (Accounts.rerun): what it runs on from its next start.
export type Rerun = { runtime: Runtime; profile: string; pinned: boolean; model: string | null; effort: string | null; fast: boolean | null };

/// A profile as a session's runtime starts on it, with its spelling of the session's model.
export type RunOn = Profile & { spelling(model: string): string | null };

export type AccountsDeps = {
  config(): HubConfig;
  store: Store;
  /// The profiles of sessions with a process now (their load).
  running(): string[];
  /// Its time.
  clock: Clock.Clock;
  /// Of a runtime's profiles, those a session from `host` may run on (accounts/sources.ts); throws the reason when its
  /// Workspace's source allows none. All of them when not given.
  eligible?: (profiles: Profile[], runtime: Runtime, host: string | null, lang: Lang) => Profile[];
  /// The host a session takes part in a Task of (null: none), whose source it keeps to.
  hostOf?: (key: string) => string | null;
};

export class Accounts {
  private deps: AccountsDeps;
  private health: (id: string) => ProfileHealth = () => ({});
  private picked = new Map<string, number>();
  /// Profiles a turn ran into the allowance of, and when: passed over until their allowance is read again, or for
  /// SPENT_FOR_MS when it is not.
  private spent = new Map<string, number>();

  constructor(deps: AccountsDeps) {
    this.deps = deps;
  }

  /// Lets the pool see profiles' checks and allowances.
  setHealth(health: (id: string) => ProfileHealth) {
    this.health = health;
  }

  healthOf(id: string): ProfileHealth {
    const health: ProfileHealth = { ...this.health(id) };
    const at = this.spent.get(id);
    if (at !== undefined) {
      // Read again since: what it says now counts.
      const checked = health.quota?.checkedAt;
      if ((typeof checked === "number" && checked > at) || this.deps.clock.currentTimeMillisUnsafe() - at > SPENT_FOR_MS) this.spent.delete(id);
      else health.spent = true;
    }
    return health;
  }

  /// The profiles of a runtime a session from `host` may run on: only those of its Workspace's account source.
  candidates(runtime: Runtime, host: string | null, lang: Lang = stationLang()): Profile[] {
    const all = this.deps.config().profiles.filter((p) => p.runtimes.includes(runtime));
    return this.deps.eligible ? this.deps.eligible(all, runtime, host, lang) : all;
  }

  /// The profiles a session already made may run on now. When its Workspace allows none any more, the one it is on
  /// stays where it still may be used (not the machine's login once that is not in use); else it has none.
  private sessionCandidates(key: string, runtime: Runtime, current: string): Profile[] {
    const host = this.deps.hostOf?.(key) ?? null;
    try {
      return this.candidates(runtime, host);
    } catch (e) {
      const kept = this.deps.config().profiles.find((p) => p.id === current && p.runtimes.includes(runtime));
      const lentHere = isObject(kept?.share) && kept.share.borrowed === true && kept.share.host === host;
      if (kept && (lentHere || this.candidates(runtime, null).some((p) => p.id === kept.id))) return [kept];
      throw e;
    }
  }

  /// Chooses the profile a session runs on (pool.ts).
  pick(candidates: Profile[], model: string | null | undefined, strict: boolean): Profile {
    const running = this.deps.running();
    const profile = pickProfile(candidates, model, { health: (id) => this.healthOf(id), load: (id) => running.filter((p) => p === id).length, lastPicked: (id) => this.picked.get(id) ?? 0, now: () => this.deps.clock.currentTimeMillisUnsafe() }, strict);
    this.picked.set(profile.id, this.deps.clock.currentTimeMillisUnsafe());
    return profile;
  }

  /// The profile a session's runtime starts on: its own while usable (the account's cache is warm there), else the one
  /// the pool picks among those of its runtime (transcripts are shared, so it resumes with all it had there).
  runOn(key: string): RunOn {
    const { store } = this.deps;
    const row = store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    const runtime = runtimeNamed(row.runtime);
    if (!runtime) throw new Error(`session ${key} runs an unknown runtime ${row.runtime}`);
    const candidates = this.sessionCandidates(key, runtime, row.profile);
    const withSpelling = (p: Profile): RunOn => ({ ...p, spelling: (model: string) => spelling(p, model) });
    // Kept to it by hand: that one, whatever it says. Otherwise its own while it can run it: usable, and with its model
    // enabled.
    const current = candidates.find((p) => p.id === row.profile);
    if (current && (row.profilePinned || (usable(this.healthOf(current.id), this.deps.clock.currentTimeMillisUnsafe()) && serves(current, row.model)))) return withSpelling(current);
    if (candidates.length === 0) throw new Error(`session ${key}: no profile runs ${row.runtime}`);
    const next = this.pick(candidates, row.model, false);
    if (next.id !== row.profile) {
      store.setSessionProfile(key, next.id, false);
      log.info("hub", "session taken on by another profile", { session: key, from: row.profile, to: next.id });
    }
    return withSpelling(next);
  }

  /// A turn of the session ran into its profile's allowance: that profile is passed over for now, and a session left to
  /// the station moves to another of its runtime's that can run it now. The names of the one left and the one taken
  /// when it moved; null when it is kept to its profile or none other can.
  spend(key: string): [string, string] | null {
    const { store } = this.deps;
    const row = store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    this.spent.set(row.profile, this.deps.clock.currentTimeMillisUnsafe());
    if (row.profilePinned) return null;
    const runtime = runtimeNamed(row.runtime);
    if (!runtime) return null;
    const config = this.deps.config();
    // As the pool: those with its model enabled, or, when none has (a connect's binding from before models were
    // enabled), all of its runtime's.
    let all: Profile[];
    try {
      all = this.sessionCandidates(key, runtime, row.profile);
    } catch {
      return null;
    }
    const strict = all.some((p) => serves(p, row.model));
    const candidates = all.filter((p) => p.id !== row.profile && (!strict || serves(p, row.model)) && usable(this.healthOf(p.id), this.deps.clock.currentTimeMillisUnsafe()));
    if (candidates.length === 0) return null;
    const next = this.pick(candidates, row.model, false);
    store.setSessionProfile(key, next.id, false);
    log.info("hub", "allowance ran out; session taken on by another profile", { session: key, from: row.profile, to: next.id });
    const from = config.profiles.find((p) => p.id === row.profile)?.name ?? row.profile;
    return [from, next.name];
  }

  /// The reasoning levels every eligible account offers for a model (a pinned account may offer more): automatic
  /// selection must work on every one, quota failover included.
  modelEfforts(runtime: "claude" | "codex", model: string | null, pinned: string | null): string[] {
    const profiles = this.deps
      .config()
      .profiles.filter((p) => p.runtimes.includes(runtime))
      .filter((p) => pinned === null || p.id === pinned)
      .filter((p) => model === null || runs(p, model));
    return commonEfforts(
      profiles.map((p) => availableEfforts(runtime, model ?? p.model ?? null, this.healthOf(p.id).check?.modelEfforts ?? null)),
      runtime,
    );
  }

  /// Checks a change (configure) and works out what it makes of the session: its profile (and whether kept to it), its
  /// model and effort. Throws what is wrong with it, in `lang`.
  /// Checks moving a session to another runtime (configure): null when `change` names none, or the one it runs. Its
  /// model, effort and fast are as given, else the new runtime's defaults (the old ones are another runtime's); its
  /// profile the one given (kept to it), else the pool's pick among those it may run on with the model enabled.
  rerun(key: string, change: SessionChange, lang: Lang = stationLang()): Rerun | null {
    const row = this.deps.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    if (change.runtime === undefined || change.runtime === row.runtime) return null;
    const t = (k: string, args?: Record<string, unknown>) => tr(lang, k, args);
    const runtime = runtimeNamed(change.runtime);
    if (!runtime) throw new Error(`unknown runtime ${change.runtime}`);
    const name = runtimeTitle(runtime);
    const nonEmpty = (v: string | null | undefined) => (v === undefined || v === null || v === "" ? null : v);
    const model = nonEmpty(change.model);
    const wanted = nonEmpty(change.profile);
    const effort = nonEmpty(change.effort);
    if (change.fast !== undefined && change.fast !== null && runtime !== "codex") throw new Error(t("station.session.fastOpenAiOnly"));
    const candidates = this.candidates(runtime, this.deps.hostOf?.(key) ?? null, lang);
    if (candidates.length === 0) throw new Error(t("station.session.noProfile", { runtime: name }));
    let profile: Profile;
    if (wanted !== null) {
      const next = candidates.find((p) => p.id === wanted);
      if (!next) throw new Error(t("station.source.profileOutside", { profile: wanted }));
      if (model !== null && !runs(next, model)) throw new Error(t("station.session.modelOff", { profile: next.name, model }));
      profile = next;
    } else {
      if (model !== null && !candidates.some((p) => runs(p, model))) throw new Error(t("station.session.noProfileForModel", { model, runtime: name }));
      profile = this.pick(candidates, model, true);
    }
    if (effort !== null) {
      const allowed = this.modelEfforts(runtime, model, wanted);
      if (!allowed.includes(effort)) throw new Error(t("station.profile.efforts", { runtime: name, efforts: allowed.join(t("station.list.separator")) }));
    }
    return { runtime, profile: profile.id, pinned: wanted !== null, model: model ?? profile.model ?? null, effort, fast: runtime === "codex" ? (change.fast ?? null) : null };
  }

  change(key: string, change: SessionChange, lang: Lang = stationLang()) {
    const { store } = this.deps;
    const t = (k: string, args?: Record<string, unknown>) => tr(lang, k, args);
    const row = store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    const runtime = runtimeNamed(row.runtime);
    if (!runtime) throw new Error(`session ${key} runs an unknown runtime ${row.runtime}`);
    const name = runtimeTitle(runtime);
    const config = this.deps.config();
    const nonEmpty = (v: string | null | undefined) => (v === undefined ? undefined : v === null || v === "" ? null : v);
    // A profile given keeps the session to it; null gives the choice back to the station.
    const wantedProfile = nonEmpty(change.profile);
    const newModel = nonEmpty(change.model);
    const newEffort = nonEmpty(change.effort);
    if (change.fast !== undefined && change.fast !== null && runtime !== "codex") throw new Error(t("station.session.fastOpenAiOnly"));
    if (typeof wantedProfile === "string") {
      const next = config.profiles.find((p) => p.id === wantedProfile);
      if (!next) throw new Error(`unknown profile ${wantedProfile}`);
      if (!next.runtimes.includes(runtime)) throw new Error(t("station.profile.cannotRun", { profile: next.name, runtime: name }));
      if (!this.candidates(runtime, this.deps.hostOf?.(key) ?? null, lang).some((p) => p.id === next.id)) throw new Error(t("station.source.profileOutside", { profile: next.name }));
      const model = newModel !== undefined ? newModel : row.model;
      if (model !== null && !runs(next, model)) throw new Error(t("station.session.modelOff", { profile: next.name, model }));
    }
    let model = newModel !== undefined ? newModel : row.model;
    // Another spelling of its model is its model.
    const remodel = model !== null && row.model !== null ? !sameModel(model, row.model) : model !== row.model;
    if (!remodel) model = row.model;
    const effort = newEffort !== undefined ? newEffort : remodel ? null : row.effort;
    // What changes is checked; what stays is as it was.
    if (typeof newModel === "string" && model !== null && !config.profiles.some((p) => p.runtimes.includes(runtime) && runs(p, model!))) {
      throw new Error(t("station.session.noProfileForModel", { model, runtime: name }));
    }
    if (effort !== null && (newEffort !== undefined || wantedProfile !== undefined || remodel)) {
      const pinned = wantedProfile !== undefined ? wantedProfile : !remodel && row.profilePinned ? row.profile : null;
      const allowed = this.modelEfforts(runtime, model, pinned);
      if (!allowed.includes(effort)) throw new Error(t("station.profile.efforts", { runtime: name, efforts: allowed.join(t("station.list.separator")) }));
    }
    const profile = wantedProfile !== undefined ? wantedProfile : remodel ? null : undefined;
    return { row, model, effort, profile };
  }
}
