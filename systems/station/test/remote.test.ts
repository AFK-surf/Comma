// the Rust station's remote.rs's tests ported (transfer paths, task_tests, session_tests, recovery_tests; same names, same
// checks), with the schedules on a TestClock; then two stations in one process, the source's tools reaching the target
// through a direct `call` that answers as the transport does.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { after, describe, test } from "node:test";
import { type Clock, type Duration, Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { signalGroup } from "../src/jobs/group.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { IDLE_MS, type PeerCall, Refused, Remote, answerPeer, filePath, readJson, writeJson } from "../src/jobs/remote.ts";
import { applyState } from "../src/cloud/presence.ts";
import { Cloud, writeState } from "../src/cloud/state.ts";
import { PEER_ALPN, followRoster, peerCall, servePeer } from "../src/mesh/peer.ts";
import { type Json, Store } from "../src/store/store.ts";
import { remoteTools } from "../src/tools/remote.ts";
import { memoryMesh } from "./memory-mesh.ts";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const c of cleanup.reverse()) await c();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempdir(): string {
  const d = mkdtempSync(join(tmpdir(), "remote-test-"));
  dirs.push(d);
  return d;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const turn = async () => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
};

/// Waits for what real I/O does (a process, a peer's answer), looking every 5 ms. No deadline: it comes, however slow
/// the machine, or the test hangs.
async function until(_what: string, check: () => boolean) {
  while (!check()) await sleep(5);
}

/// A task's command that never ends by itself: running for as long as a test needs, however slow the machine.
const FOREVER = "tail -f /dev/null";

/// A TestClock, and how many sleeps were asked of it: a fiber asked for one is sleeping on it (an adjust reaches it).
function testClock() {
  const scope = Effect.runSync(Scope.make());
  cleanup.push(() => Effect.runPromise(Scope.close(scope, Exit.void)).catch(() => undefined));
  const test = Effect.runSync(Scope.provide(TestClock.make(), scope));
  let asked = 0;
  const clock: Clock.Clock & { adjust: typeof test.adjust; asked: () => number } = {
    ...test,
    sleep: (duration) =>
      Effect.suspend(() => {
        asked++;
        return test.sleep(duration);
      }),
    asked: () => asked,
  };
  return clock;
}

/// Moves `clock` on by `by` until `check` holds: a schedule's next round, whenever its fiber goes to sleep (no
/// deadline: what is checked for happens on rounds of the clock, however slow the machine).
async function rounds(_what: string, clock: ReturnType<typeof testClock>, by: Duration.Input, check: () => boolean) {
  while (!check()) {
    await Effect.runPromise(clock.adjust(by));
    await sleep(1);
  }
}

type Station = { dir: string; store: Store; jobs: Jobs; remote: Remote; told: [string, string][] };

function station(allow: string[], options: { clock?: Clock.Clock; dir?: string; store?: Store; jobs?: Jobs; notify?: (s: string, t: string) => void; configKey?: string } = {}): Station {
  const dir = options.dir ?? tempdir();
  const store = options.store ?? Store.open(":memory:");
  const told: [string, string][] = [];
  const jobs = options.jobs ?? new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const config = { [options.configKey ?? "remoteJobs"]: { allow } };
  const remote = new Remote({
    data: dir, store, jobs, config: () => config, clock: options.clock,
    notify: options.notify ?? ((session, text) => void told.push([session, text])),
  });
  cleanup.push(async () => {
    await remote.close();
    if (!options.jobs) {
      for (const job of store.listJobs(null)) if (job.pgid !== null) signalGroup(job.pgid, "SIGKILL");
      await jobs.shutdown();
    }
    if (!options.store) store.close();
  });
  return { dir, store, jobs, remote, told };
}

const b64 = (s: string) => Buffer.from(s).toString("base64");
const text = (v: Json, key: string): string => (v !== null && typeof v === "object" && typeof v[key] === "string" ? v[key] : "");
const unb64 = (v: Json) => Buffer.from(v.data, "base64").toString();

