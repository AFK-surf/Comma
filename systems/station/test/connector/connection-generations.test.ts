// Ported from systems/connector/salix-connect/main_test.go: connection generations (the Go tests ran them on the VM
// server's /connect; the names keep their origin). A new connection generation replaces the old one: the old socket is closed and its reply sink is shut before
// the new generation is published, a request the old generation was still admitting has no side effect, and
// actor-owned work (exec, accepted writes) finishes regardless. Request, stream and write-stream admission are bounded;
// a control frame overtakes queued data; the request watchdog closes a blocked socket but honours long methods.
// Sockets are in-memory (`connectForTest`); a socket opened with a `window` makes the connector's sends wait for the test
// to read, which is how a slow peer is modelled. Deadlines run on the connector's TestClock.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, openSync, closeSync, readFileSync, statSync, writeFileSync, writeSync, constants } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Deferred, Duration, Effect, Exit, Option, type Scope } from "effect";
import {
  CONNECTION_DRAIN_TIMEOUT,
  MAX_CONCURRENT_REQUESTS,
  MAX_CONCURRENT_STREAM_WRITES,
  MAX_FILE_BYTES,
  MAX_PENDING_WRITE_STREAMS,
  type Message,
  type ConnectorConfig,
    makeConnector,
} from "../../src/connector/connector.ts";
import { eventually } from "./support/eventually.ts";
import { settle } from "./support/memory-net.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
const scoped = <A, E>(effect: Effect.Effect<A, E, Scope.Scope>) => Effect.runPromise(Effect.scoped(effect));
const mkfifo = (path: string) => execFileSync("mkfifo", ["-m", "600", path]);
/** Writes to a FIFO the connector is blocked reading, releasing it. */
const releaseFifo = (path: string) => {
  const fd = openSync(path, constants.O_WRONLY);
  writeSync(fd, "release");
  closeSync(fd);
};

/** A VM-serving connector whose PATH holds no host agent runtimes (the Go tests' isolateHostRuntimeCommands). */
function vmConnector(cfg: Partial<ConnectorConfig> = {}) {
  return makeConnector({ root: tempDir(), env: { HOME: tempDir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin" }, ...cfg });
}

type VmSocket = Effect.Success<ReturnType<ReturnType<typeof vmConnector>["connectForTest"]>>;

/** Opens /connect and reads the first frame, which must be metadata (the Go tests' dialVMWebSocket). */
const dial = (c: ReturnType<typeof vmConnector>, options?: { window?: number }) =>
  Effect.gen(function* () {
    const ws = yield* c.connectForTest(options);
    const metadata = yield* ws.read;
    assert.equal(metadata.type, "metadata", `first frame ${JSON.stringify(metadata)}`);
    return ws;
  });

/** Says `connected`: the connection's identity. */
const connected = (ws: VmSocket, runId: string) => ws.send({ type: "connected", connector_run_id: runId });

const exchange = (ws: VmSocket, request: Message) => ws.send(request).pipe(Effect.andThen(ws.read));

test("a connection answers requests after connected", () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector({ name: "worker" });
      const ws = yield* dial(c);
      yield* connected(ws, "run-1");
      const reply = yield* exchange(ws, { id: "req-1", type: "request", method: "exec", params: { command: "printf ok", timeout: 5 } });
      assert.deepEqual([reply.id, reply.type, (reply.result as any)?.stdout], ["req-1", "response", "ok"]);
      yield* c.close();
    }),
  ));

test("TestVMWebSocketMetadataAlwaysCarriesEmptySkills", () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector({ name: "metadata-skills" });
      const ws = yield* c.connectForTest();
      const metadata = yield* ws.read;
      // Without the field a reconnect cannot clear stale skills on the server.
      assert.ok("skills" in metadata, "metadata omitted skills");
      assert.deepEqual(metadata.skills, []);
      yield* c.close();
    }),
  ));

test("TestVMWebSocketGenerationsDoNotLeakParentContextWatchers", () =>
  run(
    Effect.gen(function* () {
      const c = vmConnector({ name: "generation-watchers" });
      const baseline = c.connectionWatcherCountForTest();
      for (let index = 0; index < 20; index++) {
        yield* Effect.scoped(dial(c));
        yield* settle;
        assert.equal(c.activeConnectionForTest(), null, "a closed WebSocket generation stayed active");
      }
      assert.ok(c.connectionWatcherCountForTest() <= baseline, "connection watchers leaked across generations");
      yield* c.close();
    }),
  ));

