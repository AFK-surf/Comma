// A simulator's device as Apple draws it (docs/simulator-screen.md, "The device's case"), ported from still.fail
// (github.com/AFK-surf/still.fail, afk/main d4aeecd700) station/src/screens/sim-chrome.ts: the case and buttons Xcode has
// for its device type (DeviceKit's .devicechrome: chrome.json, PDFs), read on this Mac and kept nowhere but this Mac's
// temporary files: they are Apple's, never in this repository or an app. Each panel (an iPhone Duo's two) is told clients
// as geometry in the case's own points; its pictures, turned as the device stands, are made as a client asks. The case is
// one picture with the panel's shape cut out of it (the device type's framebuffer mask) and the sensor bar over that, so the
// device's picture shows through it however a client draws that.
//
// Where it all lies and how it is laid out is serve-sim's (EvanBacon/serve-sim packages/serve-sim/src/devicekit-chrome.ts
// and device-displays.ts, Apache-2.0: vendor/README.md), changed so a client has one picture to draw.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { deflate, inflateSync } from "node:zlib";
import { panelOf } from "./sim-mask.ts";
import type { Panel } from "./source.ts";

const CHROME_ROOT = "/Library/Developer/DeviceKit/Chrome";
const CHROME_PREFIX = "com.apple.dt.devicekit.chrome.";
const CACHE = join(tmpdir(), "comma-device-chrome");
/// Pictures made by an older way of making them are not used: said in their names.
const CACHE_WAY = 1;
const deflated = promisify(deflate);

export type Size = { width: number; height: number };
export type Rect = Size & { x: number; y: number };
type Insets = { top: number; left: number; bottom: number; right: number };

/// A button of the device, in its panel's frame: where it rests, the way it goes in as it is pressed, its HID usage
/// (none: it is only drawn); `front`: on the case (a home button), not behind it.
export type ChromeButton = Rect & { name: string; dx: number; dy: number; front?: boolean; page?: number; usage?: number };

/// A panel's case as clients are told it, upright as its framebuffer is, in the case's own points.
export type ChromePanel = {
  /// Which it is, for the pictures of it (`pictures`): where several panels have the same case, the same.
  key: string;
  /// The framebuffer in pixels, whose shape says which panel a picture is of.
  width: number;
  height: number;
  frame: Size;
  /// Where the picture goes in `frame`.
  screen: Rect;
  /// The panel's corners as sim-mask.ts has them: what a client covers of the picture's, outside the panel and under the case.
  corners: number[];
  /// Each corner as a superellipse, where the mask says it (sim-mask.ts `curves`).
  curves?: Panel["curves"];
  buttons: ChromeButton[];
};

/// What makes a panel's pictures, kept beside what clients are told.
export type ChromeSource = ChromePanel & {
  dir: string;
  body: Rect;
  composite: string | null;
  slice: Slice | null;
  sizing: Insets;
  mask: string | null;
  sensor: string | null;
  images: { name: string; image: string; down: string | null; under: boolean }[];
};

type Slice = { topLeft: string; top: string; topRight: string; right: string; bottomRight: string; bottom: string; bottomLeft: string; left: string };

/// A device type's displays with a digitizer, each as much as its capabilities.plist says of it.
export type ChromeDisplay = { chrome: string; mask: string | null; width: number; height: number; scale: number };

/// A device type's panels: its capabilities' displays, else (an older profile) the one its profile.plist says.
export function displaysOf(capabilities: unknown, profile: unknown): ChromeDisplay[] {
  const caps = record(record(capabilities).capabilities ?? capabilities);
  const out: ChromeDisplay[] = [];
  for (const entry of Array.isArray(caps.displays) ? caps.displays : []) {
    const d = record(entry);
    if (d.displayType !== "integrated" || d.hasDigitizer !== true || typeof d.chromeIdentifier !== "string") continue;
    const [width, height, scale] = [num(d.width), num(d.height), num(d.scale) || 1];
    if (width > 0 && height > 0) out.push({ chrome: d.chromeIdentifier, mask: stringOf(d.framebufferMaskIdentifier), width, height, scale });
  }
  if (out.length > 0) return out;
  const p = record(profile);
  const dims = record(caps.ScreenDimensionsCapability);
  const [width, height, scale] = [num(dims["main-screen-width"]), num(dims["main-screen-height"]), num(dims["main-screen-scale"]) || 1];
  if (typeof p.chromeIdentifier !== "string" || width <= 0 || height <= 0) return [];
  return [{ chrome: p.chromeIdentifier, mask: stringOf(p.framebufferMask), width, height, scale }];
}

