// Jobs on other stations of the workspace (the Rust station's remote.rs, where they were remote tasks). Workspace peers
// call named operations over an authenticated station transport (`stillfail/station/1`, the mesh layer's); shell jobs
// (`job.*`) are one service on it, never an admin API proxy. An administrator explicitly trusts source station keys in
// config.json: remoteJobs.allow = ["<station public key>"] (remoteTasks.allow, its old name, is read too). This grants
// shell execution as the station's OS user, not a sandbox. A source session's jobs share one working directory on the
// target (remote/sessions/<id>/work). The source asks for it to be removed when the session is archived or deleted; the
// target removes it itself after IDLE_MS unused.
//
// A record names the workspace by its first id (cloud/state.ts `workspaceKey`), and so do the requests between
// stations: the control plane telling the workspace by a new id changes neither.
//
// The records are the Rust's files, written the same way (remote/incoming/<id>/task.json, sessions/<id>/session.json,
// outgoing/<id>.json, used/<id>.json), so either station reads what the other wrote. What asks other machines (a
// job's state every 5 s, a closed session's stations every 60 s) and the hourly sweep are Effect schedules; nothing
// here polls local state.
import { createHash, randomBytes } from "node:crypto";
import {
  closeSync, constants, existsSync, fstatSync, fsyncSync, ftruncateSync, linkSync, lstatSync, mkdirSync, openSync, readFileSync,
  readSync, readdirSync, renameSync, rmSync, statSync, writeSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join } from "node:path";
import { relativeParts } from "../ops/paths.ts";
import { platform } from "../platform/index.ts";
import { isDeepStrictEqual } from "node:util";
import { Clock, Effect, Exit, FiberSet, Schedule, Scope } from "effect";
import { log } from "../ops/log.ts";
import { type Json, type Store } from "../store/store.ts";
import { workspaceKey } from "../cloud/state.ts";
import { type Jobs, jobJson, tail } from "./jobs.ts";

/// The answer of a peer that refused a request (its `{"error": …}`): final, unlike a request that did not get through.
export class Refused extends Error {}

/// A request that could not reach the other station at all (it is not connected, or not in the workspace now): not
/// asked, rather than asked and not answered.
export class Unreachable extends Error {}

/// A request to another station of the workspace over the station transport: its result, a Refused when that station
/// answered with an error, any other error when it could not be asked (or the answer did not come). `workspace` is the
/// request's (null for `peers` and `describe`, which the transport answers or checks against its own). Station "" with
/// method `peers` is the transport's roster: {workspace, stations, current}.
export type PeerCall = (station: string, workspace: string | null, request: Json) => Promise<Json>;
/// Takes a message a session of another station sent here (the hub's from_peer): from which station, the request.
export type Inbox = (peer: string, request: Json) => Promise<Json>;
/// Tells a session's agent something; a throw (or rejection) is "not told" (it is told again later).
export type RemoteNotify = (session: string, text: string) => void | Promise<void>;

export const CHUNK = 256 * 1024;
const MAX_FILE = 1024 * 1024 * 1024;
/// A source session's directory unused this long is removed by the target, in case its source never says so.
export const IDLE_MS = 14 * 24 * 3600 * 1000;
/// A source keeps asking an unreachable target to remove a closed session's directory this long.
const CLOSE_FOR_MS = 30 * 24 * 3600 * 1000;
/// How often a source asks about a job it follows, a closed session's stations, and a target sweeps.
const WATCH_EVERY = "5 seconds";
const CLOSE_EVERY = "60 seconds";
const SWEEP_EVERY = "1 hour";

export type RemoteOptions = {
  /// The data directory: remote/ and mesh/cloud.json in it.
  data: string;
  store: Store;
  jobs: Jobs;
  notify: RemoteNotify;
  /// config.json as it is now (remoteJobs.allow, or remoteTasks.allow as it was called).
  config: () => Json;
  /// The clock its schedules run on (a TestClock in tests).
  clock?: Clock.Clock;
};

