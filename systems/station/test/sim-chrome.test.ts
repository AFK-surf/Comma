// A simulator's case as Xcode has it (screens/sim-chrome.ts, ported from still.fail's station/test/sim-chrome.test.ts): how
// it is read and laid out, and how its pictures are made and turned. Every chrome.json and PDF here is made by the test:
// Apple's own are never in this repository. Drawing a PDF is `sips`'s, a Mac's: that test runs on a Mac alone.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { chromeOf, decode, displaysOf, encode, pageSize, picturesOf, turned } from "../src/screens/sim-chrome.ts";
import { compositeCase } from "./sim-chrome-fixture.ts";

test("a PDF's page, on its side as /Rotate says", () => {
  assert.deepEqual(pageSize(Buffer.from("<< /MediaBox [0 0 63 16] >>")), { width: 63, height: 16 });
  assert.deepEqual(pageSize(Buffer.from("<< /MediaBox [0 0 63 16] /Rotate 270 >>")), { width: 16, height: 63 });
  assert.equal(pageSize(Buffer.from("none")), null);
});

test("a device type's displays: those with a digitizer, else the profile's", () => {
  const caps = {
    capabilities: {
      displays: [
        { displayType: "integrated", hasDigitizer: true, chromeIdentifier: "x.phone15", framebufferMaskIdentifier: "A", width: 1398, height: 2034, scale: 3 },
        { displayType: "integrated", hasDigitizer: true, chromeIdentifier: "x.phone14", framebufferMaskIdentifier: "B", width: 2007, height: 2853, scale: 3 },
        { displayType: "tvOut", hasDigitizer: false, width: 720, height: 480 },
      ],
    },
  };
  assert.deepEqual(displaysOf(caps, {}).map((d) => d.chrome), ["x.phone15", "x.phone14"]);
  const old = { capabilities: { ScreenDimensionsCapability: { "main-screen-width": 750, "main-screen-height": 1334, "main-screen-scale": 2 } } };
  assert.deepEqual(displaysOf(old, { chromeIdentifier: "x.phone" }), [{ chrome: "x.phone", mask: null, width: 750, height: 1334, scale: 2 }]);
  assert.deepEqual(displaysOf({}, {}), []);
});

test("a case in pieces: the panel inside its sizing, each button from its side, by its usage", async () => {
  const root = mkdtempSync(join(tmpdir(), "sim-chrome-"));
  const dir = join(root, "phone9.devicechrome/Contents/Resources");
  mkdirSync(dir, { recursive: true });
  const pdf = (name: string, w: number, h: number) => writeFileSync(join(dir, `${name}.pdf`), `<< /MediaBox [0 0 ${w} ${h}] >>`);
  for (const n of ["TL", "T", "TR", "R", "BR", "B", "BL", "L"]) pdf(n, 18, 18);
  pdf("Vol", 16, 64);
  pdf("Vol Dn", 16, 64);
  pdf("Power", 16, 100);
  pdf("Home", 60, 60);
  const button = (name: string, image: string, anchor: string, align: string, x: number, y: number, more: object = {}) => ({ name, image, anchor, align, offsets: { normal: { x, y }, rollover: { x: x + (anchor === "left" ? -5 : anchor === "bottom" ? 0 : 5), y } }, ...more });
  writeFileSync(
    join(dir, "chrome.json"),
    JSON.stringify({
      images: { topLeft: "TL", top: "T", topRight: "TR", right: "R", bottomRight: "BR", bottom: "B", bottomLeft: "BL", left: "L", sizing: { leftWidth: 20, rightWidth: 20, topHeight: 30, bottomHeight: 40 }, devicePadding: { left: 9, right: 9, top: 0, bottom: 0 } },
      inputs: [
        button("volume-up", "Vol", "left", "leading", 8, 100, { usagePage: 12, usage: 233, imageDown: "Vol Dn" }),
        button("power", "Power", "right", "leading", -8, 120, { usagePage: 12, usage: 48 }),
        button("home", "Home", "bottom", "center", 0, -90, { usagePage: 12, usage: 64, onTop: true }),
        button("gone", "Missing", "left", "leading", 0, 0),
      ],
    }),
  );
  const c = await chromeOf({ chrome: "com.apple.dt.devicekit.chrome.phone9", mask: null, width: 750, height: 1334, scale: 2 }, root, null, root);
  assert.ok(c);
  assert.deepEqual(c.frame, { width: 375 + 40 + 18, height: 667 + 70 });
  assert.deepEqual(c.screen, { x: 29, y: 30, width: 375, height: 667 });
  const by = Object.fromEntries(c.buttons.map((b) => [b.name, b]));
  assert.deepEqual(Object.keys(by), ["volume-up", "power", "home"]);
  // (as far out on the left as on the right: normal 8 inward puts a 16 wide button's edge on the case's, 5 further out as it stands)
  assert.equal(by["volume-up"]!.x, 9 - 5);
  assert.equal(by.power!.x + by.power!.width, 9 + 415 + 5);
  assert.equal(by["volume-up"]!.dx, 5);
  assert.deepEqual([by.power!.page, by.power!.usage], [12, 48]);
  assert.equal(by.home!.front, true);
  assert.equal(by.home!.x, 9 + (415 - 60) / 2);
  assert.equal(by.home!.y, 737 - 90);
  assert.equal(by.home!.dx, 0);
});

