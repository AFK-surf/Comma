// Ported from systems/connector/salix-connect/main_test.go: the connection to Salix (same test names).
// The connector dials /v1/connect with its token, sends metadata first, answers heartbeats without metadata-only
// fields, closes a connection that hears nothing within the read timeout and dials again, keeps one whose heartbeats
// come, re-reports system info on a timer without probing runtimes and keeps doing so after a failed publish, fails a
// send blocked by a slow peer within the write deadline, and stops reconnecting once a cleanup failure is fatal.
// Salix is the in-memory Sockets service; timers run on the connector's TestClock.
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Deferred, Duration, Effect, Exit, Fiber, Queue } from "effect";
import { CLEANUP_QUEUE_SIZE, type Connector, ConnectorFatal, MAX_FILE_BYTES, WEBSOCKET_READ_TIMEOUT, WEBSOCKET_WRITE_TIMEOUT, makeConnector } from "../../src/connector/connector.ts";
import { settle } from "./support/memory-net.ts";
import { type Peer, memorySockets } from "./support/memory-socket.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
const isolated = { env: { HOME: tempDir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin" } };

/** 15 seconds pass and Salix sends its heartbeat: the frames the connector sent before its reply. */
const heartbeatTick = (c: Connector, peer: Peer) =>
  Effect.gen(function* () {
    yield* settle;
    yield* c.advanceClockForTest(Duration.seconds(15));
    yield* settle;
    yield* peer.send({ type: "heartbeat" });
    const frames: any[] = [];
    for (let frame = yield* peer.receive; frame.type !== "heartbeat"; frame = yield* peer.receive) frames.push(frame);
    return frames;
  });

test("TestRunRemoteOnceRepliesToHeartbeat", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "test-token", name: "laptop", root: tempDir(), testClock: true }, salix.layer);
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      assert.equal(new URL(peer.url).pathname, "/v1/connect");
      assert.equal(peer.headers.authorization ?? peer.headers.Authorization, "Bearer test-token");
      assert.equal((yield* peer.receive).type, "metadata", "the first connector frame was not metadata");
      yield* peer.send({ type: "heartbeat" });
      const reply = yield* peer.receive;
      assert.equal(reply.type, "heartbeat");
      assert.ok(!("skills" in reply), "the heartbeat carried metadata-only skills");
      yield* peer.close;
      yield* Fiber.await(session);
      yield* c.close();
    }),
  ));

test("TestRemoteSilentSalixIsDialedAgainAfterReadTimeout", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "token", name: "silent-salix", root: tempDir(), reconnect: true, testClock: true }, salix.layer);
      const remote = yield* Effect.forkChild(c.runRemote);
      const first = yield* Queue.take(salix.accepted);
      assert.equal((yield* first.receive).type, "metadata");
      // Salix then sends nothing and its socket stays open, as when the path died (a sleep, a network change).
      yield* settle;
      yield* c.advanceClockForTest(Duration.millis(Duration.toMillis(WEBSOCKET_READ_TIMEOUT) - 1_000));
      yield* settle;
      assert.equal(salix.dials.length, 1, "the connector dialed again before the read timeout");
      yield* c.advanceClockForTest(Duration.seconds(1));
      yield* settle;
      // The first reconnect backoff is at most 1.2 seconds.
      yield* c.advanceClockForTest(Duration.seconds(2));
      yield* settle;
      assert.equal(salix.dials.length, 2, "the connector kept a connection that heard nothing past the read timeout");
      yield* first.closed;
      yield* Fiber.interrupt(remote);
      yield* c.close();
    }),
  ));

test("TestRemoteHeartbeatsKeepConnectionPastReadTimeout", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "token", name: "heartbeating-salix", root: tempDir(), testClock: true }, salix.layer);
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      assert.equal((yield* peer.receive).type, "metadata");
      // Salix sends a heartbeat every 15 seconds: each frame starts the read timeout again.
      for (let beat = 0; beat < 8; beat++) yield* heartbeatTick(c, peer);
      yield* settle;
      assert.equal(session.pollUnsafe(), undefined, "the connector closed a connection whose heartbeats kept coming");
      assert.equal(salix.dials.length, 1);
      yield* Fiber.interrupt(session);
      yield* c.close();
    }),
  ));

