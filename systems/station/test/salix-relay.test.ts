// Salix as the relay of last resort, through the real mesh addon: two endpoints with no IP path and no relay reach
// each other only through the Salix transport, whose packets this test carries between them as Salix would (by
// endpoint id), and a dropped packet is sent again by QUIC.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { loadMesh } from "../src/mesh/native.ts";

const ALPN = Buffer.from("test/salix-relay/1");

test("two stations reach each other only through Salix, which carries their packets by endpoint id", async () => {
  const mesh = loadMesh();
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [ALPN], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0", salixRelay: true, relayOnly: true } as never);
  const [a, b] = await Promise.all([bind(), bind()]);
  const endpoints = new Map([[a.id(), a], [b.id(), b]]);
  let carried = 0;
  let dropped = false;
  // Salix: what one endpoint sends to an id, the endpoint with that id receives, from the sender's id.
  const carry = async (from: typeof a) => {
    for (;;) {
      const packets = await from.relayOutgoing!(64);
      if (packets.length === 0) return;
      for (const packet of packets) {
        // One packet lost on the way: QUIC must send it again.
        if (!dropped && carried === 3) {
          dropped = true;
          continue;
        }
        carried++;
        endpoints.get(packet.to)?.relayIncoming!(from.id(), packet.data);
      }
    }
  };
  void carry(a);
  void carry(b);
  try {
    const accepted = (async () => {
      const conn = await b.accept();
      const stream = await conn!.acceptBi();
      const got = await stream!.read();
      await stream!.write(Buffer.from(`echo ${got}`));
      await stream!.finish();
      await conn!.closed();
    })();
    const conn = await a.connect({ id: b.id(), salix: true }, ALPN);
    const stream = await conn.openBi();
    await stream.write(Buffer.from("hello"));
    await stream.finish();
    const parts: Buffer[] = [];
    for (let chunk = await stream.read(); chunk; chunk = await stream.read()) parts.push(chunk);
    assert.equal(Buffer.concat(parts).toString(), "echo hello");
    assert.ok(carried > 0 && dropped, "no packet went through Salix");
    conn.close(0, "done");
    await accepted.catch(() => {});
  } finally {
    await Promise.all([a.close(), b.close()]);
  }
});
