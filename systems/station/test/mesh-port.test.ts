// config.json `mesh.port`: the station's QUIC socket on a port named for it, kept across restarts. The launcher starts
// the new station process while the old one still holds that port, so the mesh waits for the old one to be gone before
// it binds; a port nobody named binds at once. A named port taken by something else is never swapped for another.
import assert from "node:assert/strict";
import { createSocket } from "node:dgram";
import { test, type TestContext } from "node:test";
import { Effect, Fiber, Layer, Stream } from "effect";
import { checkConfig } from "../src/accounts/check.ts";
import { MeshLive } from "../src/mesh/mesh.ts";
import { loadMesh, meshPort, type Mesh } from "../src/mesh/native.ts";
import { SalixRelay } from "../src/mesh/salix-relay.ts";
import { hearErrors } from "../src/ops/log.ts";
import { Agents, type AgentsParts } from "../src/sessions/agents.ts";
import { AdbShares, AdminApi, ControlPlane, Key, MeshNative, Store, Up } from "../src/services.ts";
import { settle } from "./hub-fakes.ts";
import { memoryMesh } from "./memory-mesh.ts";

/// A port as config.json names it. No socket is bound on it but in the last test, which takes one the system gives.
const NAMED = 4770;

test("mesh.port is a UDP port or not said; anything else is refused", () => {
  assert.equal(meshPort({}), undefined);
  assert.equal(meshPort({ mesh: null }), undefined);
  assert.equal(meshPort({ mesh: {} }), undefined);
  assert.equal(meshPort({ mesh: { port: NAMED } }), NAMED);
  checkConfig({ mesh: { port: NAMED } }, "/data");
  for (const port of [0, 65536, 4770.5, "4770"]) {
    assert.throws(() => checkConfig({ mesh: { port } }, "/data"), /mesh\.port: a UDP port, from 1 to 65535/);
  }
  assert.throws(() => checkConfig({ mesh: { port: NAMED, host: "0.0.0.0" } }, "/data"), /unknown field `mesh\.host`/);
  assert.throws(() => checkConfig({ mesh: 4770 }, "/data"), /mesh: an object/);
});

/// The station's mesh layer with its config's `mesh`, the agents' wait for the previous process (`previous`, which the
/// test resolves as the launcher's handover would) and `bind` in place of the addon's.
function startup(t: TestContext, mesh: unknown, bind: (options: Parameters<Mesh["bind"]>[0]) => ReturnType<Mesh["bind"]>) {
  const previous = Promise.withResolvers<void>();
  const built = Promise.withResolvers<void>();
  const binds: Array<string | undefined> = [];
  const errors: string[] = [];
  hearErrors((message, error) => errors.push(`${message}: ${error}`));
  t.after(() => hearErrors(null));
  const agents = { previousGone: previous.promise, config: { raw: () => ({ mesh }) } } as unknown as AgentsParts;
  const inputs = Layer.mergeAll(
    Layer.succeed(Agents)(agents),
    Layer.succeed(ControlPlane)({ state: { state: { workspace_name: "w" }, relays: () => [] }, changes: Stream.never, spec: () => ({ name: "test" }) } as never),
    Layer.succeed(Key)({ seed: Buffer.alloc(32) } as never),
    Layer.succeed(MeshNative)({
      bind: (options: Parameters<Mesh["bind"]>[0]) => {
        binds.push(options.bindAddr);
        return bind(options);
      },
    } as unknown as Mesh),
    Layer.succeed(SalixRelay)({ pump: async () => {} } as never),
    Layer.succeed(Store)(null!),
    Layer.succeed(AdminApi)(null!),
    Layer.succeed(Up)(null!),
    Layer.succeed(AdbShares)(null!),
  );
  const running = Effect.runFork(
    Effect.scoped(
      Effect.gen(function* () {
        yield* Layer.build(MeshLive.pipe(Layer.provide(inputs)));
        built.resolve();
        yield* Effect.never;
      }),
    ),
  );
  t.after(() => Effect.runPromise(Fiber.interrupt(running)));
  return { previous, built, running, binds, errors };
}

/// The memory mesh's endpoint, kept before it goes online at the control plane: what follows the bind is not tested here.
const memoryBind = async (options: Parameters<Mesh["bind"]>[0]) => {
  const endpoint = await memoryMesh().bind(options);
  endpoint.online = () => new Promise<void>(() => {});
  return endpoint;
};

test("with mesh.port the new process is ready at once and binds the port once the old process is gone", async (t) => {
  const s = startup(t, { port: NAMED }, memoryBind);
  // Built: main says ready, and the launcher stops the old process, which holds the port until it exits.
  await s.built.promise;
  await settle();
  assert.deepEqual(s.binds, []);
  s.previous.resolve();
  await settle();
  assert.deepEqual(s.binds, [`0.0.0.0:${NAMED}`]);
  assert.deepEqual(s.errors, []);
});

test("a station stopped during the handover does not bind after the old process is gone", async (t) => {
  const s = startup(t, { port: NAMED }, memoryBind);
  await s.built.promise;
  await Effect.runPromise(Fiber.interrupt(s.running));
  s.previous.resolve();
  await settle();
  assert.deepEqual(s.binds, []);
});

test("without mesh.port the mesh binds any free port beside the old process", async (t) => {
  const s = startup(t, undefined, memoryBind);
  await s.built.promise;
  await settle();
  assert.deepEqual(s.binds, [undefined]);
});

test("a named port that is taken leaves the station off the mesh, said in the log, not on another port", async (t) => {
  const s = startup(t, { port: NAMED }, async () => {
    throw new Error("Address already in use (os error 48)");
  });
  await s.built.promise;
  s.previous.resolve();
  await settle();
  assert.deepEqual(s.binds, [`0.0.0.0:${NAMED}`]);
  assert.equal(s.errors.length, 1);
  assert.match(s.errors[0], /^mesh stopped: .*Address already in use/s);
});

const ALPN = Buffer.from("test/mesh-port/1");
const options = (seed: number, bindAddr: string) => ({ secretKey: Buffer.alloc(32, seed), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr });

test("the addon binds the named port on 127.0.0.1 once it is free, and a peer reaches the station there", async () => {
  const mesh = loadMesh();
  // Another program on the port: the bind fails rather than take another port.
  const other = createSocket("udp4");
  await new Promise<void>((resolve) => other.bind(0, "127.0.0.1", resolve));
  const address = `127.0.0.1:${other.address().port}`;
  await assert.rejects(mesh.bind(options(1, address)));
  await new Promise<void>((resolve) => other.close(() => resolve()));

  const station = await mesh.bind(options(1, address));
  const peer = await mesh.bind(options(2, "127.0.0.1:0"));
  try {
    assert.ok(station.sockets().includes(address), `${station.sockets()}`);
    const accepting = station.accept();
    const outgoing = await peer.connect({ id: station.id(), ips: [address] }, ALPN);
    const incoming = (await accepting)!;
    const stream = await outgoing.openBi();
    await stream.write(Buffer.from("over the named port"));
    await stream.finish();
    const received = (await incoming.acceptBi())!;
    assert.equal((await received.read())?.toString(), "over the named port");
    assert.equal(outgoing.via(), "direct");
    outgoing.close(0, "done");
    incoming.close(0, "done");
  } finally {
    await Promise.all([station.close(), peer.close()]);
  }
});
