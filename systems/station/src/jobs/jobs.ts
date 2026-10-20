// Background jobs (the Rust station's jobs.rs): commands a session's agent starts that the station runs and keeps, apart from
// the agent's turns. Each runs in a process group of its own with its output in a log file; the agent hears when it
// ends, and whatever the job says on the way (`stillfail-job notify …`). A job with a port is a web service: kept up
// (started again when it ends, with a growing pause), and seen by the workspace's members through the station's
// /preview. Jobs outlive the station: a restart takes up what still runs, and starts again what does not (the machine
// restarted). They are not run under runners: their own groups and exit files are what lets them outlive it.
//
// Push, not poll: a job this station started is followed by its exit event; one an earlier station started (not its
// child) by its exit file appearing (a watch on jobs/exit), with a look at its leader once a second for the one end
// that writes no file (its shell killed) — Node has no exit event for a process that is not its child.
import { randomBytes } from "node:crypto";
import {
  type FSWatcher, appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readlinkSync, renameSync, rmSync,
  statSync, watch,
} from "node:fs";
import { join, sep } from "node:path";
import { Clock, Effect, Exit, FiberSet, Schedule, Scope } from "effect";
import { log } from "../ops/log.ts";
import { startLasting } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";
import { linkSync } from "../ops/links.ts";
import { outputAt, tail } from "../read/jobs.ts";
import { type JobRow, type Json, type ProcessRow, type Store } from "../store/store.ts";
import { endGroup, groupAlive, pidAlive, signalGroup, stillOurs } from "./group.ts";

export { outputAt, tail };

/// At most this many jobs of one session run at once.
export const MAX_RUNNING = 20;
/// How many lines job_log gives by default.
export const LOG_LINES = 50;
/// How many of a job's notices the pages get with it.
const NOTICES_SHOWN = 20;
/// A service that ran this long before it ended starts again at once; one that keeps ending waits longer each time.
const STEADY_MS = 60_000;
const MAX_PAUSE_MS = 60_000;
/// A job stopped from the pages is told to its agent only if the agent was at work this lately: one idle longer is not
/// woken for it (the job's state shows it stopped when the agent next looks).
const AWAKE_MS = 5 * 60_000;
/// How long a stop waits for a job's group to end before it is killed, and then for its end to be taken in.
const STOP_GRACE_MS = 5000;
const STOP_SETTLE_MS = 3000;
/// How often a stopping job's group is looked at, once its leader is gone, for members it left behind.
const STOP_LOOK_MS = 100;
/// How often a job an earlier station started is looked at (its end when it wrote no exit file).
const FOLLOW_LOOK_MS = 1000;
/// What /jobs/notify takes at most.
export const NOTIFY_BODY_LIMIT = 64 * 1024;

/// How a job's command runs: under a shell that writes its exit code to a file when it ends, so a station that did not
/// start it (it outlived the one that did) still learns how it ended.
export const WRAPPER = `/bin/sh -c "$1"; code=$?; printf '%s' "$code" > "$2"; exit "$code"`;

/// What `stillfail-job` is, in each job's PATH: `stillfail-job notify <words>` (or the words on stdin) tells the agent.
/// `ember-job`, its name before the rename, is a link to it; a job started then has only the EMBER_JOB_* variables.
export const JOB_COMMAND = `#!/bin/sh
# stillfail-job notify <words>: tells the agent that started this job (the words, or stdin's).
token=\${STILLFAIL_JOB_TOKEN:-\${EMBER_JOB_TOKEN:-}}
notify=\${STILLFAIL_JOB_NOTIFY:-\${EMBER_JOB_NOTIFY:-}}
case "$1" in
  notify)
    shift
    if [ "$#" -gt 0 ]; then printf '%s' "$*"; else cat; fi |
      curl -fsS -X POST -H "Authorization: Bearer $token" -H "content-type: text/plain; charset=utf-8" --data-binary @- "$notify" >/dev/null
    ;;
  *) echo "usage: stillfail-job notify <words>" >&2; exit 2 ;;
esac
`;
export const JOB_COMMAND_NAME = "stillfail-job";
const FORMER_JOB_COMMAND_NAME = "ember-job";