// Each test has stations of its own (directories, stores, clocks): they run at once.
describe("remote", { concurrency: true }, () => {
  test("transfer paths do not escape or follow links", () => {
    const dir = tempdir();
    for (const path of ["", "/etc/passwd", "../secret", "a/../../secret", "./a", "."]) {
      assert.throws(() => filePath(dir, path, true), Error, path);
    }
    symlinkSync("/tmp", join(dir, "link"));
    assert.throws(() => filePath(dir, "link/file", true));
    assert.throws(() => filePath(join(dir, "link"), "file", true));
    assert.ok(filePath(dir, "nested/file", true).startsWith(dir));
    assert.equal(filePath(dir, "a/./b", false), join(dir, "a", "b"), "a . inside is no component, as Path::components has it");
  });

  test("on Windows a backslash separates too, and a drive, a share or a stream is not relative", { skip: process.platform !== "win32" && "Windows only" }, () => {
    const dir = tempdir();
    for (const path of ["..\\outside.txt", "a\\..\\..\\secret", ".\\a", "C:\\Windows\\win.ini", "C:secret", "\\\\server\\share\\x", "\\x", "file:stream"]) {
      assert.throws(() => filePath(dir, path, true), Error, path);
    }
    assert.equal(filePath(dir, "nested\\file", false), join(dir, "nested", "file"));
  });

  // ── job_tests ──

  const call = (s: Station, peer: string, method: string, more: Json = {}) => s.remote.handle("ws", peer, { session: "s", key: "build-1", method, ...more });

  test("any workspace station may send a session a message, trusted for jobs or not", async () => {
    const r = station(["peer-a", "peer-b"]);
    await assert.rejects(call(r, "peer-c", "session.message"), Error, "not taken before the hub is there");
    const got: [string, Json][] = [];
    r.remote.setInbox(async (peer, request) => {
      got.push([peer, request]);
      return { thread: "EMBER/1.1" };
    });
    const answer = await call(r, "peer-c", "session.message", { to: "k", text: "hi" });
    assert.equal(answer.thread, "EMBER/1.1");
    const [peer, request] = got.pop()!;
    assert.deepEqual([peer, request.to, request.text], ["peer-c", "k", "hi"]);
    assert.equal((await call(r, "peer-c", "describe")).messages, true);
    await assert.rejects(call(r, "peer-c", "job.list"), Error, "jobs still need remoteJobs.allow");
  });

  test("a station from before Jobs is answered: task.* requests, remoteTasks.allow", async () => {
    const r = station(["peer-a"], { configKey: "remoteTasks" });
    assert.equal((await call(r, "peer-a", "describe")).jobs, true);
    await call(r, "peer-a", "task.prepare", { spec: { command: "true" } });
    const started = await call(r, "peer-a", "task.start");
    while ((await call(r, "peer-a", "task.get")).job.state === "running") await sleep(25);
    assert.equal((await call(r, "peer-a", "job.get")).job.id, started.job.id, "one job, by either name");
    assert.equal((await call(r, "peer-a", "task.list")).tasks.length, 1);
  });

  test("jobs are owned, idempotent and return files", async () => {
    const r = station(["peer-a", "peer-b"]);
    const spec = { spec: { command: "cat input > output; echo ran >> count", name: "copy" } };
    await call(r, "peer-a", "job.prepare", spec);
    await call(r, "peer-a", "file.put", { path: "input", offset: 0, data: b64("hello"), final: true });
    const first = await call(r, "peer-a", "job.start");
    while ((await call(r, "peer-a", "job.get")).job.state === "running") await sleep(25);
    const again = await call(r, "peer-a", "job.start");
    assert.equal(first.job.id, again.job.id);
    assert.equal(again.job.exitCode, 0);
    for (const [path, expected] of [["output", "hello"], ["count", "ran\n"]]) {
      assert.equal(unb64(await call(r, "peer-a", "file.get", { path })), expected);
    }
    await assert.rejects(call(r, "peer-b", "job.get"));
    await assert.rejects(call(r, "peer-c", "job.prepare", spec));
    await assert.rejects(call(r, "peer-a", "job.get", { session: "other" }));
    await assert.rejects(call(r, "peer-a", "job.prepare", { spec: { command: "echo wrong" } }));
    await assert.rejects(call(r, "peer-a", "file.put", { path: "input", offset: 0, data: "", final: true }));
  });

  test("withdrawal stops only the revoked peer's job", async () => {
    const r = station(["peer-a", "peer-b"]);
    for (const peer of ["peer-a", "peer-b"]) {
      await call(r, peer, "job.prepare", { spec: { command: FOREVER } });
      await call(r, peer, "job.start");
    }
    await r.remote.revoke("ws", ["peer-b"], true);
    assert.equal((await call(r, "peer-a", "job.get")).job.state, "stopped");
    assert.equal((await call(r, "peer-b", "job.get")).job.state, "running");
    await call(r, "peer-b", "job.stop");
  });

  // ── session_tests ──

  const callAs = (s: Station, session: string, key: string, method: string, more: Json = {}) => s.remote.handle("ws", "peer-a", { session, key, method, ...more });

  async function run(s: Station, session: string, key: string, command: string): Promise<Json> {
    await callAs(s, session, key, "job.prepare", { spec: { command } });
    await callAs(s, session, key, "job.start");
    // A real process: looked at every 25 ms (no deadline).
    for (;;) {
      const got = await callAs(s, session, key, "job.get");
      if (got.job.state !== "running") return got;
      await sleep(25);
    }
  }

  test("a session's jobs share one directory that closing removes", async () => {
    const r = station(["peer-a"]);
    await run(r, "s", "clone", "mkdir repo && echo built > repo/out");
    assert.equal((await run(r, "s", "build", "cat repo/out > copy")).job.exitCode, 0);
    assert.equal(unb64(await callAs(r, "s", "build", "file.get", { path: "copy" })), "built\n");
    // Another session starts empty and is left alone when the first closes.
    assert.notEqual((await run(r, "t", "look", "test -e repo")).job.exitCode, 0);
    await callAs(r, "s", "long", "job.prepare", { spec: { command: FOREVER } });
    const long = await callAs(r, "s", "long", "job.start");
    await r.remote.handle("ws", "peer-a", { method: "session.close", session: "s" });
    assert.ok(!existsSync(r.remote.room("ws", "peer-a", "s")));
    assert.equal(r.store.getJob(long.job.id)!.state, "stopped");
    await assert.rejects(callAs(r, "s", "build", "job.get"), Error, "records go with the directory");
    assert.ok(existsSync(join(r.remote.room("ws", "peer-a", "t"), "work")));
    // Closing again (a retried request) is fine.
    await r.remote.handle("ws", "peer-a", { method: "session.close", session: "s" });
  });

  test("the target removes idle session and old job directories itself", async () => {
    const r = station(["peer-a"]);
    await run(r, "idle", "a", "touch made");
    await run(r, "recent", "a", "touch made");
    const old = join(r.remote.root, "incoming", "from-before");
    mkdirSync(join(old, "work"), { recursive: true });
    writeJson(join(old, "task.json"), { spec: { command: "true" }, workspace: "ws", station: "peer-a", session: "x", key: "k" });
    const later = Date.now() + IDLE_MS + 1000;
    const record = join(r.remote.room("ws", "peer-a", "recent"), "session.json");
    const seen = readJson(record);
    seen.seen = later;
    writeJson(record, seen);
    await r.remote.sweep(later);
    assert.ok(!existsSync(r.remote.room("ws", "peer-a", "idle")));
    assert.ok(existsSync(r.remote.room("ws", "peer-a", "recent")));
    assert.ok(!existsSync(old));
  });

  test("closing a source session asks each used station until answered", async () => {
    const clock = testClock();
    const r = station(["peer-a"], { clock });
    mkdirSync(join(r.dir, "mesh"), { recursive: true });
    r.remote.recordUse("ws", "s", "up");
    r.remote.recordUse("ws", "s", "old");
    r.remote.recordUse("ws", "s", "down");
    r.remote.recordUse("ws", "other", "up");
    const asked: string[] = [];
    let down = 0;
    r.remote.attach(async (station, _workspace, request) => {
      assert.equal(request.method, "session.close");
      assert.equal(request.session, "s");
      asked.push(station);
      const n = station === "down" ? down++ : 0;
      if (station === "old") throw new Refused("unsupported peer method: session.close");
      if (station === "down" && n < 2) throw new Error("offline");
      return { closed: true };
    });
    r.remote.closeSession("s");
    const path = r.remote.usedPath("s");
    // Every station answered, as many rounds as it takes.
    await rounds("every station answered", clock, "1 second", () => !existsSync(path));
    assert.equal(asked.filter((s) => s === "up").length, 1);
    assert.equal(asked.filter((s) => s === "old").length, 1);
    assert.equal(asked.filter((s) => s === "down").length, 3);
    assert.ok(existsSync(r.remote.usedPath("other")));
  });

  // ── recovery_tests ──

  test("a persisted receipt reconnects and delivers to its original session", async () => {
    const clock = testClock();
    const first = station([]);
    const path = first.remote.outgoing("ws", "original-session", "target", "stable-key");
    writeJson(path, { workspace: "ws", session: "original-session", station: "target", key: "stable-key", delivered: false });
    await first.remote.close();
    const messages: [string, string][] = [];
    const restarted = station([], { clock, dir: first.dir, store: first.store, jobs: first.jobs, notify: (s, t) => void messages.push([s, t]) });
    let attempts = 0;
    restarted.remote.attach(async (station, _workspace, request) => {
      const n = attempts++;
      assert.equal(station, "target");
      assert.equal(request.workspace, "ws");
      assert.equal(request.session, "original-session");
      assert.equal(request.key, "stable-key");
      assert.equal(request.method, "job.get", "recovery queries; it does not resubmit the command");
      if (n < 2) throw new Error("offline");
      return { job: { state: "exited", exitCode: 0 }, log: "done", notices: [] };
    });
    await rounds("delivered", clock, "1 second", () => readJson(path).delivered === true);
    assert.equal(attempts, 3);
    assert.equal(messages.length, 1);
    assert.equal(messages[0][0], "original-session");
    assert.ok(messages[0][1].includes("done"));
    assert.equal(readJson(path).delivered, true);
  });

  // ── two stations ──

  /// A source station "A" and a target "B" that trusts it, in one workspace; A's calls reach B as the transport would
  /// carry them (B's errors come back as Refused).
  function pair(allow = ["A"]) {
    const clock = testClock();
    const a = station([], { clock });
    const b = station(allow);
    mkdirSync(join(a.dir, "mesh"), { recursive: true });
    writeFileSync(join(a.dir, "mesh", "cloud.json"), JSON.stringify({ workspace: "ws", station: "A" }));
    const home = join(a.dir, "work");
    mkdirSync(home);
    a.store.insertSession({ key: "s1", connect: "ds", runtime: "claude", profile: "cc", workspace: home, token: "t1", createdBy: "ann", createdAt: Date.now(), lastActiveAt: Date.now() });
    const asked: Json[] = [];
    const transport: PeerCall = async (target, workspace, request) => {
      asked.push(request);
      if (target === "" && request.method === "peers") return { workspace: "ws", stations: [{ id: "A" }, { id: "B" }], current: true };
      if (target !== "B") throw new Error("peer is not another station in this workspace");
      const answer = await answerPeer(b.remote, workspace ?? "ws", "A", JSON.parse(JSON.stringify(request)));
      if ("error" in answer) throw new Refused(answer.error);
      return answer.result;
    };
    a.remote.attach(transport);
    const tools = remoteTools(a.remote);
    const use = async (name: string, args: Json) => JSON.parse(await tools.find((t) => t.name === name)!.run("s1", args));
    return { a, b, home, clock, use, asked };
  }

  test("a session runs a job on another station: inputs up, its notices and end told here, its artifact down", async () => {
    const { a, b, home, clock, use } = pair();
    assert.deepEqual((await use("station_list", {})).stations, [{ id: "A" }, { id: "B" }]);
    const described = await use("station_list", { station: "B" });
    assert.equal(described.jobs, true);
    assert.equal(described.fileChunkBytes, 256 * 1024);
    // An input bigger than one chunk goes up in pieces.
    const input = "abc\n".repeat(100_000);
    writeFileSync(join(home, "input.txt"), input);
    // It waits at a gate (a file to appear: a fifo is no file Windows' Node can write) until its notice has been told,
    // so that comes before its end.
    const gate = join(tempdir(), "gate");
    const command = `while [ ! -f '${gate}' ]; do sleep 0.05; done; tr a-z A-Z < input.txt > out.txt`;
    assert.deepEqual(await use("station_job", { station: "B", key: "k1", action: "prepare", command, name: "upper" }), { key: "k1", prepared: true });
    const up = await use("station_file", { station: "B", key: "k1", direction: "upload", path: "input.txt", local: join(home, "input.txt") });
    assert.deepEqual(up, { uploaded: join(home, "input.txt"), bytes: input.length });
    const started = await use("station_job", { station: "B", key: "k1", action: "start" });
    assert.equal(started.job.state, "running");
    const job = b.store.getJob(started.job.id)!;
    assert.equal(job.sessionKey, "remote:ws:A:s1");
    // Its spec says who asked for it.
    const listed = await use("station_job", { station: "B", action: "list" });
    assert.deepEqual(listed.jobs[0].spec, { name: "upper", command, requestedBy: "ann" });
    // What it says on the way reaches the session that started it, once (as many rounds as it takes).
    b.jobs.notified(job.token, "half way");
    await rounds("its notice is told", clock, "5 seconds", () => a.told.length > 0);
    assert.equal(a.told.length, 1);
    assert.equal(a.told[0][0], "s1");
    assert.ok(a.told[0][1].startsWith("Remote job k1 on B: {") && a.told[0][1].includes("half way"), a.told[0][1]);
    await writeFile(gate, "go");
    await until("it ends", () => b.store.getJob(job.id)!.state !== "running");
    await rounds("its end is told", clock, "5 seconds", () => a.told.length > 1);
    assert.equal(a.told.length, 2);
    assert.ok(a.told[1][1].includes('"state":"exited"'), a.told[1][1]);
    // Delivered: not told again.
    await Effect.runPromise(clock.adjust("30 seconds"));
    await turn();
    assert.equal(a.told.length, 2);
    const down = await use("station_file", { station: "B", key: "k1", direction: "download", path: "out.txt", local: "out.txt" });
    assert.deepEqual(down, { downloaded: join(home, "out.txt"), bytes: input.length });
    assert.equal(readFileSync(join(home, "out.txt"), "utf8"), input.toUpperCase());
    await assert.rejects(use("station_file", { station: "B", key: "k1", direction: "download", path: "out.txt", local: "out.txt" }), /already exists/);
    await assert.rejects(use("station_file", { station: "B", key: "k1", direction: "download", path: "out.txt", local: "/elsewhere/out.txt" }), /inside this session workspace/);
    // The chat closed: the target's directory for it goes.
    const room = b.remote.room("ws", "A", "s1");
    assert.ok(existsSync(room));
    const asleep = clock.asked();
    a.remote.closeSession("s1");
    await until("its directory goes", () => !existsSync(room));
    // Every station answered: the record goes at the next round.
    await until("the first round is over", () => clock.asked() > asleep);
    assert.ok(existsSync(a.remote.usedPath("s1")));
    await Effect.runPromise(clock.adjust("60 seconds"));
    await until("the record goes", () => !existsSync(a.remote.usedPath("s1")));
  });

  test("a start the target refuses is final, and asked for again only by a new start", async () => {
    const { a, use, asked, clock } = pair([]);
    await assert.rejects(use("station_job", { station: "B", key: "k", action: "start" }), (e: Error) => e instanceof Refused && /remoteJobs.allow/.test(e.message));
    const record = readJson(a.remote.outgoing("ws", "s1", "B", "k"));
    assert.deepEqual([record.delivered, record.refused], [true, true]);
    const before = asked.length;
    await Effect.runPromise(clock.adjust("1 minute"));
    await turn();
    assert.equal(asked.filter((r) => r.method === "job.get").length, asked.slice(0, before).filter((r) => r.method === "job.get").length, "not followed");
    await assert.rejects(use("station_job", { station: "B", key: "", action: "get" }), /station and key are required/);
    await assert.rejects(use("station_job", { station: "B", key: "k", action: "run" }), /unknown job action/);
  });

  // ── the control plane tells the workspace by a new id ──

  /// Two stations of one workspace, each as it runs: its cloud.json and what the control plane tells it (`told`, a
  /// `state` frame), the peer transport between their endpoints, the roster followed, remote jobs allowed from the
  /// other. "A" has a chat `s1` whose tools reach "B".
  async function workspaceOf(first: string) {
    const mesh = memoryMesh();
    const clock = testClock();
    const ends = await Promise.all([1, 2].map((n) => mesh.bind({ secretKey: Buffer.alloc(32, n), alpns: [PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" })));
    const ids = ends.map((e) => e.id());
    const where = new Map(ends.map((e) => [e.id(), `127.0.0.1:${e.sockets()[0]!.split(":").at(-1)}`]));
    const peers = ids.map((id) => ({ id }));
    const [a, b] = ends.map((endpoint, i) => {
      const s = station([ids[1 - i]!], i === 0 ? { clock } : {});
      writeState(s.dir, {
        provider: "comma", origin: "https://api.comma.test", station: endpoint.id(), workspace: first, workspace_name: "Team", name: "S",
        relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [], revocations: [],
      });
      const cloud = new Cloud(s.dir);
      const unfollow = followRoster(cloud, s.remote, { listen: () => () => {} });
      void (async () => {
        for (;;) {
          const conn = await endpoint.accept();
          if (!conn) return;
          void servePeer(conn, cloud, s.remote).catch(() => {});
        }
      })();
      s.remote.attach(peerCall(endpoint, cloud, (id) => ({ id, ips: [where.get(id)!] })));
      cleanup.push(async () => {
        unfollow();
        cloud.close();
        await endpoint.close();
      });
      /// What the control plane says now; then whatever the roster's change set going here is over.
      const hears = async (workspace: string, was: string[], roster = peers) => {
        applyState(cloud, JSON.stringify({ type: "state", workspace, workspace_was: was, peers: roster }));
        await s.remote.sweep(0);
      };
      return { ...s, id: endpoint.id(), cloud, hears };
    });
    await a!.hears(first, []);
    await b!.hears(first, []);
    const home = join(a!.dir, "work");
    mkdirSync(home);
    a!.store.insertSession({ key: "s1", connect: "ds", runtime: "claude", profile: "cc", workspace: home, token: "t1", createdBy: "ann", createdAt: 1, lastActiveAt: 1 });
    const tools = remoteTools(a!.remote);
    const use = async (name: string, args: Json) => JSON.parse(await tools.find((t) => t.name === name)!.run("s1", args));
    const job = (action: string, key: string, more: Json = {}) => use("station_job", { station: b!.id, key, action, ...more });
    return { a: a!, b: b!, clock, job };
  }

  const records = (s: Station, name: string) => readdirSync(join(s.dir, "remote", name)).filter((n) => !n.endsWith(".tmp")).sort();

  test("a rename carries a running job over: its directory, its records and who follows it, whichever station hears first", async () => {
    const { a, b, clock, job } = await workspaceOf("wsp_x");
    await job("prepare", "k1", { command: FOREVER });
    const started = await job("start", "k1");
    assert.equal(started.job.state, "running");
    const row = () => b.store.getJob(started.job.id)!;
    assert.equal(row().sessionKey, `remote:wsp_x:${a.id}:s1`);
    const room = b.remote.room("wsp_x", a.id, "s1");
    const [incoming, outgoing] = [records(b, "incoming"), records(a, "outgoing")];

    // The target hears of the new id first: the job runs on, and the source, which still says the old id, is answered.
    await b.hears("grp_y", ["wsp_x"]);
    assert.equal(b.cloud.state!.workspace, "grp_y");
    assert.equal(row().state, "running");
    assert.equal((await job("get", "k1")).job.state, "running");
    // The source still follows it: what the job says on the way is told to its chat.
    b.jobs.notified(row().token, "half way");
    await rounds("its notice is told", clock, "5 seconds", () => a.told.length > 0);
    assert.ok(a.told[0]![1].includes("half way"), a.told[0]![1]);

    // The source hears too. The same job, directory and records: nothing is made anew under the new id.
    await a.hears("grp_y", ["wsp_x"]);
    assert.equal((await job("get", "k1")).job.state, "running");
    await job("prepare", "k2", { command: "pwd > where.txt" });
    await job("start", "k2");
    assert.equal((await job("list", "")).jobs.length, 2);
    await until("the second job ends", () => existsSync(join(room, "work", "where.txt")));
    assert.deepEqual(records(b, "sessions"), [basename(room)]);
    assert.deepEqual(records(b, "incoming").filter((n) => incoming.includes(n)), incoming);
    assert.deepEqual(records(a, "outgoing").filter((n) => outgoing.includes(n)), outgoing);
    assert.equal(records(a, "outgoing").length, 2);
    assert.equal(row().state, "running");

    // The chat closes: the target, asked under the name it knows the directory by, removes it and stops the job.
    a.remote.closeSession("s1");
    await until("its directory goes", () => !existsSync(room));
    assert.equal(row().state, "stopped");
  });

  test("a source that hears of the new id first starts and follows a job on a target that has not", async () => {
    const { a, b, job } = await workspaceOf("wsp_x");
    await a.hears("grp_y", ["wsp_x"]);
    await job("prepare", "k1", { command: FOREVER });
    const started = await job("start", "k1");
    assert.equal(started.job.state, "running");
    // Not refused: the record says it is followed.
    const record = readJson(a.remote.outgoing("wsp_x", "s1", b.id, "k1"));
    assert.deepEqual([record.workspace, record.delivered, record.refused], ["wsp_x", false, undefined]);
    // And the other way round: the target's requests are answered here.
    assert.equal(text(await b.remote.ask(a.id, { method: "describe" }), "os") !== "", true);
    await b.hears("grp_y", ["wsp_x"]);
    assert.equal(b.store.getJob(started.job.id)!.state, "running");
    assert.equal((await job("get", "k1")).job.state, "running");
    assert.equal((await job("stop", "k1")).job.state, "stopped");
  });

  test("a new id that does not lead back to the one held is another workspace: its jobs stop", async () => {
    const { a, b, job } = await workspaceOf("wsp_x");
    await job("prepare", "k1", { command: FOREVER });
    const started = await job("start", "k1");
    // Told a workspace with a history of its own, the source still on its roster: not a rename.
    await b.hears("grp_z", ["wsp_q"]);
    assert.equal(b.store.getJob(started.job.id)!.state, "stopped");
    await assert.rejects(job("get", "k1"), (e: Error) => e instanceof Refused && /outside this workspace/.test(e.message));
    assert.equal(a.cloud.state!.workspace, "wsp_x");
  });
});
