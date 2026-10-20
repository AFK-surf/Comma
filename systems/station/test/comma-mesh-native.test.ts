// Comma's client endpoint on the station's own addon (`@comma/mesh/station-native`, which the desktop app's core uses):
// a request served between two endpoints on 127.0.0.1, the station knowing the client by the id its credential names.
import assert from "node:assert/strict";
import { test } from "node:test";
import { MESH_ALPN, MeshClient, serveMesh } from "@comma/mesh";
import { bindNativeEndpoint } from "@comma/mesh/station-native";
import { loadMesh } from "../src/mesh/native.ts";

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
