// A simulator's screen as Apple draws it: its device type's framebuffer masks (a PDF for each of its panels, an iPhone
// Duo's two), read for what the app's device body goes round. Each corner is the circle that comes as near its corner as the
// shape does, as a share of the panel's width: Apple's curves start far along the edges, and may pass them a little (a Duo's
// cover is nearly square on its hinge). Each corner's `curves` is the superellipse nearest its curve, as CSS draws one
// (`corner-shape: superellipse(k)` on a `border-radius` of `reach`): Apple's continuous corners, which no circle is.
import { inflateSync } from "node:zlib";
import type { Panel } from "./source.ts";

/// How many straight pieces each curve of a mask is taken as.
const CURVE_STEPS = 16;


/// The panel a mask's PDF says, its corners top left and then round it; null when it is not such a mask.
export function panelOf(pdf: Buffer): Panel | null {
  const text = pdf.toString("latin1");
  const box = /\/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+([\d.]+)\s+([\d.]+)\s*\]/.exec(text);
  if (!box) return null;
  const [width, height] = [Number(box[1]), Number(box[2])];
  // (a page's drawing may not be the file's first stream, nor at all where another tool made it: the first that has the shape)
  for (const stream of text.matchAll(/stream\r?\n/g)) {
    if (text.startsWith("end", stream.index - 3)) continue;
    const start = stream.index + stream[0].length;
    const end = text.indexOf("endstream", start);
    if (end < 0) break;
    const body = pdf.subarray(start, end);
    let path: string;
    try {
      path = inflateSync(body).toString("latin1");
    } catch {
      path = body.toString("latin1");
    }
    const outline = outlineOf(path);
    if (outline.length === 0) continue;
    const corner = (x: number, y: number) => {
      const nearest = Math.min(...outline.map(([px, py]) => Math.hypot(px - x, py - y)));
      return Math.round((nearest / (Math.SQRT2 - 1) / width) * 10_000) / 10_000;
    };
    const corners: Panel["corners"] = [corner(0, height), corner(width, height), corner(width, 0), corner(0, 0)];
    if (!corners.every((c) => c <= 0.5)) return null;
    const curve = (x: number, y: number) => {
      const { reach, k } = curveOf(
        outline.map(([px, py]) => [Math.abs(px - x), Math.abs(py - y)]),
        Math.min(width, height) / 4,
      );
      return { reach: Math.round((reach / width) * 10_000) / 10_000, k: Math.round(k * 1000) / 1000 };
    };
    const curves: NonNullable<Panel["curves"]> = [curve(0, height), curve(width, height), curve(width, 0), curve(0, 0)];
    return { width, height, corners, curves };
  }
  return null;
}

/// The superellipse `|x/reach|^n + |y/reach|^n = 1` (n = 2^k, as CSS's `superellipse(k)`) that comes nearest a corner's
/// curve: `points` as their distances from the corner's two edges, those nearer than `within` to both taken. Each is
/// measured along the line to the curve's centre. A corner with no curve has reach 0.
export function curveOf(points: [number, number][], within: number): { reach: number; k: number } {
  const edge = within / 1000;
  const curved = points.filter(([a, b]) => a > edge && b > edge && a < within && b < within);
  if (curved.length < 3) return { reach: 0, k: 1 };
  const longest = Math.max(...curved.map(([a, b]) => Math.max(a, b)));
  const off = (reach: number, n: number) => {
    let worst = 0;
    for (const [a, b] of curved) {
      if (a >= reach || b >= reach) {
        worst = Math.max(worst, Math.min(a, b));
        continue;
      }
      const u = (reach - a) / reach;
      const v = (reach - b) / reach;
      worst = Math.max(worst, Math.abs((u ** n + v ** n) ** (1 / n) - 1) * reach);
    }
    return worst;
  };
  // (coarse, then fine round the best: a mask is read once for its device type)
  let best = { off: Infinity, reach: longest, n: 2 };
  const search = (reaches: [number, number, number], ns: [number, number, number]) => {
    const around = best;
    for (let reach = around.reach + reaches[0]; reach <= around.reach + reaches[1]; reach += reaches[2])
      for (let n = Math.max(1.2, around.n + ns[0]); n <= around.n + ns[1]; n += ns[2]) {
        const got = off(reach, n);
        if (got < best.off) best = { off: got, reach, n };
      }
  };
  search([-longest / 2, longest / 3, longest / 50], [-0.8, 6, 0.1]);
  search([-longest / 50, longest / 50, longest / 1000], [-0.1, 0.1, 0.005]);
  return { reach: best.reach, k: Math.log2(best.n) };
}

/// The points along a mask's drawing's shape, on its page: its first subpath with curves (a clip round the page before it has
/// none, and it may be a clip itself), each curve in small steps. Empty when it has no such shape.
function outlineOf(path: string): [number, number][] {
  let points: [number, number][] = [];
  let curved = false;
  // (as Illustrator's masks have it: the shape's own coordinates moved onto the page, and curves in its short forms)
  let [a, b, c, d, e, f] = [1, 0, 0, 1, 0, 0];
  const onPage = (x: number, y: number): [number, number] => [a * x + c * y + e, b * x + d * y + f];
  const said: number[] = [];
  let at: [number, number] = [0, 0];
  const curve = (x1: number, y1: number, x2: number, y2: number, x3: number, y3: number) => {
    const [x0, y0] = at;
    for (let i = 1; i <= CURVE_STEPS; i++) {
      const t = i / CURVE_STEPS;
      const u = 1 - t;
      points.push(onPage(u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3, u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3));
    }
    at = [x3, y3];
    curved = true;
  };
  for (const word of path.split(/\s+/)) {
    const n = Number(word);
    if (word !== "" && !Number.isNaN(n)) {
      said.push(n);
      continue;
    }
    const last = said.slice(-6) as [number, number, number, number, number, number];
    const [p, q, r, s] = said.slice(-4) as [number, number, number, number];
    if (word === "cm" && said.length >= 6) {
      const [a2, b2, c2, d2, e2, f2] = last;
      [a, b, c, d, e, f] = [a2 * a + b2 * c, a2 * b + b2 * d, c2 * a + d2 * c, c2 * b + d2 * d, e2 * a + f2 * c + e, e2 * b + f2 * d + f];
    } else if (word === "m") {
      if (curved) break;
      points = [];
    }
    if ((word === "m" || word === "l") && said.length >= 2) {
      at = [said.at(-2)!, said.at(-1)!];
      points.push(onPage(...at));
    } else if (word === "c" && said.length >= 6) {
      curve(...last);
    } else if (word === "v" && said.length >= 4) {
      curve(at[0], at[1], p, q, r, s);
    } else if (word === "y" && said.length >= 4) {
      curve(p, q, r, s, r, s);
    }
    said.length = 0;
  }
  return curved ? points : [];
}
