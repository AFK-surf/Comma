// A Workload's durable archive: a parked station exports its root over the connection as a zstd tar into signed
// object storage parts, without its live databases but with their snapshots; a Container's start restores it from the
// parts onto its empty disk before any station runs there, the snapshots in the databases' places; the same operation
// answers again and another is refused. The object store is a local HTTP server that honours If-None-Match.
import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { delimiter, dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Duration, Effect, Exit } from "effect";
import { ClaudeDriver } from "../../src/agents/claude.ts";
import { runnerId } from "../../src/agents/process.ts";
import { runnersDir } from "../../src/agents/runner.ts";
import { hubConfig } from "../../src/sessions/config.ts";
import { Hub } from "../../src/sessions/hub.ts";
import { InternalChat } from "../../src/sessions/internal.ts";
import { newSession, say } from "../../src/sessions/lifecycle.ts";
import { chatTools } from "../../src/tools/chat.ts";
import { openAgentsDoor } from "../../src/tools/http.ts";
import { McpEndpoint } from "../../src/tools/mcp.ts";
import { makeConnector } from "../../src/connector/connector.ts";
import { RESTORE_ARCHIVE_ENV, restoreArchiveCommand } from "../../src/connector/cli.ts";
import { ARCHIVE_PART_BYTES, type ArchiveState, RESTORE_VALUE_LIMIT, archiveStateDir, restoreBeforeStart, signedStorageUrl } from "../../src/connector/durable-archive.ts";
import { stationArchiveState, stationIdle } from "../../src/connector/service.ts";
import { JOB_COMMAND_NAME, Jobs } from "../../src/jobs/jobs.ts";
import { linkTranscripts } from "../../src/sessions/agent-home.ts";
import { Store } from "../../src/store/store.ts";
import { Tasks } from "../../src/tasks/tasks.ts";
import { Rig, settle } from "../hub-fakes.ts";
import { eventually } from "./support/eventually.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);

