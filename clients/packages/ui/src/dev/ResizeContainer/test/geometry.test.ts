import { describe, expect, it } from "vitest";
import {
  adaptRectToCanvas,
  applyMove,
  applyResize,
  centerRect,
  clampRectToCanvas,
  NO_GUIDES,
  snapRectToCenter,
  toPixelRect,
  toRelativeRect,
  type Rect,
  type Size,
} from "../geometry";

const minSize: Size = { width: 80, height: 60 };

describe("clampRectToCanvas", () => {
  it("keeps a rect that already fits untouched", () => {
    const rect: Rect = { x: 20, y: 30, width: 200, height: 150 };
    expect(clampRectToCanvas(rect, { width: 800, height: 600 }, minSize)).toEqual(rect);
  });

  it("nudges toward the top-left before shrinking", () => {
    const rect: Rect = { x: 700, y: 500, width: 200, height: 150 };
    expect(clampRectToCanvas(rect, { width: 800, height: 600 }, minSize)).toEqual({
      x: 600,
      y: 450,
      width: 200,
      height: 150,
    });
  });

  it("shrinks only when the rect is larger than the canvas", () => {
    const rect: Rect = { x: 50, y: 40, width: 900, height: 700 };
    expect(clampRectToCanvas(rect, { width: 800, height: 600 }, minSize)).toEqual({
      x: 0,
      y: 0,
      width: 800,
      height: 600,
    });
  });
});

describe("toRelativeRect / toPixelRect", () => {
  it("round-trips between pixel and relative space", () => {
    const canvas: Size = { width: 1000, height: 500 };
    const rect: Rect = { x: 100, y: 50, width: 400, height: 200 };
    const relative = toRelativeRect(rect, canvas);
    expect(relative).toEqual({ x: 0.1, y: 0.1, width: 0.4, height: 0.4 });
    expect(toPixelRect(relative, canvas)).toEqual(rect);
  });

  it("returns zeros for a zero-sized canvas", () => {
    expect(
      toRelativeRect({ x: 1, y: 1, width: 1, height: 1 }, { width: 0, height: 0 })
    ).toEqual({
      x: 0,
      y: 0,
      width: 0,
      height: 0,
    });
  });
});

describe("adaptRectToCanvas", () => {
  const prev: Size = { width: 1000, height: 800 };

  it("keeps pixel size and drifts top-left when the canvas shrinks", () => {
    const rect: Rect = { x: 700, y: 600, width: 250, height: 180 };
    const next: Size = { width: 800, height: 600 };
    expect(adaptRectToCanvas(rect, prev, next, "pixel", minSize)).toEqual({
      x: 550,
      y: 420,
      width: 250,
      height: 180,
    });
  });

  it("scales proportionally in relative mode", () => {
    const rect: Rect = { x: 100, y: 80, width: 500, height: 400 };
    const next: Size = { width: 500, height: 400 };
    expect(adaptRectToCanvas(rect, prev, next, "relative", minSize)).toEqual({
      x: 50,
      y: 40,
      width: 250,
      height: 200,
    });
  });

  it("falls back to clamping when there is no previous canvas size", () => {
    const rect: Rect = { x: 100, y: 80, width: 500, height: 400 };
    const next: Size = { width: 400, height: 300 };
    expect(
      adaptRectToCanvas(rect, { width: 0, height: 0 }, next, "relative", minSize)
    ).toEqual({ x: 0, y: 0, width: 400, height: 300 });
  });
});

describe("applyMove", () => {
  const canvas: Size = { width: 800, height: 600 };
  const rect: Rect = { x: 100, y: 100, width: 200, height: 150 };

  it("translates within bounds", () => {
    expect(applyMove(rect, 50, -40, canvas)).toEqual({
      x: 150,
      y: 60,
      width: 200,
      height: 150,
    });
  });

  it("stops at the canvas edges", () => {
    expect(applyMove(rect, 10_000, 10_000, canvas)).toEqual({
      x: 600,
      y: 450,
      width: 200,
      height: 150,
    });
    expect(applyMove(rect, -10_000, -10_000, canvas)).toEqual({
      x: 0,
      y: 0,
      width: 200,
      height: 150,
    });
  });

  it("locks to the dominant axis with the Shift option", () => {
    expect(applyMove(rect, 60, 20, canvas, { lockAxis: true })).toEqual({
      x: 160,
      y: 100,
      width: 200,
      height: 150,
    });
    expect(applyMove(rect, 15, -40, canvas, { lockAxis: true })).toEqual({
      x: 100,
      y: 60,
      width: 200,
      height: 150,
    });
  });
});

