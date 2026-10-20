import { CoreProvider } from "@comma/core-client";
import { useProductInboxProjection } from "../../../../product-inbox";
import { createProductInboxProjectionHarness } from "../../../../test/productInboxProjectionHarness";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { initializeCommaI18n } from "@comma/i18n";
import { useMemo, useState } from "react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ChatTaskPanel } from "../ChatTaskPanel";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../conversation/ConversationView";
import { fixedDraftSource } from "../../composer/conversationDraft";
import type { ChatMessage, ConversationChannelState } from "@comma/core/chat";
import { createdTasksOf } from "@comma/core/chat";

describe("chat task panel", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
    window.localStorage.clear();
  });

  it("removes summary properties when the detail owner denies access", async () => {
    const summary = taskState("ready_for_review");
    const { setState, setTaskProjection } = renderConversation({
      conversationId: "cnv_task_1",
      state: settled({ conversation: undefined, status: "loading" }),
    });
    act(() => setTaskProjection(summary));
    expect(
      await screen.findByRole("heading", { name: "Translate this sentence" })
    ).toBeVisible();
    expect(screen.getByTestId("task-panel-properties")).toBeVisible();

    act(() => {
      setState(
        settled({ conversation: undefined, status: "error", errorKind: "forbidden" })
      );
      // The list can still hold an earlier summary after a detail denial.
      setTaskProjection(summary);
    });
    await waitFor(() =>
      expect(screen.queryByTestId("task-panel-properties")).toBeNull()
    );
    expect(
      screen.queryByRole("heading", { name: "Translate this sentence" })
    ).toBeNull();
    expect(screen.getByText("This conversation cannot be opened")).toBeVisible();
  });

  it("keeps route Properties in sync when only the Inbox task status changes", async () => {
    const actions = { ...createActions(), setTaskStatus: vi.fn() };
    const { setTaskProjection } = renderConversation({
      actions,
      state: settled({
        conversation: {
          id: "cnv_task_1",
          group_id: "grp_1",
          kind: "agent_task",
          status: "in_progress",
          title: "Translate this sentence",
        },
      }),
    });

    const status = await screen.findByTestId("task-conversation-status");
    // Without a task summary, fall back to the conversation snapshot.
    expect(status).toHaveTextContent("In progress");

    for (const [rawStatus, label] of [
      ["needs_review", "Needs Review"],
      ["completed", "Done"],
      ["in_progress", "In progress"],
    ] as const) {
      // The Inbox advances independently; the open conversation stays stale.
      act(() => setTaskProjection(taskState(rawStatus)));
      await waitFor(() => expect(status).toHaveTextContent(label));
    }
    expect(actions.setTaskStatus).not.toHaveBeenCalled();
  });

  it("tracks a task's status as its projection moves on", async () => {
    const { setState } = renderConversation({ state: taskState("in_progress") });

    const item = await screen.findByTestId("chat-task-item-cnv_task_1");
    expect(item.textContent).toContain("In progress");
    expect(item.querySelector(".comma-shiny-text")).toBeTruthy();

    setState(taskState("needs_review"));
    await waitFor(() => {
      expect(screen.getByTestId("chat-task-item-cnv_task_1").textContent).toContain(
        "Needs Review"
      );
    });
    expect(
      screen.getByTestId("chat-task-item-cnv_task_1").querySelector(".comma-shiny-text")
    ).toBeNull();
  });

  it("settles an arriving row only from its own reveal animation", async () => {
    const task = {
      archiveVersion: 7,
      conversationId: "cnv_task_arrival",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      statusBucket: "needs_review" as const,
      title: "Review the arrival",
      turnKey: "msg_u1",
      version: 1,
    };
    const actions = {
      onArchive: vi.fn().mockResolvedValue(undefined),
      onDismiss: vi.fn(),
      onOpen: vi.fn(),
      onReveal: vi.fn(),
    };
    const { rerender } = render(<ChatTaskPanel {...actions} items={[task]} />);
    const item = await screen.findByTestId("chat-task-item-cnv_task_arrival");

    expect(item).toHaveAttribute("data-arriving", "true");
    fireNamedAnimationEvent(
      openButton(item),
      "animationend",
      "comma-chat-task-item-reveal"
    );
    fireNamedAnimationEvent(item, "animationend", "another-animation");
    expect(item).toHaveAttribute("data-arriving", "true");

    fireNamedAnimationEvent(item, "animationend", "comma-chat-task-item-reveal");
    expect(item).not.toHaveAttribute("data-arriving");

    rerender(
      <ChatTaskPanel {...actions} items={[{ ...task, archiveVersion: undefined }]} />
    );
    expect(screen.getByTestId("chat-task-item-cnv_task_arrival")).toBe(item);
    expect(item).not.toHaveAttribute("data-arriving");

    rerender(<ChatTaskPanel {...actions} items={[task]} />);
    expect(screen.getByTestId("chat-task-item-cnv_task_arrival")).toBe(item);
    expect(item).not.toHaveAttribute("data-arriving");
  });

  it("settles an arriving row when its reveal animation is cancelled", async () => {
    const task = {
      archiveVersion: undefined,
      conversationId: "cnv_task_cancelled_arrival",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      statusBucket: "in_progress" as const,
      title: "Cancelled arrival",
      turnKey: "msg_u1",
      version: 1,
    };
    render(
      <ChatTaskPanel
        items={[task]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
      />
    );
    const item = await screen.findByTestId("chat-task-item-cnv_task_cancelled_arrival");
    fireNamedAnimationEvent(item, "animationcancel", "comma-chat-task-item-reveal");

    expect(item).not.toHaveAttribute("data-arriving");
  });

  it("ignores user-authored task mentions and stays out of the rail", async () => {
    const { unmount } = renderConversation({
      state: settled({
        messages: [
          message("msg_u1", "user", "Check [Task](comma:task/cnv_task_9)", {
            refs: [{ conversationId: "cnv_task_9", kind: "agent_task" }],
          }),
          message("msg_a1", "assistant", "Sure."),
        ],
      }),
    });
    await waitFor(() => {
      expect(
        document.querySelector('[data-slot="chat-assistant-output"]')
      ).toBeTruthy();
    });
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();
    unmount();

    renderConversation({ state: taskState("in_progress"), variant: "rail" });
    await waitFor(() => {
      expect(
        document.querySelector('[data-slot="chat-assistant-output"]')
      ).toBeTruthy();
    });
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();
  });

  it("clears an acknowledged settled task until it runs again", async () => {
    const user = userEvent.setup();
    const { setState } = renderConversation({ state: taskState("done") });

    // Acknowledging a settled row commits the clearance in the same beat: the
    // row leaves by unmounting, with no exit motion to wait out.
    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-reveal-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();

    // Running again re-docks the task…
    setState(taskState("in_progress", [], 2));
    await screen.findByTestId("chat-task-item-cnv_task_1");

    // …and its next settle is a newer version than the one acknowledged, so it
    // shows again and asks for a fresh acknowledgement.
    setState(taskState("needs_review", [], 3));
    await waitFor(() => {
      expect(screen.getByTestId("chat-task-item-cnv_task_1").textContent).toContain(
        "Needs Review"
      );
    });
    await user.click(screen.getByTestId("chat-task-reveal-cnv_task_1"));
    await waitFor(() => {
      expect(screen.queryByTestId("chat-task-panel")).toBeNull();
    });
  });

  it("shows a newer settle that this device never saw run", async () => {
    const user = userEvent.setup();
    const { setState } = renderConversation({ state: taskState("done") });
    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();

    // The Task ran and settled again while no panel here watched it run.
    setState(taskState("needs_review", [], 5));
    await screen.findByTestId("chat-task-item-cnv_task_1");
  });

  it("keeps a dismissed task cleared when it changes without running again", async () => {
    const user = userEvent.setup();
    const { setState } = renderConversation({ state: taskState("needs_review") });
    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();

    // The review is accepted elsewhere: a newer version of the same run.
    setState(taskState("completed", [], 1, 9));
    await waitFor(() => expect(screen.queryByTestId("chat-task-panel")).toBeNull());
    expect(screen.queryByTestId("chat-task-item-cnv_task_1")).toBeNull();
  });

  it("keeps a dismissal when another surface still sees the task running", async () => {
    const user = userEvent.setup();
    renderConversation({ state: taskState("done") });
    // The rail reads the same chat with facts that can lag: it still has the
    // Task running long after it settled.
    renderConversation({ state: taskState("in_progress"), variant: "rail" });

    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));

    // The running copy on the other surface does not lift the acknowledgement.
    await waitFor(() => expect(screen.queryByTestId("chat-task-panel")).toBeNull());
  });

  it("docks every task but mounts only the rows near the scrollport", async () => {
    const turns = Array.from({ length: 40 }, (_, index) => [
      message(`msg_u${index}`, "user", `Start task ${index}`),
      message(`msg_a${index}`, "assistant", `Started task ${index}.`, {
        parts: [
          { kind: "markdown", text: `Started task ${index}.` },
          inlineTaskPart(`cnv_task_${index}`, `Task ${index}`),
        ],
      }),
    ]).flat();
    renderConversation({ state: settled({ messages: turns }) });

    const panel = await screen.findByTestId("chat-task-panel");
    expect(screen.getByTestId("chat-task-panel-toggle").textContent).toContain(
      "40 Tasks"
    );
    // Five rows show at a time; the rest of the history is not in the DOM.
    const rows = panel.querySelectorAll(".comma-chat-task-item");
    expect(rows.length).toBeGreaterThanOrEqual(5);
    expect(rows.length).toBeLessThan(10);
    expect(rows[0]?.textContent).toContain("Task 0");
    // Assistive tech still hears the whole list's size and each row's place.
    const first = rows[0]!.closest("li");
    expect(first?.getAttribute("aria-posinset")).toBe("1");
    expect(first?.getAttribute("aria-setsize")).toBe("40");
  });

  it("highlights only the message that announced the task", async () => {
    const user = userEvent.setup();
    renderConversation({ state: taskState("needs_review") });

    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-reveal-cnv_task_1"));

    await waitFor(() => {
      expect(document.querySelector('[data-reveal-highlight="true"]')).not.toBeNull();
    });
    const highlighted = document.querySelectorAll('[data-reveal-highlight="true"]');
    // The announcing sentence alone: the assistant message's body, not its
    // turn, not the user message that prompted it, and not the article's
    // hover-action row.
    expect(highlighted).toHaveLength(1);
    const marked = highlighted[0]!;
    expect(marked.classList.contains("comma-chat-assistant-response-body")).toBe(true);
    expect(marked.closest("[data-message-id]")?.getAttribute("data-message-id")).toBe(
      "msg_a1"
    );
  });

  it("dismisses a settled task without revealing its turn", async () => {
    const user = userEvent.setup();
    const laterTurns: ChatMessage[] = Array.from({ length: 8 }, (_, index) => [
      message(`msg_u${index + 2}`, "user", `Follow-up ${index}`),
      message(`msg_a${index + 2}`, "assistant", `Reply ${index}`),
    ]).flat();
    renderConversation({
      state: taskState("needs_review", laterTurns),
    });

    const item = await screen.findByTestId("chat-task-item-cnv_task_1");
    expect(document.querySelector('[data-turn-key="msg_u1"]')).toBeNull();
    // Open the Task, Dismiss, Reveal in Chat.
    expect(item.querySelectorAll("button")).toHaveLength(3);

    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();
    // Hiding the row never anchors the announcing turn.
    expect(document.querySelector('[data-turn-key="msg_u1"]')).toBeNull();
  });

  it("splits the row between opening the task and revealing its turn", async () => {
    const user = userEvent.setup();
    const task = {
      archiveVersion: undefined,
      conversationId: "cnv_task_split",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      statusBucket: "in_progress" as const,
      title: "Build the release",
      turnKey: "msg_u1",
      version: 1,
    };
    const onOpen = vi.fn();
    const onReveal = vi.fn();
    render(
      <ChatTaskPanel
        items={[task]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={onOpen}
        onReveal={onReveal}
      />
    );

    const item = await screen.findByTestId("chat-task-item-cnv_task_split");
    await user.click(openButton(item));
    expect(onOpen).toHaveBeenCalledExactlyOnceWith(task, "chat");
    expect(onReveal).not.toHaveBeenCalled();

    await user.click(
      screen.getByRole("button", { name: "Reveal in chat: Build the release" })
    );
    expect(onReveal).toHaveBeenCalledExactlyOnceWith(task);
    expect(onOpen).toHaveBeenCalledOnce();
  });

  it("keeps archive with the settled row's Reveal and Dismiss controls", async () => {
    const user = userEvent.setup();
    const onArchive = vi.fn().mockResolvedValue(undefined);
    const onDismiss = vi.fn();
    const onOpen = vi.fn();
    const onReveal = vi.fn();
    const task = {
      archiveVersion: 7,
      conversationId: "cnv_task_archive",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      statusBucket: "needs_review" as const,
      title: "Review the release",
      turnKey: "msg_u1",
      version: 1,
    };
    render(
      <ChatTaskPanel
        items={[task]}
        onArchive={onArchive}
        onDismiss={onDismiss}
        onOpen={onOpen}
        onReveal={onReveal}
      />
    );

    const item = await screen.findByTestId("chat-task-item-cnv_task_archive");
    const archiveButton = screen.getByRole("button", {
      name: "Archive task",
    });
    const actions = item.querySelector(".comma-chat-task-item-actions");
    expect(item.querySelectorAll("button")).toHaveLength(4);
    expect(actions?.contains(archiveButton)).toBe(true);
    expect(
      actions?.contains(screen.getByTestId("chat-task-dismiss-cnv_task_archive"))
    ).toBe(true);
    expect(
      actions?.contains(screen.getByTestId("chat-task-reveal-cnv_task_archive"))
    ).toBe(true);

    await user.click(archiveButton);

    expect(onOpen).not.toHaveBeenCalled();
    expect(onReveal).not.toHaveBeenCalled();
    expect(onDismiss).not.toHaveBeenCalled();
    await user.click(screen.getByRole("menuitem", { name: "Archive task" }));
    expect(onArchive).toHaveBeenCalledExactlyOnceWith(task);
  });
});

