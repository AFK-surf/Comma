import { act, cleanup, fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { installUiClock } from "../../../clock";
import { createVirtualUiClock } from "../../../clock/virtual";
import { TaskCardReorderItem, TaskCardReorderList } from "../TaskCardReorder";

const pointer = (type: string, clientY: number) => {
  const event = new MouseEvent(type, { bubbles: true, button: 0, clientY });
  Object.defineProperty(event, "pointerId", { value: 1 });
  return event;
};

// A card is lifted and held near the bottom edge for 150ms, then nearer it;
// reads how far the column has scrolled 400ms after the lift.
function scrolledAt400ms(frameMs: number) {
  const clock = createVirtualUiClock({ frameMs });
  const restore = installUiClock(clock);
  try {
    render(
      <div data-slot="scroll-area-viewport" data-testid="viewport">
        <TaskCardReorderList ids={["a", "b", "c"]} onReorder={() => {}}>
          {["a", "b", "c"].map((id) => (
            <TaskCardReorderItem id={id} key={id}>
              <div>{id}</div>
            </TaskCardReorderItem>
          ))}
        </TaskCardReorderList>
      </div>
    );
    const viewport = screen.getByTestId("viewport");
    viewport.getBoundingClientRect = () =>
      DOMRect.fromRect({ x: 0, y: 0, width: 300, height: 300 });
    Object.defineProperty(viewport, "scrollHeight", { value: 2_000 });
    Object.defineProperty(viewport, "clientHeight", { value: 300 });

    fireEvent.pointerDown(screen.getByText("a"), {
      button: 0,
      clientY: 100,
      pointerId: 1,
    });
    act(() => {
      window.dispatchEvent(pointer("pointermove", 270));
    });
    act(() => clock.advance(150));
    act(() => {
      window.dispatchEvent(pointer("pointermove", 290));
    });
    act(() => clock.advance(250));
    return viewport.scrollTop;
  } finally {
    cleanup();
    restore();
  }
}

describe("TaskCardReorderList", () => {
  it("autoscrolls the same distance by a moment whatever the frame rate before it", () => {
    // Frames every 16ms land on 400ms exactly; 1000/60 does not add up to it.
    const at60fps = scrolledAt400ms(16);
    expect(at60fps).toBeGreaterThan(0);
    expect(scrolledAt400ms(100)).toBe(at60fps);
    // One frame, at 400ms: straight to the moment.
    expect(scrolledAt400ms(400)).toBe(at60fps);
  });
});