/// Tells a session's agent something (the hub's notify).
export type Notify = (session: string, text: string) => void;
/// A session's web service as members open it: its link (still.fail cloud's /o/ link of the session, naming the
/// service), when the station is in a workspace.
export type Link = (session: string, job: string) => string | null;

export type JobsOptions = {
  store: Store;
  /// The data directory: jobs live in its jobs/ (logs/, bin/, exit/).
  data: string;
  notify: Notify;
  link: Link;
  /// The clock its timers run on (a TestClock in tests).
  clock?: Clock.Clock;
};

type Running = {
  pgid: number;
  /// Stopped by request: its end is not news, nor restarted.
  stopping: boolean;
  /// Its leader (the wrapper shell) is gone.
  gone: Promise<void>;
  /// Its end is taken in (off `running`, its record written).
  settled: Promise<void>;
  settle: () => void;
};

const hex = (n: number) => randomBytes(n).toString("hex");

/// JobRow as serde writes it (the token skipped, `sessionKey` as `session`).
export function jobJson(j: JobRow): Json {
  return {
    id: j.id, session: j.sessionKey, name: j.name, command: j.command, cwd: j.cwd, port: j.port, state: j.state, pgid: j.pgid,
    exitCode: j.exitCode, startedAt: j.startedAt, endedAt: j.endedAt, restarts: j.restarts, log: j.log, watch: j.watch,
  };
}

/// A job as the pages show it: its record, what it said lately (newest first) and when its output last grew.
export function shown(store: Store, job: JobRow): Json {
  const v = jobJson(job);
  v.notices = store.jobNotices(job.id, NOTICES_SHOWN);
  v.outputAt = outputAt(job.log);
  return v;
}

/// The watches running, by session: what the pages show of a watching chat's agent (its session's `watch`): the
/// watches' names (oldest first), since when the first runs, when one last gave word (`at`: its latest notice, else its
/// start; a notice is news to the pages, output is not).
export function watching(store: Store): Map<string, { names: string[]; since: number; at: number }> {
  const by = new Map<string, JobRow[]>();
  for (const job of store.listJobs(null).filter((j) => j.watch && j.state === "running")) {
    const list = by.get(job.sessionKey) ?? [];
    list.push(job);
    by.set(job.sessionKey, list);
  }
  const out = new Map<string, { names: string[]; since: number; at: number }>();
  for (const [key, jobs] of by) {
    // A stable sort, as sort_by_key is.
    jobs.sort((a, b) => a.startedAt - b.startedAt);
    const at = Math.max(...jobs.map((j) => Math.max(store.jobNotices(j.id, 1)[0]?.at ?? j.startedAt, j.startedAt)));
    out.set(key, { names: jobs.map((j) => j.name), since: jobs[0].startedAt, at });
  }
  return out;
}

/// The exit code a job's shell wrote when it ended, if it did.
export function readExit(path: string): number | null {
  try {
    const text = readFileSync(path, "utf8").trim();
    return /^[+-]?\d+$/.test(text) ? Number(text) : null;
  } catch {
    return null;
  }
}

/// How a job is named to its agent.
export function named(job: JobRow): string {
  return job.port !== null ? `Service "${job.name}" (${job.id}, port ${job.port})` : `Job "${job.name}" (${job.id})`;
}

/// How long a service that ended waits before it starts again: none after a steady run, else 1 s doubling with each
/// quick end, 60 s at most.
export function restartPause(restarts: number, ranMs: number): number {
  if (ranMs >= STEADY_MS) return 0;
  return Math.min(1000 * 2 ** Math.min(Math.max(restarts, 0), 6), MAX_PAUSE_MS);
}

export class Jobs {
  readonly store: Store;
  readonly dir: string;
  private notify: Notify;
  private link: Link;
  /// Where `stillfail-job notify` posts (the MCP endpoint's /jobs/notify).
  private notifyUrl = "";
  private running = new Map<string, Running>();
  /// Shutting down: jobs go on without the station and stay recorded as running, to be taken up by the next one.
  private closing = false;
  private scope: Scope.Closeable;
  /// Runs an effect as a fiber of these jobs' (a service's restart pause, a followed job's end): they end with it.
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  /// Runs an effect on the jobs' clock but apart from them (a stop's grace goes on through a shutdown).
  private timed: (effect: Effect.Effect<void>) => Promise<void>;
  /// What waits for an exit file to appear, by job id; the watch on jobs/exit that tells them.
  private exitHeard = new Map<string, () => void>();
  private exitWatch: FSWatcher | null = null;

