// A view's pace (mesh/screen-pace.ts, ported with its tests from still.fail): which frames may go, and the bit rate its source
// is asked for, from the acknowledgements alone, on a clock the test moves.
import assert from "node:assert/strict";
import { test } from "node:test";
import { AHEAD_MS, CUT, LINK_SLACK_MS, DOWN, DOWNSIZE_MS, DOWNSIZE_SHARE, FrameLatency, LOW_BOUNDS, Sizer, UPSIZE_MS, LoopStall, MAX_RATE, MAX_UNACKED, MIN_RATE, Pacer, QUEUE_MS, START_RATE, START_UNACKED, START_UP, UP, UP_AFTER_MS, UP_EVERY_MS, UP_FAST, ownRate, type Quality, queueMs, rateCeiling, rateToAsk, SALIX_RATE, SHARPER, STILL_MS, Sharpener, viewCeiling } from "../src/mesh/screen-pace.ts";

function paced() {
  let now = 0;
  const pacer = new Pacer(() => now);
  let ts = 0;
  return {
    pacer,
    at: (ms: number) => void (now = ms),
    /// Frames sent while the pacer lets them (at most `n`), each `bytes` long: their timestamps.
    send(n: number, bytes = 10_000): number[] {
      const sent: number[] = [];
      for (let i = 0; i < n && pacer.may(); i++) {
        ts += 1000;
        pacer.sent(ts, bytes);
        sent.push(ts);
      }
      return sent;
    },
  };
}

/// Frames offered each 16 ms for `ms` over a link that decodes each `trip` ms after it went: how many went.
function over(trip: number, ms: number): number {
  const p = paced();
  const due: { at: number; ts: number }[] = [];
  let went = 0;
  for (let t = 0; t < ms; t++) {
    p.at(t);
    while (due.length > 0 && due[0]!.at <= t) p.pacer.acked(due.shift()!.ts);
    if (t % 16 === 0) for (const ts of p.send(1)) (went++, due.push({ at: t + trip, ts }));
  }
  return went;
}

test("a far link carries as many frames as a near one: they go while the oldest waits no longer than the round trip", () => {
  const near = over(20, 2000);
  const far = over(150, 2000);
  assert.ok(near >= 120, `near: ${near}`);
  assert.ok(far >= near - 12, `far: ${far} of ${near}`);
  // Two before the round trip is known, then as many as the link holds.
  const p = paced();
  assert.equal(p.send(10).length, START_UNACKED);
});

test("a queue building stops the frames until an acknowledgement", () => {
  const p = paced();
  p.send(1);
  p.at(20);
  p.pacer.acked(1000);
  assert.equal(p.pacer.rtt(), 20);
  p.send(3);
  assert.equal(p.pacer.unacked, 3);
  // The oldest has waited the round trip and QUEUE_MS: none more.
  p.at(20 + 20 + QUEUE_MS);
  assert.equal(p.pacer.may(), true);
  p.at(20 + 20 + QUEUE_MS + 1);
  assert.equal(p.pacer.may(), false);
  p.pacer.acked(4000);
  assert.equal(p.pacer.may(), true);
  // A far link's round trip varies more: half of it, where that is more than QUEUE_MS.
  assert.equal(queueMs(20), QUEUE_MS);
  assert.equal(queueMs(150), 75);
});

/// A source at 60 frames a second over a link that carries `capacity()` bits a second (each frame decoded once it is
/// through, after `base` ms more), each frame as large as the rate the pacer asks makes it: the pacer's rate each ms.
function bottleneck(capacity: (t: number) => number, ms: number, base = 10, start: number | null = null, own = ownRate(1920, 1080)) {
  let now = 0;
  const pacer = new Pacer(() => now, start);
  pacer.ceiling(own);
  const due: { at: number; ts: number }[] = [];
  let free = 0;
  let ts = 0;
  const rates: number[] = [];
  for (let t = 0; t < ms; t++) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) pacer.acked(due.shift()!.ts);
    if (t % 16 === 0 && pacer.may()) {
      const bytes = Math.round(pacer.rate()! / 60 / 8);
      ts += 1000;
      pacer.sent(ts, bytes);
      free = Math.max(free, t) + (bytes * 8 * 1000) / capacity(t);
      due.push({ at: Math.ceil(free) + base, ts });
    }
    rates.push(pacer.rate()!);
  }
  return rates;
}

test("the bit rate: down towards what went through once frames stay held back, never below half at a time; up again a step at a time", () => {
  const own = ownRate(1920, 1080);
  // A link that carries 5 Mbit/s for 4 s, then 100.
  const rates = bottleneck((t) => (t < 4000 ? 5_000_000 : 100_000_000), 20_000);
  const low = Math.min(...rates.slice(0, 4000));
  assert.ok(low < 5_000_000, `lowered to under the link: ${low}`);
  assert.ok(low >= 5_000_000 * DOWN * 0.5, `about what went through: ${low}`);
  // Each cut at most halves it.
  for (let t = 1; t < rates.length; t++) assert.ok(rates[t]! >= rates[t - 1]! * CUT - 1, `at ${t}: ${rates[t - 1]} to ${rates[t]}`);
  // The link wide again: up by UP each UP_EVERY_MS once nothing queued for UP_AFTER_MS, to its own.
  assert.equal(rates.at(-1), own);
  const rising = rates.slice(4000).findIndex((r, i, a) => i > 0 && r > a[i - 1]!);
  assert.ok(rising >= 0 && rising <= UP_AFTER_MS + 2 * UP_EVERY_MS, `up again after ${rising} ms`);
});

