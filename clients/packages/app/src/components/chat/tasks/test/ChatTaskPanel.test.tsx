import type { ChatQuestionPart } from "@comma/chat-contract";
import { CoreProvider } from "@comma/core-client";
import type { ChatMessage, ConversationChannelState } from "@comma/core/chat";
import { createdTasksOf } from "@comma/core/chat";
import { initializeCommaI18n } from "@comma/i18n";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { useMemo, useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useProductInboxProjection } from "../../../../product-inbox";
import { createProductInboxProjectionHarness } from "../../../../test/productInboxProjectionHarness";
import { fixedDraftSource } from "../../composer/conversationDraft";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../conversation/ConversationView";
import { ChatTaskPanel } from "../ChatTaskPanel";
import type { ChatAttentionCard } from "../useChatAttentionCards";
import type { ChatCreatedTask } from "../useChatCreatedTasks";

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

  it("moves a task from the running pill to the attention focus strip when it needs review", async () => {
    const user = userEvent.setup();
    const { setState } = renderConversation({ state: taskState("in_progress") });

    const activePill = await screen.findByTestId("chat-task-panel-toggle");
    expect(activePill).toHaveTextContent("1 running");
    await user.click(activePill);
    const item = await screen.findByTestId("chat-task-item-cnv_task_1");
    expect(item.textContent).toContain("In progress");
    expect(item.querySelector(".comma-shiny-text")).toBeTruthy();

    setState(taskState("needs_review"));
    await waitFor(() => {
      expect(screen.queryByTestId("chat-task-panel-toggle")).toBeNull();
      expect(screen.getByTestId("chat-task-item-cnv_task_1")).toHaveAttribute(
        "data-status",
        "needs_review"
      );
    });
    expect(
      screen.getByTestId("chat-task-item-cnv_task_1").querySelector(".comma-shiny-text")
    ).toBeNull();
  });

  it("settles an arriving row only from its own reveal animation", async () => {
    const task: ChatCreatedTask = {
      archiveVersion: 7,
      conversationId: "cnv_task_arrival",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "needs_review",
      title: "Review the arrival",
      turnKey: "msg_u1",
      version: 1,
    };
    const secondTask: ChatCreatedTask = {
      ...task,
      conversationId: "cnv_task_arrival_2",
      title: "Second arrival",
    };
    const actions = {
      onArchive: vi.fn().mockResolvedValue(undefined),
      onDismiss: vi.fn(),
      onOpen: vi.fn(),
      onReveal: vi.fn(),
    };
    const { rerender } = render(
      <ChatTaskPanel
        {...actions}
        defaultOpenPopover="attention"
        items={[task, secondTask]}
      />
    );
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
      <ChatTaskPanel
        {...actions}
        defaultOpenPopover="attention"
        items={[{ ...task, archiveVersion: undefined }, secondTask]}
      />
    );
    expect(screen.getByTestId("chat-task-item-cnv_task_arrival")).toBe(item);
    expect(item).not.toHaveAttribute("data-arriving");

    rerender(
      <ChatTaskPanel
        {...actions}
        defaultOpenPopover="attention"
        items={[task, secondTask]}
      />
    );
    expect(screen.getByTestId("chat-task-item-cnv_task_arrival")).toBe(item);
    expect(item).not.toHaveAttribute("data-arriving");
  });

  it("settles an arriving row when its reveal animation is cancelled", async () => {
    const task: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_task_cancelled_arrival",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "in_progress",
      title: "Cancelled arrival",
      turnKey: "msg_u1",
      version: 1,
    };
    render(
      <ChatTaskPanel
        defaultOpenPopover="active"
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

  it("opens popovers on demand and closes them on Escape or outside click", async () => {
    const user = userEvent.setup();
    const runningTask: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_task_active",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "in_progress",
      title: "Running task",
      turnKey: "msg_u1",
      version: 1,
    };
    const reviewA: ChatCreatedTask = {
      ...runningTask,
      conversationId: "cnv_task_review_1",
      statusBucket: "needs_review",
      title: "Review PR #1",
    };
    const reviewB: ChatCreatedTask = {
      ...runningTask,
      conversationId: "cnv_task_review_2",
      statusBucket: "needs_review",
      title: "Review PR #2",
    };

    render(
      <div>
        <button data-testid="outside-target" type="button">
          Outside
        </button>
        <ChatTaskPanel
          items={[reviewA, reviewB, runningTask]}
          onArchive={vi.fn()}
          onDismiss={vi.fn()}
          onOpen={vi.fn()}
          onReveal={vi.fn()}
        />
      </div>
    );

    // Popovers start closed; left focus strip shows the top review task + "+1", right pill shows "1 running".
    expect(screen.queryByTestId("chat-dock-attention-popover")).toBeNull();
    expect(screen.queryByTestId("chat-dock-active-popover")).toBeNull();
    expect(screen.getByTestId("chat-dock-attention-focus")).toHaveTextContent(
      "Review PR #1"
    );
    expect(screen.getByTestId("chat-dock-attention-focus")).not.toHaveTextContent(
      /\bOpen\b/
    );
    expect(screen.getByTestId("chat-dock-attention-toggle")).toHaveTextContent("+1");
    expect(screen.getByTestId("chat-task-panel-toggle")).toHaveTextContent("1 running");

    // Opening the attention popover shows both review items.
    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.getByTestId("chat-dock-attention-popover")).toBeVisible();
    expect(screen.getByTestId("chat-task-item-cnv_task_review_1")).toBeVisible();
    expect(screen.getByTestId("chat-task-item-cnv_task_review_2")).toBeVisible();

    // Switching to the active popover closes the attention popover.
    await user.click(screen.getByTestId("chat-task-panel-toggle"));
    expect(screen.queryByTestId("chat-dock-attention-popover")).toBeNull();
    expect(screen.getByTestId("chat-dock-active-popover")).toBeVisible();
    expect(screen.getByTestId("chat-task-item-cnv_task_active")).toBeVisible();

    // Escape closes the open popover.
    await user.keyboard("{Escape}");
    expect(screen.queryByTestId("chat-dock-active-popover")).toBeNull();

    // Clicking outside also closes an open popover.
    await user.click(screen.getByTestId("chat-task-panel-toggle"));
    expect(screen.getByTestId("chat-dock-active-popover")).toBeVisible();
    await user.click(screen.getByTestId("outside-target"));
    expect(screen.queryByTestId("chat-dock-active-popover")).toBeNull();
  });

  it("closes an open popover when clicking blank space in the dock bar or the focus bubble", async () => {
    const user = userEvent.setup();
    const onOpen = vi.fn();
    const loopA: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_loop_1",
      messageId: undefined,
      needsAttention: false,
      needsInput: false,
      loopStanding: { kind: "scheduled", text: "Every day at 8:00 AM" },
      loopStop: undefined,
      statusBucket: "loops",
      title: "Morning PR brief",
      turnKey: undefined,
      version: 1,
    };
    const loopB: ChatCreatedTask = {
      ...loopA,
      conversationId: "cnv_loop_2",
      title: "Daily digest",
    };
    const reviewA: ChatCreatedTask = {
      ...loopA,
      conversationId: "cnv_review_1",
      loopStanding: undefined,
      statusBucket: "needs_review",
      title: "Review PR #1",
    };
    const reviewB: ChatCreatedTask = {
      ...reviewA,
      conversationId: "cnv_review_2",
      title: "Review PR #2",
    };

    const { container, rerender } = render(
      <ChatTaskPanel
        items={[loopA, loopB]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={onOpen}
        onReveal={vi.fn()}
      />
    );

    const bar = container.querySelector<HTMLElement>(".comma-chat-dock-bar")!;
    const activeToggle = screen.getByTestId("chat-task-panel-toggle");

    // Clicking the empty space to the right of the pill in the dock bar closes the menu.
    await user.click(activeToggle);
    expect(screen.getByTestId("chat-dock-active-popover")).toBeVisible();
    await user.click(bar);
    expect(screen.queryByTestId("chat-dock-active-popover")).toBeNull();

    // Clicking the toggle pill itself still toggles cleanly without bouncing back open.
    await user.click(activeToggle);
    expect(screen.getByTestId("chat-dock-active-popover")).toBeVisible();
    await user.click(activeToggle);
    expect(screen.queryByTestId("chat-dock-active-popover")).toBeNull();

    // With both focus bubble and active pill present, clicking the bar gap or focus bubble closes the popover.
    rerender(
      <ChatTaskPanel
        items={[reviewA, reviewB, loopA]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={onOpen}
        onReveal={vi.fn()}
      />
    );

    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.getByTestId("chat-dock-attention-popover")).toBeVisible();
    await user.click(bar);
    expect(screen.queryByTestId("chat-dock-attention-popover")).toBeNull();

    // Clicking the FocusTaskBubble +N toggle itself closes without bouncing back open.
    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.getByTestId("chat-dock-attention-popover")).toBeVisible();
    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.queryByTestId("chat-dock-attention-popover")).toBeNull();

    await user.click(screen.getByTestId("chat-task-panel-toggle"));
    expect(screen.getByTestId("chat-dock-active-popover")).toBeVisible();
    await user.click(screen.getByRole("button", { name: /Review PR #1/ }));
    expect(screen.queryByTestId("chat-dock-active-popover")).toBeNull();
    expect(onOpen).toHaveBeenCalledWith(reviewA, "chat");

    // Clicking the focusCard +N toggle itself also closes without bouncing back open.
    const focusCard: ChatAttentionCard = {
      actionLabel: "Answer",
      expiresAt: null,
      id: "question:msg_q1",
      kind: "question",
      kindLabel: "Question",
      messageId: "msg_q1",
      priority: 1,
      title: "Keep the canary?",
      turnKey: "msg_u1",
    };
    rerender(
      <ChatTaskPanel
        attentionCards={[focusCard]}
        items={[reviewA, loopA]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={onOpen}
        onReveal={vi.fn()}
        onRevealCard={vi.fn()}
      />
    );
    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.getByTestId("chat-dock-attention-popover")).toBeVisible();
    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.queryByTestId("chat-dock-attention-popover")).toBeNull();
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
    const { setState } = renderConversation({ state: taskState("needs_review") });

    // Single settled task surfaces directly in the focus strip with Reveal & Dismiss.
    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-reveal-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();

    // Running again re-docks the task in the active pill…
    setState(taskState("in_progress", [], 2));
    await screen.findByTestId("chat-task-panel-toggle");

    // …and its next settle is a newer version than the one acknowledged, so it
    // shows again in the attention focus strip.
    setState(taskState("needs_review", [], 3));
    await waitFor(() => {
      expect(screen.getByTestId("chat-task-item-cnv_task_1")).toHaveAttribute(
        "data-status",
        "needs_review"
      );
    });
    await user.click(screen.getByTestId("chat-task-reveal-cnv_task_1"));
    await waitFor(() => {
      expect(screen.queryByTestId("chat-task-panel")).toBeNull();
    });
  });

  it("shows a newer settle that this device never saw run", async () => {
    const user = userEvent.setup();
    const { setState } = renderConversation({ state: taskState("needs_review") });
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

    // The Task is renamed elsewhere: a newer version of the same run.
    setState(taskState("needs_review", [], 1, 9));
    await waitFor(() => expect(screen.queryByTestId("chat-task-panel")).toBeNull());
    expect(screen.queryByTestId("chat-task-item-cnv_task_1")).toBeNull();
  });

  it("lets a task that ended leave the panel without an acknowledgement", async () => {
    const { setState } = renderConversation({ state: taskState("in_progress") });
    await screen.findByTestId("chat-task-panel-toggle");

    for (const status of ["completed", "cancelled"]) {
      setState(taskState(status));
      await waitFor(() => expect(screen.queryByTestId("chat-task-panel")).toBeNull());
      setState(taskState("in_progress", [], 2));
      await screen.findByTestId("chat-task-panel-toggle");
    }
  });

  it("keeps a failed task until it is dismissed", async () => {
    const user = userEvent.setup();
    const { setState } = renderConversation({ state: taskState("in_progress") });
    await screen.findByTestId("chat-task-panel-toggle");

    setState(taskState("failed"));
    await waitFor(() =>
      expect(screen.getByTestId("chat-task-dismiss-cnv_task_1")).toBeTruthy()
    );
    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();
  });

  it("keeps a dismissal when another surface still sees the task running", async () => {
    const user = userEvent.setup();
    renderConversation({ state: taskState("needs_review") });
    // The rail reads the same chat with facts that can lag: it still has the
    // Task running long after it settled.
    renderConversation({ state: taskState("in_progress"), variant: "rail" });

    await screen.findByTestId("chat-task-item-cnv_task_1");
    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));

    // The running copy on the other surface does not lift the acknowledgement.
    await waitFor(() => expect(screen.queryByTestId("chat-task-panel")).toBeNull());
  });

  it("docks every running task but mounts only the rows near the scrollport when opened", async () => {
    const user = userEvent.setup();
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
    const toggle = screen.getByTestId("chat-task-panel-toggle");
    expect(toggle.textContent).toContain("40 running");
    await user.click(toggle);

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
    expect(highlighted).toHaveLength(1);
    const marked = highlighted[0]!;
    expect(marked.classList.contains("comma-chat-assistant-response-body")).toBe(true);
    expect(marked.closest("[data-message-id]")?.getAttribute("data-message-id")).toBe(
      "msg_a1"
    );
  });

  it("surfaces open question cards in the focus bubble and answers them in their reply thread", async () => {
    const user = userEvent.setup();
    const question: ChatQuestionPart = {
      allowOther: true,
      choices: [
        { id: "rolling", label: "Rolling deploy", recommended: true },
        { id: "exclusive", label: "Exclusive cutover" },
      ],
      kind: "question",
      messageId: "msg_q1",
      multiSelect: false,
      prompt: "Choose the staging migration strategy",
      state: { status: "open" },
    };
    const laterTurns: ChatMessage[] = Array.from({ length: 4 }, (_, index) => [
      message(`msg_u${index + 2}`, "user", `Follow-up ${index}`),
      message(`msg_a${index + 2}`, "assistant", `Reply ${index}`),
    ]).flat();

    renderConversation({
      state: settled({
        messages: [
          message("msg_u1", "user", "Prepare release"),
          message("msg_q1", "assistant", "Before we start:", {
            parts: [{ kind: "markdown", text: "Before we start:" }, question],
          }),
          ...laterTurns,
        ],
      }),
    });

    const focus = await screen.findByTestId("chat-dock-attention-focus");
    expect(focus).toHaveTextContent("Question");
    expect(focus).toHaveTextContent("Choose the staging migration strategy");

    await user.click(screen.getByTestId("chat-dock-card-question:msg_q1"));
    const thread = await screen.findByRole("region", { name: "Reply thread" });
    expect(thread.querySelector('[data-message-id="msg_q1"]')).not.toBeNull();
  });

  it("hands an answered card over to the next pending card until none is left", async () => {
    const user = userEvent.setup();
    const withQuestions = (open: ReadonlySet<string>) =>
      settled({
        messages: [
          message("msg_u1", "user", "Prepare release"),
          ...(["msg_q1", "msg_q2"] as const).map((id) => {
            const part = openQuestion(
              id,
              id === "msg_q1" ? "Keep the canary?" : "Freeze merges?"
            );
            return message(id, "assistant", "Decide:", {
              parts: [
                { kind: "markdown", text: "Decide:" },
                open.has(id)
                  ? part
                  : { ...part, state: { status: "answered", choiceIds: ["yes"] } },
              ],
            });
          }),
        ],
      });
    const { setState } = renderConversation({
      state: withQuestions(new Set(["msg_q1", "msg_q2"])),
    });

    // The newest card leads; answering it starts a run over both.
    await user.click(await screen.findByTestId("chat-dock-card-question:msg_q2"));
    let thread = await screen.findByRole("region", { name: "Reply thread" });
    expect(thread.querySelector('[data-message-id="msg_q2"]')).not.toBeNull();
    expect(within(thread).getByRole("status")).toHaveTextContent("1 / 2");

    // The reader answers in the thread.
    fireEvent.pointerDown(thread.querySelector('[data-message-id="msg_q2"]')!);
    act(() => setState(withQuestions(new Set(["msg_q1"]))));
    await waitFor(
      () => {
        thread = screen.getByRole("region", { name: "Reply thread" });
        expect(thread.querySelector('[data-message-id="msg_q1"]')).not.toBeNull();
      },
      { timeout: 3000 }
    );
    expect(within(thread).getByRole("status")).toHaveTextContent("2 / 2");

    fireEvent.pointerDown(thread.querySelector('[data-message-id="msg_q1"]')!);
    act(() => setState(withQuestions(new Set())));
    await waitFor(
      () => expect(screen.queryByRole("region", { name: "Reply thread" })).toBeNull(),
      { timeout: 3000 }
    );
  });

  it("ends a run without moving on when its card closes without an answer here", async () => {
    const user = userEvent.setup();
    const withQuestions = (open: ReadonlySet<string>) =>
      settled({
        messages: [
          message("msg_u1", "user", "Prepare release"),
          ...(["msg_q1", "msg_q2"] as const).map((id) => {
            const part = openQuestion(
              id,
              id === "msg_q1" ? "Keep the canary?" : "Freeze merges?"
            );
            return message(id, "assistant", "Decide:", {
              parts: [
                { kind: "markdown", text: "Decide:" },
                open.has(id)
                  ? part
                  : { ...part, state: { status: "answered", choiceIds: ["yes"] } },
              ],
            });
          }),
        ],
      });
    const { setState } = renderConversation({
      state: withQuestions(new Set(["msg_q1", "msg_q2"])),
    });

    await user.click(await screen.findByTestId("chat-dock-card-question:msg_q2"));
    const thread = await screen.findByRole("region", { name: "Reply thread" });
    expect(within(thread).getByRole("status")).toHaveTextContent("1 / 2");

    // Answered on another device: the reader did nothing in this thread.
    act(() => setState(withQuestions(new Set(["msg_q1"]))));
    // Past the handoff delay: no next card takes over.
    act(() => vi.advanceTimersByTime(1000));
    const still = screen.getByRole("region", { name: "Reply thread" });
    expect(still.querySelector('[data-message-id="msg_q2"]')).not.toBeNull();
    expect(still.querySelector('[data-message-id="msg_q1"]')).toBeNull();
  });

  it("shows a card in the transcript when its message cannot take a reply", async () => {
    const user = userEvent.setup();
    renderConversation({
      state: settled({
        messages: [
          message("msg_u1", "user", "Prepare release"),
          message("msg_q1", "assistant", "Decide:", {
            delivery: "failed",
            parts: [
              { kind: "markdown", text: "Decide:" },
              openQuestion("msg_q1", "Keep the canary?"),
            ],
          }),
        ],
      }),
    });

    await user.click(await screen.findByTestId("chat-dock-card-question:msg_q1"));

    await waitFor(() => {
      expect(
        document
          .querySelector('[data-reveal-highlight="true"]')
          ?.closest("[data-message-id]")
          ?.getAttribute("data-message-id")
      ).toBe("msg_q1");
    });
    expect(screen.queryByRole("region", { name: "Reply thread" })).toBeNull();
  });

  it("shows pending confirmation cards and review tasks together in the attention popover", async () => {
    const user = userEvent.setup();
    const onRevealCard = vi.fn();
    const cards: ChatAttentionCard[] = [
      {
        actionLabel: "Fill in",
        expiresAt: null,
        id: "request:req_1",
        kind: "secret",
        kindLabel: "Secret",
        messageId: "msg_a1",
        priority: 1,
        title: "Fill in Stripe test key",
        turnKey: "msg_u1",
      },
      {
        actionLabel: "Answer",
        expiresAt: null,
        id: "question:msg_q1",
        kind: "question",
        kindLabel: "Question",
        messageId: "msg_q1",
        priority: 2,
        title: "Rolling or exclusive?",
        turnKey: "msg_u1",
      },
    ];
    const reviewTask: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_review_1",
      messageId: "msg_a2",
      needsAttention: true,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "needs_review",
      title: "Fix attribution PR",
      turnKey: "msg_u2",
      version: 1,
    };
    const runningTask: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_run_1",
      messageId: "msg_a3",
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "in_progress",
      title: "Run client E2E",
      turnKey: "msg_u3",
      version: 1,
    };

    render(
      <ChatTaskPanel
        attentionCards={cards}
        items={[reviewTask, runningTask]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
        onRevealCard={onRevealCard}
      />
    );

    expect(screen.getByTestId("chat-dock-attention-focus")).toHaveTextContent(
      "Fill in Stripe test key"
    );
    expect(screen.getByTestId("chat-dock-attention-toggle")).toHaveTextContent("+2");
    expect(screen.getByTestId("chat-task-panel-toggle")).toHaveTextContent("1 running");

    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    expect(screen.getByTestId("chat-dock-attention-popover")).toBeVisible();
    expect(screen.getByTestId("chat-dock-card-row-request:req_1")).toBeVisible();
    expect(screen.getByTestId("chat-dock-card-row-question:msg_q1")).toBeVisible();
    expect(screen.getByTestId("chat-task-item-cnv_review_1")).toBeVisible();

    await user.click(screen.getByTestId("chat-dock-card-row-question:msg_q1"));
    expect(onRevealCard).toHaveBeenCalledExactlyOnceWith(cards[1]);
    expect(screen.queryByTestId("chat-dock-attention-popover")).toBeNull();
  });

  it("filters between running tasks and loops inside the active popover", async () => {
    const user = userEvent.setup();
    const running: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_run",
      messageId: undefined,
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "in_progress",
      title: "Build release",
      turnKey: undefined,
      version: 1,
    };
    const loop: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_loop",
      messageId: undefined,
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      loopStanding: { kind: "scheduled", text: "Every day at 9:00 AM" },
      statusBucket: "loops",
      title: "Daily AI radar",
      turnKey: undefined,
      version: 1,
    };

    render(
      <ChatTaskPanel
        items={[running, loop]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
      />
    );

    await user.click(screen.getByTestId("chat-task-panel-toggle"));
    expect(
      screen
        .getByTestId("chat-dock-active-popover")
        .querySelector(".comma-chat-dock-popover-title svg")
    ).toBeNull();
    expect(screen.getByTestId("chat-task-item-cnv_run")).toBeVisible();
    expect(screen.getByTestId("chat-task-item-cnv_loop")).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Loops 1" }));
    expect(screen.queryByTestId("chat-task-item-cnv_run")).toBeNull();
    expect(screen.getByTestId("chat-task-item-cnv_loop")).toBeVisible();

    await user.click(screen.getByRole("button", { name: "In progress 1" }));
    expect(screen.getByTestId("chat-task-item-cnv_run")).toBeVisible();
    expect(screen.queryByTestId("chat-task-item-cnv_loop")).toBeNull();
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
    // Open the Task, Dismiss, Reveal in Chat; no Open CTA badge.
    expect(item.querySelectorAll("button")).toHaveLength(3);
    expect(item.querySelector(".comma-chat-dock-cta")).toBeNull();
    expect(item).not.toHaveTextContent(/\bOpen\b/);
    expect(screen.getByTestId("chat-task-dismiss-cnv_task_1")).toBeVisible();
    expect(screen.getByTestId("chat-task-reveal-cnv_task_1")).toBeVisible();

    await user.click(screen.getByTestId("chat-task-dismiss-cnv_task_1"));
    expect(screen.queryByTestId("chat-task-panel")).toBeNull();
    // Hiding the row never anchors the announcing turn.
    expect(document.querySelector('[data-turn-key="msg_u1"]')).toBeNull();
  });

  it("shows a Task whose Loop stopped on an error as stopped, not running", async () => {
    render(
      <ChatTaskPanel
        defaultOpenPopover="active"
        items={[
          {
            archiveVersion: undefined,
            conversationId: "cnv_task_paused",
            messageId: undefined,
            needsAttention: false,
            needsInput: false,
            loopStop: { text: "Stopped · couldn’t reach this task", failed: true },
            statusBucket: "loops",
            title: "Daily digest",
            turnKey: undefined,
            version: 1,
          },
        ]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
      />
    );

    const item = await screen.findByTestId("chat-task-item-cnv_task_paused");
    expect(item).toHaveTextContent("Stopped · couldn’t reach this task");
    expect(item).not.toHaveTextContent("In progress");
    expect(item.querySelector(".comma-task-status-spin")).toBeNull();
    expect(item.querySelector(".comma-task-status-loop-failed")).not.toBeNull();
    expect(item.querySelector(".comma-shiny-text")).toBeNull();
  });

  it("shows an active Loop Task with a static trigger icon and non-shimmering schedule", async () => {
    render(
      <ChatTaskPanel
        defaultOpenPopover="active"
        items={[
          {
            archiveVersion: undefined,
            conversationId: "cnv_task_loop_active",
            messageId: undefined,
            needsAttention: false,
            needsInput: false,
            loopStop: undefined,
            loopStanding: {
              kind: "scheduled",
              text: "Every day at 9:00 AM",
            },
            statusBucket: "loops",
            title: "Daily AI radar",
            turnKey: undefined,
            version: 1,
          },
        ]}
        onArchive={vi.fn()}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
      />
    );

    expect(screen.getByTestId("chat-task-panel-toggle")).toHaveTextContent("1 Loop");
    const item = await screen.findByTestId("chat-task-item-cnv_task_loop_active");
    expect(item).toHaveTextContent("Every day at 9:00 AM");
    expect(item).not.toHaveTextContent("In progress");
    expect(item.querySelector(".comma-task-status-spin")).toBeNull();
    expect(item.querySelector(".comma-task-status-loop-standing")).not.toBeNull();
    expect(item.querySelector(".comma-shiny-text")).toBeNull();
  });

  it("splits the row between opening the task and revealing its turn", async () => {
    const user = userEvent.setup();
    const task: ChatCreatedTask = {
      archiveVersion: undefined,
      conversationId: "cnv_task_split",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "in_progress",
      title: "Build the release",
      turnKey: "msg_u1",
      version: 1,
    };
    const onOpen = vi.fn();
    const onReveal = vi.fn();
    render(
      <ChatTaskPanel
        defaultOpenPopover="active"
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

  it("keeps archive with the settled row's Reveal and Dismiss controls in both focus strip and popover", async () => {
    const user = userEvent.setup();
    const onArchive = vi.fn().mockResolvedValue(undefined);
    const onDismiss = vi.fn();
    const onOpen = vi.fn();
    const onReveal = vi.fn();
    const task: ChatCreatedTask = {
      archiveVersion: 7,
      conversationId: "cnv_task_archive",
      messageId: "msg_a1",
      needsAttention: false,
      needsInput: false,
      loopStop: undefined,
      statusBucket: "needs_review",
      title: "Review the release",
      turnKey: "msg_u1",
      version: 1,
    };
    const otherTask: ChatCreatedTask = {
      ...task,
      conversationId: "cnv_task_archive_2",
      title: "Second release",
    };

    const { rerender } = render(
      <ChatTaskPanel
        items={[task]}
        onArchive={onArchive}
        onDismiss={onDismiss}
        onOpen={onOpen}
        onReveal={onReveal}
      />
    );

    const singleFocus = await screen.findByTestId("chat-task-item-cnv_task_archive");
    const singleArchive = screen.getByRole("button", { name: "Archive task" });
    expect(singleFocus.querySelectorAll("button")).toHaveLength(4);
    await user.click(singleArchive);
    await user.click(screen.getByRole("menuitem", { name: "Archive task" }));
    expect(onArchive).toHaveBeenCalledExactlyOnceWith(task);

    // Inside the expanded popover, clicking the portaled menu item must keep the popover mounted until archive runs.
    onArchive.mockClear();
    rerender(
      <ChatTaskPanel
        defaultOpenPopover="attention"
        items={[task, otherTask]}
        onArchive={onArchive}
        onDismiss={onDismiss}
        onOpen={onOpen}
        onReveal={onReveal}
      />
    );
    await user.click(screen.getByTestId("chat-dock-attention-toggle"));
    const row = await screen.findByTestId("chat-task-item-cnv_task_archive");
    const actions = row.querySelector(".comma-chat-task-item-actions");
    const archiveButton = row.querySelector<HTMLElement>(
      '[aria-label="Archive task"]'
    )!;
    expect(actions?.contains(archiveButton)).toBe(true);
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

function openQuestion(messageId: string, prompt: string): ChatQuestionPart {
  return {
    allowOther: false,
    // Independent cards, such as station cards, stay open side by side.
    independent: true,
    choices: [
      { id: "yes", label: "Yes" },
      { id: "no", label: "No" },
    ],
    kind: "question",
    messageId,
    multiSelect: false,
    prompt,
    state: { status: "open" },
  };
}