  constructor(options: JobsOptions) {
    this.store = options.store;
    this.notify = options.notify;
    this.link = options.link;
    const dir = join(options.data, "jobs");
    this.dir = dir;
    for (const sub of ["logs", "bin", "exit"]) mkdirSync(join(dir, sub), { recursive: true });
    // Runnable by name from any shell (on Windows from cmd or PowerShell, Codex's shell there, too).
    const script = join(dir, "bin", JOB_COMMAND_NAME);
    try {
      platform.makeCommand(script, JOB_COMMAND);
    } catch (error) {
      // The script is there for a POSIX shell; only another shell's way to it (no Git's sh on Windows) is missing.
      if (!existsSync(script)) throw error;
      log.warn("jobs", "no stillfail-job for cmd and PowerShell", { error: String(error) });
    }
    // The old name, for jobs and agents used to it: a link to the new one (in place of the script it was).
    const former = join(dir, "bin", FORMER_JOB_COMMAND_NAME);
    let linked: string | null = null;
    try {
      linked = readlinkSync(former);
    } catch {}
    if (linked !== JOB_COMMAND_NAME) {
      const aside = join(dir, "bin", `.${FORMER_JOB_COMMAND_NAME}.${process.pid}`);
      rmSync(aside, { force: true });
      // Where links are refused, a copy will do: the script is written afresh at each start.
      linkSync(JOB_COMMAND_NAME, aside, { copy: true });
      renameSync(aside, former);
    }
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
    const clock = options.clock;
    this.timed = (effect) => Effect.runPromise(clock ? effect.pipe(Effect.provideService(Clock.Clock, clock)) : effect);
  }

  /// Where `stillfail-job notify` posts, once the endpoint listens.
  setNotifyUrl(url: string): void {
    this.notifyUrl = url;
  }

  /// A remote job's notices are kept by its job and returned to the source station by Remote, not told here.
  private tell(job: JobRow, text: string): void {
    if (job.sessionKey.startsWith("remote:")) return;
    try {
      this.notify(job.sessionKey, text);
    } catch (error) {
      log.warn("jobs", "job notice not given", { session: job.sessionKey, error: (error as Error).message });
    }
  }

  /// Starts a job for `session`: `command` run by sh in `cwd`; a web service when it has a port.
  start(session: string, name: string, command: string, cwd: string, port: number | null, watch: boolean): JobRow {
    return this.startId(session, name, command, cwd, port, watch, null);
  }

  /// A remote job supplies a stable id. Its caller serializes starts; an existing record is never spawned again.
  startId(session: string, name: string, command: string, cwd: string, port: number | null, watch: boolean, id: string | null): JobRow {
    if (id !== null) {
      const job = this.store.getJob(id);
      if (job) return job;
    }
    if (command.trim() === "") throw new Error("command is empty");
    let isDir = false;
    try {
      isDir = statSync(cwd).isDirectory();
    } catch {}
    if (!isDir) throw new Error(`no such directory: ${cwd}`);
    if (port !== null && port < 1024) throw new Error("a service's port is 1024 or above");
    if (watch && port !== null) throw new Error("a watch is a job, not a web service: give it no port");
    if (this.store.listJobs(session).filter((j) => j.state === "running").length >= MAX_RUNNING) {
      throw new Error(`this session runs ${MAX_RUNNING} jobs already; stop some first`);
    }
    if (port !== null) {
      // A service holds its port until it is stopped (between its restarts too).
      const taken = this.store.listJobs(null).find((j) => j.port === port && (j.state === "running" || j.state === "exited"));
      if (taken) throw new Error(`port ${port} is ${named(taken)}'s already`);
    }
    const jobId = id ?? `job_${hex(4)}`;
    const shownName = name.trim() === "" ? (command.trim().split(/\s+/)[0] || "job") : [...name.trim()].slice(0, 60).join("");
    const job: JobRow = {
      log: join(this.dir, "logs", `${jobId}.log`),
      id: jobId,
      sessionKey: session,
      name: shownName,
      command,
      cwd,
      port,
      token: hex(16),
      state: "running",
      pgid: null,
      exitCode: null,
      startedAt: this.store.now(),
      endedAt: null,
      restarts: 0,
      watch,
    };
    this.store.insertJob(job);
    try {
      this.spawn(job, false);
    } catch (error) {
      this.store.jobEnded(job.id, "failed", null);
      throw error;
    }
    log.info("jobs", "job started", { job: job.id, session, name: job.name, port: job.port });
    return this.store.getJob(job.id) ?? job;
  }

