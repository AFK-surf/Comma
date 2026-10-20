// Ported from systems/connector/salix-connect/lan_gateway_test.go and lan_udp_test.go (same test names).
// The LAN gateway reaches any address, caps response bytes, and collects UDP replies up to a count or a timeout.
// These use real loopback sockets, so their timeouts run on the live clock (README, Determinism).
import assert from "node:assert/strict";
import { createSocket } from "node:dgram";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { after, test } from "node:test";
import { Effect, Exit } from "effect";
import { LAN_GATEWAY_MAX_BYTES, LAN_UDP_MAX_PAYLOAD_BYTES, lanGatewayCapability, lanHttpRequest, udpRequest } from "../../src/connector/lan-gateway.ts";

const closers: Array<() => void> = [];
after(() => closers.forEach((close) => close()));

function httpServer(body: string): Promise<string> {
  const server = createServer((_req, res) => res.end(body));
  closers.push(() => server.close());
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${(server.address() as AddressInfo).port}`)));
}

/** Answers every datagram with each of `replies`, prefixed by the request bytes. */
function udpEcho(...replies: string[]): Promise<number> {
  const socket = createSocket("udp4");
  closers.push(() => socket.close());
  socket.on("message", (msg, from) => {
    for (const reply of replies) socket.send(Buffer.concat([msg, Buffer.from(reply)]), from.port, from.address);
  });
  return new Promise((resolve) => socket.bind(0, "127.0.0.1", () => resolve(socket.address().port)));
}

const udpParams = (port: number, extra: Record<string, unknown> = {}) => ({
  host: "127.0.0.1",
  port,
  payload_b64: Buffer.from("hello").toString("base64"),
  timeout_ms: 500,
  ...extra,
});

test("TestLANHTTPRequestReachesAnyDestination", async () => {
  // The server listens on loopback: the gateway refuses no address.
  const url = await httpServer('{"on":true}');
  const result = await Effect.runPromise(lanHttpRequest({ method: "GET", url }));
  assert.equal(result.status, 200);
  assert.equal(result.body, '{"on":true}');
});

test("TestLANHTTPRequestCapsResponseBytes", async () => {
  const url = await httpServer("x".repeat(LAN_GATEWAY_MAX_BYTES + 10));
  const result = await Effect.runPromise(lanHttpRequest({ method: "GET", url, max_bytes: 10 * LAN_GATEWAY_MAX_BYTES }));
  assert.equal(result.truncated, true);
  assert.equal(String(result.body).length, LAN_GATEWAY_MAX_BYTES);
});

test("TestLANGatewayCapabilityAdvertisesLimits", () => {
  const capability = lanGatewayCapability();
  assert.deepEqual(capability.methods, ["lan_http_request", "lan_tcp_dial", "udp_request"]);
  assert.equal(capability.max_bytes, 65536);
  assert.equal(capability.max_timeout_seconds, 30);
});

test("TestUDPRequestStopsAtMaxResponses", async () => {
  const port = await udpEcho("-a", "-b", "-c");
  const result = await Effect.runPromise(udpRequest(udpParams(port, { max_responses: 2 })));
  assert.equal(result.timed_out, false);
  assert.equal(result.responses.length, 2);
  assert.equal(Buffer.from(result.responses[0].payload_b64, "base64").toString(), "hello-a");
  assert.equal(result.responses[0].from, `127.0.0.1:${port}`);
});

test("TestUDPRequestCollectsUntilTimeout", async () => {
  const port = await udpEcho("-a");
  const result = await Effect.runPromise(udpRequest(udpParams(port, { timeout_ms: 200 })));
  assert.equal(result.timed_out, true);
  assert.equal(result.responses.length, 1);
});

test("TestUDPRequestRejectsBadParams", async () => {
  for (const params of [
    udpParams(0),
    udpParams(54321, { host: "" }),
    udpParams(54321, { payload_b64: "not base64!" }),
    udpParams(54321, { payload_b64: Buffer.alloc(LAN_UDP_MAX_PAYLOAD_BYTES + 1).toString("base64") }),
  ]) {
    assert.ok(Exit.isFailure(await Effect.runPromiseExit(udpRequest(params))), `params ${JSON.stringify(params).slice(0, 80)} were accepted`);
  }
});
