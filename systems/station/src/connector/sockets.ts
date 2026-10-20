// The WebSocket client as a service, so the connection to Salix can be replaced by an in-memory one in tests.
import { Context, Effect, Layer } from "effect";
import WebSocket from "ws";
import { AuthError, WebSocketHandshakeError } from "./status.ts";

const HANDSHAKE_BODY_LIMIT = 4096;

/** A connected JSON WebSocket. `receive` fails once the peer closed. */
export type JsonSocket = {
  send(frame: unknown): Effect.Effect<void, Error>;
  /** A binary frame (packets through Salix, the relay of last resort). */
  sendBinary?(data: Buffer): Effect.Effect<void, Error>;
  /** Where binary frames that come go (none: dropped). */
  onBinary?(handler: (data: Buffer) => void): void;
  readonly receive: Effect.Effect<any, Error>;
  readonly ping: Effect.Effect<void>;
  readonly close: Effect.Effect<void>;
};

export class Sockets extends Context.Service<Sockets, { dial(url: string, headers: Record<string, string>): Effect.Effect<JsonSocket, Error> }>()("station/Sockets") {}

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** A `ws` socket (open, or opening) as a JSON socket: frames parsed as they come, sends in order. */
export function jsonSocketOf(ws: WebSocket): JsonSocket {
  const inbox: unknown[] = [];
  const waiters: Array<(frame: { ok: true; value: unknown } | { ok: false; error: Error }) => void> = [];
  let ended: Error | null = null;
  const deliver = (item: { ok: true; value: unknown } | { ok: false; error: Error }) => {
    const waiter = waiters.shift();
    if (waiter) waiter(item);
    else if (item.ok) inbox.push(item.value);
  };
  let binary: ((data: Buffer) => void) | null = null;
  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      binary?.(Buffer.isBuffer(data) ? data : Buffer.concat(data as Buffer[]));
      return;
    }
    try {
      deliver({ ok: true, value: JSON.parse(data.toString()) });
    } catch (e) {
      deliver({ ok: false, error: toError(e) });
    }
  });
  ws.on("close", () => {
    ended ??= new Error("socket closed");
    for (const waiter of waiters.splice(0)) waiter({ ok: false, error: ended });
  });
  ws.on("error", (error) => {
    ended ??= error;
  });
  const socket: JsonSocket = {
    send: (frame) =>
      Effect.callback<void, Error>((done) => {
        if (ended) return done(Effect.fail(ended));
        ws.send(JSON.stringify(frame), (error) => done(error ? Effect.fail(error) : Effect.void));
      }),
    receive: Effect.callback<unknown, Error>((done) => {
      if (inbox.length) return done(Effect.succeed(inbox.shift()));
      if (ended) return done(Effect.fail(ended));
      waiters.push((item) => done(item.ok ? Effect.succeed(item.value) : Effect.fail(item.error)));
    }),
    sendBinary: (data) =>
      Effect.callback<void, Error>((done) => {
        if (ended) return done(Effect.fail(ended));
        ws.send(data, { binary: true }, (error) => done(error ? Effect.fail(error) : Effect.void));
      }),
    onBinary: (handler) => void (binary = handler),
    ping: Effect.sync(() => ws.ping()),
    close: Effect.sync(() => ws.close()),
  };
  return socket;
}

/** Real sockets (the `ws` package). */
export const liveSockets = Layer.succeed(Sockets)({
  dial: (url, headers) =>
    Effect.callback<JsonSocket, Error>((resume) => {
      const ws = new WebSocket(url, { headers, maxPayload: 16 * 1024 * 1024 });
      const opened = new Promise<void>((resolve, reject) => {
        ws.once("open", () => resolve());
        ws.once("error", reject);
        // A refused credential (401, 403) is an AuthError: the app mints another on `auth_required`.
        ws.once("unexpected-response", (_request, response) => {
          const chunks: Buffer[] = [];
          let size = 0;
          const settle = () => {
            const body = Buffer.concat(chunks).toString("utf8");
            const status = response.statusCode ?? 0;
            reject(status === 401 || status === 403 ? new AuthError(status, body) : new WebSocketHandshakeError(status, body));
            ws.terminate();
          };
          response.on("data", (chunk: Buffer) => {
            if (size < HANDSHAKE_BODY_LIMIT) chunks.push(chunk.subarray(0, HANDSHAKE_BODY_LIMIT - size));
            size += chunk.length;
          });
          response.once("end", settle);
          response.once("error", settle);
        });
      });
      const socket = jsonSocketOf(ws);
      opened.then(
        () => resume(Effect.succeed(socket)),
        (error) => resume(Effect.fail(toError(error))),
      );
    }),
});
