// Ported from systems/connector/salix-connect/websocket_writer_test.go (same test names).
// The writer is the single owner of socket writes: control frames go before queued data, a close releases every
// blocked send, and an interrupted send never waits behind a full queue. No test waits on real time: each blocked
// step is a fiber, and "released" means its fiber finished.
import assert from "node:assert/strict";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { Cause, Deferred, Effect, Exit, Fiber, Queue, Scope } from "effect";
import { type Message, makeConnector } from "../../src/connector/connector.ts";
import { type JsonWriter, WEBSOCKET_DATA_QUEUE_SIZE, makeWebSocketWriter } from "../../src/connector/websocket-writer.ts";
import { tempDir } from "./support/temp.ts";

/** A socket whose every write waits for a permit; what it started writing is in `started`. */
function gatedWriter() {
  return Effect.gen(function* () {
    const started = yield* Queue.unbounded<Message>();
    const permit = yield* Queue.unbounded<void>();
    const closed = yield* Deferred.make<void>();
    const conn: JsonWriter = {
      writeJson: (m) =>
        Queue.offer(started, m).pipe(
          Effect.andThen(Effect.raceFirst(Queue.take(permit), Deferred.await(closed).pipe(Effect.andThen(Effect.fail(new Error("test writer closed")))))),
        ),
      close: () => Deferred.succeed(closed, undefined).pipe(Effect.asVoid),
    };
    return { conn, started, permit };
  });
}

const scoped = <A, E>(body: Effect.Effect<A, E, Scope.Scope>) => Effect.runPromise(Effect.scoped(body));

test("TestWebSocketWriterPrioritizesControlFrames", () =>
  scoped(
    Effect.gen(function* () {
      const { conn, started, permit } = yield* gatedWriter();
      const writer = yield* makeWebSocketWriter(conn);
      const first = yield* Effect.forkChild(writer.send({ id: "data-1", type: "response" }));
      assert.equal((yield* Queue.take(started)).id, "data-1");
      yield* writer.enqueue({ id: "data-2", type: "response" });
      yield* writer.enqueue({ type: "heartbeat" });
      yield* Queue.offer(permit, undefined);
      yield* Fiber.join(first);
      assert.equal((yield* Queue.take(started)).type, "heartbeat", "control frame did not go first");
      yield* Queue.offer(permit, undefined);
      assert.equal((yield* Queue.take(started)).id, "data-2");
      yield* Queue.offer(permit, undefined);
    }),
  ));

test("TestWebSocketWriterCloseReleasesBlockedSend", () =>
  scoped(
    Effect.gen(function* () {
      const { conn, started } = yield* gatedWriter();
      const writer = yield* makeWebSocketWriter(conn);
      const blocked = yield* Effect.forkChild(writer.send({ id: "blocked", type: "response" }));
      yield* Queue.take(started);
      yield* writer.close(new Error("connection cancelled"));
      assert.ok(Exit.isFailure(yield* Effect.exit(writer.enqueue({ type: "heartbeat" }))), "enqueue succeeded after writer close");
      assert.ok(Exit.isFailure(yield* Fiber.await(blocked)), "blocked send returned without an error");
    }),
  ));

test("TestWebSocketWriterSendContextDoesNotWaitBehindFullQueue", () =>
  scoped(
    Effect.gen(function* () {
      const { conn, started } = yield* gatedWriter();
      const writer = yield* makeWebSocketWriter(conn);
      yield* Effect.forkChild(writer.send({ id: "active", type: "response" }));
      yield* Queue.take(started);
      for (let i = 0; i < WEBSOCKET_DATA_QUEUE_SIZE; i++) yield* writer.enqueue({ id: "queued", type: "response" });
      const cancelled = yield* Effect.forkChild(writer.send({ id: "cancelled", type: "response" }));
      const exit = yield* Fiber.interrupt(cancelled).pipe(Effect.andThen(Fiber.await(cancelled)));
      assert.ok(Exit.isFailure(exit) && Cause.hasInterruptsOnly(exit.cause), "send did not end on interruption behind a full queue");
    }),
  ));

test("TestWebSocketWriterRunsAdmissionReleaseBeforeWritingReply", () =>
  scoped(
    Effect.gen(function* () {
      const { conn, started, permit } = yield* gatedWriter();
      const writer = yield* makeWebSocketWriter(conn);
      const released = yield* Deferred.make<void>();
      let releasedBeforeWrite = false;
      const send = yield* Effect.forkChild(writer.sendBeforeWrite({ id: "reply", type: "response" }, Deferred.succeed(released, undefined).pipe(Effect.asVoid)));
      const write = yield* Queue.take(started);
      releasedBeforeWrite = yield* Deferred.isDone(released);
      assert.ok(releasedBeforeWrite, "reply write started without releasing request admission");
      assert.equal(write.id, "reply");
      yield* Queue.offer(permit, undefined);
      yield* Fiber.join(send);
    }),
  ));

test("TestAbortPendingTransfersClosesFilesAndACKWaiters", async () => {
  const file = await open(join(tempDir(), "pending-write"), "w");
  const c = makeConnector({});
  const session = c.claimConnection(() => Effect.void);
  session.trackPendingWrite("write-1", file);
  const ack = Effect.runPromise(session.waitPendingAck("read-1", 1));
  session.abortPendingTransfers("disconnected");
  assert.equal(session.pendingWriteCount(), 0);
  assert.equal(session.pendingAckCount(), 0);
  await assert.rejects(file.write("after close"), "pending write file remained open");
  assert.equal(await ack, "disconnected");
});

test("TestReadStreamACKWaitHonorsConnectionCancellation", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const c = makeConnector({});
      const session = c.claimConnection(() => Effect.void);
      const wait = yield* Effect.forkChild(session.sendReadStreamFrame("read-1", 1, { id: "read-1", type: "stream" }));
      yield* Effect.yieldNow;
      const exit = yield* Fiber.interrupt(wait).pipe(Effect.andThen(Fiber.await(wait)));
      assert.ok(Exit.isFailure(exit) && Cause.hasInterruptsOnly(exit.cause), "ACK wait ignored cancellation");
      assert.equal(session.pendingAckCount(), 0, "pending ACK map was not cleared");
    }),
  ));

test("TestReadStreamErrorACKReleasesWaiterImmediately", async () => {
  const c = makeConnector({});
  const session = c.claimConnection((frame) =>
    Effect.sync(() => queueMicrotask(() => session.completePendingAck(frame.id!, frame.stream!.seq ?? 0, "server stream consumer closed"))),
  );
  const exit = await Effect.runPromiseExit(
    session.sendReadStreamFrame("meeting-artifact", 1, { id: "meeting-artifact", type: "stream", stream: { seq: 1 } }),
  );
  assert.ok(Exit.isFailure(exit));
  assert.match(String(Cause.squash(exit.cause)), /server stream consumer closed/);
  assert.equal(session.pendingAckCount(), 0, "pending ACK map was not cleared");
});
