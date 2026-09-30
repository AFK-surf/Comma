import { fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { TaskBoard, TaskBoardColumn, TASK_BOARD_COLUMN_WIDTH } from "../TaskBoard";
import { TaskCard } from "../TaskCard";

const Icon = ({ name }: { name: string }) => <span data-testid={name} />;

function setElementMetric(
  element: HTMLElement,
  key: "clientHeight" | "clientWidth" | "scrollHeight" | "scrollWidth",
  value: number
) {
  Object.defineProperty(element, key, {
    configurable: true,
    value,
  });
}

describe("TaskBoard", () => {
  it("renders columns inside a horizontal scroll area", () => {
    const { container } = render(
      <TaskBoard>
        <TaskBoardColumn count={1} icon={<Icon name="backlog" />} label="Backlog">
          <TaskCard icon={<Icon name="card-icon" />} title="First task" />
        </TaskBoardColumn>
      </TaskBoard>
    );

    const scrollArea = container.querySelector('[data-slot="scroll-area"]');
    const track = container.querySelector('[data-slot="scroll-area-content"]');
    expect(scrollArea).toHaveAttribute("data-orientation", "horizontal");
    expect(track).toHaveClass("box-border", "pb-md");
    expect(container.querySelector('[data-slot="task-board-column"]')).toBeTruthy();
    expect(screen.getByText("First task")).toBeInTheDocument();
  });

  it("never turns a wheel over a column into a sideways board scroll", async () => {
    const { container } = render(
      <TaskBoard>
        <TaskBoardColumn icon={<Icon name="backlog" />} label="Backlog">
          <TaskCard icon={<Icon name="card-icon" />} title="First task" />
        </TaskBoardColumn>
      </TaskBoard>
    );
    const viewports = container.querySelectorAll<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const boardViewport = viewports[0]!;
    const columnViewport = viewports[1]!;

    setElementMetric(boardViewport, "clientWidth", 300);
    setElementMetric(boardViewport, "scrollWidth", 900);
    setElementMetric(columnViewport, "clientHeight", 300);
    setElementMetric(columnViewport, "scrollHeight", 300);
    // Let the board measure its overflow, which is what arms its wheel mapping.
    fireEvent.scroll(boardViewport);
    await new Promise((resolve) => window.requestAnimationFrame(resolve));

    // The board maps an ordinary mouse wheel to a sideways scroll...
    expect(fireEvent.wheel(boardViewport, { deltaY: 60 })).toBe(false);
    expect(boardViewport.scrollLeft).toBe(60);
    boardViewport.scrollLeft = 0;

    // ...but a wheel that started over a column is that column's, whether the
    // column has anything left to scroll or not. The browser scrolls the
    // column, and chains a sideways gesture on to the board, by itself.
    for (const columnScrollHeight of [300, 900]) {
      setElementMetric(columnViewport, "scrollHeight", columnScrollHeight);
      expect(fireEvent.wheel(columnViewport, { deltaY: 60 })).toBe(true);
      expect(boardViewport.scrollLeft).toBe(0);
    }
    expect(fireEvent.wheel(columnViewport, { deltaX: 60 })).toBe(true);
  });
});

describe("TaskBoardColumn", () => {
  it("renders the header icon, label, and count", () => {
    const { container } = render(
      <TaskBoardColumn count={4} icon={<Icon name="status" />} label="Needs Review">
        <TaskCard icon={<Icon name="card-icon" />} title="Task" />
      </TaskBoardColumn>
    );

    expect(screen.getByText("Needs Review")).toBeInTheDocument();
    expect(
      container.querySelector('[data-slot="task-board-column-count"]')
    ).toHaveTextContent("4");
    expect(
      container.querySelector(
        '[data-slot="task-board-column-icon"] [data-testid="status"]'
      )
    ).toBeTruthy();
    expect(container.querySelector('[data-slot="task-board-column"]')).toHaveClass(
      "bg-todo-kanban-bg-column-primary"
    );
  });

  it("formats large counts with the active locale", () => {
    render(
      <TaskBoardColumn count={10_000} icon={<Icon name="status" />} label="Backlog">
        <TaskCard icon={<Icon name="card-icon" />} title="Task" />
      </TaskBoardColumn>
    );

    expect(screen.getByText("10,000")).toBeInTheDocument();
  });

  it("applies the design column width by default", () => {
    const { container } = render(
      <TaskBoardColumn icon={<Icon name="status" />} label="Backlog">
        <TaskCard icon={<Icon name="card-icon" />} title="Task" />
      </TaskBoardColumn>
    );

    const column = container.querySelector(
      '[data-slot="task-board-column"]'
    ) as HTMLElement;

    expect(column.style.width).toBe(
      `var(--task-board-column-width, ${TASK_BOARD_COLUMN_WIDTH}px)`
    );
  });

  it("keeps the column body in the flex scroll height chain", () => {
    const { container } = render(
      <TaskBoardColumn icon={<Icon name="status" />} label="Backlog">
        <TaskCard icon={<Icon name="card-icon" />} title="Task" />
      </TaskBoardColumn>
    );

    const columnScroll = container.querySelector(
      '[data-slot="task-board-column"] [data-slot="scroll-area"]'
    );
    const columnBody = container.querySelector(
      '[data-slot="task-board-column"] [data-slot="scroll-area-content"]'
    );
    const columnViewport = container.querySelector(
      '[data-slot="task-board-column"] [data-slot="scroll-area-viewport"]'
    );

    expect(columnScroll).toHaveClass(
      "basis-0",
      "flex-1",
      "min-h-0",
      "min-w-0",
      "overflow-x-hidden"
    );
    expect(columnScroll).toHaveAttribute("data-orientation", "vertical");
    expect(columnBody).toHaveClass("min-w-0", "overflow-x-clip", "w-full");
    expect(columnBody).toHaveClass("pb-lg");
    expect(columnViewport).toHaveClass("overflow-x-hidden", "min-w-0");
  });

  it("renders the empty state when there are no cards", () => {
    const { container } = render(
      <TaskBoardColumn
        count={0}
        emptyState="No tasks"
        icon={<Icon name="status" />}
        label="Cancel"
      >
        {[]}
      </TaskBoardColumn>
    );

    expect(
      container.querySelector('[data-slot="task-board-column-empty"]')
    ).toHaveTextContent("No tasks");
  });

  it("renders cards instead of the empty state when children exist", () => {
    const { container } = render(
      <TaskBoardColumn
        emptyState="No tasks"
        icon={<Icon name="status" />}
        label="Backlog"
      >
        <TaskCard icon={<Icon name="card-icon" />} title="Visible task" />
      </TaskBoardColumn>
    );

    expect(container.querySelector('[data-slot="task-board-column-empty"]')).toBeNull();
    expect(screen.getByText("Visible task")).toBeInTheDocument();
  });
});