async function objectStore(options: { rejectPuts?: boolean; failPuts?: number } = {}) {
  const objects = new Map<string, Buffer>();
  const puts = new Map<string, number>();
  const server = createServer(async (req, res) => {
    const key = new URL(req.url ?? "/", "http://store").pathname;
    if (req.method === "PUT" && options.rejectPuts) return void res.writeHead(403).end();
    if (req.method === "PUT") puts.set(key, (puts.get(key) ?? 0) + 1);
    // A flaky store fails each part's first PUTs in turn: unavailable, throttled, then the connection drops.
    const attempt = puts.get(key) ?? 0;
    if (req.method === "PUT" && attempt <= (options.failPuts ?? 0)) {
      if (attempt % 3 === 0) return void req.socket.destroy();
      return void res.writeHead(attempt % 3 === 1 ? 503 : 429).end();
    }
    if (req.method === "PUT") {
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(chunk as Buffer);
      if (objects.has(key) && req.headers["if-none-match"] === "*") return void res.writeHead(412).end();
      objects.set(key, Buffer.concat(chunks));
      return void res.writeHead(200).end();
    }
    const body = objects.get(key);
    if (!body) return void res.writeHead(404).end();
    res.writeHead(200).end(body);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const url = (key: string) => `${base}/${key}?signature=x`;
  return { objects, puts, url, close: () => new Promise<void>((resolve) => server.close(() => resolve())) };
}

/** The station's own state as the service gives it: one live database and its snapshot. */
function stationState(root: string): ArchiveState {
  const data = join(root, ".station");
  mkdirSync(data, { recursive: true });
  return {
    live: () => [join(data, "stillfail.db")],
    runtime: () => [join(data, "run")],
    snapshots: async () => {
      const file = join(tempDir(), "snapshot.db");
      writeFileSync(file, "consistent snapshot");
      return { entries: [{ name: ".station/stillfail.db", file }], done: () => {} };
    },
    sessions: () => 0,
  };
}

/** Bytes zstd cannot shrink, the same every run (a fixed xorshift sequence). */
function incompressible(length: number): Buffer {
  const out = Buffer.alloc(length);
  let x = 0x9e3779b9;
  for (let i = 0; i < length; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    out[i] = x & 0xff;
  }
  return out;
}

type ObjectStore = Awaited<ReturnType<typeof objectStore>>;
let manifests = 0;
/**
 * What a Container's start names its archive with, as Salix makes it: the manifest of the parts written next to them,
 * and base64 of the JSON that names the archive and the manifest's URL.
 */
function restoreValue(store: ObjectStore, operation: string, bytes: number, parts: Array<{ get_url: string; bytes: number }>, manifest: unknown = { operation, bytes, parts }) {
  const key = `${operation}/restore-manifest-${++manifests}`;
  store.objects.set(`/${key}`, Buffer.from(typeof manifest === "string" ? manifest : JSON.stringify(manifest)));
  return Buffer.from(JSON.stringify({ operation, bytes, manifest_url: store.url(key) })).toString("base64");
}
const partsOf = (url: (key: string) => string, operation: string, bytes: number) =>
  Array.from({ length: Math.ceil(bytes / ARCHIVE_PART_BYTES) }, (_, i) => ({ get_url: url(`${operation}/${i}`), bytes: Math.min(ARCHIVE_PART_BYTES, bytes - i * ARCHIVE_PART_BYTES) }));
/** The image's step before it starts the station: the archive onto `root`. */
const beforeStart = (root: string, restore: string) => Effect.runPromiseExit(restoreBeforeStart({ root, dir: archiveStateDir(root), restore, allowedUrl: signedStorageUrl("127.0.0.1") }));

test("a parked Workload station exports to signed parts, and a Container's start restores them onto its disk before a station runs there", async () => {
  const store = await objectStore();
  try {
    const source = tempDir();
    writeFileSync(join(source, "work.txt"), "user work");
    writeFileSync(join(source, "big.bin"), Buffer.alloc(ARCHIVE_PART_BYTES + 1000, 3));
    const state = stationState(source);
    writeFileSync(join(source, ".station", "stillfail.db"), "live, mid-write");
    const c = makeConnector({ root: source, env: { HOME: tempDir() }, workloadCredential: "w", archiveHostSuffix: "127.0.0.1" }, undefined, { archive: state, agentsIdle: () => true });
    const call = (method: string, params: Record<string, unknown>) => run(c.dispatchForTest(method, method, params)) as Promise<Record<string, any>>;
    const transfers = Array.from({ length: 4 }, (_, i) => ({ put_url: store.url(`op1/${i}`), get_url: store.url(`op1/${i}`) }));

    const refused = await Effect.runPromiseExit(c.dispatchForTest("e", "archive_export", { operation: "op1", transfers }));
    assert.ok(Exit.isFailure(refused) && String(refused.cause).includes("requires quiescence"));
    await call("cloud_runtime_quiesce", { token: "t" });
    assert.equal((await call("archive_export", { operation: "op1", transfers })).phase, "preparing");
    let exported: Record<string, any> = {};
    await eventually(async () => {
      exported = await call("archive_status", { operation: "op1" });
      return exported.phase !== "preparing";
    }, "the export");
    assert.equal(exported.phase, "exported");
    assert.equal(exported.uploaded_bytes, exported.bytes);
    // A lost reply: the same operation answers again.
    assert.equal((await call("archive_export", { operation: "op1", transfers })).phase, "exported");
    await run(c.close());

    // A new Container: its disk is empty, and its start names the archive.
    const target = join(tempDir(), "workspace");
    const bytes = exported.bytes as number;
    const restore = restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes));
    assert.ok(restore.length < 400 && restore.length < RESTORE_VALUE_LIMIT, `the start's value is ${restore.length} bytes`);
    const restored = await beforeStart(target, restore);
    assert.ok(Exit.isSuccess(restored), String(Exit.isFailure(restored) && restored.cause));
    const { entries: _entries, files: _files, timings: _timings, ...receipt } = restored.value;
    assert.deepEqual(receipt, { operation: "op1", phase: "restored", bytes });
    assert.equal(readFileSync(join(target, "work.txt"), "utf8"), "user work");
    assert.equal(readFileSync(join(target, "big.bin")).length, ARCHIVE_PART_BYTES + 1000);
    // The databases are in their places before anything opens them: nothing is staged for a second start.
    assert.equal(readFileSync(join(target, ".station", "stillfail.db"), "utf8"), "consistent snapshot");
    assert.ok(!existsSync(join(target, ".station", "restore")));
    // The same start again (its reply was lost) answers the same; another archive is not this disk's.
    assert.ok(Exit.isSuccess(await beforeStart(target, restore)));
    const other = await beforeStart(target, restoreValue(store, "op2", bytes, partsOf(store.url, "op1", bytes)));
    assert.ok(Exit.isFailure(other) && String(other.cause).includes("restore operation changed"));

    // The station that then starts there says which archive its disk is, and takes none over its connection.
    const t = makeConnector({ root: target, env: { HOME: tempDir() }, workloadCredential: "w", archiveHostSuffix: "127.0.0.1" }, undefined, { archive: stationState(target) });
    assert.deepEqual(await run(t.dispatchForTest("s", "archive_status", { kind: "import", operation: "op1" })), restored.value);
    const unknown = await Effect.runPromiseExit(t.dispatchForTest("s", "archive_status", { kind: "import", operation: "op2" }));
    assert.ok(Exit.isFailure(unknown) && String(unknown.cause).includes("archive import unavailable"));
    const overConnection = await Effect.runPromiseExit(t.dispatchForTest("i", "archive_import", { operation: "op1", bytes, parts: partsOf(store.url, "op1", bytes) }));
    assert.ok(Exit.isFailure(overConnection), "a running station imported an archive");
    await run(t.close());
  } finally {
    await store.close();
  }
});

