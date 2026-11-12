import { fireEvent, render, screen } from "@comma/test-utils/render";
import { useRef } from "react";
import { stubProperty } from "@comma/test-utils/stub-property";
import { afterEach, beforeEach, expect, it } from "vitest";
import { RailResizeHandle, useRailWidth } from "../railResize";

/** A rail as the Inbox lays its list out: its width and the divider on its edge. */
function Rail() {
  const rail = useRef<HTMLElement | null>(null);
  const { width, setWidth } = useRailWidth("comma.testRailWidth", 320);
  return (
    <aside data-testid="rail" ref={rail} style={{ flexBasis: width, width }}>
      <RailResizeHandle
        hint="Drag to resize. Click to reset."
        label="Resize the list"
        minWidth={320}
        onWidthChange={setWidth}
        rail={rail}
        testId="rail-resize"
        width={width}
      />
    </aside>
  );
}

const railWidth = () => screen.getByTestId("rail").style.width;

function drag(dx: number) {
  const handle = screen.getByTestId("rail-resize");
  fireEvent.pointerDown(handle, { button: 0, clientX: 320, pointerId: 1 });
  if (dx !== 0) fireEvent.pointerMove(handle, { clientX: 320 + dx, pointerId: 1 });
  fireEvent.pointerUp(handle, { clientX: 320 + dx, pointerId: 1 });
}

/** The window's width for the running test; half of it is the widest the list goes. */
const windowWidth = (width: number) =>
  stubProperty(window, "innerWidth", { value: width });

beforeEach(() => {
  localStorage.clear();
  windowWidth(1200);
});

afterEach(() => localStorage.clear());

it("widens the list by dragging its divider, up to half the window, and keeps the width", () => {
  const { unmount } = render(<Rail />);
  expect(railWidth()).toBe("320px");

  drag(120);
  expect(railWidth()).toBe("440px");

  drag(900);
  expect(railWidth()).toBe("600px");

  // It is never narrower than its default.
  drag(-900);
  expect(railWidth()).toBe("320px");

  drag(80);
  unmount();
  render(<Rail />);
  expect(railWidth()).toBe("400px");
});

it("puts the list back to its default width on a click of the divider", () => {
  render(<Rail />);
  drag(200);
  expect(railWidth()).toBe("520px");

  drag(0);
  expect(railWidth()).toBe("320px");
  expect(localStorage.getItem("comma.testRailWidth")).toBeNull();
});

it("keeps a wide list within half of a window made narrower", () => {
  localStorage.setItem("comma.testRailWidth", "560");
  render(<Rail />);
  expect(railWidth()).toBe("560px");

  windowWidth(900);
  fireEvent(window, new Event("resize"));
  expect(railWidth()).toBe("450px");
});

it("resizes from the keyboard and resets with Enter", () => {
  render(<Rail />);
  const handle = screen.getByRole("button", { name: "Resize the list" });
  fireEvent.keyDown(handle, { key: "ArrowRight" });
  expect(railWidth()).toBe("336px");
  fireEvent.keyDown(handle, { key: "Enter" });
  expect(railWidth()).toBe("320px");
});
