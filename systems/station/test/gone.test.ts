// A client's connections whose process is gone (src/mesh/gone.ts): asked whether they are still there when the same
// device connects again, and when one with a view open has received nothing for a while; closed when they do not
// answer, left alone when they do.
import assert from "node:assert/strict";
import { test } from "node:test";
import { GONE_CODE, Superseded, watchQuiet } from "../src/mesh/gone.ts";
import type { Connection } from "../src/mesh/native.ts";

/// A connection whose other end answers (`there`) or not, and whose received packets the test counts.
function conn(id: string, there: boolean) {
  let closed: { code: number; reason: string } | null = null;
  let end!: (why: string) => void;
  const ended = new Promise<string>((resolve) => (end = resolve));
  const c = {
    asked: 0,
    received: 0,
    there,
    remoteId: () => id,
    isClosed: () => closed !== null,
    close: (code: number, reason: string) => {
      closed ??= { code, reason };
      end(reason);
    },
    closed: () => ended,
    answers: async () => {
      c.asked += 1;
      return c.there;
    },
    stats: () => ({ rxBytes: 0, rxPackets: c.received, txBytes: 0, txPackets: 0, lostPackets: 0 }),
    closedWith: () => closed,
  };
  return c;
}
const asConnection = (c: ReturnType<typeof conn>) => c as unknown as Connection;
/// What the fakes above resolved has been taken (each answers at once): no timer.
const settled = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

test("a device that connects again: its older connection that answers nothing is closed, one that answers is kept", async () => {
  const superseded = new Superseded();
  const killed = conn("dev_a", false);
  const live = conn("dev_a", true);
  const other = conn("dev_b", false);
  await superseded.arrived(asConnection(killed));
  await superseded.arrived(asConnection(other));
  assert.equal(killed.asked, 0);
  await superseded.arrived(asConnection(live));
  assert.deepEqual(killed.closedWith(), { code: GONE_CODE, reason: "gone" });
  // Another device's is not asked.
  assert.equal(other.asked, 0);
  // A further one: the live one answers and stays; the closed one is not asked again.
  await superseded.arrived(asConnection(conn("dev_a", true)));
  assert.equal(live.closedWith(), null);
  assert.equal(killed.asked, 1);
});

test("a connection with a view open that received nothing for 30 s is asked, and closed when it does not answer", async () => {
  const c = conn("dev_a", false);
  let tick = () => {};
  const every = (_ms: number, f: () => void) => ((tick = f), () => {});
  let views = 1;
  watchQuiet(asConnection(c), () => views > 0, every, { quiet: 30_000, look: 5_000 });
  const look = async (n: number) => {
    for (let i = 0; i < n; i++) {
      tick();
      await Promise.resolve();
    }
  };
  // A client that sends something within each look is never asked.
  for (let i = 0; i < 10; i++) {
    c.received += 1;
    await look(1);
  }
  assert.equal(c.asked, 0);
  // Nothing open: a quiet one (a phone frozen in the background) is not asked.
  views = 0;
  await look(10);
  assert.equal(c.asked, 0);
  // A view open, and nothing received for 30 s: asked, and closed.
  views = 1;
  await look(5);
  assert.equal(c.asked, 0);
  await look(2);
  assert.equal(c.asked, 1);
  await settled();
  assert.deepEqual(c.closedWith(), { code: GONE_CODE, reason: "gone" });
});

test("a quiet connection with a view open that answers is kept, and asked again only after another quiet while", async () => {
  const c = conn("dev_a", true);
  let tick = () => {};
  watchQuiet(asConnection(c), () => true, (_ms, f) => ((tick = f), () => {}), { quiet: 30_000, look: 5_000 });
  for (let i = 0; i < 7; i++) {
    tick();
    await settled();
  }
  assert.equal(c.asked, 1);
  assert.equal(c.closedWith(), null);
  for (let i = 0; i < 4; i++) {
    tick();
    await settled();
  }
  assert.equal(c.asked, 1);
  tick();
  await settled();
  assert.equal(c.asked, 2);
});
