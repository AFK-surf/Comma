import {
  ProductInboxProjectionProvider,
  useProductInboxProjection,
} from "../../../../product-inbox";
import {
  createProductInboxProjectionHarness,
  testProductLease,
} from "../../../../test/productInboxProjectionHarness";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { initializeCommaI18n } from "@comma/i18n";
import { useMemo, useState, type ComponentProps } from "react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../../../api";
import { ChatTaskPanel } from "../ChatTaskPanel";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../conversation/ConversationView";
import { fixedDraftSource } from "../../composer/conversationDraft";
import type {
  ChatMessage,
  ConversationChannelState,
} from "../../model/conversationChannel";

describe("chat task panel", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
    // Acknowledgements persist in localStorage; keep tests independent.
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

  it.each(["route", "rail"] as const)(
    "keeps %s Properties in sync when only the Inbox task status changes",
    async (variant) => {
      const actions = { ...createActions(), acceptTaskReview: vi.fn() };
      const { setTaskProjection } = renderConversation({
        actions,
        variant,
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
        await waitFor(() => {
          expect(status).not.toHaveAttribute("data-swapping");
          expect(status).toHaveTextContent(label);
        });
        // A summary alone must not invent a versioned review action.
        expect(
          status.closest("aside")?.querySelector(".comma-task-panel-done")
        ).toBeNull();
      }
      expect(actions.acceptTaskReview).not.toHaveBeenCalled();
    }
  );

  it("lists agent-created tasks above the composer in creation order", async () => {
    renderConversation({
      state: settled({
        messages: [
          message("msg_u1", "user", "Translate these"),
          message("msg_a1", "assistant", "Started the first task.", {
            parts: [
              { kind: "markdown", text: "Started the first task." },
              inlineTaskPart("cnv_task_1", "Translate this sentence"),
            ],
          }),
          message("msg_u2", "user", "And one more"),
          message("msg_a2", "assistant", "Started the second task.", {
            parts: [
              { kind: "markdown", text: "Started the second task." },
              inlineTaskPart("cnv_task_2", "Summarize the document"),
            ],
          }),
        ],
      }),
    });

    const panel = await screen.findByTestId("chat-task-panel");
    const titles = [...panel.querySelectorAll(".comma-chat-task-item-title")].map(
      (node) => node.textContent
    );
    expect(titles).toEqual(["Translate this sentence", "Summarize the document"]);
    expect(screen.getByTestId("chat-task-item-cnv_task_1").textContent).toContain(
      "In progress"
    );
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
      statusBucket: "needs_review" as const,
      title: "Review the arrival",
      turnKey: "msg_u1",
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
      statusBucket: "in_progress" as const,
      title: "Cancelled arrival",
      turnKey: "msg_u1",
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

  it("ignores user-authored task mentions and stays out of the side chat", async () => {
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

    renderConversation({ state: taskState("in_progress"), variant: "side-chat" });
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

    // Running again re-docks the task and lifts the old acknowledgement…
    setState(taskState("in_progress"));
    await screen.findByTestId("chat-task-item-cnv_task_1");

    // …so its next settle shows again and asks for a fresh acknowledgement.
    setState(taskState("needs_review"));
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

  it("opts the row out of the shared button press scale", async () => {
    renderConversation({ state: taskState("needs_review") });

    const row = openButton(await screen.findByTestId("chat-task-item-cnv_task_1"));
    expect(row).toHaveAttribute("data-no-press-feedback");
  });

  it("collapses the panel to its header and back", async () => {
    const user = userEvent.setup();
    renderConversation({ state: taskState("needs_review") });

    const panel = await screen.findByTestId("chat-task-panel");
    const toggle = screen.getByTestId("chat-task-panel-toggle");
    expect(toggle.textContent).toContain("1 Task");
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(panel.dataset["collapsed"]).toBeUndefined();

    await user.click(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(panel.dataset["collapsed"]).toBe("true");
    // Folded, the panel is its header alone: no list is left behind it to take
    // focus, reach the a11y tree, or keep following the Tasks.
    expect(screen.queryByTestId("chat-task-panel-list")).toBeNull();
    expect(screen.queryByTestId("chat-task-item-cnv_task_1")).toBeNull();
    expect(toggle.textContent).toContain("1 Task");

    await user.click(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    expect(panel.dataset["collapsed"]).toBeUndefined();
    expect(screen.getByTestId("chat-task-item-cnv_task_1")).toBeTruthy();
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

  it("keeps a running task docked when it is revealed", async () => {
    const user = userEvent.setup();
    renderConversation({ state: taskState("in_progress") });

    const item = await screen.findByTestId("chat-task-item-cnv_task_1");
    expect(screen.queryByTestId("chat-task-dismiss-cnv_task_1")).toBeNull();
    // Open the Task and Reveal in Chat; a running row offers no Dismiss.
    expect(item.querySelectorAll("button")).toHaveLength(2);
    await user.click(screen.getByTestId("chat-task-reveal-cnv_task_1"));
    expect(screen.getByTestId("chat-task-item-cnv_task_1")).toBeTruthy();
  });

  it("opens the task's chat from the row without revealing or clearing it", async () => {
    const user = userEvent.setup();
    const onOpenConversationRef = vi.fn();
    renderConversation({
      onOpenConversationRef,
      state: taskState("needs_review"),
    });

    const item = await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(openButton(item));

    // The same open the Task's chip in the transcript performs.
    expect(onOpenConversationRef).toHaveBeenCalledExactlyOnceWith({
      conversationId: "cnv_task_1",
      kind: "agent_task",
      title: "Translate this sentence",
    });
    // Opening is navigation, not acknowledgement: the settled row stays, and
    // the transcript is not moved to the announcing turn.
    expect(screen.getByTestId("chat-task-item-cnv_task_1")).toBeTruthy();
    expect(document.querySelector('[data-reveal-highlight="true"]')).toBeNull();
  });

  it("splits the row between opening the task and revealing its turn", async () => {
    const user = userEvent.setup();
    const task = {
      archiveVersion: undefined,
      conversationId: "cnv_task_split",
      messageId: "msg_a1",
      needsAttention: false,
      statusBucket: "in_progress" as const,
      title: "Build the release",
      turnKey: "msg_u1",
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
      statusBucket: "needs_review" as const,
      title: "Review the release",
      turnKey: "msg_u1",
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

  it("reveals the announcing turn, remounting it when the window dropped it", async () => {
    const user = userEvent.setup();
    const olderTurns: ChatMessage[] = [
      message("msg_u1", "user", "Start a task"),
      message("msg_a1", "assistant", "Started.", {
        parts: [
          { kind: "markdown", text: "Started." },
          inlineTaskPart("cnv_task_1", "Translate this sentence"),
        ],
      }),
    ];
    const laterTurns: ChatMessage[] = Array.from({ length: 8 }, (_, index) => [
      message(`msg_u${index + 2}`, "user", `Follow-up ${index}`),
      message(`msg_a${index + 2}`, "assistant", `Reply ${index}`),
    ]).flat();
    const { setState } = renderConversation({
      state: settled({ messages: [...olderTurns, ...laterTurns] }),
    });

    const item = await screen.findByTestId("chat-task-item-cnv_task_1");
    // Eight later turns push the task's turn out of the six-turn window.
    expect(document.querySelector('[data-turn-key="msg_u1"]')).toBeNull();

    await user.click(within(item).getByTestId("chat-task-reveal-cnv_task_1"));

    await waitFor(() => {
      expect(document.querySelector('[data-turn-key="msg_u1"]')).toBeTruthy();
    });

    act(() => {
      setState(
        settled({
          messages: [
            ...olderTurns,
            ...laterTurns,
            message("msg_u10", "user", "One more follow-up"),
            message("msg_a10", "assistant", "One more reply"),
          ],
        })
      );
    });

    // Once reveal hands the old turn to the window, a new tail turn advances
    // the bounded suffix instead of retaining every turn after the reveal.
    await waitFor(() => {
      expect(
        document
          .querySelector(".comma-chat-thread")
          ?.getAttribute("data-comma-turn-window-start")
      ).toBe("1");
    });
    expect(document.querySelector('[data-turn-key="msg_u1"]')).toBeNull();
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

function taskState(
  status: string,
  laterTurns: ChatMessage[] = []
): ConversationChannelState {
  return settled({
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
            },
          },
        ],
      }),
      ...laterTurns,
    ],
  });
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
  return {
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
}

function renderConversation({
  actions = createActions(),
  conversationId,
  onOpenConversationRef,
  state: initialState,
  variant = "route",
}: {
  actions?: ConversationViewActions;
  conversationId?: string;
  onOpenConversationRef?: ComponentProps<
    typeof ConversationView
  >["onOpenConversationRef"];
  state: ConversationChannelState;
  variant?: "home" | "rail" | "route" | "side-chat";
}) {
  const projection = createProductInboxProjectionHarness({
    initial: canonicalTaskProjection(initialState),
  });
  const api = stubApi();
  let setViewState: ((next: ConversationChannelState) => void) | undefined;

  function RouteComponent() {
    useProductInboxProjection({ enabled: true, session: testProductLease });
    const [viewState, setState] = useState(initialState);
    const draftSource = useMemo(
      () => fixedDraftSource(viewState.draft),
      [viewState.draft]
    );
    setViewState = setState;
    return (
      <ConversationView
        actions={actions}
        api={api}
        conversationId={conversationId}
        draftSource={draftSource}
        groupId="grp_1"
        onOpenConversationRef={onOpenConversationRef}
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
    <ProductInboxProjectionProvider controller={projection.controller}>
      <RouterProvider router={router} />
    </ProductInboxProjectionProvider>
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

function stubApi() {
  return {
    generateChatSuggestions: vi.fn().mockResolvedValue([]),
  } as unknown as CommaApiClient;
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
      workspaceId: "wsp_1",
      workspaceName: "Workspace",
    })),
  };
}