// Ported from still.fail#4384 (station/test/screen-pace.test.ts).
test("lowered, the rate climbs back by UP, and by UP_FAST once nothing was held back for UP_FAST_AFTER_MS", () => {
  const top = rateCeiling(1920, 1080);
  // A link that carries 5 Mbit/s for 4 s, then 100.
  const rates = bottleneck((t) => (t < 4000 ? 5_000_000 : 100_000_000), 20_000, 10, null, top);
  const steps = rates.slice(4000).flatMap((r, i, a) => (i > 0 && r > a[i - 1]! ? [{ at: 4000 + i, by: r / a[i - 1]! }] : []));
  const by = (k: number) => (s: { by: number }) => Math.abs(s.by - k) < 1e-9;
  assert.ok(by(UP)(steps[0]!), `first by UP: ${JSON.stringify(steps)}`);
  const fast = steps.findIndex(by(UP_FAST));
  assert.ok(fast > 0 && steps.slice(fast, -1).every(by(UP_FAST)), `then by UP_FAST: ${JSON.stringify(steps)}`);
  // From about the link's 5 Mbit/s to 33 in under 5 s (by UP alone: 15 steps, 7.5 s).
  assert.ok(steps.at(-1)!.at - steps[0]!.at < 5000, `at the top soon: ${JSON.stringify(steps)}`);
  assert.equal(rates.at(-1), top);
});

// Ported from still.fail's station/test/screen-pace.test.ts (afk/main 0a70d5e9d0), with Cue's MAX_RATE check.
test("the most a view is asked at: × 16 a pixel (自动, 高清, 原画), 流畅 × 6, at most MAX_RATE, never less than the source's own", () => {
  assert.equal(rateCeiling(1920, 1080), 1920 * 1080 * 16);
  assert.equal(rateCeiling(1920, 1080, "hd"), 1920 * 1080 * 16);
  assert.equal(rateCeiling(1920, 1080, "original"), 1920 * 1080 * 16);
  assert.equal(rateCeiling(1920, 1080, "smooth"), 1920 * 1080 * 6);
  assert.equal(rateCeiling(3840, 2160), MAX_RATE);
  assert.equal(rateCeiling(3840, 2160, "smooth"), 3840 * 2160 * 6);
  assert.equal(rateCeiling(3840, 2160, "original"), MAX_RATE);
  assert.equal(MAX_RATE, 60_000_000);
  // A small picture's own (at least 1 Mbit/s) is never lowered.
  assert.equal(rateCeiling(200, 100), 1_000_000);
  assert.equal(rateCeiling(200, 100, "original"), 1_000_000);
  assert.equal(rateCeiling(200, 100, "smooth"), 1_000_000);
  assert.equal(ownRate(200, 100), 1_000_000);
});

test("one view's ceiling: its picture's, a preview's its own, and no more than SALIX_RATE through Salix", () => {
  assert.equal(viewCeiling(1920, 1080), rateCeiling(1920, 1080));
  assert.equal(viewCeiling(1920, 1080, { via: "direct" }), 1920 * 1080 * 16);
  assert.equal(viewCeiling(1920, 1080, { via: "relay" }), 1920 * 1080 * 16);
  assert.equal(viewCeiling(1920, 1080, { via: "salix" }), SALIX_RATE);
  assert.equal(viewCeiling(640, 360, { via: "salix" }), rateCeiling(640, 360));
  assert.equal(viewCeiling(640, 1386, { peek: true }), ownRate(640, 1386));
  // Each 画质 at its own ceiling on a direct way; through Salix none goes past SALIX_RATE (what the relay carries, not a
  // choice of picture), and 流畅's lower one stays lower.
  assert.equal(viewCeiling(1920, 1080, { via: "direct", quality: "smooth" }), 1920 * 1080 * 6);
  assert.equal(viewCeiling(1920, 1080, { via: "direct", quality: "original" }), 1920 * 1080 * 16);
  for (const quality of ["smooth", "hd", "original"] as const) assert.equal(viewCeiling(1920, 1080, { via: "salix", quality }), SALIX_RATE, quality);
  assert.equal(viewCeiling(1280, 720, { via: "salix", quality: "smooth" }), 1280 * 720 * 6);
  // A preview's is its source's own whatever it said.
  assert.equal(viewCeiling(640, 1386, { peek: true, quality: "original" }), ownRate(640, 1386));
  // Two views at it leave Salix's 4 MiB/s a connection room for QUIC's own bytes and for input.
  assert.ok(2 * SALIX_RATE < 4 * 1024 * 1024 * 8);
  // One view at it takes no more than half of a Salix node's budget (2 MiB/s for all its relayed connections).
  assert.ok(2 * SALIX_RATE <= 2 * 1024 * 1024 * 8);
});

test("the source is asked again past a 5% step, and at once when its ceiling goes below what it was asked", () => {
  // A 800×640 view at its own ceiling over a direct way, its connection then going through Salix.
  const direct = viewCeiling(800, 640, { via: "direct" });
  assert.equal(direct, 8_192_000);
  const pacer = new Pacer(() => 0, direct);
  pacer.ceiling(direct);
  const salix = viewCeiling(800, 640, { via: "salix" });
  pacer.ceiling(salix);
  // 2.3% lower: under a step, and still asked, as SALIX_RATE is a bound.
  assert.equal(rateToAsk(direct, pacer.rate(), salix), SALIX_RATE);
  // A step's change the same way either way; less than a step, nothing.
  const top = rateCeiling(1920, 1080);
  assert.equal(rateToAsk(10_000_000, 10_600_000, top), 10_600_000);
  assert.equal(rateToAsk(10_000_000, 9_800_000, top), null);
  assert.equal(rateToAsk(null, 1_500_000, null), 1_500_000);
  assert.equal(rateToAsk(1_500_000, null, null), null);
});

test("a late acknowledgement alone lowers nothing: a still or idle screen's frames, held back by none", () => {
  let now = 0;
  const pacer = new Pacer(() => now);
  const own = ownRate(1920, 1080);
  pacer.ceiling(own);
  let ts = 1000;
  pacer.sent(ts, 10_000);
  now = 20;
  pacer.acked(ts);
  // A frame now and then (a sharper picture of a still screen, a cursor's blink), each large and a while on the way.
  for (let i = 0; i < 20; i++) {
    now += 1000;
    assert.equal(pacer.may(), true);
    pacer.sent((ts += 1000), 300_000);
    now += 400;
    pacer.acked(ts);
  }
  assert.equal(pacer.rate(), own);
  // A frame held a round trip (a packet lost and sent again) while the next waits: not slower either. (Its own bytes
  // at the rate asked, 13 ms, and the link's jitter are not counted as held.) One frame on the way alone holds none.
  pacer.sent((ts += 1000), 10_000);
  pacer.sent((ts += 1000), 10_000);
  now += pacer.rtt()! + queueMs(pacer.rtt()!) + pacer.jitter() + 20;
  assert.equal(pacer.may(), false);
  pacer.acked(ts);
  assert.equal(pacer.may(), true);
  assert.equal(pacer.rate(), own);
});

