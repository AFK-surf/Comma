import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import {
  CommaLogoAnimation,
  type CommaLogoAnimationProps,
} from "../CommaLogoAnimation";

describe("CommaLogoAnimation", () => {
  it("cuts one aperture through both parts of the mark, apart from other marks", () => {
    const view = render(
      <>
        <CommaLogoAnimation cutout size={18} />
        <CommaLogoAnimation cutout size={32} />
      </>
    );
    const marks = Array.from(
      view.container.querySelectorAll('[data-slot="comma-logo-animation"]')
    );
    const apertures = marks.map((mark) => mark.querySelector("mask")!.id);
    expect(new Set(apertures).size).toBe(2);
    marks.forEach((mark, index) => {
      const masked = Array.from(mark.querySelectorAll("path[mask]"));
      expect(masked).toHaveLength(2);
      masked.forEach((path) =>
        expect(path).toHaveAttribute("mask", `url(#${apertures[index]})`)
      );
    });
  });

  it("plays the stylesheet's shared cycle without adding keyframes of its own", () => {
    // Adding or removing an @keyframes rule restyles every animated element
    // in the document, and the mark mounts with each reply.
    const view = render(<CommaLogoAnimation size={18} />);
    const logo = view.container.querySelector<HTMLElement>(
      '[data-slot="comma-logo-animation"]'
    )!;
    expect(logo.querySelector("style")).toBeNull();
    expect(logo.style.getPropertyValue("--comma-logo-zoom-animation")).toBe("");
    expect(logo.style.getPropertyValue("--comma-logo-nested-animation")).toBe("");
    expect(logo.style.getPropertyValue("--comma-logo-cycle")).toBe("3.4s");
  });

  it("names its own keyframes only for a cycle of its own", () => {
    const view = render(
      <>
        <CommaLogoAnimation easing="linear" size={18} />
        <CommaLogoAnimation intervalSeconds={0.4} size={18} />
      </>
    );
    const marks = Array.from(
      view.container.querySelectorAll<HTMLElement>('[data-slot="comma-logo-animation"]')
    );
    const names = marks.map((mark) =>
      mark.style.getPropertyValue("--comma-logo-zoom-animation")
    );
    expect(names.every((name) => name.startsWith("comma-logo-zoom-"))).toBe(true);
    expect(new Set(names).size).toBe(2);
    marks.forEach((mark, index) => {
      expect(mark.querySelector("style")!.textContent).toContain(
        `@keyframes ${names[index]}`
      );
    });
  });

  it("preserves the source cycle and supports paused frame inspection", () => {
    const view = render(<CommaLogoAnimation paused progress={0.5} size={18} />);
    const logo = view.container.querySelector<HTMLElement>(
      '[data-slot="comma-logo-animation"]'
    )!;
    expect(logo).toHaveAttribute("data-paused", "true");
    expect(logo.style.getPropertyValue("--comma-logo-cycle")).toBe("3.4s");
    expect(logo.style.getPropertyValue("--comma-logo-delay")).toBe("-1.7s");
    expect(logo.style.getPropertyValue("--comma-logo-size")).toBe("18px");
  });

  it.each<CommaLogoAnimationProps>([
    { zoomSeconds: 0, intervalSeconds: 0 },
    { zoomSeconds: -1 },
    { zoomSeconds: NaN },
    { zoomSeconds: Infinity },
    { intervalSeconds: -1 },
    { intervalSeconds: NaN },
    { intervalSeconds: Infinity },
    { zoomSeconds: Number.MAX_VALUE, intervalSeconds: Number.MAX_VALUE },
    { progress: NaN },
    { progress: Infinity },
    { progress: -0.1 },
    { progress: 1.1 },
    { nestedDelayPercent: NaN },
    { nestedDelayPercent: -1 },
    { nestedDelayPercent: 100 },
  ])(
    "rejects invalid animation timing instead of silently emitting broken CSS: %j",
    (props) => {
      expect(() => render(<CommaLogoAnimation {...props} />)).toThrow(RangeError);
    }
  );

  it("allows a zero hold and the first and last inspection frames", () => {
    const view = render(<CommaLogoAnimation intervalSeconds={0} progress={0} />);
    const logo = view.container.querySelector<HTMLElement>(
      '[data-slot="comma-logo-animation"]'
    )!;
    expect(logo.style.getPropertyValue("--comma-logo-cycle")).toBe("2s");
    view.rerender(<CommaLogoAnimation intervalSeconds={0} progress={1} />);
    expect(logo.style.getPropertyValue("--comma-logo-delay")).toBe("-2s");
    expect(logo.querySelector("style")!.textContent).not.toMatch(/NaN|Infinity/);
  });
});
