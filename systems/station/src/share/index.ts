// What this station shares with the other stations of its workspace, and what it uses of theirs
// (docs/station-share.md). It is between the stations only (the station transport, `share.*`, jobs/remote.ts hands
// them here); still.fail cloud says nothing of it beyond which stations are in the workspace.
//
// - The station that has a profile or a skill (its host) keeps who may use it (`allow`, null: every station) and who
//   has a copy or borrows it (state.json `hosted[id].told`: each station and the version it was told of). It tells
//   each station that may use it, directly, when it is shared, changed, moved or no longer shared (share.changed), the
//   ones that did not answer again later.
// - A station that uses one keeps which station it has it from (`share.host` on its profile, state.json
//   `borrowed[id].host`) and asks that station once a run what it is at (share.version), for what changed while it was
//   away.
// - A key profile and a skill: each station that may use it keeps a copy (config.json, <data>/share/<id>/); the host
//   being offline changes nothing for them.
// - A subscription: only its host keeps the login and renews it (a refresh token is spent when used, so two renewing
//   would sign each other out). The others borrow a short-lived access token for each process they start; with the host
//   offline they cannot.
// - Edits to a skill made where it is copied go to its host, which keeps one order of them; one made on an older copy
//   is kept beside the skill as SKILL.conflict-<station>.md.
// - A share moves to another station only from its host, while both are up: it stops lending, hands the profile and
//   its login over, keeps a copy borrowed from the new host, and tells the stations it had told where it went.
//
// Config: a shared profile has `share: {id, allow}` on its host and `share: {id, borrowed: true, host}` where copied
// (made and removed only here). Shared skills are config.json `sharedSkills: {name: {id, allow}}`.
import { createHash, randomBytes } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, renameSync, rmSync, unlinkSync, watch, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import type { Clock } from "effect";
import type { Env, MachineToken } from "../agents/machine-logins.ts";
import { codexAuthFile } from "../agents/machine-logins.ts";
import { accessKind, isMachine } from "../agents/profiles.ts";
import type { Cloud } from "../cloud/state.ts";
import type { ConfigFile } from "../ops/config.ts";
import { Fibers } from "../ops/fibers.ts";
import { writePrivate } from "../ops/files.ts";
import { log } from "../ops/log.ts";
import { linkSync } from "../ops/links.ts";
import { joinPath, relativeParts } from "../ops/paths.ts";

type Json = any;

/// What a skill may hold to be shared (sent whole in one request of the station transport, which takes 1 MB).
const MAX_SKILL_BYTES = 512 * 1024;
const MAX_SKILL_FILES = 200;
/// A host lends a Codex token it has for at least this long; one closer to its end is renewed first (when it can be).
const CODEX_LEND_MS = 24 * 3600_000;
const CODEX_MIN_MS = 3600_000;
/// Edits to a skill are taken once they have settled this long.
const SETTLE_MS = 2000;
/// What could not be done because another station did not answer is tried again after this, then twice as long each
/// time up to RETRY_MAX_MS (only while there is).
const RETRY_MS = 60_000;
const RETRY_MAX_MS = 30 * 60_000;
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token";

export type ShareRole = "host" | "user";
/// What the overview says of a shared profile or skill: for its host also the stations that have it (`users`).
export type ShareView = { id: string; role: ShareRole; host: string; allow: string[] | null; reachable: boolean | null; users?: string[] };
export type ShareKind = "profile" | "skill";

export type SharingDeps = {
  data: string;
  config: ConfigFile;
  /// Which stations are in the workspace (cloud.json's roster), and this one's id.
  cloud: Cloud;
  /// A request to another station of the workspace (the station transport).
  ask: (station: string, request: Json) => Promise<Json>;
  /// The agents' home (its skills/ directory is where shared skills are linked).
  agentHome: () => string;
  /// The station's environment (the machine's own logins are found in it).
  env: Env;
  /// A Claude profile's current access token, renewed when about to run out (the accounts module's).
  claudeToken: (profile: Json) => Promise<MachineToken>;
  /// Whether the machine's own login of a runtime is in use (accounts/sources.ts): one not in use is never lent.
  machineAllowed?: (runtime: "claude" | "codex") => boolean;
  /// Whether a Codex app-server runs on a profile here now (its login must not be renewed under it).
  codexRunning: (profileId: string) => boolean;
  /// A profile's check and allowance as this station has them (for the stations borrowing it).
  status: (profileId: string) => { check: Json; quota: Json };
  /// Something the overview shows changed.
  changed: () => void;
  /// A host that had not answered answers again: what is borrowed from it is checked again.
  recheck?: () => void;
  clock?: Clock.Clock;
  /// Tests: Codex's token endpoint.
  codexTokenUrl?: string;
};

type Hosted = { version: number; hash: string; kind: ShareKind; name: string; allow: string[] | null; told: Record<string, number> };
type Borrowed = { version: number; hash: string; kind: ShareKind; name: string; host: string; allow: string[] | null; pending?: boolean; stale?: boolean };
type State = {
  /// What this station shares: its version (raised when what it is changes) and each station told of it, at which
  /// version (-1: told it is no longer for it).
  hosted: Record<string, Hosted>;
  /// What it uses of others': from which station, at which version.
  borrowed: Record<string, Borrowed>;
  /// Shares it handed to another station, and the stations still to be told where they went.
  moved: Record<string, { to: string; tell: string[] }>;
};

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
const hashOf = (v: unknown) => createHash("sha256").update(typeof v === "string" ? v : JSON.stringify(v)).digest("hex");
const newId = () => `sh-${randomBytes(10).toString("hex")}`;
/// A profile as another station gets it: what it is, its key when it has one, never where its files are or a login.
function portable(p: Json): Json {
  const out: Json = {};
  for (const k of ["name", "runtime", "credential", "source", "endpoint", "protocol", "key", "env", "model", "models", "disabled_models", "background_on_message", "fast"]) {
    if (p[k] !== undefined) out[k] = structuredClone(p[k]);
  }
  // On the machine's own login where it is: a subscription elsewhere, lent by its host.
  if (out.credential === "machine") out.credential = "subscription";
  if (out.credential !== "api_key") delete out.key;
  return out;
}

