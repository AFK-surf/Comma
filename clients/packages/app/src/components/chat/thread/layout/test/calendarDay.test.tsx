import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

// Local times, so the test holds in any time zone.
const lastNight = new Date(2026, 9, 22, 23, 32).getTime();
const midnight = new Date(2026, 9, 23).getTime();

// Each run loads the module afresh: its day check is shared by the renderer.
async function openTranscript() {
  vi.resetModules();
  const { installUiClock } = await import("@comma/ui/clock");
  const { createVirtualUiClock } = await import("@comma/ui/clock/virtual");
  const { useStartOfToday } = await import("../calendarDay");
  const { formatConversationTimestamp } = await import("../messageTimestamp");
  const clock = createVirtualUiClock({ start: lastNight });
  const restore = installUiClock(clock);
  let renders = 0;
  const view = renderHook(() => {
    renders += 1;
    const today = useStartOfToday();
    return {
      today,
      isToday: formatConversationTimestamp(lastNight, "en", today)?.isToday,
    };
  });
  return {
    clock,
    renders: () => renders,
    view,
    close: () => {
      view.unmount();
      restore();
    },
  };
}

describe("useStartOfToday", () => {
  it("stops calling last night's message today once the transcript stays open past midnight", async () => {
    const { clock, view, close } = await openTranscript();
    try {
      expect(view.result.current.isToday).toBe(true);
      act(() => clock.advance(midnight - lastNight + 60_000));
      expect(view.result.current).toEqual({ today: midnight, isToday: false });
    } finally {
      close();
    }
  });

  it("re-renders once when the day changes, not on every check", async () => {
    const { clock, renders, close } = await openTranscript();
    try {
      const opened = renders();
      act(() => clock.advance(midnight - lastNight - 60_000));
      expect(renders()).toBe(opened);
      act(() => clock.advance(2 * 60 * 60_000));
      expect(renders()).toBe(opened + 1);
    } finally {
      close();
    }
  });
});
