import { useRef } from "react";
import { act, render } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { afterEach, expect, it, vi } from "vitest";
import { useNativeRecorderWindow } from "../components/useNativeRecorderWindow";

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it("keeps the native envelope until the actual resize animation finishes", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) =>
    setTimeout(() => callback(performance.now()), 16)
  );
  vi.stubGlobal("cancelAnimationFrame", clearTimeout);
  const layoutWindow = vi.fn(async () => {});
  installNativeBridgeMock({ meetingRecorder: { layoutWindow } });
  let height = 56;
  let animations: Animation[] = [];
  function Probe({ compact = false }: { compact?: boolean }) {
    const root = useRef<HTMLDivElement>(null);
    useNativeRecorderWindow(root, true);
    return (
      <div ref={root}>
        <div
          className="comma-recorder-motion"
          data-compact={compact || undefined}
          style={
            {
              "--meeting-recorder-width": "370px",
              "--meeting-recorder-compact-width": "227px",
            } as React.CSSProperties
          }
        >
          <div
            data-slot="meeting-recorder"
            data-phase="recording"
            ref={(card) => {
              if (!card) return;
              Object.defineProperty(card, "offsetHeight", {
                configurable: true,
                get: () => height,
              });
              card.getBoundingClientRect = () =>
                ({ width: 370, height, x: 0, y: 0 }) as DOMRect;
              card.getAnimations = () => animations;
            }}
          />
        </div>
      </div>
    );
  }
  const view = render(<Probe />);
  await act(async () => {
    await vi.advanceTimersByTimeAsync(240);
  });
  expect(layoutWindow).toHaveBeenLastCalledWith({ width: 418, height: 104 });

  let finish!: () => void;
  animations = [
    {
      finished: new Promise<void>((resolve) => {
        finish = resolve;
      }),
      effect: { getComputedTiming: () => ({ endTime: 480 }) },
    } as unknown as Animation,
  ];
  view.rerender(<Probe compact />);
  height = 50; // An intermediate CSS frame, not the compact endpoint.
  await act(async () => {
    await vi.advanceTimersByTimeAsync(260);
  });
  expect(layoutWindow).toHaveBeenLastCalledWith({ width: 418, height: 104 });

  height = 42;
  await act(async () => {
    finish();
    await vi.advanceTimersByTimeAsync(32);
  });
  expect(layoutWindow).toHaveBeenLastCalledWith({ width: 275, height: 90 });
});