test("an export retries a part the store failed, throttled or dropped, backing off 250, 500, 1000 ms", async () => {
  const store = await objectStore({ failPuts: 3 });
  try {
    const source = tempDir();
    writeFileSync(join(source, "work.txt"), "user work");
    const c = makeConnector({ root: source, env: { HOME: tempDir() }, workloadCredential: "w", archiveHostSuffix: "127.0.0.1", testClock: true }, undefined, { archive: stationState(source), agentsIdle: () => true });
    const call = (method: string, params: Record<string, unknown>) => run(c.dispatchForTest(method, method, params)) as Promise<Record<string, any>>;
    const transfers = [{ put_url: store.url("op1/0"), get_url: store.url("op1/0") }];
    const puts = () => store.puts.get("/op1/0") ?? 0;
    await call("cloud_runtime_quiesce", { token: "t" });
    await call("archive_export", { operation: "op1", transfers });
    for (const [failed, delay] of [[1, 250], [2, 500], [3, 1000]] as const) {
      await eventually(() => puts() === failed && c.sleepsForTest() > 0, `backoff after failed PUT ${failed}`);
      await run(c.advanceClockForTest(Duration.millis(delay - 1)));
      assert.ok(c.sleepsForTest() > 0 && puts() === failed, `the backoff after PUT ${failed} ended before ${delay} ms`);
      await run(c.advanceClockForTest(Duration.millis(1)));
    }
    let status: Record<string, any> = {};
    await eventually(async () => {
      status = await call("archive_status", { operation: "op1" });
      return status.phase !== "preparing";
    }, "the export");
    assert.equal(status.phase, "exported", String(status.error));
    assert.equal(puts(), 4);
    assert.equal(status.uploaded_bytes, status.bytes);
    await run(c.close());
  } finally {
    await store.close();
  }
});

/** What a station's start seeds in its data directory: jobs/bin's command and the link of its former name, a profile's
 * transcripts link (absolute). */
async function started(root: string) {
  const data = join(root, ".station");
  const store = Store.open(":memory:");
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  linkTranscripts(data, [{ id: "p", runtimes: ["claude"], home: join(data, "homes", "p") }]);
  await jobs.shutdown();
  store.close();
}

/** Exports `source` (a parked station's root) as `operation`: its bytes. */
async function exportOf(store: Awaited<ReturnType<typeof objectStore>>, source: string, operation: string, state: ArchiveState = stationState(source)): Promise<number> {
  const c = makeConnector({ root: source, env: { HOME: tempDir() }, workloadCredential: "w", archiveHostSuffix: "127.0.0.1" }, undefined, { archive: state, agentsIdle: () => true });
  const call = (method: string, params: Record<string, unknown>) => run(c.dispatchForTest(method, method, params)) as Promise<Record<string, any>>;
  const transfers = Array.from({ length: 2 }, (_, i) => ({ put_url: store.url(`${operation}/${i}`), get_url: store.url(`${operation}/${i}`) }));
  await call("cloud_runtime_quiesce", { token: "t" });
  await call("archive_export", { operation, transfers });
  let exported: Record<string, any> = {};
  await eventually(async () => {
    exported = await call("archive_status", { operation });
    return exported.phase !== "preparing";
  }, "the export");
  assert.equal(exported.phase, "exported", String(exported.error));
  await run(c.close());
  return exported.bytes as number;
}

