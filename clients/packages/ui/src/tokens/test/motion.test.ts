// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import {
  commaReducedMotionAttribute,
  isReducedMotionEnabled,
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
