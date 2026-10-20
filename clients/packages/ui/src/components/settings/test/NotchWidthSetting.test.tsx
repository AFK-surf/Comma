import { act } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { advance } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { installUiClock } from "../../../clock";
import { createVirtualUiClock } from "../../../clock/virtual";
import { NotchWidthSetting } from "../NotchWidthSetting";

const labels = {
  width: "Width",
  reset: "Reset",
  preview: "Preview",
  valueText: (value: number) => `${value} pt`,
  sampleTitle: "Task",
};

// A pointer event as the browser delivers it, stamped with `timeStamp`.
function pointer(type: string, clientX: number, timeStamp: number) {
  const event = new MouseEvent(type, { bubbles: true, button: 0, clientX });
  Object.defineProperty(event, "pointerId", { value: 1 });
  Object.defineProperty(event, "timeStamp", { value: timeStamp });
  return event;
}

// Drags past the far end of the field, one clock frame per move, releases,
// and reads the Notch's width once the release has sprung for a while.
async function flingPastTheEnd(timeStamps: [number, number, number, number]) {
  const view = render(
    <NotchWidthSetting
      defaultValue={150}
      labels={labels}
      max={200}
      min={100}
      onValueCommit={() => {}}
      value={150}
    />
  );
  const field = screen.getByRole("slider");
  field.getBoundingClientRect = () =>
    DOMRect.fromRect({ x: 0, y: 0, width: 100, height: 20 });
  field.setPointerCapture = () => {};
  field.hasPointerCapture = () => true;
  field.releasePointerCapture = () => {};

  field.dispatchEvent(pointer("pointerdown", 50, timeStamps[0]));
  await advance(16);
  field.dispatchEvent(pointer("pointermove", 80, timeStamps[1]));
  await advance(16);
  field.dispatchEvent(pointer("pointermove", 130, timeStamps[2]));
  await advance(16);
  field.dispatchEvent(pointer("pointerup", 130, timeStamps[3]));
  await advance(48);
  const shell = view.container.querySelector<HTMLElement>(".comma-notch-width__shell");
  const width = shell?.style.width;
  view.unmount();
  return width;
}

describe("NotchWidthSetting", () => {
  it("springs back from a fling by its own clock, not by when input events say they happened", async () => {
    // The same drag on the same clock: events stamped close together and far
    // apart must leave the Notch at the same width.
    const close = await flingPastTheEnd([1000, 1001, 1002, 1003]);
    const apart = await flingPastTheEnd([1000, 1400, 1800, 2200]);
    expect(close).toBeDefined();
    expect(apart).toBe(close);
  });

  it("glides to the same width at a moment whatever the frame rate before it", () => {
    // End sets the widest Notch; 200ms into the glide it is still moving.
    const widthAt = (ms: number, frameMs: number) => {
      const clock = createVirtualUiClock({ frameMs });
      const restore = installUiClock(clock);
      try {
        const view = render(
          <NotchWidthSetting
            defaultValue={150}
            labels={labels}
            max={200}
            min={100}
            onValueCommit={() => {}}
            value={150}
          />
        );
        act(() => {
          fireEvent.keyDown(screen.getByRole("slider"), { key: "End" });
        });
        act(() => clock.advance(ms));
        const width = view.container.querySelector<HTMLElement>(
          ".comma-notch-width__shell"
        )?.style.width;
        view.unmount();
        return width;
      } finally {
        restore();
      }
    };
    const at60fps = widthAt(200, 1000 / 60);
    expect(at60fps).not.toBe(widthAt(1_000, 1000 / 60));
    expect(widthAt(200, 100)).toBe(at60fps);
    // One frame, at 200ms: straight to the moment.
    expect(widthAt(200, 200)).toBe(at60fps);
  });
});