/// A skill's files, relative paths to their bytes; refused past the limits (or with links in it).
function readSkill(dir: string): Record<string, Buffer> {
  const files: Record<string, Buffer> = {};
  let bytes = 0;
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const path = join(at, name);
      const meta = lstatSync(path);
      if (meta.isSymbolicLink()) continue;
      if (meta.isDirectory()) walk(path);
      else if (meta.isFile()) {
        // A conflict kept beside the skill is the host's to show, not part of what is shared.
        if (/^SKILL\.conflict-/.test(name)) continue;
        bytes += meta.size;
        if (bytes > MAX_SKILL_BYTES || Object.keys(files).length >= MAX_SKILL_FILES) throw new Error("the skill is too large to share (512 KB, 200 files at most)");
        files[relative(dir, path).split(sep).join("/")] = readFileSync(path);
      }
    }
  };
  walk(dir);
  return files;
}

const skillHash = (files: Record<string, Buffer>) =>
  hashOf(Object.keys(files).sort().map((k) => `${k}\0${createHash("sha256").update(files[k]!).digest("hex")}`).join("\n"));

/// A relative path that stays inside the skill (relativeParts: not rooted, no `..`), none of its components `.` or
/// empty.
const safePath = (p: string) => {
  const parts = relativeParts(p);
  return parts !== null && !parts.some((s) => s === "." || s === "");
};

function writeSkill(dir: string, files: Record<string, string>) {
  const temp = `${dir}.tmp-${randomBytes(4).toString("hex")}`;
  rmSync(temp, { recursive: true, force: true });
  for (const [path, data] of Object.entries(files)) {
    if (!safePath(path)) throw new Error(`bad path in a shared skill: ${path}`);
    mkdirSync(dirname(join(temp, path)), { recursive: true });
    writeFileSync(join(temp, path), Buffer.from(data, "base64"));
  }
  mkdirSync(temp, { recursive: true });
  rmSync(dir, { recursive: true, force: true });
  renameSync(temp, dir);
}

const encodeFiles = (files: Record<string, Buffer>) => Object.fromEntries(Object.entries(files).map(([k, v]) => [k, v.toString("base64")]));

/// When a JWT runs out (ms), if it says.
function jwtExpiry(token: unknown): number | null {
  if (typeof token !== "string") return null;
  try {
    const claims = JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8"));
    return typeof claims?.exp === "number" ? claims.exp * 1000 : null;
  } catch {
    return null;
  }
}

export class Sharing {
  private deps: SharingDeps;
  private time: Fibers;
  private watchers = new Map<string, { close(): void }>();
  private settle = new Map<string, () => void>();
  private retry: (() => void) | null = null;
  private retryMs = RETRY_MS;
  private stops: (() => void)[] = [];
  /// Hosts that did not answer lately, and when (for the overview's `reachable`).
  private unreachable = new Map<string, number>();
  /// Shares this station is handing to another right now: not lent meanwhile.
  private moving = new Set<string>();
  private reconciling: Promise<void> | null = null;
  private again = false;
  /// Copies asked about in this run (what changed while this station was away is found that way).
  private checked = new Set<string>();
  /// Hosts outside the workspace (Salix, for a Workload's station): asked through their own channel (null while it is
  /// down), and their shares are what they last said, not kept in step with the workspace's roster.
  private hosts = new Map<string, ((request: Json) => Promise<Json>) | null>();

  constructor(deps: SharingDeps) {
    this.deps = deps;
    this.time = new Fibers("share", deps.clock);
  }

  private get root() {
    return join(this.deps.data, "share");
  }

  private ask(host: string, request: Json): Promise<Json> {
    if (!this.hosts.has(host)) return this.deps.ask(host, request);
    const ask = this.hosts.get(host);
    return ask ? ask(request) : Promise.reject(new Error(`${host} is not connected`));
  }

  /// A host outside the workspace: how it is asked now (null: it cannot be).
  attachHost(host: string, ask: ((request: Json) => Promise<Json>) | null) {
    this.hosts.set(host, ask);
  }

  /// The profiles such a host lends, all of them (`{id, version, name, profile, email}` each): each placed as a copy
  /// borrowed from it; one it no longer lends taken away.
  hostProfiles(host: string, given: unknown) {
    if (!Array.isArray(given)) throw new Error("profiles must be a list");
    this.hosts.set(host, this.hosts.get(host) ?? null);
    const state = this.readState();
    const ids = new Set<string>();
    for (const share of given as Json[]) {
      const id = String(share?.id ?? "");
      if (!/^sh-[0-9a-z]{10,40}$/.test(id)) throw new Error("bad share id");
      ids.add(id);
      const had = state.borrowed[id];
      if (had && had.host !== host) throw new Error("that share is another station's");
      const version = Number(share?.version ?? 0);
      if (had && had.version === version) continue;
      const next: Borrowed = { version, hash: "", kind: "profile", name: String(share?.name ?? id), host, allow: null };
      this.placeProfile(id, next, share);
      state.borrowed[id] = next;
    }
    for (const [id, had] of Object.entries(state.borrowed)) {
      if (had.host !== host || ids.has(id)) continue;
      this.drop(id, had);
      delete state.borrowed[id];
    }
    this.writeState(state);
    this.deps.changed();
  }