  /// Where a job's exit code is written when it ends.
  exitFile(id: string): string {
    return join(this.dir, "exit", id);
  }

  private track(id: string, pgid: number, gone: Promise<void>): Running {
    let settle = () => {};
    const settled = new Promise<void>((resolve) => (settle = resolve));
    const running: Running = { pgid, stopping: false, gone, settled, settle };
    this.running.set(id, running);
    return running;
  }

  /// Runs a job's command, and follows it to its end.
  private spawn(job: JobRow, restarted: boolean): void {
    // Made (or found) here, so a log that cannot be written is said now; the shell opens it itself (below).
    closeSync(openSync(job.log, "a"));
    const exit = this.exitFile(job.id);
    rmSync(exit, { force: true });
    const env: NodeJS.ProcessEnv = platform.prependPath(process.env, join(this.dir, "bin"));
    // Under both names: scripts written against the old ones go on working.
    for (const prefix of ["STILLFAIL_", "EMBER_"]) {
      env[`${prefix}JOB_ID`] = job.id;
      env[`${prefix}JOB_TOKEN`] = job.token;
      env[`${prefix}JOB_NOTIFY`] = this.notifyUrl;
    }
    if (job.port !== null) env.PORT = String(job.port);
    // A group of its own (detached: pgid = its pid; on Windows the job of the runner it runs under), not ended with the
    // station. The shell appends to the log itself: Git's sh on Windows cannot write to a file Node opened for
    // appending (its handle may only append).
    const child = startLasting(platform.posixShell(env), ["-c", `exec >>"$3" 2>&1; ${WRAPPER}`, JOB_COMMAND_NAME, job.command, exit, job.log], {
      cwd: job.cwd, env, stdio: "ignore",
    });
    child.on("error", () => {});
    const pgid = child.pid;
    if (pgid === undefined) throw new Error("the job ended before it started");
    this.store.recordProcess(pgid, this.store.now(), "job", `job: ${job.name}`);
    this.store.jobStarted(job.id, pgid, restarted);
    const exited = new Promise<number | null>((resolve) => child.once("exit", (code) => resolve(code)));
    const running = this.track(job.id, pgid, exited.then(() => undefined));
    const began = this.store.now();
    void this.run(
      Effect.promise(() => exited).pipe(
        Effect.flatMap((code) => Effect.sync(() => this.ended(job.id, pgid, code, running.stopping, this.store.now() - began))),
      ),
    ).catch(() => undefined);
  }

  /// The end of a job an earlier station started (not this one's child): its exit file appearing (heard from the watch
  /// on jobs/exit), or its leader gone (looked at once a second: that end writes no file and has no event).
  private leaderGone(id: string, pgid: number): Effect.Effect<void> {
    const exit = this.exitFile(id);
    const over = () => existsSync(exit) || !pidAlive(pgid);
    const heard = Effect.callback<void>((resume) => {
      let done = false;
      const look = () => {
        if (done || !existsSync(exit)) return;
        done = true;
        resume(Effect.void);
      };
      this.exitHeard.set(id, look);
      this.watchExits();
      return Effect.sync(() => {
        done = true;
        if (this.exitHeard.get(id) === look) this.exitHeard.delete(id);
      });
    });
    const looked = Effect.sync(over).pipe(
      Effect.repeat({ schedule: Schedule.spaced(FOLLOW_LOOK_MS), until: (gone) => gone }),
      Effect.asVoid,
    );
    return Effect.race(looked, heard);
  }