function inlineTaskPart(conversationId: string, title: string) {
  return {
    kind: "inline-task",
    task: {
      conversationId,
      status: "in_progress",
      title,
      unavailable: false,
    },
  } as const;
}

function fireNamedAnimationEvent(
  target: Element,
  type: "animationcancel" | "animationend",
  animationName: string
) {
  const event = new Event(type, { bubbles: true });
  Object.defineProperty(event, "animationName", { value: animationName });
  fireEvent(target, event);
}

/** The row's own press target: it opens the Task. */
function openButton(item: HTMLElement): HTMLElement {
  const button = item.querySelector<HTMLElement>(".comma-chat-task-item-row");
  if (!button) throw new Error("task row has no open button");
  return button;
}

/** When each fixture state's Task started its latest run, as Salix says it. */
const runsOf = new WeakMap<ConversationChannelState, number>();

function taskState(
  status: string,
  laterTurns: ChatMessage[] = [],
  /** When the Task's latest run started (`run_started_at`). */
  run = 1,
  /** The Task's metadata version (`updated_at`): a rename or review acceptance moves it on. */
  updatedAt = run
): ConversationChannelState {
  const state = settled({
    messages: [
      message("msg_u1", "user", "Translate this"),
      message("msg_a1", "assistant", "Started the task.", {
        parts: [
          { kind: "markdown", text: "Started the task." },
          {
            kind: "inline-task",
            task: {
              conversationId: "cnv_task_1",
              status,
              title: "Translate this sentence",
              unavailable: false,
              updatedAt,
            },
          },
        ],
      }),
      ...laterTurns,
    ],
  });
  runsOf.set(state, run);
  return state;
}