  private me(): string | null {
    return this.deps.cloud.state?.station ?? null;
  }

  /// The workspace's other stations, as the cloud said last (null: not known now).
  private peers(): string[] | null {
    const cloud = this.deps.cloud;
    if (!cloud.peersCurrent || cloud.state === null) return null;
    const me = this.me();
    return (cloud.state.peers ?? []).flatMap((p: any) => (typeof p?.id === "string" && p.id !== me ? [p.id as string] : []));
  }

  private mayUse(allow: string[] | null, station: string): boolean {
    return allow === null || allow.includes(station);
  }

  // ── state ──

  /// The one copy of state.json in memory (read at the first use): every change is made to it and written through, so
  /// a request answered while the shares are brought in line changes the same one.
  private state: State | null = null;

  private readState(): State {
    if (this.state) return this.state;
    try {
      const s = JSON.parse(readFileSync(join(this.root, "state.json"), "utf8"));
      this.state = { hosted: isObject(s.hosted) ? s.hosted : {}, borrowed: isObject(s.borrowed) ? s.borrowed : {}, moved: isObject(s.moved) ? s.moved : {} };
    } catch {
      this.state = { hosted: {}, borrowed: {}, moved: {} };
    }
    return this.state;
  }

  private writeState(_s: State = this.readState()) {
    mkdirSync(this.root, { recursive: true });
    writePrivate(join(this.root, "state.json"), JSON.stringify(this.readState(), null, 2));
  }

  private profiles(): Json[] {
    const raw = this.deps.config.raw();
    return Array.isArray(raw?.profiles) ? raw.profiles : [];
  }

  private home(p: Json): string {
    const home = String(p.home ?? `homes/${p.id}`);
    // Relative to the data directory unless rooted (as each machine roots paths: C:\… on Windows).
    return joinPath(this.deps.data, home);
  }

  private skillsDir(): string {
    return join(this.deps.agentHome(), "skills");
  }

  /// The skills this station shares: name → id and who may use it (an id alone: every station).
  private sharedSkills(): Record<string, { id: string; allow: string[] | null }> {
    const s = this.deps.config.raw()?.sharedSkills;
    if (!isObject(s)) return {};
    const out: Record<string, { id: string; allow: string[] | null }> = {};
    for (const [name, v] of Object.entries(s)) {
      if (typeof v === "string") out[name] = { id: v, allow: null };
      else if (isObject(v) && typeof v.id === "string") out[name] = { id: v.id, allow: Array.isArray(v.allow) ? v.allow : null };
    }
    return out;
  }

  /// What this station shares now, by id: what it is, who may use it, its content's hash (null: unreadable now).
  private ownShares(): Map<string, { kind: ShareKind; name: string; allow: string[] | null; hash: string | null; profile?: Json; skill?: string }> {
    const out = new Map<string, { kind: ShareKind; name: string; allow: string[] | null; hash: string | null; profile?: Json; skill?: string }>();
    for (const p of this.profiles()) {
      if (!isObject(p.share) || p.share.borrowed === true || typeof p.share.id !== "string") continue;
      out.set(p.share.id, { kind: "profile", name: String(p.name ?? p.id), allow: Array.isArray(p.share.allow) ? p.share.allow : null, hash: hashOf(portable(p)), profile: p });
    }
    for (const [name, { id, allow }] of Object.entries(this.sharedSkills())) {
      const dir = join(this.skillsDir(), name);
      let hash: string | null = null;
      try {
        hash = skillHash(readSkill(dir));
      } catch (e) {
        log.warn("share", "a shared skill could not be read", { name, error: (e as Error).message });
      }
      out.set(id, { kind: "skill", name, allow, hash, skill: name });
    }
    return out;
  }

  // ── running ──

  start() {
    this.stops.push(this.deps.cloud.listen(() => this.reconcile()));
    this.stops.push(this.deps.config.listen(() => this.reconcile()));
    this.reconcile();
  }

  async close() {
    for (const stop of this.stops.splice(0)) stop();
    for (const w of this.watchers.values()) w.close();
    this.watchers.clear();
    await this.time.close();
  }

  /// Brings what is here in line with what is configured and what the hosts say: one at a time, again if asked meanwhile.
  reconcile(): Promise<void> {
    if (this.reconciling) {
      this.again = true;
      return this.reconciling;
    }
    this.reconciling = (async () => {
      do {
        this.again = false;
        try {
          await this.reconcileOnce();
        } catch (e) {
          log.warn("share", "bringing shares in line failed", { error: (e as Error).message });
        }
      } while (this.again);
    })().finally(() => (this.reconciling = null));
    return this.reconciling;
  }

