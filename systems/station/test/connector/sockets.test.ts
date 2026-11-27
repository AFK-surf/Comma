// The live Sockets service (the `ws` package): a dial whose effect is interrupted before the handshake completed closes
// its TCP connection, so a Salix that never answers the upgrade leaves no half-open socket behind. A dial given a proxy
// goes through it, and is made again directly when the proxy, not Salix, is what failed.
import assert from "node:assert/strict";
import { type IncomingMessage, type Server, createServer as createHttpServer } from "node:http";
import { type AddressInfo, type Socket, connect, createServer } from "node:net";
import { test } from "node:test";
import { Duration, Effect, Fiber } from "effect";
import { WebSocketServer } from "ws";
import { Sockets, liveSockets, makeLiveSockets } from "../../src/connector/sockets.ts";
import { AuthError } from "../../src/connector/status.ts";

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

const listening = (server: Server) => new Promise<number>((resolve) => server.listen(0, "127.0.0.1", () => resolve((server.address() as AddressInfo).port)));
const dial = (port: number, proxy: string, sockets = liveSockets) =>
  Effect.runPromise(
    Effect.gen(function* () {
      const live = yield* Sockets;
      return yield* live.dial(`ws://127.0.0.1:${port}/v1/connect`, { authorization: "Bearer tok" }, proxy);
    }).pipe(Effect.provide(sockets)),
  );

/** Salix: counts the upgrades that reach it, and answers each with `refuse`'s status or by echoing frames. */
async function salix(refuse?: number) {
  const server = createHttpServer();
  const accept = new WebSocketServer({ noServer: true });
  const upgrades: IncomingMessage[] = [];
  server.on("upgrade", (request, socket, head) => {
    upgrades.push(request);
    if (refuse) return void socket.end(`HTTP/1.1 ${refuse} Refused\r\ncontent-length: 0\r\nconnection: close\r\n\r\n`);
    accept.handleUpgrade(request, socket, head, (ws) => ws.on("message", (data) => ws.send(data.toString())));
  });
  return { port: await listening(server), upgrades, close: () => (accept.close(), server.closeAllConnections(), server.close()) };
}

/** An HTTP proxy: counts the tunnels asked of it, and makes each (or answers `refuse`'s status). */
async function proxy(refuse?: number) {
  const server = createHttpServer();
  const tunnels: string[] = [];
  const open = new Set<Socket>();
  server.on("connect", (request, client: Socket, head) => {
    tunnels.push(request.url ?? "");
    if (refuse) return void client.end(`HTTP/1.1 ${refuse} Refused\r\ncontent-length: 0\r\n\r\n`);
    const [host, port] = (request.url ?? "").split(":");
    const upstream = connect(Number(port), host, () => {
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      upstream.write(head);
      upstream.pipe(client).pipe(upstream);
    });
    for (const socket of [client, upstream]) (open.add(socket), socket.on("error", () => {}));
  });
  const port = await listening(server);
  return { url: `http://127.0.0.1:${port}`, tunnels, close: () => (open.forEach((socket) => socket.destroy()), server.close()) };
}

test("a dial given a proxy reaches Salix through it", async () => {
  const server = await salix();
  const through = await proxy();
  try {
    const socket = await dial(server.port, through.url);
    await Effect.runPromise(socket.send({ type: "hello" }));
    assert.deepEqual(await Effect.runPromise(socket.receive), { type: "hello" });
    assert.deepEqual(through.tunnels, [`127.0.0.1:${server.port}`]);
    assert.equal(server.upgrades.length, 1);
    // The credential goes to Salix inside the tunnel.
    assert.equal(server.upgrades[0].headers.authorization, "Bearer tok");
    await Effect.runPromise(socket.close);
  } finally {
    through.close();
    server.close();
  }
});

test("a proxy that is not there, or refuses the tunnel, does not keep the station offline: the dial is made directly", async () => {
  const server = await salix();
  // A proxy that went away: its port is closed.
  const gone = await proxy();
  gone.close();
  // A proxy that answers 403 itself: not Salix refusing the credential.
  const refusing = await proxy(403);
  try {
    for (const through of [gone, refusing]) {
      const socket = await dial(server.port, through.url);
      await Effect.runPromise(socket.send({ type: "hello" }));
      assert.deepEqual(await Effect.runPromise(socket.receive), { type: "hello" });
      await Effect.runPromise(socket.close);
    }
    assert.deepEqual(refusing.tunnels, [`127.0.0.1:${server.port}`]);
    // Each dial reached Salix once, directly.
    assert.equal(server.upgrades.length, 2);
  } finally {
    refusing.close();
    server.close();
  }
});

test("a proxy that takes the connection and never answers is given up, its connection closed, and the dial is made directly", async () => {
  const server = await salix();
  // The proxy accepts TCP, reads the CONNECT and says nothing.
  const stalled = createServer();
  const taken = new Promise<Socket>((resolve) => stalled.once("connection", (conn) => resolve(conn.resume())));
  await new Promise<void>((resolve) => stalled.listen(0, "127.0.0.1", resolve));
  try {
    const { port } = stalled.address() as AddressInfo;
    const dialing = dial(server.port, `http://127.0.0.1:${port}`, makeLiveSockets({ proxyDialTimeout: Duration.millis(200) }));
    const conn = await taken;
    const closed = new Promise<void>((resolve) => conn.once("close", () => resolve()));
    const socket = await dialing;
    await Effect.runPromise(socket.send({ type: "hello" }));
    assert.deepEqual(await Effect.runPromise(socket.receive), { type: "hello" });
    assert.equal(server.upgrades.length, 1);
    // The attempt that was given up does not keep its connection to the proxy.
    await closed;
    await Effect.runPromise(socket.close);
  } finally {
    stalled.close();
    server.close();
  }
});

test("Salix's refusal of the credential through the proxy stands: it is not asked again directly", async () => {
  const server = await salix(401);
  const through = await proxy();
  try {
    await assert.rejects(dial(server.port, through.url), (error) => error instanceof AuthError && error.status === 401);
    assert.equal(server.upgrades.length, 1);
  } finally {
    through.close();
    server.close();
  }
});
