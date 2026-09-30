import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import {
  CommaLogoAnimation,
  type CommaLogoAnimationProps,
} from "../CommaLogoAnimation";

describe("CommaLogoAnimation", () => {
  it("keeps independently mounted marks from sharing clipping or animation IDs", () => {
    const view = render(
      <>
        <CommaLogoAnimation size={18} />
        <CommaLogoAnimation size={32} />
      </>
    );
    const marks = Array.from(view.container.querySelectorAll("svg"));
    const boundaries = marks.map((mark) => mark.querySelector("clipPath")!.id);
    expect(new Set(boundaries).size).toBe(2);
    marks.forEach((mark, index) => {
      expect(mark.querySelector("g[clip-path]")).toHaveAttribute(
        "clip-path",
        `url(#${boundaries[index]})`
      );
    });
    expect(marks[0]!.style.getPropertyValue("--comma-logo-zoom-animation")).not.toBe(
      marks[1]!.style.getPropertyValue("--comma-logo-zoom-animation")
    );
  });

  it("preserves the source cycle and supports paused frame inspection", () => {
    const view = render(<CommaLogoAnimation paused progress={0.5} size={18} />);
    const logo = view.container.querySelector("svg")!;
    expect(logo).toHaveAttribute("data-paused", "true");
    expect(logo.style.getPropertyValue("--comma-logo-cycle")).toBe("3.4s");
    expect(logo.style.getPropertyValue("--comma-logo-delay")).toBe("-1.7s");
    expect(logo).toHaveAttribute("width", "18");
    expect(logo).toHaveAttribute("height", "18");
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
    const logo = view.container.querySelector("svg")!;
    expect(logo.style.getPropertyValue("--comma-logo-cycle")).toBe("2s");
    view.rerender(<CommaLogoAnimation intervalSeconds={0} progress={1} />);
    expect(logo.style.getPropertyValue("--comma-logo-delay")).toBe("-2s");
    expect(logo.querySelector("style")!.textContent).not.toMatch(/NaN|Infinity/);
  });
});
