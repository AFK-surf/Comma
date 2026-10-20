// The single owner of a WebSocket's writes. Callers either wait for their write (`send`) or, from the read loop,
// queue a frame without waiting (`enqueue`): a full queue there fails the connection instead of stalling the reader.
// Control frames (heartbeat, metadata) go before queued data. Closing fails every waiting and later send.
import { Cause, Deferred, Effect, Exit, Fiber, Option, Queue, type Scope } from "effect";
import type { Message } from "./message.ts";

export const WEBSOCKET_CONTROL_QUEUE_SIZE = 16;
export const WEBSOCKET_DATA_QUEUE_SIZE = 64;

export class WebSocketClosed extends Error {
  override readonly name = "WebSocketClosed";
  constructor(message = "websocket closed") {
    super(message);
  }
}

export class WebSocketQueueFull extends Error {
  override readonly name = "WebSocketQueueFull";
  constructor() {
    super("websocket write queue full");
  }
}

/** What the writer needs from a socket: a JSON frame write (bounded by its own deadline) and a close. */
export type JsonWriter = {
  writeJson(message: Message): Effect.Effect<void, Error>;
  close(): Effect.Effect<void>;
};

type Write = {
  message: Message;
  /** Completed with the write's outcome; absent for fire-and-forget frames. */
  result?: Deferred.Deferred<void, Error>;
  /** Runs right before the frame can become visible on the wire. */
  beforeWrite?: Effect.Effect<void>;
};

export type WebSocketWriter = {
  /** Writes `message` and waits for the write. Interruption abandons the wait (and the write, if not started). */
  send(message: Message): Effect.Effect<void, Error>;
  /**
   * As `send`, running `beforeWrite` once the frame is admitted to the queue and immediately before it is written:
   * a request releases its admission slot there, so its reply can never be seen before the slot is free.
   */
  sendBeforeWrite(message: Message, beforeWrite: Effect.Effect<void>): Effect.Effect<void, Error>;
  /** Queues `message` without waiting for capacity or the write. */
  enqueue(message: Message): Effect.Effect<void, Error>;
  close(error?: Error): Effect.Effect<void>;
  readonly closed: Effect.Effect<Error>;
};

const isControl = (message: Message) => message.type === "heartbeat" || message.type === "metadata";

/** Starts the writer in the current scope; closing the scope closes the writer. */
export function makeWebSocketWriter(conn: JsonWriter): Effect.Effect<WebSocketWriter, never, Scope.Scope> {
  return Effect.gen(function* () {
    const control = yield* Queue.bounded<Write>(WEBSOCKET_CONTROL_QUEUE_SIZE);
    const data = yield* Queue.bounded<Write>(WEBSOCKET_DATA_QUEUE_SIZE);
    const done = yield* Deferred.make<Error>();
    let closedWith: Error | undefined;

    const closeError = () => closedWith ?? new WebSocketClosed();

    const close = (error: Error = new WebSocketClosed()): Effect.Effect<void> =>
      Effect.suspend(() => {
        if (closedWith) return Effect.void;
        closedWith = error;
        return Deferred.succeed(done, error).pipe(Effect.andThen(conn.close()), Effect.asVoid);
      });

    const failed = Deferred.await(done).pipe(Effect.flatMap((error) => Effect.fail(error)));

    const complete = (write: Write, exit: Exit.Exit<void, Error>) => (write.result ? Deferred.done(write.result, exit).pipe(Effect.asVoid) : Effect.void);

    const next: Effect.Effect<Write> = Effect.suspend(() => {
      const urgent = Queue.takeUnsafe(control);
      if (urgent && Exit.isSuccess(urgent)) return Effect.succeed(urgent.value);
      return Effect.raceFirst(Queue.take(control), Queue.take(data));
    });

    const loop: Effect.Effect<void> = Effect.gen(function* () {
      while (true) {
        const write = yield* Effect.raceFirst(next.pipe(Effect.map(Option.some)), Deferred.await(done).pipe(Effect.as(Option.none<Write>())));
        if (Option.isNone(write)) return;
        const request = write.value;
        if (closedWith) {
          yield* complete(request, Exit.fail(closeError()));
          return;
        }
        // A sender that gave up before its turn does not reach the wire.
        if (request.result && (yield* Deferred.isDone(request.result))) continue;
        if (request.beforeWrite) yield* request.beforeWrite;
        const exit = yield* Effect.exit(conn.writeJson(request.message));
        yield* complete(request, exit);
        if (Exit.isFailure(exit)) {
          yield* close(errorOf(exit));
          return;
        }
      }
    });

    const fiber = yield* Effect.forkScoped(loop);
    yield* Effect.addFinalizer(() => close().pipe(Effect.andThen(Fiber.interrupt(fiber))));

    const queueFor = (message: Message) => (isControl(message) ? control : data);

    const sendBeforeWrite = (message: Message, beforeWrite?: Effect.Effect<void>): Effect.Effect<void, Error> =>
      Effect.gen(function* () {
        if (closedWith) return yield* Effect.fail(closeError());
        const result = yield* Deferred.make<void, Error>();
        const write: Write = { message, result, beforeWrite };
        // Waiting for queue capacity and for the write both end on interruption or close.
        yield* Effect.raceFirst(Queue.offer(queueFor(message), write).pipe(Effect.asVoid), failed).pipe(
          Effect.onInterrupt(() => Deferred.interrupt(result)),
        );
        return yield* Effect.raceFirst(Deferred.await(result), failed).pipe(Effect.onInterrupt(() => Deferred.interrupt(result)));
      });

    return {
      send: (message) => sendBeforeWrite(message),
      sendBeforeWrite: (message, beforeWrite) => sendBeforeWrite(message, beforeWrite),
      enqueue: (message) =>
        Effect.suspend(() => {
          if (closedWith) return Effect.fail(closeError());
          if (!Queue.offerUnsafe(queueFor(message), { message })) return Effect.fail(new WebSocketQueueFull());
          return closedWith ? Effect.fail(closeError()) : Effect.void;
        }),
      close,
      closed: Deferred.await(done),
    };
  });
}

function errorOf(exit: Exit.Exit<void, Error>): Error {
  if (Exit.isSuccess(exit)) return new WebSocketClosed();
  const error = Cause.squash(exit.cause);
  return error instanceof Error ? error : new WebSocketClosed(String(error));
}
