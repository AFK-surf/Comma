// The screen's pointer drawn over the picture, where the station says it is (`state.cursor`), for a source whose
// pictures leave it out (the computer's desktop). Ported from still.fail: where to draw it and when is the web viewer's
// (web/src/screen/ScreenViewer.tsx `drawPointer`); its shapes are the mbui app's (apps/mbui/src/sf/pointer.mbt
// `pointer_layers`, as a Mac draws each), there rasterised, here the same outlines as SVG in its 20-unit square.
// Deviation: the web viewer draws an arrow whatever the shape; this draws the shape, as mbui and Android do.
import type { ReactNode } from "react";
import type { ScreenCursor } from "./screenStreamStats";

/** The pointer's own colours, as a Mac draws it whatever the theme (pointer.mbt `pointer_edge`, `pointer_white`). */
const EDGE = "#1b1c1f";
const WHITE = "#ffffff";

type Outline = { d: string; transform?: string | undefined };

const poly = (...pts: number[]) =>
  `M${pts.reduce<string[]>((out, v, i) => (i % 2 ? out : [...out, `${v},${pts[i + 1]}`]), []).join("L")}Z`;
const rect = (x0: number, y0: number, x1: number, y1: number) =>
  poly(x0, y0, x1, y0, x1, y1, x0, y1);

/** The arrow's outline (pointer.mbt `pointer_outline`, its tip at 1, 1). */
const ARROW = poly(1, 1, 1, 17, 5, 13.5, 8, 19.5, 10.5, 18.5, 7.5, 12.5, 12.5, 12.5);
const I_BEAM = [
  rect(9.4, 3, 10.6, 17),
  rect(7.2, 2, 12.8, 3.2),
  rect(7.2, 16.8, 12.8, 18),
];
/** A two-headed arrow across the middle (`ptr_both_ways(8.6)`). */
const BOTH_WAYS = [
  rect(4.7, 9.25, 15.3, 10.75),
  poly(1.4, 10, 4.8, 6.4, 4.8, 13.6),
  poly(18.6, 10, 15.2, 13.6, 15.2, 6.4),
];
const turned = (outlines: string[], degrees: number): Outline[] =>
  outlines.map((d) => ({ d, transform: `rotate(${degrees} 10 10)` }));
const flat = (outlines: string[]): Outline[] => outlines.map((d) => ({ d }));
/** An hourglass, its middle at (cx, cy), `k` as large as a whole pointer's (`ptr_hourglass`). */
const hourglass = (cx: number, cy: number, k: number) =>
  poly(
    ...[
      -4.5, -8, 4.5, -8, 4.5, -6.6, 0.9, 0, 4.5, 6.6, 4.5, 8, -4.5, 8, -4.5, 6.6, -0.9,
      0, -4.5, -6.6,
    ].map((v, i) => (i % 2 ? cy : cx) + v * k)
  );

/** A dark shape with a white band round it (`ptr_dark`: `pointer_halo` 1 wide). */
function dark(outlines: Outline[]): ReactNode {
  return (
    <>
      {outlines.map((o, i) => (
        <path
          d={o.d}
          fill={WHITE}
          key={`halo${i}`}
          stroke={WHITE}
          strokeLinejoin="round"
          strokeWidth={2}
          transform={o.transform}
        />
      ))}
      {outlines.map((o, i) => (
        <path d={o.d} fill={EDGE} key={`fill${i}`} transform={o.transform} />
      ))}
    </>
  );
}

type Finger = [ax: number, ay: number, bx: number, by: number, r: number];

