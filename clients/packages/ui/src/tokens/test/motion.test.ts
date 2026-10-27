// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import {
  commaReducedMotionAttribute,
  cssTimeMs,
  isReducedMotionEnabled,
  loopEasing,
  subscribeToReducedMotion,
} from "../motion";

describe("reduced motion preference", () => {
  afterEach(() => {
    document.documentElement.removeAttribute(commaReducedMotionAttribute);
    vi.unstubAllGlobals();
  });

  it("combines the system preference with Comma's manual setting", () => {
    const matchMedia = vi.fn(() => ({ matches: false }));
    vi.stubGlobal("matchMedia", matchMedia);

    expect(isReducedMotionEnabled()).toBe(false);

    document.documentElement.setAttribute(commaReducedMotionAttribute, "true");
    expect(isReducedMotionEnabled()).toBe(true);

    document.documentElement.setAttribute(commaReducedMotionAttribute, "false");
    matchMedia.mockReturnValue({ matches: true });
    expect(isReducedMotionEnabled()).toBe(true);
  });

  it("subscribes to system and manual preference changes", async () => {
    const changeListeners = new Set<() => void>();
    const mediaQuery = {
      addEventListener: vi.fn((_event: string, listener: () => void) => {
        changeListeners.add(listener);
      }),
      matches: false,
      removeEventListener: vi.fn((_event: string, listener: () => void) => {
        changeListeners.delete(listener);
      }),
    };
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => mediaQuery)
    );
    const onChange = vi.fn();
    const unsubscribe = subscribeToReducedMotion(onChange);

    document.documentElement.setAttribute(commaReducedMotionAttribute, "true");
    await vi.waitFor(() => expect(onChange).toHaveBeenCalledOnce());

    changeListeners.forEach((listener) => listener());
    expect(onChange).toHaveBeenCalledTimes(2);

    unsubscribe();
    expect(mediaQuery.removeEventListener).toHaveBeenCalledWith("change", onChange);
  });
});

describe("CSS time read back from a custom property", () => {
  it("keeps milliseconds whether or not minified CSS rewrote them as seconds", () => {
    expect(cssTimeMs("180ms")).toBe(180);
    expect(cssTimeMs(" .18s")).toBe(180);
  });
});

describe("loop easing", () => {
  it("holds each value of the curve for a 60 Hz frame, from rest to rest", () => {
    const easing = loopEasing("cubic-bezier(0.4, 0, 0.2, 1)", 1000);
    const holds = [...easing.matchAll(/(-?[\d.]+) ([\d.]+)% ([\d.]+)%/g)].map((hold) =>
      hold.slice(1).map(Number)
    );
    expect(holds).toHaveLength(60);
    expect(holds[0]).toEqual([0, 0, holds[1]![1]]);
    expect(holds.at(-1)).toEqual([1, holds.at(-1)![1], 100]);
    // Slow at the ends, fastest in the middle, never back.
    const values = holds.map(([value]) => value!);
    expect(
      values.every((value, index) => index === 0 || value >= values[index - 1]!)
    ).toBe(true);
    expect(values[30]! - values[29]!).toBeGreaterThan(values[1]! - values[0]!);
  });
});
