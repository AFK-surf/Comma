import { describe, expect, it } from "vitest";
import {
  boundPointerReorderTranslation,
  pointerReorderOverdragCap,
} from "../pointerReorder";

describe("pointer reorder", () => {
  it("bounds the pointer-drag translation to the row band with damped overshoot", () => {
    const initialTops = new Map([
      ["document", 100],
      ["news", 128],
      ["tasks", 156],
    ]);

    // Inside the band the translation tracks the pointer 1:1.
    expect(boundPointerReorderTranslation(10, initialTops, 128)).toBe(10);
    expect(boundPointerReorderTranslation(-28, initialTops, 128)).toBe(-28);
    expect(boundPointerReorderTranslation(56, initialTops, 100)).toBe(56);

    // Past the band the overshoot is damped, monotonic, and capped so the
    // scroll viewport's scrollable overflow stays bounded.
    const nearOvershoot = boundPointerReorderTranslation(70, initialTops, 100);
    const farOvershoot = boundPointerReorderTranslation(500, initialTops, 100);
    expect(nearOvershoot).toBeGreaterThan(56);
    expect(nearOvershoot).toBeLessThan(70);
    expect(farOvershoot).toBeGreaterThan(nearOvershoot);
    expect(farOvershoot).toBeLessThanOrEqual(56 + pointerReorderOverdragCap);

    const farUndershoot = boundPointerReorderTranslation(-500, initialTops, 156);
    expect(farUndershoot).toBeLessThan(-56);
    expect(farUndershoot).toBeGreaterThanOrEqual(-56 - pointerReorderOverdragCap);

    // A lone row stays pinned within the overshoot cap.
    expect(
      Math.abs(boundPointerReorderTranslation(90, new Map([["only", 30]]), 30))
    ).toBeLessThanOrEqual(pointerReorderOverdragCap);
  });
});
