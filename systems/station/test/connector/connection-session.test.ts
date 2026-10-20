// Ported from systems/connector/salix-connect/connection_session_test.go (same test names).
// A replaced connection's blocked work cannot hold up or disturb its replacement; write streams reserve capacity
// before touching a file; a closed session admits nothing; a filesystem deadline does not close the transport;
// request timeouts follow each method's contract; cleanup exhaustion is fatal; process stdin writes are serialized.
// Go tests that raced goroutines check the same admission rules here with fibers and a settled scheduler.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { open, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { Deferred, Duration, Effect, Exit, Fiber, Queue } from "effect";
import { TestClock } from "effect/testing";
import {
  MAX_PENDING_WRITE_STREAMS,
  type Message,
  isConnectorFatal,
  makeConnector,
  requestTimeoutMs,
  terminalConnectionError,
} from "../../src/connector/connector.ts";
import { type ProcessStdin } from "../../src/connector/processes.ts";
import { eventually } from "./support/eventually.ts";
import { settle } from "./support/memory-net.ts";
import { tempDir } from "./support/temp.ts";

const b64 = (s: string) => Buffer.from(s).toString("base64");

test("TestConnectionReplacementDetachesBlockedWriteAndServesNewRequests", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const c = makeConnector({ name: "test", root: tempDir() });
      const old = c.claimConnection(() => Effect.void);
      // A file whose write blocks until it is closed.
      const started = yield* Deferred.make<void>();
      const closed = yield* Deferred.make<void>();
      const pending = old.reservePendingWrite("write-1");
      assert.ok(
        old.activatePendingWrite("write-1", pending, {
          write: () => Deferred.succeed(started, undefined).pipe(Effect.andThen(Deferred.await(closed)), Effect.andThen(Effect.fail(new Error("closed during write")))),
          close: Deferred.succeed(closed, undefined).pipe(Effect.asVoid),
        }),
      );
      assert.ok(old.startStream({ id: "write-1", type: "stream", stream: { channel: "data", data: b64("payload") } }), "old stream was not admitted");
      yield* Deferred.await(started);
      const responses = yield* Queue.unbounded<Message>();
      const fresh = c.claimConnection((m) => Queue.offer(responses, m).pipe(Effect.asVoid));
      assert.ok(fresh.startRequest({ id: "new-1", type: "request", method: "process_list" }), "replacement did not admit a request");
      const response = yield* Queue.take(responses);
      assert.equal(response.type, "response");
      assert.equal(response.id, "new-1");
      assert.equal(yield* old.wait, true, "old connection worker did not drain after file cleanup");
      fresh.close("canceled");
    }),
  ));

test("TestOldConnectionCleanupCannotRemoveNewConnectionTransfer", async () => {
  const c = makeConnector({ name: "test", root: tempDir() });
  const old = c.claimConnection(() => Effect.void);
  const fresh = c.claimConnection(() => Effect.void);
  const pending = fresh.reservePendingWrite("same-id");
  const file = await open(join(tempDir(), "new-generation"), "w");
  assert.ok(fresh.activatePendingWrite("same-id", pending, file));
  old.abortPendingTransfers("late old cleanup");
  assert.equal(fresh.pendingWrite("same-id"), pending, "old connection cleanup removed the new connection's transfer");
  assert.equal(c.setIdentity(old, { runId: "old-run", deviceId: "old-device", connectorId: "old-connector", ownerUserId: "old-owner", generation: 1 }), false, "a replaced connection updated the identity");
  assert.equal(c.setIdentity(fresh, { runId: "new-run", deviceId: "new-device", connectorId: "new-connector", ownerUserId: "new-owner", generation: 2 }), true);
  assert.deepEqual(c.connectionIdentity(), { runId: "new-run", deviceId: "new-device", connectorId: "new-connector" });
  fresh.close("canceled");
});

test("TestPrepareWriteStreamReservesCapacityBeforeTruncating", async () => {
  const root = tempDir();
  const c = makeConnector({ name: "test", root });
  const session = c.claimConnection(() => Effect.void);
  for (let i = 0; i < MAX_PENDING_WRITE_STREAMS; i++) session.reservePendingWrite(String.fromCharCode(97 + i));
  await writeFile(join(root, "important.txt"), "keep me");
  const exit = await Effect.runPromiseExit(c.prepareWriteStream(session, "overflow", { path: "important.txt" }));
  assert.ok(Exit.isFailure(exit), "a capacity-exhausted write stream succeeded");
  assert.equal(await readFile(join(root, "important.txt"), "utf8"), "keep me", "a rejected write truncated the file");
  session.close("canceled");
});

test("TestCloseSealsWorkerAdmissionBeforeWaiting", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const c = makeConnector({ name: "test", root: tempDir() });
      for (let iteration = 0; iteration < 100; iteration++) {
        const session = c.claimConnection(() => Effect.void);
        // Starters and the close interleave on the scheduler in every order it picks.
        const starters = yield* Effect.forkChild(
          Effect.forEach(Array.from({ length: 16 }), () =>
            Effect.forEach(Array.from({ length: 16 }), () => Effect.sync(() => session.startRequest({ id: "race", type: "request", method: "process_list" })).pipe(Effect.andThen(Effect.yieldNow))),
          { concurrency: "unbounded" }),
        );
        session.close("canceled");
        yield* Fiber.join(starters);
        assert.equal(yield* session.wait, true, "workers were admitted after the session closed");
        assert.equal(session.startRequest({ id: "late", type: "request", method: "process_list" }), false, "a closed session admitted a late worker");
      }
    }),
  ));

