import { afterEach, describe, expect, it } from "vitest";
import { act, render } from "@comma/test-utils/render";
import { NativeSurfaceSuppressor } from "../NativeSurfaceSuppressor";
import {
  claimNativeSurfaceSuppression,
  isNativeSurfaceSuppressed,
  releaseNativeSurfaceSuppression,
  useNativeSurfaceSuppressed,
} from "../nativeSurfaceSuppression";

afterEach(() => {
  // Claims are module-level; drop any a test left behind.
  releaseNativeSurfaceSuppression("a");
  releaseNativeSurfaceSuppression("b");
});

describe("nativeSurfaceSuppression", () => {
  it("is suppressed while any claim is held", () => {
    expect(isNativeSurfaceSuppressed()).toBe(false);
    claimNativeSurfaceSuppression("a");
    claimNativeSurfaceSuppression("b");
    releaseNativeSurfaceSuppression("a");
    expect(isNativeSurfaceSuppressed()).toBe(true);
    releaseNativeSurfaceSuppression("b");
    expect(isNativeSurfaceSuppressed()).toBe(false);
  });

  it("notifies subscribers only when the resolved state flips", () => {
    const seen: boolean[] = [];
    const Probe = () => {
      seen.push(useNativeSurfaceSuppressed());
      return null;
    };
    render(<Probe />);
    expect(seen).toEqual([false]);
    act(() => claimNativeSurfaceSuppression("a"));
    act(() => claimNativeSurfaceSuppression("b")); // no flip, no render
    expect(seen).toEqual([false, true]);
    act(() => releaseNativeSurfaceSuppression("b")); // still held by "a"
    expect(seen).toEqual([false, true]);
    act(() => releaseNativeSurfaceSuppression("a"));
    expect(seen).toEqual([false, true, false]);
  });

  it("NativeSurfaceSuppressor holds a claim for its mount lifetime", () => {
    const view = render(<NativeSurfaceSuppressor />);
    expect(isNativeSurfaceSuppressed()).toBe(true);
    view.unmount();
    expect(isNativeSurfaceSuppressed()).toBe(false);
  });
});