describe("applyResize", () => {
  const canvas: Size = { width: 800, height: 600 };
  const rect: Rect = { x: 100, y: 100, width: 200, height: 150 };

  it("grows from the bottom-right corner", () => {
    expect(
      applyResize(
        rect,
        { left: false, right: true, top: false, bottom: true },
        60,
        40,
        canvas,
        minSize
      )
    ).toEqual({ x: 100, y: 100, width: 260, height: 190 });
  });

  it("moves the origin when dragging the top-left corner", () => {
    expect(
      applyResize(
        rect,
        { left: true, right: false, top: true, bottom: false },
        -30,
        -20,
        canvas,
        minSize
      )
    ).toEqual({ x: 70, y: 80, width: 230, height: 170 });
  });

  it("respects the minimum size from the left edge", () => {
    const result = applyResize(
      rect,
      { left: true, right: false, top: false, bottom: false },
      10_000,
      0,
      canvas,
      minSize
    );
    expect(result.width).toBe(minSize.width);
    expect(result.x).toBe(rect.x + rect.width - minSize.width);
  });

  it("does not extend past the canvas from the right edge", () => {
    const result = applyResize(
      rect,
      { left: false, right: true, top: false, bottom: false },
      10_000,
      0,
      canvas,
      minSize
    );
    expect(result.width).toBe(canvas.width - rect.x);
  });

  it("keeps the center fixed with the fromCenter option (right edge)", () => {
    // center = (200, 175); dragging the right edge out by 30 grows both sides.
    const result = applyResize(
      rect,
      { left: false, right: true, top: false, bottom: false },
      30,
      0,
      canvas,
      minSize,
      { fromCenter: true }
    );
    expect(result).toEqual({ x: 70, y: 100, width: 260, height: 150 });
    expect(result.x + result.width / 2).toBe(rect.x + rect.width / 2);
  });

  it("scales symmetrically from a corner with the fromCenter option", () => {
    const result = applyResize(
      rect,
      { left: false, right: true, top: false, bottom: true },
      40,
      30,
      canvas,
      minSize,
      { fromCenter: true }
    );
    expect(result).toEqual({ x: 60, y: 70, width: 280, height: 210 });
    expect(result.x + result.width / 2).toBe(rect.x + rect.width / 2);
    expect(result.y + result.height / 2).toBe(rect.y + rect.height / 2);
  });
});

describe("centerRect", () => {
  const canvas: Size = { width: 800, height: 600 };

  it("centers a rect that fits", () => {
    const result = centerRect({ x: 10, y: 20, width: 200, height: 100 }, canvas);
    expect(result).toEqual({ x: 300, y: 250, width: 200, height: 100 });
    expect(result.x + result.width / 2).toBe(400);
    expect(result.y + result.height / 2).toBe(300);
  });

  it("shrinks to fit while staying centered", () => {
    const result = centerRect({ x: 0, y: 0, width: 1000, height: 700 }, canvas);
    expect(result).toEqual({ x: 0, y: 0, width: 800, height: 600 });
  });
});

describe("snapRectToCenter", () => {
  const canvas: Size = { width: 800, height: 600 };

  it("snaps both axes and reports both guides when near the center", () => {
    // canvas center = (400, 300); rect center is 3px/4px off on each axis.
    const rect: Rect = { x: 303, y: 154, width: 200, height: 300 };
    const { rect: snapped, guides } = snapRectToCenter(rect, canvas, 6);
    expect(snapped).toEqual({ x: 300, y: 150, width: 200, height: 300 });
    expect(snapped.x + snapped.width / 2).toBe(400);
    expect(snapped.y + snapped.height / 2).toBe(300);
    expect(guides).toEqual({ vertical: true, horizontal: true });
  });

  it("snaps only the axis within threshold", () => {
    const rect: Rect = { x: 303, y: 80, width: 200, height: 200 };
    const { rect: snapped, guides } = snapRectToCenter(rect, canvas, 6);
    expect(snapped.x).toBe(300);
    expect(snapped.y).toBe(80);
    expect(guides).toEqual({ vertical: true, horizontal: false });
  });

  it("returns the shared NO_GUIDES reference when nothing is close", () => {
    const rect: Rect = { x: 0, y: 0, width: 100, height: 100 };
    const { rect: snapped, guides } = snapRectToCenter(rect, canvas, 6);
    expect(snapped).toEqual(rect);
    expect(guides).toBe(NO_GUIDES);
  });
});
