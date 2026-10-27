import { act } from "react";
import { describe, expect, it, vi } from "vitest";
import { render } from "@comma/test-utils/render";
import { TitleSwap } from "../TitleSwap";

const layers = (container: HTMLElement) =>
  Array.from(container.querySelectorAll(".comma-title-swap-text")).map((layer) => [
    layer.getAttribute("data-motion"),
    layer.textContent,
  ]);

describe("TitleSwap", () => {
  it("shows the first title at rest", () => {
    const { container } = render(<TitleSwap identity="t1" text="Draft" />);

    expect(layers(container)).toEqual([[null, "Draft"]]);
  });

  it("blurs a renamed title across, then settles on the new one", () => {
    const { container, rerender } = render(<TitleSwap identity="t1" text="Draft" />);

    rerender(<TitleSwap identity="t1" text="🚀 Launch checklist" />);

    expect(layers(container)).toEqual([
      ["exit", "Draft"],
      ["enter", "🚀 Launch checklist"],
    ]);
    expect(container.querySelector('[data-motion="exit"]')).toHaveAttribute(
      "aria-hidden",
      "true"
    );

    act(() => {
      vi.advanceTimersByTime(200);
    });

    expect(layers(container)).toEqual([[null, "🚀 Launch checklist"]]);
  });

  it("swaps from the latest title when renamed again mid-swap", () => {
    const { container, rerender } = render(<TitleSwap identity="t1" text="One" />);

    rerender(<TitleSwap identity="t1" text="Two" />);
    act(() => {
      vi.advanceTimersByTime(100);
    });
    rerender(<TitleSwap identity="t1" text="Three" />);

    expect(layers(container)).toEqual([
      ["exit", "Two"],
      ["enter", "Three"],
    ]);

    // The first swap's timer must not end the second one early.
    act(() => {
      vi.advanceTimersByTime(100);
    });
    expect(layers(container)).toHaveLength(2);

    act(() => {
      vi.advanceTimersByTime(100);
    });
    expect(layers(container)).toEqual([[null, "Three"]]);
  });

  it("shows another thing's title at once", () => {
    const { container, rerender } = render(<TitleSwap identity="t1" text="Draft" />);

    rerender(<TitleSwap identity="t2" text="Other task" />);

    expect(layers(container)).toEqual([[null, "Other task"]]);
  });
});