  /// The watch on jobs/exit (one for all followed jobs), while any is followed.
  private watchExits(): void {
    if (this.exitWatch !== null) return;
    try {
      this.exitWatch = watch(join(this.dir, "exit"), (_event, file) => {
        if (file) this.exitHeard.get(file.toString())?.();
      });
      this.exitWatch.unref();
      this.exitWatch.on("error", () => {});
    } catch {
      // Not watched: the look once a second still finds it.
    }
  }

  /// Follows a job an earlier station started (it went on through the restart) to its end.
  private follow(job: JobRow, pgid: number): void {
    let heard = () => {};
    const gone = new Promise<void>((resolve) => (heard = resolve));
    const running = this.track(job.id, pgid, gone);
    const began = this.store.now() - Math.max(0, this.store.now() - job.startedAt);
    const id = job.id;
    void this.run(
      this.leaderGone(id, pgid).pipe(
        Effect.flatMap(() =>
          Effect.sync(() => {
            heard();
            // What its shell wrote, if it did.
            this.ended(id, pgid, readExit(this.exitFile(id)), running.stopping, this.store.now() - began);
          }),
        ),
      ),
    ).catch(() => undefined);
  }

  /// A job's command ended: said to its agent, and a service started again. `pgid`: its group, when it ended just now
  /// (what it started itself goes with it).
  private ended(id: string, pgid: number | null, code: number | null, stopped: boolean, ranMs: number): void {
    // The station stopping: left as it is on record, for the next one to find it ended (its exit file says how).
    if (this.closing) return;
    const running = this.running.get(id);
    this.running.delete(id);
    try {
      this.endedRecord(id, pgid, code, stopped, ranMs);
    } finally {
      running?.settle();
    }
  }

  private endedRecord(id: string, pgid: number | null, code: number | null, stopped: boolean, ranMs: number): void {
    if (pgid !== null) {
      this.store.forgetProcess(pgid);
      // What it started itself (a server forked off) goes with it.
      signalGroup(pgid, "SIGTERM");
    }
    const job = this.store.getJob(id);
    if (!job) return;
    if (stopped) {
      this.store.jobEnded(id, "stopped", code);
      return;
    }
    const said = code !== null ? `exit code ${code}` : "a signal";
    const lines = tail(job.log, 20);
    const last = lines === "" ? "" : `\nIts last lines:\n\`\`\`\n${lines}\n\`\`\``;
    if (job.port === null) {
      this.store.jobEnded(id, "exited", code);
      this.tell(job, `${named(job)} ended with ${said}.${last}`);
      return;
    }
    // A service is kept up: at once after a steady run, else after a pause that grows with each quick end.
    const pause = restartPause(job.restarts, ranMs);
    this.store.jobEnded(id, "exited", code);
    this.tell(job, `${named(job)} ended with ${said}; the station starts it again${pause === 0 ? "" : ` in ${pause / 1000} s`}.${last}`);
    void this.run(
      Effect.sleep(pause).pipe(
        Effect.andThen(
          Effect.sync(() => {
            // Stopped meanwhile (job_stop, the session deleted): not again.
            const now = this.store.getJob(id);
            if (!now || now.state !== "exited" || this.closing) return;
            try {
              this.spawn(now, true);
            } catch (error) {
              const e = (error as Error).message;
              log.warn("jobs", "service not started again", { job: id, error: e });
              this.store.jobEnded(id, "failed", null);
              this.tell(now, `${named(now)} could not be started again: ${e}`);
            }
          }),
        ),
      ),
    ).catch(() => undefined);
  }

  /// A stop's wait for a job's end: its leader's comes as an event; members it left behind have none, and are looked at
  /// within the grace. Killed if not ended by then, and its end taken in.
  private grace(running: Running): Effect.Effect<void> {
    return Effect.gen(function* () {
      yield* Effect.promise(() => running.gone).pipe(
        Effect.andThen(
          Effect.repeat(Effect.sync(() => groupAlive(running.pgid)), {
            schedule: Schedule.spaced(STOP_LOOK_MS),
            until: (alive) => !alive,
          }),
        ),
        Effect.timeoutOption(STOP_GRACE_MS),
      );
      if (groupAlive(running.pgid)) signalGroup(running.pgid, "SIGKILL");
      yield* Effect.promise(() => running.settled).pipe(Effect.timeoutOption(STOP_SETTLE_MS));
    });
  }

