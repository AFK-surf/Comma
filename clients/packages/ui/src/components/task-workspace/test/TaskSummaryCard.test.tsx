import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { InlineTask } from "../../inline-task";
import { TaskSummaryCard, type TaskSummaryViewModel } from "../TaskSummaryCard";
import type { TaskStatusBucket } from "../taskStatus";

const RESTING_BUCKETS: TaskStatusBucket[] = [
  "backlog",
  "needs_review",
  "done",
  "cancelled",
];

function task(
  statusBucket: TaskStatusBucket,
  overrides: Partial<TaskSummaryViewModel> = {}
): TaskSummaryViewModel {
  return {
    activityStatus: statusBucket === "in_progress" ? "working" : "idle",
    freshness: "fresh",
    id: `task-${statusBucket}`,
    statusBucket,
    title: "Generate the quarterly launch brief",
    updatedAt: Date.UTC(2026, 7, 13),
    ...overrides,
  };
}

const metaRow = (root: HTMLElement) =>
  root.querySelector('[data-slot="task-card-meta-row"]');

it("shows a meeting waiting for recording without claiming the Worker is running", () => {
  render(
    <TaskSummaryCard
      task={task("in_progress", { activityStatus: "meeting_awaiting_recording" })}
    />
  );
  expect(screen.getByText("Waiting for recording")).toBeInTheDocument();
});

describe("Task card progress line", () => {
  it("shimmers the running task's activity", () => {
    const { container } = render(
      <TaskSummaryCard
        task={task("in_progress", { activityStatus: "running_tests" })}
      />
    );

    const progress = container.querySelector(".comma-shiny-text");
    expect(metaRow(container)).toBeTruthy();
    expect(progress).toHaveTextContent("Running tests");
    // The gradient rides on the truncating node itself, so the ellipsis takes
    // the same fill as the text it replaces.
    expect(progress).toHaveClass("truncate");
  });

  it("prefers the last message over the activity label", () => {
    const { container } = render(
      <TaskSummaryCard
        task={task("in_progress", {
          lastMessage: {
            content: "I am checking it now.",
            id: "msg_1",
            role: "assistant",
            roleLabel: "Comma",
          },
        })}
      />
    );

    expect(container.querySelector(".comma-shiny-text")).toHaveTextContent(
      "I am checking it now."
    );
  });

  it.each(RESTING_BUCKETS)("drops the row entirely for %s", (statusBucket) => {
    const { container } = render(<TaskSummaryCard task={task(statusBucket)} />);

    expect(metaRow(container)).toBeNull();
    expect(container.querySelector(".comma-shiny-text")).toBeNull();
  });

  it("keeps a resting task's row gone even when it reports an activity", () => {
    // Needs-review tasks report a "waiting for review" activity; that is a
    // state, not progress, and the status icon already says it.
    const { container } = render(
      <TaskSummaryCard
        task={task("needs_review", { activityStatus: "waiting_for_review" })}
      />
    );

    expect(metaRow(container)).toBeNull();
    expect(screen.queryByText("Needs Review")).toBeNull();
  });

  it("keeps the line on a running task whose activity has gone idle", () => {
    // Idle activity still means running; dropping the line here made a live
    // task look inert on the Comma assistant surface.
    const { container } = render(
      <TaskSummaryCard task={task("in_progress", { activityStatus: "idle" })} />
    );

    expect(metaRow(container)).toBeTruthy();
    expect(container.querySelector(".comma-shiny-text")).toHaveTextContent(
      "In progress"
    );
  });

  it("keeps a stale projection on the running line", () => {
    const { container } = render(
      <TaskSummaryCard task={task("in_progress", { freshness: "stale" })} />
    );

    expect(container.querySelector(".comma-shiny-text")).toHaveTextContent(
      "Stale · Working"
    );
  });
});

describe("Inline Task hover card", () => {
  const link = <a aria-label="Open Generate the quarterly launch brief" href="#task" />;

  it("shows the same shimmering line as the Task card", () => {
    const { baseElement } = render(
      <InlineTask defaultOpen link={link} task={task("in_progress")} />
    );

    expect(baseElement.querySelector(".comma-shiny-text")).toHaveTextContent("Working");
  });

  it("shows progress on a running task whose freshness is still unknown", () => {
    // The app defaults an inline Task to freshness "unknown" until its preview
    // loads (MessageInlineElements.taskSummary). That used to replace the
    // progress text outright, so the hover card only ever said "Status
    // unknown" while the task was plainly running.
    const { baseElement } = render(
      <InlineTask
        defaultOpen
        link={link}
        task={task("in_progress", { activityStatus: "idle", freshness: "unknown" })}
      />
    );

    expect(baseElement.querySelector(".comma-shiny-text")).toHaveTextContent(
      "Status unknown · In progress"
    );
  });

  it("shows no line for a resting task", () => {
    const { baseElement } = render(
      <InlineTask
        defaultOpen
        link={link}
        task={task("needs_review", { activityStatus: "waiting_for_review" })}
      />
    );

    expect(baseElement.querySelector('[data-slot="task-card-meta-row"]')).toBeNull();
  });
});