  private async reconcileOnce() {
    const me = this.me();
    if (me === null || this.deps.cloud.removed()) return;
    const peers = this.peers();
    const state = this.readState();
    let pending = false;
    const silent = new Set(this.unreachable.keys());
    const tell = async (peer: string, request: Json): Promise<boolean> => {
      try {
        await this.ask(peer, request);
        return true;
      } catch {
        pending = true;
        return false;
      }
    };

    // What this station shares: its version raised when what it is changed, each station that may use it told
    // (again, one that did not answer), one that no longer may told so.
    const own = this.ownShares();
    for (const [id, now] of own) {
      if (now.kind === "skill") this.watchHosted(now.skill!, join(this.skillsDir(), now.skill!));
      if (now.hash === null) continue;
      const was = state.hosted[id];
      const hosted: Hosted = was ?? { version: 0, hash: "", kind: now.kind, name: now.name, allow: now.allow, told: {} };
      if (hosted.hash !== now.hash) {
        hosted.version += 1;
        hosted.hash = now.hash;
      }
      hosted.allow = now.allow;
      hosted.name = now.name;
      state.hosted[id] = hosted;
      // Written before anyone is told, so what they ask for is that version.
      this.writeState();
      if (peers === null) continue;
      for (const peer of peers) {
        if (this.mayUse(now.allow, peer)) {
          if (hosted.told[peer] === hosted.version) continue;
          if (await tell(peer, { method: "share.changed", id, kind: now.kind, name: now.name, version: hosted.version, allow: now.allow })) hosted.told[peer] = hosted.version;
        } else if (peer in hosted.told) {
          if (await tell(peer, { method: "share.changed", id, gone: true })) delete hosted.told[peer];
        }
      }
      // Stations gone from the workspace: forgotten.
      for (const peer of Object.keys(hosted.told)) if (!peers.includes(peer)) delete hosted.told[peer];
    }
    // No longer shared: each station told is told so, then it is forgotten.
    for (const [id, hosted] of Object.entries(state.hosted)) {
      if (own.has(id)) continue;
      for (const peer of Object.keys(hosted.told)) {
        if (peers !== null && !peers.includes(peer)) delete hosted.told[peer];
        else if (await tell(peer, { method: "share.changed", id, gone: true })) delete hosted.told[peer];
      }
      if (Object.keys(hosted.told).length === 0) delete state.hosted[id];
    }
    // Handed to another station: the stations told of it hear where it went.
    for (const [id, moved] of Object.entries(state.moved)) {
      const left: string[] = [];
      for (const peer of moved.tell) {
        if (peer === moved.to || (peers !== null && !peers.includes(peer))) continue;
        if (!(await tell(peer, { method: "share.changed", id, host: moved.to }))) left.push(peer);
      }
      if (left.length === 0) delete state.moved[id];
      else moved.tell = left;
    }

    // What this station uses of others': fetched when its host said it changed, asked once a run, and taken away when
    // its host is gone from the workspace.
    for (const [id, had] of Object.entries(state.borrowed)) {
      if (this.hosts.has(had.host)) continue;
      if (peers !== null && !peers.includes(had.host)) {
        log.info("share", "the station a share was from left the workspace; its copy is taken away", { id, host: had.host });
        this.drop(id, had);
        delete state.borrowed[id];
        continue;
      }
      if (!had.stale && !had.pending && this.checked.has(id)) continue;
      try {
        if (had.pending && had.kind === "skill") await this.sendSkillEdit(id, had);
        if (!had.stale) {
          const now = await this.ask(had.host, { method: "share.version", id });
          this.unreachable.delete(had.host);
          if (typeof now?.moved === "string") {
            had.host = now.moved;
            had.stale = true;
          } else if (now?.version === had.version) {
            this.checked.add(id);
            continue;
          }
        }
        const got = await this.ask(had.host, { method: "share.get", id });
        this.unreachable.delete(had.host);
        if (had.kind === "profile") this.placeProfile(id, had, got);
        else this.placeSkill(id, had, got);
        had.version = Number(got?.version ?? 0);
        had.allow = Array.isArray(got?.allow) ? got.allow : null;
        had.stale = false;
        this.checked.add(id);
      } catch (e) {
        pending = true;
        this.unreachable.set(had.host, this.time.now());
        log.info("share", "a share could not be had from its host", { id, host: had.host, error: (e as Error).message });
      }
    }
    // Hosts of borrowed subscriptions that did not answer: asked whether they do now.
    for (const host of [...this.unreachable.keys()]) {
      const borrowed = this.profiles().find((p) => this.borrowedSubscription(p) && p.share.host === host);
      if (!borrowed) {
        this.unreachable.delete(host);
        continue;
      }
      try {
        await this.ask(host, { method: "share.status", id: borrowed.share.id });
        this.unreachable.delete(host);
      } catch {
        pending = true;
      }
    }
    if ([...silent].some((h) => !this.unreachable.has(h))) this.deps.recheck?.();
    this.writeState(state);
    this.linkBorrowedSkills(state);
    // What did not get through is tried again, less often the longer it does not.
    if (!pending) this.retryMs = RETRY_MS;
    else if (this.retry === null) {
      const wait = this.retryMs;
      this.retryMs = Math.min(this.retryMs * 2, RETRY_MAX_MS);
      this.retry = this.time.after(wait, () => {
        this.retry = null;
        void this.reconcile();
      });
    }
    this.deps.changed();
  }

  // ── copies of others' shares ──

  private placeProfile(id: string, had: Borrowed, got: Json) {
    const given = isObject(got?.profile) ? got.profile : null;
    if (!given) throw new Error("the host sent no profile");
    this.deps.config.update((raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const at = list.findIndex((p) => isObject(p?.share) && p.share.id === id);
      // One kept from before (a station that handed it over keeps its id and home: its chats go on with it).
      const local = at >= 0 ? String(list[at].id) : id;
      const home = at >= 0 && typeof list[at].home === "string" ? list[at].home : `homes/${id}`;
      const made: Json = { ...portable(given), id: local, home, share: { id, borrowed: true, host: had.host } };
      if (typeof got.email === "string") made.share.email = got.email;
      if (!isObject(made.env)) made.env = {};
      if (at >= 0) list[at] = made;
      else list.push(made);
      raw.profiles = list;
    });
    const placed = this.profiles().find((p) => isObject(p.share) && p.share.id === id);
    if (placed) mkdirSync(this.home(placed), { recursive: true });
  }