test("TestVMWebSocketReplacementClosesOldGenerationAndServesNewRPC", () =>
  scoped(
    Effect.gen(function* () {
      const lateMarker = join(tempDir(), "late-old-request");
      const c = vmConnector({ name: "replacement-vm" });
      const oldWs = yield* dial(c);
      yield* connected(oldWs, "old-run");
      yield* oldWs.send({ id: "old-exec", type: "request", method: "exec", params: { command: "sleep 30", timeout: 30 } });
      const newWs = yield* dial(c);
      yield* Effect.exit(oldWs.send({ id: "late-old-exec", type: "request", method: "exec", params: { command: `printf late > '${lateMarker}'` } }));
      yield* connected(newWs, "new-run");
      const reply = yield* exchange(newWs, { id: "new-list", type: "request", method: "process_list" });
      assert.deepEqual([reply.id, reply.type], ["new-list", "response"]);
      assert.ok(Exit.isFailure(yield* Effect.exit(oldWs.read)), "the old generation remained readable after replacement");
      assert.equal(c.connectionIdentity().runId, "new-run", "a stale generation replaced the active identity");
      yield* settle;
      assert.ok(!existsSync(lateMarker), "the old generation admitted a request after the replacement metadata was visible");
      yield* c.close();
    }),
  ));

test("TestVMWebSocketReplacementRejectsOldRequestAlreadyPastReadLoopActiveCheck", () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector({ name: "replacement-admission-window" });
      const marker = join(c.root(), "old-window-marker");
      const admissionEntered = yield* Deferred.make<void>();
      const releaseAdmission = yield* Deferred.make<void>();
      const replacementPublished = yield* Deferred.make<void>();
      const releaseReplacement = yield* Deferred.make<void>();
      c.setHooksForTest({
        beforeRequestAdmission: (_session, m) => (m.id === "old-window-write" ? Deferred.succeed(admissionEntered, undefined).pipe(Effect.andThen(Deferred.await(releaseAdmission))) : Effect.void),
        afterConnectionPublished: () => Deferred.succeed(replacementPublished, undefined).pipe(Effect.andThen(Deferred.await(releaseReplacement))),
      });
      const oldWs = yield* dial(c);
      yield* oldWs.send({ id: "old-window-write", type: "request", method: "write", params: { path: "old-window-marker", content: "stale" } });
      yield* Deferred.await(admissionEntered);
      // The replacement is published while the old request is past its read loop's active check.
      const newWs = yield* c.connectForTest();
      yield* Deferred.await(replacementPublished);
      yield* Deferred.succeed(releaseAdmission, undefined);
      yield* settle;
      assert.ok(!existsSync(marker), "the old generation produced a side effect after the replacement was published");
      yield* Deferred.succeed(releaseReplacement, undefined);
      assert.equal((yield* newWs.read).type, "metadata");
      const reply = yield* exchange(newWs, { id: "new-after-window", type: "request", method: "process_list" });
      assert.deepEqual([reply.id, reply.type], ["new-after-window", "response"]);
      yield* c.close();
    }),
  ));

test("TestVMWebSocketReplacementClosesOldReplySinkBeforePublishingNewGeneration", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector({ name: "replacement-reply-sink" });
      const fifo = join(c.root(), "blocked-read.fifo");
      mkfifo(fifo);
      const replacementPublished = yield* Deferred.make<void>();
      const releaseReplacement = yield* Deferred.make<void>();
      c.setHooksForTest({ afterConnectionPublished: () => Deferred.succeed(replacementPublished, undefined).pipe(Effect.andThen(Deferred.await(releaseReplacement))) });
      const oldWs = yield* dial(c);
      yield* oldWs.send({ id: "old-blocked-read", type: "request", method: "read", params: { path: "blocked-read.fifo" } });
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 1, "the old request admission"));
      const newWs = yield* c.connectForTest();
      yield* Deferred.await(replacementPublished);
      releaseFifo(fifo);
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 0, "the actor-owned old request completion"));
      assert.ok(Exit.isFailure(yield* Effect.exit(oldWs.read)), "the old reply sink stayed writable after the replacement was published");
      yield* Deferred.succeed(releaseReplacement, undefined);
      assert.equal((yield* newWs.read).type, "metadata");
      const reply = yield* exchange(newWs, { id: "new-after-old-complete", type: "request", method: "process_list" });
      assert.deepEqual([reply.id, reply.type], ["new-after-old-complete", "response"]);
      yield* c.close();
    }),
  ));

