import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, userEvent, waitFor, within } from "storybook/test";
import { InlineTask } from "./InlineTask";
import type { TaskStatusBucket, TaskSummaryViewModel } from "../task-workspace";

const task = (
  statusBucket: TaskStatusBucket,
  overrides: Partial<TaskSummaryViewModel> = {}
): TaskSummaryViewModel => ({
  activityStatus: statusBucket === "in_progress" ? "working" : "idle",
  freshness: "fresh",
  id: `task-${statusBucket}`,
  statusBucket,
  title: "Generate the quarterly launch brief",
  updatedAt: Date.UTC(2026, 7, 13),
  ...overrides,
});

const meta = {
  title: "App components/Tasks/Inline Task",
  component: InlineTask,
  args: {
    link: <a aria-label="Open Generate the quarterly launch brief" href="#task" />,
    task: task("backlog"),
  },
  decorators: [
    (Story) => (
      <p className="max-w-[640px] text-sm leading-6 text-primary">
        The latest work is tracked in <Story /> and will stay linked in the reply.
      </p>
    ),
  ],
  parameters: {
    layout: "centered",
  },
} satisfies Meta<typeof InlineTask>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Backlog: Story = {};

export const InProgress: Story = {
  args: {
    task: task("in_progress"),
  },
};

export const NeedsReview: Story = {
  args: {
    task: task("needs_review", { activityStatus: "waiting_for_review" }),
  },
};

export const Done: Story = {
  args: {
    task: task("done"),
  },
};

export const Cancelled: Story = {
  args: {
    task: task("cancelled"),
  },
};

export const LongTitle: Story = {
  args: {
    link: <a aria-label="Open long Task title" href="#task" />,
    task: task("in_progress", {
      title:
        "Investigate every remaining launch-readiness risk across desktop, web, and service integrations",
    }),
  },
};

export const Unavailable: Story = {
  args: {
    dataTestId: "inline-task-unavailable-story",
    link: undefined,
    task: task("backlog", { id: "unavailable", title: "" }),
    unavailable: true,
  },
};

export const HoverPreview: Story = {
  args: {
    dataTestId: "inline-task-hover-story",
    defaultOpen: true,
    task: task("in_progress", {
      activityStatus: "working",
      freshness: "stale",
    }),
  },
  play: async ({ canvasElement }) => {
    const page = within(canvasElement.ownerDocument.body);
    await waitFor(() => expect(page.getByRole("tooltip")).toBeVisible());
    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("tooltip")).toBeNull());
  },
};
