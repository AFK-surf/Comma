// Ported from systems/connector/salix-connect/lan_tunnel_test.go (same test names).
// lan_tcp_dial relays bytes both ways inside a credit window, acknowledges what it wrote, ends with either side, and
// refuses bad ports. The TCP side is the in-memory Net, so "nothing beyond the window" is checked after all work settled.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Exit, Layer, Queue } from "effect";
import { type Message, makeConnector } from "../../src/connector/connector.ts";
import { LAN_TUNNEL_ACK_CHANNEL, LAN_TUNNEL_CHANNEL, LAN_TUNNEL_WINDOW } from "../../src/connector/lan-tunnel.ts";
import { memoryNet, settle } from "./support/memory-net.ts";

const b64 = (s: string | Buffer) => Buffer.from(s).toString("base64");

/** Dials a listener through lan_tcp_dial; returns the session, the frames it sent, and the accepted server end. */
function openTunnel(net: ReturnType<typeof memoryNet>) {
  return Effect.gen(function* () {
    const accepted = yield* net.listen("127.0.0.1", 4022);
    const frames = yield* Queue.unbounded<Message>();
    const c = makeConnector({}, net.layer);
    const session = c.claimConnection((m) => Queue.offer(frames, m).pipe(Effect.asVoid));
    const result = yield* c.lanTcpDial(session, "t1", { host: "127.0.0.1", port: 4022 });
    const server = yield* Queue.take(accepted);
    const next = Effect.gen(function* () {
      const m = yield* Queue.take(frames);
      assert.ok(m.id === "t1" && m.type === "stream" && m.stream, `frame = ${JSON.stringify(m)}`);
      return m;
    });
    const send = (stream: Message["stream"]) => {
      assert.ok(session.routeTunnelFrame({ id: "t1", type: "stream", stream }), "tunnel frame was not routed");
    };
    return { c, session, frames, server, result, next, send };
  });
}

const run = <A, E>(body: (net: ReturnType<typeof memoryNet>) => Effect.Effect<A, E>) => {
  const net = memoryNet();
  return Effect.runPromise(body(net).pipe(Effect.provide(net.layer as Layer.Layer<never>)));
};

test("TestLANTCPDialRelaysBytesInBothDirections", () =>
  run((net) =>
    Effect.gen(function* () {
      const h = yield* openTunnel(net);
      assert.equal(h.result.status, "connected");
      assert.equal(h.result.window, LAN_TUNNEL_WINDOW);
      h.server.write(Buffer.from("SSH-2.0-test\r\n"));
      const data = yield* h.next;
      assert.equal(data.stream!.channel, LAN_TUNNEL_CHANNEL);
      assert.equal(data.stream!.data, b64("SSH-2.0-test\r\n"));
      h.send({ channel: LAN_TUNNEL_CHANNEL, data: b64("abc") });
      h.send({ channel: LAN_TUNNEL_CHANNEL, data: b64("de") });
      const got = Buffer.concat([yield* Queue.take(h.server.received), yield* Queue.take(h.server.received)]);
      assert.equal(got.toString(), "abcde");
      assert.deepEqual([(yield* h.next).stream, (yield* h.next).stream].map((s) => [s!.channel, s!.seq]), [
        [LAN_TUNNEL_ACK_CHANNEL, 3],
        [LAN_TUNNEL_ACK_CHANNEL, 5],
      ]);
      // The server closing its side ends the tunnel with an eof frame.
      h.server.end();
      const eof = yield* h.next;
      assert.ok(eof.stream!.channel === LAN_TUNNEL_CHANNEL && eof.stream!.eof && !eof.error, `eof frame = ${JSON.stringify(eof)}`);
      assert.equal(h.session.routeTunnelFrame({ id: "t1", stream: { channel: LAN_TUNNEL_CHANNEL, data: "eA==" } }), true, "a late frame for a closed tunnel must still be consumed");
    }),
  ));

test("TestLANTCPDialStopsReadingAtAFullWindow", () =>
  run((net) =>
    Effect.gen(function* () {
      const h = yield* openTunnel(net);
      const payload = Buffer.alloc(2 * LAN_TUNNEL_WINDOW, "x");
      h.server.write(payload);
      let received = 0;
      while (received < LAN_TUNNEL_WINDOW) received += Buffer.from((yield* h.next).stream!.data!, "base64").length;
      assert.equal(received, LAN_TUNNEL_WINDOW, "sent more than one window before an ack");
      yield* settle;
      assert.equal(yield* Queue.size(h.frames), 0, "a frame went beyond the window before an ack");
      h.send({ channel: LAN_TUNNEL_ACK_CHANNEL, seq: received });
      while (received < payload.length) received += Buffer.from((yield* h.next).stream!.data!, "base64").length;
    }),
  ));

test("TestLANTCPDialClosesOnServerEOFAndRefusesOverflow", () =>
  run((net) =>
    Effect.gen(function* () {
      const first = yield* openTunnel(net);
      first.send({ channel: LAN_TUNNEL_CHANNEL, eof: true });
      yield* settle;
      assert.ok(first.server.ended(), "the server did not see the end");
      const h = yield* openTunnel(net);
      // The writer holds a full window of queued bytes: one more byte overflows it.
      h.session.fillTunnelQueueForTest("t1", LAN_TUNNEL_WINDOW);
      h.send({ channel: LAN_TUNNEL_CHANNEL, data: b64("y") });
      const overflow = yield* h.next;
      assert.ok(overflow.stream!.eof && overflow.error === "tunnel window exceeded", `overflow frame = ${JSON.stringify(overflow)}`);
    }),
  ));

test("TestLANTCPDialEndsWithTheSocketAndRefusesBadPorts", () =>
  run((net) =>
    Effect.gen(function* () {
      const h = yield* openTunnel(net);
      h.session.close("canceled");
      yield* settle;
      assert.ok(h.server.ended(), "the server end stayed open after the socket closed");
      const c = makeConnector({}, net.layer);
      const session = c.claimConnection(() => Effect.void);
      for (const port of [0, 70000]) {
        assert.ok(Exit.isFailure(yield* Effect.exit(c.lanTcpDial(session, "bad", { host: "127.0.0.1", port }))), `port ${port} accepted`);
      }
      assert.ok(Exit.isFailure(yield* Effect.exit(c.lanTcpDial(session, "refused", { host: "127.0.0.1", port: 4999 }))), "closed port accepted");
      assert.equal(session.tunnelCount(), 0, "failed dials left tunnels");
      session.close("canceled");
    }),
  ));