test("a view starting at START_RATE goes up by START_UP a step until a queue first builds, then by UP", () => {
  let now = 0;
  const pacer = new Pacer(() => now, START_RATE);
  pacer.ceiling(ownRate(1920, 1080));
  assert.equal(pacer.rate(), START_RATE);
  let ts = 0;
  const frame = (trip: number) => {
    ts += 1000;
    pacer.sent(ts, 10_000);
    now += trip;
    pacer.acked(ts);
  };
  frame(20);
  assert.equal(pacer.rate(), START_RATE * START_UP, "the first round trip: up at once");
  now += UP_EVERY_MS;
  frame(20);
  assert.equal(pacer.rate(), Math.min(ownRate(1920, 1080), START_RATE * START_UP * START_UP));
  // Smaller than the own: as the picture's size has it.
  const small = new Pacer(() => now, START_RATE);
  small.ceiling(ownRate(640, 360));
  assert.equal(small.rate(), 1_000_000);
});

test("a picture's size sets the most it is asked; none before it is known", () => {
  const p = paced();
  assert.equal(p.pacer.rate(), null);
  p.pacer.ceiling(ownRate(1280, 720));
  assert.equal(p.pacer.rate(), Math.max(1_000_000, 1280 * 720 * 3));
  p.pacer.ceiling(ownRate(640, 360));
  assert.equal(p.pacer.rate(), 1_000_000);
});

test("frame latency: capture to drawn (the acknowledgement less half the round trip) and capture to sent, as medians, once a second", () => {
  let now = 10_000;
  const latency = new FrameLatency(() => now);
  // Captured at 9 990 ms, sent at 10 000 ms, acknowledged at 10 060 with a 40 ms round trip: drawn at about 10 040.
  latency.sent(9_990_000);
  now = 10_060;
  latency.acked(9_990_000, 40);
  assert.deepEqual(latency.take(), { frame: 50, before: 10 });
  // Said once a second at most.
  latency.sent(10_050_000);
  now = 10_100;
  latency.acked(10_050_000, 40);
  assert.equal(latency.take(), null);
  now = 11_100;
  assert.deepEqual(latency.take(), { frame: 50, before: 10 }, "the median of the two");
  // A timestamp not on this clock (10 s off) is not counted.
  latency.sent(1_000);
  now = 12_200;
  latency.acked(1_000, 40);
  assert.equal(latency.take(), null);
});

test("frame latency: a capture time a little ahead of the clock (ScreenCaptureKit's, a few ms) counts as made now; one far ahead does not", () => {
  let now = 20_000;
  const latency = new FrameLatency(() => now);
  // Captured 13 ms "after" now, sent now, acknowledged 60 ms later over a 40 ms round trip: 40 ms to drawn, 0 before.
  latency.sent(20_013_000);
  now = 20_060;
  latency.acked(20_013_000, 40);
  assert.deepEqual(latency.take(), { frame: 40, before: 0 });
  // AHEAD_MS and more ahead: a clock of its own, not counted.
  now = 21_100;
  latency.sent((now + AHEAD_MS + 1) * 1000);
  now = 21_160;
  latency.acked((21_100 + AHEAD_MS + 1) * 1000, 40);
  now = 23_200;
  assert.equal(latency.take(), null);
});

/// Frames offered every `every` ms (each acknowledged `trip` ms after it went) for `ms`, to a pacer asked `fps`: when
/// each went.
function capped(fps: number | undefined, every: number, ms: number, trip = 5): number[] {
  let now = 0;
  const pacer = new Pacer(() => now, null, fps);
  const due: { at: number; ts: number }[] = [];
  const went: number[] = [];
  let ts = 0;
  for (let t = 0; t < ms; t += 0.25) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) pacer.acked(due.shift()!.ts);
    if (t % every < 0.25 && pacer.may() && pacer.wait() === 0) {
      pacer.sent((ts += 1000), 10_000);
      went.push(t);
      due.push({ at: t + trip, ts });
    }
  }
  return went;
}

test("a 帧率 asked: no second carries more frames than it (and one), and a source at that rate keeps it", () => {
  for (const fps of [120, 90, 60, 30, 15]) {
    // A source faster than any asked (a 240 Hz display's).
    const went = capped(fps, 1000 / 240, 5000);
    for (let i = 0; i < went.length; i++) {
      const within = went.slice(i).filter((t) => t < went[i]! + 1000).length;
      assert.ok(within <= fps + 1, `${fps}: ${within} in the second from ${went[i]}`);
    }
    assert.ok(went.length >= fps * 5 * 0.95, `${fps}: ${went.length} in 5 s`);
  }
  // A source at the rate asked (still.fail Helper's capture asked it, its frames a little early or late): all of them.
  assert.ok(capped(60, 1000 / 60, 2000).length >= 119);
  // None asked (自动): as many as come.
  assert.equal(new Pacer(() => 0).wait(), 0);
  assert.ok(capped(undefined, 1000 / 240, 1000).length >= 239);
});

test("the station's loop standing still is left out of round trips and waits: frames held by it lower nothing", () => {
  // Frames each 16 ms as large as the rate makes them over a near link (acknowledged 30 ms after they went), the station's loop standing still `stand` ms
  // every `every` ms (nothing read meanwhile; then the pump asks before the acknowledgements are read): told, the rate
  // stays its own; not told, a stand longer than the queue's window is taken for the link. (A shorter one is not: some
  // acknowledgements in the window came in time.)
  const run = (told: boolean, stand: number, every: number) => {
    let now = 0;
    let stood = 0;
    const pacer = new Pacer(() => now, null, undefined, told ? () => stood : () => 0);
    pacer.ceiling(ownRate(1920, 1080));
    const due: { at: number; ts: number }[] = [];
    let ts = 0;
    for (let t = 0; t < 20_000; t++) {
      now = t;
      if (t % every >= every - stand) continue;
      if (t % every === 0 && t > 0) stood += stand;
      if (t % 16 === 0 && pacer.may()) {
        ts += 1000;
        pacer.sent(ts, Math.round(pacer.rate()! / 60 / 8));
        due.push({ at: t + 30, ts });
      }
      while (due.length > 0 && due[0]!.at <= t) pacer.acked(due.shift()!.ts);
    }
    return pacer.rate()!;
  };
  assert.equal(run(true, 128, 640), ownRate(1920, 1080));
  assert.equal(run(false, 128, 640), ownRate(1920, 1080));
  assert.equal(run(true, 700, 1400), ownRate(1920, 1080));
  assert.ok(run(false, 700, 1400) < ownRate(1920, 1080) / 2, `not told, taken for the link: ${run(false, 700, 1400)}`);
});