test("TestBlockedFilesystemRequestDeadlineDoesNotOwnTransport", { skip: process.platform === "win32" && "needs a FIFO" }, async () => {
  const root = tempDir();
  const path = join(root, "blocking-fifo");
  execFileSync("mkfifo", ["-m", "600", path]);
  const c = makeConnector({ name: "test", root, testClock: true });
  let closed: unknown = null;
  const responses: Message[] = [];
  const session = c.claimConnection((m) => Effect.sync(() => void responses.push(m)), {
    onClose: (err) => (closed ??= err),
    deadlineMs: () => 20,
  });
  assert.ok(session.startRequest({ id: "blocked-read", type: "request", method: "read", params: { path } }), "blocked read was not admitted");
  // Past the request's deadline: the transport is still open.
  await Effect.runPromise(c.advanceClockForTest(Duration.millis(50)));
  assert.equal(closed, null, "the request deadline closed the transport");
  await writeFile(path, "released");
  await eventually(() => responses.length === 1, "released filesystem request");
  assert.equal(responses[0].id, "blocked-read");
  assert.equal(responses[0].type, "response");
});

test("TestRequestTimeoutHonorsLongRunningMethodContracts", () => {
  const min = 60_000;
  const cases: Array<[string, Message, number]> = [
    ["exec floor", { method: "exec", params: { timeout: 5 } }, 2 * min],
    ["long exec", { method: "exec", params: { timeout: 600 } }, 605_000],
    ["http", { method: "http_request", params: { timeout_seconds: 300 } }, 305_000],
    ["tail", { method: "process_tail", params: { wait_seconds: 200 } }, 205_000],
    ["runtime probe", { method: "runtime_probe" }, 30_000],
    ["local file read", { method: "read_ref" }, min],
    ["meeting artifact missing size", { method: "meeting_artifact_read" }, 2 * min],
    ["meeting artifact small", { method: "meeting_artifact_read", params: { expected_size: 64 * 1024 } }, 2 * min],
    ["meeting artifact maximum", { method: "meeting_artifact_read", params: { expected_size: 30 * 1024 * 1024 } }, 3 * min],
    ["meeting artifact malformed", { method: "meeting_artifact_read", params: { expected_size: "huge" } }, 2 * min],
    ["meeting artifact oversize", { method: "meeting_artifact_read", params: { expected_size: 2 ** 62 } }, 2 * min],
  ];
  for (const [name, msg, want] of cases) assert.equal(requestTimeoutMs(msg), want, name);
});

test("TestCleanupQueueExhaustionIsTerminalForRemoteAndVM", async () => {
  const c = makeConnector({ cleanupQueueSize: 1 });
  const noop = { close: Effect.void };
  // The worker is busy: the queue holds one item, and the next has nowhere to go.
  await Effect.runPromise(c.blockCleanupWorkerForTest());
  c.enqueueCleanup(noop);
  c.enqueueCleanup(noop);
  const fatal = await Effect.runPromise(c.nextFatalError);
  assert.ok(isConnectorFatal(fatal) && terminalConnectionError(fatal), `cleanup exhaustion was not terminal: ${String(fatal)}`);
});

/** A process stdin whose writes each wait for a release; it records how many ran at once. */
function gatedStdin() {
  return Effect.gen(function* () {
    const entered = yield* Queue.unbounded<void>();
    const release = yield* Queue.unbounded<void>();
    let active = 0;
    let maxActive = 0;
    const stdin: ProcessStdin = {
      write: (data) =>
        Effect.gen(function* () {
          active++;
          maxActive = Math.max(maxActive, active);
          yield* Queue.offer(entered, undefined);
          yield* Queue.take(release).pipe(Effect.ensuring(Effect.sync(() => active--)));
          return data.length;
        }),
      close: Effect.void,
    };
    return { stdin, entered, release, maxActive: () => maxActive, active: () => active };
  });
}

test("TestProcessWritesAreSerializedPerProcess", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const g = yield* gatedStdin();
      const c = makeConnector({});
      c.registerProcessForTest("serial", g.stdin);
      const first = yield* Effect.forkChild(c.processWrite({ process_name: "serial", data: "first" }));
      yield* Queue.take(g.entered);
      const second = yield* Effect.forkChild(c.processWrite({ process_name: "serial", data: "second" }));
      yield* settle;
      assert.equal(yield* Queue.size(g.entered), 0, "the second stdin write entered before the first completed");
      yield* Queue.offer(g.release, undefined);
      yield* Queue.take(g.entered);
      yield* Queue.offer(g.release, undefined);
      yield* Fiber.join(first);
      yield* Fiber.join(second);
      assert.equal(g.maxActive(), 1);
    }),
  ));

test("TestCancelledProcessWriteCannotRestoreAnExpiredDeadline", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const g = yield* gatedStdin();
      const c = makeConnector({});
      c.registerProcessForTest("cancel", g.stdin);
      const write = yield* Effect.forkChild(c.processWrite({ process_name: "cancel", data: "blocked" }));
      yield* Queue.take(g.entered);
      yield* Fiber.interrupt(write);
      yield* settle;
      assert.equal(g.active(), 0, "the cancelled write still holds stdin");
      // The next write has the process's stdin to itself.
      const next = yield* Effect.forkChild(c.processWrite({ process_name: "cancel", data: "next" }));
      yield* Queue.take(g.entered);
      yield* Queue.offer(g.release, undefined);
      yield* Fiber.join(next);
    }).pipe(Effect.provide(TestClock.layer())),
  ));
