import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { Button } from "@comma/ui/components/Button";
import { describe, expect, it, vi } from "vitest";

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

  it("renders a success status dot instead of an icon when dotLeading is set", () => {
    render(
      <Button size="lg" dotLeading>
        Status
      </Button>
    );

    const button = screen.getByRole("button", { name: "Status" });
    const dot = button.querySelector("span.rounded-full");
    expect(dot).toHaveClass("bg-fg-success-primary", "size-2");
    expect(button.querySelector("svg")).not.toBeInTheDocument();
  });
});
