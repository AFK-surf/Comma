import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { Button } from "@comma/ui";
import { describe, expect, it, vi } from "vitest";
import { PlaceholderIcon } from "../../icons";

describe("Button", () => {
  it("fires press handlers for user clicks", async () => {
    const user = userEvent.setup();
    const onPress = vi.fn();

    render(<Button onPress={onPress}>Save</Button>);
    await user.click(screen.getByRole("button", { name: "Save" }));

    expect(onPress).toHaveBeenCalledTimes(1);
  });

  it("does not fire press handlers when disabled", async () => {
    const user = userEvent.setup();
    const onPress = vi.fn();

    render(
      <Button disabled onPress={onPress}>
        Save
      </Button>
    );
    await user.click(screen.getByRole("button", { name: "Save" }));

    expect(onPress).not.toHaveBeenCalled();
  });

  it.each([
    { label: "Small", size: "sm", slotClass: "size-4" },
    { label: "Default", size: "md", slotClass: "size-5" },
    { label: "Large", size: "lg", slotClass: "size-5" },
  ] as const)("renders the $label icon slot geometry", ({ label, size, slotClass }) => {
    render(
      <Button size={size} iconLeading={<PlaceholderIcon />}>
        {label}
      </Button>
    );

    const button = screen.getByRole("button", { name: label });
    const iconSlot = button.querySelector<HTMLElement>(".comma-icon-slot");

    expect(iconSlot).not.toBeNull();
    expect(iconSlot).toHaveClass(
      slotClass,
      "inline-flex",
      "shrink-0",
      "items-center",
      "justify-center"
    );
    expect(iconSlot?.querySelector("svg[data-comma-icon]")).toBeInTheDocument();
  });
});