test("TestRemoteWebSocketBlockedDataSendFailsWithinWriteDeadline", () =>
  run(
    Effect.gen(function* () {
      const root = tempDir();
      writeFileSync(join(root, "large.bin"), Buffer.alloc(MAX_FILE_BYTES, 7), { mode: 0o600 });
      // A peer that reads the metadata and then nothing: the large reply cannot be written.
      const salix = yield* memorySockets({ windowBytes: 64 * 1024 });
      const c = makeConnector({ ...isolated, root, name: "blocked-data-send", server: "https://salix.test", token: "token", testClock: true }, salix.layer);
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      yield* peer.receive;
      yield* peer.send({ id: "blocked-send", type: "request", method: "read", params: { path: "large.bin" } });
      // The 10 MB read runs on real file I/O; once its reply is being written, the write deadline passes.
      for (let attempt = 0; attempt < 10_000 && session.pollUnsafe() === undefined; attempt++) {
        yield* settle;
        yield* c.advanceClockForTest(WEBSOCKET_WRITE_TIMEOUT);
        yield* Effect.promise(() => new Promise((resolve) => setImmediate(resolve)));
      }
      const exit = yield* Fiber.await(session);
      assert.ok(Exit.isFailure(exit), "a blocked websocket send returned no error");
      // The write deadline ended it, not the read timeout: Salix is silent here as well.
      assert.match(String(exit.cause), /websocket write deadline exceeded/);
      yield* c.close();
    }),
  ));

test("TestRemoteCleanupFatalStopsReconnectAfterServerDisappears", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, root: tempDir(), name: "fatal-remote", server: "https://salix.test", token: "token", reconnect: true, testClock: true }, salix.layer);
      // The cleanup worker is stuck in one close and its queue is full: the next cleanup cannot be queued.
      const release = yield* c.blockCleanupWorkerForTest();
      for (let index = 0; index < CLEANUP_QUEUE_SIZE; index++) c.enqueueCleanup(Effect.void);
      const remote = yield* Effect.forkChild(c.runRemote);
      const peer = yield* Queue.take(salix.accepted);
      yield* peer.receive;
      yield* peer.send({ id: "pending-write", type: "request", method: "write_stream", params: { path: "pending.bin" } });
      yield* peer.receive;
      // The server goes away with a write stream pending; its cleanup has nowhere to go.
      yield* peer.close;
      const exit = yield* Fiber.await(remote);
      assert.ok(Exit.isFailure(exit) && String(exit.cause).includes(ConnectorFatal.name), `runRemote returned a non-terminal result: ${String(exit)}`);
      yield* c.advanceClockForTest(Duration.minutes(5));
      yield* settle;
      assert.equal(salix.dials.length, 1, "the connector redialled after a sticky fatal error");
      yield* release;
      yield* c.close();
    }),
  ));

test("TestRunRemoteOnceSendsPeriodicSystemInfo", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "test-token", name: "laptop", root: tempDir(), systemInfoInterval: Duration.millis(50), testClock: true }, salix.layer);
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      // The connect-time metadata, then a second report the timer sends without any prompt.
      const first = yield* peer.receive;
      assert.ok(first.type === "metadata" && first.system_info, "the first metadata has no system_info");
      yield* settle;
      yield* c.advanceClockForTest(Duration.millis(50));
      let second = yield* peer.receive;
      while (second.type !== "metadata") second = yield* peer.receive;
      assert.ok(second.system_info, `the periodic metadata has no system_info: ${JSON.stringify(second)}`);
      yield* Fiber.interrupt(session);
      yield* c.close();
    }),
  ));