test("LoopStall counts how long the loop stood still past its tick, the stand it is in now too", () => {
  let now = 0;
  const stall = new LoopStall(() => now);
  const used = stall.use();
  assert.equal(used.stalled(), 0);
  now = 100;
  assert.equal(used.stalled(), 90);
  used.done();
});

test("a still picture goes again only once it has been still and the pace asks past what it was encoded at", () => {
  const sharpen = new Sharpener();
  sharpen.sent(1000, 1_500_000);
  assert.equal(sharpen.left(1100), STILL_MS - 100);
  assert.equal(sharpen.due(1100, 3_000_000), false, "not still yet");
  assert.equal(sharpen.due(1000 + STILL_MS, 1_500_000 * SHARPER), false, "no sharper");
  assert.equal(sharpen.due(1000 + STILL_MS, 2_250_000), true);
  sharpen.sent(2000, null);
  assert.equal(sharpen.due(9000, 9_000_000), false, "a source with no rate of its own");
});

// Ported from still.fail's station/test/screen-pace.test.ts (afk/main 0a70d5e9d0), with Cue's still screen case.
test("the picture made smaller while the link carries a quarter of its own rate and the source uses it; back once the smaller one's own goes through", () => {
  let now = 0;
  const sizer = new Sizer(() => now, { maxWidth: 1920, maxHeight: 1080 });
  const big = { width: 1920, height: 1080 }, small = { width: 1280, height: 720 };
  const low = ownRate(1920, 1080) * DOWNSIZE_SHARE - 1;
  // Low, but the screen changes little (a tenth of it used): not made smaller.
  for (; now <= DOWNSIZE_MS * 2; now += 100) assert.equal(sizer.step(low, low / 10, big), null);
  // Low and used: smaller once it stays so for DOWNSIZE_MS.
  let asked = null;
  for (const start = now; now <= start + DOWNSIZE_MS && asked === null; now += 100) asked = sizer.step(low, low, big);
  assert.deepEqual(asked, LOW_BOUNDS);
  assert.equal(sizer.low, true);
  // The small one's own goes through for UPSIZE_MS: its own size again.
  asked = null;
  for (const start = now; now <= start + UPSIZE_MS + 100 && asked === null; now += 100) asked = sizer.step(ownRate(1280, 720), ownRate(1280, 720), small);
  assert.deepEqual(asked, { maxWidth: 1920, maxHeight: 1080 });
  // 原画 is never made smaller.
  const whole = new Sizer(() => now, { maxWidth: 7680, maxHeight: 4320 }, "original");
  for (let i = 0; i < 100; i++, now += 100) assert.equal(whole.step(low, low, big), null);
  assert.equal(whole.low, false);
  // 流畅 and 高清 are, as 自动 is.
  for (const quality of ["smooth", "hd"] as const) {
    const sized = new Sizer(() => now, { maxWidth: 1920, maxHeight: 1080 }, quality);
    let got = null;
    for (const start = now; now <= start + DOWNSIZE_MS + 100 && got === null; now += 100) got = sized.step(low, low, big);
    assert.deepEqual(got, LOW_BOUNDS, quality);
  }
  // A still screen's few frames, a second and more apart, each a key frame that fills what went through: not made
  // smaller however long (nothing went between them to say the link is slow).
  const still = new Sizer(() => now, { maxWidth: 1920, maxHeight: 1080 });
  for (const start = now; now <= start + DOWNSIZE_MS * 10; now += 1500) assert.equal(still.step(low, low, big), null);
  // A view asked no larger than the small bounds is never made smaller.
  const phone = new Sizer(() => now, { maxWidth: 1280, maxHeight: 720 });
  for (let i = 0; i < 100; i++, now += 100) assert.equal(phone.step(MIN_RATE, MIN_RATE, small), null);
});

/// A deterministic random source (mulberry32): the same link each run.
function random(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Wi‑Fi's delay on top of the quickest round trip, as measured between two Macs on one LAN (ping 9–71 ms, mean 21, sd
/// 17): most acknowledgements a few ms late, some 20–60 ms, and every 2–4 s a moment of 100–250 ms where all are 30–60
/// ms late (the radio busy).
function wifi(seed: number): (t: number) => number {
  const r = random(seed);
  let busyFrom = 2000;
  let busyTo = 2150;
  return (t) => {
    if (t >= busyTo) {
      busyFrom = t + 2000 + r() * 2000;
      busyTo = busyFrom + 100 + r() * 150;
    }
    if (t >= busyFrom && t < busyTo) return 30 + r() * 30;
    const u = r();
    return u < 0.75 ? r() * 12 : u < 0.97 ? 12 + r() * 40 : 50 + r() * 12;
  };
}

/// A view over a link: a source at 60 frames a second, each frame as large as the rate the pacer asks makes it and a
/// key frame (64 KB or ten frames' worth, the larger) every 10 s; the link carries `capacity(t)` bits a second, and a
/// frame is acknowledged `base` ms and `jitter(t)` more after its last byte is through, in order. The pacer starts at
/// START_RATE, as a view does, under `ceiling`; the Sizer of a 1920×1080 view runs beside it.
function link(o: { capacity: (t: number) => number; base: number; jitter?: (t: number) => number; ms: number; ceiling?: number }) {
  let now = 0;
  const pacer = new Pacer(() => now, START_RATE);
  pacer.ceiling(o.ceiling ?? rateCeiling(1920, 1080));
  const sizer = new Sizer(() => now, { maxWidth: 1920, maxHeight: 1080 });
  const size = { width: 1920, height: 1080 };
  const due: { at: number; ts: number; went: number }[] = [];
  let free = 0;
  let last = 0;
  let ts = 0;
  const rates: number[] = [];
  const delays: number[] = [];
  let low = 0;
  let frames = 0;
  for (let t = 0; t < o.ms; t++) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) {
      const f = due.shift()!;
      pacer.acked(f.ts);
      delays.push(t - f.went);
      const bounds = sizer.step(pacer.rate()!, pacer.through(), size);
      if (bounds) {
        size.width = Math.min(1920, bounds.maxWidth);
        size.height = Math.min(1080, bounds.maxHeight);
      }
    }
    if (sizer.low) low++;
    if (t % 16 === 0 && pacer.may()) {
      const average = pacer.rate()! / 60 / 8;
      const bytes = Math.round(t % 10_000 < 16 ? Math.max(64_000, average * 10) : average);
      ts += 1000;
      pacer.sent(ts, bytes);
      frames++;
      free = Math.max(free, t) + (bytes * 8 * 1000) / o.capacity(t);
      last = Math.max(last, Math.ceil(free + o.base + (o.jitter?.(t) ?? 0)));
      due.push({ at: last, ts, went: t });
    }
    rates.push(pacer.rate()!);
  }
  const mean = (from: number, to = o.ms) => rates.slice(from, to).reduce((a, b) => a + b, 0) / (to - from);
  return { rates, mean, delays, low, frames };
}

