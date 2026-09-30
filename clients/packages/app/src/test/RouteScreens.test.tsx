import userEvent from "@testing-library/user-event";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster } from "@comma/ui";
import { createContext, useContext } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { HomeRoute } from "../components/RouteScreens";
import type { ChatMessage } from "../components/chat/model/conversationChannel";
import { ChatSidebarProvider } from "../components/chat-sidebar/ChatSidebarContext";

const analytics = vi.hoisted(() => ({ begin: vi.fn(), finish: vi.fn() }));
vi.mock("../analytics/client", () => ({
  beginCommaMessageSend: (surface: string) => {
    analytics.begin(surface);
    return analytics.finish;
  },
  commaAnalyticsIdentity: () => "user-a",
  captureCommaExperience: vi.fn(),
}));

const harness = vi.hoisted(() => ({
  chatState: { status: "loading" } as
    | { status: "loading" }
    | { status: "hidden" }
    | { status: "unauthorized" }
    | { status: "error"; message: string }
    | {
        groupId: string;
        status: "ready";
        workspaceId: string;
        conversation: {
          id: string;
          kind: "user_chat";
          messages: never[];
          status: string;
          title: string;
          group_id: string;
        };
      }
    | {
        groupId: string;
        status: "provisioning";
        workspaceId: string;
        retryAfterSeconds: number;
      },
  conversationChannel: {
    send: vi.fn(),
    setDraft: vi.fn(),
  },
  conversationState: {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    connection: "live",
    conversation: undefined,
    draft: "",
    draftAttachments: [],
    errorKind: undefined as string | undefined,
    lastBackoffMs: 0,
    messages: [] as ChatMessage[],
    pending: [] as {
      clientRequestId: string;
      createdAt: number;
      error: string | undefined;
      skills: { location: string }[] | undefined;
      status: "sending" | "failed";
      text: string;
    }[],
    serverMessages: [],
    status: "ready" as string,
    syncWarning: undefined,
  },
  homeConversationTarget: undefined as
    | { conversationId: string; groupId: string; workspaceId: string }
    | undefined,
  leaseChannel: {
    getSnapshot: vi.fn(),
    send: vi.fn(),
  },
  release: vi.fn(),
  retireHomeConversationTarget: vi.fn(),
  retryWorkspaceChat: vi.fn(),
  resolveWorkspaceChat: vi.fn(),
  retain: vi.fn(),
}));

// Workspace updates must notify HomeRoute even when its props are unchanged.
// Context preserves the mounted route and editor across each test handoff.
const WorkspaceChatStateContext = createContext<typeof harness.chatState>({
  status: "loading",
});

vi.mock("../components/AuthGate", () => ({
  useCommaAuth: () => ({ userEmail: "person@example.com" }),
}));

// The rail's data wiring is covered by its own tests; stub it so this suite
// stays focused on the home layout.
vi.mock("../components/home/HomeTasksRail", () => ({
  HomeTasksRail: () => (
    <div data-comma-tasks-rail="live" data-testid="home-tasks-section" />
  ),
  HomeTasksRailLoading: () => (
    <div data-comma-tasks-rail="loading" data-testid="home-tasks-section" />
  ),
}));

vi.mock("../components/chat/ChatProvider", () => ({
  isStaleChatSessionError: () => false,
  useChatApi: () => ({}),
  useChatRegistry: () => ({
    beginAttempt: () => {
      const leases: { release(): void }[] = [];
      return {
        isCurrent: () => true,
        release: () => {
          for (const lease of leases) {
            lease.release();
          }
        },
        retain: (...args: [string, string, string]) => {
          const lease = harness.retain(...args);
          leases.push(lease);
          return lease;
        },
        run: (operation: (api: object, signal: AbortSignal) => unknown) =>
          Promise.resolve(operation({}, new AbortController().signal)),
        signal: new AbortController().signal,
      };
    },
    getHomeConversationTarget: () => harness.homeConversationTarget,
    rememberHomeConversationTarget: (
      workspaceId: string,
      groupId: string,
      conversationId: string
    ) => {
      harness.homeConversationTarget = { conversationId, groupId, workspaceId };
    },
    retireHomeConversationTarget: (groupId: string, conversationId: string) => {
      harness.retireHomeConversationTarget(groupId, conversationId);
      if (
        harness.homeConversationTarget?.groupId === groupId &&
        harness.homeConversationTarget.conversationId === conversationId
      ) {
        harness.homeConversationTarget = undefined;
      }
    },
  }),
}));