test("TestSystemInfoLoopRetriesAfterTransientPublishFailure", () =>
  run(
    Effect.gen(function* () {
      const c = makeConnector({ root: tempDir(), systemInfoInterval: Duration.millis(5), testClock: true });
      let attempts = 0;
      const loop = yield* Effect.forkChild(c.systemInfoLoop(() => (++attempts === 1 ? Effect.fail(new Error("transient publish failure")) : Effect.void)));
      for (let tick = 0; tick < 2; tick++) {
        yield* settle;
        yield* c.advanceClockForTest(Duration.millis(5));
      }
      yield* settle;
      assert.ok(attempts >= 2, `the periodic loop stopped after a transient failure; attempts=${attempts}`);
      yield* Fiber.interrupt(loop);
      yield* c.close();
    }),
  ));

// A Container just started reads a runtime's binary from its image the first time it runs (3 s for Claude Code's
// `--version`). The connection serves Salix while that probe runs, and the probe's result follows as more metadata.
test("the runtime probe of a connect does not hold Salix's requests", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "test-token", name: "vm", root: tempDir(), testClock: true }, salix.layer);
      const probed = yield* Deferred.make<void>();
      const inventory = c.runtimeInventory as unknown as { options: { discover: () => unknown[]; run: () => Effect.Effect<Record<string, unknown>> } };
      inventory.options.discover = () => [{ provider: "claude", identityMaterial: "/opt/claude" }];
      inventory.options.run = () => Deferred.await(probed).pipe(Effect.as({ provider: "claude", identity_material: "/opt/claude", ready: true, status: "available", version: "2.1.296" }));
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      assert.equal((yield* peer.receive).type, "metadata", "the first connector frame was not metadata");
      yield* peer.send({ type: "heartbeat" });
      assert.equal((yield* peer.receive).type, "heartbeat", "a request waited for the runtime probe");
      yield* Deferred.succeed(probed, undefined);
      const probe = yield* peer.receive;
      assert.equal(probe.type, "metadata");
      assert.deepEqual(probe.capabilities.agent_runtimes.map((r: Record<string, unknown>) => [r.provider, r.status]), [["claude", "available"]]);
      yield* peer.close;
      yield* Fiber.await(session);
      yield* c.close();
    }),
  ));

test("TestPeriodicSystemInfoPublishesCachedMetadataWithoutRuntimeProbe", () =>
  run(
    Effect.gen(function* () {
      const c = makeConnector({ root: tempDir() });
      c.runtimeInventory.setProbeForTest(() => assert.fail("periodic system info must not run the runtime inventory probe"));
      const sent: Array<Record<string, any>> = [];
      yield* c.publishPeriodicSystemInfo((m) => Effect.sync(() => void sent.push(m)));
      assert.equal(sent[0]?.type, "metadata");
      assert.ok(sent[0].system_info?.hostname, `system info ${JSON.stringify(sent[0].system_info)} has no host observation`);
      yield* c.close();
    }),
  ));

/** The next frame of `method` the connector sends, past any other (metadata, probes). */
const nextRequest = (peer: Peer, method: string) =>
  Effect.gen(function* () {
    for (;;) {
      const frame = yield* peer.receive;
      if (frame.method === method) return frame;
    }
  });

// The app writes the device's next credential before the current one expires. When Salix takes one over the
// connection, the live connection presents it and stays: no dial, and a later connection presents the new one.
test("a device connection presents the app's next credential to Salix and keeps serving", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "first", name: "laptop", root: tempDir(), reconnect: true, testClock: true }, salix.layer);
      const remote = yield* Effect.forkChild(c.runRemote);
      const peer = yield* Queue.take(salix.accepted);
      assert.equal(peer.headers.authorization, "Bearer first");
      yield* peer.send({ type: "connected", connector_run_id: "run-1", credential_renewal: true });
      yield* settle;
      yield* c.renewCredential("second");
      const renew = yield* nextRequest(peer, "connector_credential_renew");
      assert.equal(renew.params.token, "second");
      yield* peer.send({ id: renew.id, type: "response", result: { expires_at: 1 } });
      yield* settle;
      yield* c.advanceClockForTest(Duration.seconds(5));
      yield* settle;
      assert.equal(salix.dials.length, 1, "the connection was dialed again after Salix took the credential");
      yield* peer.close;
      yield* settle;
      yield* c.advanceClockForTest(Duration.seconds(2));
      yield* settle;
      const next = yield* Queue.take(salix.accepted);
      assert.equal(next.headers.authorization, "Bearer second");
      yield* Fiber.interrupt(remote);
      yield* c.close();
    }),
  ));