  /// Stops a job: its process group asked to end, then made to.
  async stop(id: string): Promise<JobRow> {
    const job = this.store.getJob(id);
    if (!job) throw new Error(`no job ${id}`);
    const running = this.running.get(id);
    if (running) {
      running.stopping = true;
      signalGroup(running.pgid, "SIGTERM");
      await this.timed(this.grace(running));
    } else if (job.state === "running" || job.state === "exited") {
      // A service waiting to start again, or one on record only: it stays stopped. One an earlier station left running
      // and this one does not follow (it started out of its workspace, so took nothing up): its group is ended too.
      const entry = job.pgid !== null ? this.leftBehind(job.pgid) : null;
      if (entry) {
        if (stillOurs(entry)) {
          log.warn("jobs", "ending a job an earlier station left running", { job: job.id, pgid: entry.pgid });
          await this.timed(endGroup(entry.pgid, STOP_GRACE_MS));
        }
        this.store.forgetProcess(entry.pgid);
      }
      this.store.jobEnded(id, "stopped", job.exitCode);
    }
    return this.store.getJob(id) ?? job;
  }

  /// The record of a job's group an earlier station started (not one this station follows).
  private leftBehind(pgid: number): ProcessRow | null {
    for (const r of this.running.values()) if (r.pgid === pgid) return null;
    return this.store.listProcesses().find((p) => p.runtime === "job" && p.pgid === pgid) ?? null;
  }

  /// Stops a job for someone on the pages: its agent is told who did (it did not ask for it), if it was at work within
  /// AWAKE; an idle one is not woken for it.
  async stopFor(id: string, who: string): Promise<JobRow> {
    const job = await this.stop(id);
    if (this.awake(job.sessionKey)) this.tell(job, `${named(job)} was stopped by ${who} from still.fail's page.`);
    return job;
  }

  /// Stops every job and service that runs or waits to start again, `why` written at the end of each one's log: the
  /// station left its workspace, and does no work outside one; or it starts already out of it, and what an earlier
  /// station left running (it ended before it could stop them) is ended. Agents are not told (no turn runs meanwhile,
  /// and telling them once it is back would wake them all); a job's state and log say it when one looks.
  async stopAll(why: string): Promise<void> {
    const jobs = this.store.listJobs(null);
    for (const job of jobs.filter((j) => j.state === "running" || (j.state === "exited" && j.port !== null))) {
      log.warn("jobs", "stopping a job", { job: job.id, why });
      try {
        await this.stop(job.id);
      } catch (error) {
        log.warn("jobs", "job not stopped", { job: job.id, error: (error as Error).message });
        continue;
      }
      try {
        appendFileSync(job.log, `\n[still.fail] stopped: ${why}\n`);
      } catch {}
    }
  }

  /// Takes a session's jobs that are over off its record (the pages' 清掉已结束的), their logs with them: the ids gone.
  clearEnded(session: string): string[] {
    const gone = this.store.clearEndedJobs(session);
    for (const [id, file] of gone) {
      if (file.startsWith(this.dir + sep)) rmSync(file, { force: true });
      rmSync(this.exitFile(id), { force: true });
    }
    return gone.map(([id]) => id);
  }

  /// Whether a session's agent is in a turn, or was within AWAKE.
  private awake(session: string): boolean {
    const s = this.store.getSession(session);
    return s !== null && (s.running || this.store.now() - s.lastActiveAt < AWAKE_MS);
  }

