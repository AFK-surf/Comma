// What a device type's framebuffer mask says of its panel (screens/sim-mask.ts): paths as iPhone Duo's and iPhone 17 Pro's
// masks have them.
import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateSync } from "node:zlib";
import { panelOf } from "../src/screens/sim-mask.ts";

const pdf = (box: string, path: string, deflate = true) =>
  Buffer.concat([
    Buffer.from(`%PDF-1.3\n<< /Length 1 ${deflate ? "/Filter /FlateDecode " : ""}>>\nstream\n`),
    deflate ? deflateSync(path) : Buffer.from(path),
    Buffer.from(`\nendstream\n<< /Type /Pages /MediaBox [${box}] >>\n`),
  ]);

const K = 0.5523;
/// A shape whose corners are circles of these radii, top left and then round it.
const round = (w: number, h: number, [tl, tr, br, bl]: number[]) =>
  [
    `${tl} ${h} m ${w - tr!} ${h} l`,
    `${w - tr! * (1 - K)} ${h} ${w} ${h - tr! * (1 - K)} ${w} ${h - tr!} c ${w} ${br} l`,
    `${w} ${br! * (1 - K)} ${w - br! * (1 - K)} 0 ${w - br!} 0 c ${bl} 0 l`,
    `${bl! * (1 - K)} 0 0 ${bl! * (1 - K)} 0 ${bl} c 0 ${h - tl!} l`,
    `0 ${h - tl! * (1 - K)} ${tl! * (1 - K)} ${h} ${tl} ${h} c h f`,
  ].join(" ");

const near = (got: number[], want: number[]) => {
  assert.equal(got.length, want.length);
  got.forEach((g, i) => assert.ok(Math.abs(g - want[i]!) < 0.001, `${got} not ${want}`));
};

test("a panel's corners, each the circle its shape comes as near as, as shares of its width", () => {
  const cover = panelOf(pdf("0 0 466 678", `q Q q ${round(466, 678, [10.25, 75.6, 75.6, 10.25])}`))!;
  assert.deepEqual([cover.width, cover.height], [466, 678]);
  near(cover.corners, [0.022, 0.1622, 0.1622, 0.022]);
});

test("a clip round the page first is not the shape", () => {
  const clip = "q Q q -3940 3548 m 8304 3548 l 8304 -1476 l -3940 -1476 l h W* n ";
  near(panelOf(pdf("0 0 2064 2752", clip + round(2064, 2752, [77, 77, 77, 77])))!.corners, [0.0373, 0.0373, 0.0373, 0.0373]);
  const page = "q Q q 0 2622 m 1206 2622 l 1206 0 l 0 0 l h W* n ";
  near(panelOf(pdf("0 0 1206 2622", page + round(1206, 2622, [254, 254, 254, 254])))!.corners, [0.2106, 0.2106, 0.2106, 0.2106]);
});

test("Apple's curves: long along the edges, the corner what the shape comes near", () => {
  // iPhone 17 Pro's top right, as its mask has it: its curve starts 254 along the top, and its screen's radius is 186
  const corner =
    "952.014 2622 m 968.0447 2622 984.0706 2621.952 1000.1 2621.359 c 1018.459 2620.679 1036.611 2619.286 1054.731 2615.91 c " +
    "1091.305 2609.092 1124.57 2594.296 1151.434 2567.432 c 1178.301 2540.566 1193.097 2507.296 1199.912 2470.718 c ";
  const tr = panelOf(pdf("0 0 1206 2622", `q Q q ${corner} 1206 0 l 0 0 l 0 2622 l h f`))!.corners[1]!;
  assert.ok(Math.abs(tr * 1206 - 186) < 1, `${tr * 1206}`);
});

