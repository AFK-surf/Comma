import type { Meta, StoryObj } from "@storybook/react-vite";
import { useCallback, useRef, useState } from "react";
import { expect, fn, userEvent, waitFor, within } from "storybook/test";
import type { TaskStatusBucket, TaskSummaryViewModel } from "../task-workspace";
import type { StatusIndicatorElement } from "../status-indicator";
import { HomeTasks } from "./HomeTasks";

const storyTasks: TaskSummaryViewModel[] = [
  {
    activityStatus: "running",
    freshness: "fresh",
    id: "task-summarize",
    statusBucket: "in_progress",
    title: "Summarizing recent OpenAI's update and create a HTML",
    updatedAt: 1_778_112_000,
    worker: "claude",
  },
  {
    activityStatus: "running",
    freshness: "fresh",
    id: "task-ui-library",
    statusBucket: "in_progress",
    title: "Implement UI library to Comma repo",
    updatedAt: 1_778_025_600,
  },
  {
    activityStatus: "queued",
    freshness: "fresh",
    id: "task-refraction",
    statusBucket: "backlog",
    title: "Start on refraction UI library",
    updatedAt: 1_777_939_200,
  },
  {
    activityStatus: "queued",
    freshness: "fresh",
    id: "task-report",
    statusBucket: "backlog",
    title: "Summarizing recent OpenAI's update and create a HTML",
    updatedAt: 1_777_852_800,
    worker: "codex",
  },
  {
    activityStatus: "ready_for_review",
    freshness: "fresh",
    id: "task-review",
    statusBucket: "needs_review",
    title: "Review the launch checklist for the mobile beta",
    updatedAt: 1_777_766_400,
  },
  {
    activityStatus: "done",
    freshness: "fresh",
    id: "task-done",
    statusBucket: "done",
    title: "Collect design tokens for the marketing site refresh",
    updatedAt: 1_777_680_000,
  },
];

function HomeTasksPlayground({
  onOpenTask,
  tasks: initialTasks,
}: {
  onOpenTask: (task: TaskSummaryViewModel) => void;
  tasks: TaskSummaryViewModel[];
}) {
  const [status, setStatus] = useState<TaskStatusBucket>("backlog");
  const [tasks, setTasks] = useState(initialTasks);

  const addTask = useCallback(() => {
    setTasks((current) => [
      {
        activityStatus: "queued",
        freshness: "fresh" as const,
        id: `task-new-${current.length}`,
        statusBucket: status,
        title: "Draft a follow-up plan for the workspace review",
        updatedAt: 1_778_198_400 + current.length,
      },
      ...current,
    ]);
  }, [status]);

  return (
    <div style={{ blockSize: 640, inlineSize: 320 }}>
      <HomeTasks
        onAddTask={addTask}
        onOpenTask={onOpenTask}
        onStatusChange={setStatus}
        status={status}
        tasks={tasks}
      />
    </div>
  );
}

const meta = {
  title: "App components/Home Tasks",
  component: HomeTasks,
  parameters: {
    layout: "centered",
    docs: {
      description: {
        component:
          "Comma home Tasks rail section (Figma Comma-App 1036:28913): status-bound task cards switched by the Status Indicator, with animated card entrances. The plus button in this story appends a task to the active status so the new-card motion can be previewed.",
      },
    },
  },
} satisfies Meta<typeof HomeTasks>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  args: {
    onOpenTask: fn(),
    onStatusChange: fn(),
    status: "backlog",
    tasks: storyTasks,
  },
  render: (args) => (
    <HomeTasksPlayground onOpenTask={args.onOpenTask} tasks={storyTasks} />
  ),
};

export const SwitchesCardsWithIndicator: Story = {
  args: {
    onOpenTask: fn(),
    onStatusChange: fn(),
    status: "backlog",
    tasks: storyTasks,
  },
  render: (args) => (
    <HomeTasksPlayground onOpenTask={args.onOpenTask} tasks={storyTasks} />
  ),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await waitFor(() => {
      expect(canvas.getAllByTestId("home-task-card")).toHaveLength(2);
    });

    await waitFor(() => {
      expect(canvasElement.querySelector("status-indicator")).not.toBeNull();
    });
    const indicator =
      canvasElement.querySelector<StatusIndicatorElement>("status-indicator");
    indicator!.value = "in-progress";
    indicator!.dispatchEvent(
      new CustomEvent("change", {
        bubbles: true,
        composed: true,
        detail: { index: 1, label: "In progress", value: "in-progress" },
      })
    );

    await waitFor(() => {
      const cards = canvas.getAllByTestId("home-task-card");
      expect(cards).toHaveLength(2);
      expect(cards[0]).toHaveTextContent(
        "Summarizing recent OpenAI's update and create a HTML"
      );
    });
  },
};