/** A hand (`ptr_hand`): its fingers (the first the thumb) and palm white in a dark edge 1.1 wide, lines between them. */
function hand(fingers: Finger[], palm: number[]): ReactNode {
  const capsules = (color: string, extra: number, key: string) =>
    fingers.map(([ax, ay, bx, by, r], i) => (
      <line
        key={`${key}${i}`}
        stroke={color}
        strokeLinecap="round"
        strokeWidth={2 * r + extra}
        x1={ax}
        x2={bx}
        y1={ay}
        y2={by}
      />
    ));
  const between = fingers.slice(2).map((b, i) => {
    const a = fingers[i + 1]!;
    const x = (a[0] + a[4] + b[0] - b[4]) / 2;
    return (
      <line
        key={`line${i}`}
        stroke={EDGE}
        strokeWidth={0.8}
        x1={x}
        x2={x}
        y1={Math.max(a[3], b[3]) + 0.5}
        y2={palm[1]! + 0.9}
      />
    );
  });
  return (
    <>
      {capsules(EDGE, 2.2, "edge")}
      <path
        d={poly(...palm)}
        fill={EDGE}
        stroke={EDGE}
        strokeLinejoin="round"
        strokeWidth={2.2}
      />
      {capsules(WHITE, 0, "white")}
      <path d={poly(...palm)} fill={WHITE} />
      {between}
    </>
  );
}

const ARROW_SHAPE = (
  <path d={ARROW} fill={WHITE} stroke={EDGE} strokeLinejoin="round" strokeWidth={1.2} />
);

/** The CSS cursor names each shape stands for (`pointer_shape_of`); any other is the arrow. */
function layers(shape: string): ReactNode {
  switch (shape) {
    case "text":
      return dark(flat(I_BEAM));
    case "vertical-text":
      return dark(turned(I_BEAM, 90));
    case "pointer":
      return hand(
        [
          [4.2, 10.6, 6.4, 13.6, 1.25],
          [8.0, 10.5, 8.0, 3.2, 1.45],
          [10.85, 11.0, 10.85, 8.6, 1.3],
          [13.4, 11.4, 13.4, 9.4, 1.25],
          [15.75, 12.0, 15.75, 10.4, 1.1],
        ],
        [
          6.55, 11.0, 16.85, 11.0, 16.85, 14.6, 15.3, 17.0, 15.3, 18.6, 8.3, 18.6, 8.3,
          17.4, 5.0, 13.4,
        ]
      );
    case "grab":
      return hand(
        [
          [4.6, 10.4, 6.8, 13.6, 1.2],
          [7.3, 11.0, 6.6, 5.4, 1.2],
          [9.8, 10.5, 9.5, 3.4, 1.25],
          [12.4, 10.5, 12.5, 3.8, 1.25],
          [14.6, 11.0, 15.0, 5.8, 1.1],
        ],
        [
          6.0, 10.4, 16.1, 10.4, 16.1, 14.2, 14.6, 16.8, 14.6, 18.4, 7.6, 18.4, 7.6,
          17.2, 4.8, 13.2,
        ]
      );
    case "grabbing":
      return hand(
        [
          [4.8, 11.4, 6.8, 13.6, 1.2],
          [7.0, 10.5, 7.0, 8.6, 1.2],
          [9.6, 10.5, 9.6, 7.8, 1.25],
          [12.2, 10.5, 12.2, 7.9, 1.25],
          [14.6, 10.8, 14.6, 8.8, 1.1],
        ],
        [
          5.8, 10.0, 15.7, 10.0, 15.7, 14.2, 14.4, 16.8, 14.4, 18.4, 7.6, 18.4, 7.6,
          17.2, 5.0, 13.4,
        ]
      );
    case "ew-resize":
    case "col-resize":
    case "e-resize":
    case "w-resize":
      return dark(flat(BOTH_WAYS));
    case "ns-resize":
    case "row-resize":
    case "n-resize":
    case "s-resize":
      return dark(turned(BOTH_WAYS, 90));
    case "nwse-resize":
    case "nw-resize":
    case "se-resize":
      return dark(turned(BOTH_WAYS, 45));
    case "nesw-resize":
    case "ne-resize":
    case "sw-resize":
      return dark(turned(BOTH_WAYS, 135));
    case "move":
    case "all-scroll":
      return dark([...flat(BOTH_WAYS), ...turned(BOTH_WAYS, 90)]);
    case "crosshair":
    case "cell":
      return dark(flat([rect(9.45, 1.8, 10.55, 18.2), rect(1.8, 9.45, 18.2, 10.55)]));
    case "not-allowed":
    case "no-drop":
      // A ring, and the bar across it from its top left.
      return (
        <>
          <circle cx={10} cy={10} fill="none" r={6.6} stroke={WHITE} strokeWidth={4} />
          <path
            d={rect(3.6, 9, 16.4, 11)}
            fill={WHITE}
            stroke={WHITE}
            strokeWidth={2}
            transform="rotate(45 10 10)"
          />
          <circle cx={10} cy={10} fill="none" r={6.6} stroke={EDGE} strokeWidth={2} />
          <path d={rect(3.6, 9, 16.4, 11)} fill={EDGE} transform="rotate(45 10 10)" />
        </>
      );
    case "wait":
      return dark(flat([hourglass(10, 10, 1)]));
    case "progress":
      return (
        <>
          {ARROW_SHAPE}
          {dark(flat([hourglass(15.5, 14.5, 0.45)]))}
        </>
      );
    default:
      return ARROW_SHAPE;
  }
}

