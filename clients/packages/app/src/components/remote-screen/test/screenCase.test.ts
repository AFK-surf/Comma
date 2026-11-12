import { describe, expect, it } from "vitest";
import { screenCaseOf } from "../screenCase";

// A foldable's two panels as its station tells them: the cover, upright, and the inner panel, whose framebuffer stands
// upright with its UI on its side.
const cover = {
  key: "cover",
  width: 1398,
  height: 2034,
  frame: { width: 500, height: 710 },
  screen: { x: 17, y: 16, width: 466, height: 678 },
  corners: [],
  buttons: [
    {
      name: "power",
      x: 497,
      y: 100,
      width: 6,
      height: 80,
      dx: -3,
      dy: 0,
      page: 12,
      usage: 48,
    },
  ],
};
const curve = (reach: number, k: number) => ({ reach, k });
const inner = { ...cover, key: "inner", width: 2007, height: 2853, buttons: [] };

describe("a simulator's case as it stands", () => {
  it("is the case of the panel the picture is of, none for a picture no panel has the shape of", () => {
    expect(screenCaseOf([cover, inner], 1398 / 2034, 0)?.key).toBe("cover");
    expect(screenCaseOf([cover, inner], 2853 / 2007, 90)?.key).toBe("inner");
    expect(screenCaseOf([cover, inner], 1, 0)).toBeUndefined();
  });

  it("turns with the picture: a quarter clockwise takes the right side to the bottom", () => {
    const turned = screenCaseOf([cover], 2034 / 1398, 90)!;
    expect(turned.turn).toBe(1);
    expect(turned.frame).toEqual({ width: 710, height: 500 });
    expect(turned.screen).toEqual({ x: 16, y: 17, width: 678, height: 466 });
    // The side button, on the right as it stood, is on the bottom, pressed upward.
    expect(turned.buttons[0]).toMatchObject({
      at: { x: 710 - 100 - 80, y: 497, width: 80, height: 6 },
      dy: -3,
      usage: { page: 12, usage: 48 },
    });
    // The picture's corners go round with it, cut as far in as the case covers them (0.8 of the panel's own).
    const cornered = screenCaseOf(
      [{ ...cover, corners: [0.1, 0.2, 0.3, 0.4] }],
      2034 / 1398,
      90
    )!;
    expect(cornered.corners.map((c) => Math.round(c * 10) / 10)).toEqual(
      [0.4, 0.1, 0.2, 0.3].map((share) => Math.round(share * 466 * 0.8 * 10) / 10)
    );
    // Corners its mask says as superellipses are the panel's own, each shape going round with its corner.
    const curved = screenCaseOf(
      [
        {
          ...cover,
          curves: [curve(0.1, 1), curve(0.2, 1.2), curve(0.3, 1.4), curve(0.4, 1.6)],
        },
      ],
      2034 / 1398,
      90
    )!;
    expect(curved.corners.map((c) => Math.round(c * 10) / 10)).toEqual(
      [0.4, 0.1, 0.2, 0.3].map((share) => Math.round(share * 466 * 10) / 10)
    );
    expect(curved.shapes).toEqual([1.6, 1, 1.2, 1.4]);
    // A report the picture does not agree with is not taken: an upright picture stands upright.
    expect(screenCaseOf([cover], 1398 / 2034, 90)!.turn).toBe(0);
  });
});
