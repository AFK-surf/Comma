import { render, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { TaskSummaryViewModel } from "../../task-workspace";
import { HomeTasks } from "../HomeTasks";

function task(
  id: string,
  statusBucket: TaskSummaryViewModel["statusBucket"],
  updatedAt = 1_778_000_000
): TaskSummaryViewModel {
  return {
    activityStatus: "queued",
    freshness: "fresh",
    id,
    statusBucket,
    title: `Task ${id}`,
    updatedAt,
  };
}

const tasks = [
  task("backlog-a", "backlog", 3),
  task("backlog-b", "backlog", 2),
  task("progress-a", "in_progress", 1),
];

describe("HomeTasks", () => {
  it("renders only the cards for the selected status bucket", () => {
    const { getAllByTestId, queryByText } = render(
      <HomeTasks
        onOpenTask={vi.fn()}
        onStatusChange={vi.fn()}
        status="backlog"
        tasks={tasks}
      />
    );

    const cards = getAllByTestId("home-task-card");
    expect(cards).toHaveLength(2);
    expect(queryByText("Task progress-a")).toBeNull();
  });

  it("shimmers a progress line on a running card and omits it elsewhere", () => {
    const running: TaskSummaryViewModel = {
      ...task("progress-b", "in_progress"),
      activityStatus: "thinking",
    };
    const { getByText, queryByText, rerender } = render(
      <HomeTasks
        onOpenTask={vi.fn()}
        onStatusChange={vi.fn()}
        status="in_progress"
        tasks={[running]}
      />
    );

    expect(getByText("Thinking")).toHaveClass("comma-shiny-text");

    // The line is the progress report, so a task that stopped making progress
    // drops it rather than freezing its last activity under the title.
    rerender(
      <HomeTasks
        onOpenTask={vi.fn()}
        onStatusChange={vi.fn()}
        status="done"
        tasks={[{ ...running, statusBucket: "done" }]}
      />
    );

    expect(queryByText("Thinking")).toBeNull();
  });

  it("opens a task when its card is clicked", async () => {
    const onOpenTask = vi.fn();
    const { getAllByTestId } = render(
      <HomeTasks
        onOpenTask={onOpenTask}
        onStatusChange={vi.fn()}
        status="backlog"
        tasks={tasks}
      />
    );

    await userEvent.click(getAllByTestId("home-task-card")[0]!);
    expect(onOpenTask).toHaveBeenCalledTimes(1);
    expect(onOpenTask.mock.calls[0]![0].id).toBe("backlog-a");
  });

  it("switches the visible cards when the status prop changes", async () => {
    const { container, getAllByTestId, rerender } = render(
      <HomeTasks
        onOpenTask={vi.fn()}
        onStatusChange={vi.fn()}
        status="backlog"
        tasks={tasks}
      />
    );

    rerender(
      <HomeTasks
        onOpenTask={vi.fn()}
        onStatusChange={vi.fn()}
        status="in_progress"
        tasks={tasks}
      />
    );

    // Both pages are on screen during the slide: the incoming panel renders
    // immediately while the outgoing one ghosts away.
    expect(container.querySelector('[data-role="current"]')).toHaveTextContent(
      "Task progress-a"
    );
    expect(container.querySelector('[data-role="outgoing"]')).not.toBeNull();

    await waitFor(() => {
      const cards = getAllByTestId("home-task-card");
      expect(cards).toHaveLength(1);
      expect(cards[0]).toHaveTextContent("Task progress-a");
    });
  });

  it("keeps the empty state mounted when switching between empty buckets", () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      tasks: [] as TaskSummaryViewModel[],
    };
    const { getByText, rerender } = render(<HomeTasks {...props} status="backlog" />);
    const emptyState = getByText("No tasks");

    rerender(<HomeTasks {...props} status="in_progress" />);

    expect(getByText("No tasks")).toBe(emptyState);
  });

  it("says the bucket is filtered, not that there are no tasks at all", () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      status: "cancelled" as const,
    };
    const { getByText, queryByText, rerender } = render(
      <HomeTasks {...props} tasks={tasks} />
    );

    expect(getByText("No tasks in this status")).toBeVisible();
    expect(queryByText("No tasks", { exact: true })).toBeNull();

    rerender(<HomeTasks {...props} tasks={[]} />);

    expect(getByText("No tasks", { exact: true })).toBeVisible();
  });

  it("only shows the status indicator when at least one task exists", async () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      status: "cancelled" as const,
    };
    const { container, rerender } = render(<HomeTasks {...props} tasks={[]} />);

    expect(container.querySelector(".comma-home-tasks-footer")).toBeNull();
    expect(container.querySelector("status-indicator")).toBeNull();

    rerender(<HomeTasks {...props} tasks={[tasks[0]!]} />);
    await waitFor(() => {
      expect(container.querySelector("status-indicator")).not.toBeNull();
    });
    expect(container.querySelector(".comma-home-tasks-footer")).not.toBeNull();
    expect(container.querySelector('[data-role="current"]')).toBeNull();
    expect(container).toHaveTextContent("No tasks in this status");

    rerender(<HomeTasks {...props} tasks={[]} />);
    expect(container.querySelector(".comma-home-tasks-footer")).toBeNull();
    expect(container.querySelector("status-indicator")).toBeNull();
  });

  it("moves focus before hiding the indicator with the last task", async () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      status: "backlog" as const,
    };
    const { container, getByRole, rerender } = render(
      <HomeTasks {...props} tasks={[tasks[0]!]} />
    );
    await waitFor(() => {
      expect(
        container
          .querySelector<HTMLElement>("status-indicator")
          ?.shadowRoot?.querySelector('[role="radio"]')
      ).not.toBeNull();
    });
    const indicator = container.querySelector<HTMLElement>("status-indicator");
    const selectedStatus =
      indicator?.shadowRoot?.querySelector<HTMLElement>('[role="radio"]');

    selectedStatus?.focus();
    expect(indicator?.shadowRoot?.activeElement).toBe(selectedStatus);

    rerender(<HomeTasks {...props} tasks={[]} />);

    expect(getByRole("heading", { name: "Tasks" })).toHaveFocus();
    expect(document.activeElement).not.toBe(document.body);
  });

  it("moves focus out of a page before it becomes an inert outgoing panel", async () => {
    const onOpenTask = vi.fn();
    const props = { onOpenTask, onStatusChange: vi.fn(), tasks };
    const { container, getByRole, rerender } = render(
      <HomeTasks {...props} status="backlog" />
    );
    const focusedCard = getByRole("button", { name: "Task backlog-a" });

    focusedCard.focus();
    expect(focusedCard).toHaveFocus();

    rerender(<HomeTasks {...props} status="in_progress" />);

    const outgoing = container.querySelector('[data-role="outgoing"]');
    expect(outgoing).not.toBeNull();
    expect(outgoing).toHaveAttribute("aria-hidden", "true");
    expect(outgoing).toHaveAttribute("inert");
    expect(
      outgoing?.querySelector('[data-slot="scroll-area-viewport"]')
    ).toHaveAttribute("tabindex", "-1");
    expect(getByRole("heading", { name: "Tasks" })).toHaveFocus();
    expect(document.activeElement).not.toBe(document.body);
    await userEvent.keyboard("{Enter}");
    expect(getByRole("heading", { name: "Tasks" })).toHaveFocus();
    expect(onOpenTask).not.toHaveBeenCalled();
  });

  it("moves focus before the focused task leaves the selected page", async () => {
    const props = { onOpenTask: vi.fn(), onStatusChange: vi.fn(), tasks };
    const { getByRole, queryByRole, rerender } = render(
      <HomeTasks {...props} status="backlog" />
    );
    const focusedCard = getByRole("button", { name: "Task backlog-a" });

    focusedCard.focus();
    expect(focusedCard).toHaveFocus();

    rerender(
      <HomeTasks
        {...props}
        status="backlog"
        tasks={tasks.map((candidateTask) =>
          candidateTask.id === "backlog-a"
            ? { ...candidateTask, statusBucket: "in_progress" }
            : candidateTask
        )}
      />
    );

    expect(getByRole("heading", { name: "Tasks" })).toHaveFocus();
    await waitFor(() => {
      expect(queryByRole("button", { name: "Task backlog-a" })).toBeNull();
    });
    expect(document.activeElement).not.toBe(document.body);
  });

  it("moves focus before an emptied selected page unmounts its viewport", async () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      status: "backlog" as const,
    };
    const { container, getByRole, rerender } = render(
      <HomeTasks {...props} tasks={[tasks[0]!]} />
    );
    const viewport = container.querySelector<HTMLDivElement>(
      '[data-role="current"] [data-slot="scroll-area-viewport"]'
    );

    expect(viewport).toHaveAttribute("tabindex", "0");
    viewport!.focus();
    expect(viewport).toHaveFocus();

    rerender(<HomeTasks {...props} tasks={[]} />);

    expect(getByRole("heading", { name: "Tasks" })).toHaveFocus();
    await waitFor(() => {
      expect(container.querySelector('[data-role="current"]')).toBeNull();
    });
    expect(document.activeElement).not.toBe(document.body);

    rerender(<HomeTasks {...props} ready={false} tasks={[]} />);
    expect(
      container.querySelector(
        '[data-role="current"] [data-slot="scroll-area-viewport"]'
      )
    ).toHaveAttribute("tabindex", "-1");
  });

  it("recovers instantly when the selection scrubs back to the displayed bucket", async () => {
    const props = { onOpenTask: vi.fn(), onStatusChange: vi.fn(), tasks };
    const { getAllByTestId, rerender } = render(
      <HomeTasks {...props} status="backlog" />
    );

    rerender(<HomeTasks {...props} status="in_progress" />);
    rerender(<HomeTasks {...props} status="backlog" />);

    await waitFor(() => {
      const cards = getAllByTestId("home-task-card");
      expect(cards).toHaveLength(2);
      expect(cards[0]).toHaveTextContent("Task backlog-a");
    });
  });

  it("reports indicator changes as task status buckets", async () => {
    const onStatusChange = vi.fn();
    const { container } = render(
      <HomeTasks
        onOpenTask={vi.fn()}
        onStatusChange={onStatusChange}
        status="backlog"
        tasks={tasks}
      />
    );

    // The element registers lazily on first mount.
    await waitFor(() => {
      expect(container.querySelector("status-indicator")).not.toBeNull();
    });
    const indicator = container.querySelector("status-indicator");
    indicator!.dispatchEvent(
      new CustomEvent("change", {
        bubbles: true,
        composed: true,
        detail: { index: 4, label: "Cancel", value: "cancel" },
      })
    );

    expect(onStatusChange).toHaveBeenCalledWith("cancelled");
  });

  it("marks tasks that arrive after the initial fill as new", async () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      status: "backlog" as const,
      tasks,
    };
    const { container, getAllByTestId, rerender } = render(<HomeTasks {...props} />);

    rerender(
      <HomeTasks {...props} tasks={[task("backlog-new", "backlog", 9), ...tasks]} />
    );

    await waitFor(() => {
      expect(getAllByTestId("home-task-card")).toHaveLength(3);
    });
    const newItem = container.querySelector('[data-state="new"]');
    expect(newItem).not.toBeNull();
    expect(newItem).toHaveTextContent("Task backlog-new");

    // After the pop finishes the card settles, rejoining the FLIP glide.
    await waitFor(
      () => {
        expect(container.querySelector('[data-state="new"]')).toBeNull();
      },
      { timeout: 1_000 }
    );
  });

  it("cascades cards that arrive together and settles the whole batch", async () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      status: "backlog" as const,
      tasks,
    };
    const { container, getAllByTestId, rerender } = render(<HomeTasks {...props} />);

    rerender(
      <HomeTasks
        {...props}
        tasks={[
          task("backlog-new-a", "backlog", 11),
          task("backlog-new-b", "backlog", 10),
          task("backlog-new-c", "backlog", 9),
          ...tasks,
        ]}
      />
    );

    await waitFor(() => {
      expect(getAllByTestId("home-task-card")).toHaveLength(5);
    });
    const fresh = [...container.querySelectorAll<HTMLElement>('[data-state="new"]')];
    expect(fresh).toHaveLength(3);
    expect(
      fresh.map((item) => item.style.getPropertyValue("--comma-home-tasks-new-index"))
    ).toEqual(["0", "1", "2"]);

    await waitFor(
      () => {
        expect(container.querySelector('[data-state="new"]')).toBeNull();
      },
      { timeout: 1_500 }
    );
  });

  it("measures card offsets only when the cards change", async () => {
    const props = {
      onStatusChange: vi.fn(),
      status: "backlog" as const,
      tasks,
    };
    const { getAllByTestId, rerender } = render(
      <HomeTasks {...props} onOpenTask={vi.fn()} />
    );
    const offsets = vi.spyOn(HTMLElement.prototype, "offsetTop", "get");

    try {
      // The retained Home re-renders its rail as it pauses behind another
      // page. No card moves, so reading offsets would only force a layout.
      rerender(<HomeTasks {...props} onOpenTask={vi.fn()} />);
      expect(offsets).not.toHaveBeenCalled();

      rerender(
        <HomeTasks
          {...props}
          onOpenTask={vi.fn()}
          tasks={[task("backlog-c", "backlog", 4), ...tasks]}
        />
      );
      await waitFor(() => expect(getAllByTestId("home-task-card")).toHaveLength(3));
      expect(offsets).toHaveBeenCalled();
    } finally {
      offsets.mockRestore();
    }
  });

  it("does not animate the very first data fill", async () => {
    const props = {
      onOpenTask: vi.fn(),
      onStatusChange: vi.fn(),
      ready: false,
      status: "backlog" as const,
      tasks: [] as TaskSummaryViewModel[],
    };
    const { container, getAllByTestId, rerender } = render(<HomeTasks {...props} />);

    rerender(<HomeTasks {...props} ready tasks={tasks} />);

    await waitFor(() => {
      expect(getAllByTestId("home-task-card")).toHaveLength(2);
    });
    expect(container.querySelector('[data-state="new"]')).toBeNull();
  });
});
