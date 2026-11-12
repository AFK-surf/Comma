// The live Sockets service (the `ws` package): a dial whose effect is interrupted before the handshake completed closes
// its TCP connection, so a Salix that never answers the upgrade leaves no half-open socket behind.
import assert from "node:assert/strict";
import { type AddressInfo, type Socket, createServer } from "node:net";
import { test } from "node:test";
import { Effect, Fiber } from "effect";
import { Sockets, liveSockets } from "../../src/connector/sockets.ts";

// A dial left open never closes the peer: the test then waits until the suite's own timeout ends it.
test("TestLiveDialInterruptedBeforeHandshakeClosesTheConnection", async () => {
  // Salix accepts the TCP connection, reads, and says nothing.
  const server = createServer();
  const accepted = new Promise<Socket>((resolve) => server.once("connection", (conn) => resolve(conn.resume())));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const { port } = server.address() as AddressInfo;
    const dial = Effect.runFork(
      Effect.gen(function* () {
        const sockets = yield* Sockets;
        return yield* sockets.dial(`ws://127.0.0.1:${port}/v1/connect`, {});
      }).pipe(Effect.provide(liveSockets)),
    );
    const conn = await accepted;
    const peerClosed = new Promise<void>((resolve) => conn.once("close", () => resolve()));
    // The connector's dial timeout gives up the dial while the handshake is still pending.
    await Effect.runPromise(Fiber.interrupt(dial));
    await peerClosed;
    assert.ok(conn.destroyed, "the interrupted dial left its TCP connection open");
  } finally {
    server.close();
  }
});