test("each corner as the superellipse CSS draws: Apple's continuous curves, which no circle follows", () => {
  // (a shape whose top right is a superellipse of reach 240 and exponent 2^1.4, its bottom left a circle of 100 and its
  // other corners square)
  const [w, h, reach, n] = [1206, 2622, 240, 2 ** 1.4];
  const along = Array.from({ length: 41 }, (_, i) => {
    const t = (i / 40) * (Math.PI / 2);
    return `${w - reach + reach * Math.sin(t) ** (2 / n)} ${h - reach + reach * Math.cos(t) ** (2 / n)} l`;
  }).join(" ");
  const shape = `q Q q 0 ${h} m ${w - reach} ${h} l ${along} ${w} 0 l 100 0 l ${100 * (1 - K)} 0 0 ${100 * (1 - K)} 0 100 c h f`;
  const panel = panelOf(pdf(`0 0 ${w} ${h}`, shape))!;
  const tr = panel.curves![1];
  assert.ok(Math.abs(tr.reach * w - reach) < 3, `${tr.reach * w}`);
  assert.ok(Math.abs(tr.k - 1.4) < 0.05, `${tr.k}`);
  assert.ok(Math.abs(panel.curves![3].reach * w - 100) < 3 && Math.abs(panel.curves![3].k - 1) < 0.05);
  // A corner with no curve has none.
  assert.equal(panel.curves![2].reach, 0);
});

test("a shape past its page's edge a little still has its corners", () => {
  // (Apple Watch Ultra's goes past its top by half a point)
  const over = "90 200.5 m 110 200.5 l 118 200.5 120 198 120 190 c 120 10 l 120 2 118 0 110 0 c 10 0 l 2 0 0 2 0 10 c 0 190 l 0 198 2 200.5 10 200.5 c h f";
  const corners = panelOf(pdf("0 0 120 200", over))!.corners;
  assert.ok(corners.every((c) => c > 0.05 && c < 0.2), `${corners}`);
});

test("the shape in another stream than the file's first, and a box as another tool writes it", () => {
  const mask = Buffer.concat([
    Buffer.from("%PDF-1.5\n<< /Length 4 >>\nstream\n\u0002\u0001\u0000\u0010\nendstream\n<< /Filter /FlateDecode >>\nstream\n"),
    deflateSync(round(1640, 2360, [100, 100, 100, 100])),
    Buffer.from("\nendstream\n<< /MediaBox[0.0 0.0 1640.0 2360.0] >>\n"),
  ]);
  near(panelOf(mask)!.corners, [0.061, 0.061, 0.061, 0.061]);
});

test("a shape moved onto its page, and in a curve's short forms, as Illustrator's masks have it", () => {
  // the same corners, the shape drawn from its top left with the page's origin moved there
  const r = 100 * (1 - K);
  const moved = `/Layer /MC0 BDC q 0 2360 1640 -2360 re W n /GS0 gs q 1 0 0 1 100 2360 cm 0 0 m 1440 0 l ${1440 + 100 - r} 0 1540 ${-r} 1540 -100 c 1540 -2260 l 1540 ${-2360 + r} ${1540 - r} -2360 1440 -2360 c 0 -2360 l ${-100 + r} -2360 -100 ${-2360 + r} -100 -2260 c -100 -100 l -100 ${-r} ${-100 + r} 0 0 0 c h f`;
  near(panelOf(pdf("0.0 0.0 1640.0 2360.0", moved))!.corners, [0.061, 0.061, 0.061, 0.061]);
  // v: the first control point at the point before; y: the second at the end
  const short = `50 100 m 90 100 l 100 100 100 90 v 100 10 l 100 0 90 0 y 10 0 l 0 0 0 10 v 0 90 l 0 100 10 100 y h f`;
  const corners = panelOf(pdf("0 0 100 100", short))!.corners;
  assert.ok(corners.every((c) => c > 0.05 && c < 0.15), `${corners}`);
});

test("corners that make no sense are no mask", () => {
  assert.equal(panelOf(pdf("0 0 10 10", "1000 1000 m 1100 1000 1100 1100 1000 1100 c h f")), null);
});

test("not compressed is read too, and what is no mask says so", () => {
  near(panelOf(pdf("0 0 100 200", round(100, 200, [10, 10, 10, 10]), false))!.corners, [0.1, 0.1, 0.1, 0.1]);
  assert.equal(panelOf(Buffer.from("not a pdf")), null);
  assert.equal(panelOf(pdf("0 0 100 200", "q Q")), null);
});