test("the station that starts on a restored disk seeds over what the archive holds of an earlier start", async () => {
  const store = await objectStore();
  try {
    const source = tempDir();
    await started(source);
    writeFileSync(join(source, "work.txt"), "user work");
    const bytes = await exportOf(store, source, "op1");

    const target = join(tempDir(), "workspace");
    const restored = await beforeStart(target, restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes)));
    assert.ok(Exit.isSuccess(restored), String(Exit.isFailure(restored) && restored.cause));
    const data = join(target, ".station");
    assert.equal(readFileSync(join(target, "work.txt"), "utf8"), "user work");
    assert.equal(readlinkSync(join(data, "jobs", "bin", "ember-job")), JOB_COMMAND_NAME);
    // The station starts for the first time on this disk, after the restore: its seeds and the archive's agree.
    await started(target);
    assert.equal(readlinkSync(join(data, "jobs", "bin", "ember-job")), JOB_COMMAND_NAME);
    // The archive's link (relative) and the start's (absolute) name the same place: the restored one stays.
    assert.equal(resolve(join(data, "homes", "p"), readlinkSync(join(data, "homes", "p", "projects"))), join(data, "transcripts", "claude"));
  } finally {
    await store.close();
  }
});

test("the station that starts on a restored disk says hello with how far it has each Task, not as one that has none", async () => {
  const store = await objectStore();
  const b = new Rig();
  try {
    // The Cloud VM's station takes part in a Task kept on Salix, and was given two Messages of it.
    const tasks = new Tasks(b.hub, () => null);
    b.hub.setTasks(tasks);
    tasks.begin();
    tasks.attachHost("salix", async () => ({}));
    await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
    const message = (seq: number, text: string) => ({ seq, author: { kind: "person", id: "ann@example.com" }, text, declared: null, at: 0 });
    await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [message(1, "build it"), message(2, "and test it")], through: 2 });
    await settle();
    // Its disk: the database under the Workload's root, archived as the station archives it.
    const source = tempDir();
    const data = join(source, ".comma", "station");
    mkdirSync(data, { recursive: true });
    b.store.db.exec(`VACUUM INTO '${join(data, "stillfail.db")}'`);
    const bytes = await exportOf(store, source, "op1", stationArchiveState(source, data, () => b.store.listSessions().length));
    assert.ok(b.store.listSessions().length > 0, "the archived station holds Sessions");

    // The VM wakes: a new Container, the archive onto its disk, then its station.
    const target = join(tempDir(), "workspace");
    const restored = await beforeStart(target, restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes)));
    assert.ok(Exit.isSuccess(restored), String(Exit.isFailure(restored) && restored.cause));
    const woken = Store.open(join(target, ".comma", "station", "stillfail.db"));
    try {
      const asked: unknown[] = [];
      const wokenTasks = new Tasks({ store: woken } as ConstructorParameters<typeof Tasks>[0], () => null);
      wokenTasks.attachHost("salix", async (request) => {
        asked.push(request);
        return {};
      });
      assert.deepEqual(asked, [{ method: "task.hello", tasks: [{ task: "cnv_1", fetched: 2 }] }]);
    } finally {
      woken.close();
    }
  } finally {
    await b.close();
    await store.close();
  }
});

/**
 * What one run of a station leaves in its data directory's `run` (ops/files.ts `runtimeDir`): its lock, pid and port,
 * and the record, output and socket path of a runner it kept `id` under. The pids are this test's: alive, and nothing
 * of a station's or a runner's on the machine that reads them next.
 */
function ranThere(data: string, id: string) {
  const run = join(data, "run");
  const runners = runnersDir(data);
  mkdirSync(runners, { recursive: true });
  writeFileSync(join(run, "station.lock"), "");
  writeFileSync(join(run, "station.json"), JSON.stringify({ pid: process.pid, startedAt: 1, version: "0.0.0", handoff: 1, drain: 1, channel: 1 }) + "\n");
  writeFileSync(join(run, "hub.json"), JSON.stringify({ pid: process.pid }) + "\n");
  writeFileSync(join(run, "ports.json"), '{"admin":4760}\n');
  const at = (ext: string) => join(runners, `${id}.${ext}`);
  writeFileSync(at("json"), JSON.stringify({ id, runner: process.pid, pid: process.pid, pgid: process.pid, startedAt: 1, program: "claude", args: [], socket: at("sock"), out: at("out"), err: at("err") }) + "\n");
  writeFileSync(at("out"), "what its agent said then\n");
  writeFileSync(at("err"), "");
}

