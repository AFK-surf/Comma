import { act, cleanup, fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { installUiClock } from "../../../clock";
import { createVirtualUiClock } from "../../../clock/virtual";
import { CommaMascot, commaMascotMaxGazeDistance } from "../CommaMascot";

// The mascot on a clock that frames every `frameMs`.
function onClock<T>(
  frameMs: number,
  run: (clock: ReturnType<typeof createVirtualUiClock>) => T
) {
  const clock = createVirtualUiClock({ frameMs });
  const restore = installUiClock(clock);
  try {
    return run(clock);
  } finally {
    cleanup();
    restore();
  }
}

const mascotAt = (mascot: HTMLElement) => {
  vi.spyOn(mascot, "getBoundingClientRect").mockReturnValue(
    DOMRect.fromRect({ x: 0, y: 0, width: 96, height: 96 })
  );
  Object.assign(mascot, {
    hasPointerCapture: vi.fn(() => true),
    releasePointerCapture: vi.fn(),
    setPointerCapture: vi.fn(),
  });
};

// The pointer moves off to the right; 200ms later the eyes are still
// swinging toward it.
const gazeAt200ms = (frameMs: number) =>
  onClock(frameMs, (clock) => {
    render(<CommaMascot followPointer size={96} />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });
    mascotAt(mascot);
    const move = new MouseEvent("pointermove", { clientX: 400, clientY: 60 });
    Object.defineProperty(move, "pointerType", { value: "mouse" });
    act(() => {
      window.dispatchEvent(move);
    });
    act(() => clock.advance(200));
    return mascot.querySelector(".comma-mascot__gaze")?.getAttribute("transform");
  });

// The body is pulled for 100ms and let go; 300ms later it still wobbles.
const meshAt400ms = (frameMs: number) =>
  onClock(frameMs, (clock) => {
    render(<CommaMascot size={96} />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });
    mascotAt(mascot);
    const pointer = { button: 0, pointerId: 7, pointerType: "mouse" };
    fireEvent.pointerDown(mascot, { ...pointer, clientX: 30, clientY: 30 });
    act(() => clock.advance(50));
    fireEvent.pointerMove(mascot, { ...pointer, clientX: 45, clientY: 34 });
    act(() => clock.advance(50));
    fireEvent.pointerUp(mascot, { ...pointer, clientX: 45, clientY: 34 });
    act(() => clock.advance(300));
    return [...mascot.querySelectorAll("path")]
      .map((path) => path.getAttribute("d"))
      .join("|");
  });

describe("CommaMascot", () => {
  it("renders an accessible SVG backed by the deformable mesh", () => {
    render(<CommaMascot label="Virtual Comma" size={64} />);

    const mascot = screen.getByRole("img", { name: "Virtual Comma" });
    expect(mascot).toHaveAttribute("data-mesh", "6x6");
    expect(mascot).toHaveAttribute("data-expression", "neutral");
    expect(mascot).toHaveAttribute("width", "64");
    expect(mascot.querySelectorAll(".comma-mascot__eye")).toHaveLength(2);
  });

  it("retargets expressions without replacing the eye paths", () => {
    const { rerender } = render(<CommaMascot expression="neutral" />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });
    const eyes = [...mascot.querySelectorAll(".comma-mascot__eye")];

    rerender(<CommaMascot expression="happy" />);

    expect(mascot).toHaveAttribute("data-expression", "happy");
    expect([...mascot.querySelectorAll(".comma-mascot__eye")]).toEqual(eyes);
  });

  it("can hide the expression layer to render the plain logo", () => {
    const { rerender } = render(<CommaMascot showExpression />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });
    const expression = mascot.querySelector(".comma-mascot__expression");

    expect(mascot).toHaveAttribute("data-show-expression", "true");
    expect(expression).toHaveAttribute("aria-hidden", "false");

    rerender(<CommaMascot showExpression={false} />);
    expect(mascot).toHaveAttribute("data-show-expression", "false");
    expect(expression).toHaveAttribute("aria-hidden", "true");
  });

  it("renders the traced outer and inner logo contours", () => {
    render(<CommaMascot />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });
    const outer = mascot.querySelector('[data-part="outer"]');
    const core = mascot.querySelector('[data-part="core"]');

    expect(outer?.getAttribute("d")).toContain("L 135.600 208.750");
    expect(core?.getAttribute("d")).toContain("L 146.100 206.650");
  });

  it("uses theme tokens by default while preserving explicit color overrides", () => {
    const { rerender } = render(<CommaMascot />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });

    expect(mascot.querySelector('[data-part="outer"]')).toHaveAttribute(
      "fill",
      "var(--color-text-primary)"
    );
    expect(mascot.querySelector(".comma-mascot__eye")).toHaveAttribute(
      "fill",
      "var(--color-bg-primary)"
    );

    rerender(<CommaMascot color="#ff00aa" eyeColor="#001122" />);
    expect(mascot.querySelector('[data-part="outer"]')).toHaveAttribute(
      "fill",
      "#ff00aa"
    );
    expect(mascot.querySelector(".comma-mascot__eye")).toHaveAttribute(
      "fill",
      "#001122"
    );
  });

  it("exposes pointer following as an explicit opt-in", () => {
    expect(commaMascotMaxGazeDistance).toBe(5.5);

    const { rerender } = render(<CommaMascot followPointer />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });

    expect(mascot).toHaveAttribute("data-follow-pointer", "true");
    expect(mascot.querySelector(".comma-mascot__gaze")).toHaveAttribute(
      "transform",
      "translate(0.000 0.000)"
    );

    rerender(<CommaMascot followPointer={false} />);
    expect(mascot).toHaveAttribute("data-follow-pointer", "false");
  });

  it("turns its gaze to the same place at a moment whatever the frame rate before it", () => {
    const at60fps = gazeAt200ms(1000 / 60);
    expect(at60fps).not.toBe("translate(0.000 0.000)");
    expect(gazeAt200ms(100)).toBe(at60fps);
    // One frame, at 200ms: straight to the moment.
    expect(gazeAt200ms(200)).toBe(at60fps);
  });

  it("wobbles the same at a moment whatever the frame rate before it", () => {
    // Frames every 16ms land on 400ms exactly; 1000/60 does not add up to it.
    const at60fps = meshAt400ms(16);
    expect(meshAt400ms(100)).toBe(at60fps);
    // Frames only where the pointer moved: straight to each moment.
    expect(meshAt400ms(400)).toBe(at60fps);
  });

  it("releases the soft-body drag when the pointer ends outside the SVG", () => {
    render(<CommaMascot size={96} />);
    const mascot = screen.getByRole("img", { name: "Comma mascot" });
    vi.spyOn(mascot, "getBoundingClientRect").mockReturnValue({
      bottom: 96,
      height: 96,
      left: 0,
      right: 96,
      top: 0,
      width: 96,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    Object.assign(mascot, {
      hasPointerCapture: vi.fn(() => true),
      releasePointerCapture: vi.fn(),
      setPointerCapture: vi.fn(),
    });

    fireEvent.pointerDown(mascot, {
      button: 0,
      clientX: 30,
      clientY: 30,
      pointerId: 7,
      pointerType: "mouse",
    });
    expect(mascot).toHaveAttribute("data-dragging", "true");

    fireEvent.pointerUp(window, { pointerId: 7, pointerType: "mouse" });
    expect(mascot).toHaveAttribute("data-dragging", "false");
  });
});