test("TestVMWebSocketReconnectDoesNotCancelActorOwnedExec", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector();
      const started = join(c.root(), "exec-started");
      const gate = join(c.root(), "exec-gate");
      const marker = join(c.root(), "exec-finished");
      mkfifo(gate);
      // The command waits on a FIFO instead of sleeping, so the test decides when it finishes.
      const command = `printf started > '${started}'; cat '${gate}' > /dev/null; printf finished > '${marker}'`;
      yield* Effect.scoped(
        Effect.gen(function* () {
          const ws = yield* dial(c);
          yield* ws.send({ id: "actor-owned-exec", type: "request", method: "exec", params: { command, timeout: 30 } });
          yield* Effect.promise(() => eventually(() => existsSync(started), "the actor-owned exec start"));
        }),
      );
      const replacement = yield* dial(c);
      const reply = yield* exchange(replacement, { id: "after-reconnect", type: "request", method: "process_list" });
      assert.deepEqual([reply.id, reply.type], ["after-reconnect", "response"]);
      releaseFifo(gate);
      yield* Effect.promise(() => eventually(() => existsSync(marker), "the actor-owned exec completion"));
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 0, "the actor-owned exec cleanup"));
      yield* c.close();
    }),
  ));

test("TestVMReplacementDuringComputerUseLaunchDoesNotPoisonConnector", { skip: process.platform === "darwin" ? false : "computer_use is macOS-only" }, () =>
  scoped(
    Effect.gen(function* () {
      const root = tempDir();
      const helperApp = join(root, "Comma Computer Use.app");
      execFileSync("mkdir", ["-p", join(helperApp, "Contents", "MacOS"), join(root, "bin")]);
      writeFileSync(join(helperApp, "Contents", "MacOS", "CommaComputerUseDaemon"), `#!/bin/sh\nprintf "%s\\n" "$0.app"\n`, { mode: 0o755 });
      const started = join(root, "open-started");
      writeFileSync(join(root, "bin", "open"), `#!/bin/sh\nprintf started > '${started}'\nexec /bin/sleep 30\n`, { mode: 0o755 });
      const c = makeConnector({ root, testClock: true, env: { HOME: tempDir(), PATH: join(root, "bin") }, computerUseHelperApp: helperApp, computerUseSocketPath: join(root, "computer-use.sock") });
      const oldWs = yield* dial(c);
      yield* oldWs.send({ id: "blocked-computer-use", type: "request", method: "computer_use", params: { action: "status" } });
      yield* Effect.promise(() => eventually(() => existsSync(started), "the computer_use helper launch"));
      const replacement = yield* dial(c);
      yield* c.advanceClockForTest(Duration.sum(CONNECTION_DRAIN_TIMEOUT, Duration.millis(250)));
      yield* settle;
      assert.equal(c.connectorFatal(), null, "a cancelled computer_use launch poisoned the connector");
      const reply = yield* exchange(replacement, { id: "after-computer-use-replacement", type: "request", method: "process_list" });
      assert.deepEqual([reply.id, reply.type], ["after-computer-use-replacement", "response"]);
      yield* c.close();
    }),
  ));

test("TestVMWebSocketControlFrameOvertakesQueuedDataFrames", () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector();
      writeFileSync(join(c.root(), "large.txt"), "x".repeat(MAX_FILE_BYTES), { mode: 0o600 });
      // A peer that reads one frame at a time: the connector's data sends queue behind it.
      const ws = yield* dial(c, { window: 1 });
      for (let index = 0; index < 3; index++) yield* ws.send({ id: `large-${index}`, type: "request", method: "read", params: { path: "large.txt" } });
      yield* Effect.promise(() => eventually(() => c.activeConnectionForTest() !== null && c.requestSlotsInUse() === 3, "three data responses to block or queue"));
      yield* ws.send({ type: "heartbeat" });
      let dataBeforeHeartbeat = 0;
      for (;;) {
        const frame = yield* ws.read;
        if (frame.type === "heartbeat") break;
        if (frame.type === "response" && frame.id?.startsWith("large-")) dataBeforeHeartbeat++;
      }
      assert.ok(dataBeforeHeartbeat <= 1, `the heartbeat followed ${dataBeforeHeartbeat} data frames; at most the already-active frame may lead it`);
      yield* ws.close;
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 0, "queued data responses to finish"));
      yield* c.close();
    }),
  ));

