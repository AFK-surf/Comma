import { act, render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { RailFoldPhase } from "../railFoldSpring";

// Shuts a fold, opens it again 90ms in, and reads what it painted at `ms`.
// Each run loads the module afresh: the folds share one frame loop, and one
// run's loop must not wait on another run's clock.
async function progressAt(ms: number, frameMs: number) {
  vi.resetModules();
  const { installUiClock } = await import("@comma/ui/clock");
  const { createVirtualUiClock } = await import("@comma/ui/clock/virtual");
  const { useRailFoldSpring } = await import("../railFoldSpring");
  const log: { progress: number; phase: RailFoldPhase }[] = [];
  function Fold({ shut }: { shut: boolean }) {
    useRailFoldSpring(shut, {
      span: () => 240,
      write: (progress, phase) => log.push({ progress, phase }),
    });
    return null;
  }
  const clock = createVirtualUiClock({ frameMs });
  const restore = installUiClock(clock);
  try {
    const view = render(<Fold shut={false} />);
    view.rerender(<Fold shut />);
    act(() => clock.advance(90));
    view.rerender(<Fold shut={false} />);
    act(() => clock.advance(ms - 90));
    view.unmount();
    return log.at(-1);
  } finally {
    restore();
  }
}

describe("useRailFoldSpring", () => {
  it("folds to the same place at a moment whatever the frame rate before it", async () => {
    const at60fps = await progressAt(200, 1000 / 60);
    expect(at60fps?.phase).toBe("spring");
    expect(await progressAt(200, 100)).toEqual(at60fps);
    // One frame, at 200ms: straight to the moment.
    expect(await progressAt(200, 200)).toEqual(at60fps);
  });
});