/** Where the point a shape points with is in its square (`pointer_hotspot`): the arrow's tip, the hand's fingertip. */
export function pointerHotspot(shape: string): { x: number; y: number } {
  if (layers(shape) === ARROW_SHAPE || shape === "progress") return { x: 1, y: 1 };
  return shape === "pointer" ? { x: 8, y: 2 } : { x: 10, y: 10 };
}

/** The pointer in `shape`, its hot spot at the box's top left (the box is placed on the point). */
export function ScreenPointerShape({ shape }: { shape: string }) {
  const hot = pointerHotspot(shape);
  return (
    <svg
      aria-hidden
      data-shape={shape}
      style={{
        translate: `calc(var(--pointer) * ${-hot.x / 20}) calc(var(--pointer) * ${-hot.y / 20})`,
      }}
      viewBox="0 0 20 20"
    >
      {layers(shape)}
    </svg>
  );
}

/**
 * Where on the stage the pointer is drawn and how large, or null when it is not: hidden on the screen (`none`), not
 * said yet, no picture yet, or while this device's own mouse drives the picture (it is then the pointer, in the
 * screen's shape: `cursorOf`). `element` is the `<video>` in its parent's coordinates, its picture fitted inside it
 * (`object-fit: contain`). As large as a pointer on the screen looks at the picture's size: a 81st of its width, 11 to
 * 20 px a side (still.fail's web: a 90th of it, 10 to 18 px, for its 18-unit arrow).
 */
export function pointerPlace(
  cursor: ScreenCursor | undefined,
  element: { left: number; top: number; width: number; height: number },
  picture: { width: number; height: number },
  ownDrives: boolean
): { left: number; top: number; size: number } | null {
  if (!cursor || cursor.shape === "none" || ownDrives) return null;
  if (
    !(
      picture.width > 0 &&
      picture.height > 0 &&
      element.width > 0 &&
      element.height > 0
    )
  )
    return null;
  const scale = Math.min(
    element.width / picture.width,
    element.height / picture.height
  );
  const width = picture.width * scale;
  const height = picture.height * scale;
  return {
    left: element.left + (element.width - width) / 2 + cursor.x * width,
    top: element.top + (element.height - height) / 2 + cursor.y * height,
    size: Math.round(Math.min(20, Math.max(11, width / 81))),
  };
}

/** The CSS cursor over the picture: the screen's shape while this device drives it, else the stage's own. */
export function cursorOf(cursor: ScreenCursor | undefined, driving: boolean): string {
  return driving && cursor?.shape ? cursor.shape : "";
}
