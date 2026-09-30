import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { Button } from "./Button";

describe("Button", () => {
  it("defaults to a non-submitting button and handles clicks", async () => {
    const onClick = vi.fn();
    render(<Button onClick={onClick}>Run check</Button>);

    const button = screen.getByRole("button", { name: "Run check" });
    expect(button).toHaveAttribute("type", "button");

    await userEvent.click(button);

    expect(onClick).toHaveBeenCalledTimes(1);
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