test("a station's runtime state is no part of its disk's archive: its run directory and its runtime homes' .tmp are left out, the rest of its data travels", async () => {
  const store = await objectStore();
  try {
    const source = tempDir();
    const data = join(source, ".comma", "station");
    mkdirSync(join(data, "transcripts"), { recursive: true });
    writeFileSync(join(data, "config.json"), "{}");
    writeFileSync(join(data, "transcripts", "one.jsonl"), "a transcript\n");
    // A directory of the user's that happens to be called `run` is theirs: only the station's own is left out.
    mkdirSync(join(source, "project", "run"), { recursive: true });
    writeFileSync(join(source, "project", "run", "notes.txt"), "user work");
    ranThere(data, "codex-sh-e4wolgtbetmntcyg3wgk3-73654c7b2f");
    // A Codex home: its sessions travel; the plugin marketplace an older Codex downloaded into its .tmp does not.
    const home = join(data, "homes", "sh-e4wolgtbetmntcyg3wgk3fph");
    mkdirSync(join(home, ".tmp", "plugins", "plugins", "vercel"), { recursive: true });
    writeFileSync(join(home, ".tmp", "plugins.sha"), "abc\n");
    writeFileSync(join(home, ".tmp", "plugins", "plugins", "vercel", "plugin.json"), "{}");
    writeFileSync(join(home, "state_5.sqlite"), "its sessions");
    const bytes = await exportOf(store, source, "op1", stationArchiveState(source, data, () => 0));

    const target = join(tempDir(), "workspace");
    const restored = await beforeStart(target, restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes)));
    assert.ok(Exit.isSuccess(restored), String(Exit.isFailure(restored) && restored.cause));
    assert.deepEqual(readdirSync(join(target, ".comma", "station")).sort(), ["config.json", "homes", "transcripts"], "the archive carries the station's runtime state");
    assert.deepEqual(readdirSync(join(target, ".comma", "station", "homes", "sh-e4wolgtbetmntcyg3wgk3fph")), ["state_5.sqlite"], "the archive carries a home's .tmp");
    assert.equal(readFileSync(join(target, ".comma", "station", "transcripts", "one.jsonl"), "utf8"), "a transcript\n");
    assert.equal(readFileSync(join(target, "project", "run", "notes.txt"), "utf8"), "user work");
  } finally {
    await store.close();
  }
});

test("a VM woken from an archive made before exports left runtime state out: the restore drops the other Container's runner records, and the station starts a turn for the Message that woke it", async () => {
  const store = await objectStore();
  const before = { root: process.env.SALIX_CONNECTOR_ROOT, restore: process.env[RESTORE_ARCHIVE_ENV], path: process.env.PATH };
  // The fake `claude`, under the real runner. Short roots: the runners' sockets live under them (104 bytes on macOS).
  process.env.PATH = `${join(dirname(fileURLToPath(import.meta.url)), "..", "fake")}${delimiter}${process.env.PATH}`;
  const roots = [mkdtempSync("/tmp/da-"), mkdtempSync("/tmp/da-")];
  const [source, target] = roots as [string, string];
  const dataOf = (root: string) => join(root, ".comma", "station");
  const station = (data: string) => {
    const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 1 }, data);
    const db = Store.open(join(data, "stillfail.db"));
    const door = { url: "" };
    const hub = new Hub({ config: () => config, store: db, chats: () => undefined, drivers: [new ClaudeDriver({ data })], mcpUrl: () => door.url, internal: new InternalChat() });
    return { db, hub, door };
  };
  try {
    // The VM before it was archived: its station holds a Session, and its run directory says what ran in that
    // Container (the Session's runner among it).
    mkdirSync(join(dataOf(source), "homes", "cc"), { recursive: true });
    writeFileSync(join(dataOf(source), "homes", "cc", ".credentials.json"), "{}");
    const was = station(dataOf(source));
    const [key, thread] = newSession(was.hub, { runtime: "claude", createdBy: "ada@x.com" });
    await was.hub.shutdown();
    ranThere(dataOf(source), runnerId("claude", key));
    // Archived as stations did before: its runtime state with the rest.
    const bytes = await exportOf(store, source, "op1", { ...stationArchiveState(source, dataOf(source), () => 1), runtime: () => [] });
    was.db.close();

    // The wake: a new Container, the archive onto its disk by the image's command, then its station.
    process.env.SALIX_CONNECTOR_ROOT = target;
    process.env[RESTORE_ARCHIVE_ENV] = restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes));
    assert.equal(await restoreArchiveCommand([], "127.0.0.1", dataOf(target)), 0);
    const woken = station(dataOf(target));
    const mcp = new McpEndpoint((token) => woken.db.sessionByToken(token)?.key, chatTools(woken.hub));
    const served = await openAgentsDoor({ port: 0 }, mcp, () => ({ status: 400, body: { error: "no jobs" } }));
    woken.door.url = served.url;
    try {
      await woken.hub.takeUp();
      woken.hub.recover();
      assert.ok(woken.db.getSession(key), "its Sessions are on the restored disk");
      // The Message that woke it reaches its Session.
      const said = () => woken.db.messagesBefore(thread.id, null, 10).map((m) => [m.authorKind, m.text]);
      // Real processes, with no deadline: looked at as the store changes, until the turn is over or the station says
      // none started.
      const over = new Promise<void>((done) => {
        const off = woken.db.subscribe(() => {
          if (woken.db.lastTurn(key)?.endedAt == null && !said().some(([by]) => by === "ember")) return;
          off();
          done();
        });
      });
      say(woken.hub, thread.id, "ada@x.com", "post:hello from the woken VM");
      await over;
      assert.deepEqual(said(), [["person", "post:hello from the woken VM"], ["agent", "hello from the woken VM"]]);
      assert.deepEqual(woken.db.pendingMessages(key), []);
      await eventually(() => stationIdle(woken.db), "the station going idle: it may be archived again");
      // Nothing of the other Container's run came onto this disk: what is there now is this station's own.
      for (const left of ["station.json", "station.lock", "hub.json", "ports.json"]) assert.ok(!existsSync(join(dataOf(target), "run", left)), `${left} was restored`);
    } finally {
      await woken.hub.shutdown();
      await served.close(1000);
      woken.db.close();
    }
  } finally {
    for (const [name, value] of [["SALIX_CONNECTOR_ROOT", before.root], [RESTORE_ARCHIVE_ENV, before.restore], ["PATH", before.path]] as const) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    for (const root of roots) rmSync(root, { recursive: true, force: true });
    await store.close();
  }
});

