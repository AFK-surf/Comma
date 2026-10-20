import { render } from "@testing-library/react";
import { useRef } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { gradientShimmerMotion, useGradientShimmer } from "../useGradientShimmer";
import { stubProperty } from "@comma/test-utils/stub-property";

function Shimmer({ repeat }: { repeat?: boolean }) {
  const ref = useRef<HTMLSpanElement>(null);
  useGradientShimmer(ref, { active: true, contentIdentity: "New", repeat });
  return <span ref={ref}>New</span>;
}

// The first band is measured in the next frame's shared layout read phase.
const FRAME_MS = 16;

describe("useGradientShimmer", () => {
  const sweeps: Array<{ onfinish: (() => void) | null }> = [];

  beforeEach(() => {
    sweeps.length = 0;
    vi.stubGlobal("CSS", { supports: () => true });
    stubProperty(HTMLElement.prototype, "animate", {
      value: vi.fn(() => {
        const sweep = { cancel: vi.fn(), onfinish: null, playState: "running" };
        sweeps.push(sweep);
        return sweep as unknown as Animation;
      }),
      writable: true,
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sweeps again after each pause by default", () => {
    render(<Shimmer />);
    vi.advanceTimersByTime(FRAME_MS);
    expect(sweeps).toHaveLength(1);
    sweeps[0]!.onfinish?.();
    vi.advanceTimersByTime(gradientShimmerMotion.pauseMs);
    expect(sweeps).toHaveLength(2);
  });

  it("sweeps once and rests when it does not repeat", () => {
    const { container } = render(<Shimmer repeat={false} />);
    vi.advanceTimersByTime(FRAME_MS);
    expect(sweeps).toHaveLength(1);
    sweeps[0]!.onfinish?.();
    vi.advanceTimersByTime(gradientShimmerMotion.pauseMs * 10);
    expect(sweeps).toHaveLength(1);
    expect(container.querySelector("span")).toHaveAttribute(
      "data-shimmer-ready",
      "true"
    );
  });
});
