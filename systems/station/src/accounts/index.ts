// The station's accounts (docs/station-ts.md `accounts`): its profiles as the pages edit them, their checks and
// allowances, sign-ins, profiles on the machine's own login, the machine login's renewed token, and the models the
// automatic decisions may use (the Rust station's admin/edits.rs and decision.rs, the profile parts of admin/mod.rs and
// views.rs, and what server.rs wires for them).
//
// What changes is pushed: `onChange` hears each change the overview shows (a check, an allowance, a sign-in, the
// machine's logins); config.json's own changes are the ConfigFile's to tell. Kept on a timer only where nothing says
// when it changed:
// - allowances: every 5 minutes, and only while someone follows the events (`following`), as admin/events.rs does; the
//   providers do not tell when an allowance moves. `followed()` asks the stale ones at once when the first follower comes.
// - every profile checked 3 s after start (what changed while the station was off: keys revoked, logins expired).
// - the machine's logins: read again when the overview is read with a reading over 2 minutes old (machine.ts), and only
//   those of runtimes some Workspace chose the local sign-in for (sources.ts): nothing of them is read, checked, asked
//   or used otherwise.
// - a sign-in times out after 15 minutes; a finished sign-in for a new profile is kept 15 minutes for its page.
import type { Clock } from "effect";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { Env, MachineToken } from "../agents/machine-logins.ts";
import { linkCodexAuth } from "../agents/machine-logins.ts";
import { type AccessKind, accessKind, accessOf, isMachine, keyOf, profileVia, type Runtime, storedAccess, type Via } from "../agents/profiles.ts";
import { cleanEndpoint, endpoints, find, groupOf, LEGACY, runtimesOf as runtimesOfEndpoints, SOURCES } from "../agents/providers.ts";
import type { Viewer } from "../mesh/credential.ts";
import type { ConfigFile } from "../ops/config.ts";
import { ownerOf } from "../device/access.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { joinPath } from "../ops/paths.ts";
import { hubConfig, type Profile } from "../sessions/config.ts";
import { type Capability, discover as discoverDecisions, fingerprint, resolvedModel } from "../sessions/decision.ts";
import { type ProfileHealth, serves, usable } from "../sessions/pool.ts";
import type { Store } from "../store/store.ts";
import { modelKey } from "../read/usage.ts";
import { titleOf } from "../read/views.ts";
import { currentPolicy, LEGACY_OPTIONS, savePolicy } from "../sessions/archive-policy.ts";
import { Fibers } from "../ops/fibers.ts";
import { checkAutomaticDecisions } from "./check.ts";
import { type LoginCommands, type LoginJob, LoginManager } from "./login.ts";
import { codexClaims, type MachineLogin, MachineLogins } from "./machine.ts";
import { claudeOAuthToken } from "./oauth.ts";
import { accessKinds, checkProfile, keyed, loginCommand, needsKey, type ProfileCheck, type ProfileQuota, runtimesFor, runtimesOf, URLS, type Urls } from "./profiles.ts";
import { checkQuota, machineUsage } from "./quota.ts";
import { AccountSources, localModelId, RUNTIMES, type Source, sourceOf } from "./sources.ts";

export { checkConfig } from "./check.ts";
export type { LoginJob, MachineLogin, ProfileCheck, ProfileQuota };

type Json = any;

/// How often allowances are asked again while someone follows.
const QUOTA_EVERY_MS = 5 * 60_000;
const CHECK_ON_START_MS = 3_000;
const PENDING_KEPT_MS = 15 * 60_000;
/// The login job id of a machine sign-in, before its runtime.
const MACHINE_LOGIN = "machine-login-";
/// Who the local admin interface's choices are recorded as: the person at this computer (local-admin.ts).
export const LOCAL_ADMIN = "local-admin";
/// The checks the policy page counts: of the last days, and the chats it names for each option at most.
const POLICY_DAYS = 7;
const POLICY_CHATS = 20;

