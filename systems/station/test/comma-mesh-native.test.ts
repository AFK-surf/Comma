// Comma's client endpoint on the station's own addon (`@comma/mesh/station-native`, which the desktop app's core uses):
// a request served between two endpoints on 127.0.0.1, the station knowing the client by the id its credential names.
import assert from "node:assert/strict";
import { test } from "node:test";
import { MESH_ALPN, MeshClient, serveMesh } from "@comma/mesh";
import { bindNativeEndpoint } from "@comma/mesh/station-native";
import { loadMesh } from "../src/mesh/native.ts";
import { linkOf } from "../src/mesh/comma.ts";

test("a client's endpoint on the addon reaches a station on loopback, the station knowing it by its id", async (t) => {
  const mesh = loadMesh();
  const station = await bindNativeEndpoint(mesh, { secretKey: new Uint8Array(32).fill(1), alpns: [MESH_ALPN], bindAddr: "127.0.0.1:0" });
  const app = await bindNativeEndpoint(mesh, { secretKey: new Uint8Array(32).fill(2), bindAddr: "127.0.0.1:0" });
  const server = serveMesh<string>({
    endpoint: station,
    verify: async (credential, peer) => ({ principal: `${credential}@${peer}` }),
    handle: async (request) => ({ status: 200, body: new TextEncoder().encode(request.principal) }),
  });
  const client = new MeshClient({ endpoint: app, credential: async () => "member" });
  t.after(async () => {
    client.close();
    server.close();
    await Promise.all([app.close(), station.close()]);
  });
  const addresses = [`127.0.0.1:${station.sockets()[0]!.split(":").at(-1)}`];
  const response = await client.request({ id: station.id, addresses }, { method: "GET", path: "/whoami" });
  let body = "";
  for await (const chunk of response.body) body += new TextDecoder().decode(chunk);
  assert.equal(response.status, 200);
  assert.equal(body, `member@${app.id}`);
});

test("a connection on the addon says its path's round trip and congestion window, and what went over it", async (t) => {
  const mesh = loadMesh();
  const bind = (n: number, alpns: Buffer[]) => mesh.bind({ secretKey: Buffer.alloc(32, n), alpns, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [station, app] = await Promise.all([bind(3, [Buffer.from(MESH_ALPN)]), bind(4, [])]);
  t.after(() => Promise.all([app.close(), station.close()]));
  const accepted = station.accept();
  const out = await app.connect({ id: station.id(), ips: [`127.0.0.1:${station.sockets()[0]!.split(":").at(-1)}`] }, Buffer.from(MESH_ALPN));
  const stream = await out.openBi();
  await stream.write(Buffer.from("hello"));
  const conn = (await accepted)!;
  await (await conn.acceptBi())!.read();
  const link = linkOf(conn)!;
  assert.equal(typeof link.rttMs, "number");
  assert.ok(link.cwnd! > 0, JSON.stringify(link));
  assert.equal(typeof link.congestionEvents, "number");
  assert.ok(link.rxBytes! > 0 && link.txBytes! > 0, JSON.stringify(link));
});

test("a stream's reading half stopped on the addon is told to the other end, whose writes then end", async (t) => {
  const mesh = loadMesh();
  const bind = (n: number, alpns: Buffer[]) => mesh.bind({ secretKey: Buffer.alloc(32, n), alpns, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [station, app] = await Promise.all([bind(7, [Buffer.from(MESH_ALPN)]), bind(8, [])]);
  t.after(() => Promise.all([app.close(), station.close()]));
  const accepted = station.accept();
  const out = await app.connect({ id: station.id(), ips: [`127.0.0.1:${station.sockets()[0]!.split(":").at(-1)}`] }, Buffer.from(MESH_ALPN));
  const stream = await out.openBi();
  await stream.write(Buffer.from("hello"));
  const conn = (await accepted)!;
  const served = (await conn.acceptBi())!;
  await served.read();
  await served.write(Buffer.from("first"));
  assert.deepEqual(await stream.read(), Buffer.from("first"));
  const stopped = served.stopped();
  await stream.stop!(5);
  await stopped;
  await assert.rejects(served.write(Buffer.from("more")));
});

test("a connection on the addon asks whether the client's end is there: a live one acknowledges, one closed does not", async (t) => {
  const mesh = loadMesh();
  const bind = (n: number, alpns: Buffer[]) => mesh.bind({ secretKey: Buffer.alloc(32, n), alpns, relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  const [station, app] = await Promise.all([bind(5, [Buffer.from(MESH_ALPN)]), bind(6, [])]);
  t.after(() => Promise.all([app.close(), station.close()]));
  const accepted = station.accept();
  const out = await app.connect({ id: station.id(), ips: [`127.0.0.1:${station.sockets()[0]!.split(":").at(-1)}`] }, Buffer.from(MESH_ALPN));
  const stream = await out.openBi();
  await stream.write(Buffer.from("hello"));
  const conn = (await accepted)!;
  await (await conn.acceptBi())!.read();
  // Heard from it, not taken as there for want of datagrams: what it received grew with the answer.
  const before = conn.stats!().rxPackets!;
  assert.equal(await conn.answers!(3_000), true);
  assert.ok(conn.stats!().rxPackets! > before);
  out.close(0, "done");
  await conn.closed();
  assert.equal(await conn.answers!(3_000), false);
});
