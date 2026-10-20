// Serving one connection generation, from Salix (/v1/connect) or a VM gateway (/connect): the writer, the session,
// the runtime carrier and the frame loop. A replaced generation stops reading; its stream workers must drain within
// the drain timeout, or the connector reports its workers stuck.
import { Cause, Effect, Exit, Fiber, type Scope } from "effect";
import { type Message, encodeMessage } from "./message.ts";
import type { RuntimeCarrier } from "./runtime-transport.ts";
import type { Session } from "./session.ts";
import { type JsonWriter, type WebSocketWriter, makeWebSocketWriter } from "./websocket-writer.ts";

export class ConnectionWorkersStuck extends Error {
  override readonly name = "ConnectionWorkersStuck";
  constructor() {
    super("connection workers did not stop after cancellation");
  }
}

export class ConnectionReplaced extends Error {
  override readonly name = "ConnectionReplaced";
  constructor() {
    super("connection replaced");
  }
}

/** A JSON frame transport (a WebSocket, or an in-memory one in tests). `receive` fails once the peer closed. */
export type FrameSocket = {
  send(frame: unknown): Effect.Effect<void, Error>;
  readonly receive: Effect.Effect<any, Error>;
  readonly close: Effect.Effect<void>;
};

export type ConnectionHost = {
  claim(send: (m: Message) => Effect.Effect<void, unknown>, writer: WebSocketWriter): Session;
  release(session: Session): void;
  isActive(session: Session): boolean;
  setIdentity(session: Session, frame: Message): boolean;
  /** Publishes the connect metadata (probing runtimes as the scope allows). */
  publishConnectMetadata(session: Session): Effect.Effect<void, Error>;
  activateCarrier(session: Session): RuntimeCarrier;
  revokeCarrier(carrier: RuntimeCarrier): Effect.Effect<void>;
  systemInfoLoop(session: Session): Effect.Effect<void>;
  onConnected(session: Session, carrier: RuntimeCarrier, frame: Message): Effect.Effect<void>;
  completeRuntimeReply(frame: Message): void;
  /** Runs after each request or stream (the VM marks its workspace dirty). */
  afterWork?: () => void;
  writeTimeout: Effect.Effect<void> | null;
  fork<A, E>(effect: Effect.Effect<A, E>): Fiber.Fiber<A, E>;
};

const overloadRequest = (msg: Message): Message => ({ id: msg.id, type: "error", error: `${msg.method}: connector request capacity exhausted` });
const overloadStream = (msg: Message): Message => ({ id: msg.id, type: "stream", error: "connector stream capacity exhausted", stream: { channel: "done", eof: true } });

/** The writer for a frame socket: each write bounded by the WebSocket write timeout. */
export function socketWriter(socket: FrameSocket, writeTimeout: (effect: Effect.Effect<void, Error>) => Effect.Effect<void, Error>): JsonWriter {
  return {
    writeJson: (message) => writeTimeout(socket.send(encodeMessage(message))),
    close: () => socket.close,
  };
}

/**
 * Serves `socket` until it closes, the generation is replaced, or a write fails. Returns why it ended; fails with
 * ConnectionWorkersStuck when the generation's workers did not drain.
 */
export function serveConnection(host: ConnectionHost, socket: FrameSocket, writer: WebSocketWriter): Effect.Effect<Error, ConnectionWorkersStuck, Scope.Scope> {
  return Effect.gen(function* () {
    const session = host.claim((m) => writer.send(m), writer);
    let carrier: RuntimeCarrier | null = null;
    let loop: Fiber.Fiber<void> | null = null;
    const ended = yield* Effect.exit(
      Effect.gen(function* () {
        yield* host.publishConnectMetadata(session);
        carrier = host.activateCarrier(session);
        loop = host.fork(host.systemInfoLoop(session));
        while (true) {
          // A failed write closes the writer, and with it this generation: the read loop stops too.
          const frame = (yield* Effect.raceFirst(socket.receive, writer.closed.pipe(Effect.flatMap((error) => Effect.fail(error))))) as Message;
          if (!host.isActive(session)) return new ConnectionReplaced();
          switch (frame.type) {
            case "connected":
              if (frame.connector_run_id && host.setIdentity(session, frame)) yield* host.onConnected(session, carrier, frame);
              break;
            case "heartbeat":
              yield* writer.enqueue({ type: "heartbeat" });
              break;
            case "request":
              if (!session.startRequest(frame, host.afterWork)) yield* writer.enqueue(overloadRequest(frame));
              break;
            case "response":
            case "error":
              host.completeRuntimeReply(frame);
              break;
            case "stream":
              if (frame.stream?.channel === "ack") yield* session.handleStream(frame);
              else if (!session.startStream(frame, host.afterWork)) {
                session.finishPendingWrite(frame.id ?? "");
                yield* writer.enqueue(overloadStream(frame));
              }
              break;
          }
        }
      }),
    );
    const reason = Exit.isSuccess(ended) ? ended.value : errorOf(ended);
    if (loop) yield* Fiber.interrupt(loop);
    session.close(reason);
    yield* writer.close(reason);
    host.release(session);
    if (carrier) yield* host.revokeCarrier(carrier);
    const drained = yield* session.wait;
    if (!drained) return yield* Effect.fail(new ConnectionWorkersStuck());
    return reason;
  });
}

function errorOf(exit: Exit.Exit<unknown, unknown>): Error {
  if (Exit.isSuccess(exit)) return new Error("connection closed");
  const error = Cause.squash(exit.cause);
  return error instanceof Error ? error : new Error(String(error));
}

export { makeWebSocketWriter };