test("TestVMWebSocketRealBlockingRequestsHitAdmissionLimit", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector();
      const paths = Array.from({ length: MAX_CONCURRENT_REQUESTS }, (_, index) => join(c.root(), `blocked-${index}.fifo`));
      paths.forEach(mkfifo);
      const ws = yield* dial(c);
      for (const [index, path] of paths.entries()) yield* ws.send({ id: `blocked-${index}`, type: "request", method: "read", params: { path: path.split("/").at(-1) } });
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === MAX_CONCURRENT_REQUESTS, "all filesystem request slots to fill"));
      const frame = yield* exchange(ws, { id: "over-limit", type: "request", method: "stat", params: { path: "." } });
      assert.ok(frame.id === "over-limit" && frame.type === "error" && frame.error?.includes("connector request capacity exhausted"), `overload frame ${JSON.stringify(frame)}`);
      paths.forEach(releaseFifo);
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 0, "released filesystem requests to finish"));
      yield* c.close();
    }),
  ));

test("TestVMWebSocketRealBlockingStreamsHitAdmissionLimit", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector();
      const paths = Array.from({ length: MAX_CONCURRENT_STREAM_WRITES + 1 }, (_, index) => join(c.root(), `stream-${index}.fifo`));
      paths.forEach(mkfifo);
      // Readers that never read: a stream write fills the pipe and blocks.
      const readers = paths.map((path) => openSync(path, constants.O_RDONLY | constants.O_NONBLOCK));
      const ws = yield* dial(c);
      for (const index of paths.keys()) {
        const ready = yield* exchange(ws, { id: `stream-${index}`, type: "request", method: "write_stream", params: { path: `stream-${index}.fifo` } });
        assert.deepEqual([ready.id, ready.type], [`stream-${index}`, "response"]);
      }
      const payload = Buffer.alloc(1024 * 1024, "x").toString("base64");
      for (let index = 0; index < MAX_CONCURRENT_STREAM_WRITES; index++) yield* ws.send({ id: `stream-${index}`, type: "stream", stream: { channel: "data", seq: 1, data: payload } });
      yield* Effect.promise(() => eventually(() => c.activeConnectionForTest()?.streamSlotsInUse() === MAX_CONCURRENT_STREAM_WRITES, "all stream worker slots to fill"));
      const overLimit = `stream-${MAX_CONCURRENT_STREAM_WRITES}`;
      const frame = yield* exchange(ws, { id: overLimit, type: "stream", stream: { channel: "data", seq: 1, data: Buffer.from("rejected").toString("base64") } });
      assert.ok(frame.id === overLimit && frame.type === "stream" && frame.error?.includes("connector stream capacity exhausted"), `stream overload frame ${JSON.stringify(frame)}`);
      readers.forEach((fd) => closeSync(fd));
      yield* Effect.promise(() => eventually(() => c.activeConnectionForTest()?.streamSlotsInUse() === 0, "released stream writes to finish"));
      yield* ws.close;
      yield* Effect.promise(() => eventually(() => c.activeConnectionForTest() === null, "the websocket cleanup"));
      yield* c.close();
    }),
  ));

test("TestVMWebSocketWriteStreamLimitPreservesRejectedTarget", () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector();
      const rejectedPath = join(c.root(), `stream-${MAX_PENDING_WRITE_STREAMS}.txt`);
      writeFileSync(rejectedPath, "do-not-truncate", { mode: 0o600 });
      const ws = yield* dial(c);
      for (let index = 0; index <= MAX_PENDING_WRITE_STREAMS; index++) {
        const frame = yield* exchange(ws, { id: `stream-${index}`, type: "request", method: "write_stream", params: { path: `stream-${index}.txt` } });
        assert.equal(frame.id, `stream-${index}`);
        if (index < MAX_PENDING_WRITE_STREAMS) assert.equal(frame.type, "response", `accepted write_stream frame ${JSON.stringify(frame)}`);
        else assert.ok(frame.type === "error" && frame.error?.includes("write_stream capacity exhausted"), `rejected write_stream frame ${JSON.stringify(frame)}`);
      }
      assert.equal(readFileSync(rejectedPath, "utf8"), "do-not-truncate", "a rejected stream truncated its target");
      yield* c.close();
    }),
  ));

