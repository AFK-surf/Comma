// A view's frames' times (mesh/screen-timing.ts): off unless asked, and bounded however many frames come.
import assert from "node:assert/strict";
import { test } from "node:test";
import { FrameTiming, TIMING_COLUMNS, TIMING_LINE_FRAMES, TIMING_LINE_MS, TIMING_OPEN, screenTimingOn } from "../src/mesh/screen-timing.ts";

const at = (row: (number | null)[], name: (typeof TIMING_COLUMNS)[number]) => row[TIMING_COLUMNS.indexOf(name)];

function timing() {
  let now = 1_000;
  const lines: Record<string, any>[] = [];
  const t = new FrameTiming({ fields: { view: 1 }, now: () => now, link: () => ({ rttMs: 4, cwnd: 12_000 }), line: (fields) => lines.push(fields) });
  return { t, lines, pass: (ms: number) => (now += ms), now: () => now };
}

test("only COMMA_STATION_SCREEN_TIMING set, and not 0, turns it on", () => {
  assert.equal(screenTimingOn({}), false);
  assert.equal(screenTimingOn({ COMMA_STATION_SCREEN_TIMING: "" }), false);
  assert.equal(screenTimingOn({ COMMA_STATION_SCREEN_TIMING: "0" }), false);
  assert.equal(screenTimingOn({ COMMA_STATION_SCREEN_TIMING: "1" }), true);
});

test("a frame's times are said after its capture, the receipt apart from the acknowledgement, with the link's", () => {
  const { t, lines, pass, now } = timing();
  const ts = (now() - 5) * 1000;
  t.sent({ ts, key: true, bytes: 900, helper: { encodeStart: now() - 4, encodeDone: now() - 2, sent: now() - 1.9, got: now() - 1 } });
  t.writing(ts);
  pass(1);
  t.written(ts);
  pass(10);
  t.received(ts);
  // An H.265 decoder holds it until the next comes.
  pass(16);
  t.acked(ts, { held: 16.2, decodeOut: 16 });
  assert.equal(lines.length, 1);
  assert.deepEqual(lines[0]!.link, { rttMs: 4, cwnd: 12_000 });
  assert.deepEqual(lines[0]!.frames, [[ts, 1, 900, 1, 3, 3.1, 4, 5, 5, 6, 16, 32, 16.2, null, 16, null, null]]);
});

test("a line goes at most each second, of at most so many frames; what is past them is counted, not kept", () => {
  const { t, lines, pass } = timing();
  t.sent({ ts: 1, key: true, bytes: 1 });
  t.acked(1, null);
  assert.equal(lines.length, 1);
  for (let ts = 2; ts < 2 + TIMING_LINE_FRAMES + 30; ts++) {
    t.sent({ ts, key: false, bytes: 1 });
    t.acked(ts, null);
  }
  // Within the second: none said.
  assert.equal(lines.length, 1);
  pass(TIMING_LINE_MS);
  t.sent({ ts: 10_000, key: false, bytes: 1 });
  t.acked(10_000, null);
  assert.equal(lines.length, 2);
  assert.equal(lines[1]!.frames.length, TIMING_LINE_FRAMES);
  assert.equal(lines[1]!.dropped, 31);

  // Frames never acknowledged: the oldest dropped past TIMING_OPEN, the rest said as the view ends.
  for (let ts = 20_000; ts < 20_000 + TIMING_OPEN + 5; ts++) t.sent({ ts, key: false, bytes: 1 });
  t.end();
  const last = lines.at(-1)!;
  assert.equal(last.frames.length, TIMING_LINE_FRAMES);
  assert.equal(at(last.frames[0], "ts"), 20_005);
  assert.equal(at(last.frames[0], "acked"), null);
  assert.equal(last.dropped, 5 + TIMING_OPEN - TIMING_LINE_FRAMES);
});