vi.mock("../components/chat/useWorkspaceChat", () => ({
  resolveWorkspaceChat: (...args: unknown[]) => harness.resolveWorkspaceChat(...args),
  useWorkspaceChat: () => ({
    retry: harness.retryWorkspaceChat,
    state: useContext(WorkspaceChatStateContext),
  }),
}));

vi.mock("../components/chat/conversation/useConversation", () => ({
  useConversation: () => ({
    attachFiles: vi.fn(),
    channel: harness.conversationChannel,
    discard: vi.fn(),
    // Tests edit the harness state and rerender; the draft is read at render.
    draftSource: {
      getSnapshot: () => harness.conversationState.draft,
      subscribe: () => () => {},
    },
    refresh: vi.fn(),
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: harness.conversationChannel.send,
    setDraft: harness.conversationChannel.setDraft,
    state: harness.conversationState,
  }),
}));

vi.mock("../components/chat/useWorkspaceSkills", () => ({
  useWorkspaceSkills: () => [],
}));

function HomeRouteUnderTest() {
  return (
    <ChatSidebarProvider>
      <HomeRoute />
    </ChatSidebarProvider>
  );
}

const homeUi = () => (
  <WorkspaceChatStateContext.Provider value={harness.chatState}>
    <Toaster />
    <HomeRouteUnderTest />
  </WorkspaceChatStateContext.Provider>
);

