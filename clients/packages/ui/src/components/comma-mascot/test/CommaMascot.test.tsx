import { fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { CommaMascot, commaMascotMaxGazeDistance } from "../CommaMascot";

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