  private mirror(id: string) {
    return join(this.root, id, "skill");
  }

  private placeSkill(id: string, had: Borrowed, got: Json) {
    if (!isObject(got?.files)) throw new Error("the host sent no files");
    this.stopWatch(`borrowed:${id}`);
    writeSkill(this.mirror(id), got.files);
    had.hash = String(got.hash ?? "");
  }

  /// A copy taken away: its profile, or its skill's link and files.
  private drop(id: string, had: Borrowed) {
    if (had.kind === "profile") {
      this.deps.config.update((raw) => {
        raw.profiles = (Array.isArray(raw.profiles) ? raw.profiles : []).filter((p: Json) => !(isObject(p?.share) && p.share.id === id && p.share.borrowed === true));
      });
      return;
    }
    this.stopWatch(`borrowed:${id}`);
    const link = join(this.skillsDir(), had.name);
    try {
      if (lstatSync(link).isSymbolicLink() && readlinkSync(link) === this.mirror(id)) unlinkSync(link);
    } catch {}
    rmSync(join(this.root, id), { recursive: true, force: true });
  }

  /// Each copied skill linked into the agents' skills under its name, unless one of this station's own has it; edits to
  /// the copy followed.
  private linkBorrowedSkills(state: State) {
    for (const [id, had] of Object.entries(state.borrowed)) {
      if (had.kind !== "skill") continue;
      const target = this.mirror(id);
      if (!existsSync(target)) continue;
      const link = join(this.skillsDir(), had.name);
      try {
        const meta = lstatSync(link);
        if (!meta.isSymbolicLink() || readlinkSync(link) !== target) continue;
      } catch {
        mkdirSync(this.skillsDir(), { recursive: true });
        // Where links are refused, a junction will do: its target is the copy's own directory, which stays where it is.
        linkSync(target, link, { junction: true });
      }
      this.watchBorrowed(id, target);
    }
  }

  /// Whether a copied skill shows under its name here (one of this station's own of that name wins).
  private skillLinked(id: string, name: string): boolean {
    try {
      const link = join(this.skillsDir(), name);
      return lstatSync(link).isSymbolicLink() && readlinkSync(link) === this.mirror(id);
    } catch {
      return false;
    }
  }

  // ── edits followed ──

  private stopWatch(key: string) {
    this.watchers.get(key)?.close();
    this.watchers.delete(key);
  }

  private watchDir(key: string, dir: string, then: () => void) {
    if (this.watchers.has(key) || !existsSync(dir)) return;
    try {
      const w = watch(dir, { recursive: true, persistent: false }, () => {
        this.settle.get(key)?.();
        this.settle.set(key, this.time.after(SETTLE_MS, () => (this.settle.delete(key), then())));
      });
      this.watchers.set(key, w);
    } catch (e) {
      log.warn("share", "a shared skill's directory cannot be followed", { dir, error: (e as Error).message });
    }
  }

  private watchHosted(name: string, dir: string) {
    this.watchDir(`hosted:${name}`, dir, () => void this.reconcile());
  }

  private watchBorrowed(id: string, dir: string) {
    this.watchDir(`borrowed:${id}`, dir, () => {
      const state = this.readState();
      const had = state.borrowed[id];
      if (!had) return;
      let files: Record<string, Buffer>;
      try {
        files = readSkill(dir);
      } catch {
        return;
      }
      if (skillHash(files) === had.hash) return;
      had.pending = true;
      this.writeState(state);
      void this.reconcile();
    });
  }

  /// An edit made to a copied skill, sent to its host on the version it was made on.
  private async sendSkillEdit(id: string, had: Borrowed) {
    const files = readSkill(this.mirror(id));
    const answer = await this.ask(had.host, { method: "share.put", id, base: had.version, files: encodeFiles(files) });
    had.pending = false;
    had.hash = skillHash(files);
    if (typeof answer?.version === "number") had.version = answer.version;
    // On an older copy: the host's is fetched, the edit beside it.
    if (answer?.conflict === true) had.stale = true;
  }

  // ── what others ask (share.*) ──

  /// A request of another station of the workspace (the transport checked it is one).
  async handle(peer: string, request: Json): Promise<Json> {
    const method = String(request?.method ?? "");
    const id = String(request?.id ?? "");
    if (method === "share.changed") return this.heard(peer, id, request);
    if (method === "share.take") return this.take(peer, request);
    const state = this.readState();
    const moved = state.moved[id];
    if (moved && method === "share.version") return { moved: moved.to };
    const own = this.ownShares().get(id);
    if (!own) throw new Error("this station does not share that");
    if (!this.mayUse(own.allow, peer)) throw new Error("that share is not for this station");
    const version = state.hosted[id]?.version ?? 0;
    if (method === "share.version") return { version };
    if (own.kind === "profile") {
      const p = own.profile!;
      if (method === "share.get") {
        // It has a copy now: it is told when this one changes.
        this.told(id, peer, version);
        return { version, profile: portable(p), email: accessKind(p) === "subscription" ? this.emailOf(p) : null, allow: own.allow };
      }
      if (method === "share.lend") {
        if (this.moving.has(id)) throw new Error("the login is being moved to another station");
        return this.lend(p);
      }
      if (method === "share.status") return this.deps.status(p.id);
    } else {
      const dir = join(this.skillsDir(), own.skill!);
      if (method === "share.get") {
        const files = readSkill(dir);
        this.told(id, peer, version);
        return { version, hash: skillHash(files), files: encodeFiles(files), allow: own.allow };
      }
      if (method === "share.put") return this.takeEdit(peer, id, own.skill!, dir, request);
    }
    throw new Error(`unknown share request ${method}`);
  }