/// A display's case laid out, from its device type's bundle (`bundle`: its Contents/Resources); null where Xcode has none
/// for it or what it has cannot be read: the app draws what it did before.
export async function chromeOf(display: ChromeDisplay, bundle: string, sensor: string | null, root = CHROME_ROOT): Promise<ChromeSource | null> {
  const bare = display.chrome.startsWith(CHROME_PREFIX) ? display.chrome.slice(CHROME_PREFIX.length) : display.chrome;
  if (!/^[A-Za-z0-9_-]+$/.test(bare)) return null;
  const dir = join(root, `${bare}.devicechrome`, "Contents", "Resources");
  let json: Record<string, unknown>;
  try {
    json = JSON.parse(readFileSync(join(dir, "chrome.json"), "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
  const images = record(json.images);
  const sizing = insetsOf(record(images.sizing), "leftWidth", "topHeight", "rightWidth", "bottomHeight");
  const padding = insetsOf(record(images.devicePadding), "left", "top", "right", "bottom");
  const pdf = (name: unknown) => (typeof name === "string" && existsSync(join(dir, `${name}.pdf`)) ? name : null);
  const composite = pdf(images.composite);
  const slice = sliceOf(images, pdf);
  const mask = display.mask !== null && existsSync(join(bundle, `${display.mask}.pdf`)) ? join(bundle, `${display.mask}.pdf`) : null;
  const maskSize = mask ? pageSize(readFileSync(mask)) : null;
  let bodySize: Size | null = null;
  let screen: Size = { width: display.width / display.scale, height: display.height / display.scale };
  let centre: { x: number; y: number } | null = null;
  if (composite !== null) {
    bodySize = pageSize(readFileSync(join(dir, `${composite}.pdf`)));
    const opening = await openingOf(join(dir, `${composite}.pdf`));
    if (opening) {
      // (Apple's mask is the panel's shape in units that differ from one device to another: the composite's own opening says which)
      if (maskSize) {
        const scale = Math.max(1, Math.round(maskSize.width / opening.width));
        screen = { width: maskSize.width / scale, height: maskSize.height / scale };
      }
      centre = { x: opening.x + opening.width / 2, y: opening.y + opening.height / 2 };
    }
  }
  if (bodySize === null && slice === null) return null;
  bodySize ??= { width: screen.width + sizing.left + sizing.right, height: screen.height + sizing.top + sizing.bottom };
  const body: Rect = { x: padding.left, y: padding.top, ...bodySize };
  const frame = { width: bodySize.width + padding.left + padding.right, height: bodySize.height + padding.top + padding.bottom };
  const at = centre ?? { x: composite !== null ? bodySize.width / 2 : sizing.left + screen.width / 2, y: composite !== null ? bodySize.height / 2 : sizing.top + screen.height / 2 };
  const placed: Rect = { x: body.x + at.x - screen.width / 2, y: body.y + at.y - screen.height / 2, ...screen };
  const buttons: ChromeButton[] = [];
  const pictured: ChromeSource["images"] = [];
  for (const entry of Array.isArray(json.inputs) ? json.inputs : []) {
    const b = record(entry);
    const image = pdf(b.image);
    if (image === null || typeof b.name !== "string") continue;
    const size = pageSize(readFileSync(join(dir, `${image}.pdf`)));
    if (!size) continue;
    const offsets = record(b.offsets);
    const normal = pointOf(record(offsets.normal));
    const rollover = pointOf(record(offsets.rollover));
    const place = buttonAt(String(b.anchor), String(b.align), rollover ?? normal ?? { x: 0, y: 0 }, size, body, b.onTop === true);
    const [page, usage] = [num(b.usagePage), num(b.usage)];
    buttons.push({
      name: b.name,
      ...place,
      ...size,
      dx: (normal?.x ?? 0) - (rollover?.x ?? normal?.x ?? 0),
      dy: (normal?.y ?? 0) - (rollover?.y ?? normal?.y ?? 0),
      ...(b.onTop === true ? { front: true } : {}),
      ...(page > 0 && usage > 0 ? { page, usage } : {}),
    });
    pictured.push({ name: b.name, image, down: pdf(b.imageDown), under: b.imageDownDrawMode === "compositeUnder" });
  }
  // (a mask whose name is another device's would be the same case with another shape cut out of it)
  const key = createHash("sha1").update(`${bare}\0${display.mask ?? ""}\0${sensor ?? ""}\0${display.width}x${display.height}`).digest("hex").slice(0, 16);
  return {
    key,
    width: display.width,
    height: display.height,
    frame,
    screen: placed,
    ...cornersOf(mask),
    buttons,
    dir,
    body,
    composite,
    slice,
    sizing,
    mask,
    sensor: sensor !== null && existsSync(join(bundle, `${sensor}.pdf`)) ? join(bundle, `${sensor}.pdf`) : null,
    images: pictured,
  };
}

/// What clients are told of a panel.
export function toldOf(c: ChromeSource): ChromePanel {
  const { key, width, height, frame, screen, corners, curves, buttons } = c;
  return { key, width, height, frame, screen, corners, ...(curves ? { curves } : {}), buttons };
}

/// A panel's corners as its mask says them, none where it has none.
function cornersOf(mask: string | null | undefined): { corners: number[]; curves?: Panel["curves"] } {
  const panel = mask ? panelOf(readFileSync(mask)) : null;
  return panel ? { corners: panel.corners, ...(panel.curves ? { curves: panel.curves } : {}) } : { corners: [] };
}

/// Where a button rests. In chrome.json's `offsets`, from the side it is anchored to, the middle of its picture is: at `normal`
/// its outer edge is that of the case, at `rollover` it stands out, where Apple's shows only under a pointer. Here it stands so
/// always, to be seen, by as much as `SHOWS` at least (an iPhone Duo's cover's power button is further in), and its picture's top
/// left is what `normal` says of a button on the case's face. dx, dy: towards its `normal`, the way it goes as it is pressed.
function buttonAt(anchor: string, align: string, out: { x: number; y: number }, size: Size, body: Rect, front: boolean) {
  const along = align === "trailing" ? body.x + body.width + out.x - size.width : align === "center" ? body.x + (body.width - size.width) / 2 + out.x : body.x + out.x;
  switch (anchor) {
    case "right":
      return { x: Math.max(body.x + body.width + out.x - size.width / 2, body.x + body.width + SHOWS - size.width), y: body.y + out.y };
    case "top":
      return { x: along, y: Math.min(body.y + out.y - size.height / 2, body.y - SHOWS) };
    case "bottom":
      return { x: along, y: front ? body.y + body.height + out.y : Math.max(body.y + body.height + out.y - size.height / 2, body.y + body.height + SHOWS - size.height) };
    default:
      return { x: Math.min(body.x + out.x - size.width / 2, body.x - SHOWS), y: body.y + out.y };
  }
}

/// How far a button stands out of the case at the least.
const SHOWS = 3;

/// How many pixels a case's point is drawn at: a phone's picture is as sharp as its panel, a tablet's no more than the page can show.
const pixelsOf = (c: ChromeSource) => (c.frame.width > 700 ? 2 : 3);

export type ChromePictures = { body: string; buttons: Record<string, { up: string; down?: string }> };

const making = new Map<string, Promise<ChromePictures>>();

/// A panel's pictures, turned `turn` quarters clockwise, as base64 PNGs. Made once and kept in this Mac's temporary files.
export function picturesOf(c: ChromeSource, turn: number): Promise<ChromePictures> {
  const id = `${c.key}/${turn}`;
  let made = making.get(id);
  if (!made) {
    made = make(c, turn);
    making.set(id, made);
    made.catch(() => making.delete(id));
  }
  return made;
}

async function make(c: ChromeSource, turn: number): Promise<ChromePictures> {
  const stamp = statSync(join(c.dir, "chrome.json"));
  const stem = createHash("sha1").update(`${CACHE_WAY}\0${c.key}\0${stamp.mtimeMs}\0${turn}`).digest("hex");
  mkdirSync(CACHE, { recursive: true });
  const kept = join(CACHE, `${stem}.json`);
  if (existsSync(kept)) return JSON.parse(readFileSync(kept, "utf8")) as ChromePictures;
  const scale = pixelsOf(c);
  const pictures: ChromePictures = { body: (await encode(turned(await bodyOf(c, scale), turn))).toString("base64"), buttons: {} };
  for (const b of c.buttons) {
    const names = c.images.find((i) => i.name === b.name)!;
    const size = { width: Math.round(b.width * scale), height: Math.round(b.height * scale) };
    const drawn = (name: string) => rendered(join(c.dir, `${name}.pdf`), size);
    const one = async (p: Pixels) => (await encode(turned(p, turn))).toString("base64");
    const up = await drawn(names.image);
    let down: Pixels | null = names.down ? await drawn(names.down) : null;
    // (a home button's pressed picture is what is under the button itself)
    if (down && names.under) {
      down = { ...down, data: down.data.slice() };
      paint(down, up, 0, 0);
    }
    pictures.buttons[b.name] = { up: await one(up), ...(down ? { down: await one(down) } : {}) };
  }
  const tmp = `${kept}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(pictures));
  renameSync(tmp, kept);
  return pictures;
}

/// The case over its frame: composite, or its pieces with the sides stretched; the panel's shape cut out; the sensor bar over that.
async function bodyOf(c: ChromeSource, scale: number): Promise<Pixels> {
  const frame = blank(Math.round(c.frame.width * scale), Math.round(c.frame.height * scale));
  const x = Math.round(c.body.x * scale);
  const y = Math.round(c.body.y * scale);
  const w = Math.round(c.body.width * scale);
  const h = Math.round(c.body.height * scale);
  if (c.composite !== null) {
    paint(frame, await rendered(join(c.dir, `${c.composite}.pdf`), { width: w, height: h }), x, y);
  } else if (c.slice !== null) {
    const pdf = (name: string) => join(c.dir, `${name}.pdf`);
    const corner = pageSize(readFileSync(pdf(c.slice.topLeft)))!;
    const [cw, ch] = [Math.round(corner.width * scale), Math.round(corner.height * scale)];
    const piece = (name: string, width: number, height: number) => rendered(pdf(name), { width, height });
    paint(frame, stretched(await piece(c.slice.top, Math.round(pageSize(readFileSync(pdf(c.slice.top)))!.width * scale), ch), w - 2 * cw, ch), x + cw, y);
    paint(frame, stretched(await piece(c.slice.bottom, Math.round(pageSize(readFileSync(pdf(c.slice.bottom)))!.width * scale), ch), w - 2 * cw, ch), x + cw, y + h - ch);
    paint(frame, stretched(await piece(c.slice.left, cw, Math.round(pageSize(readFileSync(pdf(c.slice.left)))!.height * scale)), cw, h - 2 * ch), x, y + ch);
    paint(frame, stretched(await piece(c.slice.right, cw, Math.round(pageSize(readFileSync(pdf(c.slice.right)))!.height * scale)), cw, h - 2 * ch), x + w - cw, y + ch);
    paint(frame, await piece(c.slice.topLeft, cw, ch), x, y);
    paint(frame, await piece(c.slice.topRight, cw, ch), x + w - cw, y);
    paint(frame, await piece(c.slice.bottomLeft, cw, ch), x, y + h - ch);
    paint(frame, await piece(c.slice.bottomRight, cw, ch), x + w - cw, y + h - ch);
    // (the pieces leave the middle empty: what is not the panel is black, as the composite has it)
    fillRect(frame, x + cw, y + ch, w - 2 * cw, h - 2 * ch);
  }
  const sx = Math.round(c.screen.x * scale);
  const sy = Math.round(c.screen.y * scale);
  const sw = Math.round(c.screen.width * scale);
  const sh = Math.round(c.screen.height * scale);
  if (c.mask !== null) {
    // Inside the mask nothing of the case is left; at its edge as much as the mask leaves.
    const mask = await rendered(c.mask, { width: sw, height: sh });
    for (let j = 0; j < sh; j++) {
      for (let i = 0; i < sw; i++) {
        const p = ((sy + j) * frame.width + sx + i) * 4 + 3;
        frame.data[p] = Math.round((frame.data[p]! * (255 - mask.data[(j * sw + i) * 4 + 3]!)) / 255);
      }
    }
  } else {
    for (let j = 0; j < sh; j++) frame.data.fill(0, (sy + j) * frame.width * 4 + sx * 4, (sy + j) * frame.width * 4 + (sx + sw) * 4);
  }
  if (c.sensor !== null) {
    // In the panel's points, at the middle of its top: a notch's. (A Dynamic Island's has nothing in it: the device draws that
    // in its own picture.)
    const size = pageSize(readFileSync(c.sensor));
    if (size) {
      const bar = await rendered(c.sensor, { width: Math.round(size.width * scale), height: Math.round(size.height * scale) });
      paint(frame, bar, sx + Math.round((sw - bar.width) / 2), sy);
    }
  }
  return frame;
}

/// The size a PDF's page says it is.
export function pageSize(pdf: Buffer): Size | null {
  const text = pdf.toString("latin1");
  const box = /\/CropBox\s*\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]/.exec(text) ?? /\/MediaBox\s*\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]/.exec(text);
  if (!box) return null;
  const [width, height] = [Math.abs(Number(box[3]) - Number(box[1])), Math.abs(Number(box[4]) - Number(box[2]))];
  if (width <= 0 || height <= 0) return null;
  return pageTurn(text) % 2 === 1 ? { width: height, height: width } : { width, height };
}

/// The quarter turns clockwise a PDF's page is shown at (an iPhone Duo's inner panel's buttons are drawn on their side so).
const pageTurn = (text: string) => Number(/\/Rotate\s+(\d+)/.exec(text)?.[1] ?? 0) / 90;

/// A composite's opening, the opaque black it has for a screen: walked out from its middle along its middle row and column,
/// so the dark metal elsewhere is not taken for it. In its own points.
async function openingOf(pdf: string): Promise<Rect | null> {
  const size = pageSize(readFileSync(pdf));
  if (!size) return null;
  const { width, height, data } = await rendered(pdf, { width: Math.round(size.width), height: Math.round(size.height) });
  const dark = (x: number, y: number) => {
    if (x < 0 || y < 0 || x >= width || y >= height) return false;
    const p = (y * width + x) * 4;
    return data[p + 3]! > 200 && data[p]! < 30 && data[p + 1]! < 30 && data[p + 2]! < 30;
  };
  const [cx, cy] = [width >> 1, height >> 1];
  if (!dark(cx, cy)) return null;
  let [x0, x1, y0, y1] = [cx, cx, cy, cy];
  while (dark(x0 - 1, cy)) x0--;
  while (dark(x1 + 1, cy)) x1++;
  while (dark(cx, y0 - 1)) y0--;
  while (dark(cx, y1 + 1)) y1++;
  return { x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1 };
}

export type Pixels = { width: number; height: number; data: Uint8Array };

const blank = (width: number, height: number): Pixels => ({ width, height, data: new Uint8Array(width * height * 4) });

/// `over` painted on `under` at (x, y), each pixel over what is there.
function paint(under: Pixels, over: Pixels, x: number, y: number) {
  for (let j = 0; j < over.height; j++) {
    const row = y + j;
    if (row < 0 || row >= under.height) continue;
    for (let i = 0; i < over.width; i++) {
      const col = x + i;
      if (col < 0 || col >= under.width) continue;
      const s = (j * over.width + i) * 4;
      const d = (row * under.width + col) * 4;
      const a = over.data[s + 3]!;
      if (a === 0) continue;
      const b = under.data[d + 3]!;
      const out = a + (b * (255 - a)) / 255;
      for (let k = 0; k < 3; k++) under.data[d + k] = Math.round((over.data[s + k]! * a + (under.data[d + k]! * b * (255 - a)) / 255) / out);
      under.data[d + 3] = Math.round(out);
    }
  }
}

function fillRect(p: Pixels, x: number, y: number, w: number, h: number) {
  for (let j = y; j < y + h; j++) {
    for (let i = x; i < x + w; i++) {
      const d = (j * p.width + i) * 4;
      p.data[d] = p.data[d + 1] = p.data[d + 2] = 0;
      p.data[d + 3] = 255;
    }
  }
}

/// A side piece stretched to `width`×`height`: only along its length, across which it is the same.
function stretched(p: Pixels, width: number, height: number): Pixels {
  const out = blank(width, height);
  for (let j = 0; j < height; j++) {
    const v = Math.min(p.height - 1, Math.floor((j * p.height) / height));
    for (let i = 0; i < width; i++) {
      const u = Math.min(p.width - 1, Math.floor((i * p.width) / width));
      out.data.set(p.data.subarray((v * p.width + u) * 4, (v * p.width + u) * 4 + 4), (j * width + i) * 4);
    }
  }
  return out;
}

/// `p` turned `turn` quarters clockwise.
export function turned(p: Pixels, turn: number): Pixels {
  const t = ((turn % 4) + 4) % 4;
  if (t === 0) return p;
  const out = t === 2 ? blank(p.width, p.height) : blank(p.height, p.width);
  for (let y = 0; y < p.height; y++) {
    for (let x = 0; x < p.width; x++) {
      const [nx, ny] = t === 1 ? [p.height - 1 - y, x] : t === 2 ? [p.width - 1 - x, p.height - 1 - y] : [y, p.width - 1 - x];
      out.data.set(p.data.subarray((y * p.width + x) * 4, (y * p.width + x) * 4 + 4), (ny * out.width + nx) * 4);
    }
  }
  return out;
}

/// A PDF's page at `size`, drawn by `/usr/bin/sips` (what every Mac has: Apple's PDFs are drawn again at that size, not scaled from a
/// picture). `sips` draws a page with a /Rotate squeezed into the wrong shape: its page is drawn as it lies, then turned here.
async function rendered(pdf: string, size: Size): Promise<Pixels> {
  mkdirSync(CACHE, { recursive: true });
  const stem = createHash("sha1").update(`${pdf}\0${statSync(pdf).mtimeMs}\0${size.width}x${size.height}`).digest("hex");
  const png = join(CACHE, `${stem}.png`);
  const bytes = readFileSync(pdf);
  const turn = pageTurn(bytes.toString("latin1"));
  const lying = turn % 2 === 1 ? { width: size.height, height: size.width } : size;
  if (!existsSync(png)) {
    const page = pageSize(bytes)!;
    const longest = Math.max(size.width, size.height);
    const tmp = `${png}.${process.pid}.png`;
    let from = pdf;
    if (turn !== 0) {
      // (the same bytes, the turn said as none: nothing else in the file moves)
      from = `${png}.${process.pid}.pdf`;
      writeFileSync(from, Buffer.from(bytes.toString("latin1").replace(/\/Rotate\s+\d+/, (said) => `/Rotate ${"0".repeat(said.length - 8)}`), "latin1"));
    }
    try {
      await promisify(execFile)("/usr/bin/sips", ["-s", "format", "png", ...(Math.round(Math.max(page.width, page.height)) !== longest ? ["-Z", String(longest)] : []), from, "--out", tmp], { timeout: 20_000 });
    } finally {
      if (from !== pdf) rmSync(from, { force: true });
    }
    renameSync(tmp, png);
  }
  const got = decode(readFileSync(png));
  // (rounding: a pixel off in a side, where what is asked is what is placed)
  return turned(got.width === lying.width && got.height === lying.height ? got : stretched(got, lying.width, lying.height), turn);
}

/// An 8-bit PNG as RGBA.
export function decode(png: Buffer): Pixels {
  if (png.length < 26 || png.toString("latin1", 1, 4) !== "PNG") throw new Error("not a PNG");
  const [width, height] = [png.readUInt32BE(16), png.readUInt32BE(20)];
  if (png[24] !== 8) throw new Error(`a PNG of ${png[24]} bits`);
  const channels = ({ 0: 1, 2: 3, 4: 2, 6: 4 } as Record<number, number>)[png[25]!];
  if (channels === undefined) throw new Error(`a PNG of colour type ${png[25]}`);
  const parts: Buffer[] = [];
  for (let at = 8; at < png.length; ) {
    const n = png.readUInt32BE(at);
    if (png.toString("latin1", at + 4, at + 8) === "IDAT") parts.push(png.subarray(at + 8, at + 8 + n));
    at += 12 + n;
  }
  const raw = inflateSync(Buffer.concat(parts));
  const out = new Uint8Array(width * height * 4);
  const stride = width * channels;
  let prior = new Uint8Array(stride);
  let row = new Uint8Array(stride);
  let at = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[at++]!;
    for (let i = 0; i < stride; i++) {
      const a = i >= channels ? row[i - channels]! : 0;
      const b = prior[i]!;
      const c = i >= channels ? prior[i - channels]! : 0;
      const v = raw[at++]!;
      row[i] = filter === 0 ? v : filter === 1 ? v + a : filter === 2 ? v + b : filter === 3 ? v + ((a + b) >> 1) : v + paeth(a, b, c);
    }
    for (let x = 0; x < width; x++) {
      const d = (y * width + x) * 4;
      if (channels >= 3) {
        out[d] = row[x * channels]!;
        out[d + 1] = row[x * channels + 1]!;
        out[d + 2] = row[x * channels + 2]!;
      } else {
        out[d] = out[d + 1] = out[d + 2] = row[x * channels]!;
      }
      out[d + 3] = channels === 4 ? row[x * 4 + 3]! : channels === 2 ? row[x * 2 + 1]! : 255;
    }
    [prior, row] = [row, prior];
  }
  return { width, height, data: out };
}

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const [pa, pb, pc] = [Math.abs(p - a), Math.abs(p - b), Math.abs(p - c)];
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

/// RGBA as a PNG.
export async function encode(p: Pixels): Promise<Buffer> {
  const raw = Buffer.alloc((p.width * 4 + 1) * p.height);
  for (let y = 0; y < p.height; y++) raw.set(p.data.subarray(y * p.width * 4, (y + 1) * p.width * 4), y * (p.width * 4 + 1) + 1);
  const head = Buffer.alloc(13);
  head.writeUInt32BE(p.width, 0);
  head.writeUInt32BE(p.height, 4);
  head.set([8, 6, 0, 0, 0], 8);
  const chunk = (type: string, body: Buffer) => {
    const out = Buffer.alloc(12 + body.length);
    out.writeUInt32BE(body.length, 0);
    out.write(type, 4, "latin1");
    body.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + body.length)), 8 + body.length);
    return out;
  };
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", head), chunk("IDAT", await deflated(raw)), chunk("IEND", Buffer.alloc(0))]);
}

const CRC = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(b: Uint8Array): number {
  let c = 0xffffffff;
  for (const v of b) c = CRC[(c ^ v) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

const record = (v: unknown): Record<string, unknown> => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const stringOf = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
const pointOf = (r: Record<string, unknown>) => (typeof r.x === "number" && typeof r.y === "number" ? { x: r.x, y: r.y } : null);
const insetsOf = (r: Record<string, unknown>, left: string, top: string, right: string, bottom: string): Insets => ({ left: num(r[left]), top: num(r[top]), right: num(r[right]), bottom: num(r[bottom]) });

function sliceOf(images: Record<string, unknown>, pdf: (name: unknown) => string | null): Slice | null {
  const [topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left] = ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left"].map((k) => pdf(images[k]));
  return topLeft && top && topRight && right && bottomRight && bottom && bottomLeft && left ? { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left } : null;
}
