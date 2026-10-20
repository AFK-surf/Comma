// TCP dialing as a service (LAN tunnels and gateways), so tests can use an in-memory network.
import { connect } from "node:net";
import { Context, Effect, Layer } from "effect";

/** A connected TCP socket. `read` yields the next chunk, or null once the peer ended. */
export type NetSocket = {
  readonly read: Effect.Effect<Buffer | null>;
  write(bytes: Uint8Array): Effect.Effect<void, Error>;
  /** Half-closes: no more writes. */
  readonly end: Effect.Effect<void>;
  readonly close: Effect.Effect<void>;
};

export class Net extends Context.Service<Net, { dial(host: string, port: number): Effect.Effect<NetSocket, Error> }>()("station/Net") {}

export const liveNet = Layer.succeed(Net)({
  dial: (host, port) =>
    Effect.callback<NetSocket, Error>((resume) => {
      const socket = connect({ host, port });
      const chunks: Array<Buffer | null> = [];
      const waiters: Array<(chunk: Buffer | null) => void> = [];
      const push = (chunk: Buffer | null) => {
        const waiter = waiters.shift();
        if (waiter) waiter(chunk);
        else chunks.push(chunk);
      };
      socket.on("data", (chunk: Buffer) => push(chunk));
      socket.on("end", () => push(null));
      socket.on("close", () => push(null));
      socket.once("error", (error) => {
        if (socket.connecting) resume(Effect.fail(error));
        else push(null);
      });
      socket.once("connect", () =>
        resume(
          Effect.succeed<NetSocket>({
            read: Effect.callback<Buffer | null>((done) => {
              if (chunks.length) return done(Effect.succeed(chunks.shift()!));
              waiters.push((chunk) => done(Effect.succeed(chunk)));
            }),
            write: (bytes) => Effect.callback<void, Error>((done) => void socket.write(bytes, (error) => done(error ? Effect.fail(error) : Effect.void))),
            end: Effect.sync(() => void socket.end()),
            close: Effect.sync(() => void socket.destroy()),
          }),
        ),
      );
    }),
});
