import { describe, expect, it } from "vitest";
import { commaMascotExpressions } from "../CommaMascot";
import { eyeMorphEasing, eyePoses, interpolateEyePose } from "../eyeMorph";

describe("Comma mascot eye morph", () => {
  it("interpolates every numeric eye parameter without changing topology", () => {
    const halfway = interpolateEyePose(eyePoses.neutral, eyePoses.happy, 0.5);
    const neutralStart = eyePoses.neutral[0][0]!;
    const happyStart = eyePoses.happy[0][0]!;

    expect(halfway).toHaveLength(2);
    expect(halfway[0]).toHaveLength(12);
    expect(halfway[0][0]!.x).toBe((neutralStart.x + happyStart.x) / 2);
    expect(halfway[0][0]!.y).toBe((neutralStart.y + happyStart.y) / 2);
    expect(
      Object.values(eyePoses).every((pose) =>
        pose.every((eye) => eye.length === eyePoses.neutral[0].length)
      )
    ).toBe(true);
  });

  it("uses a visibly oval closed shape for the default eyes", () => {
    const eye = eyePoses.neutral[0];
    const width =
      Math.max(...eye.map(({ x }) => x)) - Math.min(...eye.map(({ x }) => x));
    const height =
      Math.max(...eye.map(({ y }) => y)) - Math.min(...eye.map(({ y }) => y));

    expect(eye).toHaveLength(12);
    expect(height).toBeGreaterThan(width * 1.5);
  });

  it("uses a bounded strong in-out curve for smooth retargeting", () => {
    expect(eyeMorphEasing(0)).toBe(0);
    expect(eyeMorphEasing(1)).toBe(1);
    expect(eyeMorphEasing(0.25)).toBeGreaterThanOrEqual(0);
    expect(eyeMorphEasing(0.75)).toBeLessThanOrEqual(1);
  });

  it("keeps every expression morph-compatible and exposes the expanded set", () => {
    expect(commaMascotExpressions).toEqual([
      "neutral",
      "happy",
      "squint",
      "squeezed",
      "surprised",
      "sleepy",
      "curious",
      "determined",
      "dizzy",
      "wink",
    ]);
    for (const expression of commaMascotExpressions) {
      expect(eyePoses[expression]).toHaveLength(2);
      expect(eyePoses[expression].every((eye) => eye.length === 12)).toBe(true);
    }
  });
});