test("TestVMWebSocketRequestWatchdogClosesBlockedIOAndReplacementServes", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector({ testClock: true });
      const fifo = join(c.root(), "blocked-read");
      mkfifo(fifo);
      const finished = new Set<string>();
      c.setHooksForTest({ afterRequestFinished: (m) => Effect.sync(() => void finished.add(m.id!)) });
      const blocked = yield* dial(c);
      c.activeConnectionForTest()!.setDeadlineForTest(() => Duration.millis(30));
      yield* blocked.send({ id: "blocked-read", type: "request", method: "read", params: { path: fifo } });
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 1, "the blocked read admission"));
      yield* c.advanceClockForTest(Duration.millis(30));
      yield* settle;
      // Past its deadline the blocked read still has no reply; it cannot hold up a replacement.
      const early = yield* Effect.raceFirst(blocked.read.pipe(Effect.map(Option.some)), settle.pipe(Effect.as(Option.none())));
      assert.ok(Option.isNone(early), `a blocked request replied before its I/O returned: ${JSON.stringify(early)}`);
      const replacement = yield* dial(c);
      const reply = yield* exchange(replacement, { id: "replacement-list", type: "request", method: "process_list" });
      assert.deepEqual([reply.id, reply.type], ["replacement-list", "response"]);
      releaseFifo(fifo);
      // Both requests finish before the test ends.
      yield* Effect.promise(() => eventually(() => finished.has("blocked-read") && finished.has("replacement-list"), "both requests to finish"));
      yield* c.close();
    }),
  ));

test("TestVMWebSocketRequestWatchdogHonorsLongRunningMethodTimeout", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      // The general request deadline is shorter than the command; exec's own timeout (1s) governs it.
      const c = vmConnector({ testClock: true, requestExecutionTimeout: Duration.millis(20) });
      const gate = join(c.root(), "exec-gate");
      mkfifo(gate);
      const ws = yield* dial(c);
      yield* ws.send({ id: "long-exec", type: "request", method: "exec", params: { command: `cat '${gate}' > /dev/null; printf ok`, timeout: 1 } });
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 1, "the exec admission"));
      yield* c.advanceClockForTest(Duration.millis(50));
      releaseFifo(gate);
      const frame = yield* ws.read;
      assert.deepEqual([frame.id, frame.type, (frame.result as any)?.stdout], ["long-exec", "response", "ok"], "the long-running method was cut off by the general deadline");
      yield* c.close();
    }),
  ));

test("TestVMReplacementKeepsAcceptedProcessWritesButClosesOldReplySink", { skip: process.platform === "win32" && "needs a FIFO" }, () =>
  scoped(
    Effect.gen(function* () {
      const c = vmConnector();
      const [marker, ready, gate] = ["stdin-markers", "process-ready", "start-reading"].map((name) => join(c.root(), name));
      mkfifo(gate);
      const oldWs = yield* dial(c);
      // A process that does not read stdin until the test opens the gate.
      const started = yield* exchange(oldWs, {
        id: "start-delayed-reader",
        type: "request",
        method: "process_start",
        params: { process_name: "delayed-reader", command: "/bin/sh", args: ["-c", `printf ready > '${ready}'; cat '${gate}' > /dev/null; cat > '${marker}'`] },
      });
      assert.equal(started.type, "response", JSON.stringify(started));
      yield* Effect.promise(() => eventually(() => existsSync(ready), "the managed process readiness"));
      yield* oldWs.send({ id: "fill-pipe", type: "request", method: "process_write", params: { process_name: "delayed-reader", data: "A".repeat(1024 * 1024) } });
      yield* Effect.promise(() => eventually(() => c.processStdinBusyForTest("delayed-reader"), "the first process write to hold the stdin slot"));
      yield* oldWs.send({ id: "old-marker", type: "request", method: "process_write", params: { process_name: "delayed-reader", data: "OLD_MARKER\n" } });
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 2, "the queued old process write"));
      const newWs = yield* dial(c);
      releaseFifo(gate);
      const written = yield* exchange(newWs, { id: "new-marker", type: "request", method: "process_write", params: { process_name: "delayed-reader", data: "NEW_MARKER\n" } });
      assert.deepEqual([written.id, written.type], ["new-marker", "response"]);
      assert.ok(Exit.isFailure(yield* Effect.exit(oldWs.read)), "the old reply sink stayed readable after the replacement");
      yield* Effect.promise(() => eventually(() => c.requestSlotsInUse() === 0, "the accepted old writes to finish"));
      // A write is done once its bytes are in the stdin pipe; cat has them in the file only after it read them all.
      // Stopped before, it would leave the last ones in the pipe.
      const accepted = 1024 * 1024 + "OLD_MARKER\n".length + "NEW_MARKER\n".length;
      yield* Effect.promise(() => eventually(() => existsSync(marker) && statSync(marker).size === accepted, "cat to write every accepted byte"));
      yield* exchange(newWs, { id: "stop-reader", type: "request", method: "process_stop", params: { process_name: "delayed-reader" } });
      const content = readFileSync(marker, "utf8");
      assert.ok(content.includes("OLD_MARKER") && content.includes("NEW_MARKER"), `accepted process writes were lost across the replacement: old=${content.includes("OLD_MARKER")} new=${content.includes("NEW_MARKER")}`);
      yield* c.close();
    }),
  ));
