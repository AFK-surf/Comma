import { describe, expect, it } from "vitest";
import { materialKeyframes } from "../materialKeyframes";

const offsets = (frames: Keyframe[]) => frames.map((frame) => frame.offset);

describe("flight material keyframes", () => {
  it("holds the source material, then crosses to the bubble's", () => {
    expect(materialKeyframes("white", "blue", 0.1, 0.3)).toEqual([
      { offset: 0, backgroundColor: "white" },
      { offset: 0.1, backgroundColor: "white" },
      { offset: 0.3, backgroundColor: "blue" },
      { offset: 1, backgroundColor: "blue" },
    ]);
  });

  it("gives no zero-length segment when the crossing starts or ends at an edge", () => {
    const fromStart = materialKeyframes("white", "blue", 0, 0.168);
    expect(fromStart).toEqual([
      { offset: 0, backgroundColor: "white" },
      { offset: 0.168, backgroundColor: "blue" },
      { offset: 1, backgroundColor: "blue" },
    ]);
    expect(offsets(materialKeyframes("white", "blue", 0.5, 1))).toEqual([0, 0.5, 1]);
    expect(materialKeyframes("white", "blue", 1, 1).at(-1)).toEqual({
      offset: 1,
      backgroundColor: "blue",
    });
  });
});
