import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { TaskListGroup } from "../TaskListGroup";
import { TaskListItem } from "../TaskListItem";

const Icon = ({ name }: { name: string }) => <span data-testid={name} />;

const renderGroup = (props?: { defaultOpen?: boolean }) =>
  render(
    <TaskListGroup
      count={2}
      defaultOpen={props?.defaultOpen ?? true}
      icon={<Icon name="status-icon" />}
      label="Backlog"
    >
      <TaskListItem icon={<Icon name="row-icon" />} title="First task" />
      <TaskListItem icon={<Icon name="row-icon" />} title="Second task" />
    </TaskListGroup>
  );

describe("TaskListGroup", () => {
  it("renders the header with status icon, label, and count", () => {
    const { container } = renderGroup();

    const header = container.querySelector('[data-slot="task-list-group-header"]');
    expect(header).toBeTruthy();
    expect(screen.getByText("Backlog")).toBeInTheDocument();
    expect(
      container.querySelector('[data-slot="task-list-group-count"]')
    ).toHaveTextContent("2");
    expect(
      container.querySelector(
        '[data-slot="task-list-group-icon"] [data-testid="status-icon"]'
      )
    ).toBeTruthy();
  });

  it("shows grouped rows when expanded by default", () => {
    renderGroup({ defaultOpen: true });

    expect(screen.getByText("First task")).toBeInTheDocument();
    expect(screen.getByText("Second task")).toBeInTheDocument();
  });

  it("keeps the body collapsed when defaultOpen is false", () => {
    const { container } = renderGroup({ defaultOpen: false });

    expect(
      container.querySelector('[data-slot="task-list-group-header"]')
    ).toHaveAttribute("data-state", "closed");
    expect(screen.queryByText("First task")).not.toBeInTheDocument();
  });

  it("toggles open state when the header is clicked", async () => {
    const user = userEvent.setup();
    const { container } = renderGroup({ defaultOpen: true });

    const header = container.querySelector(
      '[data-slot="task-list-group-header"]'
    ) as HTMLElement;
    expect(header).toHaveAttribute("data-state", "open");

    await user.click(header);

    expect(header).toHaveAttribute("data-state", "closed");
  });

  it("supports a controlled open state", async () => {
    const user = userEvent.setup();
    const onOpenChange = vi.fn();

    const { container } = render(
      <TaskListGroup
        count={0}
        icon={<Icon name="status-icon" />}
        label="Cancel"
        onOpenChange={onOpenChange}
        open={false}
      >
        <TaskListItem icon={<Icon name="row-icon" />} title="Hidden task" />
      </TaskListGroup>
    );

    expect(screen.queryByText("Hidden task")).not.toBeInTheDocument();

    await user.click(
      container.querySelector('[data-slot="task-list-group-header"]') as HTMLElement
    );

    expect(onOpenChange).toHaveBeenCalledWith(true);
    expect(screen.queryByText("Hidden task")).not.toBeInTheDocument();
  });
});