// A Salix that refuses the next credential, or does not take one over the connection, gets a new connection that
// presents it, at once rather than when the current credential expires.
test("a device connection whose Salix refuses or cannot take the next credential dials again with it", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "first", name: "laptop", root: tempDir(), reconnect: true, testClock: true }, salix.layer);
      const remote = yield* Effect.forkChild(c.runRemote);
      const refusing = yield* Queue.take(salix.accepted);
      yield* refusing.send({ type: "connected", connector_run_id: "run-1", credential_renewal: true });
      yield* settle;
      yield* c.renewCredential("second");
      const renew = yield* nextRequest(refusing, "connector_credential_renew");
      yield* refusing.send({ id: renew.id, type: "error", error: "connector credential not renewed" });
      yield* refusing.closed;
      yield* c.advanceClockForTest(Duration.seconds(2));
      yield* settle;
      const older = yield* Queue.take(salix.accepted);
      assert.equal(older.headers.authorization, "Bearer second");
      // A Salix from before renewal says nothing of it in `connected`.
      yield* older.send({ type: "connected", connector_run_id: "run-2" });
      yield* settle;
      yield* c.renewCredential("third");
      yield* older.closed;
      yield* c.advanceClockForTest(Duration.seconds(2));
      yield* settle;
      const next = yield* Queue.take(salix.accepted);
      assert.equal(next.headers.authorization, "Bearer third");
      yield* Fiber.interrupt(remote);
      yield* c.close();
    }),
  ));

// A Compute Workload's station presents its connect credential on every connection: it has no expiry, so after a
// connection ends the station connects again with the same one.
test("a workload presents its connect credential on every connection", () =>
  run(
    Effect.gen(function* () {
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", workloadCredential: "connect-credential", name: "worker", root: tempDir(), testClock: true }, salix.layer);
      for (const runId of ["run-1", "run-2"]) {
        const session = yield* Effect.forkChild(c.runRemoteOnce);
        const peer = yield* Queue.take(salix.accepted);
        assert.equal(peer.headers.authorization, "Bearer connect-credential", `${runId} presented another credential`);
        assert.equal(peer.headers["X-Salix-Credential-Kind"], "workload");
        yield* peer.receive;
        yield* peer.send({ type: "connected", connector_run_id: runId });
        yield* settle;
        yield* peer.close;
        yield* Fiber.await(session);
      }
      yield* c.close();
    }),
  ));