test("a restore syncs the disk once, after every entry is in place and before its receipt says restored; the receipt says how long each step took", async () => {
  const store = await objectStore();
  try {
    const source = tempDir();
    mkdirSync(join(source, "project"));
    writeFileSync(join(source, "project", "work.txt"), "user work");
    symlinkSync("project/work.txt", join(source, "work"));
    // Two parts, compressed.
    writeFileSync(join(source, "big.bin"), incompressible(ARCHIVE_PART_BYTES + 1000));
    const bytes = await exportOf(store, source, "op1");
    assert.ok(bytes > ARCHIVE_PART_BYTES);
    // The restore's clock moves 10 ms each time it is read.
    const restoring = (target: string, sync: (root: string) => Promise<void>) => {
      let tick = 0;
      return Effect.runPromiseExit(restoreBeforeStart({ root: target, dir: archiveStateDir(target), restore: restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes)), allowedUrl: signedStorageUrl("127.0.0.1"), sync, now: () => 10 * tick++ }));
    };
    const receiptOf = (target: string) => JSON.parse(readFileSync(join(archiveStateDir(target), "import.json"), "utf8"));

    const target = join(tempDir(), "workspace");
    const synced: Array<{ root: string; phase: string; work: string; link: string }> = [];
    const restored = await restoring(target, async (root) => {
      synced.push({ root, phase: receiptOf(target).phase, work: readFileSync(join(target, "work"), "utf8"), link: readlinkSync(join(target, "work")) });
    });
    assert.ok(Exit.isSuccess(restored), String(Exit.isFailure(restored) && restored.cause));
    assert.deepEqual(synced, [{ root: target, phase: "restoring", work: "user work", link: "project/work.txt" }]);
    // .station/, its database's snapshot, project/, its file, the link and big.bin.
    const timings = { manifest_ms: 10, first_byte_ms: 20, downloaded_ms: 30, written_ms: 40, synced_ms: 50, total_ms: 60 };
    assert.deepEqual(restored.value, { operation: "op1", phase: "restored", bytes, entries: 6, files: 3, timings });
    assert.deepEqual(receiptOf(target), restored.value);

    // A sync that fails is a restore that failed: its receipt says why, and the disk is not started on.
    const unsynced = join(tempDir(), "workspace");
    const failed = await restoring(unsynced, async () => {
      throw new Error("sync: Input/output error");
    });
    assert.ok(Exit.isFailure(failed) && String(failed.cause).includes("streaming restore failed"), String(Exit.isFailure(failed) && failed.cause));
    assert.deepEqual([receiptOf(unsynced).phase, receiptOf(unsynced).error.includes("sync: Input/output error")], ["failed", true]);
  } finally {
    await store.close();
  }
});

