// An in-memory WebSocket for tests (the `Sockets` service): the connector dials a URL with headers, and the test, as
// Salix, accepts the connection and exchanges JSON frames with it. Pings and closes are seen by the other side.
// Nothing touches the network; frames move when fibers run. With a `window`, at most that many of the connector's
// frames wait unread: a further send blocks until Salix reads, as a slow peer's TCP window makes it. With
// `windowBytes`, the bound is in encoded bytes: a frame that does not fit beside what is unread waits.
import { Deferred, Effect, Exit, Layer, Queue, Semaphore } from "effect";
import { type JsonSocket, Sockets } from "../../../src/connector/sockets.ts";

export type Peer = {
  readonly url: string;
  readonly headers: Record<string, string>;
  /** The next frame the connector sent (fails once it closed). */
  readonly receive: Effect.Effect<any, Error>;
  send(frame: unknown): Effect.Effect<void>;
  /** Closes from Salix's side: the connector reads the end. */
  close: Effect.Effect<void>;
  /** Pings the connector sent so far. */
  pings(): number;
  /** Resolves when the connector closed its side. */
  readonly closed: Effect.Effect<void>;
  /** Binary frames the connector sent so far (packets through Salix). */
  binaries(): Buffer[];
  /** A binary frame to the connector. */
  sendBinary(data: Buffer): void;
};

export function memorySockets(options: { window?: number; windowBytes?: number } = {}) {
  return Effect.gen(function* () {
    const accepted = yield* Queue.unbounded<Peer>();
    const dials: Array<{ url: string; headers: Record<string, string> }> = [];
    const layer = Layer.succeed(Sockets)({
      dial: (url, headers) =>
        Effect.gen(function* () {
          dials.push({ url, headers });
          const toPeer = yield* Queue.unbounded<any>();
          const credit = options.window === undefined ? undefined : yield* Semaphore.make(options.window);
          const toClient = yield* Queue.unbounded<any>();
          let unreadBytes = 0;
          let drained = yield* Deferred.make<void>();
          const clientClosed = yield* Deferred.make<void>();
          const peerClosed = yield* Deferred.make<void>();
          let pings = 0;
          const binaries: Buffer[] = [];
          let onBinary: ((data: Buffer) => void) | null = null;
          const end = Symbol("end");
          const peer: Peer = {
            url,
            headers,
            receive: Queue.take(toPeer).pipe(
              Effect.tap(() => (credit ? Semaphore.release(credit, 1) : Effect.void)),
              Effect.tap((frame) =>
                Effect.sync(() => {
                  if (frame === end) return;
                  unreadBytes -= JSON.stringify(frame).length;
                  const wake = drained;
                  drained = Deferred.makeUnsafe<void>();
                  Deferred.doneUnsafe(wake, Exit.void);
                }),
              ),
              Effect.flatMap((frame) => (frame === end ? Effect.fail(new Error("connector closed")) : Effect.succeed(frame))),
            ),
            send: (frame) => Queue.offer(toClient, JSON.parse(JSON.stringify(frame))).pipe(Effect.asVoid),
            close: Deferred.succeed(peerClosed, undefined).pipe(Effect.andThen(Queue.offer(toClient, end)), Effect.asVoid),
            pings: () => pings,
            closed: Deferred.await(clientClosed),
            binaries: () => binaries,
            sendBinary: (data) => onBinary?.(Buffer.from(data)),
          };
          const socket: JsonSocket = {
            send: (frame) =>
              Effect.gen(function* () {
                // A blocked send fails when Salix closes, as a write on a closed TCP connection does.
                if (credit) yield* Effect.raceFirst(Semaphore.take(credit, 1), Deferred.await(peerClosed).pipe(Effect.andThen(Effect.fail(new Error("socket closed")))));
                const size = JSON.stringify(frame).length;
                while (options.windowBytes !== undefined && unreadBytes > 0 && unreadBytes + size > options.windowBytes) {
                  yield* Effect.raceFirst(Deferred.await(drained), Deferred.await(peerClosed));
                  if (Deferred.isDoneUnsafe(peerClosed)) break;
                }
                // A frame bigger than the whole window never fits: it waits for a reader that takes it in parts.
                if (options.windowBytes !== undefined && size > options.windowBytes) yield* Effect.raceFirst(Effect.never, Deferred.await(peerClosed));
                if (Deferred.isDoneUnsafe(peerClosed)) return yield* Effect.fail(new Error("socket closed"));
                unreadBytes += size;
                yield* Queue.offer(toPeer, JSON.parse(JSON.stringify(frame)));
              }),
            receive: Queue.take(toClient).pipe(Effect.flatMap((frame) => (frame === end ? Effect.fail(new Error("socket closed")) : Effect.succeed(frame)))),
            ping: Effect.sync(() => void pings++),
            sendBinary: (data) => Effect.sync(() => void binaries.push(Buffer.from(data))),
            onBinary: (handler) => void (onBinary = handler),
            close: Deferred.succeed(clientClosed, undefined).pipe(Effect.andThen(Queue.offer(toPeer, end)), Effect.asVoid),
          };
          yield* Queue.offer(accepted, peer);
          return socket;
        }),
    });
    return { layer, accepted, dials };
  });
}
