import { describe, expect, it } from "vitest";
import { render } from "@comma/test-utils/render";
import { CheckboxBase } from "./CheckboxBase";

describe("CheckboxBase", () => {
  it("draws the product's bordered box and fills it only when it carries a glyph", () => {
    const { container, rerender } = render(<CheckboxBase size="sm" />);
    const control = () => container.querySelector('[data-slot="checkbox-control"]');

    // An empty box is a 16px panel-filled outline with the darker menu border
    // and the xs shadow (Comma App 1371:19264), so it stays legible on hover and
    // selection greys; the same look serves menus and forms.
    expect(control()).toHaveClass(
      "size-4",
      "rounded-xs",
      "border",
      "border-menu-primary",
      "bg-main-panel-bg",
      "shadow-xs"
    );
    expect(control()).not.toHaveClass("bg-brand-solid", "border-primary");

    rerender(<CheckboxBase size="sm" isSelected />);
    expect(control()).toHaveClass("bg-brand-solid", "border-transparent", "shadow-xs");

    rerender(<CheckboxBase size="sm" isIndeterminate />);
    expect(control()).toHaveClass("bg-brand-solid");
  });

  it("keeps every glyph inside the box", () => {
    const { container, rerender } = render(<CheckboxBase size="sm" isSelected />);
    const control = () => container.querySelector('[data-slot="checkbox-control"]');

    expect(control()).toHaveClass("overflow-hidden");
    expect(container.querySelector("span.opacity-100")).toHaveClass("inset-px");
    // The check used to be scaled past the box's own edges.
    expect(
      container.querySelector("span.opacity-100 [data-comma-icon]")
    ).not.toHaveClass("size-[150%]");

    rerender(<CheckboxBase size="md" isSelected />);
    expect(control()).toHaveClass("size-5");
    expect(container.querySelector("span.opacity-100")).toHaveClass("inset-[15%]");
  });

  it("gives a disabled box its own fill and glyph colour", () => {
    const { container } = render(<CheckboxBase size="sm" isDisabled isSelected />);

    expect(container.querySelector('[data-slot="checkbox-control"]')).toHaveClass(
      "bg-disabled",
      "border-disabled",
      "cursor-not-allowed"
    );
    expect(container.querySelector("span.opacity-100")).toHaveClass("text-fg-disabled");
  });
});
