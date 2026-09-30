import { useRef } from "react";
import { act, render } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  commaReducedMotionAttribute,
  motionLoginCodeError,
} from "../../../tokens/motion";
import {
  isErrorShakeResting,
  stepErrorShake,
  useErrorShake,
  type ErrorShakeState,
} from "../useErrorShake";

const Probe = ({
  active,
  count = 2,
  replayKey,
}: {
  active: boolean;
  count?: number;
  replayKey?: string;
}) => {
  const cellsRef = useRef<Array<HTMLElement | null>>([]);
  useErrorShake({ active, cellsRef, count, replayKey });
  return (
    <div>
      {Array.from({ length: count }, (_, index) => (
        <div
          key={index}
          data-shake-cell={String(index)}
          ref={(node) => {
            cellsRef.current[index] = node;
          }}
        />
      ))}
    </div>
  );
};

const readTranslateX = (element: Element | null) => {
  const match = element?.getAttribute("style")?.match(/translate3d\(([-0-9.]+)px/);
  return match ? Number(match[1]) : 0;
};

describe("error shake spring", () => {
  it("uses the tuned login-code error tokens as the integrator inputs", () => {
    expect(motionLoginCodeError).toEqual({
      amplitude: 12,
      damping: 18,
      stagger: 8,
      stiffness: 910,
    });
  });

  it("starts from the amplitude and accelerates toward rest", () => {
    const next = stepErrorShake(
      { position: motionLoginCodeError.amplitude, velocity: 0 },
      0.016,
      motionLoginCodeError
    );

    expect(next.position).toBeLessThan(motionLoginCodeError.amplitude);
    expect(next.velocity).toBeLessThan(0);
    expect(isErrorShakeResting({ position: 12, velocity: 0 })).toBe(false);
    expect(isErrorShakeResting({ position: 0, velocity: 0 })).toBe(true);
  });

  it("oscillates through rest before settling with the tuned damping", () => {
    let state: ErrorShakeState = {
      position: motionLoginCodeError.amplitude,
      velocity: 0,
    };
    let crossedRest = false;

    for (let step = 0; step < 40; step += 1) {
      state = stepErrorShake(state, 0.016, motionLoginCodeError);
      if (state.position < 0) {
        crossedRest = true;
        break;
      }
    }

    expect(crossedRest).toBe(true);
  });
});

describe("useErrorShake", () => {
  let frameCallbacks: FrameRequestCallback[] = [];
  let now = 0;

  beforeEach(() => {
    frameCallbacks = [];
    now = 0;
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      frameCallbacks.push(callback);
      return frameCallbacks.length;
    });
    vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => {
      frameCallbacks = [];
    });
    vi.spyOn(performance, "now").mockImplementation(() => now);
  });

  afterEach(async () => {
    await act(async () => {
      document.documentElement.removeAttribute(commaReducedMotionAttribute);
      await Promise.resolve();
    });
    vi.restoreAllMocks();
  });

  const flushFrame = (deltaMs: number) => {
    now += deltaMs;
    const queued = frameCallbacks;
    frameCallbacks = [];
    act(() => {
      for (const callback of queued) {
        callback(now);
      }
    });
  };

  it("staggers later cells behind the first cell", () => {
    render(<Probe active />);

    flushFrame(4);
    const firstCellAtFourMs = readTranslateX(
      document.querySelector('[data-shake-cell="0"]')
    );
    expect(firstCellAtFourMs).toBeGreaterThan(0);
    expect(firstCellAtFourMs).toBeLessThan(motionLoginCodeError.amplitude);
    expect(readTranslateX(document.querySelector('[data-shake-cell="1"]'))).toBe(0);

    flushFrame(12);
    const firstCellAtSixteenMs = readTranslateX(
      document.querySelector('[data-shake-cell="0"]')
    );
    const secondCellAtSixteenMs = readTranslateX(
      document.querySelector('[data-shake-cell="1"]')
    );
    expect(firstCellAtSixteenMs).toBeLessThan(secondCellAtSixteenMs);
    expect(secondCellAtSixteenMs).toBeLessThan(motionLoginCodeError.amplitude);
  });

  it("advances each started cell to its own staggered phase on the first frame", () => {
    render(<Probe active count={3} />);

    flushFrame(17);
    const positions = Array.from({ length: 3 }, (_, index) =>
      readTranslateX(document.querySelector(`[data-shake-cell="${index}"]`))
    );

    expect(positions[0]).toBeLessThan(positions[1]!);
    expect(positions[1]).toBeLessThan(positions[2]!);
  });

  it("leaves cells still when reduced motion is enabled", () => {
    document.documentElement.setAttribute(commaReducedMotionAttribute, "true");
    render(<Probe active />);

    flushFrame(16);
    expect(readTranslateX(document.querySelector('[data-shake-cell="0"]'))).toBe(0);
    expect(readTranslateX(document.querySelector('[data-shake-cell="1"]'))).toBe(0);
  });
});
