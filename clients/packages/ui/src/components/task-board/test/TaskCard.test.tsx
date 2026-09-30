import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { TaskCard, TaskCardMeta } from "../TaskCard";

const Icon = ({ name }: { name: string }) => <span data-testid={name} />;

describe("TaskCard", () => {
  it("renders icon, title, and footer", () => {
    const { container } = render(
      <TaskCard
        footer="Created May 9"
        icon={<Icon name="status-icon" />}
        title="Summarizing recent OpenAI's update"
      />
    );

    expect(screen.getByText("Summarizing recent OpenAI's update")).toBeInTheDocument();
    expect(
      container.querySelector(
        '[data-slot="task-card-icon"] [data-testid="status-icon"]'
      )
    ).toBeTruthy();
    expect(container.querySelector('[data-slot="task-card-footer"]')).toHaveTextContent(
      "Created May 9"
    );
    expect(container.firstElementChild).toHaveClass(
      "bg-todo-kanban-bg-card-primary",
      // The 0.5px stroke paints as an inset shadow so it costs no layout.
      "inset-shadow-[0_0_0_var(--border-width-0-5)_var(--color-border-primary)]",
      "px-lg",
      "py-md",
      "shadow-xs"
    );
    expect(container.firstElementChild).not.toHaveClass(
      "py-xl",
      "shadow-sm",
      "border-[length:var(--border-width-0-5)]",
      "border-[length:var(--border-width-default)]"
    );
  });

  it("omits optional meta and badge slots when not provided", () => {
    const { container } = render(
      <TaskCard icon={<Icon name="status-icon" />} title="Untitled" />
    );

    expect(container.querySelector('[data-slot="task-card-meta-row"]')).toBeNull();
    expect(container.querySelector('[data-slot="task-card-badges"]')).toBeNull();
    expect(container.querySelector('[data-slot="task-card-footer"]')).toBeNull();
  });

  it("renders meta and badge slots when provided", () => {
    const { container } = render(
      <TaskCard
        badges={<span data-testid="schedule-badge">Schedules</span>}
        icon={<Icon name="status-icon" />}
        meta={<span data-testid="worker">worker</span>}
        title="Untitled"
      />
    );

    expect(container.querySelector('[data-slot="task-card-meta-row"]')).toBeTruthy();
    expect(screen.getByTestId("worker")).toBeInTheDocument();
    expect(
      container.querySelector(
        '[data-slot="task-card-badges"] [data-testid="schedule-badge"]'
      )
    ).toBeTruthy();
  });

  it("applies interactive, selected, and disabled states", () => {
    const { container, rerender } = render(
      <TaskCard icon={<Icon name="status-icon" />} interactive title="Task" />
    );

    expect(container.firstElementChild).toHaveClass(
      "cursor-pointer",
      "hover:bg-quaternary-hover",
      "active:bg-quaternary-hover",
      "group-active/task-card:bg-quaternary-hover"
    );

    rerender(<TaskCard icon={<Icon name="status-icon" />} selected title="Task" />);
    expect(container.firstElementChild).toHaveAttribute("data-selected", "true");
    expect(container.firstElementChild).toHaveClass("shadow-focus-gray");

    rerender(
      <TaskCard disabled icon={<Icon name="status-icon" />} interactive title="Task" />
    );
    expect(container.firstElementChild).toHaveAttribute("data-disabled", "true");
    expect(container.firstElementChild).toHaveClass("cursor-not-allowed", "opacity-60");
    expect(container.firstElementChild).not.toHaveClass("cursor-pointer");
  });
});

describe("TaskCardMeta", () => {
  it("truncates the text slot and carries no glyph of its own", () => {
    const { container } = render(
      <TaskCardMeta textClassName="comma-shiny-text">working...</TaskCardMeta>
    );

    expect(screen.getByText("working...")).toHaveClass("truncate", "comma-shiny-text");
    expect(container.querySelector('[data-slot="task-card-meta"] svg')).toBeNull();
  });
});