const LIVE_TITLES = [
  "Draft a follow-up plan for the workspace review",
  "Summarize this week's incident reports",
  "Prepare talking points for the roadmap sync",
  "Collect customer quotes for the launch page",
  "Verify the migration checklist on staging",
];

function NewCardPlayground({
  onOpenTask,
}: {
  onOpenTask: (task: TaskSummaryViewModel) => void;
}) {
  const [status, setStatus] = useState<TaskStatusBucket>("in_progress");
  const [tasks, setTasks] = useState(storyTasks);
  const counterRef = useRef(0);

  const addTasks = useCallback(
    (count: number) => {
      const base = counterRef.current;
      counterRef.current += count;
      const created = Array.from({ length: count }, (_, index) => ({
        activityStatus: "running",
        freshness: "fresh" as const,
        id: `task-live-${base + index}`,
        statusBucket: status,
        title: LIVE_TITLES[(base + index) % LIVE_TITLES.length]!,
        updatedAt: 1_778_200_000 + base + index,
      }));
      setTasks((current) => [...created, ...current]);
    },
    [status]
  );

  return (
    <div style={{ blockSize: 640, inlineSize: 320 }}>
      <div
        style={{
          display: "flex",
          gap: "var(--spacing-md)",
          justifyContent: "flex-end",
          paddingBlockEnd: "var(--spacing-lg)",
        }}
      >
        <button onClick={() => addTasks(1)} type="button">
          +1 task
        </button>
        <button onClick={() => addTasks(3)} type="button">
          +3 tasks
        </button>
      </div>
      <div style={{ blockSize: 560 }}>
        <HomeTasks
          onOpenTask={onOpenTask}
          onStatusChange={setStatus}
          status={status}
          tasks={tasks}
        />
      </div>
    </div>
  );
}

export const NewCardArrival: Story = {
  args: {
    onOpenTask: fn(),
    onStatusChange: fn(),
    status: "in_progress",
    tasks: storyTasks,
  },
  parameters: {
    docs: {
      description: {
        story:
          'The new-card moment: siblings glide aside (FLIP), then after an intent beat the card materializes — fade, 8px drop, 0.97 scale, blur dissolve. Cards arriving together cascade with one reveal-stagger beat each; the displacement happens once for the whole batch. Use "+1 task" / "+3 tasks" to trigger arrivals into the selected status.',
      },
    },
  },
  render: (args) => <NewCardPlayground onOpenTask={args.onOpenTask} />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await userEvent.click(canvas.getByRole("button", { name: "+3 tasks" }));

    await waitFor(() => {
      const fresh = canvasElement.querySelectorAll('[data-state="new"]');
      expect(fresh).toHaveLength(3);
    });
    const fresh = [
      ...canvasElement.querySelectorAll<HTMLElement>('[data-state="new"]'),
    ];
    expect(
      fresh.map((item) => item.style.getPropertyValue("--comma-home-tasks-new-index"))
    ).toEqual(["0", "1", "2"]);

    // The batch settles after its cascade so the cards rejoin the FLIP flow.
    await waitFor(
      () => {
        expect(canvasElement.querySelector('[data-state="new"]')).toBeNull();
      },
      { timeout: 2_000 }
    );
  },
};

/** The selected status is empty while Tasks sit in other buckets: filtered,
    not empty, and the copy says so. HomeTasks renders whatever status it is
    given; on Home it is HomeTasksRail that keeps an unattended rail off an
    empty bucket. */
export const Empty: Story = {
  args: {
    onOpenTask: fn(),
    onStatusChange: fn(),
    status: "cancelled",
    tasks: storyTasks,
  },
  render: (args) => {
    return (
      <div style={{ blockSize: 640, inlineSize: 320 }}>
        <HomeTasks
          onOpenTask={args.onOpenTask}
          onStatusChange={args.onStatusChange}
          status="cancelled"
          tasks={storyTasks}
        />
      </div>
    );
  },
};

export const NoTasks: Story = {
  args: {
    onOpenTask: fn(),
    onStatusChange: fn(),
    status: "backlog",
    tasks: [],
  },
  render: (args) => (
    <div style={{ blockSize: 640, inlineSize: 320 }}>
      <HomeTasks
        onOpenTask={args.onOpenTask}
        onStatusChange={args.onStatusChange}
        status="backlog"
        tasks={[]}
      />
    </div>
  ),
};