test("a fast LAN over Wi‑Fi (round trip 9–70 ms): its jitter is not a queue, and the view climbs to its ceiling at its full size", () => {
  const top = rateCeiling(1920, 1080);
  for (const seed of [1, 2, 3]) {
    const run = link({ capacity: () => 240_000_000, base: 9, jitter: wifi(seed), ms: 30_000 });
    assert.ok(run.mean(10_000) >= top * 0.8, `seed ${seed}: ${Math.round(run.mean(10_000))} of ${top}`);
    assert.ok(Math.min(...run.rates.slice(1000)) >= START_RATE, `seed ${seed}: down to ${Math.min(...run.rates.slice(1000))}`);
    assert.equal(run.low, 0, `seed ${seed}: made smaller for ${run.low} ms`);
    assert.ok(run.frames >= (30_000 / 16) * 0.95, `seed ${seed}: ${run.frames} frames`);
  }
});

test("a link that carries less than the frames backs off promptly to what it carries, Wi‑Fi's jitter or not", () => {
  for (const jitter of [undefined, wifi(4)]) {
    const run = link({ capacity: () => 2_000_000, base: 10, jitter, ms: 20_000 });
    const at = run.rates.findIndex((r) => r <= 2_000_000);
    assert.ok(at >= 0 && at < 3000, `under the link after ${at} ms`);
    assert.ok(run.mean(5000) <= 2_200_000 && run.mean(5000) >= 2_000_000 * 0.5, `settles about the link: ${Math.round(run.mean(5000))}`);
    // No queue stands: frames are on the way about a round trip, a key frame's own bytes aside.
    const sorted = run.delays.slice(run.delays.length / 4).sort((a, b) => a - b);
    assert.ok(sorted[Math.floor(sorted.length / 2)]! < 150, `median on the way: ${sorted[Math.floor(sorted.length / 2)]}`);
  }
});

test("a far, steady link (a relay's 245 ms round trip) settles near what it carries, and at SALIX_RATE where it carries more", () => {
  const narrow = link({ capacity: () => 1_000_000, base: 245, jitter: (t) => (t % 7) * 4, ms: 30_000, ceiling: SALIX_RATE });
  // About the link, a little over it while it probes (the frames it holds back keep what goes within the link).
  assert.ok(narrow.mean(10_000) >= 500_000 && narrow.mean(10_000) <= 1_300_000, `narrow: ${Math.round(narrow.mean(10_000))}`);
  const sorted = narrow.delays.slice(narrow.delays.length / 3).sort((a, b) => a - b);
  assert.ok(sorted[Math.floor(sorted.length / 2)]! <= 245 + queueMs(245), `median on the way: ${sorted[Math.floor(sorted.length / 2)]}`);
  const wide = link({ capacity: () => 33_500_000, base: 245, jitter: (t) => (t % 7) * 4, ms: 30_000, ceiling: SALIX_RATE });
  assert.ok(wide.mean(15_000) >= SALIX_RATE * 0.7, `wide: ${Math.round(wide.mean(15_000))}`);
  assert.ok(Math.min(...wide.rates.slice(1000)) >= START_RATE, `wide: down to ${Math.min(...wide.rates.slice(1000))}`);
});

test("after a moment of congestion the rate is lowered, and climbs back to the ceiling once the link is wide again", () => {
  const top = rateCeiling(1920, 1080);
  // 240 Mbit/s over Wi‑Fi, but 4 Mbit/s from 10 s to 13 s (another transfer, a weak signal).
  const run = link({ capacity: (t) => (t >= 10_000 && t < 13_000 ? 4_000_000 : 240_000_000), base: 9, jitter: wifi(5), ms: 30_000 });
  assert.ok(Math.min(...run.rates.slice(10_000, 13_500)) <= 4_000_000, `lowered: ${Math.min(...run.rates.slice(10_000, 13_500))}`);
  const back = run.rates.findIndex((r, t) => t > 13_000 && r >= top * 0.9);
  assert.ok(back > 0 && back < 13_000 + 10_000, `back at ${back}`);
});

