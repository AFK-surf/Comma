import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { Checkbox } from "@comma/ui";
import { describe, expect, it, vi } from "vitest";

describe("Checkbox", () => {
  it("renders the unselected control as a bordered panel box", () => {
    const { container } = render(<Checkbox label="Email updates" />);

    expect(container.querySelector('[data-slot="checkbox-control"]')).toHaveClass(
      "bg-main-panel-bg",
      "border",
      "border-menu-primary",
      "shadow-xs"
    );
  });

  it("reports checked state changes from user clicks", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();

    const { container } = render(
      <Checkbox label="Email updates" onChange={onChange} />
    );
    await user.click(screen.getByRole("checkbox", { name: "Email updates" }));

    const event = onChange.mock.calls.at(-1)?.[0];
    expect(event.target.checked).toBe(true);
    expect(screen.getByRole("checkbox", { name: "Email updates" })).toBeChecked();
    expect(container.querySelector('[data-slot="checkbox-control"]')).toHaveClass(
      "bg-brand-solid"
    );
    const check = container.querySelector("span.opacity-100 [data-comma-icon]");
    expect(check).toHaveClass("size-full");
    expect(check).not.toHaveClass("size-[150%]");
  });

  it("does not report changes when disabled", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();

    render(<Checkbox disabled label="Email updates" onChange={onChange} />);
    await user.click(screen.getByRole("checkbox", { name: "Email updates" }));

    expect(onChange).not.toHaveBeenCalled();
  });

  it("supports a concise accessible name for a rich visual label", () => {
    const { container } = render(
      <Checkbox
        aria-label="Done"
        controlClassName="opacity-0"
        label={
          <span>
            Done <span>1</span>
          </span>
        }
        size="sm"
      />
    );

    expect(screen.getByRole("checkbox", { name: "Done" })).toBeInTheDocument();
    expect(screen.getByText("1")).toBeInTheDocument();
    expect(container.querySelector(".comma-icon-slot")).toHaveClass("size-4");
    expect(container.querySelector('[data-slot="checkbox-control"]')).toHaveClass(
      "opacity-0"
    );
    expect(container.querySelectorAll(".comma-icon-slot > span.inset-px")).toHaveLength(
      2
    );
  });
});
