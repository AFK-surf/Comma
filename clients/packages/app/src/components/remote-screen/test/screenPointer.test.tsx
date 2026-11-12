import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
import { ScreenPointerShape, pointerHotspot } from "../ScreenPointer";

afterEach(cleanup);

// The shapes Windows' desktop says (systems/station/native/desktop-screen/src/cursor.rs), as the Mac helper says its
// own: each is drawn as itself, and an unknown name as the arrow.
const WINDOWS_SHAPES = [
  "text",
  "pointer",
  "ew-resize",
  "ns-resize",
  "nwse-resize",
  "nesw-resize",
  "move",
  "crosshair",
  "not-allowed",
  "wait",
  "progress",
];

/** The picture drawn for `shape`. */
const drawn = (shape: string) =>
  render(<ScreenPointerShape shape={shape} />).container.querySelector("svg")!
    .innerHTML;

it("draws each shape the stations say in its own picture, an unknown one as the arrow", () => {
  const arrow = drawn("default");
  const pictures = WINDOWS_SHAPES.map(drawn);
  for (const [i, picture] of pictures.entries())
    expect(picture, WINDOWS_SHAPES[i]).not.toBe(arrow);
  expect(new Set(pictures).size).toBe(WINDOWS_SHAPES.length);
  expect(drawn("zoom-in")).toBe(arrow);
  // Where each points from: the arrow's tip, the hand's fingertip, the middle of the rest.
  expect(pointerHotspot("default")).toEqual({ x: 1, y: 1 });
  expect(pointerHotspot("progress")).toEqual({ x: 1, y: 1 });
  expect(pointerHotspot("pointer")).toEqual({ x: 8, y: 2 });
  expect(pointerHotspot("text")).toEqual({ x: 10, y: 10 });
});