const text = (v: Json, key: string): string => (v !== null && typeof v === "object" && typeof v[key] === "string" ? v[key] : "");
const field = (v: Json, key: string): Json => (v !== null && typeof v === "object" && !Array.isArray(v) && key in v ? v[key] : null);
const bytes = (s: string) => Buffer.byteLength(s);
const strings = (v: Json): string[] => (Array.isArray(v) ? v.filter((s: Json): s is string => typeof s === "string" && s !== "") : []);
/// serde_json's as_u64.
const asU64 = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);

/// The name a source session, job or record goes by: sha256 of its parts as compact JSON (as serde writes them).
export function hash(v: Json): string {
  return createHash("sha256").update(JSON.stringify(v)).digest("hex");
}

export function readJson(path: string): Json {
  return JSON.parse(readFileSync(path, "utf8"));
}

/// Path::with_extension: the file name's extension replaced (or added).
function withExtension(path: string, ext: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  return join(dirname(path), `${stem}.${ext}`);
}

/// Written whole or not at all: a private temporary file, synced, renamed over.
export function writeJson(path: string, value: Json): void {
  const temp = withExtension(path, `${randomBytes(8).toString("hex")}.tmp`);
  const fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
  try {
    writeSync(fd, Buffer.from(JSON.stringify(value)));
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(temp, path);
}

const isLink = (path: string): boolean => {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
};

/// Relative paths only; transfers must not follow links planted by a job. Job commands themselves are trusted shell
/// execution, so separate working directories are organizational isolation, not an OS security boundary.
export function filePath(root: string, relative: string, create: boolean): string {
  if (lstatSync(root).isSymbolicLink()) throw new Error("transfer root is a symbolic link");
  // Path::components: a leading / is the root (and on Windows a drive, a UNC share or a stream: relativeParts), a
  // leading . is the current directory, a later . is no component.
  const given = relativeParts(relative);
  const parts: string[] = [];
  let bad = given === null;
  (given ?? []).forEach((part, i) => {
    if (part === "") return;
    if (part === ".") {
      if (i === 0) bad = true;
      return;
    }
    parts.push(part);
  });
  if (bad || parts.length === 0) throw new Error("file path must be relative, without . or ..");
  let out = root;
  for (const part of parts) {
    out = join(out, part);
    if (isLink(out)) throw new Error("file path contains a symbolic link");
  }
  if (create) mkdirSync(dirname(out), { recursive: true });
  return out;
}

/// STANDARD base64 as the Rust decodes it: padded, nothing else in it.
function fromBase64(data: string): Buffer {
  if (data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) throw new Error("Invalid input length or symbol");
  return Buffer.from(data, "base64");
}

/// The OS and architecture as Rust's std::env::consts name them.
const OS = platform.os;
const ARCH = ({ arm64: "aarch64", x64: "x86_64", ia32: "x86", arm: "arm" } as Record<string, string>)[process.arch] ?? process.arch;

export class Remote {
  readonly root: string;
  readonly store: Store;
  private data: string;
  private jobs: Jobs;
  private notify: RemoteNotify;
  private config: () => Json;
  private call: PeerCall | null = null;
  private inbox: Inbox | null = null;
  private shares: Inbox | null = null;
  private tasks: Inbox | null = null;
  /// Target-side requests, the sweep and withdrawals, one at a time.
  private serial: Promise<unknown> = Promise.resolve();
  /// The records followed now (outgoing jobs, closing sessions).
  private watching = new Set<string>();
  private scope: Scope.Closeable;
  private run: (effect: Effect.Effect<void>) => Promise<void>;

  constructor(options: RemoteOptions) {
    this.data = options.data;
    this.store = options.store;
    this.jobs = options.jobs;
    this.notify = options.notify;
    this.config = options.config;
    this.root = join(options.data, "remote");
    for (const name of ["incoming", "outgoing", "sessions", "used"]) mkdirSync(join(this.root, name), { recursive: true });
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
  }

  /// The transport is there: follow the jobs started from here and the sessions closing, sweep now and hourly.
  attach(call: PeerCall): void {
    this.call = call;
    for (const name of this.list(join(this.root, "outgoing")).filter((n) => n.endsWith(".json"))) this.watch(join(this.root, "outgoing", name));
    for (const name of this.list(join(this.root, "used")).filter((n) => n.endsWith(".json"))) {
      const path = join(this.root, "used", name);
      try {
        if (field(readJson(path), "closing") === true) this.closer(path);
      } catch {}
    }
    void this.run(
      Effect.promise(() => this.sweep(this.store.now())).pipe(Effect.repeat(Schedule.spaced(SWEEP_EVERY)), Effect.asVoid),
    ).catch(() => undefined);
  }

  /// Its schedules end (the station stops).
  async close(): Promise<void> {
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
  }

  private list(dir: string): string[] {
    try {
      return readdirSync(dir);
    } catch {
      return [];
    }
  }

  private serially<T>(f: () => Promise<T>): Promise<T> {
    const result = this.serial.then(f, f);
    this.serial = result.catch(() => undefined);
    return result;
  }

  room(workspace: string, peer: string, session: string): string {
    return join(this.root, "sessions", hash([workspace, peer, session]));
  }

  /// Makes a source session's shared directory and notes when it was last used (at most once a minute).
  private seen(workspace: string, peer: string, session: string): string {
    const room = this.room(workspace, peer, session);
    mkdirSync(join(room, "work"), { recursive: true });
    const record = join(room, "session.json");
    const now = this.store.now();
    let fresh = false;
    try {
      fresh = now - (asI64(field(readJson(record), "seen")) ?? 0) < 60_000;
    } catch {}
    if (!fresh) writeJson(record, { workspace, station: peer, session, seen: now });
    return join(room, "work");
  }

  /// Job directories (incoming/<id>) of a source session.
  private tasksOf(workspace: string, peer: string, session: string): string[] {
    const incoming = join(this.root, "incoming");
    return this.list(incoming)
      .map((name) => join(incoming, name))
      .filter((dir) => {
        try {
          const m = readJson(join(dir, "task.json"));
          return text(m, "workspace") === workspace && text(m, "station") === peer && text(m, "session") === session;
        } catch {
          return false;
        }
      });
  }

  private jobOf(task: string): string {
    return `remote_${basename(task)}`;
  }

  private running(task: string): boolean {
    return this.store.getJob(this.jobOf(task))?.state === "running";
  }

  /// Stops a source session's jobs and removes their records and its shared directory. Callers hold `serial`.
  private async closeHere(workspace: string, peer: string, session: string): Promise<void> {
    for (const task of this.tasksOf(workspace, peer, session)) {
      if (this.running(task)) await this.jobs.stop(this.jobOf(task));
      rmSync(task, { recursive: true });
    }
    const room = this.room(workspace, peer, session);
    if (existsSync(room)) {
      rmSync(room, { recursive: true });
      log.info("remote", "remote session directory removed", { workspace, station: peer, session });
    }
  }

  /// The target's own cleanup: a source session's directory unused for IDLE_MS, with nothing running, goes; so do job
  /// directories from before shared session directories.
  sweep(now: number): Promise<void> {
    return this.serially(async () => {
      const sessions = join(this.root, "sessions");
      for (const name of this.list(sessions)) {
        let meta: Json;
        try {
          meta = readJson(join(sessions, name, "session.json"));
        } catch {
          continue;
        }
        if (now - (asI64(field(meta, "seen")) ?? now) < IDLE_MS) continue;
        const [workspace, peer, session] = [text(meta, "workspace"), text(meta, "station"), text(meta, "session")];
        if (this.tasksOf(workspace, peer, session).some((t) => this.running(t))) continue;
        try {
          await this.closeHere(workspace, peer, session);
        } catch (error) {
          log.warn("remote", "idle remote session directory not removed", { error: (error as Error).message });
        }
      }
      const incoming = join(this.root, "incoming");
      for (const name of this.list(incoming)) {
        const dir = join(incoming, name);
        const record = join(dir, "task.json");
        let meta: Json;
        try {
          meta = readJson(record);
        } catch {
          continue;
        }
        let modified = now;
        try {
          modified = Math.floor(statSync(record).mtimeMs);
        } catch {}
        if (field(meta, "layout") === "session" || now - modified < IDLE_MS || this.running(dir)) continue;
        rmSync(dir, { recursive: true, force: true });
      }
    });
  }

  usedPath(session: string): string {
    return join(this.root, "used", `${hash(session)}.json`);
  }

  /// The source remembers which stations a session ran jobs on, to ask them to clean up when it closes.
  recordUse(workspace: string, session: string, station: string): void {
    const path = this.usedPath(session);
    let v: Json;
    try {
      v = readJson(path);
    } catch {
      v = { session, workspace, stations: [] };
    }
    const known = Array.isArray(v.stations) && v.stations.some((s: Json) => s === station);
    if (known && v.closing !== true) return;
    if (!known) {
      if (!Array.isArray(v.stations)) throw new Error("bad record");
      v.stations.push(station);
    }
    // Used again after closing (shown again): close later from the start.
    v.closing = false;
    v.closed = [];
    v.workspace = workspace;
    writeJson(path, v);
  }

  /// A session was archived or deleted: its jobs on other stations stop and their directories are removed. Asked until
  /// each station has answered (CLOSE_FOR_MS at most), across restarts.
  closeSession(session: string): void {
    const path = this.usedPath(session);
    let v: Json;
    try {
      v = readJson(path);
    } catch {
      return;
    }
    v.closing = true;
    v.since = this.store.now();
    try {
      writeJson(path, v);
    } catch {
      return;
    }
    // Their directories are going away: stop following this session's jobs.
    const outgoing = join(this.root, "outgoing");
    for (const name of this.list(outgoing)) {
      const file = join(outgoing, name);
      try {
        const entry = readJson(file);
        if (text(entry, "session") === session && entry.delivered !== true) {
          entry.delivered = true;
          writeJson(file, entry);
        }
      } catch {}
    }
    this.closer(path);
  }

  /// Asks each station a closing session used to remove its directory, every minute until all have answered.
  private closer(path: string): void {
    if (this.watching.has(path)) return;
    this.watching.add(path);
    const round = Effect.promise(async (): Promise<boolean> => {
      let v: Json;
      try {
        v = readJson(path);
      } catch {
        return true;
      }
      if (v.closing !== true) return true;
      const closed = Array.isArray(v.closed) ? v.closed : [];
      const pending: string[] = (Array.isArray(v.stations) ? v.stations : []).filter((s: Json) => !closed.includes(s) && typeof s === "string");
      if (pending.length === 0 || this.store.now() - (asI64(v.since) ?? 0) > CLOSE_FOR_MS) {
        try {
          if (readJson(path).closing === true) rmSync(path, { force: true });
        } catch {}
        return true;
      }
      for (const station of pending) {
        const request = { method: "session.close", workspace: field(v, "workspace"), session: field(v, "session") };
        // An answer, or a refusal (a station from before session directories, or one that no longer takes jobs from
        // here), is final; no connection is asked again.
        let done: boolean;
        try {
          await this.ask(station, request);
          done = true;
        } catch (error) {
          done = error instanceof Refused;
        }
        if (done) {
          try {
            const now = readJson(path);
            if (now.closing === true && Array.isArray(now.closed)) {
              now.closed.push(station);
              writeJson(path, now);
            }
          } catch {}
        }
      }
      return false;
    });
    void this.run(
      round.pipe(
        Effect.repeat({ schedule: Schedule.spaced(CLOSE_EVERY), until: (over) => over }),
        Effect.ensuring(Effect.sync(() => this.watching.delete(path))),
        Effect.asVoid,
      ),
    ).catch(() => undefined);
  }

  /// Where messages from other stations' sessions go (session.message): any station of the workspace may send them,
  /// trusted for jobs or not.
  setInbox(inbox: Inbox): void {
    this.inbox = inbox;
  }

  /// Where Tasks' requests go (task.invite/put/post/post_file/hello/file/leave/status, tasks/tasks.ts): any station of the
  /// workspace may send them;
  /// whether its Session takes part in the Task is checked there.
  setTasks(tasks: Inbox): void {
    this.tasks = tasks;
  }

  /// Where requests about what stations share go (share.*, share/index.ts): any station of the workspace may ask;
  /// what each share allows is checked there.
  setShares(shares: Inbox): void {
    this.shares = shares;
  }

  /// A request to another station of the workspace (session_send's messages, and this module's own).
  ask(station: string, request: Json): Promise<Json> {
    const call = this.call;
    if (!call) return Promise.reject(new Unreachable("station mesh is not ready"));
    const workspace = typeof request?.workspace === "string" ? request.workspace : null;
    return call(station, workspace, request);
  }

  allowed(peer: string): boolean {
    const config = this.config();
    return ["remoteJobs", "remoteTasks"].some((name) => {
      const allow = field(field(config, name), "allow");
      return Array.isArray(allow) && allow.some((v) => v === peer);
    });
  }

  /// Called only after the transport authenticates the source station and checks current workspace membership.
  async handle(workspace: string, peer: string, request: Json): Promise<Json> {
    const method = text(request, "method");
    if (method === "describe") {
      return { protocol: 1, os: OS, arch: ARCH, jobs: this.allowed(peer), tasks: this.allowed(peer), taskMessages: true, sessions: true, messages: true, reads: true, fileChunkBytes: CHUNK, maxFileBytes: MAX_FILE };
    }
    if (method.startsWith("share.")) {
      const shares = this.shares;
      if (!shares) throw new Error("station is starting");
      return shares(peer, request);
    }
    // A message or a chat read, not execution: workspace membership (checked by the transport) is enough, as it is for
    // the chats' pages.
    if (method === "session.message" || method === "session.read") {
      const inbox = this.inbox;
      if (!inbox) throw new Error("station is starting");
      return inbox(peer, request);
    }
    if (["task.invite", "task.put", "task.post", "task.post_file", "task.hello", "task.file", "task.leave", "task.status"].includes(method)) {
      const tasks = this.tasks;
      if (!tasks) throw new Error("station is starting");
      return tasks(peer, request);
    }
    if (!this.allowed(peer)) {
      throw new Error("remote jobs are not enabled for this source station; a target administrator must add its public key to remoteJobs.allow");
    }
    // Stations from before Jobs ask with task.* (the same requests).
    const legacy = /^task\.(prepare|start|get|log|stop|list)$/u.exec(method);
    return this.serially(() => this.job(workspace, peer, legacy ? `job.${legacy[1]}` : method, request));
  }

  private async job(workspace: string, peer: string, method: string, request: Json): Promise<Json> {
    const session = text(request, "session");
    if (method === "job.list") {
      if (session === "" || bytes(session) > 256) throw new Error("session is required");
      const jobs: Json[] = [];
      const incoming = join(this.root, "incoming");
      for (const name of readdirSync(incoming)) {
        let meta: Json;
        try {
          meta = readJson(join(incoming, name, "task.json"));
        } catch {
          continue;
        }
        if (text(meta, "workspace") !== workspace || text(meta, "station") !== peer || text(meta, "session") !== session) continue;
        const job = this.store.getJob(`remote_${name}`);
        jobs.push({ key: field(meta, "key"), spec: field(meta, "spec"), job: job ? jobJson(job) : null });
      }
      return { jobs, tasks: jobs };
    }
    if (method === "session.close") {
      if (session === "" || bytes(session) > 256) throw new Error("session is required");
      await this.closeHere(workspace, peer, session);
      return { closed: true };
    }
    const key = text(request, "key");
    if (session === "" || bytes(session) > 256 || key === "" || bytes(key) > 128) {
      throw new Error("session and job key are required (at most 256 / 128 bytes)");
    }
    const id = hash([workspace, peer, session, key]);
    const dir = join(this.root, "incoming", id);
    const record = join(dir, "task.json");
    const jobId = `remote_${id}`;
    const owner = `remote:${workspace}:${peer}:${session}`;
    if (method === "job.prepare") {
      const spec = field(request, "spec");
      if (text(spec, "command").trim() === "") throw new Error("command is required");
      if (existsSync(record)) {
        if (!isDeepStrictEqual(field(readJson(record), "spec"), spec)) {
          throw new Error("job key already used with different inputs; choose a new key for new work");
        }
      } else {
        mkdirSync(dir, { recursive: true });
        writeJson(record, { spec, workspace, station: peer, session, key, layout: "session" });
      }
      this.seen(workspace, peer, session);
      return { key, prepared: true };
    }
    let meta: Json;
    try {
      meta = readJson(record);
    } catch {
      throw new Error("unknown job");
    }
    const job = this.store.getJob(jobId);
    // Jobs prepared before shared session directories keep their own.
    const work =
      field(meta, "layout") === "session"
        ? method === "job.start" || method === "file.put"
          ? this.seen(workspace, peer, session)
          : join(this.room(workspace, peer, session), "work")
        : join(dir, "work");
    switch (method) {
      case "job.start": {
        const uploads = field(meta, "uploads");
        if (uploads !== null && typeof uploads === "object" && !Array.isArray(uploads) && Object.values(uploads).some((v) => v !== true)) {
          throw new Error("input upload is incomplete; finish it before starting");
        }
        const spec = field(meta, "spec");
        const started = this.jobs.startId(owner, text(spec, "name"), text(spec, "command"), work, null, false, jobId);
        return { key, job: jobJson(started) };
      }
      case "job.get":
      case "job.log": {
        const lines = Math.min(Math.max(asU64(field(request, "lines")) ?? 50, 1), 1000);
        return { key, job: job ? jobJson(job) : null, log: job ? tail(job.log, lines) : null, notices: this.store.jobNotices(jobId, 20) };
      }
      case "job.stop": {
        if (!job) throw new Error("job has not started");
        return { key, job: jobJson(await this.jobs.stop(job.id)) };
      }
      case "file.put": {
        if (job) throw new Error("inputs are immutable after a job starts");
        const offset = asU64(field(request, "offset"));
        if (offset === null) throw new Error("offset is required");
        const data = fromBase64(text(request, "data"));
        if (data.length > CHUNK || offset + data.length > MAX_FILE) throw new Error("file limit exceeded");
        const name = text(request, "path");
        const path = filePath(work, name, true);
        if (meta.uploads === null || typeof meta.uploads !== "object" || Array.isArray(meta.uploads)) meta.uploads = {};
        meta.uploads[name] = false;
        writeJson(record, meta);
        const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o666);
        try {
          const stat = fstatSync(fd);
          if (!stat.isFile()) throw new Error("only regular files can be transferred");
          if (offset > stat.size) throw new Error("file offset leaves a gap");
          for (let at = 0; at < data.length; ) at += writeSync(fd, data, at, data.length - at, offset + at);
          if (field(request, "final") === true) {
            ftruncateSync(fd, offset + data.length);
            fsyncSync(fd);
          }
        } finally {
          closeSync(fd);
        }
        if (field(request, "final") === true) {
          meta.uploads[name] = true;
          writeJson(record, meta);
        }
        return { bytes: data.length };
      }
      case "file.get": {
        if (job?.state === "running") throw new Error("wait for the job to finish before downloading artifacts");
        const path = filePath(work, text(request, "path"), false);
        const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        try {
          const stat = fstatSync(fd);
          if (!stat.isFile()) throw new Error("only regular files can be transferred");
          const size = stat.size;
          if (size > MAX_FILE) throw new Error("file limit exceeded");
          const offset = asU64(field(request, "offset")) ?? 0;
          if (offset > size) throw new Error("offset past end");
          const buffer = Buffer.alloc(CHUNK);
          const n = readSync(fd, buffer, 0, CHUNK, offset);
          return { data: buffer.subarray(0, n).toString("base64"), size, eof: offset + n >= size };
        } finally {
          closeSync(fd);
        }
      }
      default:
        throw new Error(`unsupported peer method: ${method}`);
    }
  }

  /// Removed peers and withdrawn local permissions stop their jobs, without touching any local jobs.
  revoke(workspace: string, peers: string[], membershipCurrent: boolean): Promise<void> {
    return this.serially(async () => {
      const incoming = join(this.root, "incoming");
      for (const name of this.list(incoming)) {
        let meta: Json;
        try {
          meta = readJson(join(incoming, name, "task.json"));
        } catch {
          continue;
        }
        const peer = text(meta, "station");
        if (this.allowed(peer) && (!membershipCurrent || (text(meta, "workspace") === workspace && peers.includes(peer)))) continue;
        const id = `remote_${name}`;
        if (this.store.getJob(id)?.state === "running") {
          try {
            await this.jobs.stop(id);
          } catch {}
        }
      }
    });
  }

  /// The workspace this station is in now (mesh/cloud.json), as its records and requests name it: the first id it
  /// had (cloud/state.ts `workspaceKey`), so a job, its directory and its record are found the same after a rename.
  private workspace(): string {
    const state = readJson(join(this.data, "mesh", "cloud.json"));
    if (field(state, "removed_at") !== null) throw new Error("station was removed from workspace");
    const ws = workspaceKey({ workspace: text(state, "workspace"), workspace_was: strings(field(state, "workspace_was")) });
    if (ws === "") throw new Error("station has no workspace");
    return ws;
  }

  outgoing(workspace: string, session: string, station: string, key: string): string {
    return join(this.root, "outgoing", `${hash([workspace, session, station, key])}.json`);
  }

  /// Follows a job started from here: asks its station every 5 s until it is over, telling its session what it said on
  /// the way and how it ended. Across restarts (the record is a file).
  private watch(path: string): void {
    if (this.watching.has(path)) return;
    this.watching.add(path);
    const round = Effect.promise(async (): Promise<boolean> => {
      let entry: Json;
      try {
        entry = readJson(path);
      } catch {
        return true;
      }
      if (entry.delivered === true) return true;
      const request = { method: "job.get", workspace: field(entry, "workspace"), session: field(entry, "session"), key: field(entry, "key") };
      let result: Json;
      try {
        result = await this.ask(text(entry, "station"), request);
      } catch {
        return false;
      }
      const state = text(field(result, "job"), "state");
      const notices = field(result, "notices");
      const finished = state !== "" && state !== "running";
      if (finished || (Array.isArray(notices) && notices.length > 0 && !isDeepStrictEqual(field(entry, "notices"), notices))) {
        const message = `Remote job ${text(entry, "key")} on ${text(entry, "station")}: ${JSON.stringify(result)}`;
        let told = true;
        try {
          await this.notify(text(entry, "session"), message);
        } catch {
          told = false;
        }
        if (told) {
          entry.notices = notices;
          entry.delivered = finished;
          try {
            writeJson(path, entry);
          } catch {}
        }
      }
      return finished && entry.delivered === true;
    });
    void this.run(
      round.pipe(
        Effect.repeat({ schedule: Schedule.spaced(WATCH_EVERY), until: (over) => over }),
        Effect.ensuring(Effect.sync(() => this.watching.delete(path))),
        Effect.asVoid,
      ),
    ).catch(() => undefined);
  }

  /// What the station_* tools do, as `session`.
  async tool(tool: string, session: string, args: Json): Promise<Json> {
    const row = this.store.getSession(session);
    if (!row) throw new Error("unknown session");
    const station = text(args, "station");
    if (tool === "station_list") return this.ask(station, { method: station === "" ? "peers" : "describe" });
    const key = text(args, "key");
    const listing = tool === "station_job" && field(args, "action") === "list";
    if (station === "" || (key === "" && !listing)) throw new Error("station and key are required (list needs only station)");
    const workspace = this.workspace();
    if (!listing) this.recordUse(workspace, session, station);
    const request: Json = { workspace, session, key };
    if (tool === "station_job") {
      const action = text(args, "action");
      if (!["prepare", "start", "get", "log", "stop", "list"].includes(action)) throw new Error("unknown job action");
      request.method = `job.${action}`;
      request.lines = field(args, "lines");
      request.spec = { name: field(args, "name"), command: field(args, "command"), requestedBy: row.createdBy };
      if (action === "start") {
        // Persist before sending: an uncertain start is still followed after a process restart.
        const path = this.outgoing(workspace, session, station, key);
        let refused = false;
        try {
          refused = readJson(path).refused === true;
        } catch {}
        if (!existsSync(path) || refused) writeJson(path, { workspace, session, station, key, delivered: false });
        this.watch(path);
      }
      try {
        return await this.ask(station, request);
      } catch (error) {
        if (action === "start" && error instanceof Refused) {
          const path = this.outgoing(workspace, session, station, key);
          try {
            const entry = readJson(path);
            entry.delivered = true;
            entry.refused = true;
            writeJson(path, entry);
          } catch {}
        }
        throw error;
      }
    }
    const root = row.workspace;
    const localArg = text(args, "local");
    let relative = localArg;
    if (isAbsolute(localArg)) {
      // Path::strip_prefix: whole components of the session's workspace (as the machine compares them); a `..` left in
      // it is filePath's to refuse.
      const within = platform.paths.relativeIn(root, localArg);
      if (within === null) throw new Error("local file must be inside this session workspace");
      relative = within;
    }
    const direction = text(args, "direction");
    const path = filePath(root, relative, direction === "download");
    request.path = field(args, "path");
    if (direction === "upload") {
      const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        const stat = fstatSync(fd);
        const size = stat.size;
        if (!stat.isFile() || size > MAX_FILE) throw new Error("input must be a regular file of at most 1 GiB");
        let offset = 0;
        for (;;) {
          const chunk = Buffer.alloc(CHUNK);
          const n = readSync(fd, chunk, 0, CHUNK, offset);
          request.method = "file.put";
          request.offset = offset;
          request.data = chunk.subarray(0, n).toString("base64");
          request.final = offset + n === size;
          await this.ask(station, { ...request });
          offset += n;
          if (offset === size) break;
          if (n === 0) throw new Error("input changed while reading");
        }
        return { uploaded: path, bytes: size };
      } finally {
        closeSync(fd);
      }
    }
    if (direction === "download") {
      if (existsSync(path)) throw new Error("local output already exists; choose another path");
      const temp = withExtension(path, `${randomBytes(8).toString("hex")}.part`);
      const fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o666);
      try {
        let size: number;
        try {
          let offset = 0;
          for (;;) {
            request.method = "file.get";
            request.offset = offset;
            const answer = await this.ask(station, { ...request });
            const data = fromBase64(text(answer, "data"));
            if (data.length > CHUNK || offset + data.length > MAX_FILE) throw new Error("invalid file response");
            for (let at = 0; at < data.length; ) at += writeSync(fd, data, at, data.length - at);
            offset += data.length;
            if (field(answer, "eof") === true) {
              fsyncSync(fd);
              size = offset;
              break;
            }
            if (data.length === 0) throw new Error("file transfer made no progress");
          }
        } finally {
          closeSync(fd);
        }
        linkSync(temp, path);
        return { downloaded: path, bytes: size };
      } finally {
        rmSync(temp, { force: true });
      }
    }
    throw new Error("direction must be upload or download");
  }
}

/// serde_json's as_i64.
function asI64(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) ? v : null;
}

/// The target side of the station transport (peer.rs `serve`): a request taken in, its answer as the wire has it
/// (`{"result": …}` or `{"error": "…"}`). The transport checks the peer and its workspace before.
export async function answerPeer(remote: Remote, workspace: string, peer: string, request: Json): Promise<Json> {
  try {
    return { result: await remote.handle(workspace, peer, request) };
  } catch (error) {
    return { error: (error as Error).message };
  }
}