function createActions(): ConversationViewActions {
  return {
    attachFiles: vi.fn(),
    discard: vi.fn(),
    refresh: vi.fn(),
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: vi.fn(),
    setDraft: vi.fn(),
  };
}

function settled(
  overrides: Partial<ConversationChannelState> = {}
): ConversationChannelState {
  return {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    connection: "live",
    conversation: {
      id: "cnv_1",
      group_id: "grp_1",
      kind: "user_chat",
      status: "completed",
      title: "Chat",
    },
    draft: "",
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    messages: [],
    participantStatus: undefined,
    pending: [],
    serverMessages: [],
    status: "ready",
    syncWarning: undefined,
    ...overrides,
  };
}

function message(
  messageId: string,
  role: string,
  text: string,
  overrides: Partial<ChatMessage> = {}
): ChatMessage {
  const built: ChatMessage = {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts: [{ kind: "markdown", text }],
    refs: [],
    role,
    source: "server",
    status: "completed",
    text,
    ...overrides,
  };
  // The Tasks an agent's message announces, as the core names them.
  return role === "user"
    ? built
    : { ...built, ...createdTasksOf(built.parts ?? [], built.refs) };
}

function renderConversation({
  actions = createActions(),
  conversationId,
  state: initialState,
  variant = "route",
}: {
  actions?: ConversationViewActions;
  conversationId?: string;
  state: ConversationChannelState;
  variant?: "home" | "rail" | "route";
}) {
  const projection = createProductInboxProjectionHarness({
    initial: canonicalTaskProjection(initialState),
  });
  let setViewState: ((next: ConversationChannelState) => void) | undefined;

  function RouteComponent() {
    useProductInboxProjection({ enabled: true });
    const [viewState, setState] = useState(initialState);
    const draftSource = useMemo(
      () => fixedDraftSource(viewState.draft),
      [viewState.draft]
    );
    setViewState = setState;
    return (
      <ConversationView
        actions={actions}
        live
        conversationId={conversationId}
        draftSource={draftSource}
        groupId="grp_1"
        state={viewState}
        variant={variant}
        workspaceId="wsp_1"
      />
    );
  }

  const rootRoute = createRootRoute({ component: Outlet });
  const conversationRoute = createRoute({
    component: RouteComponent,
    getParentRoute: () => rootRoute,
    path: "/",
  });
  const inboxRoute = createRoute({
    component: () => null,
    getParentRoute: () => rootRoute,
    path: "/inbox",
  });
  const targetConversationRoute = createRoute({
    component: () => null,
    getParentRoute: () => rootRoute,
    path: "/inbox/$workspaceId/$groupId/$conversationId",
  });
  const router = createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([
      conversationRoute,
      inboxRoute,
      targetConversationRoute,
    ]),
  });

  const result = render(
    <CoreProvider client={projection.controller}>
      <RouterProvider router={router} />
    </CoreProvider>
  );
  return {
    ...result,
    setTaskProjection: (next: ConversationChannelState) => {
      projection.emit(canonicalTaskProjection(next));
    },
    setState: (next: ConversationChannelState) => {
      projection.emit(canonicalTaskProjection(next));
      setViewState?.(next);
    },
  };
}

// Fixture server state is supplied separately from the transcript render path.
function canonicalTaskProjection(state: ConversationChannelState) {
  const tasks = state.messages.flatMap((entry) =>
    entry.role === "user"
      ? []
      : (entry.parts ?? []).flatMap((part) =>
          part.kind === "inline-task" && part.task.conversationId ? [part.task] : []
        )
  );
  return {
    activeWorkspaceId: "wsp_1",
    source: "live-sync" as const,
    items: tasks.map((task) => ({
      conversationId: task.conversationId!,
      groupId: "grp_1",
      id: task.conversationId!,
      kind: "agent_task" as const,
      source: "salix.conversation" as const,
      status: task.status ?? "in_progress",
      title: task.title ?? "",
      updatedAt: task.updatedAt ?? 1,
      runStartedAt: runsOf.get(state) ?? 1,
      workspaceId: "wsp_1",
      workspaceName: "Workspace",
    })),
  };
}
