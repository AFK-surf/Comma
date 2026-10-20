// An in-memory TCP for tests (the `Net` service): a dial to a listening host:port pairs two ends; nothing goes through
// the machine's network, and every byte moves only when a fiber runs, so a test can settle all work and then look.
import { Effect, Layer, Queue } from "effect";
import { Net, type NetSocket } from "../../../src/connector/net.ts";

export type ServerEnd = {
  /** Bytes the dialing side wrote, as one buffer per write; empty once it ended. */
  readonly received: Queue.Queue<Buffer>;
  write(bytes: Buffer): void;
  /** Ends this side: the dialing side reads its end. */
  end(): void;
  /** Whether the dialing side ended or closed. */
  readonly ended: () => boolean;
};

export function memoryNet() {
  const listeners = new Map<string, Queue.Queue<ServerEnd>>();
  const listen = (host: string, port: number) =>
    Effect.gen(function* () {
      const accepted = yield* Queue.unbounded<ServerEnd>();
      listeners.set(`${host}:${port}`, accepted);
      return accepted;
    });
  const layer = Layer.succeed(Net)({
    dial: (host, port) =>
      Effect.gen(function* () {
        const accepted = listeners.get(`${host}:${port}`);
        if (!accepted) return yield* Effect.fail(new Error(`connect ECONNREFUSED ${host}:${port}`));
        const toServer = yield* Queue.unbounded<Buffer>();
        const toClient = yield* Queue.unbounded<Buffer | null>();
        let clientEnded = false;
        let serverEnded = false;
        const server: ServerEnd = {
          received: toServer,
          write: (bytes) => void Effect.runSync(Queue.offer(toClient, bytes)),
          end: () => {
            serverEnded = true;
            Effect.runSync(Queue.offer(toClient, null));
          },
          ended: () => clientEnded,
        };
        const client: NetSocket = {
          read: Queue.take(toClient),
          write: (bytes) => (clientEnded ? Effect.fail(new Error("write after end")) : Queue.offer(toServer, Buffer.from(bytes)).pipe(Effect.asVoid)),
          end: Effect.sync(() => {
            clientEnded = true;
          }),
          close: Effect.sync(() => {
            clientEnded = true;
            if (!serverEnded) Effect.runSync(Queue.offer(toClient, null));
          }),
        };
        yield* Queue.offer(accepted, server);
        return client;
      }),
  });
  return { listen, layer };
}

/** Lets every runnable fiber run until none is left. */
export const settle = Effect.gen(function* () {
  for (let i = 0; i < 1000; i++) yield* Effect.yieldNow;
});