// Salix as the relay of last resort: on `connected` with a challenge, the station proves its endpoint id with its key;
// once Salix accepts, packets go out in binary frames (kind 1, the peer's id, the packet) and come in the same way.
test("the station registers its endpoint id and carries packets through Salix in binary frames", () =>
  run(
    Effect.gen(function* () {
      const { generateKeyPairSync, sign, verify } = yield* Effect.promise(() => import("node:crypto"));
      const { privateKey, publicKey } = generateKeyPairSync("ed25519");
      const endpointId = Buffer.from(publicKey.export({ format: "jwk" }).x as string, "base64url").toString("hex");
      const came: Array<[string, string]> = [];
      let send: ((to: string, data: Buffer) => void) | null = null;
      const relay = {
        endpointId,
        sign: (message: Buffer) => sign(null, message, privateKey),
        incoming: (from: string, data: Buffer) => void came.push([from, data.toString()]),
        attach: (_via: object, next: typeof send) => void (send = next),
      };
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "t", name: "laptop", root: tempDir(), testClock: true }, salix.layer, { relay });
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      yield* peer.receive;
      yield* peer.send({ type: "connected", connector_run_id: "run-1", relay_challenge: "nonce-1" });
      const register = yield* peer.receive;
      assert.equal(register.method, "relay_register");
      assert.equal(register.params.endpoint_id, endpointId);
      assert.ok(verify(null, Buffer.from("comma-salix-relay-v1:run-1:nonce-1"), publicKey, Buffer.from(register.params.signature, "base64")), "the registration is not signed by the station's key");
      assert.equal(send, null, "packets went out before Salix accepted the registration");
      yield* peer.send({ id: register.id, type: "response", result: { ok: true } });
      yield* settle;
      const to = "ab".repeat(32);
      send!(to, Buffer.from("packet out"));
      yield* settle;
      const [frame] = peer.binaries();
      assert.deepEqual([frame[0], frame.subarray(1, 33).toString("hex"), frame.subarray(33).toString()], [1, to, "packet out"]);
      const from = "cd".repeat(32);
      peer.sendBinary(Buffer.concat([Buffer.from([1]), Buffer.from(from, "hex"), Buffer.from("packet in")]));
      assert.deepEqual(came, [[from, "packet in"]]);
      yield* peer.close;
      yield* Fiber.await(session);
      assert.equal(send, null, "the relay stayed attached to a closed connection");
      yield* c.close();
    }),
  ));

// The station's Task index: once Salix has its endpoint id, the station asks what Salix holds of it, sends all of it to
// a Salix that holds another epoch, drops tombstones Salix holds, and sends what changed after the station's writes.
test("the station keeps Salix's copy of its Task index current over the connection", () =>
  run(
    Effect.gen(function* () {
      const { generateKeyPairSync, sign } = yield* Effect.promise(() => import("node:crypto"));
      const { privateKey, publicKey } = generateKeyPairSync("ed25519");
      const endpointId = Buffer.from(publicKey.export({ format: "jwk" }).x as string, "base64url").toString("hex");
      const relay = { endpointId, sign: (message: Buffer) => sign(null, message, privateKey), incoming: () => {}, attach: () => {} };
      const row = (thread: number, rev: number) => ({
        thread,
        rev,
        removed: false,
        json: JSON.stringify({ task: `C1/${thread}.0`, thread, title: `Task ${thread}`, status: "in_progress", created_by: null, created_at: 1, last_activity_at: 2, runtime: null, model: null, rev }),
      });
      const rows = [row(1, 1), row(2, 2)];
      const pruned: number[] = [];
      let changed = () => {};
      const index = {
        epoch: () => "e1",
        rev: () => Math.max(...rows.map((r) => r.rev)),
        since: (since: number, limit: number) => rows.filter((r) => r.rev > since).slice(0, limit),
        prune: (through: number) => void pruned.push(through),
        listen: (next: () => void) => ((changed = next), () => {}),
      };
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "t", name: "laptop", root: tempDir(), testClock: true }, salix.layer, { relay, index });
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      const metadata = yield* peer.receive;
      assert.equal(metadata.capabilities.task_index, 1);
      yield* peer.send({ type: "connected", connector_run_id: "run-1", relay_challenge: "nonce-1" });
      const register = yield* peer.receive;
      yield* peer.send({ id: register.id, type: "response", result: { ok: true } });
      const probe = yield* peer.receive;
      assert.deepEqual([probe.method, probe.params], ["task.index", { epoch: "e1", reset: false, since: 2, through: 2, rows: [] }]);
      yield* peer.send({ id: probe.id, type: "response", result: { epoch: null, through: 0 } });
      yield* settle;
      yield* c.advanceClockForTest(Duration.millis(300));
      const all = yield* peer.receive;
      assert.deepEqual([all.params.reset, all.params.through, all.params.rows.map((r: { thread: string }) => r.thread)], [true, 2, ["1", "2"]]);
      yield* peer.send({ id: all.id, type: "response", result: { epoch: "e1", through: 2 } });
      yield* settle;
      assert.deepEqual(pruned, [2]);
      rows.push(row(3, 3));
      changed();
      yield* settle;
      yield* c.advanceClockForTest(Duration.seconds(1));
      const more = yield* peer.receive;
      assert.deepEqual([more.params.reset, more.params.since, more.params.through, more.params.rows.map((r: { thread: string }) => r.thread)], [false, 2, 3, ["3"]]);
      yield* peer.close;
      yield* Fiber.await(session);
      yield* c.close();
    }),
  ));

