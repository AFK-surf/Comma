import type { Meta, StoryObj } from "@storybook/react-vite";
import { useRef, useState } from "react";
import { expect, fn, userEvent, waitFor, within } from "storybook/test";
import { ResizeContainer } from "../../dev";
import type { TaskStatusBucket } from "../task-workspace";
import { TaskWorkspace, type TaskWorkspaceProps, type TaskWorkspaceTask } from ".";

const storyTasks: TaskWorkspaceTask[] = [
  {
    activityStatus: "idle",
    conversationId: "conversation-backlog",
    groupId: "group-comma",
    updatedAt: 1_777_939_200,
    freshness: "fresh",
    id: "task-backlog",
    messages: [],
    statusBucket: "backlog",
    title: "Summarize the latest product feedback into themes",
    worker: "codex",
    workspaceId: "workspace-comma",
  },
  {
    activityStatus: "running_tests",
    conversationId: "conversation-progress",
    groupId: "group-comma",
    updatedAt: 1_778_025_600,
    freshness: "fresh",
    id: "task-progress",
    lastMessage: {
      content: "I am checking the source references and running the final tests.",
      id: "progress-message",
      role: "assistant",
      roleLabel: "Comma",
    },
    messages: [
      {
        content: "Create an implementation-ready brief for the new onboarding flow.",
        id: "progress-user-message",
        role: "user",
        roleLabel: "You",
      },
      {
        content:
          "I have grouped the findings and am checking the source references now.",
        id: "progress-assistant-message",
        role: "assistant",
        roleLabel: "Comma",
      },
    ],
    statusBucket: "in_progress",
    title: "Prepare the onboarding implementation brief",
    worker: "claude",
    workspaceId: "workspace-comma",
  },
  {
    activityStatus: "ready_for_review",
    conversationId: "conversation-review",
    groupId: "group-comma",
    updatedAt: 1_778_112_000,
    freshness: "unknown",
    id: "task-review",
    messages: [
      {
        content: "The launch checklist is ready for your review.",
        id: "review-message",
        role: "assistant",
        roleLabel: "Comma",
      },
    ],
    statusBucket: "needs_review",
    title: "Review the desktop launch checklist",
    worker: "codex",
    workspaceId: "workspace-comma",
  },
  {
    activityStatus: "completed",
    conversationId: "conversation-done",
    groupId: "group-comma",
    updatedAt: 1_777_852_800,
    freshness: "fresh",
    id: "task-done",
    messages: [],
    statusBucket: "done",
    title: "Publish the weekly customer insight digest",
    worker: "claude",
    workspaceId: "workspace-comma",
  },
  {
    activityStatus: "failed",
    conversationId: "conversation-cancelled",
    groupId: "group-comma",
    updatedAt: 1_777_766_400,
    freshness: "stale",
    id: "task-cancelled",
    messages: [],
    statusBucket: "cancelled",
    title: "Archive the superseded research workspace",
    worker: "codex",
    workspaceId: "workspace-comma",
  },
];

const meta = {
  title: "App components/Tasks/Task Workspace",
  component: TaskWorkspace,
  args: {
    onChatWithComma: fn(),
    onCopyLink: fn(),
    onCreateTask: fn(),
    onExpand: fn(),
    onRetry: fn(),
    onSendMessage: fn(async () => undefined),
    tasks: storyTasks,
    userEmail: "alex@comma.app",
    workerFilterOptions: ["codex", "claude"],
  },
  parameters: {
    layout: "fullscreen",
  },
  render: (args, { globals }) => (
    <TaskWorkspaceFrame {...args} isDark={globals.theme === "dark"} />
  ),
} satisfies Meta<typeof TaskWorkspace>;

export default meta;
type Story = StoryObj<typeof meta>;

function TaskWorkspaceFrame(args: TaskWorkspaceProps) {
  return (
    <ResizeContainer
      centered
      defaultCenterMode
      defaultMode="relative"
      defaultRect={{ width: 1440, height: 860 }}
      defaultResizable
      minHeight={480}
      minWidth={720}
    >
      <div className="absolute inset-0 overflow-hidden rounded-xl border border-primary bg-main-panel-bg shadow-lg">
        <TaskWorkspace {...args} />
      </div>
    </ResizeContainer>
  );
}

export const Complete: Story = {
  name: "Complete workspace",
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    // The route carries no content header any more; the board itself is the
    // workspace's first paint.
    await expect(canvas.queryByRole("heading", { name: "Tasks" })).toBeNull();
    await expect(
      canvas.getAllByRole("button", {
        name: /Prepare the onboarding implementation brief/,
      })[0]
    ).toBeVisible();
  },
};