  /// Notes that a station has a share at a version (it has fetched it).
  private told(id: string, peer: string, version: number) {
    const state = this.readState();
    const hosted = state.hosted[id];
    if (!hosted) return;
    hosted.told[peer] = version;
    this.writeState(state);
  }

  /// What a host says of one of its shares: there, changed, no longer for this station, or moved to another station.
  private heard(peer: string, id: string, request: Json): Json {
    if (!/^sh-[0-9a-z]{10,40}$/.test(id)) throw new Error("bad share id");
    const state = this.readState();
    const had = state.borrowed[id];
    // From another station than the one it was had from: that one handed it over (its word on where may come later).
    if (had && had.host !== peer && request.gone !== true && typeof request.host !== "string") {
      had.host = peer;
      had.stale = true;
    }
    if (had && had.host !== peer) throw new Error("only the station that has it says so");
    if (request.gone === true) {
      if (had) {
        this.drop(id, had);
        delete state.borrowed[id];
      }
    } else if (typeof request.host === "string") {
      if (had) {
        had.host = request.host;
        had.stale = true;
      }
    } else if (!had || had.version !== request.version) {
      const kind: ShareKind = request.kind === "skill" ? "skill" : "profile";
      const name = String(request.name ?? id);
      if (kind === "skill" && !/^[A-Za-z0-9._-]+$/.test(name)) throw new Error("bad skill name");
      state.borrowed[id] = { ...(had ?? { version: -1, hash: "" }), kind, name, host: peer, allow: Array.isArray(request.allow) ? request.allow : null, stale: true };
    }
    this.writeState(state);
    void this.reconcile();
    return { heard: true };
  }

  private emailOf(p: Json): string | null {
    if (typeof p.share?.email === "string") return p.share.email;
    const home = this.home(p);
    if (p.runtime === "codex") {
      try {
        const auth = JSON.parse(readFileSync(join(home, "auth.json"), "utf8"));
        const claims = JSON.parse(Buffer.from(String(auth?.tokens?.id_token ?? "").split(".")[1] ?? "", "base64url").toString("utf8"));
        const email = claims?.email ?? claims?.["https://api.openai.com/profile"]?.email;
        return typeof email === "string" ? email : null;
      } catch {
        return null;
      }
    }
    for (const file of [join(home, ".claude.json"), join(home, "claude.json")]) {
      try {
        const email = JSON.parse(readFileSync(file, "utf8"))?.oauthAccount?.emailAddress;
        if (typeof email === "string") return email;
      } catch {}
    }
    return null;
  }

  /// An edit from a station that copies a skill: taken when made on the current version; else kept beside it.
  private takeEdit(peer: string, id: string, name: string, dir: string, request: Json): Json {
    const state = this.readState();
    const hosted = state.hosted[id];
    const version = hosted?.version ?? 0;
    const files: Record<string, string> = isObject(request.files) ? request.files : {};
    let size = 0;
    for (const [path, data] of Object.entries(files)) {
      if (!safePath(path) || typeof data !== "string") throw new Error("bad file in a skill edit");
      size += Buffer.byteLength(data, "base64");
    }
    if (size > MAX_SKILL_BYTES) throw new Error("the skill is too large to share");
    let conflict = false;
    if (request.base === version) {
      writeSkill(dir, files);
    } else {
      conflict = true;
      const skill = files["SKILL.md"];
      if (typeof skill === "string") writeFileSync(join(dir, `SKILL.conflict-${peer.slice(0, 12)}.md`), Buffer.from(skill, "base64"));
    }
    const next = version + 1;
    if (hosted) {
      hosted.version = next;
      hosted.hash = skillHash(readSkill(dir));
      // The station that sent it has it (unless it conflicted); the others are told.
      if (!conflict) hosted.told[peer] = next;
    }
    this.writeState(state);
    log.info("share", conflict ? "a skill edit on an older copy kept beside it" : "a skill edit taken", { name, from: peer });
    void this.reconcile();
    return { version: next, conflict };
  }

  /// A short-lived access token of a shared subscription, renewed here when needed.
  private async lend(p: Json): Promise<Json> {
    if (accessKind(p) !== "subscription") throw new Error("only a subscription is lent");
    if (isMachine(p) && this.deps.machineAllowed?.(p.runtime) === false) throw new Error("the machine's own login is not in use");
    if (p.runtime === "claude") {
      const t = await this.deps.claudeToken(p);
      return { runtime: "claude", token: t.token, expiresAt: t.expiresAt };
    }
    const file = isMachine(p) ? codexAuthFile(this.deps.env) : join(this.home(p), "auth.json");
    let auth = JSON.parse(readFileSync(file, "utf8"));
    let expiresAt = jwtExpiry(auth?.tokens?.access_token) ?? 0;
    if (expiresAt - this.time.now() < CODEX_LEND_MS && !this.deps.codexRunning(p.id)) {
      try {
        auth = await this.renewCodex(file, auth);
        expiresAt = jwtExpiry(auth?.tokens?.access_token) ?? 0;
      } catch (e) {
        log.warn("share", "renewing a shared Codex login failed", { profile: p.id, error: (e as Error).message });
      }
    }
    if (expiresAt - this.time.now() < CODEX_MIN_MS) throw new Error("the Codex login here runs out soon and cannot be renewed now");
    const tokens = auth.tokens ?? {};
    return { runtime: "codex", tokens: { id_token: tokens.id_token, access_token: tokens.access_token, account_id: tokens.account_id }, expiresAt };
  }