test("none for what Xcode does not have, or a name that is no folder's", async () => {
  const root = mkdtempSync(join(tmpdir(), "sim-chrome-"));
  assert.equal(await chromeOf({ chrome: "x.none", mask: null, width: 1, height: 1, scale: 1 }, root, null, root), null);
  assert.equal(await chromeOf({ chrome: "../../etc", mask: null, width: 1, height: 1, scale: 1 }, root, null, root), null);
});

test("pictures turned clockwise, and through a PNG as they were", async () => {
  // 2×1: red, green
  const p = { width: 2, height: 1, data: new Uint8Array([255, 0, 0, 255, 0, 255, 0, 128]) };
  const q = turned(p, 1);
  assert.deepEqual([q.width, q.height, ...q.data], [1, 2, 255, 0, 0, 255, 0, 255, 0, 128]);
  assert.deepEqual([...turned(p, 2).data], [0, 255, 0, 128, 255, 0, 0, 255]);
  assert.deepEqual([...turned(p, 3).data], [0, 255, 0, 128, 255, 0, 0, 255]);
  assert.equal(turned(p, 0), p);
  const back = decode(await encode(p));
  assert.deepEqual([back.width, back.height, ...back.data], [2, 1, ...p.data]);
});

test("a composite case's pictures: the panel cut out where its mask is, the case round it, turned as asked", { skip: !existsSync("/usr/bin/sips") }, async () => {
  const { root, bundle } = compositeCase();
  const c = await chromeOf({ chrome: "com.apple.dt.devicekit.chrome.phone8", mask: "Mask", width: 240, height: 540, scale: 3 }, bundle, null, root);
  assert.ok(c);
  assert.deepEqual(c.frame, { width: 106, height: 200 });
  assert.deepEqual(c.screen, { x: 10, y: 10, width: 80, height: 180 });
  assert.deepEqual(c.buttons.map((b) => [b.name, b.page, b.usage]), [["power", 12, 48]]);
  const upright = await picturesOf(c, 0);
  // (a phone's case is drawn at three pixels a point)
  const body = decode(Buffer.from(upright.body, "base64"));
  assert.deepEqual([body.width, body.height], [318, 600]);
  const alpha = (p: typeof body, x: number, y: number) => p.data[(y * p.width + x) * 4 + 3]!;
  assert.equal(alpha(body, 159, 300), 0, "the panel shows through");
  assert.equal(alpha(body, 10, 300), 255, "the case is round it");
  assert.equal(alpha(body, 315, 300), 0, "nothing in its padding");
  const power = decode(Buffer.from(upright.buttons.power!.up, "base64"));
  assert.deepEqual([power.width, power.height], [12, 90]);
  // A quarter turn clockwise: the case on its side, its left edge now its top.
  const turnedBody = decode(Buffer.from((await picturesOf(c, 1)).body, "base64"));
  assert.deepEqual([turnedBody.width, turnedBody.height], [600, 318]);
  assert.equal(alpha(turnedBody, 300, 159), 0);
  assert.equal(alpha(turnedBody, 300, 10), 255);
});
