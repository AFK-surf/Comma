import { renderHook, waitFor } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { motionDurationMs, useLeaving } from "../useLeaving";

describe("useLeaving", () => {
  it("hands back the value just left for the duration, then nothing", async () => {
    const { rerender, result } = renderHook(({ value }) => useLeaving(value, 40), {
      initialProps: { value: "review" },
    });
    expect(result.current).toBeUndefined();

    rerender({ value: "done" });
    expect(result.current).toBe("review");

    await waitFor(() => expect(result.current).toBeUndefined());
  });

  it("follows a second change inside the window and never reports the current value", () => {
    const { rerender, result } = renderHook(({ value }) => useLeaving(value, 1000), {
      initialProps: { value: 1 },
    });
    rerender({ value: 2 });
    expect(result.current).toBe(1);
    rerender({ value: 3 });
    expect(result.current).toBe(2);
    rerender({ value: 3 });
    expect(result.current).toBe(2);
  });

  it("reads a duration token off the root and falls back without one", () => {
    expect(motionDurationMs("--motion-duration-state-swap-exit", 100)).toBe(100);
    document.documentElement.style.setProperty(
      "--motion-duration-state-swap-exit",
      "250ms"
    );
    expect(motionDurationMs("--motion-duration-state-swap-exit", 100)).toBe(250);
    document.documentElement.style.setProperty(
      "--motion-duration-state-swap-exit",
      "0.3s"
    );
    expect(motionDurationMs("--motion-duration-state-swap-exit", 100)).toBe(300);
    document.documentElement.style.removeProperty("--motion-duration-state-swap-exit");
  });
});
