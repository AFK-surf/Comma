import { describe, expect, it } from "vitest";
import { resolveOverlayLabelCollisions } from "../label-collisions";

describe("resolveOverlayLabelCollisions", () => {
  it("moves an overlapping label to the nearest available lane", () => {
    const rect = { height: 18, left: 80, top: 50, width: 72 };
    const shifts = resolveOverlayLabelCollisions({
      items: [
        { axis: "horizontal", rect },
        { axis: "horizontal", rect },
      ],
      viewport: { height: 200, left: 0, top: 0, width: 320 },
    });

    expect(shifts[0]).toEqual({ x: 0, y: 0 });
    expect(shifts[1]?.x).toBe(0);
    expect(Math.abs(shifts[1]?.y ?? 0)).toBe(24);
  });

  it("keeps labels away from reserved badges and viewport edges", () => {
    const [shift] = resolveOverlayLabelCollisions({
      items: [
        {
          axis: "vertical",
          rect: { height: 18, left: 2, top: 40, width: 64 },
        },
      ],
      obstacles: [{ height: 26, left: 0, top: 35, width: 80 }],
      viewport: { height: 160, left: 0, top: 0, width: 240 },
    });

    expect(shift?.x).toBeGreaterThan(0);
  });
});