/// A whole view, as mesh/screens.ts runs one, on a clock the test moves (1 ms a step):
/// - the pump: a frame goes once the source has one and the pump asked for it; after it, the next is asked for while the
///   pacer lets one go, else on the next acknowledgement that lets one go (`#pump`, `#wake`);
/// - the source (the Mac helper): a new picture each 16 ms while `moving(t)`, one at each of `changes` while still; a
///   frame as large as the rate asked makes it (while still, `stillBytes` at most), a key frame (64 KB or ten frames, the
///   larger; STILL_BYTES while still) after a new size and each `keyEvery` ms, and the Sharpener's key frame of a still
///   picture STILL_BYTES; a new size takes RESIZE_MS before its first frame;
/// - the link: `capacity(t)` bits a second, `base` ms of round trip (half each way) and `jitter(t)` more on the way out;
///   where `quiet`, a frame of 50 KB or more after a second of less than 1 Mbit/s finds it carrying `quiet.rate()` for
///   `quiet.ms()` (round 3's still screen: each key frame 1–5 s on the way);
/// - the client: a decoder that keeps the newest frame until the next comes where `hold` (an H.265 decoder that keeps
///   one: it is acknowledged then), and one made anew for a new size that takes `init` ms;
/// - the Sizer and the bit rate's ceiling, as `#asked` and `#setCeiling` run them.
const STILL_BYTES = 150_000;
const RESIZE_MS = 1000;
function view(o: { capacity: (t: number) => number; base: number; jitter?: (t: number) => number; back?: (t: number) => number; ms: number; moving: (t: number) => boolean; changes?: number[]; hold?: boolean; init?: number; via?: string; quality?: Quality; start?: { width: number; height: number }; stillBytes?: number; keyEvery?: number; quiet?: { rate: () => number; ms: () => number } }) {
  let now = 0;
  const pacer = new Pacer(() => now, START_RATE);
  const sizer = new Sizer(() => now, { maxWidth: 1920, maxHeight: 1080 }, o.quality);
  const sharpen = new Sharpener();
  let size = o.start ?? { width: 1920, height: 1080 };
  const ceiling = () => viewCeiling(size.width, size.height, { via: o.via ?? null, ...(o.quality ? { quality: o.quality } : {}) });
  pacer.ceiling(ceiling());
  const changes = new Set(o.changes ?? []);
  // The source: a new picture, a key frame owed, no frame before `ready` (a new size's encoder), the size it makes.
  let fresh = false;
  let key = true;
  let still = false;
  let ready = 0;
  let next: { width: number; height: number } | null = null;
  // The pump: asking for a frame, or held until an acknowledgement lets one go.
  let asking = true;
  // The link and the client.
  let free = 0;
  let arrive = 0;
  let back = 0;
  let decoderFrom = 0;
  let ts = 0;
  let lastKey = 0;
  let slowTo = 0;
  let slowRate = 0;
  const recent: { at: number; bytes: number }[] = [];
  let inside: { ts: number }[] = [];
  const acks: { at: number; ts: number }[] = [];
  const arrivals: { at: number; ts: number; sent: number; config: boolean }[] = [];
  const sent: number[] = [];
  const rates: number[] = [];
  const sizes: { at: number; width: number; height: number }[] = [];
  let low = 0;
  const asked = () => {
    const bounds = sizer.step(pacer.rate()!, pacer.through(), size);
    if (bounds) {
      next = { width: Math.min(1920, bounds.maxWidth), height: Math.min(1080, bounds.maxHeight) };
      ready = now + RESIZE_MS;
      fresh = true;
    }
  };
  for (let t = 0; t < o.ms; t++) {
    now = t;
    // The client: frames through the link, decoded (the newest kept where `hold`), acknowledged.
    while (arrivals.length > 0 && arrivals[0]!.at <= t) {
      const f = arrivals.shift()!;
      if (f.config) {
        for (const g of inside) acks.push({ at: (back = Math.max(back, t + o.base / 2 + (o.back?.(t) ?? 0))), ts: g.ts });
        inside = [];
        decoderFrom = t + (o.init ?? 0);
      }
      inside.push({ ts: f.ts });
      const out = o.hold ? inside.length - 1 : inside.length;
      for (const g of inside.splice(0, out)) acks.push({ at: (back = Math.max(back, Math.max(t, decoderFrom) + o.base / 2 + (o.back?.(t) ?? 0))), ts: g.ts });
    }
    acks.sort((a, b) => a.at - b.at);
    while (acks.length > 0 && acks[0]!.at <= t) {
      pacer.acked(acks.shift()!.ts);
      asked();
      if (!asking && pacer.may()) asking = true;
    }
    if ((o.moving(t) && t % 16 === 0) || changes.has(t)) (fresh = true), (still = false);
    if (sharpen.due(t, pacer.rate())) (key = true), (fresh = true), (still = true);
    if (asking && fresh && t >= ready) {
      let config = false;
      if (next) {
        size = next;
        next = null;
        sizes.push({ at: t, ...size });
        pacer.ceiling(ceiling());
        pacer.resized();
        key = true;
        config = true;
      }
      if (o.keyEvery !== undefined && t - lastKey >= o.keyEvery) key = true;
      if (key) lastKey = t;
      const average = pacer.rate()! / 60 / 8;
      const bytes = Math.round(key ? (still || !o.moving(t) ? STILL_BYTES : Math.max(64_000, average * 10)) : o.moving(t) ? average : Math.min(average, o.stillBytes ?? 3_000));
      fresh = key = still = false;
      ts += 1000;
      pacer.sent(ts, bytes);
      sharpen.sent(t, pacer.rate());
      sent.push(t);
      while (recent.length > 0 && recent[0]!.at < t - 1000) recent.shift();
      if (o.quiet && t >= 1000 && !o.moving(t) && bytes >= 50_000 && recent.reduce((a, f) => a + f.bytes, 0) * 8 < 1_000_000) {
        slowTo = t + o.quiet.ms();
        slowRate = o.quiet.rate();
      }
      recent.push({ at: t, bytes });
      free = Math.max(free, t) + (bytes * 8 * 1000) / (t < slowTo ? slowRate : o.capacity(t));
      arrive = Math.max(arrive, Math.ceil(free + o.base / 2 + (o.jitter?.(t) ?? 0)));
      arrivals.push({ at: arrive, ts, sent: t, config });
      asking = pacer.may();
      if (!asking) asked();
    }
    if (sizer.low) low++;
    rates.push(pacer.rate()!);
  }
  const mean = (from: number, to = o.ms) => rates.slice(from, to).reduce((a, b) => a + b, 0) / (to - from);
  /// Gaps over `over` ms between frames sent within [from, to).
  const gaps = (from: number, to: number, over: number) => sent.filter((s, i) => i > 0 && s >= from && s < to && s - sent[i - 1]! > over).length;
  const frames = (from: number, to: number) => sent.filter((s) => s >= from && s < to).length;
  return { rates, mean, low, sizes, gaps, frames };
}

