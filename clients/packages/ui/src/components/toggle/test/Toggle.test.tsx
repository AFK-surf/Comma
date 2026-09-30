import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { Toggle } from "../Toggle";

describe("Toggle", () => {
  it("drives the knob from its selected state alone", async () => {
    const user = userEvent.setup();
    render(<Toggle aria-label="Notifications" size="md" slim />);

    const input = screen.getByRole("switch", { name: "Notifications" });
    const root = input.closest("label");
    const track = root?.querySelector('[data-slot="toggle-base"]');
    const motion = root?.querySelector('[data-slot="toggle-thumb-motion"]');
    const thumb = root?.querySelector('[data-slot="toggle-thumb"]');

    // The knob's box comes from the track's own size variables, so a variant
    // never has to restate a travel distance.
    expect(track).toHaveClass(
      "[--comma-toggle-thumb-size:18px]",
      "[--comma-toggle-thumb-inset:2px]"
    );
    expect(motion).toHaveClass("comma-toggle-thumb-motion");
    expect(motion).not.toHaveClass("size-4.5");
    expect(thumb).toHaveClass("comma-toggle-thumb", "size-full");

    expect(track).toHaveAttribute("data-selected", "false");
    expect(track).toHaveAttribute("data-disabled", "false");

    await user.hover(root!);
    expect(root).toHaveAttribute("data-hovered", "true");

    await user.click(input);

    expect(input).toBeChecked();
    expect(track).toHaveAttribute("data-selected", "true");
    // Hover and commit share one mechanism, so no interaction bookkeeping is
    // mirrored onto the element.
    expect(track).not.toHaveAttribute("data-interacted");
    expect(track).not.toHaveAttribute("data-morph-hovered");
    expect(track).not.toHaveAttribute("data-animation-starts-hovered");
  });

  it("waits for a controlled selection commit before moving the knob", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    const { rerender } = render(
      <Toggle
        aria-label="Controlled notifications"
        checked
        onChange={onChange}
        size="md"
        slim
      />
    );

    const input = screen.getByRole("switch", {
      name: "Controlled notifications",
    });
    const root = input.closest("label");
    const track = root?.querySelector('[data-slot="toggle-base"]');

    await user.hover(root!);
    await user.click(input);

    expect(onChange).toHaveBeenCalledWith(
      expect.objectContaining({ target: { checked: false } })
    );
    // The click reports intent; the knob stays put until the owner commits it.
    expect(track).toHaveAttribute("data-selected", "true");

    rerender(
      <Toggle
        aria-label="Controlled notifications"
        checked={false}
        onChange={onChange}
        size="md"
        slim
      />
    );

    expect(input).not.toBeChecked();
    expect(track).toHaveAttribute("data-selected", "false");
  });
});