// Salix as the Station a Task is kept on: its task.invite and task.put reach the station's Tasks; while connected, the
// station asks it task.post and task.hello on the connection, and a refusal is final; once the connection is gone it is
// asked nothing.
test("Salix's Tasks: task.invite, task.put and task.status come in, task.post and task.hello go out on the live connection", () =>
  run(
    Effect.gen(function* () {
      const handled: Array<[string, Record<string, unknown>]> = [];
      let ask: ((request: Record<string, unknown>) => Promise<unknown>) | null = null;
      const tasks = {
        handle: async (method: string, params: Record<string, unknown>) => (handled.push([method, params]), method === "task.invite" ? { session: "ember:c-1" } : method === "task.status" ? { state: "idle" } : { through: 1 }),
        models: () => ({ codex: ["gpt-5.5"] }),
        attach: (next: typeof ask) => void (ask = next),
      };
      const salix = yield* memorySockets();
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: "t", name: "laptop", root: tempDir(), testClock: true }, salix.layer, { tasks });
      const session = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      const metadata = yield* peer.receive;
      assert.equal(metadata.capabilities.tasks, 2);
      assert.deepEqual(metadata.capabilities.task_models, { codex: ["gpt-5.5"] }, "what a Task may choose to run here");
      yield* peer.send({ type: "connected", connector_run_id: "run-1" });
      yield* settle;
      yield* peer.send({ id: "c1", type: "request", method: "task.invite", params: { task: "cnv_1", start: { requester: "ann@x" } } });
      let reply = yield* peer.receive;
      while (reply.id !== "c1") reply = yield* peer.receive;
      assert.deepEqual(reply.result, { session: "ember:c-1" });
      yield* peer.send({ id: "c2", type: "request", method: "task.put", params: { task: "cnv_1", messages: [], through: 1 } });
      reply = yield* peer.receive;
      while (reply.id !== "c2") reply = yield* peer.receive;
      assert.deepEqual(reply.result, { through: 1 });
      yield* peer.send({ id: "c3", type: "request", method: "task.status", params: { task: "cnv_1" } });
      reply = yield* peer.receive;
      while (reply.id !== "c3") reply = yield* peer.receive;
      assert.deepEqual(reply.result, { state: "idle" });
      assert.deepEqual(handled, [
        ["task.invite", { task: "cnv_1", start: { requester: "ann@x" } }],
        ["task.put", { task: "cnv_1", messages: [], through: 1 }],
        ["task.status", { task: "cnv_1" }],
      ]);
      // Asked on the connection: the answer, or Salix's refusal.
      const hello = ask!({ method: "task.hello" });
      let asked = yield* peer.receive;
      while (asked.method !== "task.hello") asked = yield* peer.receive;
      yield* peer.send({ id: asked.id, type: "response", result: {} });
      assert.deepEqual(yield* Effect.promise(() => hello), {});
      const post = ask!({ method: "task.post", task: "cnv_1", session: "ember:c-1", text: "done", key: "k" });
      asked = yield* peer.receive;
      while (asked.method !== "task.post") asked = yield* peer.receive;
      yield* peer.send({ id: asked.id, type: "error", error: "takes no part" });
      yield* Effect.promise(() => assert.rejects(post, /takes no part/));
      yield* peer.close;
      yield* Fiber.await(session);
      yield* Effect.promise(() => assert.rejects(ask!({ method: "task.hello" }), /not connected/));
      yield* c.close();
    }),
  ));