test("a still screen whose large frames the link takes seconds for keeps its rate and size; motion on a narrow link after it still backs off", () => {
  const top = rateCeiling(1920, 1080);
  for (const seed of [1, 2, 3]) {
    const r = random(seed + 50);
    // Moving for 15 s, then a still page for 60 s: a 1.3 KB frame each 33 ms (round 3: 180–330 kbit/s at 31 a second)
    // and a key frame each 10 s (the helper's before; one the client or the Sharpener asks still comes). After a quiet
    // second the link carries a large frame at 0.33–1.3 Mbit/s for 4–8 s: 127–195 KB key frames took 1.0–5.0 s on a
    // 240 Mbit/s Wi‑Fi LAN (2026-11-08). From 75 s, motion on a link that carries 2 Mbit/s.
    const changes: number[] = [];
    for (let t = 15_000 + 33; t < 75_000; t += 33) changes.push(t);
    const run = view({ capacity: (t) => (t < 75_000 ? 240_000_000 : 2_000_000), base: 9, jitter: wifi(seed), ms: 85_000, moving: (t) => t < 15_000 || t >= 75_000, changes, hold: true, stillBytes: 1_300, keyEvery: 10_000, quiet: { rate: () => 330_000 + r() * 1_000_000, ms: () => 4000 + r() * 4000 } });
    assert.ok(run.mean(10_000, 15_000) >= top * 0.9, `seed ${seed}: before it was still: ${Math.round(run.mean(10_000, 15_000))}`);
    // Still: the rate stays at the top, so a key frame's own bytes take 40 ms; the size stays.
    assert.ok(Math.min(...run.rates.slice(15_000, 75_000)) >= top * 0.9, `seed ${seed}: still, down to ${Math.min(...run.rates.slice(15_000, 75_000))}`);
    assert.equal(run.low, 0, `seed ${seed}: made smaller for ${run.low} ms (${JSON.stringify(run.sizes)})`);
    // Moving on a link narrower than the rate: down to about it within 3 s.
    const under = run.rates.findIndex((rate, t) => t >= 75_000 && rate <= 2_000_000);
    assert.ok(under > 0 && under - 75_000 <= 3000, `seed ${seed}: under the link ${under - 75_000} ms after motion`);
  }
});

test("a still screen is no slow link: its few frames, each kept by the decoder until the next, lower nothing, and motion after it goes at once at the full rate and size", () => {
  const top = rateCeiling(1920, 1080);
  for (const seed of [1, 2, 3]) {
    const r = random(seed);
    // Moving for 15 s, still for 30 s (a change each 0.5–3 s: a clock, a cursor's blink, a key typed), moving again.
    const changes: number[] = [];
    for (let t = 15_000 + 500; t < 45_000; t += 500 + Math.floor(r() * 2500)) changes.push(t);
    const run = view({ capacity: () => 240_000_000, base: 9, jitter: wifi(seed), ms: 60_000, moving: (t) => t < 15_000 || t >= 45_000, changes, hold: true });
    assert.ok(run.mean(10_000, 15_000) >= top * 0.9, `seed ${seed}: before it was still: ${Math.round(run.mean(10_000, 15_000))}`);
    assert.ok(Math.min(...run.rates.slice(15_000)) >= top * 0.5, `seed ${seed}: still, down to ${Math.min(...run.rates.slice(15_000))}`);
    assert.equal(run.low, 0, `seed ${seed}: made smaller for ${run.low} ms`);
    // Moving again: at the full rate within a second, and frames as many as come.
    assert.ok(Math.min(...run.rates.slice(46_000)) >= top * 0.8, `seed ${seed}: moving again at ${Math.min(...run.rates.slice(46_000))}`);
    assert.ok(run.frames(45_000, 60_000) >= (15_000 / 16) * 0.95, `seed ${seed}: ${run.frames(45_000, 60_000)} frames`);
  }
});

test("a picture back at its full size from 1280×720 goes up to its own ceiling, not the smaller one's: a decoder made anew for it is no queue", () => {
  const top = rateCeiling(1920, 1080);
  const small = rateCeiling(1280, 720);
  for (const seed of [1, 2, 3]) {
    // 1 Mbit/s for 15 s (made smaller), then 240 over Wi‑Fi; the client's decoder for a new size ready 300 ms after.
    const run = view({ capacity: (t) => (t < 15_000 ? 1_000_000 : 240_000_000), base: 9, jitter: wifi(seed), ms: 40_000, moving: () => true, hold: true, init: 300 });
    const up = run.sizes.find((s) => s.at > 15_000 && s.width === 1920);
    assert.ok(run.sizes.some((s) => s.width === 1280) && up, `seed ${seed}: sizes ${JSON.stringify(run.sizes)}`);
    // Within 3 s of the full size, at its own ceiling; never lowered under the smaller one's after it.
    const at = run.rates.findIndex((rate, t) => t > up.at && rate >= top * 0.95);
    assert.ok(at > 0 && at - up.at <= 3000, `seed ${seed}: at the top ${at - up.at} ms after ${up.at}`);
    assert.ok(Math.min(...run.rates.slice(up.at)) >= small * 0.9, `seed ${seed}: down to ${Math.min(...run.rates.slice(up.at))} after ${up.at}`);
    assert.ok(run.mean(30_000) >= top * 0.9, `seed ${seed}: ${Math.round(run.mean(30_000))}`);
  }
});

/// A relay's delay (Salix's WebSocket over TCP): what goes through it waits for the relay's next write, 0–120 ms.
function relay(seed: number): (t: number) => number {
  const r = random(seed);
  let at = 0;
  return (t) => {
    while (at <= t) at += 20 + r() * 100;
    return at - t;
  };
}

