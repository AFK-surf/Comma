import { describe, expect, it } from "vitest";
import { recorderWindowBounds } from "../recorder-window-geometry";

const area = { x: 0, y: 38, width: 1512, height: 944 };
describe("recorder native window footprint", () => {
  it("uses the compact or expanded card envelope, not the display work area", () => {
    const center = { x: 756, y: 130 };
    expect(recorderWindowBounds(center, { width: 243, height: 58 }, area)).toEqual({
      x: 635,
      y: 101,
      width: 243,
      height: 58,
    });
    const expanded = recorderWindowBounds(center, { width: 386, height: 72 }, area);
    expect(expanded).toEqual({ x: 563, y: 94, width: 386, height: 72 });
    expect(expanded.x + expanded.width / 2).toBe(center.x);
  });
  it("adds menu space below the card without moving its screen anchor", () => {
    const center = { x: 756, y: 130 };
    const card = recorderWindowBounds(center, { width: 386, height: 72 }, area);
    const menu = recorderWindowBounds(
      center,
      { width: 386, height: 252, anchorY: 36 },
      area
    );
    expect(menu.y).toBe(card.y);
    expect(menu.height).toBe(252);
  });
  it("returns offscreen drags to the nearest work-area edge, including negative-origin monitors", () => {
    const left = { x: -1920, y: 0, width: 1920, height: 1080 };
    expect(
      recorderWindowBounds({ x: -1930, y: 1090 }, { width: 386, height: 72 }, left)
    ).toEqual({ x: -1920, y: 1008, width: 386, height: 72 });
    expect(
      recorderWindowBounds(
        { x: -1930, y: 1090 },
        { width: 386, height: 72 },
        left,
        false
      ).x
    ).toBeLessThan(left.x);
  });
});
