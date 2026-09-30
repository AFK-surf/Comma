import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { BarsThreeIcon, LayoutColumnIcon } from "../../icons";
import { TaskViewToggle } from "../TaskViewToggle";

describe("TaskViewToggle", () => {
  it("marks the default view as pressed", () => {
    const { container } = render(<TaskViewToggle defaultValue="board" />);

    expect(screen.getByLabelText("Board view")).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByLabelText("List view")).toHaveAttribute("aria-pressed", "false");
    expect(container.querySelector("fieldset")).toHaveClass("gap-md", "border-0");
    expect(screen.getByLabelText("Board view")).toHaveClass(
      "size-6",
      "rounded-full",
      "border-secondary"
    );
  });

  it("uses semantic list and board icons from the shared Central Icons registry", () => {
    const { container } = render(
      <>
        <TaskViewToggle />
        <div data-testid="expected-icons">
          <BarsThreeIcon />
          <LayoutColumnIcon />
        </div>
      </>
    );
    const actualIcons = container.querySelectorAll(
      '[data-slot="task-view-toggle"] button svg'
    );
    const expectedIcons = screen.getByTestId("expected-icons").querySelectorAll("svg");

    expect(actualIcons).toHaveLength(2);
    expect(actualIcons[0]?.innerHTML).toBe(expectedIcons[0]?.innerHTML);
    expect(actualIcons[1]?.innerHTML).toBe(expectedIcons[1]?.innerHTML);
  });

  it("switches the selection when uncontrolled", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();

    render(<TaskViewToggle defaultValue="board" onChange={onChange} />);

    await user.click(screen.getByLabelText("List view"));

    expect(onChange).toHaveBeenCalledWith("list");
    expect(screen.getByLabelText("List view")).toHaveAttribute("aria-pressed", "true");
  });

  it("respects a controlled value without self-updating", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();

    render(<TaskViewToggle onChange={onChange} value="board" />);

    await user.click(screen.getByLabelText("List view"));

    expect(onChange).toHaveBeenCalledWith("list");
    expect(screen.getByLabelText("Board view")).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByLabelText("List view")).toHaveAttribute("aria-pressed", "false");
  });

  it("does not fire onChange when disabled", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();

    render(<TaskViewToggle defaultValue="board" disabled onChange={onChange} />);

    await user.click(screen.getByLabelText("List view"));

    expect(onChange).not.toHaveBeenCalled();
  });
});