/// What the pages are refused, and with which status (admin/mod.rs `http_error`).
export class Refusal extends Error {
  readonly status: number;
  /// What a caller tells apart, where it needs to (the local admin interface's `error`).
  readonly code: string | undefined;
  constructor(status: number, message: string, code?: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/// What a check is asked: the account and where it signs in (its home, or a trial one for a key being tried).
export type CheckRequest = { runtime: Runtime; kind: AccessKind; key: string; via: Via; home: string; machine: boolean };

/// The profile's codex app-server, for what only it says (the agents' CodexDriver: rateLimits, resetQuota, models).
export type CodexAccess = {
  rateLimits(profile: Profile): Promise<Json>;
  resetQuota(profile: Profile, key: string): Promise<Json>;
  models(profile: Profile): Promise<{ models: string[]; efforts: Map<string, string[]> }>;
};

export type AccountsDeps = {
  data: string;
  store: Store;
  config: ConfigFile;
  /// The hub, whose account pool picks profiles by their checks and allowances (and knows which ran out lately).
  /// Starts reviewing the done chats no decision has answered (review.ts): how many, or null without a usable model.
  reviewUndecided?: () => number | null;
  hub?: { accounts: { setHealth(health: (id: string) => ProfileHealth): void; healthOf(id: string): ProfileHealth } };
  /// The codex driver, once there.
  codex?: () => CodexAccess | undefined;
  /// Whether someone follows the events (allowances are asked again on a round only then).
  following?: () => boolean;
  /// The station's environment (where the machine's logins are, and the CLIs found); process.env by default.
  env?: Env;
  /// A Compute Workload's station, which runs on the accounts Salix lends only (accounts/sources.ts).
  managed?: boolean;
  loginCommands?: LoginCommands;
  urls?: Urls;
  /// Tests: how a profile is checked, its allowance read (null: nobody can ask), its reset asked, its decisions found.
  check?: (request: CheckRequest, lang: Lang) => Promise<ProfileCheck>;
  quota?: ((profile: Profile) => Promise<ProfileQuota>) | null;
  resetQuota?: ((profile: Profile, key: string) => Promise<Json>) | null;
  discover?: (profile: Profile, check: ProfileCheck) => Promise<Capability>;
  /// The machine's logins (null: none to read); read in `env` with their allowances by default.
  machine?: MachineLogins | null;
  /// Check every profile shortly after start (the real station; tests leave it off).
  checkOnStart?: boolean;
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
  /// Which account each Workspace's runtimes run on (made from `config` when not given).
  sources?: AccountSources;
  /// The Workspace the station enrolled in (cloud.json), whose source the machine-account routes set; null: none.
  workspace?: () => string | null;
  /// Profiles other stations share with this one (share/index.ts): how they are doing is their host's to say, and
  /// what the overview says of each profile's sharing.
  shared?: {
    status(profile: Profile): Promise<{ check: Json; quota: Json }>;
    view(profile: Json): Json | null;
    /// Whether the station the profile is another's of did not answer lately.
    hostName?(profile: Json): string | null;
  };
};

/// A sign-in with no profile yet: its runtime, its home while signing in, who started it, what it made.
type Pending = { runtime: Runtime; home: string; by: Viewer; created: string | null; error: string | null };

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
const manages = (viewer: Viewer) => viewer.role === "owner" || viewer.role === "admin";
const runtimeOf = (v: unknown): Runtime | undefined => (v === "claude" || v === "codex" ? v : undefined);
const ACCESS_KINDS: AccessKind[] = ["subscription", "opencode-go", "anthropic-api", "env", "api-provider"];
const accessKindOf = (v: unknown): AccessKind | undefined => (ACCESS_KINDS.includes(v as AccessKind) ? (v as AccessKind) : undefined);
/// admin/mod.rs Input::text: JavaScript's String(x ?? "").
const text = (v: unknown) => (v === undefined || v === null ? "" : typeof v === "string" ? v : JSON.stringify(v));
const named = (runtime: Runtime) => (runtime === "claude" ? "Claude Code" : "Codex");
/// A model server's address as a runtime is pointed at it: Anthropic's protocol at its root (the runtime adds `/v1`),
/// Responses under `/v1` (added when the address has no path). Undefined unless it is an http(s) address.
function serverAddress(given: string, protocol: "anthropic" | "responses"): string | undefined {
  const clean = cleanEndpoint(given);
  if (clean === undefined) return undefined;
  if (protocol === "anthropic") return clean.endsWith("/v1") ? clean.slice(0, -"/v1".length) : clean;
  let path: string;
  try {
    path = new URL(clean).pathname;
  } catch {
    return undefined;
  }
  return path === "" || path === "/" ? `${clean}/v1` : clean;
}
/// A copy of a profile another station shares (share/index.ts): edited, checked and signed in only there.
export const borrowed = (p: Json): boolean => isObject(p?.share) && p.share.borrowed === true;

export class Accounts {
  readonly logins: LoginManager;
  readonly machine: MachineLogins | null;
  readonly sources: AccountSources;
  private checks = new Map<string, ProfileCheck>();
  private quotas = new Map<string, ProfileQuota>();
  private quotaBusy = new Map<string, Promise<void>>();
  private pending = new Map<string, Pending>();
  /// Sign-ins of the machine's own logins (`POST /machine-logins`), by runtime: who asked, and why it was not taken up.
  private machineSignIns = new Map<Runtime, { by: string; error: string | null }>();
  private listeners = new Set<() => void>();
  private background: Fibers;
  private stops: (() => void)[] = [];
  private readonly env: Env;
  private readonly urls: Urls;
  private readonly checkFn: (request: CheckRequest, lang: Lang) => Promise<ProfileCheck>;
  private readonly quotaFn: ((profile: Profile) => Promise<ProfileQuota>) | null;
  private readonly resetFn: ((profile: Profile, key: string) => Promise<Json>) | null;
  private readonly discoverFn: (profile: Profile, check: ProfileCheck) => Promise<Capability>;

  private deps: AccountsDeps;

  constructor(deps: AccountsDeps) {
    this.deps = deps;
    this.background = new Fibers("accounts", deps.clock);
    this.env = deps.env ?? (process.env as Env);
    this.urls = deps.urls ?? URLS;
    this.logins = new LoginManager(deps.data, deps.loginCommands, undefined, deps.clock);
    this.sources = deps.sources ?? new AccountSources({ config: deps.config, data: deps.data, now: () => this.background.now(), managed: deps.managed });
    this.machine =
      deps.machine !== undefined ? deps.machine : new MachineLogins(this.env, (runtime, env) => this.profiles().some((p) => isMachine(p) && p.runtime === runtime) ? machineUsage(runtime, env, this.urls) : Promise.resolve(null), undefined, deps.clock);
    this.machine?.allow((runtime) => this.machineAllowed(runtime));
    this.checkFn =
      deps.check ?? ((request, lang) => checkProfile({ ...request, env: this.env, machineToken: (env) => this.machineToken(env), urls: this.urls, lang }));
    this.quotaFn =
      deps.quota !== undefined
        ? deps.quota
        : (profile) => {
            const codex = deps.codex?.();
            return checkQuota(profile, this.env, codex ? (p) => codex.rateLimits(p) : undefined, this.urls);
          };
    this.resetFn =
      deps.resetQuota !== undefined
        ? deps.resetQuota
        : (profile, key) => {
            const codex = deps.codex?.();
            if (!codex) throw new Refusal(503, tr(stationLang(), "station.quota.resetUnsupported"));
            return codex.resetQuota(profile, key);
          };
    this.discoverFn = deps.discover ?? ((profile, check) => discoverDecisions(profile, check, this.background.clock));
    // What the last run learned about profiles shows until they are checked again.
    for (const [id, status] of deps.store.profileStatus()) {
      if (isObject(status.check)) this.checks.set(id, status.check as ProfileCheck);
      if (isObject(status.quota)) this.quotas.set(id, status.quota as ProfileQuota);
    }
  }

  /// Starts what runs on its own: the pool told of profiles' health, sign-ins followed, the checks after start, the
  /// allowance rounds, the machine's logins read.
  start() {
    this.deps.hub?.accounts.setHealth((id) => this.health(id));
    // A finished sign-in changes what the profile can do; it is checked again right away.
    this.stops.push(
      this.logins.changes((id) => {
        if (id.startsWith(MACHINE_LOGIN)) {
          this.machineSignInChanged(id.slice(MACHINE_LOGIN.length) as Runtime);
          return this.changed();
        }
        const pending = this.pending.has(id);
        if (pending) this.pendingChanged(id);
        this.changed();
        if (!pending && this.logins.get(id)?.state === "done") this.afterSignIn(id);
      }),
    );
    if (this.machine) {
      this.stops.push(this.machine.changes(() => this.changed()));
      if (RUNTIMES.some((r) => this.machineAllowed(r))) this.background.spawn(() => this.machine!.refresh());
    }
    if (this.deps.checkOnStart !== false) {
      this.background.after(CHECK_ON_START_MS, () => {
        for (const p of this.profiles()) if (this.inUse(p)) this.background.spawn(() => this.check(p.id));
      });
    }
    this.background.every(QUOTA_EVERY_MS, () => {
      if (this.deps.following?.() === true) this.refreshQuotas(false);
    });
  }

  async close() {
    for (const stop of this.stops.splice(0)) stop();
    await this.logins.close();
    await this.background.close();
  }

  /// Hears each change the overview shows of the accounts; gives the function that stops it.
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed() {
    for (const listener of this.listeners) {
      try {
        listener();
      } catch (e) {
        log.warn("accounts", "an accounts listener failed", { error: (e as Error).message });
      }
    }
  }

  /// The profiles as the config has them now (parse_config's derivations).
  profiles(): Profile[] {
    return hubConfig(this.deps.config.raw(), this.deps.data).profiles;
  }

  private profile(id: string): Profile | undefined {
    return this.profiles().find((p) => p.id === id);
  }

  /// Whether the machine's own login of a runtime may be read and used: some Workspace chose the local sign-in for it.
  machineAllowed(runtime: Runtime): boolean {
    return this.sources.localActive(runtime);
  }

  /// Whether a profile may be checked, asked about and used: one on the machine's login only while that is allowed.
  private inUse(p: Profile): boolean {
    return !isMachine(p) || this.machineAllowed(p.runtime);
  }

  /// How a profile is doing, for the pool: its last check and allowance.
  health(id: string): ProfileHealth {
    return { check: this.checks.get(id) ?? null, quota: this.quotas.get(id) ?? null };
  }

  /// The machine login's current Claude token, renewed when about to run out (the Claude driver's `machineToken`).
  async machineToken(env: Env = this.env): Promise<MachineToken> {
    if (!this.machineAllowed("claude")) throw new Refusal(409, tr(stationLang(), "station.source.machineOff"));
    const [token, expiresAt] = await claudeOAuthToken(env, null, null, this.urls.claudeToken);
    return { token, expiresAt };
  }

  /// A Claude profile's current token, renewed when about to run out: what a station sharing it lends.
  async claudeToken(profile: Json): Promise<MachineToken> {
    if (profile.credential === "machine") return this.machineToken();
    const home = String(profile.home ?? "");
    const [token, expiresAt] = await claudeOAuthToken(this.env, joinPath(this.deps.data, home), null, this.urls.claudeToken);
    return { token, expiresAt };
  }

  /// Refused for a copy of another station's profile: it is changed there.
  private own(id: string, lang: Lang) {
    const p = (Array.isArray(this.deps.config.raw()?.profiles) ? this.deps.config.raw().profiles : []).find((x: Json) => x?.id === id);
    if (p && borrowed(p)) throw new Refusal(409, tr(lang, "station.share.borrowedEdit"));
  }

  private machineOwner(viewer: Viewer) {
    const owner = ownerOf(this.deps.config.raw());
    if (owner !== null ? viewer.sub !== owner : !manages(viewer))
      throw new Refusal(403, "Only this computer's owner can change its machine accounts.");
  }

  // ── edits ──

  /// Edits config.json (refused as 400 when the result does not pass), said in the log as `what`.
  private save(by: Viewer | string, what: string, edit: (raw: Json) => void) {
    try {
      this.deps.config.update(edit);
    } catch (e) {
      throw new Refusal(400, (e as Error).message);
    }
    log.info("accounts", "config changed from the admin page", { what, by: typeof by === "string" ? by : by.email });
  }

  /// PUT /profiles/:id: a profile made or edited. Its new state is checked after (in the background).
  putProfile(id: string, given: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()) {
    this.own(id, lang);
    if (this.profile(id) && isMachine(this.profile(id)!)) this.machineOwner(viewer);
    this.save(viewer, `profile ${id}`, (raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const existing: Json | undefined = list.find((p) => p?.id === id);
      const machine = existing?.credential === "machine";
      // One on the machine's login is the machine's: only which of its models are used, and how it runs, are chosen.
      const get = (key: string): unknown => (machine && !["model", "models", "backgroundOnMessage", "fast"].includes(key) ? undefined : given[key]);
      // env: a string sets the value; null removes the key; an omitted key keeps it (so masked secrets survive edits).
      const env: Record<string, string> = isObject(existing?.env) ? { ...existing.env } : {};
      const givenEnv = get("env");
      if (isObject(givenEnv)) {
        for (const [key, value] of Object.entries(givenEnv)) {
          if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`invalid environment variable name ${key}`);
          if (value === null) delete env[key];
          else if (typeof value === "string") env[key] = value;
        }
      }
      const access = get("access");
      const oldAccess = existing ? accessOf(existing) : undefined;
      const kind = accessKindOf(isObject(access) ? access.kind : undefined) ?? accessKindOf(oldAccess?.kind);
      const givenKey = isObject(access) && typeof access.key === "string" && access.key.trim() !== "" ? access.key.trim() : undefined;
      const keep = oldAccess !== undefined && oldAccess.kind === kind ? oldAccess : undefined;
      const key: string | undefined = givenKey ?? (typeof keep?.key === "string" ? keep.key : undefined);
      // An API provider stays the one it was made for; its address can be changed.
      const provider: string | undefined = typeof keep?.provider === "string" ? keep.provider : undefined;
      let endpoint: string | undefined = typeof keep?.endpoint === "string" ? keep.endpoint : undefined;
      if (isObject(access) && typeof access.endpoint === "string") {
        endpoint = cleanEndpoint(access.endpoint);
        if (endpoint === undefined) throw new Refusal(400, tr(lang, "station.profile.addressNeeded"));
      }
      const protocol: string | undefined = typeof keep?.protocol === "string" ? keep.protocol : undefined;
      const givenName = get("name");
      const name = typeof givenName === "string" ? givenName.trim() : typeof existing?.name === "string" ? existing.name : undefined;
      const givenModel = get("model");
      let model = typeof givenModel === "string" ? givenModel.trim() : givenModel !== undefined ? undefined : typeof existing?.model === "string" ? existing.model : undefined;
      if (model === "") model = undefined;
      const givenModels = get("models");
      let models: string[] | undefined;
      if (Array.isArray(givenModels)) {
        const seen = new Set<string>();
        models = givenModels
          .map((m) => (typeof m === "string" ? m : JSON.stringify(m)).trim())
          .filter((m) => m !== "" && !seen.has(m) && (seen.add(m), true))
          .slice(0, 200);
      } else if (givenModels === undefined && Array.isArray(existing?.models)) {
        models = [...existing.models];
      }
      if (models !== undefined && models.length === 0) models = undefined;
      // One model named by hand (a provider that does not list its models): added to those enabled.
      const added = get("addModel");
      if (typeof added === "string" && added.trim() !== "") {
        const one = added.trim();
        models ??= [];
        if (!models.includes(one)) models.push([...one].slice(0, 200).join(""));
      }
      const givenFast = get("fast");
      let fast: boolean | undefined;
      if (typeof givenFast === "boolean") fast = givenFast;
      else if (givenFast !== undefined) throw new Refusal(400, "fast must be a boolean");
      else fast = typeof existing?.fast === "boolean" ? existing.fast : undefined;
      const givenBackground = get("backgroundOnMessage");
      const background = typeof givenBackground === "boolean" ? givenBackground : typeof existing?.background_on_message === "boolean" ? existing.background_on_message : undefined;
      const givenHome = get("home");
      const home = typeof givenHome === "string" && givenHome.trim() !== "" ? givenHome.trim() : typeof existing?.home === "string" ? existing.home : `homes/${id}`;
      const api = kind === "api-provider";
      const next: Json = { id };
      if (name !== undefined && name !== "") next.name = name;
      const runtime = runtimeOf(get("runtime")) ?? runtimeOf(existing?.runtime);
      if (runtime !== undefined) next.runtime = runtime;
      if (kind !== undefined) Object.assign(next, storedAccess(runtime, kind, { key, ...(api ? { provider, endpoint, protocol } : {}) }, machine));
      next.home = home;
      next.env = env;
      if (model !== undefined) next.model = model;
      if (models !== undefined) next.models = models;
      // Shared with other stations: still (share/index.ts keeps this).
      if (isObject(existing?.share)) next.share = existing.share;
      // Only the default's opposite is written.
      if (background === false) next.background_on_message = false;
      if (fast === true) next.fast = true;
      if (existing) {
        const kept = runtimesFor(next);
        for (const r of runtimesFor(existing)) if (!kept.includes(r)) lastOfRuntime(raw, r, id, lang);
      }
      raw.profiles = list;
      const at = list.findIndex((p) => p?.id === id);
      if (at >= 0) list[at] = next;
      else list.push(next);
    });
  }

  /// DELETE /profiles/:id. Its home stays.
  deleteProfile(id: string, viewer: Viewer, lang: Lang = stationLang()) {
    this.own(id, lang);
    if (this.profile(id) && isMachine(this.profile(id)!)) this.machineOwner(viewer);
    this.save(viewer, `delete profile ${id}`, (raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const profile = list.find((p) => p?.id === id);
      if (!profile) throw new Error(`unknown profile ${id}`);
      for (const r of runtimesFor(profile)) lastOfRuntime(raw, r, id, lang);
      raw.profiles = list.filter((p) => p?.id !== id);
    });
  }

  /// POST /profiles: a new keyed profile, made only once its key is checked and works. Its id.
  async newKeyedProfile(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<string> {
    const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
    const access = isObject(input.access) ? input.access : undefined;
    const kind = accessKindOf(access?.kind);
    if (kind === undefined) throw new Refusal(400, `unknown access ${access?.kind === undefined ? "" : JSON.stringify(access.kind)}`);
    if (kind === "subscription") throw new Refusal(400, t("station.profile.subscriptionBySignIn"));
    const field = (k: string) => (typeof access?.[k] === "string" && access[k].trim() !== "" ? (access[k].trim() as string) : undefined);
    const [provider, givenEndpoint, givenProtocol] = [field("provider"), field("endpoint"), field("protocol")];
    // An API provider is the one named, at the address given where the provider has none of its own; the two kinds
    // that came before the list are added as they were.
    let source = undefined as ReturnType<typeof find>;
    if (kind === "api-provider") {
      source = provider !== undefined && !(provider in LEGACY) ? find(provider) : undefined;
      if (!source) throw new Refusal(400, t("station.profile.unknownProvider"));
      const chosen = source.endpointRequired ? (givenProtocol ?? (source.protocols.length === 1 ? source.protocols[0] : undefined)) : undefined;
      if (endpoints(source, givenEndpoint, chosen) === undefined) throw new Refusal(400, t("station.profile.addressNeeded"));
    }
    const endpoint = source && givenEndpoint !== undefined ? cleanEndpoint(givenEndpoint) : undefined;
    // Of one at the reader's own address: the protocol it speaks there (the one chosen, else its first).
    const protocol = source?.endpointRequired ? (source.protocols.find((p) => p === givenProtocol) ?? source.protocols[0]) : undefined;
    // A key runs every runtime it can; custom variables are for the runtime given.
    const runtimes: Runtime[] = source ? runtimesOfEndpoints(endpoints(source, endpoint, protocol) ?? {}) : runtimesOf(kind, runtimeOf(input.runtime));
    if ((runtimes.length === 0 && !source) || !runtimes.every((r) => accessKinds(r).includes(kind))) throw new Refusal(400, `unknown access ${kind}`);
    const runtime = runtimes[0] ?? "claude";
    const key = typeof access?.key === "string" ? access.key.trim() : "";
    if (needsKey(kind, source?.id) && key === "") throw new Refusal(400, t("station.profile.keyRequired"));
    const homes = join(this.deps.data, "homes");
    const trial = join(homes, `new-${randomBytes(4).toString("hex")}`);
    mkdirSync(trial, { recursive: true });
    const check = await this.checkFn({ runtime, kind, key, via: { provider: source?.id, endpoint, protocol }, home: trial, machine: false }, lang);
    // A provider with no model list leaves its key unchecked (state unknown); a refused key is what stops it.
    const refused = source ? check.state === "failed" : check.state !== "ok" && keyed(kind);
    if (refused) {
      rmSync(trial, { recursive: true, force: true });
      throw new Refusal(400, t("station.profile.checkFailed", { detail: check.detail }));
    }
    const label = source
      ? source.name
      : kind === "opencode-go"
        ? "OpenCode Go"
        : kind === "anthropic-api"
          ? "Anthropic API"
          : t("station.profile.envName", { runtime: named(runtime) });
    const base = source ? source.id : kind === "env" ? `${runtime}-env` : kind;
    const id = unique(base, this.takenIds());
    renameSync(trial, join(homes, id));
    this.save(viewer, `profile ${id}`, (raw) => {
      const made: Json = { id, name: label };
      if (kind === "env") made.runtime = runtime;
      Object.assign(made, storedAccess(runtime, kind, { key, provider: source?.id, endpoint, protocol }), { home: `homes/${id}`, env: {} });
      raw.profiles = [...(Array.isArray(raw.profiles) ? raw.profiles : []), made];
    });
    this.keepCheck(id, check);
    // What the automatic decisions can use is found once the profile is made: a request to add does not wait on that.
    const profile = this.profile(id);
    if (profile) {
      this.background.spawn(async () => {
        const decision = await this.discoverFn(profile, check);
        // A profile edited or removed meanwhile does not inherit what was found for the one it was.
        const now = this.profile(id);
        if (!now || fingerprint(now) !== fingerprint(profile)) return;
        this.keepCheck(id, { ...check, decision });
      });
    }
    return id;
  }

  /// POST /profiles/machine: a profile on the machine's own login of a runtime, when that login is one a profile can
  /// use (kept in a file). Named by its account. Its id.
  async newMachineProfile(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<string> {
    this.machineOwner(viewer);
    const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
    const runtime = runtimeOf(input.runtime);
    if (!runtime) throw new Refusal(400, `unknown runtime ${text(input.runtime)}`);
    const id = `machine-${runtime}`;
    // Asking for it is choosing the local sign-in for the station's Workspace: one kept from before is used again.
    const wasAllowed = this.machineAllowed(runtime);
    this.chooseLocal(runtime, viewer.email, lang);
    if (this.profiles().some((p) => p.id === id)) {
      if (wasAllowed) throw new Refusal(409, t("station.machine.alreadyUsed"));
      this.afterSignIn(id);
      return id;
    }
    const machine = this.machine;
    if (!machine) throw new Refusal(400, t("station.machine.unreadable"));
    await machine.refresh();
    const login = machine.get().find((l) => l.runtime === runtime);
    if (!login?.loggedIn) throw new Refusal(400, t("station.machine.notSignedIn", { runtime: named(runtime) }));
    if (!login.usable) throw new Refusal(400, t("station.machine.keychain"));
    this.machineOwner(viewer);
    if (this.profile(id)) throw new Refusal(409, t("station.machine.alreadyUsed"));
    this.saveMachineProfile(login, viewer.email, lang);
    this.afterSignIn(id);
    return id;
  }

  /// POST /machine-logins: the machine's own Codex or Claude Code signed in, by the person on this computer (the
  /// desktop app's station): its login command opens the authorization page in their browser. Once it succeeds, the
  /// machine's login is used (the `machine-<runtime>` profile), as the person asked by signing in from here.
  async newMachineLogin(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<LoginJob> {
    this.machineOwner(viewer);
    const runtime = runtimeOf(input.runtime);
    if (!runtime) throw new Refusal(400, `unknown runtime ${text(input.runtime)}`);
    this.chooseLocal(runtime, viewer.email, lang);
    return this.startMachineSignIn(runtime, viewer.email, lang);
  }

  /// The machine's login of a runtime signed in by its own login command (in the person's browser).
  private startMachineSignIn(runtime: Runtime, by: string, lang: Lang): Promise<LoginJob> {
    const home = platform.home(this.env);
    if (!home) throw new Refusal(400, tr(lang, "station.machine.unreadable"));
    this.machineSignIns.set(runtime, { by, error: null });
    log.info("accounts", "machine sign-in started", { runtime, by });
    return this.logins.start({ id: `${MACHINE_LOGIN}${runtime}`, runtime, home, machine: true }, lang);
  }

  /// The machine-account routes (over the mesh, of an enrolled station): the local sign-in chosen for its Workspace.
  private chooseLocal(runtime: Runtime, by: string, lang: Lang) {
    if (this.machineAllowed(runtime)) return;
    const workspace = this.deps.workspace?.() ?? null;
    if (workspace === null) throw new Refusal(409, tr(lang, "station.source.noWorkspace"));
    this.setSource(workspace, runtime, "local", by, false);
  }

  /// A Workspace's source of a runtime recorded; the machine's login read once it is in use (and made its profile,
  /// `takeUp`), and no sign-in of it left running once it is not.
  private setSource(workspace: string, runtime: Runtime, source: Source, by: string, takeUp: boolean) {
    try {
      this.sources.set(workspace, runtime, source, by);
    } catch (e) {
      throw new Refusal(400, (e as Error).message);
    }
    log.info("accounts", "account source chosen", { workspace, runtime, source, by });
    if (this.machineAllowed(runtime)) {
      if (takeUp) {
        this.background.spawn(async () => {
          await this.machine?.refreshNew();
          this.takeUpMachine(runtime);
        });
      }
    } else if (this.machineSignIns.has(runtime)) {
      this.logins.cancel(`${MACHINE_LOGIN}${runtime}`);
      this.machineSignIns.delete(runtime);
    }
    this.changed();
  }

  /// The machine's login of each runtime in use, signed in and kept in a file, made the `machine-<runtime>` profile
  /// when there is none: choosing the local sign-in is what asks for it.
  private takeUpMachine(runtime: Runtime) {
    const login = this.machine?.get().find((l) => l.runtime === runtime);
    const id = `machine-${runtime}`;
    if (!login?.loggedIn || !login.usable || this.profile(id)) return;
    this.saveMachineProfile(login, this.machineSignIns.get(runtime)?.by ?? LOCAL_ADMIN, stationLang());
    this.afterSignIn(id);
  }

  /// A machine sign-in moved on: once it succeeds, the machine's login is read again and used.
  private machineSignInChanged(runtime: Runtime) {
    const asked = this.machineSignIns.get(runtime);
    if (!asked || this.logins.get(`${MACHINE_LOGIN}${runtime}`)?.state !== "done") return;
    this.background.spawn(async () => {
      const lang = stationLang();
      const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
      await this.machine?.refreshNew();
      const login = this.machine?.get().find((l) => l.runtime === runtime);
      const id = `machine-${runtime}`;
      const error = !login?.loggedIn
        ? t("station.machine.notSignedIn", { runtime: named(runtime) })
        : !login.usable
          ? t("station.machine.keychain")
          : null;
      this.machineSignIns.set(runtime, { by: asked.by, error });
      if (error === null && !this.profile(id)) {
        this.saveMachineProfile(login!, asked.by, lang);
        this.afterSignIn(id);
      }
      this.changed();
    });
  }

  // ── the local admin interface (local-admin.ts, RFC43 §3.3) ──

  /// GET /local/accounts: each Workspace this computer is connected to (or chose a source for), each runtime's source,
  /// whether the Workspace lent it accounts, and, only under `local`, the machine's own login.
  async localAccounts(lang: Lang = stationLang()): Promise<Json> {
    const known = new Map<string, string | null>();
    for (const i of this.sources.instances()) if (!known.has(i.workspaceId) || known.get(i.workspaceId) === null) known.set(i.workspaceId, i.name);
    for (const w of this.sources.chosenWorkspaces()) if (!known.has(w)) known.set(w, null);
    const workspaces: Json[] = [];
    for (const [workspaceId, name] of known) {
      const runtimes: Json = {};
      for (const runtime of RUNTIMES) runtimes[runtime] = await this.localRuntime(workspaceId, runtime, lang);
      workspaces.push({ workspaceId, name: name ?? workspaceId, runtimes });
    }
    return { workspaces };
  }

  private async localRuntime(workspace: string, runtime: Runtime, _lang: Lang): Promise<Json> {
    const source = this.sources.source(workspace, runtime);
    const lent = this.sources.lent(this.profiles(), this.sources.hostOf(workspace)).filter((p) => p.runtimes.includes(runtime));
    let local: Json = null;
    if (source === "local") {
      if (this.machine && !this.machine.has(runtime)) await this.machine.refresh().catch(() => undefined);
      // Signed in since it was chosen (in a terminal, say): used as the choice asked.
      this.takeUpMachine(runtime);
      const login = this.machine?.get().find((l) => l.runtime === runtime);
      local = {
        installed: login?.installed ?? false,
        loggedIn: login?.loggedIn ?? false,
        email: login?.loggedIn ? login.email : null,
        usable: login?.usable ?? false,
        signIn: this.localSignInView(runtime),
      };
    }
    // Only what would run: a Workspace whose accounts run another runtime only is not offered for this one.
    // `chosen`: a person recorded a choice (an explicit none too); false while it is none only by default.
    const chosen = this.sources.choice(workspace, runtime) !== null;
    return { source, chosen, workspaceAvailable: lent.length > 0, workspaceAccounts: lent.map((p) => ({ name: p.name })), local, endpoint: this.localModelView(runtime) };
  }

  /// The model server this computer runs a runtime on under `endpoint`: its address, whether it has a key, how its last
  /// check went and the models it serves; null until an address is given.
  private localModelView(runtime: Runtime): Json {
    const profile = this.profile(localModelId(runtime));
    if (!profile) return null;
    const check = this.checks.get(profile.id);
    return { address: String(profile.endpoint ?? ""), keyed: keyOf(profile) !== "", state: check?.state ?? "unknown", detail: check?.detail ?? "", models: profile.models };
  }

  /// The model server at `given` taken for a runtime under `endpoint` (its `local-model-<runtime>` profile), at the
  /// protocol the runtime speaks: Claude Code Anthropic's, Codex Responses. Its models are what it lists, its default
  /// the first unless the one it had is still there. Its key, for a server that asks for one (a proxy such as
  /// CLIProxyAPI or LiteLLM), is the one given (an empty one removes it), else the one it had. Kept even when it does
  /// not answer: its check says why. No address given keeps the one there is, and is refused while there is none.
  private async saveLocalModel(runtime: Runtime, given: unknown, givenKey: unknown, lang: Lang) {
    const id = localModelId(runtime);
    if (given === undefined || given === null) {
      if (this.profile(id)) return;
      throw new Refusal(409, tr(lang, "station.source.endpointNeeded"), "endpoint_missing");
    }
    const protocol = runtime === "claude" ? "anthropic" : "responses";
    const endpoint = typeof given === "string" ? serverAddress(given, protocol) : undefined;
    if (endpoint === undefined) throw new Refusal(400, tr(lang, "station.profile.addressNeeded"), "invalid_endpoint");
    const had = this.profile(id);
    const key = typeof givenKey === "string" ? givenKey.trim() : had ? keyOf(had) : "";
    const via: Via = { provider: "custom", endpoint, protocol };
    // Its models are read from the OpenAI-style list every such server has under /v1 (Ollama, LM Studio, CLIProxyAPI,
    // LiteLLM), with a bearer key: asked with Anthropic's headers, a proxy answers with a catalog of its own.
    const listed: Via = { provider: "custom", endpoint: serverAddress(given as string, "responses"), protocol: "responses" };
    const check = await this.checkFn({ runtime, kind: "api-provider", key, via: listed, home: join(this.deps.data, "homes", id), machine: false }, lang);
    const found = check.state === "ok" ? (check.models ?? []) : [];
    this.save(LOCAL_ADMIN, `profile ${id}`, (raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const existing: Json | undefined = list.find((p) => p?.id === id);
      const models: string[] = found.length > 0 ? found : existing?.endpoint === endpoint && Array.isArray(existing.models) ? existing.models : [];
      const model = models.includes(existing?.model) ? existing.model : models[0];
      const made: Json = { id, name: tr(lang, "station.source.endpointName", { address: endpoint }), ...storedAccess(runtime, "api-provider", { ...via, key }), home: `homes/${id}`, env: {} };
      if (models.length > 0) made.models = models;
      if (model !== undefined) made.model = model;
      raw.profiles = existing ? list.map((p) => (p?.id === id ? made : p)) : [...list, made];
    });
    mkdirSync(join(this.deps.data, "homes", id), { recursive: true });
    this.keepCheck(id, check);
  }

  private localSignInView(runtime: Runtime): Json {
    const asked = this.machineSignIns.get(runtime);
    const job = this.logins.get(`${MACHINE_LOGIN}${runtime}`);
    if (!asked || !job) return null;
    const failed = job.state === "failed" || job.state === "cancelled" || (job.state === "done" && asked.error !== null);
    const state = failed ? "failed" : job.state === "done" ? "done" : "running";
    return { state, url: job.url, error: failed ? (asked.error ?? job.error ?? null) : null };
  }

  /// The Workspace named, refused when this computer neither is connected to it nor chose a source for it.
  private localWorkspace(workspace: string, runtime: string, lang: Lang): Runtime {
    const known = this.sources.instances().some((i) => i.workspaceId === workspace) || this.sources.chosenWorkspaces().includes(workspace);
    if (!known) throw new Refusal(404, tr(lang, "station.source.unknownWorkspace"), "unknown_workspace");
    const r = runtimeOf(runtime);
    if (!r) throw new Refusal(400, `unknown runtime ${runtime}`, "unknown_runtime");
    return r;
  }

  /// PUT /local/accounts/<workspace>/<runtime>: the source chosen. The Workspace's accounts only once it lent some; a
  /// model server with its address (`endpoint`, and its `key` if it asks for one), or once one was given.
  async localSetSource(workspace: string, runtime: string, input: Record<string, unknown>, lang: Lang = stationLang()): Promise<Json> {
    const r = this.localWorkspace(workspace, runtime, lang);
    const source = sourceOf(input.source);
    if (!source) throw new Refusal(400, `unknown source ${text(input.source)}`, "unknown_source");
    if (source === "workspace" && !this.sources.lent(this.profiles(), this.sources.hostOf(workspace)).some((p) => p.runtimes.includes(r))) {
      throw new Refusal(409, tr(lang, "station.source.workspaceUnavailable"), "workspace_accounts_unavailable");
    }
    if (source === "endpoint") await this.saveLocalModel(r, input.endpoint, input.key, lang);
    this.setSource(workspace, r, source, LOCAL_ADMIN, true);
    return this.localAccounts(lang);
  }

  /// POST /local/accounts/<workspace>/<runtime>/sign-in: the machine's login signed in, under `local` only.
  async localSignIn(workspace: string, runtime: string, lang: Lang = stationLang()): Promise<Json> {
    const r = this.localWorkspace(workspace, runtime, lang);
    if (this.sources.source(workspace, r) !== "local") throw new Refusal(409, tr(lang, "station.source.notLocal"), "source_not_local");
    await this.startMachineSignIn(r, LOCAL_ADMIN, lang);
    return this.localAccounts(lang);
  }

  /// DELETE /local/accounts/<workspace>/<runtime>/sign-in: that sign-in stopped.
  async localStopSignIn(workspace: string, runtime: string, lang: Lang = stationLang()): Promise<Json> {
    const r = this.localWorkspace(workspace, runtime, lang);
    if (this.machineSignIns.delete(r)) {
      this.logins.cancel(`${MACHINE_LOGIN}${r}`);
      this.changed();
    }
    return this.localAccounts(lang);
  }

  /// The overview's `machineSignIns`: each machine sign-in's job, and why it was not taken up.
  machineSignInsView(): Json[] {
    return [...this.machineSignIns.entries()].map(([runtime, s]) => ({ runtime, job: this.logins.get(`${MACHINE_LOGIN}${runtime}`), error: s.error }));
  }

  /// A profile `machine-<runtime>` on the machine's login, saved (its models none yet). Its id.
  private saveMachineProfile(login: MachineLogin, by: string, lang: Lang): string {
    const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
    const runtime = login.runtime;
    const id = `machine-${runtime}`;
    const home = join(this.deps.data, "homes", id);
    mkdirSync(home, { recursive: true });
    if (runtime === "codex") linkCodexAuth(home, this.machine!.env);
    const name = login.email !== null ? t("station.machine.emailName", { email: login.email }) : t("station.machine.runtimeName", { runtime: named(runtime) });
    log.info("accounts", "profile on the machine's login made", { profile: id, runtime, by });
    this.save(by, `profile ${id} on the machine's login`, (raw) => {
      const made = { id, name, runtime, ...storedAccess(runtime, "subscription", {}, true), home: `homes/${id}`, env: {} };
      raw.profiles = [...(Array.isArray(raw.profiles) ? raw.profiles : []), made];
    });
    return id;
  }

  /// The models a check of a profile on the machine's login found, enabled beside those it has.
  private enableFound(id: string, check: ProfileCheck) {
    const found = check.state === "ok" ? (check.models ?? []) : [];
    const has = this.profile(id)?.models ?? [];
    if (found.every((m) => has.includes(m))) return;
    this.save("station", `profile ${id}'s models`, (raw) => {
      const made = (Array.isArray(raw.profiles) ? raw.profiles : []).find((p: Json) => p?.id === id);
      if (!made) return;
      const models: string[] = Array.isArray(made.models) ? made.models : [];
      made.models = [...models, ...found.filter((m) => !models.includes(m))];
    });
  }

  // ── sign-ins ──

  /// POST /profiles/:id/login: a subscription profile signed in (again).
  async startLogin(id: string, viewer: Viewer, lang: Lang = stationLang()): Promise<LoginJob> {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    if (accessKind(profile) !== "subscription") throw new Refusal(400, tr(lang, "station.admin.loginSubscriptionOnly"));
    if (profile.credential === "machine") throw new Refusal(400, tr(lang, "station.admin.loginOnMachine"));
    if (borrowed(profile)) throw new Refusal(409, tr(lang, "station.share.borrowedEdit"));
    log.info("accounts", "login started from the admin page", { profile: id, by: viewer.email });
    return this.logins.start({ id, runtime: profile.runtime, home: profile.home }, lang);
  }

  /// POST /logins: signing a subscription in before there is a profile; the profile is made once it succeeds.
  async newLogin(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<{ id: string; job: LoginJob }> {
    const runtime = runtimeOf(input.runtime);
    if (!runtime) throw new Refusal(400, `unknown runtime ${text(input.runtime)}`);
    const id = `login-${randomBytes(4).toString("hex")}`;
    const home = join(this.deps.data, "homes", id);
    this.pending.set(id, { runtime, home, by: viewer, created: null, error: null });
    log.info("accounts", "sign-in for a new profile started", { login: id, runtime, by: viewer.email });
    const job = await this.logins.start({ id, runtime, home }, lang);
    return { id, job };
  }

  /// Whether a sign-in for a new profile is under that id.
  hasPending(id: string): boolean {
    return this.pending.has(id);
  }

  /// A sign-in for a new profile, dropped (DELETE /logins/:id): its command stopped, its home removed unless it made one.
  dropLogin(id: string) {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    this.logins.cancel(id);
    if (pending.created === null) rmSync(pending.home, { recursive: true, force: true });
    this.changed();
  }

  /// A sign-in for a new profile moved on: once it succeeds the profile is made, named by the account signed in.
  private pendingChanged(id: string) {
    const p = this.pending.get(id);
    if (!p) return;
    const state = this.logins.get(id)?.state;
    if (state === "failed" || state === "cancelled") {
      rmSync(p.home, { recursive: true, force: true });
      return;
    }
    if (state !== "done" || p.created !== null || p.error !== null) return;
    const lang = stationLang();
    const email = accountEmail(p.runtime, p.home);
    const base = slug(email ?? `${p.runtime}-subscription`, 40) || p.runtime;
    const profileId = unique(base, this.takenIds());
    const target = join(this.deps.data, "homes", profileId);
    try {
      renameSync(p.home, target);
    } catch (e) {
      log.warn("accounts", "could not move a new profile's home", { login: id, error: (e as Error).message });
      return this.pendingFailed(id, tr(lang, "station.login.homeFailed", { error: (e as Error).message }));
    }
    const name = email ?? tr(lang, p.runtime === "claude" ? "station.profile.claudeSubscription" : "station.profile.chatgptSubscription");
    try {
      this.save(p.by, `profile ${profileId} from a sign-in`, (raw) => {
        const made = { id: profileId, name, runtime: p.runtime, ...storedAccess(p.runtime, "subscription", {}), home: `homes/${profileId}`, env: {} };
        raw.profiles = [...(Array.isArray(raw.profiles) ? raw.profiles : []), made];
      });
    } catch (e) {
      log.warn("accounts", "the signed-in profile was not saved", { login: id, error: (e as Error).message });
      try {
        renameSync(target, p.home);
      } catch {}
      return this.pendingFailed(id, tr(lang, "station.login.saveFailed", { error: (e as Error).message }));
    }
    p.created = profileId;
    this.afterSignIn(profileId);
    // Kept a while for the page that started it to follow it to the profile.
    this.background.after(PENDING_KEPT_MS, () => this.dropLogin(id));
  }

  private pendingFailed(id: string, error: string) {
    const p = this.pending.get(id);
    if (p) p.error = error;
    this.changed();
  }

  /// A profile just signed in: checked (which lists its models) and its allowance read, so its page shows them at once.
  private afterSignIn(id: string) {
    this.background.spawn(async () => {
      try {
        await this.check(id);
      } catch (e) {
        log.warn("accounts", "check after sign-in failed", { profile: id, error: (e as Error).message });
      }
      await this.refreshQuota(id);
    });
  }

  // ── checks and allowances ──

  private keepCheck(id: string, check: ProfileCheck) {
    check.checkedAt = this.background.now();
    this.checks.set(id, check);
    this.deps.store.setProfileCheck(id, check);
    this.changed();
  }

  /// POST /profiles/:id/check: asks the provider or runtime whether the profile works, its models, its reasoning levels
  /// (Codex) and what it can decide with.
  async check(id: string, lang: Lang = stationLang()): Promise<ProfileCheck> {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    if (!this.inUse(profile)) throw new Refusal(409, tr(lang, "station.source.machineOff"));
    const kind = accessKind(profile);
    if (borrowed(profile) && kind === "subscription" && this.deps.shared) return this.checkBorrowed(profile, lang);
    const check = await this.checkFn(
      { runtime: profile.runtime, kind, key: keyOf(profile), via: profileVia(profile), home: profile.home, machine: isMachine(profile) },
      lang,
    );
    // Codex capabilities kept for each account, including providers whose model ids came from their API.
    const codexSubscription = kind === "subscription" && profile.runtime === "codex";
    const codex = this.deps.codex?.();
    if ((check.state === "ok" || check.state === "unknown") && profile.runtimes.includes("codex") && codex) {
      try {
        const catalog = await codex.models(profile);
        if (codexSubscription && check.models === null) check.models = catalog.models;
        check.modelEfforts = { codex: Object.fromEntries(catalog.efforts) };
      } catch (e) {
        // A temporary listing failure does not erase a saved selection in the clients.
        const previous = this.checks.get(id);
        if (previous) {
          if (previous.modelEfforts !== undefined) check.modelEfforts = previous.modelEfforts;
          if (codexSubscription && check.models === null) check.models = previous.models;
        }
        check.detail = tr(lang, "station.profile.modelsStale", { detail: check.detail });
        log.warn("accounts", "could not list codex model capabilities", { profile: id, error: (e as Error).message });
      }
    }
    check.decision = await this.discoverFn(profile, check);
    // A profile edited during the probe does not inherit the previous account's capabilities.
    const now = this.profile(id);
    if (!now || fingerprint(now) !== fingerprint(profile)) throw new Refusal(409, "Profile 已修改，请重新检查");
    this.keepCheck(id, check);
    if (isMachine(now)) this.enableFound(id, check);
    // One never asked yet (just made, however): its allowance now, not at the next round.
    if (check.state === "ok" && !this.quotas.has(id)) this.background.spawn(() => this.refreshQuota(id));
    return check;
  }

  /// A copy of another station's subscription: how it is doing is what its host says (unusable while it does not answer).
  private async checkBorrowed(profile: Profile, lang: Lang): Promise<ProfileCheck> {
    let check: ProfileCheck;
    try {
      const got = await this.deps.shared!.status(profile);
      check = isObject(got.check) ? (got.check as ProfileCheck) : { state: "unknown", detail: "", models: null, checkedAt: 0 };
      if (isObject(got.quota)) {
        this.quotas.set(profile.id, got.quota as ProfileQuota);
        this.deps.store.setProfileQuota(profile.id, got.quota);
      }
    } catch {
      const host = this.deps.shared!.hostName?.(profile) ?? "";
      check = { state: "failed", detail: tr(lang, "station.share.hostOffline", { host }), models: null, checkedAt: 0 };
    }
    this.keepCheck(profile.id, check);
    return check;
  }

  /// POST /profiles/:id/quota: a profile's allowance asked again (unless a question is on its way already: then the
  /// last one).
  refreshQuota(id: string): Promise<ProfileQuota | null> {
    return this.readQuota(id, false);
  }

  private readQuota(id: string, afterReset: boolean): Promise<ProfileQuota | null> {
    const busy = this.quotaBusy.get(id);
    if (busy && !afterReset) return Promise.resolve(this.quotas.get(id) ?? null);
    // A read after a reset waits for any older one, so an in-flight snapshot from before cannot win.
    const read = (async () => {
      if (busy) await busy;
      return this.askQuota(id);
    })();
    const done: Promise<void> = read.then(
      () => {},
      () => {},
    );
    this.quotaBusy.set(id, done);
    void done.then(() => {
      if (this.quotaBusy.get(id) === done) this.quotaBusy.delete(id);
    });
    return read;
  }

  private async askQuota(id: string): Promise<ProfileQuota | null> {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    // Another station's subscription: its allowance comes with its host's check.
    if (borrowed(profile) && accessKind(profile) === "subscription" && this.deps.shared) {
      await this.checkBorrowed(profile, stationLang()).catch(() => {});
      return this.quotas.get(id) ?? null;
    }
    if (!this.quotaFn || !this.inUse(profile)) return this.quotas.get(id) ?? null;
    const read = { ...(await this.quotaFn(profile)), checkedAt: this.background.now() };
    this.quotas.set(id, read);
    this.deps.store.setProfileQuota(id, read);
    this.changed();
    return read;
  }

  /// Asks again every profile's allowance older than a round (all of them, `all`).
  refreshQuotas(all: boolean) {
    if (!this.quotaFn) return;
    const now = this.background.now();
    for (const p of this.profiles()) {
      if (!this.inUse(p)) continue;
      const q = this.quotas.get(p.id);
      const fresh = q !== undefined && now - q.checkedAt < QUOTA_EVERY_MS - 1000;
      if (fresh && !all) continue;
      this.background.spawn(() => this.refreshQuota(p.id));
    }
  }

  /// Copies of other stations' subscriptions checked again (their host answers again, or may).
  recheckBorrowed() {
    for (const p of this.profiles()) {
      if (borrowed(p) && accessKind(p) === "subscription") this.background.spawn(() => this.check(p.id).catch(() => {}));
    }
  }

  /// The first follower of the events came: allowances older than a round are asked again now.
  followed() {
    this.refreshQuotas(false);
  }

  /// POST /profiles/:id/reset-quota: an OpenAI subscription's rate-limit reset redeemed, under the request's key.
  async resetQuota(id: string, key: string, lang: Lang = stationLang()): Promise<Json> {
    const t = (k: string) => tr(lang, k);
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, t("station.profile.notFound"));
    if (profile.runtime !== "codex" || accessKind(profile) !== "subscription") throw new Refusal(400, t("station.quota.resetOpenAiOnly"));
    if (!this.resetFn) throw new Refusal(503, t("station.quota.resetUnsupported"));
    const result = await this.resetFn(profile, key);
    await this.readQuota(id, true);
    const outcome = result?.outcome;
    if (outcome === "reset" || outcome === "alreadyRedeemed") return result;
    if (outcome === "nothingToReset") throw new Refusal(409, t("station.quota.nothingToReset"));
    if (outcome === "noCredit") throw new Refusal(409, t("station.quota.noCredit"));
    throw new Refusal(502, t("station.quota.resetUnconfirmed"));
  }

  // ── the automatic decisions (admin/decision.rs) ──

  /// The models the decisions may ask: each a usable profile's verified one, with the profiles that have it.
  decisionModels(): { id: string; name: string; profiles: string[] }[] {
    const models = new Map<string, string[]>();
    for (const profile of this.profiles()) {
      if (!this.inUse(profile)) continue;
      const health = this.deps.hub?.accounts.healthOf(profile.id) ?? this.health(profile.id);
      if (!usable(health, this.background.clock.currentTimeMillisUnsafe())) continue;
      const capability: Capability | undefined = health.check?.decision;
      if (!capability) continue;
      for (const model of [...(capability.models ?? []), ...(capability.model ? [capability.model] : [])]) {
        if (!resolvedModel(profile, capability, model)) continue;
        const names = models.get(model) ?? [];
        if (!names.includes(profile.name)) names.push(profile.name);
        models.set(model, names);
      }
    }
    return [...models.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([id, profiles]) => ({ id, name: modelName(id), profiles }));
  }

  /// PUT /automatic-decisions (a workspace manager's).
  putAutomaticDecisions(input: Record<string, unknown>, viewer: Viewer) {
    if (!manages(viewer)) throw new Refusal(403, "只有 workspace 管理员能配置自动决策");
    try {
      checkAutomaticDecisions(input);
    } catch {
      throw new Refusal(400, "自动决策配置格式不正确");
    }
    const rule: Json = isObject(input.completion) ? input.completion : {};
    const config = { completion: { enabled: rule.enabled === true, model: typeof rule.model === "string" ? rule.model : null } };
    if (config.completion.enabled && !this.decisionModels().some((m) => m.id === config.completion.model)) {
      throw new Refusal(400, "请选择现有 Profile 中已验证可用的决策模型");
    }
    this.save(viewer, "automatic decisions", (raw) => {
      raw.automaticDecisions = config;
    });
  }

  /// POST /automatic-decisions/review: the done chats no decision has answered, reviewed now in the background; how many.
  reviewUndecided(viewer: Viewer): number {
    if (!manages(viewer)) throw new Refusal(403, "只有 workspace 管理员能触发自动决策");
    const review = this.deps.reviewUndecided;
    if (!review) throw new Refusal(503, "这台 station 暂不支持手动检查");
    if (!hubConfig(this.deps.config.raw(), this.deps.data).automaticDecisions.completion.enabled) throw new Refusal(409, "先启用并保存这条规则");
    const queued = review();
    if (queued === null) throw new Refusal(409, "配置的模型在现有 Profile 中暂不可用");
    return queued;
  }

  /// POST /automatic-decisions/refresh: every profile checked again (four at a time).
  async refreshDecisionModels(viewer: Viewer, lang: Lang = stationLang()) {
    if (!manages(viewer)) throw new Refusal(403, "只有 workspace 管理员能刷新决策模型");
    const ids = this.profiles().filter((p) => this.inUse(p)).map((p) => p.id);
    const errors: unknown[] = [];
    let next = 0;
    const worker = async () => {
      while (next < ids.length) {
        const id = ids[next++]!;
        try {
          await this.check(id, lang);
        } catch (e) {
          errors.push(e);
        }
      }
    };
    await Promise.all([worker(), worker(), worker(), worker()]);
    if (errors.length > 0) throw errors[0];
  }

  // ── what the overview shows of the accounts (admin/views.rs `overview`) ──

  /// What the session's chat is called in the chat list; its key only where it has no chat.
  private chatTitleOf(session: string): string {
    const summary = this.deps.store.listThreads("", session, null)[0];
    if (summary) return titleOf(summary.thread, summary.firstText, null);
    return this.deps.store.getSession(session)?.title ?? session;
  }

  /// The overview's `automaticDecisions`.
  automaticDecisionsView(viewer: Viewer): Json {
    if (!manages(viewer)) return { canEdit: false, settings: {}, models: [], recent: [] };
    const lang = stationLang();
    const titles = new Map<string, string>();
    const title = (session: string) => {
      let t = titles.get(session);
      if (t === undefined) titles.set(session, (t = this.chatTitleOf(session)));
      return t;
    };
    // For pages from before the policy: the checks one by one.
    const recent = this.deps.store.recentDecisions().map((row: Json) => {
      const d = row.detail ?? {};
      const session = typeof row.session === "string" ? row.session : "";
      return {
        id: row.id, session, title: title(session), at: row.at, label: checkLabel(d, lang),
        accepted: d.accepted ?? null, model: d.model ?? null, profile: d.profile ?? null, elapsedMs: d.elapsedMs ?? null, error: d.error ?? null,
      };
    });
    const settings = this.deps.config.raw()?.automaticDecisions;
    const completion = isObject(settings?.completion) ? settings.completion : {};
    return {
      canEdit: true,
      canReview: this.deps.reviewUndecided !== undefined,
      settings: { completion: { enabled: completion.enabled === true, model: typeof completion.model === "string" ? completion.model : null } },
      models: this.decisionModels(),
      recent,
      policy: this.policyView(title),
    };
  }

  /// The archive policy as the pages show it: its words, its options each with the chats the checks of the last days
  /// put there (by their latest check), who changed it last, and how many checks failed.
  private policyView(title: (session: string) => string): Json {
    const store = this.deps.store;
    const policy = currentPolicy(store);
    const saved = store.archivePolicy();
    const latest = new Map<string, Json>();
    for (const row of store.decisionsSince(store.now() - POLICY_DAYS * 86_400_000)) if (typeof row.session === "string") latest.set(row.session, row);
    const byOption = new Map<string, Json[]>();
    let failed = 0;
    for (const [session, row] of [...latest.entries()].reverse()) {
      const picked = pickedOf(row.detail);
      if (picked === null) {
        failed++;
        continue;
      }
      const list = byOption.get(picked) ?? [];
      list.push({ session, title: title(session), at: row.at, recommended: row.detail?.accepted === true });
      byOption.set(picked, list);
    }
    const by = saved?.change.by;
    return {
      text: policy.policy,
      options: policy.options.map((o) => {
        const chats = byOption.get(o.id) ?? [];
        return { ...o, count: chats.length, chats: chats.slice(0, POLICY_CHATS) };
      }),
      days: POLICY_DAYS,
      checked: latest.size,
      failed,
      edited: saved !== null,
      change: saved
        ? { at: saved.change.at, summary: saved.change.summary, by: by?.kind === "agent" ? { kind: "agent", session: by.session, title: title(by.session), runtime: store.getSession(by.session)?.runtime ?? null } : { kind: "person", email: by?.email ?? null, name: by?.name ?? null } }
        : null,
    };
  }

  /// PUT /automatic-decisions/policy (a workspace manager's): the policy in words and its options; the done chats are
  /// checked again under it.
  putArchivePolicy(input: Record<string, unknown>, viewer: Viewer) {
    if (!manages(viewer)) throw new Refusal(403, "只有 workspace 管理员能改归档策略");
    let changed: string | null;
    try {
      changed = savePolicy(this.deps.store, input, { kind: "person", email: viewer.email, name: viewer.name || null });
    } catch (e) {
      throw new Refusal(400, (e as Error).message);
    }
    if (changed !== null) this.deps.reviewUndecided?.();
  }

  /// The overview's `profiles`.
  profilesView(): Json[] {
    const raw = this.deps.config.raw();
    const config = hubConfig(raw, this.deps.data);
    return config.profiles.map((p) => {
      const kind = accessKind(p);
      const via = profileVia(p);
      const custom: Record<string, string> = isObject(p.env) ? (p.env as Record<string, string>) : {};
      const env = Object.keys(custom)
        .sort()
        .map((key) => ({ key, secret: secretKey(key), value: secretKey(key) ? mask(custom[key]!) : custom[key] }));
      const check = this.checks.get(p.id);
      let checkView: Json = null;
      if (check) {
        checkView = structuredClone(check);
        if (isObject(checkView.decision)) delete checkView.decision.fingerprint;
        if (check.decision && check.decision.fingerprint !== fingerprint(p)) checkView.decision = { state: "pending", detail: "Profile 已修改，等待自动检查" };
      }
      return {
        id: p.id, name: p.name, runtime: p.runtime, runtimes: p.runtimes,
        email: kind === "subscription" && !isMachine(p) ? (borrowed(p) ? (typeof (p.share as Json)?.email === "string" ? (p.share as Json).email : null) : accountEmail(p.runtime, p.home)) : null,
        // A provider's key says `env` where an older core reads it; the provider next to it tells a newer core it is not.
        access: {
          kind: kind === "api-provider" ? "env" : kind, key: mask(keyOf(p)),
          provider: via.provider ?? null, endpoint: via.endpoint ?? null, protocol: via.protocol ?? null,
        },
        home: p.home, homeExists: existsSync(p.home), model: p.model ?? null, models: p.models,
        env,
        // Connects whose sessions can run on it: of its runtime, and its models have theirs.
        usedBy: config.connects.filter((c) => p.runtimes.includes(c.bind.runtime) && serves(p, c.bind.model)).map((c) => c.id),
        loginCommand: loginCommand(p.runtime, p.home),
        machine: isMachine(p),
        backgroundOnMessage: p.backgroundOnMessage,
        fast: p.runtime === "codex" && kind === "subscription" ? p.fast === true : null,
        check: checkView,
        login: this.logins.get(p.id),
        quota: this.quotas.get(p.id) ?? null,
        // Shared with the workspace's other stations, or another station's (absent: neither; old clients ignore it).
        share: this.deps.shared?.view(p) ?? null,
      };
    });
  }

  /// The overview's `logins`: sign-ins for new profiles.
  loginsView(): Json[] {
    return [...this.pending.entries()].map(([id, p]) => ({ id, runtime: p.runtime, job: this.logins.get(id), created: p.created, error: p.error }));
  }

  /// The overview's `machineLogins`.
  machineLogins(): MachineLogin[] {
    return this.machine?.get() ?? [];
  }

  /// The overview's `apiProviders`: the providers a key can be added for (not the two kinds from before the list).
  apiProviders(): Json[] {
    return SOURCES.filter((s) => !(s.id in LEGACY)).map((s) => ({ id: s.id, name: s.name, group: groupOf(s.id) }));
  }

  /// Ids a new profile may not take: the profiles' own, and every home on disk (a deleted profile's home stays).
  private takenIds(): Set<string> {
    const taken = new Set(this.profiles().map((p) => p.id));
    try {
      for (const name of readdirSync(join(this.deps.data, "homes"))) taken.add(name);
    } catch {}
    return taken;
  }
}

/// Makes the station's accounts (start() it once wired).
export const makeAccounts = (deps: AccountsDeps) => new Accounts(deps);

/// A profile leaving its runtime (deleted, or moved to another): refused when it is the last one of a runtime that
/// connects run.
function lastOfRuntime(raw: Json, runtime: Runtime, id: string, lang: Lang) {
  const profiles: Json[] = Array.isArray(raw?.profiles) ? raw.profiles : [];
  if (profiles.some((p) => p?.id !== id && runtimesFor(p).includes(runtime))) return;
  const users = (Array.isArray(raw?.connects) ? raw.connects : [])
    .filter((c: Json) => c?.bind?.runtime === runtime)
    .map((c: Json) => (typeof c?.slack?.botName === "string" && c.slack.botName !== "" ? c.slack.botName : c.id));
  if (users.length > 0) throw new Error(tr(lang, "station.profile.lastForRuntime", { runtime, users: users.join(tr(lang, "station.list.separator")) }));
}

/// The account a subscription home is signed in as, when its files say: Codex's id token, Claude's account record.
export function accountEmail(runtime: Runtime, home: string): string | null {
  if (runtime === "codex") {
    const claims = codexClaims(home);
    const email = claims?.email ?? claims?.["https://api.openai.com/profile"]?.email;
    return typeof email === "string" ? email : null;
  }
  for (const file of [join(home, ".claude.json"), join(home, "claude.json")]) {
    try {
      const email = JSON.parse(readFileSync(file, "utf8"))?.oauthAccount?.emailAddress;
      if (typeof email === "string") return email;
    } catch {}
  }
  return null;
}

/// A slug for an id: lower case, runs of anything else as one dash, at most `max` long.
export function slug(text: string, max: number): string {
  let out = "";
  for (const c of text.toLowerCase()) {
    if (/^[a-z0-9]$/.test(c)) out += c;
    else if (!out.endsWith("-")) out += "-";
  }
  return [...out.replace(/^-+|-+$/g, "")].slice(0, max).join("").replace(/-+$/, "");
}

/// The first of base, base-2, base-3 … not taken.
export function unique(base: string, taken: Set<string>): string {
  let id = base;
  for (let n = 2; taken.has(id); n++) id = `${base}-${n}`;
  return id;
}

/// Whether a variable holds a secret (shown masked).
export const secretKey = (key: string) => ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"].some((w) => key.toUpperCase().includes(w));

/// Masks a secret for the pages: its first five and last four characters.
export function mask(value: string): string {
  if (value === "") return "";
  const chars = [...value];
  if (chars.length <= 8) return "••••";
  return `${chars.slice(0, 5).join("")}…${chars.slice(-4).join("")}`;
}

// ── a model as people call it (shapes model.rs `name`) ──

const CLAUDE = ["fable", "opus", "sonnet", "haiku"];
const BRANDS: Record<string, string> = {
  deepseek: "DeepSeek", minimax: "MiniMax", qwq: "QwQ", glm: "GLM", gpt: "GPT", oss: "OSS", moonshot: "Moonshot", devstral: "Devstral",
  codestral: "Codestral", llama: "Llama", ernie: "ERNIE", vl: "VL", r1: "R1", it: "IT",
};

const word = (w: string) => BRANDS[w] ?? (w === "" ? "" : w[0]!.toUpperCase() + w.slice(1));
const digitsOnly = (w: string) => /^[0-9]+$/.test(w);

function namedModel(base: string): string | undefined {
  const words = base.split("-").filter((w) => w !== "");
  const first = words[0];
  if (first === undefined) return undefined;
  if (first === "claude" || CLAUDE.includes(first)) {
    const family = words.find((w) => CLAUDE.includes(w));
    if (family === undefined) return undefined;
    const version = words.filter(digitsOnly);
    const rest = words.filter((w) => w !== "claude" && w !== family && !digitsOnly(w)).map(word);
    return [word(family), ...(version.length > 0 ? [version.join(".")] : []), ...rest].join(" ");
  }
  const dashed = first === "gpt" ? "GPT" : first === "glm" ? "GLM" : undefined;
  if (dashed !== undefined && words[1] !== undefined) return [`${dashed}-${words[1]}`, ...words.slice(2).map(word)].join(" ");
  const oSeries = first.length > 1 && first.startsWith("o") && digitsOnly(first.slice(1));
  const known = ["gpt", "glm", "codex", "deepseek", "qwen", "qwq", "gemini", "gemma", "kimi", "moonshot", "minimax", "grok", "mistral", "devstral", "codestral", "llama", "doubao", "hunyuan", "ernie"];
  const family = first.replace(/[0-9.]+$/, "");
  if (!oSeries && !known.includes(family)) return undefined;
  return words.map((w, i) => (i === 0 && oSeries ? w : word(w))).join(" ");
}

/// A model as people call it: Opus 5.5, GPT-6 Astra, o4 Mini, DeepSeek V4 Pro; one of a family not known here reads as
/// it is spelled.
export function modelName(id: string): string {
  const k = modelKey(id);
  const at = k.indexOf("[");
  const [base, context] = at >= 0 ? [k.slice(0, at), k.slice(at + 1).replace(/\]+$/, "").toUpperCase()] : [k, ""];
  const named = namedModel(base);
  if (named === undefined) return id.trim();
  return context === "" ? named : `${named} ${context}`;
}

/// A check in a line, for the pages that list them one by one: the option the model picked and what came of it, or
/// that it failed. Checks from before the policy had options name the fixed four's.
export function checkLabel(d: Json, lang: Lang): string {
  const selected = typeof d?.result?.selected === "string" ? d.result.selected : null;
  if (selected === null) return tr(lang, "station.decisions.failed");
  const name = typeof d.option?.name === "string" ? d.option.name : (LEGACY_OPTIONS[selected]?.name ?? selected);
  return `${name} · ${tr(lang, d.accepted === true ? "station.decisions.archive" : "station.decisions.keep")}`;
}

/// The id of the option a check picked, null when it failed.
const pickedOf = (d: Json): string | null => (typeof d?.result?.selected === "string" ? d.result.selected : null);
