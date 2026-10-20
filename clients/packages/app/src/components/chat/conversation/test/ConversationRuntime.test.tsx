import type { ChatViewValue } from "@comma/core/contract";
import {
  idleConversationChannelState,
  type ChatMessage,
  type ConversationChannelState,
} from "@comma/core/chat";
import { advance } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, fireEvent, render, screen, within } from "@comma/test-utils/render";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRouter,
} from "@tanstack/react-router";
import { onTestFinished, describe, expect, it } from "vitest";
import { ChatProvider } from "../../ChatProvider";
import { ConversationView } from "../ConversationView";
import { useConversation } from "../useConversation";

const session = { audience: "https://api.comma.test", sessionId: "session-user-1" };
const message: ChatMessage = {
  attachments: [],
  clientRequestId: "req_retry",
  delivery: "sent",
  messageId: "msg_source",
  parts: [{ kind: "markdown", text: "Please try again" }],
  refs: [],
  role: "user",
  source: "server",
  text: "Please try again",
};

function Conversation() {
  const { draftSource, state, ...actions } = useConversation("wsp_1", "grp_1", "cnv_1");
  return (
    <ConversationView
      actions={actions}
      draftSource={draftSource}
      state={state}
      workspaceId="wsp_1"
      groupId="grp_1"
      conversationId="cnv_1"
    />
  );
}

async function setup(
  initial: Partial<ConversationChannelState>,
  calls?: (name: string, params: unknown) => unknown
) {
  installNativeBridgeMock({
    platform: "electron",
    self: { windowId: "win_main", role: "main-window" },
  });
  let state = { ...idleConversationChannelState, status: "ready" as const, ...initial };
  let revision = 1;
  const core = createScriptedCore({
    values: (topic): ChatViewValue | undefined =>
      topic.topic === "chatView"
        ? {
            session,
            state,
            revision,
            draftEpoch: 0,
            lease: { leaseId: "lease_1", subscriberId: "win_main:grp_1/cnv_1" },
          }
        : undefined,
    calls: calls ?? (() => ({ revision })),
  });
  const router = createRouter({
    routeTree: createRootRoute({ component: Conversation }),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  const rendered = render(
    core.wrap(
      <ChatProvider
        productLease={{ ...session, authorityInstanceId: "authority-1", generation: 1 }}
      >
        <RouterProvider router={router} />
      </ChatProvider>
    )
  );
  onTestFinished(() => {
    rendered.unmount();
    core.client.close();
  });
  await advance(0);
  return {
    core,
    async show(change: Partial<ConversationChannelState>) {
      await act(async () => {
        state = { ...state, ...change };
        revision += 1;
        core.changed("chatView");
      });
      await advance(0);
    },
  };
}

async function markDone() {
  fireEvent.click(screen.getByRole("button", { name: "Needs Review" }));
  await advance(0);
  fireEvent.click(screen.getByRole("menuitem", { name: "Done" }));
  await advance(0);
}

// Core recovery tests own HTTP errors and reconnection. These tests exercise the actual
// channel, hooks and React view against the core protocol, including outgoing calls.
describe("a conversation renderer on the core protocol", () => {
  it("keeps a conflicted Task canonical and sends its refreshed version on an explicit retry", async () => {
    const task = {
      group_id: "grp_1",
      id: "cnv_1",
      kind: "agent_task" as const,
      title: "Review Task",
      status: "ready_for_review" as const,
      review_version: 2,
      updated_at: 2,
    };
    let rejectChange = true;
    const t = await setup({ conversation: task }, (name) => {
      if (name === "chatView.setTaskStatus" && rejectChange)
        throw Object.assign(new Error("conflict"), {
          code: "chat_refused",
          status: 409,
        });
      return { revision: 1 };
    });
    await markDone();
    expect(screen.getByRole("alert")).toHaveTextContent("Couldn’t change the status");
    expect(screen.getByTestId("task-conversation-status")).toHaveAttribute(
      "data-status",
      "needs_review"
    );
    const expected = {
      workspace: "wsp_1",
      group: "grp_1",
      conversation: "cnv_1",
      surface: "win_main",
      session,
      status: "completed",
    };
    expect(t.core.sentTo("chatView.setTaskStatus")).toEqual([
      { ...expected, expectedUpdatedAt: 2 },
    ]);
    await t.show({ conversation: { ...task, review_version: 3, updated_at: 3 } });
    expect(t.core.sentTo("chatView.setTaskStatus")).toHaveLength(1);
    rejectChange = false;
    await markDone();
    expect(t.core.sentTo("chatView.setTaskStatus")).toEqual([
      { ...expected, expectedUpdatedAt: 2 },
      { ...expected, expectedUpdatedAt: 3 },
    ]);
    await t.show({ conversation: { ...task, status: "completed", updated_at: 4 } });
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByTestId("task-conversation-status")).toHaveAttribute(
      "data-status",
      "done"
    );
  });

  it.each([
    { reason: "server", error: undefined, label: "Send failed" },
    {
      reason: "billing",
      error: "Billing is temporarily unavailable. Try again later.",
      label: "Send failed · Billing is temporarily unavailable. Try again later.",
    },
  ])(
    "shows a $reason failure and retries the same pending message",
    async ({ error, label }) => {
      const pending = {
        clientRequestId: "req_retry",
        createdAt: 1,
        error,
        skills: undefined,
        status: "failed" as const,
        text: message.text,
      };
      const t = await setup({
        messages: [{ ...message, delivery: "failed", source: "pending", error }],
        pending: [pending],
      });
      const failed = screen.getByTestId("chat-failed-row");
      expect(screen.getAllByTestId("chat-failed-row")).toHaveLength(1);
      expect(failed).toHaveTextContent(label);
      expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(
        /^$/
      );
      expect(t.core.sentTo("chatView.retry")).toEqual([]);

      fireEvent.click(within(failed).getByRole("button", { name: "Retry" }));
      await advance(0);
      expect(t.core.sentTo("chatView.retry")).toEqual([
        {
          clientRequestId: "req_retry",
          workspace: "wsp_1",
          group: "grp_1",
          conversation: "cnv_1",
          surface: "win_main",
          session,
        },
      ]);
      expect(t.core.sentTo("chatView.send")).toEqual([]);

      await t.show({ messages: [message], serverMessages: [message], pending: [] });
      expect(screen.queryByTestId("chat-failed-row")).toBeNull();
      expect(screen.getAllByText(message.text, { exact: true })).toHaveLength(1);
    }
  );

  it("keeps the transcript while reconnecting and shows the participant stop", async () => {
    const participantStatus = {
      conversationId: "cnv_1",
      participantId: "ptp_1",
      state: "active" as const,
      status: "is thinking...",
      updatedAt: 1,
    };
    const t = await setup({
      connection: "live",
      messages: [message],
      serverMessages: [message],
      participantStatus,
    });
    const status = screen.getByTestId("participant-status-slot");
    expect(status).toHaveAttribute("data-state", "active");
    expect(status).toHaveTextContent("Thinking");
    await t.show({ connection: "reconnecting" });
    expect(screen.getByText(message.text, { exact: true })).toBeVisible();
    await t.show({
      connection: "live",
      participantStatus: {
        ...participantStatus,
        state: "stopped",
        status: "",
        updatedAt: 2,
      },
    });
    expect(status).toHaveAttribute("data-state", "stopped");
    expect(status).toHaveAttribute("data-active", "false");
  });
});
