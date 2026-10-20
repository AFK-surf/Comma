// A desktop station signed in to two Workspaces (Groups) holds a connector run to Salix for each, and one iroh
// endpoint, whose packets for Salix (the relay of last resort) go through its SalixRelayHub. Salix passes a packet only
// within the Group of the connection it came on, so the hub sends a peer's packets on the connection that peer was last
// heard on (on every connection until it is heard), and one connection ending leaves the others carrying.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";
import { Effect, Fiber, Queue } from "effect";
import { makeConnector } from "../../src/connector/connector.ts";
import { SalixRelayHub } from "../../src/mesh/salix-relay.ts";
import type { Endpoint } from "../../src/mesh/native.ts";
import { settle } from "./support/memory-net.ts";
import { type Peer, memorySockets } from "./support/memory-socket.ts";
import { tempDir } from "./support/temp.ts";

const isolated = { env: { HOME: tempDir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin" } };
const PEER_G1 = "a1".repeat(32);
const PEER_G2 = "b2".repeat(32);
const NEW_PEER = "c3".repeat(32);

/** The iroh endpoint's side of the hub: the test hands it packets to send, and sees what came in. */
function fakeEndpoint() {
  const out: Array<{ to: string; data: Buffer }> = [];
  let wake: (() => void) | null = null;
  // Resolved when the hub asks for more packets: it has handed the last batch to its connections.
  let handed: (() => void) | null = null;
  let closed = false;
  const came: Array<[string, string]> = [];
  const endpoint = {
    relayIncoming: (from: string, data: Buffer) => void came.push([from, data.toString()]),
    relayOutgoing: async () => {
      const h = handed;
      handed = null;
      h?.();
      while (out.length === 0 && !closed) await new Promise<void>((resolve) => (wake = resolve));
      return out.splice(0);
    },
  } as unknown as Endpoint;
  const poke = () => {
    const w = wake;
    wake = null;
    w?.();
  };
  return {
    endpoint,
    came,
    /** Hands the hub a packet for `to`, and waits until the hub has passed it to its connections, which then send it. */
    send: (to: string, data: string) =>
      Effect.gen(function* () {
        yield* Effect.promise(() => new Promise<void>((resolve) => ((handed = resolve), out.push({ to, data: Buffer.from(data) }), poke())));
        yield* settle;
      }),
    close: () => ((closed = true), poke()),
  };
}

const frame = (from: string, data: string) => Buffer.concat([Buffer.from([1]), Buffer.from(from, "hex"), Buffer.from(data)]);
/** What a connection carried out, as [to, packet]. */
const carried = (peer: Peer) => peer.binaries().map((f) => [f.subarray(1, 33).toString("hex"), f.subarray(33).toString()]);

/** The station: one hub, its endpoint pumping through it, and a connector run per Group, each registered with Salix. */
const station = Effect.gen(function* () {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const endpointId = Buffer.from(publicKey.export({ format: "jwk" }).x as string, "base64url").toString("hex");
  const hub = new SalixRelayHub(endpointId, (message) => sign(null, message, privateKey));
  const iroh = fakeEndpoint();
  const pumping = hub.pump(iroh.endpoint);
  const salix = yield* memorySockets();
  const connect = (group: string) =>
    Effect.gen(function* () {
      const c = makeConnector({ ...isolated, server: "https://salix.test", token: `token-${group}`, name: `laptop-${group}`, root: tempDir(), testClock: true }, salix.layer, { relay: hub });
      const run = yield* Effect.forkChild(c.runRemoteOnce);
      const peer = yield* Queue.take(salix.accepted);
      yield* peer.receive;
      yield* peer.send({ type: "connected", connector_run_id: `run-${group}`, relay_challenge: `nonce-${group}` });
      const register = yield* peer.receive;
      assert.equal(register.method, "relay_register");
      yield* peer.send({ id: register.id, type: "response", result: { ok: true } });
      yield* settle;
      return { c, run, peer };
    });
  // Group 1's connection registers first, Group 2's last.
  const g1 = yield* connect("g1");
  const g2 = yield* connect("g2");
  const stop = Effect.gen(function* () {
    iroh.close();
    yield* Effect.promise(() => pumping);
    for (const g of [g1, g2]) {
      yield* g.peer.close;
      yield* Fiber.await(g.run);
      yield* g.c.close();
    }
  });
  return { hub, iroh, g1, g2, stop };
});

test("a station in two Groups sends a peer's packets on the connection that peer is heard on", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const { iroh, g1, g2, stop } = yield* station;
      // A peer of Group 1 is heard on Group 1's connection, a peer of Group 2 on Group 2's.
      g1.peer.sendBinary(frame(PEER_G1, "hello from g1"));
      g2.peer.sendBinary(frame(PEER_G2, "hello from g2"));
      assert.deepEqual(iroh.came, [
        [PEER_G1, "hello from g1"],
        [PEER_G2, "hello from g2"],
      ]);
      yield* iroh.send(PEER_G1, "to g1");
      yield* iroh.send(PEER_G2, "to g2");
      assert.deepEqual(carried(g1.peer), [[PEER_G1, "to g1"]], "Group 1's peer was not sent its packet on Group 1's connection");
      assert.deepEqual(carried(g2.peer), [[PEER_G2, "to g2"]], "Group 2's peer was not sent its packet on Group 2's connection");
      // A peer not heard yet: its packets go on every connection; Salix passes them where it is.
      yield* iroh.send(NEW_PEER, "first");
      assert.deepEqual(carried(g1.peer).slice(1), [[NEW_PEER, "first"]]);
      assert.deepEqual(carried(g2.peer).slice(1), [[NEW_PEER, "first"]]);
      yield* stop;
    }),
  ));

test("a station in two Groups keeps relaying on one connection when the other ends", () =>
  Effect.runPromise(
    Effect.gen(function* () {
      const { iroh, g1, g2, stop } = yield* station;
      g1.peer.sendBinary(frame(PEER_G1, "hello"));
      g2.peer.sendBinary(frame(PEER_G1, "hello again"));
      // Group 2's connection ends: Group 1's still carries, also to a peer last heard on Group 2's.
      yield* g2.peer.close;
      yield* Fiber.await(g2.run);
      yield* iroh.send(PEER_G1, "after g2 ended");
      assert.deepEqual(carried(g1.peer), [[PEER_G1, "after g2 ended"]], "Group 1's connection stopped carrying when Group 2's ended");
      assert.deepEqual(carried(g2.peer), []);
      yield* stop;
    }),
  ));