describe("HomeRoute startup draft", () => {
  beforeEach(() => {
    analytics.begin.mockClear();
    analytics.finish.mockClear();
    harness.chatState = { status: "loading" };
    harness.homeConversationTarget = undefined;
    harness.conversationChannel.send.mockReset();
    harness.conversationChannel.setDraft.mockReset();
    harness.conversationState.activity = undefined;
    harness.conversationState.assistantDraft = undefined;
    harness.conversationState.draft = "";
    harness.conversationState.errorKind = undefined;
    harness.conversationState.messages = [];
    harness.conversationState.pending = [];
    harness.conversationState.status = "ready";
    harness.leaseChannel.getSnapshot.mockReset();
    harness.leaseChannel.getSnapshot.mockReturnValue(harness.conversationState);
    harness.leaseChannel.send.mockReset();
    harness.release.mockReset();
    harness.retireHomeConversationTarget.mockReset();
    harness.retryWorkspaceChat.mockReset();
    harness.resolveWorkspaceChat.mockReset();
    harness.retain.mockReset();
    harness.retain.mockReturnValue({
      channel: harness.leaseChannel,
      release: harness.release,
    });
  });

  it("keeps recovery visible when workspace resolves before deferred dismissals run", async () => {
    vi.useFakeTimers();
    const view = render(homeUi());
    try {
      harness.chatState = { status: "hidden" };
      view.rerender(homeUi());
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1000);
      });
      expect(screen.getByRole("button", { name: "Retry" })).toBeVisible();
      expect(screen.getByTestId("workspace-resolution")).toHaveTextContent(
        "No workspace is available for chat."
      );
    } finally {
      view.unmount();
      await act(async () => {
        await vi.runOnlyPendingTimersAsync();
      });
      vi.useRealTimers();
    }
  });

  it("keeps retry and the draft when startup and send both resolve hidden", async () => {
    let resolveSend!: (value: { status: "hidden" }) => void;
    harness.resolveWorkspaceChat.mockReturnValue(
      new Promise((resolve) => {
        resolveSend = resolve;
      })
    );
    const view = render(homeUi());
    const prompt = screen.getByRole("textbox", { name: "AI prompt" });
    await userEvent.type(prompt, "recover this");
    await userEvent.click(screen.getByRole("button", { name: "Send" }));
    await act(async () => {
      harness.chatState = { status: "hidden" };
      resolveSend({ status: "hidden" });
    });
    view.rerender(homeUi());
    const retry = await screen.findByRole("button", { name: "Retry" });
    await waitFor(() => expect(retry).toBeVisible());
    expect(prompt).toHaveTextContent("recover this");
    await userEvent.click(retry);
    expect(harness.retryWorkspaceChat).toHaveBeenCalledOnce();
  });

  it("reports Home workspace resolution rejection as failure and restores the draft", async () => {
    harness.resolveWorkspaceChat.mockRejectedValue(
      new Error("private resolution failure")
    );
    render(homeUi());
    await userEvent.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "retry resolution"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByTestId("home-pending-error")).toBeVisible();
    await waitFor(() =>
      expect(analytics.finish).toHaveBeenCalledExactlyOnceWith("failed", "server")
    );
    expect(analytics.begin).toHaveBeenCalledExactlyOnceWith("home");
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(
      "retry resolution"
    );
  });

  it.each(["accepted", "failed"] as const)(
    "reports Home native admission %s with runtime boundary",
    async (outcome) => {
      const admission = deferred<void>();
      const completion = deferred<void>();
      void completion.promise.catch(() => undefined);
      harness.resolveWorkspaceChat.mockResolvedValue(readyResolution());
      harness.leaseChannel.send.mockReturnValue(
        Object.assign(completion.promise, { accepted: admission.promise })
      );
      render(homeUi());
      await userEvent.type(
        screen.getByRole("textbox", { name: "AI prompt" }),
        "native send"
      );
      await userEvent.click(screen.getByRole("button", { name: "Send" }));
      await waitFor(() => expect(harness.leaseChannel.send).toHaveBeenCalled());
      expect(analytics.finish).not.toHaveBeenCalled();
      if (outcome === "accepted") admission.resolve();
      else admission.reject(new Error("private admission failure"));
      await waitFor(() =>
        expect(analytics.finish).toHaveBeenCalledExactlyOnceWith(outcome, "runtime")
      );
      expect(analytics.begin).toHaveBeenCalledExactlyOnceWith("home");
      completion.reject(new Error("later delivery failure"));
      await Promise.resolve();
      expect(analytics.finish).toHaveBeenCalledTimes(1);
    }
  );

  it("consumes the startup draft before a delayed send can remount the composer", async () => {
    const resolution = deferred<ReadyResolution>();
    const send = deferred<void>();
    harness.resolveWorkspaceChat.mockReturnValue(resolution.promise);
    harness.leaseChannel.send.mockReturnValue(send.promise);
    const { rerender } = render(homeUi());

    await userEvent.type(screen.getByRole("textbox", { name: "AI prompt" }), "run it");
    await userEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(/^$/);
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
    harness.chatState = readyState();
    rerender(homeUi());

    expect(harness.conversationChannel.setDraft).not.toHaveBeenCalled();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(/^$/);
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );

    resolution.resolve(readyResolution());
    await waitFor(() =>
      expect(harness.leaseChannel.send).toHaveBeenCalledWith("run it")
    );
    send.resolve();
    await waitFor(() => expect(harness.release).toHaveBeenCalledOnce());
    expect(analytics.begin).toHaveBeenCalledExactlyOnceWith("home");
    expect(analytics.finish).toHaveBeenCalledExactlyOnceWith("accepted", "server");
    rerender(homeUi());

    expect(harness.conversationChannel.setDraft).not.toHaveBeenCalled();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(/^$/);
    expect(screen.getByRole("textbox", { name: "AI prompt" })).not.toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });

  it("restores the consumed startup draft when the channel rejects before acceptance", async () => {
    const send = deferred<void>();
    harness.resolveWorkspaceChat.mockResolvedValue(readyResolution());
    harness.leaseChannel.send.mockReturnValue(send.promise);
    const { rerender } = render(homeUi());

    await userEvent.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "retry me"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(/^$/);

    send.reject(new Error("send failed"));
    harness.chatState = readyState();
    rerender(homeUi());
    await waitFor(() =>
      expect(harness.conversationChannel.setDraft).toHaveBeenCalledWith("retry me")
    );
    expect(harness.release).toHaveBeenCalledOnce();
    expect(await screen.findByTestId("home-pending-error")).toHaveTextContent(
      "Chat is temporarily unavailable"
    );
    expect(screen.queryByText("send failed")).toBeNull();
    expect(analytics.finish).toHaveBeenCalledExactlyOnceWith("failed", "server");
  });

  it("keeps Workspace recovery available when startup send and resolution both fail", async () => {
    const resolution = deferred<ReadyResolution>();
    harness.resolveWorkspaceChat.mockReturnValue(resolution.promise);
    const { rerender } = render(homeUi());

    await userEvent.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "recover this"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send" }));

    harness.chatState = {
      message: "Workspace resolution failed",
      status: "error",
    };
    rerender(homeUi());
    resolution.reject(new Error("Startup send failed"));

    expect(await screen.findByTestId("workspace-resolution")).toHaveTextContent(
      "Chat is temporarily unavailable"
    );
    expect(screen.queryByText("Startup send failed")).toBeNull();
    expect(screen.queryByText("Workspace resolution failed")).toBeNull();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).not.toHaveAttribute(
      "aria-disabled"
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(
      "recover this"
    );

    const retry = screen.getByRole("button", { name: "Retry" });
    await waitFor(() => expect(retry).toBeVisible());
    expect(screen.queryByTestId("home-pending-error")).toBeNull();
    await userEvent.click(retry);
    expect(harness.retryWorkspaceChat).toHaveBeenCalledOnce();
  });

  it("keeps the composer empty when an accepted send later becomes a failed row", async () => {
    const completion = deferred<void>();
    void completion.promise.catch(() => undefined);
    harness.resolveWorkspaceChat.mockResolvedValue(readyResolution());
    harness.leaseChannel.send.mockReturnValue(
      Object.assign(completion.promise, { accepted: Promise.resolve() })
    );
    render(homeUi());

    await userEvent.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "charge it"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => expect(harness.release).toHaveBeenCalledOnce());

    harness.conversationState.pending = [
      {
        clientRequestId: "req_failed",
        createdAt: 1,
        error: "Payment required",
        skills: undefined,
        status: "failed",
        text: "charge it",
      },
    ];
    completion.reject(new Error("Payment required"));
    await Promise.resolve();

    expect(harness.conversationChannel.setDraft).not.toHaveBeenCalled();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(/^$/);
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("gates the startup composer while the Workspace is provisioning", async () => {
    harness.chatState = {
      groupId: "grp_reserved",
      retryAfterSeconds: 2,
      status: "provisioning",
      workspaceId: "wsp_reserved",
    };
    render(homeUi());

    expect(screen.getByRole("textbox", { name: "AI prompt" })).not.toHaveAttribute(
      "aria-disabled"
    );
    expect(screen.getByRole("button", { name: "Voice input" })).toBeEnabled();
    expect(await screen.findByTestId("workspace-resolution")).toHaveTextContent(
      "Preparing your workspace. You can chat when it is ready."
    );

    await userEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(harness.retryWorkspaceChat).toHaveBeenCalledOnce();
    expect(harness.resolveWorkspaceChat).not.toHaveBeenCalled();
    expect(screen.getByTestId("home-responsive-layout")).toContainElement(
      screen.getByTestId("home-tasks-section")
    );
    expect(
      screen.queryByRole("heading", { name: "What do you want to do" })
    ).toBeNull();
  });

  it("hides the unavailable access control in the compact startup composer", () => {
    const view = render(homeUi());

    expect(screen.queryByRole("button", { name: "Full-access" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Add attachment" })).toBeNull();
    expect(view.container.querySelector('input[type="file"]')).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeVisible();
  });

  it("preserves the editor node, focus, selection, and draft across Workspace handoff", async () => {
    harness.conversationChannel.setDraft.mockImplementation((draft: string) => {
      harness.conversationState.draft = draft;
    });
    const { rerender } = render(homeUi());
    const editor = screen.getByRole("textbox", { name: "AI prompt" });

    await userEvent.type(editor, "keep typing");
    setRichEditorCaret(editor, 4);
    expect(editor).toHaveFocus();

    harness.chatState = readyState();
    harness.conversationState.status = "loading";
    rerender(homeUi());

    await waitFor(() =>
      expect(harness.conversationChannel.setDraft).toHaveBeenCalledWith("keep typing")
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toBe(editor);
    expect(editor).toHaveFocus();
    expect(editor).toHaveTextContent("keep typing");
    expect(window.getSelection()?.anchorOffset).toBe(4);
    expect(window.getSelection()?.focusOffset).toBe(4);
  });

  it("keeps the Home composer mounted during the first conversation snapshot", () => {
    harness.chatState = readyState();
    harness.conversationState.status = "loading";

    render(homeUi());

    expect(screen.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    expect(screen.getByTestId("home-responsive-layout")).toContainElement(
      screen.getByRole("textbox", { name: "AI prompt" })
    );
  });

  it("renders the complete Home composition while Workspace Chat reloads", () => {
    render(homeUi());

    const homeLayout = screen.getByTestId("home-responsive-layout");
    expect(homeLayout).toContainElement(screen.getByTestId("home-greet-rail"));
    expect(homeLayout).toContainElement(screen.getByTestId("chat-empty"));
    expect(homeLayout).toContainElement(screen.getByTestId("home-tasks-rail"));
    expect(homeLayout).toContainElement(screen.getByTestId("home-tasks-section"));
    expect(screen.getByTestId("home-tasks-section")).toHaveAttribute(
      "data-comma-tasks-rail",
      "live"
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toBeEnabled();
    expect(
      screen.queryByRole("heading", { name: "What do you want to do" })
    ).toBeNull();
  });

  it("keeps Comma assistant history while Workspace Chat reloads", () => {
    harness.homeConversationTarget = {
      conversationId: "cnv_home",
      groupId: "grp_test",
      workspaceId: "wsp_home",
    };
    harness.conversationState.messages = [
      {
        attachments: [],
        blocksKey: undefined,
        clientRequestId: undefined,
        createdAt: 1_720_000_002,
        createdBy: undefined,
        delivery: "sent",
        error: undefined,
        messageId: "msg-settings-history",
        refs: [],
        role: "assistant",
        source: "server",
        status: "completed",
        text: "Kept through Settings",
      },
    ];

    render(homeUi());

    expect(screen.getByText("Kept through Settings")).toBeVisible();
    expect(screen.queryByTestId("chat-empty")).toBeNull();
    expect(screen.queryByRole("button", { name: "Voice input" })).toBeNull();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).not.toHaveAttribute(
      "data-placeholder",
      "Do anything"
    );
  });

  it("retires the retained conversation when Workspace Chat resolves hidden", async () => {
    harness.homeConversationTarget = {
      conversationId: "cnv_stale",
      groupId: "grp_test",
      workspaceId: "wsp_stale",
    };
    harness.chatState = { status: "hidden" };

    render(homeUi());

    expect(harness.retireHomeConversationTarget).toHaveBeenCalledWith(
      "grp_test",
      "cnv_stale"
    );
    expect(harness.homeConversationTarget).toBeUndefined();
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    expect(screen.getByTestId("home-responsive-layout")).toContainElement(
      screen.getByTestId("home-tasks-section")
    );
    expect(screen.getByTestId("home-tasks-section")).toHaveAttribute(
      "data-comma-tasks-rail",
      "loading"
    );
    expect(await screen.findByTestId("workspace-resolution")).toHaveTextContent(
      "No workspace is available for chat."
    );
    expect(
      screen.queryByRole("heading", { name: "What do you want to do" })
    ).toBeNull();
  });

  it.each([
    {
      feedback: "Your sign-in expired. Sign in again.",
      label: "unauthorized",
      state: { status: "unauthorized" } as const,
    },
    {
      feedback: "Chat is temporarily unavailable",
      label: "resolver error",
      state: { message: "Workspace resolution failed", status: "error" } as const,
    },
  ])("keeps the complete Home composition for $label", async ({ feedback, state }) => {
    harness.chatState = state;

    render(homeUi());

    const homeLayout = screen.getByTestId("home-responsive-layout");
    expect(homeLayout).toContainElement(screen.getByTestId("home-greet-rail"));
    expect(homeLayout).toContainElement(screen.getByTestId("chat-empty"));
    expect(homeLayout).toContainElement(screen.getByTestId("home-tasks-rail"));
    expect(homeLayout).toContainElement(screen.getByTestId("home-tasks-section"));
    expect(screen.getByTestId("home-tasks-section")).toHaveAttribute(
      "data-comma-tasks-rail",
      state.status === "unauthorized" ? "loading" : "live"
    );
    expect(await screen.findByTestId("workspace-resolution")).toHaveTextContent(
      feedback
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).not.toHaveAttribute(
      "aria-disabled"
    );
    expect(screen.queryByText("Workspace resolution failed")).toBeNull();
    expect(
      screen.queryByRole("heading", { name: "What do you want to do" })
    ).toBeNull();

    if (state.status === "error") {
      await userEvent.click(screen.getByRole("button", { name: "Retry" }));
      expect(harness.retryWorkspaceChat).toHaveBeenCalledOnce();
    }
  });

  it("keeps a retained Home conversation bound when Workspace revalidation fails", async () => {
    harness.homeConversationTarget = {
      conversationId: "cnv_retained",
      groupId: "grp_test",
      workspaceId: "wsp_retained",
    };
    harness.chatState = {
      message: "Workspace revalidation failed",
      status: "error",
    };
    harness.conversationState.draft = "Keep this draft";

    render(homeUi());

    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(
      "Keep this draft"
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).not.toHaveAttribute(
      "aria-disabled",
      "true"
    );
    expect(await screen.findByTestId("workspace-resolution")).toHaveTextContent(
      "Chat is temporarily unavailable"
    );
    expect(screen.queryByText("Workspace revalidation failed")).toBeNull();
    expect(screen.getByTestId("home-responsive-layout")).toContainElement(
      screen.getByTestId("home-tasks-section")
    );

    await userEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(harness.retryWorkspaceChat).toHaveBeenCalledOnce();
  });

  it("renders the complete Home composition before the first message", () => {
    harness.chatState = readyState();
    harness.conversationState.status = "ready";
    harness.conversationState.errorKind = undefined;
    harness.conversationState.messages = [];
    harness.conversationState.pending = [];

    render(homeUi());

    const homeLayout = screen.getByTestId("home-responsive-layout");
    expect(homeLayout).toContainElement(screen.getByTestId("home-greet-rail"));
    expect(homeLayout).toContainElement(screen.getByTestId("chat-empty"));
    expect(homeLayout).toContainElement(screen.getByTestId("home-tasks-rail"));
    expect(screen.queryByRole("button", { name: "Full-access" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeVisible();
    expect(
      screen.queryByRole("heading", { name: "What do you want to do" })
    ).toBeNull();
  });

  it("provides responsive Greet and Tasks rails without header triggers", () => {
    harness.chatState = readyState();
    harness.conversationState.status = "error";
    harness.conversationState.errorKind = "unauthorized";
    render(homeUi());

    const greetRail = screen.getByTestId("home-greet-rail");
    const tasksRail = screen.getByTestId("home-tasks-rail");

    expect(screen.getByTestId("home-responsive-layout")).toContainElement(greetRail);
    expect(screen.getByTestId("home-responsive-layout")).toContainElement(tasksRail);
    expect(greetRail).toHaveAttribute("id", "comma-home-greet-panel");
    expect(tasksRail).toHaveAttribute("id", "comma-home-tasks-panel");
    // The fold marker now comes from the shell's measurement of the route, not
    // from each rail reading a container-query marker back out of computed
    // style. An unmeasured Home reports both rails open.
    expect(greetRail).toHaveAttribute("data-folded", "false");
    expect(tasksRail).toHaveAttribute("data-folded", "false");
    expect(screen.queryByRole("button", { name: "Show Greet panel" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Show Tasks panel" })).toBeNull();
  });
});

type ReadyResolution = ReturnType<typeof readyResolution>;

function readyResolution() {
  return {
    conversation: {
      group_id: "grp_chat",
      id: "cnv_chat",
      kind: "user_chat" as const,
      messages: [] as never[],
      status: "open",
      title: "Chat",
    },
    groupId: "grp_chat",
    status: "ready" as const,
    workspaceId: "wsp_chat",
  };
}

function readyState() {
  return readyResolution();
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function setRichEditorCaret(editor: HTMLElement, offset: number) {
  editor.focus();
  const textNode = editor.firstChild;
  if (!textNode) throw new Error("expected Home editor text node");
  const range = document.createRange();
  range.setStart(textNode, offset);
  range.collapse(true);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
}