test("a restore that fails leaves its receipt saying why, and that disk is not restored again", async () => {
  const store = await objectStore();
  try {
    const source = tempDir();
    // Too much for one part, compressed.
    writeFileSync(join(source, "big.bin"), incompressible(ARCHIVE_PART_BYTES + 1000));
    const bytes = await exportOf(store, source, "op1");
    assert.ok(bytes > ARCHIVE_PART_BYTES);
    // The archive's second part is gone from the store.
    store.objects.delete("/op1/1");
    const target = join(tempDir(), "workspace");
    const restore = restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes));
    const failed = await beforeStart(target, restore);
    assert.ok(Exit.isFailure(failed) && String(failed.cause).includes("streaming restore failed"), String(Exit.isFailure(failed) && failed.cause));
    const receipt = JSON.parse(readFileSync(join(archiveStateDir(target), "import.json"), "utf8"));
    assert.deepEqual([receipt.operation, receipt.phase], ["op1", "failed"]);
    assert.match(receipt.error, /signed archive read failed/);
    const again = await beforeStart(target, restore);
    assert.ok(Exit.isFailure(again) && String(again.cause).includes("partial restore requires a new disk"));
  } finally {
    await store.close();
  }
});

test("a start's restore is refused when it is not what Salix makes: other hosts, another archive's manifest, sizes that do not add up", async () => {
  const store = await objectStore();
  try {
    const target = join(tempDir(), "workspace");
    const part = (get_url: string, bytes: number) => ({ get_url, bytes });
    const value = (fields: Record<string, unknown>) => Buffer.from(JSON.stringify(fields)).toString("base64");
    const here = store.url("op1/0");
    for (const [restore, why] of [
      ["not base64!", "invalid restore instruction"],
      [Buffer.from("not json").toString("base64"), "invalid restore instruction"],
      ["A".repeat(RESTORE_VALUE_LIMIT + 4), "invalid restore instruction"],
      [value({ operation: "op 1", bytes: 10, manifest_url: here }), "invalid archive operation"],
      [value({ operation: "op1", bytes: 0, manifest_url: here }), "invalid streaming archive"],
      [value({ operation: "op1", bytes: 10, manifest_url: "https://elsewhere.example/op1/m?s=x" }), "invalid archive manifest URL"],
      [value({ operation: "op1", bytes: 10, manifest_url: store.url("op1/no-manifest") }), "archive manifest read failed"],
      [restoreValue(store, "op1", 10, [], "not json"), "invalid archive manifest"],
      [restoreValue(store, "op1", 10, [], { operation: "op2", bytes: 10, parts: [part(here, 10)] }), "archive manifest names another archive"],
      [restoreValue(store, "op1", 10, []), "invalid streaming archive"],
      [restoreValue(store, "op1", 10, [part("https://elsewhere.example/op1/0?s=x", 10)]), "invalid streaming archive part"],
      [restoreValue(store, "op1", 10, [part(here, 9)]), "invalid streaming archive part"],
    ] as const) {
      const refused = await beforeStart(target, restore);
      assert.ok(Exit.isFailure(refused) && String(refused.cause).includes(why), `${why}: ${String(Exit.isFailure(refused) && refused.cause)}`);
    }
    // Nothing was unpacked, and the disk holds no receipt: the manifest is read first.
    assert.ok(!existsSync(join(archiveStateDir(target), "import.json")));
    assert.ok(!existsSync(join(target, "work.txt")));
  } finally {
    await store.close();
  }
});

test("the largest archive's start value is as small as the smallest: its 1024 parts are in the manifest", async () => {
  const store = await objectStore();
  try {
    const bytes = 1024 * ARCHIVE_PART_BYTES;
    const parts = Array.from({ length: 1024 }, (_, i) => ({ get_url: store.url(`largest/${i}`), bytes: ARCHIVE_PART_BYTES }));
    const largest = restoreValue(store, "largest", bytes, parts);
    const smallest = restoreValue(store, "largest", 1, [{ get_url: store.url("largest/0"), bytes: 1 }]);
    assert.ok(largest.length < 400, `the start's value is ${largest.length} bytes`);
    assert.ok(Math.abs(largest.length - smallest.length) <= 16);
    // The start reads the manifest, takes every part from it, and fails at the first part: none is in the store.
    const failed = await beforeStart(join(tempDir(), "workspace"), largest);
    assert.ok(Exit.isFailure(failed) && String(failed.cause).includes("signed archive read failed"), String(Exit.isFailure(failed) && failed.cause));
  } finally {
    await store.close();
  }
});