test("a relay of 200 ms round trip that carries 33 Mbit/s: the view goes near SALIX_RATE, at 60 frames a second with few long gaps", () => {
  for (const seed of [1, 2, 3]) {
    const run = view({ capacity: () => 33_500_000, base: 200, jitter: relay(seed), back: relay(seed + 100), ms: 40_000, moving: () => true, hold: true, via: "salix" });
    assert.ok(run.mean(15_000) >= SALIX_RATE * 0.8, `seed ${seed}: ${Math.round(run.mean(15_000))}`);
    assert.ok(run.frames(10_000, 40_000) >= (30_000 / 16) * 0.9, `seed ${seed}: ${run.frames(10_000, 40_000)} frames in 30 s`);
    assert.ok(run.gaps(10_000, 40_000, 100) <= 5, `seed ${seed}: ${run.gaps(10_000, 40_000, 100)} gaps over 100 ms in 30 s`);
    assert.equal(run.low, 0, `seed ${seed}: made smaller for ${run.low} ms`);
  }
});

test("each 画质 on a whole view: 流畅 goes up to its lower ceiling on a LAN; on a narrow link 原画 keeps its size where 自动 is made smaller", () => {
  // A LAN of 240 Mbit/s: 流畅 at its × 6, the others at × 16.
  for (const [quality, top] of [["smooth", rateCeiling(1920, 1080, "smooth")], ["hd", rateCeiling(1920, 1080)], [undefined, rateCeiling(1920, 1080)]] as const) {
    const run = view({ capacity: () => 240_000_000, base: 9, jitter: wifi(1), ms: 20_000, moving: () => true, hold: true, ...(quality ? { quality } : {}) });
    assert.ok(run.mean(10_000) >= top * 0.9 && Math.max(...run.rates) <= top, `${quality}: ${Math.round(run.mean(10_000))} of ${top}`);
  }
  // A link of 1 Mbit/s: 自动 goes to 1280×720; 原画 stays 1920×1080, its rate at what the link carries.
  const auto = view({ capacity: () => 1_000_000, base: 9, jitter: wifi(2), ms: 20_000, moving: () => true, hold: true });
  assert.ok(auto.sizes.some((s) => s.width === 1280), `自动: ${JSON.stringify(auto.sizes)}`);
  const whole = view({ capacity: () => 1_000_000, base: 9, jitter: wifi(2), ms: 20_000, moving: () => true, hold: true, quality: "original" });
  assert.deepEqual(whole.sizes, []);
  assert.equal(whole.low, 0);
  assert.ok(whole.mean(10_000) <= 1_500_000, `原画: ${Math.round(whole.mean(10_000))}`);
});

test("through Salix every 画质 stays under SALIX_RATE, and 原画 keeps its size there", () => {
  for (const quality of ["smooth", "hd", "original"] as const) {
    const run = view({ capacity: () => 33_500_000, base: 200, jitter: relay(1), back: relay(101), ms: 30_000, moving: () => true, hold: true, via: "salix", quality });
    assert.ok(Math.max(...run.rates) <= SALIX_RATE, `${quality}: up to ${Math.max(...run.rates)}`);
    if (quality === "original") assert.deepEqual(run.sizes, []);
  }
});

/// A desktop changing a little at 60 frames a second (4 KB frames whatever the rate asked, a 32 KB key frame first) over
/// a relay of 500 ms round trip that carries 400 kbit/s, the frames queuing in front of it, the view asked at its
/// ceiling (33 Mbit/s: its frames far smaller than that rate makes them, which a lower one makes no smaller): how late
/// each is acknowledged after it went, from 10 s on. `link`: the round trip QUIC says of the connection, told to the
/// pacer. A browser's view through a relay and a proxy, 2026-11-11: 200–600 kbit/s, 2–7 KB frames, 14 s late.
function relayed(link: number): number[] {
  let now = 0;
  const pacer = new Pacer(() => now, rateCeiling(1920, 1080));
  pacer.ceiling(rateCeiling(1920, 1080));
  pacer.link(link);
  const due: { at: number; ts: number; went: number }[] = [];
  const delays: number[] = [];
  let free = 0;
  let ts = 0;
  for (let t = 0; t < 40_000; t++) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) {
      const f = due.shift()!;
      pacer.acked(f.ts);
      if (t >= 10_000) delays.push(t - f.went);
    }
    if (t % 16 === 0 && pacer.may()) {
      const bytes = ts === 0 ? 32_000 : 4_000;
      ts += 1000;
      pacer.sent(ts, bytes);
      free = Math.max(free, t) + (bytes * 8 * 1000) / 400_000;
      due.push({ at: Math.ceil(free + 500), ts, went: t });
    }
  }
  return delays.sort((a, b) => a - b);
}

test("a link narrower than a desktop's small frames: they wait about a round trip and a half, not seconds; QUIC's round trip bounds the pace's", () => {
  // Before: 60 frames on the way, acknowledged 2.5 s late at the median and up to 4.8 s.
  const delays = relayed(500);
  const median = delays[Math.floor(delays.length / 2)]!;
  assert.ok(median <= 1500, `median ${median} ms`);
  assert.ok(delays.at(-1)! <= 2500, `at most ${delays.at(-1)} ms`);
  // Frames that took seconds (one key frame through a relay at its slowest, 6 s) are not the link's round trip once
  // QUIC says it: the oldest may wait that and a little, not seconds.
  let now = 0;
  const pacer = new Pacer(() => now, START_RATE);
  pacer.sent(1000, 32_000);
  now = 6000;
  pacer.acked(1000);
  assert.equal(pacer.rtt(), 6000);
  pacer.link(500);
  assert.equal(pacer.rtt(), 500 + LINK_SLACK_MS);
  pacer.link(null);
  assert.equal(pacer.rtt(), 6000);
});

test("backlogged: the oldest frame on the way waited past its round trip and the queue a view lets build, asked without moving the pace", () => {
  const p = paced();
  assert.equal(p.pacer.backlogged(), false);
  p.send(1);
  p.at(100);
  p.pacer.acked(1000);
  p.send(2);
  // Two on the way: not yet late.
  p.at(100 + 100 + queueMs(100));
  assert.equal(p.pacer.backlogged(), false);
  p.at(100 + 100 + queueMs(100) + 1);
  assert.equal(p.pacer.backlogged(), true);
  assert.equal(p.pacer.unacked, 2);
  // Through: none waits.
  p.pacer.acked(3000);
  assert.equal(p.pacer.backlogged(), false);
});
