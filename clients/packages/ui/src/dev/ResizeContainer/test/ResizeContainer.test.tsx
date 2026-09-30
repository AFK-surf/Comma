import { describe, expect, it } from "vitest";
import { render } from "@comma/test-utils/render";
import { ResizeContainer } from "../ResizeContainer";

describe("ResizeContainer", () => {
  it("keeps content clipped by default and supports visible visual overflow", () => {
    const { container, rerender } = render(
      <ResizeContainer>
        <div>Preview</div>
      </ResizeContainer>
    );

    expect(container.querySelector('[data-slot="resize-viewport"]')).toHaveClass(
      "overflow-hidden"
    );

    rerender(
      <ResizeContainer clipContent={false}>
        <div>Preview</div>
      </ResizeContainer>
    );

    expect(container.querySelector('[data-slot="resize-viewport"]')).toHaveClass(
      "overflow-visible"
    );
  });

  it("keeps the full horizontal resize hit areas inside the content bounds", () => {
    const { container } = render(
      <ResizeContainer defaultResizable>
        <div>Preview</div>
      </ResizeContainer>
    );

    expect(container.querySelector('[data-handle="w"]')).toHaveClass("left-0", "w-2");
    expect(container.querySelector('[data-handle="w"]')).not.toHaveClass(
      "-translate-x-1/2"
    );
    expect(container.querySelector('[data-handle="e"]')).toHaveClass("right-0", "w-2");
    expect(container.querySelector('[data-handle="e"]')).not.toHaveClass(
      "translate-x-1/2"
    );
  });
});