test("restore-archive is the image's command: 0 once the disk is the archive its start named, 1 with nothing restored otherwise", async () => {
  const store = await objectStore();
  const before = { root: process.env.SALIX_CONNECTOR_ROOT, restore: process.env[RESTORE_ARCHIVE_ENV] };
  try {
    const source = tempDir();
    writeFileSync(join(source, "work.txt"), "user work");
    const bytes = await exportOf(store, source, "op1");
    const target = join(tempDir(), "workspace");
    process.env.SALIX_CONNECTOR_ROOT = target;
    delete process.env[RESTORE_ARCHIVE_ENV];
    assert.equal(await restoreArchiveCommand([], "127.0.0.1"), 1, "a start that names no archive restored one");
    process.env[RESTORE_ARCHIVE_ENV] = restoreValue(store, "op1", bytes, [{ get_url: store.url("missing/0"), bytes }]);
    assert.equal(await restoreArchiveCommand([], "127.0.0.1"), 1);
    assert.ok(!existsSync(join(target, "work.txt")));
    const fresh = join(tempDir(), "workspace");
    process.env.SALIX_CONNECTOR_ROOT = fresh;
    process.env[RESTORE_ARCHIVE_ENV] = restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes));
    assert.equal(await restoreArchiveCommand([], "127.0.0.1"), 0);
    assert.equal(readFileSync(join(fresh, "work.txt"), "utf8"), "user work");
    assert.equal(JSON.parse(readFileSync(join(fresh, "durable-archive", "import.json"), "utf8")).phase, "restored");
  } finally {
    for (const [name, value] of [["SALIX_CONNECTOR_ROOT", before.root], [RESTORE_ARCHIVE_ENV, before.restore]] as const) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await store.close();
  }
});

test("a link out of the Workload's disk is left out of its archive, not a failed export", async () => {
  const store = await objectStore();
  try {
    const source = tempDir();
    writeFileSync(join(source, "work.txt"), "user work");
    // Links an agent's tools leave, into the machine's own files: the disk's, not the archive's.
    symlinkSync(tempDir(), join(source, "outside"));
    symlinkSync("work.txt", join(source, "inside"));
    const bytes = await exportOf(store, source, "op1");

    const target = join(tempDir(), "workspace");
    const restored = await beforeStart(target, restoreValue(store, "op1", bytes, partsOf(store.url, "op1", bytes)));
    assert.ok(Exit.isSuccess(restored), String(Exit.isFailure(restored) && restored.cause));
    assert.equal(readFileSync(join(target, "inside"), "utf8"), "user work");
    assert.ok(lstatSync(join(target, "inside")).isSymbolicLink());
    assert.ok(!existsSync(join(target, "outside")), "a link out of the disk was restored");
  } finally {
    await store.close();
  }
});

test("a failed export reports why", async () => {
  const store = await objectStore({ rejectPuts: true });
  try {
    const source = tempDir();
    writeFileSync(join(source, "big.bin"), Buffer.alloc(ARCHIVE_PART_BYTES + 1000, 3));
    const c = makeConnector({ root: source, env: { HOME: tempDir() }, workloadCredential: "w", archiveHostSuffix: "127.0.0.1" }, undefined, { archive: stationState(source), agentsIdle: () => true });
    const call = (method: string, params: Record<string, unknown>) => run(c.dispatchForTest(method, method, params)) as Promise<Record<string, any>>;
    const transfers = Array.from({ length: 4 }, (_, i) => ({ put_url: store.url(`op1/${i}`), get_url: store.url(`op1/${i}`) }));
    await call("cloud_runtime_quiesce", { token: "t" });
    await call("archive_export", { operation: "op1", transfers });
    let status: Record<string, any> = {};
    await eventually(async () => {
      status = await call("archive_status", { operation: "op1" });
      return status.phase !== "preparing";
    }, "the export");
    assert.equal(status.phase, "failed");
    assert.match(String(status.error), /signed archive upload rejected/);
    await run(c.close());
  } finally {
    await store.close();
  }
});
