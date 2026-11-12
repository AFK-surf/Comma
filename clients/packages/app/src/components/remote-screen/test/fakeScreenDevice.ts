import type { ScreenDeviceShape, ScreenStreamCapabilities } from "../screenDevice";

/** A made-up phone: even corners, a thin frame, wider at top and bottom. */
export const fakePhone: readonly [ScreenDeviceShape] = [
  {
    frame: { width: 420, height: 880 },
    screen: { x: 15, y: 20, width: 390, height: 840 },
    corners: [55, 55, 55, 55],
  },
];

/**
 * A made-up foldable: its cover, nearly square along the hinge side, and the
 * larger panel inside.
 */
export const fakeFoldable: readonly [ScreenDeviceShape, ScreenDeviceShape] = [
  {
    frame: { width: 500, height: 710 },
    screen: { x: 16, y: 16, width: 468, height: 678 },
    corners: [10, 75, 75, 10],
  },
  {
    frame: { width: 1290, height: 1820 },
    screen: { x: 20, y: 20, width: 1250, height: 1780 },
    corners: [130, 130, 130, 130],
  },
];

export const fakeDeviceCapabilities = (
  shapes: ScreenStreamCapabilities["shapes"]
): ScreenStreamCapabilities => ({
  input: "touch",
  buttons: ["home", "lock", "volume", "rotate"],
  shapes,
});

/**
 * A canvas that looks like no real app: each corner has its own color and the
 * top edge says so, so that any turn can be told by eye.
 */
export function fakePicture(width: number, height: number): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d")!;
  const corner = Math.round(Math.min(width, height) / 4);
  context.fillStyle = "#f4f5f7";
  context.fillRect(0, 0, width, height);
  for (const [color, x, y] of [
    ["#e5484d", 0, 0],
    ["#30a46c", width - corner, 0],
    ["#205bff", width - corner, height - corner],
    ["#f5a623", 0, height - corner],
  ] as const) {
    context.fillStyle = color;
    context.fillRect(x, y, corner, corner);
  }
  context.fillStyle = "#1c1c1e";
  context.font = `${corner / 2}px sans-serif`;
  context.textAlign = "center";
  context.fillText("TOP", width / 2, corner / 2);
  return canvas;
}

/** Turns the canvas a quarter clockwise, as a source that turns its own frames does. */
export function turnFakePicture(canvas: HTMLCanvasElement) {
  const before = document.createElement("canvas");
  before.width = canvas.width;
  before.height = canvas.height;
  before.getContext("2d")!.drawImage(canvas, 0, 0);
  canvas.width = before.height;
  canvas.height = before.width;
  const context = canvas.getContext("2d")!;
  context.translate(canvas.width, 0);
  context.rotate(Math.PI / 2);
  context.drawImage(before, 0, 0);
  context.setTransform(1, 0, 0, 1, 0, 0);
}