  /// After a start of the station: what still runs is followed again; what ended meanwhile is told as ended; what was
  /// running and is gone without a word (the machine restarted, or an older station ended it) runs again, and its agent
  /// is told; a service waiting to start again starts. Groups of jobs no longer running are ended.
  relaunch(): void {
    const recorded = new Map<number, ProcessRow>(this.store.listProcesses().filter((p) => p.runtime === "job").map((p) => [p.pgid, p]));
    const followed = new Set<number>();
    const jobs = this.store.listJobs(null);
    for (const job of jobs.filter((j) => j.state === "running")) {
      const entry = job.pgid !== null ? recorded.get(job.pgid) : undefined;
      if (entry) {
        if (stillOurs(entry)) {
          log.info("jobs", "job went on through the restart; following it again", { job: job.id, pgid: entry.pgid });
          this.follow(job, entry.pgid);
          followed.add(entry.pgid);
          continue;
        }
        this.store.forgetProcess(entry.pgid);
        const code = readExit(this.exitFile(job.id));
        if (code !== null) {
          // It ended while no station was running: as if it had just ended.
          const ran = Math.max(0, this.store.now() - job.startedAt);
          const id = job.id;
          void this.run(Effect.sync(() => this.ended(id, null, code, false, ran))).catch(() => undefined);
          continue;
        }
      }
      // A remote command may have external effects. A lost process is an uncertain result, not permission to execute
      // it again. Its stable task id remains queryable and cannot be reused.
      if (job.id.startsWith("remote_")) {
        this.store.jobEnded(job.id, "failed", null);
        continue;
      }
      try {
        this.spawn(job, true);
        this.tell(job, `The station restarted; ${named(job)} was started again.`);
      } catch (error) {
        const e = (error as Error).message;
        log.warn("jobs", "job not started again", { job: job.id, error: e });
        this.store.jobEnded(job.id, "failed", null);
        this.tell(job, `The station restarted; ${named(job)} could not be started again: ${e}`);
      }
    }
    // A service that ended just before the station stopped, waiting out its pause: it starts now.
    for (const job of jobs.filter((j) => j.state === "exited" && j.port !== null)) {
      try {
        this.spawn(job, true);
      } catch (error) {
        log.warn("jobs", "service not started again", { job: job.id, error: (error as Error).message });
        this.store.jobEnded(job.id, "failed", null);
      }
    }
    for (const [pgid, entry] of recorded) {
      if (followed.has(pgid)) continue;
      if (stillOurs(entry)) {
        log.warn("jobs", "ending the group of a job no longer running", { pgid, label: entry.label });
        void this.timed(endGroup(pgid, STOP_GRACE_MS));
      }
      this.store.forgetProcess(pgid);
    }
  }

  /// The station stops: its jobs go on (the next station takes them up); what followed them and the services' restart
  /// pauses end here.
  async shutdown(): Promise<void> {
    this.closing = true;
    this.exitWatch?.close();
    this.exitWatch = null;
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
  }

  /// `stillfail-job notify`: the job with this token tells its agent something.
  notified(token: string, text: string): void {
    const job = this.store.jobByToken(token);
    if (!job) throw new Error("unknown job token");
    const said = [...text.trim()].slice(0, 4000).join("");
    if (said === "") throw new Error("nothing to say");
    this.store.addJobNotice(job.id, said);
    this.tell(job, `${named(job)} says: ${said}`);
  }

  /// A job as the agent reads it: a service with its link.
  view(job: JobRow): Json {
    const v = jobJson(job);
    if (job.port !== null) v.link = this.link(job.sessionKey, job.id);
    return v;
  }
}

/// POST /jobs/notify on the MCP endpoint (server.rs `answer_mcp`): a job's `stillfail-job notify`, its token as the
/// bearer, its words as the body (at most 64 KiB). The HTTP wiring is the server's: it gives the authorization header
/// and the body read so far (more than the limit is refused).
export function notifyEndpoint(jobs: Jobs, authorization: string | undefined, body: Buffer | string): { status: number; body: Json } {
  const token = authorization?.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
  const bytes = typeof body === "string" ? Buffer.from(body) : body;
  if (bytes.length > NOTIFY_BODY_LIMIT) return { status: 400, body: { error: "length limit exceeded" } };
  try {
    jobs.notified(token, new TextDecoder("utf-8").decode(bytes));
    return { status: 200, body: { ok: true } };
  } catch (error) {
    return { status: 400, body: { error: (error as Error).message } };
  }
}