export const Empty: Story = {
  args: {
    tasks: [],
  },
  name: "Empty workspace",
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(canvas.getByText("No tasks")).toBeVisible();
    await expect(canvas.getByRole("button", { name: "Create new task" })).toBeVisible();
    await expect(canvas.queryByText("Backlog")).not.toBeInTheDocument();
  },
};

export const ListView: Story = {
  args: {
    initialView: "list",
  },
  name: "List view",
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(canvas.getByTestId("tasks-list")).toBeVisible();
    await expect(canvas.getByRole("button", { name: "Filter tasks" })).toBeVisible();
    await expect(canvas.getByRole("button", { name: "Board view" })).toBeVisible();
  },
};

export const SelectedTask: Story = {
  args: {
    initialTaskId: "task-progress",
  },
  name: "Selected task",
  play: async ({ args, canvasElement }) => {
    const canvas = within(canvasElement);
    const panel = canvas.getByRole("complementary", { name: "Task chat" });
    await expect(panel).toBeVisible();
    const input = canvas.getByLabelText("Continue task");
    const reply = "Please include the handoff owners.";

    await userEvent.type(input, reply);
    const sendButton = canvas.getByRole("button", { name: "Send message" });
    await expect(input).toHaveValue(reply);
    await expect(sendButton).toBeEnabled();
    await userEvent.click(sendButton);
    await waitFor(() =>
      expect(args.onSendMessage).toHaveBeenCalledWith(
        expect.objectContaining({ id: "task-progress" }),
        reply
      )
    );
  },
};

export const Loading: Story = {
  args: {
    loading: true,
    tasks: [],
  },
  name: "Loading",
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const loading = canvas.getByRole("status", { name: "Loading task" });
    await expect(loading).toBeVisible();
    await expect(loading).toHaveAttribute("aria-busy", "true");
    await expect(
      canvasElement.querySelector('[data-slot="task-workspace-loading-state"]')
    ).toBeInTheDocument();
  },
};

export const ErrorState: Story = {
  args: {
    loadError: "fixture-load-error",
    onRetry: fn(),
    tasks: [],
  },
  name: "Load error",
  play: async ({ args, canvasElement }) => {
    const canvas = within(canvasElement);
    await expect(canvas.getByRole("heading", { name: "Error" })).toBeVisible();
    await expect(
      canvas.getByText("Task could not be refreshed. Try again in a moment.")
    ).toBeVisible();
    await userEvent.click(canvas.getByRole("button", { name: "Try again" }));
    await expect(args.onRetry).toHaveBeenCalledOnce();
  },
};

/**
 * The persisted-order contract: drops report through `onTaskOrderChange`, the
 * arrangement is fed back through `taskOrder`, and a remount (a reload, in
 * app terms) restores it. The "store" here is a ref that outlives the
 * workspace instance, standing in for the Group-stored order on the server.
 */
function PersistedOrderPlayground(args: TaskWorkspaceProps) {
  const storeRef = useRef<Partial<Record<TaskStatusBucket, readonly string[]>>>({});
  const [epoch, setEpoch] = useState(0);
  const [, forceRender] = useState(0);

  return (
    <div className="flex h-[720px] flex-col gap-md p-md">
      <button
        className="self-start rounded-md border border-primary px-lg py-xs text-sm"
        data-testid="persisted-order-reload"
        onClick={() => setEpoch((current) => current + 1)}
        type="button"
      >
        Reload workspace
      </button>
      <div className="relative min-h-0 flex-1 overflow-hidden rounded-xl border border-primary bg-main-panel-bg">
        <TaskWorkspace
          {...args}
          key={epoch}
          onTaskOrderChange={(bucket, ids) => {
            storeRef.current = { ...storeRef.current, [bucket]: ids };
            forceRender((current) => current + 1);
          }}
          taskOrder={storeRef.current}
        />
      </div>
    </div>
  );
}

export const PersistedOrder: Story = {
  name: "Persisted order",
  args: {
    tasks: [
      ...storyTasks,
      {
        activityStatus: "idle",
        conversationId: "conversation-backlog-2",
        groupId: "group-comma",
        updatedAt: 1_777_852_800,
        freshness: "fresh",
        id: "task-backlog-2",
        messages: [],
        statusBucket: "backlog",
        title: "Collect design tokens for the marketing refresh",
        worker: "claude",
        workspaceId: "workspace-comma",
      },
    ],
  },
  render: (args) => <PersistedOrderPlayground {...args} />,
};