  /// Codex's own renewal of its ChatGPT login, done here while no Codex runs on it (it would hold the old refresh token).
  private async renewCodex(file: string, auth: Json): Promise<Json> {
    const refresh = auth?.tokens?.refresh_token;
    if (typeof refresh !== "string" || refresh === "") throw new Error("no refresh token");
    const response = await fetch(this.deps.codexTokenUrl ?? CODEX_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: CODEX_CLIENT_ID, grant_type: "refresh_token", refresh_token: refresh, scope: "openid profile email" }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`the token endpoint answered ${response.status}`);
    const got = await response.json();
    const next = structuredClone(auth);
    next.tokens = { ...next.tokens };
    for (const k of ["id_token", "access_token", "refresh_token"]) if (typeof got?.[k] === "string") next.tokens[k] = got[k];
    next.last_refresh = new Date(this.time.now()).toISOString();
    writePrivate(file, JSON.stringify(next, null, 2));
    return next;
  }

  // ── borrowing (the agents' drivers) ──

  /// Whether a profile is a copy of another station's subscription (its login borrowed for each process).
  borrowedSubscription(profile: Json): boolean {
    return isObject(profile?.share) && profile.share.borrowed === true && accessKind(profile) === "subscription";
  }

  private hostOf(profile: Json): string {
    const host = profile?.share?.host;
    if (typeof host !== "string") throw new Error("this profile is not borrowed from another station");
    return host;
  }

  /// A borrowed Claude subscription's token, from its host.
  async lendClaude(profile: Json): Promise<MachineToken> {
    const host = this.hostOf(profile);
    try {
      const got = await this.ask(host, { method: "share.lend", id: profile.share.id });
      this.unreachable.delete(host);
      if (typeof got?.token !== "string") throw new Error("the host lent no token");
      return { token: got.token, expiresAt: Number(got.expiresAt ?? 0) };
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      this.deps.changed();
      throw new Error(`the station this subscription is signed in on did not lend it: ${(e as Error).message}`);
    }
  }

  /// A borrowed Codex subscription: its home's auth.json written with the host's current tokens (no refresh token, so
  /// Codex never renews it here); when they run out.
  async lendCodex(profile: Json): Promise<number> {
    const host = this.hostOf(profile);
    let got: Json;
    try {
      got = await this.ask(host, { method: "share.lend", id: profile.share.id });
      this.unreachable.delete(host);
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      this.deps.changed();
      throw new Error(`the station this subscription is signed in on did not lend it: ${(e as Error).message}`);
    }
    const auth = {
      auth_mode: "chatgpt",
      OPENAI_API_KEY: null,
      tokens: { ...got.tokens, refresh_token: "lent-by-another-station" },
      last_refresh: new Date(this.time.now()).toISOString(),
    };
    const home = this.home(profile);
    mkdirSync(home, { recursive: true });
    writePrivate(join(home, "auth.json"), JSON.stringify(auth, null, 2));
    return Number(got.expiresAt ?? 0);
  }

  /// A borrowed profile's check and allowance, as its host has them.
  async status(profile: Json): Promise<{ check: Json; quota: Json }> {
    const host = this.hostOf(profile);
    try {
      const got = await this.ask(host, { method: "share.status", id: profile.share.id });
      this.unreachable.delete(host);
      return { check: got?.check ?? null, quota: got?.quota ?? null };
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      throw e;
    }
  }

  // ── what the pages ask (this station hosting) ──

  /// A profile shared (with who may use it: null, every station), its stations changed, or no longer shared.
  async shareProfile(profileId: string, on: boolean, allow: string[] | null) {
    const p = this.profiles().find((x) => x.id === profileId);
    if (!p) throw new Error(`unknown profile ${profileId}`);
    if (isObject(p.share) && p.share.borrowed === true) throw new Error("this profile is another station's");
    const had = isObject(p.share) && typeof p.share.id === "string" ? (p.share.id as string) : null;
    this.deps.config.update((raw) => {
      for (const x of raw.profiles ?? []) {
        if (x.id !== profileId) continue;
        if (on) x.share = { id: had ?? newId(), allow };
        else delete x.share;
      }
    });
    await this.reconcile();
  }

  /// A skill shared, its stations changed, or no longer shared.
  async shareSkill(name: string, on: boolean, allow: string[] | null) {
    const had = this.sharedSkills()[name]?.id ?? null;
    if (on) {
      const dir = join(this.skillsDir(), name);
      if (lstatSync(dir).isSymbolicLink()) throw new Error("this skill is another station's");
      if (readSkill(dir)["SKILL.md"] === undefined) throw new Error("no SKILL.md in that skill");
    }
    this.deps.config.update((raw) => {
      const skills: Json = isObject(raw.sharedSkills) ? raw.sharedSkills : {};
      if (on) skills[name] = { id: had ?? newId(), allow };
      else delete skills[name];
      raw.sharedSkills = skills;
    });
    if (!on) this.stopWatch(`hosted:${name}`);
    await this.reconcile();
  }

  /// A shared profile moved to another station: this one stops lending, hands the profile and its login over (the other
  /// says it has it), then keeps a copy borrowed from it and tells the stations it had told where it went.
  async moveProfile(profileId: string, to: string) {
    const p = this.profiles().find((x) => x.id === profileId);
    if (!p || !isObject(p.share) || p.share.borrowed === true) throw new Error("only a profile this station shares can be moved");
    if (isMachine(p)) throw new Error("the machine's own login stays on its machine");
    if (to === this.me()) return;
    if (!(this.peers() ?? []).includes(to)) throw new Error("that station is not in the workspace now");
    const id = p.share.id as string;
    const allow: string[] | null = Array.isArray(p.share.allow) ? p.share.allow : null;
    const credentials: Record<string, string> = {};
    const home = this.home(p);
    for (const name of [".credentials.json", ".claude.json", "auth.json"]) {
      try {
        const path = join(home, name);
        if (!lstatSync(path).isSymbolicLink()) credentials[name] = readFileSync(path).toString("base64");
      } catch {}
    }
    const state = this.readState();
    const was = state.hosted[id];
    this.moving.add(id);
    try {
      await this.ask(to, { method: "share.take", id, profile: { ...portable(p), ...(typeof p.key === "string" ? { key: p.key } : {}) }, email: this.emailOf(p), credentials, allow, version: (was?.version ?? 0) + 1 });
    } catch (e) {
      this.moving.delete(id);
      throw e;
    }
    // Ours no more: the login forgotten (the new host renews it now), the profile kept as a copy under the same id.
    for (const name of Object.keys(credentials)) rmSync(join(home, name), { force: true });
    const email = this.emailOf(p);
    this.deps.config.update((raw) => {
      for (const x of raw.profiles ?? []) if (x.id === profileId) x.share = { id, borrowed: true, host: to, ...(email ? { email } : {}) };
    });
    const after = this.readState();
    delete after.hosted[id];
    after.borrowed[id] = { version: (was?.version ?? 0) + 1, hash: "", kind: "profile", name: String(p.name ?? p.id), host: to, allow };
    after.moved[id] = { to, tell: Object.keys(was?.told ?? {}) };
    this.writeState(after);
    this.moving.delete(id);
    log.info("share", "a shared profile moved to another station", { profile: profileId, to });
    await this.reconcile();
  }

  /// A profile handed over by the station that has it (one this station borrows it from, or any station of the
  /// workspace for one not seen here).
  private take(peer: string, request: Json): Json {
    const id = String(request?.id ?? "");
    if (!/^sh-[0-9a-z]{10,40}$/.test(id)) throw new Error("bad share id");
    const state = this.readState();
    const had = state.borrowed[id];
    if (had && had.host !== peer) throw new Error("only the station that has it can hand it over");
    if (this.ownShares().has(id)) return { taken: true };
    const given = isObject(request.profile) ? request.profile : null;
    if (!given) throw new Error("nothing handed over");
    const existing = this.profiles().find((x) => isObject(x.share) && x.share.id === id);
    const localId = existing?.id ?? id;
    const home = join(this.deps.data, "homes", localId);
    mkdirSync(home, { recursive: true });
    for (const [name, data] of Object.entries(isObject(request.credentials) ? request.credentials : {})) {
      if (![".credentials.json", ".claude.json", "auth.json"].includes(name) || typeof data !== "string") continue;
      const path = join(home, name);
      try {
        if (lstatSync(path).isSymbolicLink()) unlinkSync(path);
      } catch {}
      writePrivate(path, Buffer.from(data, "base64"));
    }
    const allow = Array.isArray(request.allow) ? request.allow : null;
    this.deps.config.update((raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const made: Json = { ...portable(given), ...(typeof given.key === "string" ? { key: given.key } : {}), id: localId, home: `homes/${localId}`, share: { id, allow } };
      if (!isObject(made.env)) made.env = {};
      const at = list.findIndex((x) => x.id === localId);
      if (at >= 0) list[at] = made;
      else list.push(made);
      raw.profiles = list;
    });
    const after = this.readState();
    delete after.borrowed[id];
    // The station that handed it over keeps a copy, at this version.
    const version = Number(request.version ?? 1);
    const p = this.profiles().find((x) => x.id === localId);
    after.hosted[id] = { version, hash: p ? hashOf(portable(p)) : "", kind: "profile", name: String(given.name ?? localId), allow, told: { [peer]: version } };
    this.writeState(after);
    log.info("share", "a shared profile handed over to this station", { id, from: peer });
    void this.reconcile();
    return { taken: true };
  }

  // ── the overview ──

  /// What the overview says of a profile's sharing (null: not shared).
  profileView(p: Json): ShareView | null {
    if (!isObject(p?.share) || typeof p.share.id !== "string") return null;
    const id = p.share.id as string;
    if (p.share.borrowed === true) {
      const host = String(p.share.host ?? "");
      const had = this.readState().borrowed[id];
      return { id, role: "user", host, allow: had?.allow ?? null, reachable: !this.unreachable.has(host) };
    }
    const told = this.readState().hosted[id]?.told ?? {};
    return { id, role: "host", host: this.me() ?? "", allow: Array.isArray(p.share.allow) ? p.share.allow : null, reachable: null, users: Object.entries(told).filter(([, v]) => v >= 0).map(([k]) => k) };
  }

  /// What the memory page says of a skill's sharing (null: not shared): by its name in the agents' skills.
  skillView(name: string): ShareView | null {
    const hosted = this.sharedSkills()[name];
    if (hosted) return { id: hosted.id, role: "host", host: this.me() ?? "", allow: hosted.allow, reachable: null };
    for (const [id, had] of Object.entries(this.readState().borrowed)) {
      if (had.kind !== "skill" || had.name !== name || !this.skillLinked(id, name)) continue;
      return { id, role: "user", host: had.host, allow: had.allow, reachable: !this.unreachable.has(had.host) };
    }
    return null;
  }
}

export const sharedSkillConflicts = (dir: string): string[] => {
  try {
    return readdirSync(dir).filter((n) => /^SKILL\.conflict-.*\.md$/.test(n));
  } catch {
    return [];
  }
};
