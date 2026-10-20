// Stations of a workspace calling each other over the mesh (peer.rs), its endpoints connected in memory
// (memory-mesh.ts): a request answered by the other's remote tasks; its refusal a Refused; who may call only the
// roster's stations, while the roster is current.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { Refused } from "../src/jobs/remote.ts";
import { PEER_ALPN, member, peerAddr, peerCall, servePeer } from "../src/mesh/peer.ts";
import { memoryMesh } from "./memory-mesh.ts";

const cloudOf = (station: string, peers: string[]): any => ({
  state: { workspace: "ws", station, peers: peers.map((id) => ({ id })) },
  peersCurrent: true,
  removed: () => false,
  relays: () => [],
});

test("a peer's request is answered by the other station's remote tasks", async () => {
  const mesh = memoryMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [PEER_ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [source, target] = await Promise.all([bind(), bind()]);
  const sourceCloud = cloudOf(source.id(), [target.id()]);
  const targetCloud = cloudOf(target.id(), [source.id()]);
  const asked: any[] = [];
  const remote: any = {
    handle: async (workspace: string, peer: string, request: any) => {
      asked.push([workspace, peer, request.method]);
      if (request.method === "no") throw new Error("remote tasks are not enabled");
      return { ok: request.method };
    },
  };
  void (async () => {
    for (;;) {
      const conn = await target.accept();
      if (!conn) return;
      void servePeer(conn, targetCloud, remote).catch(() => {});
    }
  })();
  const port = target.sockets()[0]!.split(":").at(-1);
  const call = peerCall(source, sourceCloud, (id) => ({ id, ips: [`127.0.0.1:${port}`] }));
  try {
    assert.deepEqual(await call(target.id(), "ws", { method: "describe" }), { ok: "describe" });
    assert.deepEqual(await call(target.id(), "ws", { method: "task.get" }), { ok: "task.get" });
    await assert.rejects(call(target.id(), "ws", { method: "no" }), (e) => e instanceof Refused && /not enabled/.test(e.message));
    assert.deepEqual(asked.map((a) => a.slice(0, 2)), [["ws", source.id()], ["ws", source.id()], ["ws", source.id()]]);
    // The transport's own roster.
    assert.deepEqual(await call("", null, { method: "peers" }), { workspace: "ws", stations: [{ id: target.id() }], current: true });
    // Only stations of the roster, of this workspace, while the roster is current.
    await assert.rejects(call("ab".repeat(32), "ws", { method: "describe" }), /not another station/);
    await assert.rejects(call(target.id(), "other", { method: "describe" }), /outside this workspace/);
    targetCloud.state.peers = [];
    await assert.rejects(call(target.id(), "ws", { method: "describe" }), Refused);
    sourceCloud.peersCurrent = false;
    assert.throws(() => member(sourceCloud, target.id(), null), /not current/);
  } finally {
    await Promise.all([source.close(), target.close()]);
  }
});

test("a peer is dialed where the control plane last said it is; one that said nothing, by its id", async () => {
  const mesh = memoryMesh();
  const bind = (key: number) => mesh.bind({ secretKey: Buffer.alloc(32, key), alpns: [PEER_ALPN], relayUrls: [], discovery: false });
  const [source, moved, old] = await Promise.all([bind(1), bind(2), bind(3)]);
  const cloud: any = {
    state: {
      workspace: "ws",
      station: source.id(),
      peers: [
        // What is not a URL or an `ip:port` is left out: it would fail the whole dial.
        { id: moved.id(), home_relay: "https://relay2.comma.test/", addrs: ["192.168.1.5:4770", "[fe80::1%3]:4770", "nowhere", 7] },
        { id: old.id(), home_relay: "not a url" },
      ],
    },
    peersCurrent: true,
    removed: () => false,
    relays: () => ["https://relay.comma.test/"],
  };
  const served: any = { handle: async () => "ok" };
  for (const [endpoint, id] of [[moved, moved.id()], [old, old.id()]] as const) {
    const peers = { ...cloud, state: { ...cloud.state, station: id, peers: [{ id: source.id() }] } };
    void (async () => {
      for (let conn = await endpoint.accept(); conn; conn = await endpoint.accept()) void servePeer(conn, peers, served).catch(() => {});
    })();
  }
  const call = peerCall(source, cloud);
  try {
    assert.equal(await call(moved.id(), "ws", { method: "describe" }), "ok");
    assert.equal(await call(old.id(), "ws", { method: "describe" }), "ok");
    assert.deepEqual(mesh.dials, [
      { id: moved.id(), relays: ["https://relay2.comma.test/", "https://relay.comma.test/"], ips: ["192.168.1.5:4770", "[fe80::1%3]:4770"], salix: true },
      { id: old.id(), relays: ["https://relay.comma.test/"], salix: true },
    ]);
    assert.deepEqual(peerAddr(cloud, "ab".repeat(32)), { id: "ab".repeat(32), relays: ["https://relay.comma.test/"], salix: true });
  } finally {
    await Promise.all([source.close(), moved.close(), old.close()]);
  }
});
