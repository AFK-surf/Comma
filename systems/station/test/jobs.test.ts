// the Rust station's jobs/tests.rs ported (same names, same checks): real jobs in temporary data directories, a real Store,
// and a notify that records what agents are told. Plus the restart pause on a TestClock and /jobs/notify.
// The tests share nothing (each its own directory, store and jobs; their ports are only claims in that store), so they
// run at once. No test waits a fixed time:
// a job that must outlive something waits at a gate (a fifo) the test opens, and a service's pause is on a TestClock.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { type Clock, type Duration, Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { endGroup, groupAlive, signalGroup } from "../src/jobs/group.ts";
import { Jobs, notifyEndpoint, readExit, restartPause, shown, tail, watching } from "../src/jobs/jobs.ts";
import { jobTools } from "../src/tools/jobs.ts";
import { Store } from "../src/store/store.ts";
import { WINDOWS, platform } from "../src/platform/index.ts";

const dirs: string[] = [];
const all: Jobs[] = [];
const stores: Store[] = [];
const scopes: Scope.Closeable[] = [];
after(async () => {
  for (const j of all) {
    // What a test left running goes, then the instance.
    for (const job of j.store.listJobs(null)) if (job.pgid !== null) signalGroup(job.pgid, "SIGKILL");
    await j.shutdown().catch(() => undefined);
  }
  for (const scope of scopes) await Effect.runPromise(Scope.close(scope, Exit.void)).catch(() => undefined);
  for (const s of stores) {
    try {
      s.close();
    } catch {}
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempdir(): string {
  const d = mkdtempSync(join(tmpdir(), "jobs-test-"));
  dirs.push(d);
  return d;
}

type Told = [string, string][];

function jobsOn(
  data: string, store: Store, told: Told,
  link = (session: string, job: string): string | null => `https://ember.test/o/ws/st/${session}?service=${job}`, clock?: Clock.Clock,
) {
  const jobs = new Jobs({ store, data, notify: (session, text) => void told.push([session, text]), link, clock });
  all.push(jobs);
  return jobs;
}

class Rig {
  dir: string;
  store: Store;
  jobs: Jobs;
  told: Told = [];
  work: string;
  constructor(dir = tempdir(), store = memory(), clock?: Clock.Clock) {
    this.dir = dir;
    this.store = store;
    this.jobs = jobsOn(dir, store, this.told, undefined, clock);
    this.work = join(dir, "work");
    mkdirSync(this.work, { recursive: true });
  }
  said(): string[] {
    return this.told.map(([, t]) => t);
  }
  state(id: string): string {
    return this.store.getJob(id)!.state;
  }
}

function memory(): Store {
  const s = Store.open(":memory:");
  stores.push(s);
  return s;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/// Waits for what a real process does (it has no event here), looking every 5 ms. No deadline: it comes, however slow
/// the machine, or the test hangs.
async function until(_what: string, check: () => boolean) {
  while (!check()) await sleep(5);
}

/// A job's command that never ends by itself: running for as long as a test needs, however slow the machine.
const FOREVER = "tail -f /dev/null";

/// A TestClock for a station, and how many sleeps were asked of it and are over: a fiber asked for one is sleeping on
/// it (an adjust reaches it), one whose sleep is over has gone on past it.
function testClock() {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const test = Effect.runSync(Scope.provide(TestClock.make(), scope));
  let asked = 0;
  let over = 0;
  const clock: Clock.Clock = {
    ...test,
    sleep: (duration) =>
      Effect.suspend(() => {
        asked++;
        return test.sleep(duration).pipe(Effect.andThen(Effect.sync(() => void over++)));
      }),
  };
  return { clock, adjust: (by: Duration.Input) => Effect.runPromise(test.adjust(by)), asked: () => asked, over: () => over };
}

/// A fifo a job's command waits at (`cat` it) until the test opens it.
/// What a job's command waits at (`wait`, shell) until the test lets it go on (`open`): a fifo; on Windows, which has
/// none for sh, a file looked for until it is there.
function gate(dir: string): { wait: string; open: () => Promise<void> } {
  const path = join(dir, `gate-${Math.random().toString(36).slice(2)}`);
  if (WINDOWS) return { wait: `until [ -e '${path}' ]; do sleep 0.05; done`, open: () => writeFile(path, "go") };
  execFileSync("mkfifo", [path]);
  // Off the main thread: opening a fifo to write waits for its reader.
  return { wait: `cat '${path}' >/dev/null`, open: () => writeFile(path, "go") };
}

/// The same store, and the same jobs directory, as a restarted station has.
function restarted(before: Rig): Rig {
  const r = Object.create(Rig.prototype) as Rig;
  r.dir = before.dir;
  r.store = before.store;
  r.told = [];
  r.jobs = jobsOn(before.dir, before.store, r.told, () => null);
  r.work = before.work;
  return r;
}

describe("jobs", { concurrency: true }, () => {
  test("a job runs apart, its output logged and its agent told how it ended", async () => {
    const r = new Rig();
    const job = r.jobs.start("s1", "build", "echo compiling; echo done >&2; exit 3", r.work, null, false);
    assert.equal(job.state, "running");
    await until("it ends", () => r.state(job.id) === "exited");
    const ended = r.store.getJob(job.id)!;
    assert.equal(ended.exitCode, 3);
    assert.equal(tail(ended.log, 10), "compiling\ndone");
    await until("its agent is told", () => r.said().length > 0);
    const said = r.said();
    assert.ok(said[0].startsWith(`Job "build" (${job.id}) ended with exit code 3.`), said[0]);
    assert.ok(said[0].includes("compiling\ndone"));
    assert.equal(r.told[0][0], "s1");
  });

  test("a job tells its agent on the way through its token", async () => {
    const r = new Rig();
    const job = r.jobs.start("s1", "long", FOREVER, r.work, null, false);
    r.jobs.notified(job.token, "  half way  ");
    assert.deepEqual(r.said(), [`Job "long" (${job.id}) says: half way`]);
    assert.throws(() => r.jobs.notified("wrong", "x"));
    // What it said is kept for the pages, newest first, with the job as they get it.
    r.jobs.notified(job.token, "nearly there");
    assert.deepEqual(r.store.jobNotices(job.id, 10).map((n) => n.text), ["nearly there", "half way"]);
    const v = shown(r.store, r.store.getJob(job.id)!);
    assert.equal(v.notices[0].text, "nearly there");
    assert.ok(!("token" in v));
    const stopped = await r.jobs.stop(job.id);
    // "stopped" is written as its end is taken in, and what its agent is told then is told at once.
    assert.equal(stopped.state, "stopped");
    assert.equal(r.said().length, 2, "a stop asked for is no news");
  });

  test("a job has its command under the new name and the old, and its variables under both", async () => {
    const r = new Rig();
    const job = r.jobs.start(
      "s1", "names",
      `stillfail-job 2>&1; ember-job 2>&1; [ "$STILLFAIL_JOB_ID" = "$EMBER_JOB_ID" ] && [ "$STILLFAIL_JOB_TOKEN" = "$EMBER_JOB_TOKEN" ] && echo same`,
      r.work, null, false,
    );
    await until("it ends", () => r.state(job.id) !== "running");
    const ended = r.store.getJob(job.id)!;
    assert.equal(ended.state, "exited");
    assert.equal(tail(ended.log, 10), "usage: stillfail-job notify <words>\nusage: stillfail-job notify <words>\nsame");
    // Made again (a station starting over the same directory), the link stays one.
    const bin = join(r.dir, "jobs", "bin");
    jobsOn(r.dir, r.store, [], () => null);
    assert.equal(readlinkSync(join(bin, "ember-job")), "stillfail-job");
    // On Windows, stillfail-job.cmd beside them (for cmd and PowerShell).
    assert.equal(readdirSync(bin).length, WINDOWS ? 3 : 2);
  });

  test("the job command reads the old variables of a job started before the rename", async () => {
    const r = new Rig();
    const bin = join(r.dir, "jobs", "bin");
    // A /jobs/notify that says what it was asked (by the real curl).
    const asked: { url?: string; authorization?: string; body: string }[] = [];
    const server = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => (body += chunk));
      req.on("end", () => {
        asked.push({ url: req.url, authorization: req.headers.authorization, body });
        res.end("{}");
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const notify = `http://127.0.0.1:${(server.address() as AddressInfo).port}/jobs/notify`;
    try {
      // Windows runs no script by its #!: Git's sh runs it, with Windows' own PATH (curl is System32's or Git's).
      const out = WINDOWS
        ? spawn(platform.posixShell(), [join(bin, "ember-job"), "notify", "hi"], {
            env: { ...platform.prependPath(process.env, bin), EMBER_JOB_TOKEN: "t0k", EMBER_JOB_NOTIFY: notify },
            stdio: ["ignore", "ignore", "pipe"],
          })
        : spawn(join(bin, "ember-job"), ["notify", "hi"], {
            env: { EMBER_JOB_TOKEN: "t0k", EMBER_JOB_NOTIFY: notify, PATH: `${bin}:/usr/bin:/bin` },
            stdio: ["ignore", "ignore", "pipe"],
          });
      let said = "";
      out.stderr.on("data", (chunk) => (said += chunk));
      const code = await new Promise((resolve) => out.on("close", resolve));
      assert.equal(code, 0, said);
      assert.deepEqual(asked, [{ url: "/jobs/notify", authorization: "Bearer t0k", body: "hi" }]);
    } finally {
      server.closeAllConnections();
      server.close();
    }
  });

  /// A session whose agent was last at work `agoMs` ago.
  function sessionActive(store: Store, key: string, agoMs: number) {
    const at = store.now() - agoMs;
    store.insertSession({ key, connect: "ds", runtime: "claude", profile: "cc", workspace: `/w/${key}`, token: key, createdAt: at, lastActiveAt: at });
  }

  test("a job stopped from the pages tells its agent who did", async () => {
    const r = new Rig();
    sessionActive(r.store, "s1", 60_000);
    const job = r.jobs.start("s1", "watch", FOREVER, r.work, null, false);
    const stopped = await r.jobs.stopFor(job.id, "ann@example.com");
    assert.equal(stopped.state, "stopped");
    assert.deepEqual(r.said(), [`Job "watch" (${job.id}) was stopped by ann@example.com from still.fail's page.`]);
  });

  test("a job stopped from the pages does not wake an idle agent", async () => {
    const r = new Rig();
    sessionActive(r.store, "s1", 6 * 60_000);
    const job = r.jobs.start("s1", "watch", FOREVER, r.work, null, false);
    assert.equal((await r.jobs.stopFor(job.id, "ann@example.com")).state, "stopped");
    // Once it is at work again, it is told.
    const other = r.jobs.start("s1", "again", FOREVER, r.work, null, false);
    r.store.setRunning("s1", true);
    await r.jobs.stopFor(other.id, "ann@example.com");
    assert.deepEqual(r.said(), [`Job "again" (${other.id}) was stopped by ann@example.com from still.fail's page.`]);
  });

  test("clearing a session's ended jobs takes them and their logs away and leaves the rest", async () => {
    const r = new Rig();
    const failed = r.jobs.start("s1", "boom", "echo x; exit 2", r.work, null, false);
    const done = r.jobs.start("s1", "done", "true", r.work, null, false);
    const live = r.jobs.start("s1", "watch", FOREVER, r.work, null, false);
    const other = r.jobs.start("s2", "boom", "exit 2", r.work, null, false);
    await until("they end", () => [failed, done, other].every((j) => r.state(j.id) === "exited"));
    r.store.addJobNotice(failed.id, "broke");
    const cleared = r.jobs.clearEnded("s1").sort();
    assert.deepEqual(cleared, [failed.id, done.id].sort());
    const left = r.store.listJobs(null).map((j) => j.id);
    assert.equal(left.length, 2);
    assert.ok(left.includes(live.id) && left.includes(other.id));
    assert.ok(!existsSync(failed.log));
    assert.deepEqual(r.store.jobNotices(failed.id, 5), []);
    await r.jobs.stop(live.id);
  });

  test("a service is kept up and stays down once stopped", async () => {
    // Its pauses on a TestClock: a stopped service's would have ended long before the clock is through.
    const time = testClock();
    const r = new Rig(undefined, undefined, time.clock);
    const job = r.jobs.start("s1", "web", "echo up on $PORT; exit 1", r.work, 4999, false);
    await until("it waits out its pause", () => time.asked() === 1);
    await time.adjust("1 second");
    await until("it is started again", () => r.store.getJob(job.id)!.restarts >= 1);
    assert.ok(r.said()[0].includes("ended with exit code 1; the station starts it again in 1 s."), r.said()[0]);
    assert.ok(tail(job.log, 5).includes("up on 4999"));
    assert.throws(() => r.jobs.start("s2", "other", "true", r.work, 4999, false), /port 4999/, "one service per port");
    await until("it ended again and waits out its pause", () => time.asked() === 2);
    await r.jobs.stop(job.id);
    await until("it is stopped", () => r.state(job.id) === "stopped");
    const restarts = r.store.getJob(job.id)!.restarts;
    await time.adjust("10 minutes");
    await until("its pause is over", () => time.over() === 2);
    assert.equal(r.store.getJob(job.id)!.restarts, restarts, "not started again");
    assert.equal(r.state(job.id), "stopped");
  });

  test("a job goes on through a restart of the station and is followed to its end", async () => {
    const before = new Rig();
    const go = gate(before.dir);
    const job = before.jobs.start("s1", "build", `${go.wait}; echo built; exit 4`, before.work, null, false);
    await before.jobs.shutdown();
    const pgid = before.store.getJob(job.id)!.pgid!;
    assert.ok(groupAlive(pgid), "the station stopping does not stop it");
    const after = restarted(before);
    after.jobs.relaunch();
    const followed = after.store.getJob(job.id)!;
    assert.deepEqual([followed.pgid, followed.restarts], [pgid, 0], "the same run, not started again");
    assert.deepEqual(after.said(), []);
    await go.open();
    await until("it ends", () => after.state(job.id) === "exited");
    assert.equal(after.store.getJob(job.id)!.exitCode, 4, "how it ended, from what its shell wrote");
    assert.equal(tail(job.log, 5), "built", "it ran on to its end");
    await until("its agent is told", () => after.said().length > 0);
    assert.ok(after.said()[0].includes("ended with exit code 4"), after.said()[0]);
  });

  test("a job that ended while no station ran is told as ended, not run again", async () => {
    const before = new Rig();
    const go = gate(before.dir);
    const job = before.jobs.start("s1", "quick", `${go.wait}; exit 5`, before.work, null, false);
    await before.jobs.shutdown();
    await go.open();
    const pgid = before.store.getJob(job.id)!.pgid!;
    await until("it ends", () => readExit(before.jobs.exitFile(job.id)) === 5 && !groupAlive(pgid));
    assert.equal(before.state(job.id), "running", "still running on record");
    const after = restarted(before);
    after.jobs.relaunch();
    await until("it is told as ended", () => after.state(job.id) === "exited");
    const ended = after.store.getJob(job.id)!;
    assert.deepEqual([ended.exitCode, ended.restarts], [5, 0]);
    await until("its agent is told", () => after.said().length > 0);
    assert.ok(after.said()[0].includes("ended with exit code 5"), after.said()[0]);
  });

  test("a job gone without a word runs again when the station starts", async () => {
    const before = new Rig();
    const job = before.jobs.start("s1", "watch", FOREVER, before.work, null, false);
    await before.jobs.shutdown();
    // What a restart of the machine does to it.
    const pgid = before.store.getJob(job.id)!.pgid!;
    signalGroup(pgid, "SIGKILL");
    await until("it is gone", () => !groupAlive(pgid));
    const after = restarted(before);
    after.jobs.relaunch();
    const again = after.store.getJob(job.id)!;
    assert.ok(again.pgid !== null && again.pgid !== pgid && again.restarts === 1);
    assert.deepEqual(after.said(), [`The station restarted; Job "watch" (${job.id}) was started again.`]);
    await after.jobs.stop(job.id);
  });

  test("the agents' tools start, list, read and stop their session's jobs only", async () => {
    const r = new Rig();
    const tools = jobTools(r.jobs, () => r.work);
    const call = (name: string, key: string, args: Record<string, unknown>) => tools.find((t) => t.name === name)!.run(key, args);
    const made = JSON.parse(await call("job_start", "s1", { command: `echo hello; ${FOREVER}`, name: "hi", port: 5010 }));
    const id: string = made.id;
    assert.equal(made.link, `https://ember.test/o/ws/st/s1?service=${id}`);
    assert.ok(!("token" in made), "its token is not said");
    await until("it writes", () => tail(r.store.getJob(id)!.log, 5) === "hello");
    assert.equal(await call("job_log", "s1", { id }), "hello");
    await assert.rejects(call("job_log", "s2", { id }), /another session's/);
    assert.ok((await call("job_list", "s1", {})).includes(id));
    assert.equal(await call("job_list", "s2", {}), "No jobs.");
    assert.ok((await call("job_stop", "s1", { id })).endsWith("is stopped."));
  });

  test("leaving the workspace stops every job and service and says why", async () => {
    const r = new Rig();
    const job = r.jobs.start("s1", "long", FOREVER, r.work, null, false);
    const service = r.jobs.start("s2", "web", FOREVER, r.work, 47991, false);
    const done = r.jobs.start("s1", "done", "exit 0", r.work, null, false);
    await until("the short one ends", () => r.state(done.id) === "exited");
    await r.jobs.stopAll("the station was removed from its workspace");
    await until("both are stopped", () => r.state(job.id) === "stopped" && r.state(service.id) === "stopped");
    assert.equal(r.state(done.id), "exited", "what was over stays as it was");
    const log = readFileSync(r.store.getJob(job.id)!.log, "utf8");
    assert.ok(log.endsWith("[still.fail] stopped: the station was removed from its workspace\n"), log);
    assert.ok(!r.said().some((t) => t.includes("was stopped")), "agents are not woken for it");
  });

  /// A station that starts out of its workspace takes nothing up; stopping all then ends what the one before left running.
  test("stopping all ends jobs an earlier station left running", async () => {
    const before = new Rig();
    const job = before.jobs.start("s1", "long", FOREVER, before.work, null, false);
    await before.jobs.shutdown();
    const pgid = before.store.getJob(job.id)!.pgid!;
    const after = restarted(before);
    await after.jobs.stopAll("the station was removed from its workspace");
    assert.equal(after.state(job.id), "stopped");
    assert.ok(!groupAlive(pgid), "its group is ended, not only marked");
    assert.deepEqual(after.store.listProcesses(), [], "and off the record");
    const log = readFileSync(after.store.getJob(job.id)!.log, "utf8");
    assert.ok(log.endsWith("[still.fail] stopped: the station was removed from its workspace\n"), log);
    assert.deepEqual(after.said(), []);
  });

  test("a watch is kept by its session while it runs, with when it last said something", async () => {
    const r = new Rig();
    assert.throws(() => r.jobs.start("s1", "w", FOREVER, r.work, 4998, true), /no port/, "a watch is no service");
    const plain = r.jobs.start("s2", "build", FOREVER, r.work, null, false);
    const watch = r.jobs.start("s1", "盯 CI", FOREVER, r.work, null, true);
    assert.ok(!plain.watch && watch.watch);
    assert.equal(r.store.getJob(watch.id)!.watch, true, "kept as a watch");
    const now = watching(r.store);
    assert.deepEqual([...now.keys()], ["s1"], "only the watch's session");
    assert.deepEqual([now.get("s1")!.names, now.get("s1")!.at], [["盯 CI"], watch.startedAt]);
    r.jobs.notified(watch.token, "build ✓");
    const at = r.store.jobNotices(watch.id, 1)[0].at;
    assert.equal(watching(r.store).get("s1")!.at, at, "its latest word");
    await r.jobs.stop(watch.id);
    assert.equal(watching(r.store).size, 0, "stopped: no longer watching");
    await r.jobs.stop(plain.id);
  });

  test("a remote task whose process was lost is not run again", async () => {
    const r = new Rig();
    const job = r.jobs.startId("remote:ws:peer:session", "once", `echo ran >> count; ${FOREVER}`, r.work, null, false, "remote_lost_test");
    await until("command started", () => existsSync(join(r.work, "count")));
    await r.jobs.shutdown();
    await Effect.runPromise(endGroup(job.pgid!, 50));
    rmSync(r.jobs.exitFile(job.id), { force: true });
    const next = jobsOn(r.dir, r.store, [], () => null);
    next.relaunch();
    assert.equal(r.store.getJob(job.id)!.state, "failed");
    assert.equal(readFileSync(join(r.work, "count"), "utf8"), "ran\n");
    const repeat = next.startId("remote:ws:peer:session", "once", "echo ran >> count", r.work, null, false, "remote_lost_test");
    assert.equal(repeat.state, "failed");
    assert.equal(readFileSync(join(r.work, "count"), "utf8"), "ran\n");
  });

  // ── beyond the Rust's tests ──

  test("a service's pause grows with each quick end, and a steady run starts again at once", () => {
    assert.deepEqual([0, 1, 2, 3, 5, 6, 9].map((n) => restartPause(n, 100)), [1000, 2000, 4000, 8000, 32000, 60000, 60000]);
    assert.equal(restartPause(4, 60_000), 0);
  });

  test("a service waits out its pause on the station's clock", async () => {
    const time = testClock();
    const dir = tempdir();
    const store = memory();
    const told: Told = [];
    const jobs = new Jobs({ store, data: dir, notify: (s, t) => void told.push([s, t]), link: () => null, clock: time.clock });
    all.push(jobs);
    const work = join(dir, "work");
    mkdirSync(work);
    const job = jobs.start("s1", "web", "exit 1", work, 4997, false);
    await until("it ended and waits out its pause", () => store.getJob(job.id)!.state === "exited" && time.asked() === 1);
    assert.equal(store.getJob(job.id)!.restarts, 0, "not before its pause");
    await time.adjust("999 millis");
    assert.equal(time.over(), 0);
    assert.equal(store.getJob(job.id)!.restarts, 0);
    await time.adjust("1 millis");
    await until("started again after 1 s on its clock", () => store.getJob(job.id)!.restarts === 1);
    await until("it ended again", () => told.length >= 2);
    assert.ok(told[1][1].includes("starts it again in 2 s"), told[1][1]);
    await jobs.stop(job.id);
    assert.equal(store.getJob(job.id)!.state, "stopped");
  });

  test("what a job says reaches /jobs/notify with its token, and nothing else does", async () => {
    const r = new Rig();
    const job = r.jobs.start("s1", "long", FOREVER, r.work, null, false);
    assert.deepEqual(notifyEndpoint(r.jobs, `Bearer ${job.token}`, "built ✓"), { status: 200, body: { ok: true } });
    assert.deepEqual(notifyEndpoint(r.jobs, "Bearer nope", "x"), { status: 400, body: { error: "unknown job token" } });
    assert.deepEqual(notifyEndpoint(r.jobs, `Bearer ${job.token}`, "   "), { status: 400, body: { error: "nothing to say" } });
    assert.deepEqual(notifyEndpoint(r.jobs, `Bearer ${job.token}`, Buffer.alloc(64 * 1024 + 1, 97)).status, 400);
    assert.deepEqual(r.said(), [`Job "long" (${job.id}) says: built ✓`]);
    await r.jobs.stop(job.id);
  });

  test("a remote task's end is not told to a session here", async () => {
    const r = new Rig();
    const job = r.jobs.startId("remote:ws:peer:s", "t", "exit 0", r.work, null, false, "remote_quiet");
    // "exited" is written as its end is taken in, and what a session is told then is told at once.
    await until("it ends", () => r.state(job.id) === "exited");
    assert.deepEqual(r.said(), []);
  });
});
