import { describe, expect, it } from "vitest";
import { commaMascotCorePoints, commaMascotOuterPoints } from "../mascotGeometry";

const bounds = (points: readonly { x: number; y: number }[]) => ({
  maxX: Math.max(...points.map(({ x }) => x)),
  maxY: Math.max(...points.map(({ y }) => y)),
  minX: Math.min(...points.map(({ x }) => x)),
  minY: Math.min(...points.map(({ y }) => y)),
});

describe("Comma mascot traced geometry", () => {
  it("preserves the original mark bounds and asymmetric inner tail", () => {
    expect(bounds(commaMascotOuterPoints)).toEqual({
      maxX: 214,
      maxY: 214,
      minX: 18,
      minY: 18,
    });
    expect(bounds(commaMascotCorePoints)).toEqual({
      maxX: 198.6,
      maxY: 207.7,
      minX: 128.6,
      minY: 126.5,
    });
    expect(commaMascotCorePoints).toContainEqual({ x: 146.1, y: 206.65 });
  });
});
