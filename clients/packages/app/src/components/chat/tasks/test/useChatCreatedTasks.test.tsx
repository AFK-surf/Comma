import type { ProductInboxListResult, TaskSummary } from "@comma/core-client";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
import { messageReading, type ChatMessage } from "@comma/core/chat";
import {
  focusTurnKey,
  selectActivityFocusTarget,
} from "../../thread/activity/activityFocus";
import { useChatCreatedTasks } from "../useChatCreatedTasks";

afterEach(() => localStorage.clear());

const messages: ChatMessage[] = [
  {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId: "message",
    parts: [],
    refs: [{ kind: "agent_task", conversationId: "task", title: "Message title" }],
    createdTasks: [{ conversationId: "task", title: "Message title" }],
    role: "assistant",
    source: "server",
    status: "completed",
    text: "",
  },
];
const summary: TaskSummary = {
  id: "task",
  group_id: "group",
  kind: "agent_task",
  status: "completed",
  title: "Current title",
  updated_at: 2,
  archive_availability: { allowed: true, reason: null },
};
const list: ProductInboxListResult = {
  activeWorkspaceId: "workspace",
  source: "live-sync",
  items: [
    {
      id: "task",
      conversationId: "task",
      groupId: "group",
      kind: "agent_task",
      workspaceId: "workspace",
      workspaceName: "Workspace",
      source: "salix.conversation",
      status: "completed",
      title: "Current title",
      updatedAt: 2,
      archiveVersion: 2,
      archiveAvailability: { allowed: true, reason: null },
    },
  ],
};

function render(summaries: TaskSummary[] | undefined, transcript = messages) {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "tasks"
        ? list
        : topic.topic === "taskSummaries" && summaries
          ? { summaries }
          : undefined,
  });
  const hook = renderHook(
    () => useChatCreatedTasks({ groupId: "group", messages: transcript }),
    {
      wrapper: ({ children }) => core.wrap(children),
    }
  );
  return { core, ...hook };
}

it("docks a Task with the core's facts, keeps its object while they hold, and drops it once archived", async () => {
  const { core, result, unmount } = render([summary]);
  await waitFor(() =>
    expect(result.current[0]).toMatchObject({
      title: "Current title",
      archiveVersion: 2,
    })
  );
  const before = result.current;
  // The same facts said again (a read of the list that changed nothing).
  act(() => core.emit("taskSummaries", { summaries: [{ ...summary }] }));
  expect(result.current).toBe(before);

  act(() =>
    core.emit("taskSummaries", {
      summaries: [{ ...summary, status: "archived", updated_at: 3 }],
    })
  );
  await waitFor(() => expect(result.current).toEqual([]));
  unmount();
});

it("withholds archive permission while the core does not confirm the facts", async () => {
  const { archive_availability: _, ...unconfirmed } = summary;
  const { result, unmount } = render([unconfirmed]);
  await waitFor(() =>
    expect(result.current[0]).toMatchObject({ title: "Current title" })
  );
  expect(result.current[0]?.archiveVersion).toBeUndefined();
  unmount();
});

it("docks the Task a person's Quick Chat started, revealed at that message's own turn", async () => {
  const { createdTasks: _, ...agentMessage } = messages[0]!;
  // As the core hands it over: the person's words, then the Task they started.
  const spoken: ChatMessage = {
    ...agentMessage,
    messageId: "spoken",
    messageType: "quick_chat",
    parts: [
      { kind: "markdown", text: "Book a table" },
      { kind: "inline-task", task: { conversationId: "task", unavailable: false } },
    ],
    refs: [],
    role: "user",
    text: "Book a table",
  };
  const { result, unmount } = render(
    [summary],
    [{ ...spoken, ...messageReading(spoken) }]
  );
  await waitFor(() =>
    expect(result.current[0]).toMatchObject({
      conversationId: "task",
      messageId: "spoken",
      turnKey: "spoken",
    })
  );
  unmount();
});

/** A message that announces one Task, as the core reads it. */
function announcing(message: ChatMessage, taskId: string): ChatMessage {
  const parts = [
    {
      kind: "inline-task" as const,
      task: { conversationId: taskId, unavailable: false },
    },
  ];
  return { ...message, parts, ...messageReading({ ...message, parts }) };
}

it("names a Quick Chat's Task with the Router's while the Router waits on the Quick Chat", async () => {
  const { createdTasks: _, ...base } = messages[0]!;
  const transcript = [
    { ...base, messageId: "m1", refs: [], role: "user", text: "Plan the trip" },
    announcing(
      { ...base, messageId: "m2", messageType: "quick_chat", refs: [], role: "user" },
      "q"
    ),
    announcing({ ...base, messageId: "m3", refs: [] }, "t"),
  ];
  const running = (id: string): TaskSummary => ({
    ...summary,
    id,
    status: "in_progress",
  });
  const { result, unmount } = render([running("q"), running("t")], transcript);
  await waitFor(() => expect(result.current).toHaveLength(2));

  const target = selectActivityFocusTarget({
    createdTasks: result.current,
    currentTurnKey: focusTurnKey(transcript),
    participantStatus: {
      conversationId: "home",
      participantId: "router",
      state: "active",
      status: "",
      updatedAt: 1,
      waiting: true,
    },
  });
  // The Quick Chat is the Router's current request: its own Task and the one
  // the Router delegated in answer are the turn's.
  expect(target?.tasks.map((task) => task.conversationId)).toEqual(["q", "t"]);
  unmount();
});
