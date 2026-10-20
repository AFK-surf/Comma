import { useRef } from "react";
import { act, render } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { afterEach, expect, it, vi } from "vitest";
import { useNativeRecorderWindow } from "../components/useNativeRecorderWindow";

afterEach(() => {
  vi.unstubAllGlobals();
});

it("keeps the expanded native envelope while the card hovers in and out", async () => {
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) =>
    setTimeout(() => callback(performance.now()), 16)
  );
  vi.stubGlobal("cancelAnimationFrame", clearTimeout);
  const layoutWindow = vi.fn(async () => {});
  installNativeBridgeMock({ meetingRecorder: { layoutWindow } });
  let height = 56;
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
              card.getAnimations = () => [];
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

  view.rerender(<Probe compact />);
  height = 42;
  await act(async () => {
    await vi.advanceTimersByTimeAsync(240);
  });
  expect(layoutWindow.mock.calls).toEqual([[{ width: 418, height: 104 }]]);
});
